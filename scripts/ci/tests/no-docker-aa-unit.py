"""Pure tests of scripts/ci/no-docker-aa.py (T-38 of no-docker.test.sh).

Usage: python3 -I -B no-docker-aa-unit.py <path of no-docker-aa.py>

The helper's source and the two AppArmor templates are read once, then
every call that would open, list, read or write a file, read a link, run a
program, open a pidfd or send a signal is replaced by one that raises: the
operations run against a fake System and a fake control directory only,
never against this machine. Each assertion prints "ok   <case> <text>" or
"FAIL <case> <text>"; the cases are P-01 to P-11, W (the helper calls the
tested functions) and M1 to M17 (mutated copies of the helper, each of
which must fail at least one assertion of its case). The last line is
"SUMMARY <ok> ok, <failed> failed". Exit 0 only if nothing failed; 2 if a
mutant cannot be made exactly.
"""

import ast
import builtins
import errno
import hashlib
import os
import signal
import socket
import subprocess
import sys

sys.dont_write_bytecode = True
SOURCE_PATH = sys.argv[1]
with open(SOURCE_PATH) as f:
    SOURCE = f.read()
HERE = os.path.dirname(os.path.abspath(SOURCE_PATH))
with open(os.path.join(HERE, "no-docker", "apparmor.profile"), "rb") as f:
    PROD_BYTES = f.read()
with open(os.path.join(HERE, "tests", "no-docker", "apparmor-negative.profile"), "rb") as f:
    NEG_BYTES = f.read()


def load(src):
    ns = {"__name__": "aa_under_test", "__file__": SOURCE_PATH}
    exec(compile(src, SOURCE_PATH, "exec"), ns)
    ns["say"] = lambda text: None  # the helper's messages are not results
    return ns


class IOAttempt(AssertionError):
    pass


def tripwire(name):
    def raiser(*args, **kwargs):
        raise IOAttempt(f"{name} called in a pure test")
    return raiser


for mod, names in ((os, ("open", "listdir", "readlink", "stat", "lstat", "fstat", "scandir", "walk", "write",
                         "read", "link", "rename", "unlink", "fsync", "fchmod", "pidfd_open", "kill", "fork",
                         "pipe", "waitpid", "setns")),
                   (signal, ("pidfd_send_signal", "signal")),
                   (socket, ("socket", "socketpair")),
                   (subprocess, ("run", "Popen", "check_output", "call"))):
    for name in names:
        if hasattr(mod, name):
            setattr(mod, name, tripwire(f"{mod.__name__}.{name}"))
builtins.open = tripwire("open")

A = load(SOURCE)
NAME = "flowcrm-nd-" + "0123456789abcdef" * 2
NEGNAME = "flowcrm-nd-neg-" + "fedcba9876543210" * 2
HOST = 4026531836
NSINO = 4026532269
HASH = "a" * 64
results = {"ok": 0, "fail": 0}


def emit(tag, good, text):
    results["ok" if good else "fail"] += 1
    print(f"{'ok  ' if good else 'FAIL'} {tag} {text}")


# --- fakes -------------------------------------------------------------------

def rec(text, uid=0, mode=0o444, regular=True):
    return {"uid": uid, "mode": mode, "regular": regular, "text": text}


class FakeCtl:
    def __init__(self, files=None, race=None):
        self.files = dict(files or {})
        self.race = race  # a record that appears as "ns" just before a link
        self.writes = []

    def lstat(self, name):
        return True if name in self.files else None

    def record(self, name):
        return self.files.get(name)

    def write_new(self, tmp, final, text, replace):
        self.writes.append((final, text))
        if final == "ns" and self.race is not None:
            self.files["ns"] = self.race
        if final in self.files and not replace:
            return False
        self.files[final] = rec(text)
        return True


def init_task(pid=900, state="Z (zombie)", threads="1", name="sh", ino=NSINO):
    return (pid, ino, {"Name": name, "State": state, "Threads": threads, "NSpid": f"{pid}\t1"})


