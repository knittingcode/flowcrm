"""Check that isolated steps come last in every CI job (static).

Usage: ci-isolation-order.py REPO_ROOT [WORKFLOW]   (default .github/workflows/ci.yml)

A step is isolated when every command it runs (in its `run:` text, or in
the recipe of a `make` target it runs) is scripts/ci/no-docker.sh, its
test harness scripts/ci/tests/no-docker.test.sh, or a script with the
recognised re-exec stanza: it runs code under test, which may leave files
or processes for later steps. A step that mixes such commands with others
fails.
The descriptor wrapper scripts/ci/fdnorm.py is transparent to this rule only
in the exact form "python3 -I scripts/ci/fdnorm.py -- PATH", with nothing
else on the command: the classification is then that of PATH. Any other
command that names the wrapper is not isolated, and the wrapper never makes
a command isolated by itself.
Code under test cannot write anything on the Linux runner's file systems
except private temporary directories, but the order is the second line:
after the first isolated step of a job, only isolated steps may follow.

Also checked:
  - the workflow is in the strict subset of YAML that load_workflow reads. A
    spelling it does not know is an error, not something to skip: GitHub would
    read `env :`, a bare `-` or a comment line in a block scalar differently
    from a reader that matches line prefixes;
  - the workflow, its jobs and its steps have only the keys listed below, the
    workflow runs for pull requests without path filters, and no job has `needs:`
    or another key that could skip a required check;
  - the required jobs "Repository guard" and "Dev environment" exist once and
    each has an isolated step;
  - in .github/workflows/ci.yml, they run exactly the suites in SUITES, in order;
  - every isolated step of those jobs is exactly one wrapped command, and the
    wrapper exists;
  - no isolated step has a key other than name, run and timeout-minutes, and
    no env or defaults apply to it from its job or the workflow;
  - no step writes to $GITHUB_ENV or $GITHUB_PATH, in its text or in a script it
    runs: that would reach later isolated steps as settings. The only action
    allowed is actions/checkout, pinned to a commit, with persist-credentials: false;
  - no run text has a ${{ }} expression, which GitHub expands before the shell;
  - a script counts as isolated only if its re-exec stanza comes before anything
    but comments, set options and the assignment of $here;
  - no job or step has an `if:` condition (one could run a non-isolated
    step after a failed isolated one, or skip a required check) or a
    `continue-on-error:` key (a failed step, a security gate included,
    would no longer fail its job);
  - every tracked file that mentions no-docker.sh is either part of the
    isolation itself, documentation, the workflow, or has the re-exec
    stanza in its recognised form, so a suite isolated another way is
    noticed instead of being classified as not isolated.
This reads the workflow's text. A script can still compute such a name, and the
runner has not been consulted: actionlint and GitHub read the same file separately.
Exit 0 if all hold; prints one line per check.
"""

import os
import re
import subprocess
import sys

STANZA = re.compile(r'no-docker\.sh" --check >/dev/null 2>&1 \|\|\n\s+exec "[^"\n]*/no-docker\.sh" ')
OWN = {"scripts/ci/no-docker.sh", "scripts/ci/no-docker-probe.py", "scripts/ci/tests/no-docker.test.sh",
       "scripts/ci/tests/ci-isolation-order.py", ".github/workflows/ci.yml",
       "scripts/ci/tests/no-docker-static.py", "scripts/ci/no-docker-aa.py",
       "scripts/ci/tests/ci-isolation-order-unit.py"}
