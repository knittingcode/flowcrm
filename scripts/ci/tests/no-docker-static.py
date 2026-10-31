"""Static rules of the Linux test isolation (T-39 of no-docker.test.sh).

Usage: python3 -I -B no-docker-static.py <repository root>

Each rule is checked twice: on the tracked files of the repository, which
must pass, and on the same files with a mutant fixture applied, which must
fail. The fixtures are strings in this file, never files of the
repository. Two more lines check the AppArmor templates themselves. Each
check prints "ok   <rule> <text>" or "FAIL <rule> <text>"; the last line is
"SUMMARY <ok> ok, <failed> failed". Exit 0 only if nothing failed.

  S-02   no code reloads, replaces or removes AppArmor policy, changes its
         mode or writes its configuration (apparmor_parser -r/-R, aa-teardown
         and the like, a restart of the service, writes to /etc/apparmor.d or
         /sys/module/apparmor/parameters);
  S-02b  attach_disconnected appears only in the negative-control template
         and the files that check it;
  S-03b  no sudo -E or --preserve-env anywhere; in no-docker.test.sh sudo
         runs only the reviewed test commands;
  S-05   the AppArmor templates are exactly the reviewed rule set (RULES
         below), the negative-control one differing only by
         attach_disconnected.

Code means every tracked file except Markdown; lines that are comments
(#, //, /* or *) are not code either.
"""

import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True

SELF = "scripts/ci/tests/no-docker-static.py"
TEST = "scripts/ci/tests/no-docker.test.sh"
AA = "scripts/ci/no-docker-aa.py"
AA_UNIT = "scripts/ci/tests/no-docker-aa-unit.py"
TEMPLATE = "scripts/ci/no-docker/apparmor.profile"
NEGATIVE = "scripts/ci/tests/no-docker/apparmor-negative.profile"

results = {"ok": 0, "fail": 0}


def emit(tag, good, text):
    results["ok" if good else "fail"] += 1
    print(f"{'ok  ' if good else 'FAIL'} {tag} {text}")


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


def read_repo(root):
    """{path: text} of every tracked regular file (text decoded leniently)."""
    files = {}
    for p in tracked(root):
        full = os.path.join(root, p)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        with open(full, "rb") as f:
            files[p] = f.read().decode("utf-8", "replace")
    return files


def comment(line):
    s = line.lstrip()
    return s.startswith(("#", "//", "/*", "*"))


def code_lines(files, exempt=()):
    """(path, line number, line) of every code line outside exempt."""
    for p, text in sorted(files.items()):
        if p.endswith(".md") or p in exempt:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if not comment(line):
                yield p, n, line


# --- S-02 ---------------------------------------------------------------------

S02 = [
    re.compile(r"apparmor_parser\b[^\n]*[\s\"'](-[A-Za-z]*[rR][A-Za-z]*\b|--(replace|remove)\b)"),
    re.compile(r"\baa-(teardown|complain|enforce|disable)\b"),
    re.compile(r"\b(systemctl|service)\b[^\n]*\bapparmor\b"),
]
APPARMOR_CONFIG = re.compile(r"/etc/apparmor\.d|/sys/module/apparmor/parameters")
WRITE = re.compile(r">|\btee\b|\bcp\b|\bmv\b|\binstall\b|\bln\b|\brm\b|\bsed\s+-i|[\"'][wax]b?\+?[\"']|O_WRONLY|O_RDWR"
                   r"|O_CREAT|write_text|write_bytes")


def s02(files):
    found = []
    for p, n, line in code_lines(files, exempt=(SELF, AA_UNIT)):
        if any(r.search(line) for r in S02) or (APPARMOR_CONFIG.search(line) and WRITE.search(line)):
            found.append(f"{p}:{n}")
    return found


# --- S-02b --------------------------------------------------------------------

def s02b(files):
    return [f"{p}:{n}" for p, n, line in code_lines(files, exempt=(SELF, AA, AA_UNIT, NEGATIVE))
            if "attach_disconnected" in line]


# --- S-03b --------------------------------------------------------------------

PRESERVE = re.compile(r"\bsudo\b(\s+-[A-Za-z]+)*\s+-[A-Za-z]*E[A-Za-z]*\b|--preserve-env\b")
SUDO_USE = re.compile(r"(^|[\s;|&(`])sudo\s")
TEST_SUDO = [
    re.compile(r"sudo -n (mount|umount|kill|unshare)\s"),
    re.compile(r'sudo -n "\$nd"\s'),
    re.compile(r"sudo -n cat /sys/kernel/security/apparmor/profiles\b"),
    re.compile(r'sudo -n cat "?/proc/[^/\s]+/attr/apparmor/(current|exec)\b'),
    re.compile(r'sudo -n timeout [0-9]+ /usr/bin/python3 -I "?[^\s"]*/no-docker-aa\.py"? (load|release|diag)\s'),
]