class FakeSys:
    def __init__(self, listed=(("enforce",),), hash_now=HASH, tasks=None, sweeps=None, events=None):
        # The modes NAME is listed with, one entry per call (the last one
        # repeats); "unreadable" makes the list raise.
        self.lists = [x if x == "unreadable" else list(x) for x in listed]
        self.hash_now = hash_now
        self.tasks = [init_task()] if tasks is None else tasks
        self.sweeps = sweeps if sweeps is not None else [[("/proc/1/task/1/attr/apparmor/current", "unconfined\n")]]
        self.calls = events if events is not None else []
        self.removed = []
        self.added = []
        self.procs = {}
        self.start = {}
        self.inodes = {}

    def profile_list(self):
        self.calls.append("list")
        modes = self.lists[0] if len(self.lists) == 1 else self.lists.pop(0)
        if modes == "unreadable":
            raise OSError(errno.EACCES, "denied")
        return "".join(f"{NAME} ({m})\n" for m in modes) + "foreign (enforce)\n"

    def kernel_hash(self, name):
        return self.hash_now

    def host_pidns(self):
        return HOST

    def pidns_tasks(self):
        self.calls.append("p1")
        return self.tasks

    def label_sweep(self):
        self.calls.append("sweep")
        return self.sweeps[0] if len(self.sweeps) == 1 else self.sweeps.pop(0)

    def remove(self, name):
        self.calls.append("remove")
        self.removed.append(name)
        self.lists = [[]]

    def template_bytes(self, path):
        return NEG_BYTES if path.endswith("apparmor-negative.profile") else PROD_BYTES

    def parser_add(self, text):
        self.added.append(text)
        self.lists = [["enforce"]]

    def process_table(self):
        return self.procs

    def pidfd_open(self, pid):
        self.calls.append(f"pidfd_open {pid}")
        return 77

    def start_time(self, pid):
        self.calls.append("start_time")
        return self.start.get(pid, 5000)

    def ns_inodes(self, pid):
        self.calls.append("ns_inodes")
        return self.inodes.get(pid, (NSINO, 4026532267))

    def pidfd_signal(self, fd, sig):
        self.calls.append(f"signal {int(sig)}")

    def close(self, fd):
        pass

    def sleep(self, s):
        pass

    def clock(self):
        return 0.0


def ok_ctl(state="entered spid=4242\n", ns=f"pid:{NSINO} mnt:4026532267\n", hash_=f"sha256 {HASH}\n"):
    files = {}
    if state is not None:
        files["state"] = rec(state, uid=1001, mode=0o600)
    if ns is not None:
        files["ns"] = rec(ns)
    if hash_ is not None:
        files["hash"] = rec(hash_)
    return FakeCtl(files)


def release(P, ctl, fs, name=NAME):
    """"released" (removed), "kept" (refused, nothing removed) or what else
    happened."""
    try:
        P["release"](name, ctl, fs)
        return "released" if fs.removed == [name] else "not removed"
    except P["Refused"] as e:
        return "kept" if not fs.removed else f"removed and refused ({e})"


# --- the cases ---------------------------------------------------------------

def p01(P, emit):
    ok = P["name_ok"]
    emit("P-01", ok("load", NAME) and ok("release", NAME), "a valid NAME is accepted by load and release")
    emit("P-01", ok("load-negative-control", NEGNAME) and ok("release", NEGNAME) and ok("diag", NEGNAME),
         "a valid NEGNAME is accepted by load-negative-control, release and diag")
    emit("P-01", not ok("load", NEGNAME), "rejected: NEGNAME by load")
    emit("P-01", not ok("load-negative-control", NAME), "rejected: NAME by load-negative-control")
    ops = ("load", "load-negative-control", "release", "diag")
    emit("P-01", not any(ok(o, NAME[:-1]) or ok(o, NEGNAME[:-1]) for o in ops), "rejected: 31 hex digits")
    emit("P-01", not any(ok(o, NAME + "0") or ok(o, NEGNAME + "0") for o in ops), "rejected: 33 hex digits")
    emit("P-01", not any(ok(o, NAME.upper()) or ok(o, NAME[:-1] + "A") for o in ops), "rejected: upper case")
    bad = [NAME[:-2] + "/x", "../" + NAME, NAME + "\n", NAME + " x", "flowcrm-nd-" + "0" * 30 + "..", ""]
    emit("P-01", not any(ok(o, b) for o in ops for b in bad), "rejected: path characters, a newline, a space, empty")


def p02(P, emit):
    pl = P["parse_label"]
    emit("P-02", pl(f"{NAME} (enforce)") == (NAME, "enforce"), "enforce: the name and its mode")
    emit("P-02", pl(f"{NAME} (complain)") == (NAME, "complain"), "complain: the mode is complain")
    emit("P-02", pl(f"other//&{NAME} (enforce)")[0] != NAME, "a stacked label is not the profile itself")
    emit("P-02", pl("unconfined") == ("unconfined", None), "unconfined has no mode")
    emit("P-02", pl("") is None and pl("\n") is None, "an empty label is nothing")
    emit("P-02", pl(f"{NAME} (enforce)\n") == (NAME, "enforce"), "a trailing newline is ignored")
    emit("P-02", pl(f":ns:{NAME} (enforce)")[0] != NAME, "a namespace-prefixed label is not the profile itself")