WRAPPER = "scripts/ci/fdnorm.py"
# The only recognised use of the wrapper. No component starts with a dot, so
# neither ./ nor ../ can reach a script outside the checkout's own paths. A
# directory is required: execvp searches PATH for a bare name, which need not be
# the file classified here.
WRAPPED = re.compile(r"python3 -I scripts/ci/fdnorm\.py -- ((?:[\w-][\w.-]*/)+[\w-][\w.-]*\.(?:sh|py))")
SEPARATORS = r"\n|;|&&|\|\||\|"
# Keys an isolated step may have. Others, such as shell, env or
# working-directory, change how its exact run: line behaves.
STEP_KEYS = {"name", "run", "timeout-minutes"}
# Workflow and job keys that do the same for every step below them.
INHERITED = ("env", "defaults")
SCRIPT = re.compile(r"(?<![\w./$-])((?:\./)?(?:[\w.-]+/)*[\w.-]+\.(?:sh|py))(?![\w.-])")
REQUIRED = ("Repository guard", "Dev environment")
# The isolated suites of the real workflow, in order.
SUITES = {
    "Repository guard": ["scripts/ci/tests/guard-tracked-files.test.sh", "scripts/ci/tests/guard-dockerfile-frontend.test.sh",
                         "scripts/ci/tests/guard-trivyignore.test.sh", "scripts/ci/tests/guard-edge-config.test.sh",
                         "scripts/ci/tests/no-docker.test.sh"],
    "Dev environment": ["tests/devenv/unit.sh"],
}
WORKFLOW_KEYS = {"name", "on", "permissions", "concurrency", "jobs"}
JOB_KEYS = {"name", "runs-on", "timeout-minutes", "permissions", "steps"}
ANY_STEP_KEYS = {"name", "run", "uses", "with", "timeout-minutes"}
# The one action allowed. Any other, even pinned, could export settings for later
# steps (core.exportVariable) in text this check does not read.
CHECKOUT = re.compile(r"actions/checkout@[0-9a-f]{40}")
RUNNER = re.compile(r"ubuntu-\d\d\.\d\d")
PROPAGATES = re.compile(r"GITHUB_(ENV|PATH)|::(set-env|add-path)")
# What may run before the re-exec stanza of a script.
BEFORE_STANZA = re.compile(r'''(#.*|set -[a-z]+|here=\$\(cd (-P )?"\$\(dirname "\$0"\)" && pwd( -P)?\))?''')
# Runs code under test only through no-docker.sh (it has no stanza of its
# own: it tests the isolation from outside).
HARNESS = "scripts/ci/tests/no-docker.test.sh"

ok = True


def report(passed, text):
    global ok
    if not passed:
        ok = False
    print(f"ci-isolation-order: {'ok  ' if passed else 'FAIL'} {text}")


class Unreadable(Exception):
    """The workflow is outside the subset of YAML this file reads."""


KEY = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*):(?: +(.*))?")
FLOW_LIST = re.compile(r"\[ *[\w.-]+(?: *, *[\w.-]+)* *\]")
BLOCK_HEADERS = ("|", "|-", ">", ">-")
# A line break or control character that a line-by-line reader and YAML see differently.
# Unicode spaces too: Python's strip removes them, and YAML and the shell keep them.
BAD_CHAR = re.compile("[\\x00-\\x09\\x0b-\\x1f\\x7f-\\xa0\\u1680\\u180e\\u2000-\\u200f\\u2028-\\u202f\\u205f-\\u2064\\u3000\\ufeff]")


def line_indent(line):
    return len(line) - len(line.lstrip(" "))


