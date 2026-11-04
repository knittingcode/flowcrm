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

# --- the whole workflow


def workflow(*guard_steps):
    def job(jid, name, steps):
        body = [f"  {jid}:", f"    name: {name}", "    runs-on: ubuntu-24.04", "    steps:"]
        for i, run in enumerate(steps):
            body += [f"      - name: Step {i}", f"        run: {run}"]
        return "\n".join(body)
    return ("name: CI\non:\n  push:\njobs:\n" + job("guard", "Repository guard", guard_steps) + "\n"
            + job("devenv", "Dev environment", [f"{W} {ISO}"]) + "\n")


def run_order(*steps):
    wf = os.path.join(root, "wf.yml")
    with open(wf, "w") as f:
        f.write(workflow(*steps))
    return subprocess.run([sys.executable, "-I", path, root, wf], capture_output=True, text=True)


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

os.rename(os.path.join(root, "scripts/ci/fdnorm.py"), os.path.join(root, "scripts/ci/fdnorm.gone"))
p = run_order("scripts/guard.sh", f"{W} {ISO}")
check(p.returncode != 0 and "wrapper" in p.stdout, "a wrapper that does not exist fails")
os.rename(os.path.join(root, "scripts/ci/fdnorm.gone"), os.path.join(root, "scripts/ci/fdnorm.py"))

print(f"SUMMARY {passed} ok, {failed} failed")
sys.exit(0 if failed == 0 else 1)