def p03(P, emit):
    good = {"enabled": "Y", "mode": "enforce", "af_unix": True, "parser": True, "aa_exec": True}

    def passes(o):
        return all(p for p, _ in P["preflight_findings"](o))

    emit("P-03", passes(good), "enabled, enforce, af_unix and both tools pass")
    for text, change in (("AppArmor disabled", {"enabled": "N"}), ("enabled unreadable", {"enabled": None}),
                         ("global mode complain", {"mode": "complain"}), ("global mode unreadable", {"mode": None}),
                         ("no af_unix class", {"af_unix": False}), ("af_unix unreadable", {"af_unix": None}),
                         ("apparmor_parser missing", {"parser": False}), ("aa-exec missing", {"aa_exec": False}),
                         ("a tool unreadable", {"parser": None})):
        emit("P-03", not passes(dict(good, **change)), f"rejected: {text}")
    emit("P-03", passes(dict(good, restrict_unconfined="1", restrict_userns="1")),
         "the sysctl values are recorded, not gating")
    emit("P-03", not passes({}), "rejected: an empty observation")
    af = P["af_unix_feature"]
    emit("P-03", af("file", "yes\n") and af("dir", "") and not af("file", "no\n") and not af("other", "")
         and not af("missing", ""), "af_unix: a file reading yes or a directory counts; anything else does not")


def p04(P, emit):
    lm = P["listed_modes"]
    emit("P-04", lm(f"x (enforce)\n{NAME} (enforce)\n", NAME) == ["enforce"], "listed once in enforce mode")
    emit("P-04", lm(f"{NAME} (enforce)\n{NAME} (enforce)\n", NAME) == ["enforce", "enforce"], "listed twice: both seen")
    emit("P-04", lm(f"{NAME} (complain)\n", NAME) == ["complain"], "listed in complain mode")
    fs = FakeSys(listed=(("enforce",),))
    try:
        P["load"]("load", NAME, FakeCtl(), fs)
        refused = False
    except P["Refused"]:
        refused = True
    fs2 = FakeSys(listed=((),))
    P["load"]("load", NAME, FakeCtl(), fs2)
    emit("P-04", lm("x (enforce)\n", NAME) == [] and refused and not fs.added and len(fs2.added) == 1,
         "absent: loaded only then; a NAME listed already is never loaded again")
    fs = FakeSys(listed=("unreadable",))
    try:
        r = release(P, ok_ctl(), fs)
    except OSError:
        r = "error"
    emit("P-04", r == "error" and not fs.removed, "an unreadable list is an error, nothing is removed")
    emit("P-04", lm(f"{NAME}0 (enforce)\nx{NAME} (enforce)\n", NAME) == [], "similar foreign names are not the profile")


def p05(P, emit):
    sr = P["sweep_result"]
    lab = "/proc/9/task/9/attr/apparmor/current"
    emit("P-05", sr([(lab, f"{NAME} (enforce)\n")], NAME)[0] == [lab], "a task carrying the profile is counted")
    emit("P-05", sr([(lab, f"other//&{NAME} (enforce)\n")], NAME)[0] == [lab], "a stacked label is counted")
    emit("P-05", sr([(lab, f":ns://{NAME} (enforce)\n")], NAME)[0] == [lab], "a prefixed label is counted")
    emit("P-05", sr([(lab, f"{NAME}ff (enforce)\n")], NAME)[0] == [lab], "a longer name containing it is counted")
    emit("P-05", sr([(lab, OSError(errno.ENOENT, "x")), (lab, OSError(errno.ESRCH, "x"))], NAME) == ([], []),
         "a task that ended (ENOENT, ESRCH) is skipped")
    emit("P-05", sr([(lab, OSError(errno.EACCES, "x"))], NAME)[1] != [], "an unreadable label (EACCES) is unknown")
    emit("P-05", sr([(lab, OSError(errno.EINVAL, "x"))], NAME)[1] != [], "an unreadable label (EINVAL) is unknown")
    seq = [[(lab, "unconfined\n")], [(lab, f"{NAME} (enforce)\n")]]
    emit("P-05", P["sweeps_clear"](lambda: seq.pop(0), NAME) is not None, "two sweeps are required: a carrier in the second keeps it")
    emit("P-05", P["sweeps_clear"](lambda: [(lab, "unconfined\n")], NAME) is None, "two clear sweeps pass")