def is_blank(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def scalar(value, no):
    """A one-line value. Always a string, or a list for a flow list of plain words."""
    value = value.strip(" ")
    quoted = re.fullmatch(r"(?:'([^']*)'|\"([^\"\\\\]*)\")(?: +#.*)?", value)
    if quoted:
        return quoted.group(1) if quoted.group(1) is not None else quoted.group(2)
    value = re.sub(r"(^| +)#.*$", "", value)
    if not value:
        raise Unreadable(f"line {no}: a value that is only a comment")
    if FLOW_LIST.fullmatch(value):
        return [w.strip() for w in value[1:-1].split(",")]
    if value[0] in "&*!|>'\"%@`{[]},?#~" or value in ("-", "?", ":") or value.startswith(("- ", "? ", ": ")):
        raise Unreadable(f"line {no}: value {value!r} needs more of YAML than this file reads")
    if ": " in value or value.endswith(":"):
        raise Unreadable(f"line {no}: value {value!r} has a colon that YAML may read as a key")
    return value


class Reader:
    def __init__(self, text):
        bad = BAD_CHAR.search(text)
        if bad:
            raise Unreadable(f"character {ord(bad.group(0)):#x} is not allowed")
        self.lines = text.split("\n")
        self.i = 0

    def skip(self):
        while self.i < len(self.lines) and is_blank(self.lines[self.i]):
            self.i += 1

    def more(self, indent):
        """Whether the next line that holds content is at this indent; deeper is an error."""
        self.skip()
        if self.i >= len(self.lines):
            return False
        n = line_indent(self.lines[self.i])
        if n > indent:
            raise Unreadable(f"line {self.i + 1}: unexpected indent")
        return n == indent

    def block(self, indent):
        self.skip()
        if self.lines[self.i].lstrip(" ").startswith("-"):
            return self.sequence(indent)
        return self.mapping(indent)

    def sequence(self, indent):
        items = []
        while self.more(indent):
            line = self.lines[self.i]
            rest = line[indent:]
            if not rest.startswith("- ") or rest[2:3] == " " or not KEY.fullmatch(rest[2:]):
                raise Unreadable(f"line {self.i + 1}: a list item must be written as \"- key: value\"")
            self.lines[self.i] = " " * (indent + 2) + rest[2:]
            items.append(self.mapping(indent + 2))
        return items

    def mapping(self, indent):
        result = {}
        while self.more(indent):
            no = self.i + 1
            m = KEY.fullmatch(self.lines[self.i][indent:])
            if not m:
                raise Unreadable(f"line {no}: not a plain \"key: value\": {self.lines[self.i].strip()!r}")
            key, value = m.group(1), m.group(2)
            if key in result:
                raise Unreadable(f"line {no}: duplicate key {key}")
            self.i += 1
            value = (value or "").strip(" ")
            if value in BLOCK_HEADERS:
                result[key] = self.block_scalar(indent, value, no)
            elif not value or value.startswith("#"):
                self.skip()
                deeper = self.i < len(self.lines) and line_indent(self.lines[self.i]) > indent
                result[key] = self.block(line_indent(self.lines[self.i])) if deeper else None
            else:
                result[key] = scalar(value, no)
        return result

    def block_scalar(self, indent, header, no):
        body = []
        width = None
        while self.i < len(self.lines):
            line = self.lines[self.i]
            if not line.strip():
                body.append("")
                self.i += 1
                continue
            n = line_indent(line)
            if n <= indent:
                break
            if width is None:
                width = n
            if n < width:
                raise Unreadable(f"line {self.i + 1}: less indented than its block scalar")
            body.append(line[width:])
            self.i += 1
        while body and not body[-1]:
            body.pop()
        if not body:
            raise Unreadable(f"line {no}: empty block scalar")
        if header[0] == ">":
            if any(not b or b.startswith(" ") for b in body):
                raise Unreadable(f"line {no}: a folded scalar with a blank or deeper line")
            return " ".join(body)
        return "\n".join(body)


def load_workflow(text):
    """The workflow as dicts, lists and strings, or Unreadable.

    This is a strict subset of YAML, not a YAML parser: the workflow is checked with
    `python3 -I` on a runner where PyYAML is not known to exist and nothing may be
    installed, and refusing every other spelling cannot read one differently from
    GitHub. The regressions compare it with PyYAML where that is available."""
    reader = Reader(text)
    tree = reader.mapping(0)
    reader.skip()
    if reader.i < len(reader.lines):
        raise Unreadable(f"line {reader.i + 1}: not a plain \"key: value\" at the top level")
    return tree


def parse(path):
    """{job id: {"name": str, "steps": [{"name": str, "text": str, ...}], ...}} of a
    workflow. Keys the rules care about are kept for main to report."""
    with open(path, encoding="utf-8") as f:
        return jobs_of(load_workflow(f.read()))


def jobs_of(tree):
    jobs = {}
    inherited = [f"workflow {k}" for k in INHERITED if k in tree]
    raw_jobs = tree.get("jobs")
    if not isinstance(raw_jobs, dict) or not raw_jobs:
        raise Unreadable("the workflow has no jobs mapping")
    for jid, raw in raw_jobs.items():
        if not isinstance(raw, dict) or not isinstance(raw.get("steps"), list):
            raise Unreadable(f"job {jid} has no list of steps")
        job = {"name": raw.get("name") if isinstance(raw.get("name"), str) else "", "keys": set(raw), "steps": [],
               "if": "if" in raw, "coe": "continue-on-error" in raw, "raw": raw,
               "inherited": inherited + [f"job {k}" for k in INHERITED if k in raw]}
        for rs in raw["steps"]:
            run = rs.get("run")
            job["steps"].append({"name": rs.get("name") if isinstance(rs.get("name"), str) else "",
                                 "text": run if isinstance(run, str) else "", "keys": set(rs), "raw": rs,
                                 "if": "if" in rs, "coe": "continue-on-error" in rs})
        jobs[jid] = job
    return jobs


def make_recipe(root, target):
    try:
        lines = open(os.path.join(root, "Makefile")).read().splitlines()
    except OSError:
        return ""
    out, inside = [], False
    for line in lines:
        if re.match(rf"^{re.escape(target)}\s*:", line):
            inside = True
            continue
        if inside:
            if line.startswith("\t"):
                out.append(line)
            else:
                break
    return "\n".join(out)


def commands(text):
    """The program each simple command of a shell text runs: the first word
    after variable assignments and an interpreter (bash, sh, python3, exec,
    env) of every command separated by a newline, ;, &&, || or |. A command
    in the exact form of WRAPPED counts as PATH; any other command that names
    the wrapper counts as the wrapper, which has no stanza and is not isolated."""
    words = []
    for part in re.split(SEPARATORS, text):
        wrapped = WRAPPED.fullmatch(part.strip())
        if wrapped:
            words.append(wrapped.group(1))
            continue
        if "fdnorm" in part or "fd*" in part:
            words.append(WRAPPER)
            continue
        toks = part.split()
        while toks and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]) or toks[0] in ("exec", "env", "then", "do", "!")
                        or toks[0].lstrip("@") in ("bash", "sh", "python3", "/bin/bash", "/bin/sh")):
            toks = toks[1:]
            while toks and toks[0].startswith("-") and toks[0] != "-":
                toks = toks[1:]  # interpreter options such as -I or -e
        if toks:
            words.append(toks[0])
    return words


