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
  - the required jobs "Repository guard" and "Dev environment" exist and
    each has an isolated step;
  - every isolated step of those jobs is exactly one wrapped command, and the
    wrapper exists;
  - no isolated step has a key other than name, run and timeout-minutes, and
    no env or defaults apply to it from its job or the workflow;
  - no job or step has an `if:` condition (one could run a non-isolated
    step after a failed isolated one, or skip a required check) or a
    `continue-on-error:` key (a failed step, a security gate included,
    would no longer fail its job);
  - every tracked file that mentions no-docker.sh is either part of the
    isolation itself, documentation, the workflow, or has the re-exec
    stanza in its recognised form, so a suite isolated another way is
    noticed instead of being classified as not isolated.
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
SCRIPT =re.compile(r"(?<![\w./$-])((?:\./)?(?:[\w.-]+/)*[\w.-]+\.(?:sh|py))(?![\w.-])")
REQUIRED = ("Repository guard", "Dev environment")
# Runs code under test only through no-docker.sh (it has no stanza of its
# own: it tests the isolation from outside).
HARNESS = "scripts/ci/tests/no-docker.test.sh"

ok = True


def report(passed, text):
    global ok
    if not passed:
        ok = False
    print(f"ci-isolation-order: {'ok  ' if passed else 'FAIL'} {text}")


def indent(line):
    return len(line) - len(line.lstrip(" "))


def parse(path):
    """{job id: {"name": str, "steps": [{"name": str, "text": str}]}} of a
    workflow written in the block style of this repository."""
    jobs = {}
    lines = open(path).read().splitlines()
    in_jobs = False
    job = None
    step = None
    inherited = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        n = indent(line)
        if n == 0:
            in_jobs = line.rstrip() == "jobs:"
            job = step = None
            if line.split(":")[0] in INHERITED:
                inherited.append("workflow " + line.split(":")[0])
            continue
        if not in_jobs:
            continue
        if n == 2:
            job = {"name": "", "steps": [], "if": False, "coe": False, "inherited": inherited}
            jobs[line.strip().rstrip(":")] = job
            step = None
        elif n == 4 and job is not None:
            step = None
            key = line.strip()
            if key.split(":")[0] in INHERITED:
                job["inherited"] = job["inherited"] + ["job " + key.split(":")[0]]
            if key.startswith("name:"):
                job["name"] = key[len("name:"):].strip().strip("'\"")
            if key.startswith("if:"):
                job["if"] = True
            if key.startswith("continue-on-error:"):
                job["coe"] = True
        elif n >= 6 and job is not None:
            stripped = line.strip()
            if n == 6 and stripped.startswith("- "):
                step = {"name": "", "text": "", "if": False, "coe": False, "run": [], "in_run": False, "keys": set()}
                job["steps"].append(step)
                stripped = stripped[2:]
                n = 8
            if step is None:
                continue
            if n == 8:
                step["in_run"] = False
                step["keys"].add(stripped.split(":")[0])
                if stripped.startswith("name:"):
                    step["name"] = stripped[len("name:"):].strip().strip("'\"")
                elif stripped.startswith("if:"):
                    step["if"] = True
                elif stripped.startswith("continue-on-error:"):
                    step["coe"] = True
                elif stripped.startswith("run:"):
                    value = stripped[len("run:"):].strip()
                    step["in_run"] = True
                    if value in ("|", "|-", ">", ">-"):
                        step["style"] = value[0]
                    else:
                        step["style"] = "|"
                        step["run"].append(value)
            elif step.get("in_run"):
                step["run"].append(stripped)
    for job in jobs.values():
        for step in job["steps"]:
            sep = " " if step.get("style") == ">" else "\n"
            step["text"] = sep.join(step["run"])
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
        (iso if STANZA.search(content) else other).append(w)
    return bool(iso) and not other, bool(iso) and bool(other), missing


def starts_through_wrapper(text):
    """The whole step is one command in the exact form of WRAPPED. One suite per
    step: a second one joined by || or | could hide the first one's failure."""
    return bool(WRAPPED.fullmatch(text.strip()))


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
    workflow = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, ".github/workflows/ci.yml")
    jobs = parse(workflow)
    names = {j["name"]: jid for jid, j in jobs.items()}
    for required in REQUIRED:
        report(required in names, f"required job {required!r} exists")
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