def p06(P, emit):
    def case(text, want, ctl=None, fs=None, p1_called=None):
        fs = fs or FakeSys()
        r = release(P, ctl or ok_ctl(), fs)
        good = r == want and (p1_called is None or ("p1" in fs.calls) == p1_called)
        emit("P-06", good, f"{text}: {r}")

    case("init alive", "kept", fs=FakeSys(tasks=[init_task(state="S (sleeping)")]))
    case("init a single-threaded zombie", "released")
    case("no task in the namespace", "released", fs=FakeSys(tasks=[]))
    case("state loading, no namespace recorded: no P1", "released", ctl=ok_ctl(state="loading\n", ns=None), p1_called=False)
    case("state entering, namespace record missing", "kept", ctl=ok_ctl(state="entering\n", ns=None))
    ctl = ok_ctl()
    ctl.files["ns"] = rec(f"pid:{NSINO} mnt:1\n", uid=1001)
    case("namespace record not root-owned", "kept", ctl=ctl)
    case("namespace record unparsable", "kept", ctl=ok_ctl(ns="pid:x\n"))
    case("another task in the namespace", "kept", fs=FakeSys(tasks=[init_task(), (901, NSINO, {"Name": "sleep", "State": "S", "Threads": "1", "NSpid": "901\t7"})]))
    case("the task scan unreadable (EACCES)", "kept", fs=FakeSys(tasks=[(5, OSError(errno.EACCES, "x"), None)]))
    case("state missing or unknown: treated as entered", "kept", ctl=ok_ctl(state="garbage\n", ns=None))
    case("namespace record naming the host's namespace", "kept", ctl=ok_ctl(ns=f"pid:{HOST} mnt:1\n"))
    case("state loading with a namespace recorded: treated as entered", "kept",
         fs=FakeSys(tasks=[init_task(state="S (sleeping)")]), ctl=ok_ctl(state="loading\n"), p1_called=True)
    fs = FakeSys(tasks=[init_task(state="S (sleeping)")])
    a = release(P, ok_ctl(state="not-forked\n", ns=None), FakeSys())
    b = release(P, ok_ctl(state="not-forked\n"), fs)
    emit("P-06", a == "released" and b == "kept" and "p1" in fs.calls,
         f"state not-forked: released without P1 only when no namespace is recorded ({a}, {b})")
    # IC-1: the namespace record's format.
    case("a record whose mount namespace is unknown (mnt:-)", "released", ctl=ok_ctl(ns=f"pid:{NSINO} mnt:-\n"))
    bad = ["pid:0 mnt:1\n", "pid:-1 mnt:1\n", f"pid:{NSINO} mnt:1", f"pid:{NSINO} mnt:1\n\n", f"pid:0{NSINO} mnt:1\n",
           f"pid:{NSINO}  mnt:1\n", f"mnt:1 pid:{NSINO}\n", f"pid:{NSINO} mnt:1 x\n", f"pid:{NSINO}\n",
           f"pid:{NSINO} mnt:\n", "pid:1e3 mnt:1\n", f"pid:{NSINO} mnt:-1\n", f"pid:+{NSINO} mnt:1\n",
           "pid:99999999999999999999 mnt:1\n", f" pid:{NSINO} mnt:1\n", ""]
    rejected = 0
    for text in bad:
        fs = FakeSys(tasks=[])
        if release(P, ok_ctl(ns=text), fs) == "kept" and P["p0"](rec(text), HOST) is not None:
            rejected += 1
    emit("P-06", rejected == len(bad), f"malformed namespace records are refused ({rejected} of {len(bad)} variants)")