def s03b(files):
    found = [f"{p}:{n}" for p, n, line in code_lines(files, exempt=(SELF,)) if PRESERVE.search(line)]
    for p, n, line in code_lines({TEST: files.get(TEST, "")}):
        for m in SUDO_USE.finditer(line):
            rest = line[m.end() - len("sudo") - 1:].lstrip()
            if not any(r.match(rest) for r in TEST_SUDO):
                found.append(f"{p}:{n}")
    return found


# --- S-05 ---------------------------------------------------------------------

RULES = ["file,", "unix,", "network,", "signal,", "ptrace (read, readby, trace, tracedby) peer=@NAME@,",
         "deny capability,", "deny mount,", "deny umount,", "deny pivot_root,", "deny network vsock,"]
FLAGS = {"production": "enforce", "negative": "enforce,attach_disconnected"}
FORBIDDEN = [
    (re.compile(r"\bcomplain\b"), "complain"),
    (re.compile(r"\bchange_profile\b"), "change_profile"),
    (re.compile(r"\buserns\b"), "userns"),
    (re.compile(r"(^|\s)#?include\b"), "include"),
    (re.compile(r"\b[pPcCuU]i?x\b|\bix\b"), "an exec transition"),
    (re.compile(r"\battach_disconnected\b"), "attach_disconnected"),
]


def normalised(text):
    return [re.sub(r"\s+", " ", line.strip()) for line in text.splitlines() if line.strip()]


def grammar(text, kind):
    """Findings of a template against the reviewed rule set; [] if exact."""
    want = ["abi <abi/4.0>,", f"profile @NAME@ flags=({FLAGS[kind]}) {{"] + RULES + ["}"]
    got = normalised(text)
    found = []
    if got != want:
        extra = [x for x in got if x not in want]
        missing = [x for x in want if x not in got]
        found.append(f"not the reviewed rule set (extra {extra}, missing {missing}"
                     + (", order differs" if not extra and not missing else "") + ")")
    for r, what in FORBIDDEN:
        if kind == "negative" and what == "attach_disconnected":
            continue
        if any(r.search(line) for line in got):
            found.append(what)
    return found


def s05(files):
    return [f"{TEMPLATE}: {x}" for x in grammar(files.get(TEMPLATE, ""), "production")] + \
           [f"{NEGATIVE}: {x}" for x in grammar(files.get(NEGATIVE, ""), "negative")]


# --- the rules and their mutant fixtures --------------------------------------

def add(path, text):
    return lambda files: dict(files, **{path: files.get(path, "") + text})


def edit(path, old, new):
    def change(files):
        if files.get(path, "").count(old) != 1:
            raise LookupError(f"the fixture for {path} does not match exactly once")
        return dict(files, **{path: files[path].replace(old, new)})
    return change


RULE_LIST = [
    ("S-02", "no AppArmor reload, replace, remove, mode change or configuration write", s02,
     add("scripts/ci/no-docker.sh", "\nsudo -n apparmor_parser -r -K -q \"$profile\"\n")),
    ("S-02b", "attach_disconnected only in the negative-control template", s02b,
     add(TEMPLATE, "  # flags=(attach_disconnected)\n  attach_disconnected,\n")),
    ("S-03b", "no sudo -E or --preserve-env; sudo in no-docker.test.sh only as reviewed", s03b,
     add(TEST, "\nsudo -n -E true\n")),
    ("S-05", "the templates are exactly the reviewed rule set", s05,
     edit(TEMPLATE, "  deny network vsock,\n", "")),
]


def check_rules(files):
    for tag, text, rule, mutate in RULE_LIST:
        found = rule(files)
        emit(tag, not found, f"repository: {text}" + (f" (violations: {', '.join(found)})" if found else ""))
        try:
            caught = rule(mutate(files))
        except LookupError as e:
            emit(tag, False, f"mutant fixture: {e}")
            continue
        emit(tag, bool(caught), f"mutant fixture is rejected ({', '.join(caught) or 'NOT rejected'})")


def check_templates(files):
    prod = files.get(TEMPLATE, "")
    neg = files.get(NEGATIVE, "")
    found = grammar(prod, "production")
    emit("S-05", not found and "@NAME@" in prod and "attach_disconnected" not in prod,
         f"template: {TEMPLATE} is the production rule set with flags=(enforce) ({found or 'exact'})")
    as_production = grammar(neg, "production")
    emit("S-05", grammar(neg, "negative") == [] and len(as_production) == 2
         and as_production[1] == "attach_disconnected"
         and normalised(neg.replace("flags=(enforce,attach_disconnected)", "flags=(enforce)")) == normalised(prod),
         f"template: {NEGATIVE} differs from the production template only by attach_disconnected ({as_production})")


def main():
    files = read_repo(os.path.abspath(sys.argv[1]))
    check_rules(files)
    check_templates(files)
    print(f"SUMMARY {results['ok']} ok, {results['fail']} failed")
    return 0 if results["fail"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