def step_commands(root, text):
    """Every program a step runs: its own commands and those of the
    recipes of the make targets it runs. A make command that is not plainly
    "make TARGET..." with a recipe for each target stays the command make,
    which is not isolated."""
    words = []
    for part in re.split(SEPARATORS, text):
        found = commands(part)
        plain = re.fullmatch(r"make((?:\s+[A-Za-z][\w-]*)+)", part.strip())
        recipes = [make_recipe(root, t) for t in plain.group(1).split()] if plain and found == ["make"] else []
        if recipes and all(recipes):
            for recipe in recipes:
                words += commands(recipe.replace("\t", " "))
        else:
            words += found
    return [w[2:] if w.startswith("./") else w for w in words]


def stanza_first(content):
    """The re-exec stanza is there, and nothing ran before it."""
    m = STANZA.search(content)
    if not m:
        return False
    start = content.rfind("\n", 0, m.start()) + 1
    return all(BEFORE_STANZA.fullmatch(line.strip()) for line in content[:start].split("\n"))


def propagates(root, step):
    """Whether the step writes settings for later steps: in its text, or in a script
    it runs. Quotes and backslashes do not hide the name from this."""
    texts = [step["text"]]
    for w in step_commands(root, step["text"]):
        if SCRIPT.fullmatch(w):
            try:
                with open(os.path.join(root, w), encoding="utf-8", errors="replace") as f:
                    texts.append(f.read())
            except OSError:
                pass
    return any(PROPAGATES.search(re.sub(r"[\"'\\\\\n]", "", t)) for t in texts)