def p07(P, emit):
    rd, R = P["render"], P["Refused"]
    sha = hashlib.sha256(PROD_BYTES).hexdigest()

    def refused(data, kind="production"):
        try:
            rd(data, kind, hashlib.sha256(data).hexdigest(), NAME)
            return False
        except R:
            return True

    try:
        rd(PROD_BYTES + b"\n", "production", sha, NAME)
        mismatch = False
    except R:
        mismatch = True
    emit("P-07", mismatch, "rejected: template bytes that differ from the pinned sha256")
    text = rd(PROD_BYTES, "production", sha, NAME)
    emit("P-07", "@" not in text and text.count(NAME) == 2, "every @NAME@ is replaced (profile name and ptrace peer)")
    emit("P-07", "  unix,\n" in text and not refused(PROD_BYTES), "the unix rule is accepted (not an exec mode)")
    emit("P-07", refused(PROD_BYTES.replace(b"  file,\n", b"  file,\n  /usr/bin/** px,\n")), "rejected: an exec transition")
    emit("P-07", refused(PROD_BYTES.replace(b"flags=(enforce)", b"flags=(enforce,attach_disconnected)")),
         "rejected: attach_disconnected in the production template")
    emit("P-07", refused(PROD_BYTES.replace(b"  signal,\n", b"  signal,\n  change_profile,\n")), "rejected: change_profile")


def p08(P, emit):
    tf, R = P["template_for"], P["Refused"]

    def kind(op, name):
        try:
            return tf(op, name)[0]
        except R:
            return "refused"

    emit("P-08", kind("load-negative-control", NEGNAME) == "negative", "load-negative-control loads the negative template")
    emit("P-08", kind("load", NAME) == "production" and kind("load", NEGNAME) == "refused",
         "load never loads the negative template")
    emit("P-08", kind("load-negative-control", NAME) == "refused", "the negative template needs NEGNAME")
    fs = FakeSys(listed=((),))
    P["load"]("load", NAME, FakeCtl(), fs)
    emit("P-08", len(fs.added) == 1 and "attach_disconnected" not in fs.added[0] and NAME in fs.added[0],
         "load adds the production profile under NAME")


def p09(P, emit):
    def case(text, want, fs, ctl=None):
        r = release(P, ctl or ok_ctl(), fs)
        emit("P-09", r == want, f"{text}: {r}")

    case("the profile vanished", "kept", FakeSys(listed=((),)))
    case("its mode changed (complain)", "kept", FakeSys(listed=(("complain",),)))
    case("its kernel hash changed", "kept", FakeSys(hash_now="b" * 64))
    case("unchanged", "released", FakeSys())
    case("no hash exported, at load or now", "released", FakeSys(hash_now=None), ok_ctl(hash_="sha256 none\n"))
    fs = FakeSys(listed=((),))
    r = release(P, ok_ctl(state="loading\n", ns=None), fs)
    emit("P-09", r == "not removed" and "remove" not in fs.calls and "sweep" not in fs.calls,
         f"state loading and the name never loaded: success with nothing to remove ({r})")


def procs_tree(launcher=1000, sudo=1001, monitor=None, unshare=1002, init=1003, init_ns=NSINO, nspid=("1003", "1")):
    sudo_argv = ["sudo", "-n", "unshare", "--net", "--mount", "--pid", "--fork", "--kill-child", "--mount-proc",
                 "--ipc", "--propagation", "private", "--", "/bin/sh", "-c", "INIT"]
    p = {launcher: {"ppid": 999, "comm": "bash", "argv": ["bash"], "start": 1, "nspid": [str(launcher)], "pidns": HOST, "ruid": 1001},
         sudo: {"ppid": launcher, "comm": "sudo", "argv": sudo_argv, "start": 2, "nspid": [str(sudo)], "pidns": HOST, "ruid": 0}}
    parent = sudo
    if monitor:
        p[monitor] = {"ppid": sudo, "comm": "sudo", "argv": sudo_argv, "start": 3, "nspid": [str(monitor)], "pidns": HOST, "ruid": 0}
        parent = monitor
    p[unshare] = {"ppid": parent, "comm": "unshare", "argv": sudo_argv[2:], "start": 4, "nspid": [str(unshare)], "pidns": HOST, "ruid": 0}
    if init:
        p[init] = {"ppid": unshare, "comm": "sh", "argv": ["/bin/sh", "-c", "INIT"], "start": 5000, "nspid": list(nspid),
                   "pidns": init_ns, "ruid": 0}
    return p


