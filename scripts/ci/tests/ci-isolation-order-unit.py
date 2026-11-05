"""Regressions of the descriptor wrapper rule of ci-isolation-order.py.

Usage: ci-isolation-order-unit.py PATH_TO_CI_ISOLATION_ORDER

Prints one "ok"/"FAIL" line per assertion and a SUMMARY line; exit 0 if all
pass. Every command below is workflow text in a temporary fixture: it is only
parsed, never run.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

path = os.path.abspath(sys.argv[1])
spec = importlib.util.spec_from_file_location("order", path)
order = importlib.util.module_from_spec(spec)
spec.loader.exec_module(order)

passed = failed = 0


def check(cond, text):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
    print(f"{'ok  ' if cond else 'FAIL'} {text}")


W = "python3 -I scripts/ci/fdnorm.py --"
ISO = "scripts/iso.test.sh"
root = tempfile.mkdtemp(prefix="order-unit.")


def write(rel, text):
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)


STANZA = ('"$here/no-docker.sh" --check >/dev/null 2>&1 ||\n'
          '  exec "$here/no-docker.sh" "$0" "$@"\n')
write(ISO, "#!/bin/bash\n" + STANZA)
write("scripts/guard.sh", "#!/bin/bash\nexit 0\n")
write("scripts/ci/fdnorm.py", "# wrapper fixture\n")
write("scripts/ci/no-docker.sh", "#!/bin/bash\n")
write("scripts/ci/tests/no-docker.test.sh", "#!/bin/bash\n")


def classify(text):
    return order.isolated(root, {"text": text})


# --- recognised: the wrapper around a command that is already isolated
for text in (f"{W} {ISO}", f"{W} scripts/ci/no-docker.sh", f"{W} scripts/ci/tests/no-docker.test.sh"):
    iso, mixed, missing = classify(text)
    check(iso and not mixed and not missing, f"isolated: {text}")
check(classify(f"{W} {ISO}\n{W} {ISO}")[0], "isolated: two wrapped suites on separate lines")
check(classify(ISO)[0], f"the unwrapped form stays recognised: {ISO}")

# --- not recognised: everything else that names the wrapper
for text in (
    f"{W} docker",
    f"{W} docker ps",
    f"{W} docker system df",
    f"{W} make",
    f"{W} unknown-tool",
    f"{W} scripts/guard.sh",
    f"{W} scripts/missing.sh",
    f"{W} {ISO} extra-argument",
    f"{W} bash {ISO}",
    f"{W} bash -c 'docker ps'",
    f"{W} sh -c {ISO}",
    f"{W} env {ISO}",
    f"{W} exec {ISO}",
    f"{W} python3 {ISO}",
    f"{W} ./{ISO}",
    f"{W} ../{ISO}",
    f"{W} /{ISO}",
    f"{W} scripts/../{ISO}",
    f"{W} scripts/ci/fdnorm.py",
    f"{W} scripts/ci/fdnorm.py -- {ISO}",
    f"{W}  {ISO}",
    f"{W}\t{ISO}",
    f"{W} {ISO} &",
    f"{W} {ISO} & docker ps",
    f"{W} {ISO} >/dev/null",
    f"{W} {ISO}>/dev/null",
    f"{W} $(docker ps)",
    f"{W} `docker ps`",
    f"{W} $SUITE",
    f"{W} ${{SUITE}}.sh",
    f"{W} '{ISO}'",
    f'{W} "{ISO}"',
    f"{W} scripts/*.sh",
    f"python3 scripts/ci/fdnorm.py -- {ISO}",
    f"python3 -I -S scripts/ci/fdnorm.py -- {ISO}",
    f"python3 -Ic scripts/ci/fdnorm.py -- {ISO}",
    f"python -I scripts/ci/fdnorm.py -- {ISO}",
    f"/usr/bin/python3 -I scripts/ci/fdnorm.py -- {ISO}",
    f"FOO=1 {W} {ISO}",
    f"LD_PRELOAD=x {W} {ISO}",
    f"env {W} {ISO}",
    f"exec {W} {ISO}",
    f"sudo {W} {ISO}",
    f"python3 -I other/fdnorm.py -- {ISO}",
    f"python3 -I ./scripts/ci/fdnorm.py -- {ISO}",
    f"python3 -I scripts/ci/fd*.py -- {ISO}",
    f"python3 -I scripts/ci/fdnorm.py {ISO}",
    f"python3 -I scripts/ci/fdnorm.py - {ISO}",
    f"python3 -I scripts/ci/fdnorm.py --x -- {ISO}",
    f"scripts/ci/fdnorm.py -- {ISO}",
    "python3 -I scripts/ci/fdnorm.py --",
    "python3 -I scripts/ci/fdnorm.py",
):
    iso, _, _ = classify(text)
    check(not iso, f"not isolated: {text!r}")

# --- a wrapped suite next to any other command is mixed, never isolated
for text in (f"{W} {ISO}\ndocker ps", f"{W} {ISO}; docker ps", f"docker ps && {W} {ISO}", f"docker ps | {W} {ISO}",
             f"{W} {ISO}\n{W} docker"):
    iso, mixed, _ = classify(text)
    check(not iso and mixed, f"mixed: {text!r}")

# --- a make that cannot be resolved to a recipe is another command, not nothing
write("Makefile", f"iso:\n\t{ISO}\nother:\n\tdocker ps\n")
check(classify("make iso")[0], "isolated: a make target whose recipe is isolated")
for text in (f"{W} {ISO}; make nosuchtarget", f"{W} {ISO}; make -C x y", f"{W} {ISO}; make other", f"{W} {ISO}; FOO=1 make iso"):
    iso, mixed, _ = classify(text)
    check(not iso and mixed, f"mixed: {text!r}")

# --- the wrapper needs a path with a directory: execvp searches PATH for a bare name
write("bare.test.sh", "#!/bin/bash\n" + STANZA)
check(not classify(f"{W} bare.test.sh")[0], "not isolated: a bare script name in the wrapper")

# --- the whole workflow


def workflow(*guard_steps):
    def job(jid, name, steps):
        body = [f"  {jid}:", f"    name: {name}", "    runs-on: ubuntu-24.04", "    steps:"]
        for i, run in enumerate(steps):
            body += [f"      - name: Step {i}", f"        run: {run}"]
        return "\n".join(body)
    return ("name: CI\non:\n  pull_request:\njobs:\n" + job("guard", "Repository guard", guard_steps) + "\n"
            + job("devenv", "Dev environment", [f"{W} {ISO}"]) + "\n")


def run_order(*steps):
    wf = os.path.join(root, "wf.yml")
    with open(wf, "w") as f:
        f.write(workflow(*steps))
    return subprocess.run([sys.executable, "-I", path, root, wf], capture_output=True, text=True)


def run_text(text):
    wf = os.path.join(root, "wf.yml")
    with open(wf, "w") as f:
        f.write(text)
    return subprocess.run([sys.executable, "-I", path, root, wf], capture_output=True, text=True)


# Settings that change how an isolated step runs, though its run: line is exact.
GOOD_STEP = f"      - name: Suite\n        run: {W} {ISO}\n"
JOBS = ("  guard:\n    name: Repository guard\n{job}    runs-on: ubuntu-24.04\n    steps:\n" + "{step}"
        + "  devenv:\n    name: Dev environment\n    runs-on: ubuntu-24.04\n    steps:\n" + GOOD_STEP)
BASE = "name: CI\non:\n  pull_request:\n{top}jobs:\n" + JOBS
p = run_text(BASE.format(top="", job="", step=GOOD_STEP))
check(p.returncode == 0, f"the exact step with no extra keys passes (rc {p.returncode})")
p = run_text(BASE.format(top="", job="", step=GOOD_STEP + "        timeout-minutes: 5\n"))
check(p.returncode == 0, "timeout-minutes on an isolated step passes")
for label, kw in (
    ("step shell", {"step": GOOD_STEP + "        shell: bash -c 'docker ps; bash {0}'\n"}),
    ("step env", {"step": GOOD_STEP + "        env:\n          LD_PRELOAD: x\n"}),
    ("step working-directory", {"step": GOOD_STEP + "        working-directory: other\n"}),
    ("job env", {"job": "    env:\n      BASH_ENV: x\n", "step": GOOD_STEP}),
    ("job defaults", {"job": "    defaults:\n      run:\n        shell: bash -c 'docker ps; bash {0}'\n", "step": GOOD_STEP}),
    ("workflow env", {"top": "env:\n  BASH_ENV: x\n", "step": GOOD_STEP}),
    ("workflow defaults", {"top": "defaults:\n  run:\n    shell: sh\n", "step": GOOD_STEP}),
):
    p = run_text(BASE.format(**{"top": "", "job": "", **kw}))
    check(p.returncode != 0 and "changes how" in p.stdout, f"refused: {label} on an isolated step (rc {p.returncode})")


p = run_order("scripts/guard.sh", f"{W} {ISO}")
check(p.returncode == 0, f"a workflow with wrapped suites last passes (rc {p.returncode}): {p.stdout[-200:] if p.returncode else ''}")

p = run_order("scripts/guard.sh", ISO)
check(p.returncode != 0 and "does not start through" in p.stdout, "an isolated step that is not wrapped fails")

p = run_order(f"{W} {ISO}", "scripts/guard.sh")
check(p.returncode != 0 and "no step that is not isolated after" in p.stdout, "a step that is not isolated after a wrapped one fails")

p = run_order(f"{W} {ISO}", f"{W} docker")
check(p.returncode != 0 and "no step that is not isolated after" in p.stdout, "wrapped docker after a wrapped suite fails")

p = run_order("scripts/guard.sh", f"{W} docker")
check(p.returncode != 0, "a job whose only wrapped command is docker has no isolated step and fails")

p = run_order("scripts/guard.sh", f"{W} {ISO}; docker ps")
check(p.returncode != 0, "a wrapped suite mixed with docker fails")

# A failing first suite must fail the step, so a step runs exactly one suite.
for sep in ("||", "|", ";", "&&"):
    p = run_order("scripts/guard.sh", f"{W} {ISO} {sep} {W} {ISO}")
    check(p.returncode != 0 and "does not start through" in p.stdout, f"two wrapped suites joined by {sep} fail")

os.rename(os.path.join(root, "scripts/ci/fdnorm.py"), os.path.join(root, "scripts/ci/fdnorm.gone"))
p = run_order("scripts/guard.sh", f"{W} {ISO}")
check(p.returncode != 0 and "wrapper" in p.stdout, "a wrapper that does not exist fails")
os.rename(os.path.join(root, "scripts/ci/fdnorm.gone"), os.path.join(root, "scripts/ci/fdnorm.py"))

# --- spellings GitHub reads and a line reader may not (FCRM-PARADEV-005)
GATE = "      - name: Gate\n        run: scripts/guard.sh\n"
SAFE = BASE.format(top="", job="", step=GATE + GOOD_STEP)
p = run_text(SAFE)
check(p.returncode == 0, f"a gate before the suites passes (rc {p.returncode})")


def refused(label, text):
    p = run_text(text)
    check(p.returncode == 1 and "FAIL" in p.stdout and "Traceback" not in p.stderr, f"refused: {label} (rc {p.returncode})")


def good(top="", job="", step=None, tail=""):
    return BASE.format(top=top, job=job, step=GATE + GOOD_STEP if step is None else step) + tail


# Hidden or malformed steps.
refused("a bare dash hides a later step", good(tail="        timeout-minutes: 5\n      -\n          run: docker ps\n"))
refused("a bare dash with a later key", good(tail="      -\n        run: docker ps\n"))
refused("two spaces after the dash", good(tail="      -  run: docker ps\n"))
refused("a step at another indent", good(tail="       - run: docker ps\n"))
refused("a list item that is not a mapping", good(tail="      - docker ps\n"))
refused("a nested list in a step", good(tail="        - run: docker ps\n"))
refused("steps in a flow list", SAFE.replace("    steps:\n", "    steps: [{run: docker ps}]\n    x:\n", 1))
refused("a job in a flow mapping", good(tail="  hidden: {runs-on: ubuntu-24.04, steps: [{run: docker ps}]}\n"))
refused("a job with steps at the indent of the key", good(tail="  other:\n    runs-on: ubuntu-24.04\n    steps:\n    - run: docker ps\n"))
refused("a decoy step in a multi-line concurrency", good(tail="  other:\n    runs-on: ubuntu-24.04\n    concurrency: |\n      - run: " + f"{W} {ISO}\n    steps:\n    - run: docker ps\n"))
refused("a tab in the indent", good(tail="\t- run: docker ps\n"))
refused("a job without steps", good(tail="  other:\n    runs-on: ubuntu-24.04\n"))
# Run blocks read differently.
for label, run in (
    ("a comment line first in a folded run", f">-\n          #\n          {W} {ISO}"),
    ("a comment line first in a literal run", f"|\n          # {W} {ISO}\n          {W} {ISO}"),
    ("a comment line after a folded run", f">-\n          {W} {ISO}\n          #"),
    ("a keep block indicator", f"|+\n          {W} {ISO}"),
    ("an indent indicator", f">2\n          {W} {ISO}"),
    ("an alias", "*suite"),
    ("an anchor", f"&suite {W} {ISO}"),
    ("a tag", f"!!str {W} {ISO}"),
    ("a double-quoted value with an escape", f'"{W} {ISO}\\n"'),
    ("a multi-line plain value", f"{W} {ISO}\n          docker ps"),
    ("a null run", "~"),
    ("a mapping run", f"{{a: b}}"),
):
    refused(label, good(step=f"      - name: Suite\n        run: {run}\n"))
refused("a run that is only a comment", good(step=f"      - name: Gate\n        run: '# nothing'\n      - name: Suite\n        run: >-\n          #\n          {W} {ISO}\n"))
# Other ways to write a key.
for key in ("env :", '"env":', "'env':", "env\t:", "? env", "<<: *x", "&a env:", "!!str env:"):
    refused(f"workflow key {key!r}", good(top=key + "\n  BASH_ENV: x\n"))
    refused(f"job key {key!r}", good(job="    " + key + "\n      BASH_ENV: x\n"))
for key in ("defaults :", '"defaults":'):
    refused(f"workflow key {key!r}", good(top=key + "\n  run:\n    shell: sh\n"))
refused("step key 'shell :'", good(step=GOOD_STEP + "        shell : sh\n"))
refused('step key "run":', good(step=f'      - name: Suite\n        "run": {W} {ISO}\n'))
refused("a duplicate run key", good(step=GOOD_STEP + "        run: docker ps\n"))
refused("a duplicate job key", good(tail="  guard:\n    runs-on: ubuntu-24.04\n    steps:\n" + GOOD_STEP))
refused("a duplicate workflow key", good(top="name: other\n"))
refused("a document marker", "---\n" + good())
refused("a second document", good() + "---\nname: x\n")
refused("a directive", "%YAML 1.1\n" + good())
for ch, label in (("\x85", "NEL"), ("\u2028", "LINE SEPARATOR"), ("\r", "CR"), ("\x0c", "FF")):
    refused(f"a {label} character", good().replace("name: CI", f"name: CI{ch}jobs:", 1))
# The gates and required jobs cannot be switched off.
for key in ("continue-on-error : true", '"continue-on-error": true', "continue-on-error: true", "if : false", '"if": false', "if: false"):
    refused(f"gate step {key!r}", good(step=f"      - name: Gate\n        {key}\n        run: scripts/guard.sh\n" + GOOD_STEP))
    refused(f"required job {key!r}", good(job=f"    {key}\n"))
refused("a required job with needs", good(job="    needs: other\n"))
refused("a required job that is a reusable workflow", good(job="    uses: x/y/.github/workflows/z.yml@main\n"))
refused("a required job with a matrix", good(job="    strategy:\n      matrix:\n        a: [b]\n"))
refused("a required job in a container", good(job="    container: img\n"))
refused("a required job on a computed runner", good().replace("runs-on: ubuntu-24.04", "runs-on: ${{ vars.x }}", 1))
refused("a required job twice", good(tail="  again:\n    name: Dev environment\n    runs-on: ubuntu-24.04\n    steps:\n" + GOOD_STEP))
refused("a workflow not run for pull requests", good().replace("  pull_request:\n", "  push:\n", 1))
refused("a path filter", good().replace("  pull_request:\n", "  pull_request:\n    paths:\n      - docs/x\n", 1))
refused("branches-ignore", good().replace("  pull_request:\n", "  pull_request:\n    branches-ignore: [main]\n", 1))
refused("branches without main", good().replace("  pull_request:\n", "  pull_request:\n    branches: [other]\n", 1))
refused("another trigger", good().replace("  pull_request:\n", "  pull_request:\n  workflow_dispatch:\n", 1))
refused("an unknown workflow key", good(top="x-note: y\n"))
refused("branches as a word that contains main", good().replace("  pull_request:\n", "  pull_request:\n    branches: domain\n", 1))
refused("branches as the word main", good().replace("  pull_request:\n", "  pull_request:\n    branches: main\n", 1))
for ch, label in (("\xa0", "NO-BREAK SPACE"), ("\u2003", "EM SPACE"), ("\u200b", "ZERO WIDTH SPACE"), ("\u3000", "IDEOGRAPHIC SPACE"), ("\u205f", "MATHEMATICAL SPACE")):
    refused(f"a {label} at the end of a quoted run", good(step=f'      - name: Suite\n        run: "{W} {ISO}{ch}"\n'))
    refused(f"a {label} at the end of a plain run", good(step=f"      - name: Suite\n        run: {W} {ISO}{ch}\n"))
refused("a step with neither run nor uses", good(step="      - name: Nothing\n" + GOOD_STEP))
refused("a step with both run and uses", good(step="      - name: Both\n        uses: a/b@" + "0" * 40 + "\n        run: scripts/guard.sh\n" + GOOD_STEP))
CHECKOUT_STEP = "      - name: Checkout\n        uses: actions/checkout@" + "0" * 40 + "\n        with:\n          persist-credentials: false\n"
p = run_text(good(step=CHECKOUT_STEP + GOOD_STEP))
check(p.returncode == 0, f"the pinned checkout passes (rc {p.returncode})")
refused("an action that is not pinned", good(step="      - name: Mutable\n        uses: actions/checkout@main\n        with:\n          persist-credentials: false\n" + GOOD_STEP))
refused("another action, though pinned", good(step="      - name: Other\n        uses: actions/github-script@" + "0" * 40 + "\n        with:\n          persist-credentials: false\n" + GOOD_STEP))
refused("an action that exports BASH_ENV", good(step="      - name: Seed\n        uses: actions/github-script@" + "0" * 40 + "\n        with:\n          script: |\n            core.exportVariable('BASH_ENV', '/tmp/x');\n" + GOOD_STEP))
refused("a checkout that keeps credentials", good(step=CHECKOUT_STEP.replace("false", "true") + GOOD_STEP))
refused("a checkout of another ref", good(step=CHECKOUT_STEP + "          ref: other\n" + GOOD_STEP))
refused("a checkout without with", good(step="      - name: Checkout\n        uses: actions/checkout@" + "0" * 40 + "\n" + GOOD_STEP))
refused("with on a run step", good(step="      - name: Run\n        run: scripts/guard.sh\n        with:\n          a: b\n" + GOOD_STEP))
refused("a gate step with env", good(step="      - name: Gate\n        env:\n          X: y\n        run: scripts/guard.sh\n" + GOOD_STEP))
# Settings written for later steps.
for text in ('echo "BASH_ENV=$PWD/x" >> "$GITHUB_ENV"', 'echo x >> "$GITHUB_PATH"', "echo x >> ${GITHUB_ENV}", 'echo x >> "$GITHUB_"ENV',
             "echo x >> $GITHUB_\\ENV", "echo ::add-path::x", "echo ::set-env name=a::b", "tee -a $GITHUB_PATH"):
    refused(f"a step that runs {text!r}", good(step=f"      - name: Seed\n        run: {text}\n" + GOOD_STEP))
refused("a line continuation in the name", good(step='      - name: Seed\n        run: |\n          printf x >> "$GITHUB_EN\\\n          V"\n' + GOOD_STEP))
refused("an expression that builds the name", good(step='      - name: Seed\n        run: |\n          printf x >> "$${{ \'GITHUB\' }}_ENV"\n' + GOOD_STEP))
refused("an expression in a step", good(step="      - name: Seed\n        run: echo ${{ github.ref }}\n" + GOOD_STEP))
refused("GITHUB_ENV in a folded step", good(step="      - name: Seed\n        run: >-\n          echo x\n          >> $GITHUB_ENV\n" + GOOD_STEP))
write("scripts/seed.sh", '#!/bin/bash\necho "BASH_ENV=x" >>"$GITHUB_ENV"\n')
refused("a script that writes GITHUB_ENV", good(step="      - name: Seed\n        run: scripts/seed.sh\n" + GOOD_STEP))
write("Makefile", "iso:\n\tscripts/iso.test.sh\nother:\n\tdocker ps\nseed:\n\tscripts/seed.sh\n")
refused("a make target that writes GITHUB_ENV", good(step="      - name: Seed\n        run: make seed\n" + GOOD_STEP))

# A script is isolated only if nothing runs before its stanza.
write("scripts/late.test.sh", "#!/bin/bash\ndocker ps\n" + STANZA)
check(not classify(f"{W} scripts/late.test.sh")[0], "not isolated: a command before the stanza")
refused("a script with code before its stanza, as an ordinary step", good(step="      - name: Late\n        run: scripts/late.test.sh\n" + GOOD_STEP))
write("scripts/first.test.sh", '#!/bin/bash\n# Comment.\nset -u\n\nhere=$(cd "$(dirname "$0")" && pwd)\n# Comment.\n' + STANZA)
check(classify(f"{W} scripts/first.test.sh")[0], "isolated: only set, here and comments before the stanza")
write("scripts/first-p.test.sh", '#!/bin/bash\nhere=$(cd -P "$(dirname "$0")" && pwd -P)\n' + STANZA)
check(classify(f"{W} scripts/first-p.test.sh")[0], "isolated: the -P form of here")
write("scripts/assign.test.sh", '#!/bin/bash\nhere=$(docker ps)\n' + STANZA)
check(not classify(f"{W} scripts/assign.test.sh")[0], "not isolated: another assignment of here")

# Harmless spellings of this subset still read.
p = run_text(good(top="# A comment.\n\n", job="    # A comment.\n    timeout-minutes: 10\n",
                  step="      # A comment.\n      - name: Checkout\n        uses: actions/checkout@" + "0" * 40 + " # v1\n        with:\n          persist-credentials: false\n"
                       + "      - name: Folded\n        run: >-\n          scripts/guard.sh\n          --flag\n"
                       + "      - name: Literal\n        run: |\n          scripts/guard.sh\n\n          # Not a suite.\n          scripts/guard.sh\n"
                       + "      - name: 'Quoted name'\n        run: scripts/guard.sh\n" + GOOD_STEP))
check(p.returncode == 0, f"comments, folded and literal runs, and quoted names read (rc {p.returncode}) {p.stdout[-300:] if p.returncode else ''}")
tree = order.load_workflow("a:\n  b: 'c'\n  d: \"e\"\n  f: [g, h]\n  i: j # k\n  l: |\n    m\n      n\n\n    # o\n  p: >-\n    q\n    r\n  s:\n    - t: u\n      v: w\n    - x: y\n  z:\n")
check(tree == {"a": {"b": "c", "d": "e", "f": ["g", "h"], "i": "j", "l": "m\n  n\n\n# o", "p": "q r", "s": [{"t": "u", "v": "w"}, {"x": "y"}], "z": None}},
      "the subset reads to the tree YAML gives")

# --- the six suites of the real workflow
real = tempfile.mkdtemp(prefix="order-real.")
for rel in sum(order.SUITES.values(), []) + ["scripts/ci/no-docker.sh", "scripts/ci/fdnorm.py"]:
    full = os.path.join(real, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write("#!/bin/bash\n" + STANZA)
wfdir = os.path.join(real, ".github/workflows")
os.makedirs(wfdir)


def real_workflow(guard, devenv):
    def steps(paths):
        return "".join(f"      - name: Step {i}\n        run: {W} {path}\n" for i, path in enumerate(paths))
    return ("name: CI\non:\n  pull_request:\njobs:\n  guard:\n    name: Repository guard\n    runs-on: ubuntu-24.04\n    steps:\n" + steps(guard)
            + "  devenv:\n    name: Dev environment\n    runs-on: ubuntu-24.04\n    steps:\n" + steps(devenv))


def run_real(guard, devenv):
    with open(os.path.join(wfdir, "ci.yml"), "w") as f:
        f.write(real_workflow(guard, devenv))
    return subprocess.run([sys.executable, "-I", path, real], capture_output=True, text=True)


G, U = order.SUITES["Repository guard"], order.SUITES["Dev environment"]
check(len(G) + len(U) == 6, "six suites are listed")
p = run_real(G, U)
check(p.returncode == 0, f"the six suites in order pass (rc {p.returncode}) {p.stdout[-200:] if p.returncode else ''}")
for label, guard, devenv in (
    ("a suite left out", G[:-1], U),
    ("the last suite left out", G, []),
    ("suites in another order", G[::-1], U),
    ("a suite twice", G + G[-1:], U),
    ("a suite in the other job", G[1:], U + G[:1]),
):
    p = run_real(guard, devenv)
    check(p.returncode == 1, f"refused: {label} (rc {p.returncode})")

# --- the real workflow reads the same here and in PyYAML, where that exists
repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(path))))
real_ci = os.path.join(repo, ".github/workflows/ci.yml")
try:
    import yaml
except ImportError:
    yaml = None
if yaml is None or not os.path.isfile(real_ci):
    print("skip the comparison with PyYAML: PyYAML or the real workflow is not available")
else:
    def text_tree(node):
        if isinstance(node, dict):
            return {("on" if k is True else str(k)): text_tree(v) for k, v in node.items()}
        if isinstance(node, list):
            return [text_tree(v) for v in node]
        if node is None:
            return None
        return str(node).lower() if isinstance(node, bool) else str(node)
    with open(real_ci) as f:
        text = f.read()
    mine = order.load_workflow(text)
    theirs = text_tree(yaml.safe_load(text))
    # YAML keeps the trailing line break of a literal block; the shell does not care.
    def trimmed(node):
        if isinstance(node, dict):
            return {k: trimmed(v) for k, v in node.items()}
        if isinstance(node, list):
            return [trimmed(v) for v in node]
        return node.rstrip("\n") if isinstance(node, str) else node
    check(trimmed(mine) == trimmed(theirs), "the real ci.yml reads the same as in PyYAML")

print(f"SUMMARY {passed} ok, {failed} failed")
sys.exit(0 if failed == 0 else 1)