def late_stanzas(root, step):
    """Scripts a step runs that have the stanza after other code: such a script is
    neither isolated nor ordinary, so it is refused rather than reclassified."""
    found = []
    for w in step_commands(root, step["text"]):
        if SCRIPT.fullmatch(w):
            try:
                with open(os.path.join(root, w), encoding="utf-8", errors="replace") as f:
                    content = f.read()
            except OSError:
                continue
            if STANZA.search(content) and not stanza_first(content):
                found.append(w)
    return found


def check_trigger(tree):
    """The workflow runs for pull requests, and no filter can skip it for some of them."""
    on = tree.get("on")
    problems = []
    if not isinstance(on, dict) or "pull_request" not in on:
        return ["it does not run for pull requests"]
    for event, spec in on.items():
        if event not in ("pull_request", "push"):
            problems.append(f"event {event}")
        elif spec is not None and (not isinstance(spec, dict) or set(spec) != {"branches"} or not isinstance(spec["branches"], list)
                                   or "main" not in spec["branches"]):
            problems.append(f"{event} has filters other than branches including main")
    return problems


def check_structure(tree, jobs):
    extra = sorted(set(tree) - WORKFLOW_KEYS - set(INHERITED))
    report(not extra, "the workflow has only known keys" + (f" (also: {', '.join(extra)})" if extra else ""))
    problems = check_trigger(tree)
    report(not problems, "the workflow runs for every pull request" + (f" ({'; '.join(problems)})" if problems else ""))
    for jid, job in jobs.items():
        label = job["name"] or jid
        extra = sorted(job["keys"] - JOB_KEYS - set(INHERITED) - {"if", "continue-on-error"})
        report(not extra, f"{label}: the job has only known keys" + (f" (also: {', '.join(extra)}; needs and others can skip it)" if extra else ""))
        runner = job["raw"].get("runs-on")
        report(isinstance(runner, str) and bool(RUNNER.fullmatch(runner)), f"{label}: runs on a fixed Ubuntu image")
        for step in job["steps"]:
            name = f"{label} / {step['name']}"
            raw = step["raw"]
            extra = sorted(step["keys"] - ANY_STEP_KEYS - {"if", "continue-on-error"})
            report(not extra, f"{name}: the step has only known keys" + (f" (also: {', '.join(extra)})" if extra else ""))
            # GitHub expands an expression before the shell sees the text, so nothing
            # read here is what would run.
            report("${{" not in step["text"], f"{name}: has no expression in its run text")
            kinds = ("run" in raw) + ("uses" in raw)
            report(kinds == 1 and isinstance(raw.get("run", ""), str), f"{name}: has one run text or one action")
            if "uses" in raw:
                report(isinstance(raw["uses"], str) and bool(CHECKOUT.fullmatch(raw["uses"])), f"{name}: the action is actions/checkout, pinned to a commit")
                report(raw.get("with") == {"persist-credentials": "false"}, f"{name}: the action has exactly persist-credentials: false")
            elif "with" in raw:
                report(False, f"{name}: has with only for an action")


def isolated(root, step):
    """(isolated, mixed, missing scripts) of a step. A command is isolated
    when it is scripts/ci/no-docker.sh, the isolation's own test harness, or
    a script with the recognised re-exec stanza; any other command (docker,
    make help, a trusted guard) is not. A step is isolated when all of its
    commands are; one that mixes both is reported."""
    iso, other, missing = [], [], []
    for w in step_commands(root, step["text"]):
        if not SCRIPT.fullmatch(w):
            other.append(w)
            continue
        if w in ("scripts/ci/no-docker.sh", HARNESS):
            iso.append(w)
            continue
        try:
            content = open(os.path.join(root, w), encoding="utf-8", errors="replace").read()
        except OSError:
            missing.append(w)
            continue
        (iso if stanza_first(content) else other).append(w)
    return bool(iso) and not other, bool(iso) and bool(other), missing


def starts_through_wrapper(text):
    """The whole step is one command in the exact form of WRAPPED. One suite per
    step: a second one joined by || or | could hide the first one's failure."""
    return bool(WRAPPED.fullmatch(text))