def p10(P, emit):
    fs = FakeSys()
    fs.procs = procs_tree()
    ctl = FakeCtl()
    r = P["kill_init_once"](1000, ctl, fs)
    order = [c for c in fs.calls if c.startswith(("pidfd_open", "start_time", "ns_inodes", "signal"))]
    want = ["pidfd_open 1003", "start_time", "ns_inodes", "start_time", "signal 0", f"signal {int(signal.SIGKILL)}"]
    recorded = ctl.writes == [("ns", f"pid:{NSINO} mnt:4026532267\n")]
    emit("P-10", r == "killed" and order == want and recorded,
         f"namespace record missing: held by a pidfd, start time checked around the namespace read, recorded, then killed ({order})")
    fs = FakeSys()
    fs.procs = procs_tree()
    ctl = FakeCtl({"ns": rec(f"pid:{NSINO} mnt:4026532267\n")})
    r1 = P["kill_init_once"](1000, ctl, fs)
    fs2 = FakeSys()
    fs2.procs = procs_tree()
    fs2.inodes = {1003: (NSINO + 1, None)}
    ctl2 = FakeCtl({"ns": rec(f"pid:{NSINO} mnt:4026532267\n")})
    try:
        P["kill_init_once"](1000, ctl2, fs2)
        r2 = "killed"
    except P["Refused"]:
        r2 = "refused"
    emit("P-10", r1 == "killed" and not ctl.writes and r2 == "refused" and f"signal {int(signal.SIGKILL)}" not in fs2.calls,
         f"namespace recorded: nothing written; killed only in the recorded namespace ({r1}, {r2})")
    fs = FakeSys()
    fs.procs = procs_tree()
    ctl = FakeCtl(race=rec(f"pid:{NSINO} mnt:4026532267\n"))
    r1 = P["kill_init_once"](1000, ctl, fs)
    fs2 = FakeSys()
    fs2.procs = procs_tree()
    ctl2 = FakeCtl(race=rec(f"pid:{NSINO + 5} mnt:-\n"))
    try:
        P["kill_init_once"](1000, ctl2, fs2)
        r2 = "killed"
    except P["Refused"]:
        r2 = "refused"
    emit("P-10", r1 == "killed" and r2 == "refused" and f"signal {int(signal.SIGKILL)}" not in fs2.calls,
         f"pid 1 recorded its namespace first: the same one is accepted, another one stops the kill ({r1}, {r2})")
    fs = FakeSys()
    fs.procs = procs_tree()
    fs.procs[1005] = dict(fs.procs[1001])  # a second sudo of the launcher: ambiguous
    now = [0.0]
    fs.clock = lambda: now[0]

    def tick(s_):
        now[0] += 1.0
    fs.sleep = tick
    try:
        P["kill_init"](1000, FakeCtl(), fs)
        r = "returned"
    except P["Refused"]:
        r = "refused"
    emit("P-10", r == "refused" and f"signal {int(signal.SIGKILL)}" not in fs.calls and now[0] >= 8,
         f"an ambiguous lookup is retried until the deadline, then refused without a signal ({r}, {now[0]:.0f}s)")


def p11(P, emit):
    cf = P["ctldir_findings"]
    path = "/home/runner/work/_temp/no-docker-ctl.Ab12Cd"
    info = {"dir": True, "link": False, "uid": 1001, "mode": 0o700}
    emit("P-11", cf(path, info, path, 1001, "runner", 1001) == [], "a valid CTLDIR is accepted")
    bad = [("work/_temp/no-docker-ctl.Ab12Cd", info, None),
           ("/home/runner/work/_temp/../_temp/no-docker-ctl.Ab12Cd", info, None),
           (path, info, "/home/runner/work/_temp/real"),
           (path, None, path), (path, dict(info, dir=False), path), (path, dict(info, link=True), path),
           (path, dict(info, mode=0o755), path), (path, dict(info, uid=0), path),
           ("/home/runner/work/x/no-docker-ctl.Ab12Cd", info, None), ("/home/runner/work/_temp/ctl.Ab12Cd", info, None),
           ("/home/runner/work/_temp/no-docker-ctl.Ab", info, None)]
    refused = sum(1 for p, i, real in bad if cf(p, i, real or p, 1001, "runner", 1001))
    user = sum(1 for args in ((1001, "root", 0), (1001, "other", 1002), (1001, "Runner", 1001), (1001, "", None))
               if cf(path, info, path, *args))
    emit("P-11", refused == len(bad) and user == 4,
         f"CTLDIR refused: relative, not canonical, a link, missing, not a directory, mode, owner, place, name; SUDO_USER mismatch ({refused + user} of {len(bad) + 4})")
    lf = P["launcher_findings"]

    def table(chain):
        t = {1000: {"ppid": 999, "comm": "bash", "ruid": 1001}}
        prev = 1000
        for i, comm in enumerate(chain):
            t[2000 + i] = {"ppid": prev, "comm": comm, "ruid": 0}
            prev = 2000 + i
        return t, prev

    t, me = table(["sudo", "timeout", "python3"])
    t2, me2 = table(["sudo", "sudo", "timeout", "python3"])
    emit("P-11", lf(1000, t, me, 1001) == [] and lf(1000, t2, me2, 1001) == [],
         "LAUNCHERPID accepted: the parent of the sudo that started this helper (with and without sudo's monitor)")
    t3, me3 = table(["bash", "sudo", "timeout", "python3"])
    t4, me4 = table(["sudo", "a", "b", "c", "d", "timeout", "python3"])
    variants = [lf(1000, {**t, 1000: {"ppid": 999, "comm": "bash", "ruid": 0}}, me, 1001),
                lf(1000, t3, me3, 1001), lf(4242, t, me, 1001), lf(1000, t4, me4, 1001),
                lf(999, {**t, 999: {"ppid": 1, "comm": "bash", "ruid": 1001}}, me, 1001)]
    emit("P-11", all(variants), "LAUNCHERPID refused: another uid, not the sudo's parent, absent, too far up, a grandparent")
    fi = P["find_init"]
    fake = procs_tree()
    fake[1006] = dict(fake[1002], ppid=1003, pidns=NSINO)  # a process inside named unshare, with its argv
    emit("P-11", fi(procs_tree(), 1000, HOST, None) == ("found", 1003)
         and fi(procs_tree(monitor=1010), 1000, HOST, NSINO) == ("found", 1003)
         and fi(fake, 1000, HOST, None) == ("found", 1003),
         "pid 1 is found below the launcher's sudo and unshare (with and without sudo's monitor; a process "
         "inside disguised as unshare is not taken)")
    two = procs_tree()
    two[1004] = dict(two[1003])
    sudo2 = procs_tree()
    sudo2[1005] = dict(sudo2[1001])
    argv = procs_tree()
    argv[1001] = dict(argv[1001], argv=["sudo", "-n", "unshare", "--net", "--"])
    outcomes = [fi(procs_tree(init=None), 1000, HOST, None)[0], fi(argv, 1000, HOST, None)[0],
                fi(sudo2, 1000, HOST, None)[0], fi(two, 1000, HOST, None)[0],
                fi(procs_tree(init_ns=HOST), 1000, HOST, None)[0],
                fi(procs_tree(nspid=("1003", "7")), 1000, HOST, None)[0],
                fi(procs_tree(), 1000, HOST, NSINO + 1)[0], fi(procs_tree(), 4242, HOST, None)[0]]
    emit("P-11", outcomes == ["none", "none", "ambiguous", "ambiguous", "none", "none", "ambiguous", "none"],
         f"pid 1 is not taken: no child yet, another sudo argv, two sudos, two children, the host namespace, not pid 1, another recorded namespace, another launcher ({outcomes})")


CASES = [("P-01", p01), ("P-02", p02), ("P-03", p03), ("P-04", p04), ("P-05", p05), ("P-06", p06), ("P-07", p07),
         ("P-08", p08), ("P-09", p09), ("P-10", p10), ("P-11", p11)]


def run_case(fn, ns, emit_fn):
    try:
        fn(ns, emit_fn)
    except IOAttempt:
        raise
    except Exception as e:
        emit_fn(fn.__name__.upper().replace("P", "P-", 1), False, f"raised {type(e).__name__}: {e}")


# --- W: the helper calls what is tested --------------------------------------

def calls_in(tree, fname):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == fname:
            return {n.func.id if isinstance(n.func, ast.Name) else n.func.attr
                    for n in ast.walk(node) if isinstance(n, ast.Call)
                    and isinstance(n.func, (ast.Name, ast.Attribute))} | \
                   {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}
    return set()


def wiring():
    tree = ast.parse(SOURCE)
    need = {
        "main": {"preflight", "load", "kill_init", "release", "diag", "validated_ctldir", "launcher_findings", "name_ok"},
        "release": {"parse_state", "release_plan", "p0", "p1", "p2", "sweeps_clear", "listed_modes", "parse_ns"},
        "load": {"template_for", "render", "listed_modes"},
        "kill_init_once": {"find_init", "p0", "parse_ns", "ns_record"},
        "preflight": {"preflight_findings"},
        "sweeps_clear": {"sweep_result"},
    }
    for fname, names in need.items():
        missing = names - calls_in(tree, fname)
        emit("W", not missing, f"{fname} uses {', '.join(sorted(names))}" + (f" (missing: {', '.join(sorted(missing))})" if missing else ""))