def tracked(root):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
        return [p for p in out.decode().split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        found = []
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x != ".git"]
            found += [os.path.relpath(os.path.join(d, f), root) for f in files]
        return found


def main():
    root = os.path.abspath(sys.argv[1])
    real = len(sys.argv) <= 2
    workflow = os.path.join(root, ".github/workflows/ci.yml") if real else sys.argv[2]
    try:
        with open(workflow, encoding="utf-8") as f:
            tree = load_workflow(f.read())
        jobs = jobs_of(tree)
    except (Unreadable, OSError, UnicodeDecodeError) as e:
        report(False, f"the workflow can be read strictly: {e}")
        return 1
    report(True, "the workflow can be read strictly")
    check_structure(tree, jobs)
    names = [j["name"] for j in jobs.values()]
    for required in REQUIRED:
        report(names.count(required) == 1, f"required job {required!r} exists once")
    report(not any(j["if"] or any(s["if"] for s in j["steps"]) for j in jobs.values()),
           "no job or step has an if: condition")
    coe = [s["name"] or job["name"] for job in jobs.values() for s in [{"name": ""}] * job["coe"] + job["steps"]
           if s.get("coe", job["coe"] and not s["name"])]
    report(not coe, "no job or step has continue-on-error" + (f" ({', '.join(repr(c) for c in coe)})" if coe else ""))
    report(os.path.isfile(os.path.join(root, WRAPPER)), f"the descriptor wrapper {WRAPPER} exists")
    for jid, job in jobs.items():
        first = None
        late = []
        for i, step in enumerate(job["steps"]):
            iso, mixed, missing = isolated(root, step)
            report(not missing, f"{job['name'] or jid} / {step['name']}: the scripts it runs exist"
                   + (f" (missing {' '.join(missing)})" if missing else ""))
            report(not mixed, f"{job['name'] or jid} / {step['name']}: does not mix isolated and other commands")
            report(not propagates(root, step), f"{job['name'] or jid} / {step['name']}: writes nothing to GITHUB_ENV or GITHUB_PATH")
            late_scripts = late_stanzas(root, step)
            report(not late_scripts, f"{job['name'] or jid} / {step['name']}: no script runs code before its stanza"
                   + (f" ({' '.join(late_scripts)})" if late_scripts else ""))
            if iso and job["name"] in REQUIRED:
                through = starts_through_wrapper(step["text"])
                report(through, f"{job['name'] or jid} / {step['name']}: "
                       + ("starts through the descriptor wrapper" if through else "does not start through the descriptor wrapper"))
            if iso:
                changes = sorted(step["keys"] - STEP_KEYS) + job["inherited"]
                report(not changes, f"{job['name'] or jid} / {step['name']}: nothing changes how the step runs"
                       + (f" (changes how it runs: {', '.join(changes)})" if changes else ""))
            if iso and first is None:
                first = step["name"]
            elif not iso and first is not None:
                late.append(step["name"])
        report(not late, f"{job['name'] or jid}: no step that is not isolated after the first isolated one"
               + (f" ({first!r}, then {', '.join(repr(s) for s in late)})" if late else ""))
        if job["name"] in REQUIRED:
            report(first is not None, f"{job['name']}: has isolated steps (first: {first})")
        if real and job["name"] in SUITES:
            ran = [m.group(1) for m in (WRAPPED.fullmatch(s["text"]) for s in job["steps"]) if m]
            report(ran == SUITES[job["name"]], f"{job['name']}: runs exactly its wrapped suites, in order"
                   + (f" (found {' '.join(ran)})" if ran != SUITES[job["name"]] else ""))
    unknown = []
    for p in tracked(root):
        if p in OWN or p.endswith(".md"):
            continue
        try:
            content = open(os.path.join(root, p), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if "no-docker.sh" in content and not STANZA.search(content):
            unknown.append(p)
    report(not unknown, "every other file that mentions no-docker.sh has the recognised re-exec stanza"
           + (f" (not recognised: {' '.join(unknown)})" if unknown else ""))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