# --- M: mutants of the helper, each must fail its case -----------------------

MUTANTS = [
    ("M1", "P-05", "a sweep counting exact labels only",
     "        elif name in label:\n            carriers.append(path)", "        elif label.split(' (')[0] == name:\n            carriers.append(path)"),
    ("M2", "P-05", "an unreadable label counted as no carrier",
     "            if not gone(label):\n                unknown.append", "            if False:\n                unknown.append"),
    ("M3", "P-05", "a single sweep", "SWEEPS = 2", "SWEEPS = 1"),
    ("M4", "P-06", "P1 skipped",
     '        why = p1(sys_.pidns_tasks(), parse_ns(rec["text"])[0])\n        if why:',
     '        why = None\n        if why:'),
    ("M5", "P-09", "P2 skipped",
     "    why = p2(listed_modes(sys_.profile_list(), name), sys_.kernel_hash(name), hash_load)\n    if why:",
     "    why = None\n    if why:"),
    ("M6", "P-09", "the kernel hash not compared",
     '    if (hash_now or "none") != hash_load:', '    if False:'),
    ("M7", "P-04", "a load that replaces a loaded profile",
     '    if listed_modes(sys_.profile_list(), name):\n        raise Refused(f"{name} is loaded already")',
     '    if False:\n        raise Refused(f"{name} is loaded already")'),
    ("M8", "P-08", "the negative template reachable through load",
     '    if op == "load" and name_ok("load", name):\n        return ("production",)',
     '    if op == "load" and name_ok("release", name):\n        return ("negative" if "neg" in name else "production",)'),
    ("M9", "P-01", "the name prefix not checked",
     'NAME_RE = re.compile(r"flowcrm-nd-[0-9a-f]{32}")', 'NAME_RE = re.compile(r"[a-z-]*[0-9a-f]{32}")'),
    ("M10", "P-06", "an init that still runs accepted",
     '                and st.get("State", "").startswith("Z"))', '                )'),
    ("M11", "P-05", "a task that ended counted as unknown",
     "    return isinstance(e, OSError) and e.errno in (errno.ENOENT, errno.ESRCH)", "    return False"),
    ("M12", "P-05", "a stacked label not counted",
     "        elif name in label:\n            carriers.append(path)", "        elif label.startswith(name):\n            carriers.append(path)"),
    ("M13", "P-06", "a missing state treated as loading",
     '    if text is None or STATE_RE.fullmatch(text) is None:\n        return "unknown"',
     '    if text is None or STATE_RE.fullmatch(text) is None:\n        return "loading"'),
    ("M14", "P-06", "a namespace record naming the host accepted",
     "    if pid_ino == host_ino:\n        return \"the namespace record names the host's pid namespace\"",
     "    if False:\n        return \"the namespace record names the host's pid namespace\""),
    ("M15", "P-06", "state loading with a namespace recorded not escalated",
     '    if state in ("loading", "not-forked") and not ns_exists:', '    if state == "loading" or (state == "not-forked" and not ns_exists):'),
    ("M16", "P-06", "state not-forked accepted with a namespace recorded",
     '    if state in ("loading", "not-forked") and not ns_exists:', '    if state == "not-forked" or (state == "loading" and not ns_exists):'),
    ("M17", "P-10", "pid 1 signalled before its namespace is recorded",
     "        sys_.pidfd_signal(pidfd, 0)\n        if pid_ino == host:",
     "        sys_.pidfd_signal(pidfd, 0)\n        sys_.pidfd_signal(pidfd, signal.SIGKILL)\n        if pid_ino == host:"),
]


def mutants():
    for name, case, text, old, new in MUTANTS:
        n = SOURCE.count(old)
        if n != 1:
            print(f"HARNESS ERROR: mutant {name} matches {n} times; the helper changed, the mutant must be updated")
            sys.exit(2)
        ns = load(SOURCE.replace(old, new))
        failed = []
        run_case(dict(CASES)[case], ns, lambda tag, good, t: None if good else failed.append(t))
        emit(name, bool(failed), f"{text}: {'rejected by ' + case if failed else 'NOT rejected by ' + case}")


for tag, fn in CASES:
    run_case(fn, A, emit)
wiring()
mutants()
print(f"SUMMARY {results['ok']} ok, {results['fail']} failed")
sys.exit(0 if results["fail"] == 0 else 1)
