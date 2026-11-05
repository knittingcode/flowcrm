"""Pure tests of the Linux rules of scripts/ci/no-docker-probe.py.

Usage: python3 -I -B no-docker-probe-unit.py <path of no-docker-probe.py>

The probe's source is read once, then every call that would read /proc,
open a file or socket, run a program, fork or enter a namespace is replaced
by one that raises: the rules are tested on fixtures only, never on this
machine. Each assertion prints "ok   <case> <text>" or "FAIL <case> <text>";
the cases are C01 to C07 and C10 to C14 (the rules, the gate's label,
descriptor and fence checks and --root-exec's sanitation), W (the probe
calls the tested functions) and M1 to M21 (mutated copies of the probe,
each of which must fail at least one assertion of its case). The
last line is "SUMMARY <ok> ok, <failed> failed". Exit 0 only if nothing
failed; 2 if a mutant cannot be made exactly.
"""

import ast
import builtins
import errno
import os
import resource
import signal
import socket
import subprocess
import sys

sys.dont_write_bytecode = True
SOURCE_PATH = sys.argv[1]
with open(SOURCE_PATH) as f:
    SOURCE = f.read()


def load(src):
    ns = {"__name__": "probe_under_test", "__file__": SOURCE_PATH}
    exec(compile(src, SOURCE_PATH, "exec"), ns)
    return ns


class IOAttempt(AssertionError):
    pass


def tripwire(name):
    def raiser(*args, **kwargs):
        raise IOAttempt(f"{name} called in a pure test")
    return raiser


for mod, names in ((os, ("open", "listdir", "readlink", "getxattr", "setns", "fork", "stat", "lstat", "fstat",
                         "scandir", "walk", "pipe", "kill", "waitpid", "closerange", "close", "dup2",
                         "set_inheritable", "execv", "execvp", "access", "statvfs", "isatty")),
                   (signal, ("signal", "pthread_sigmask")),
                   (resource, ("getrlimit",)),
                   (socket, ("socket", "socketpair", "if_nameindex")),
                   (subprocess, ("run", "Popen", "check_output", "call"))):
    for name in names:
        if hasattr(mod, name):
            setattr(mod, name, tripwire(f"{mod.__name__}.{name}"))
builtins.open = tripwire("open")

P = load(SOURCE)
INIT = "pid:[4026531836]"
HOST_NS = f"net=net:[4026531833] mnt=mnt:[4026531832] pid={INIT} ipc=ipc:[4026531839]"
results = {"ok": 0, "fail": 0}


def emit(tag, good, text):
    results["ok" if good else "fail"] += 1
    print(f"{'ok  ' if good else 'FAIL'} {tag} {text}")


def passes(findings):
    return bool(findings) and all(p for p, _ in findings)


def failing(findings):
    return [t for p, t in findings if not p]


def status(**over):
    st = {"Name": "python3", "Uid": "1001\t1001\t1001\t1001", "Gid": "1001\t1001\t1001\t1001", "Groups": "",
          "NoNewPrivs": "1", "NSpid": "20", "CapInh": "0000000000000000", "CapPrm": "0000000000000000",
          "CapEff": "0000000000000000", "CapBnd": "0000000000000000", "CapAmb": "0000000000000000"}
    st.update(over)
    return {k: v for k, v in st.items() if v is not None}


def mount(point, fstype, opts=("rw",), sup=("rw",)):
    return {"id": hash(point) & 0xFFFF, "point": point, "fstype": fstype, "opts": list(opts), "super": list(sup)}


def valid_mounts():
    vis = {p: mount(p, t) for p, t in (("/tmp", "tmpfs"), ("/var/tmp", "tmpfs"), ("/dev/shm", "tmpfs"),
                                        ("/run", "tmpfs"), ("/dev/mqueue", "mqueue"))}
    vis["/proc"] = mount("/proc", "proc")
    vis["/sys/fs/cgroup"] = mount("/sys/fs/cgroup", "tmpfs", ("ro",))
    vis["/"] = mount("/", "ext4", ("ro",))
    return vis


HOST_DEVS = {"/tmp": "2049", "/var/tmp": "2049", "/dev/shm": "27", "/run": "29", "/dev/mqueue": "23"}
DEVS = {"/tmp": "54", "/var/tmp": "55", "/dev/shm": "56", "/run": "53", "/dev/mqueue": "51"}
PROCS = [("1", {"Name": "sh", "Uid": "0\t0\t0\t0"}), ("20", status()), ("21", status(Name="bash"))]


def valid_obs(**over):
    o = {"status": status(), "group": "runner", "uid": 1001, "pid": 20, "proc_self": "20",
         "ns": {"net": "net:[4026532270]", "mnt": "mnt:[4026532267]", "pid": "pid:[4026532269]",
                "ipc": "ipc:[4026532268]"},
         "host_ns": {"net": "net:[4026531833]", "mnt": "mnt:[4026531832]", "pid": INIT, "ipc": "ipc:[4026531839]"},
         "host_ns_raw": HOST_NS, "processes": list(PROCS), "sid": 17, "sid_ours": True, "tty": "ENXIO",
         "stdio": [(0, "/dev/null"), (1, "pipe"), (2, "pipe")], "interfaces": ["lo"], "work": "/tmp/no-docker.x",
         "mounts": valid_mounts(), "host_devs": dict(HOST_DEVS), "devs": dict(DEVS), "writable": [],
         "cwd": "/home/runner/work", "cwd_reachable": True}
    o.update(over)
    return o


# --- the cases; each takes the probe namespace and an emit function --------

def c01(P, emit):
    f = P["eval_pidns"]("20", 20, "pid:[4026532269]", HOST_NS, "20")
    emit("C01", passes(f) and len(f) == 4, f"a private /proc with NSpid of one entry, this pid, passes ({failing(f)})")
    f = P["evaluate_linux"](valid_obs())
    emit("C01", passes(f), f"the whole mechanism check passes on a valid observation ({failing(f)})")


def c02(P, emit):
    variants = [
        ("NSpid of two entries (a /proc of an ancestor namespace)", ("4711\t20", 20, "pid:[4026532269]", HOST_NS, "20")),
        ("NSpid of one entry that is not this pid", ("21", 20, "pid:[4026532269]", HOST_NS, "20")),
        ("NSpid missing", ("", 20, "pid:[4026532269]", HOST_NS, "20")),
        ("NSpid malformed", ("20 x", 20, "pid:[4026532269]", HOST_NS, "20")),
        ("own pid namespace is the caller's", ("20", 20, INIT, HOST_NS, "20")),
        ("caller not in the initial pid namespace", ("20", 20, "pid:[4026532269]", HOST_NS.replace(INIT, "pid:[4026532001]"), "20")),
        ("own namespace is the initial one, the caller claimed another", ("20", 20, INIT, HOST_NS.replace(INIT, "pid:[4026532001]"), "20")),
        ("caller given twice", ("20", 20, "pid:[4026532269]", HOST_NS + f" pid={INIT}", "20")),
        ("caller a near miss", ("20", 20, "pid:[4026532269]", HOST_NS.replace(INIT, "pid:[04026531836]"), "20")),
        ("caller missing", ("20", 20, "pid:[4026532269]", "net=net:[1]", "20")),
        ("own namespace malformed", ("20", 20, "pid:[x]", HOST_NS, "20")),
        ("/proc/self is another pid", ("20", 20, "pid:[4026532269]", HOST_NS, "4711")),
    ]
    for text, args in variants:
        f = P["eval_pidns"](*args)
        emit("C02", not passes(f), f"rejected: {text} ({len(failing(f))} failing)")
    f = P["evaluate_linux"](valid_obs(ns=dict(valid_obs()["ns"], pid=INIT)))
    emit("C02", not passes(f), "rejected by the whole check: a pid namespace shared with the caller")


def c03(P, emit):
    ev = P["eval_processes"]
    emit("C03", passes(ev(PROCS, 1001)), "our processes and the root shell as pid 1 pass")
    emit("C03", passes(ev(PROCS + [("22", OSError(errno.ENOENT, "gone"))], 1001)), "a process that ended is skipped")
    emit("C03", passes(ev(PROCS + [("22", OSError(errno.ESRCH, "gone"))], 1001)), "a process that ended (ESRCH) is skipped")
    bad = [
        ("a process of another user", PROCS + [("30", status(Uid="0\t0\t0\t0", Name="sleep"))]),
        ("a host daemon under our uid", PROCS + [("31", status(Name="dockerd"))]),
        ("Runner.Worker visible", PROCS + [("32", status(Name="Runner.Worker"))]),
        ("pid 1 is systemd", [("1", {"Name": "systemd", "Uid": "0\t0\t0\t0"})] + PROCS[1:]),
        ("pid 1 is not root", [("1", {"Name": "sh", "Uid": "1001\t1001\t1001\t1001"})] + PROCS[1:]),
        ("pid 1 missing", PROCS[1:]),
        ("pid 1 unreadable (hidepid)", [("1", OSError(errno.EPERM, "hidden"))] + PROCS[1:]),
        ("a status unreadable (EACCES)", PROCS + [("33", OSError(errno.EACCES, "denied"))]),
        ("a process without uids", PROCS + [("34", {"Name": "x"})]),
    ]
    for text, entries in bad:
        emit("C03", not passes(ev(entries, 1001)), f"rejected: {text}")


def c04(P, emit):
    ev = P["eval_creds"]
    emit("C04", passes(ev(status(), "runner")), "no capability, no_new_privs, not root passes")
    for cap in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"):
        emit("C04", not passes(ev(status(**{cap: "0000000000000400"}), "runner")), f"rejected: {cap} not zero")
        emit("C04", not passes(ev(status(**{cap: None}), "runner")), f"rejected: {cap} missing")
    emit("C04", not passes(ev(status(CapEff="zzzz"), "runner")), "rejected: an unparsable capability set")
    emit("C04", not passes(ev(status(NoNewPrivs="0"), "runner")), "rejected: no_new_privs unset")
    emit("C04", not passes(ev(status(Uid="1001\t0\t1001\t1001"), "runner")), "rejected: a uid 0")


def c05(P, emit):
    ev = P["eval_creds"]
    for gid in ("1000", "1001"):
        emit("C05", passes(ev(status(Gid="\t".join([gid] * 4)), "g")), f"primary gid {gid} passes")
    for gid, why in (("999", "the last system gid"), ("118", "the docker group"), ("6", "disk"), ("0", "root")):
        emit("C05", not passes(ev(status(Gid="\t".join([gid] * 4)), "g")), f"rejected: primary gid {gid} ({why})")
    emit("C05", not passes(ev(status(Gid="1001\t1001\t118\t1001"), "g")), "rejected: gids that differ")
    emit("C05", not passes(ev(status(Gid=None), "g")), "rejected: gids missing")
    emit("C05", not passes(ev(status(Groups="118"), "g")), "rejected: a supplementary group")


def c06(P, emit):
    ev = P["eval_mounts"]
    emit("C06", passes(ev(valid_mounts(), HOST_DEVS, DEVS, "/w", [])), "private mounts, one procfs, masked cgroups pass")
    v = valid_mounts()
    v["/proc"]["super"] = ["rw", "hidepid=0"]
    emit("C06", passes(ev(v, HOST_DEVS, DEVS, "/w", [])), "hidepid=0 passes")
    for text, change in (
            ("a second procfs", lambda v: v.update({"/mnt/p": mount("/mnt/p", "proc")})),
            ("an nsfs file", lambda v: v.update({"/x": mount("/x", "nsfs")})),
            ("/proc with hidepid=2", lambda v: v["/proc"].update(super=["rw", "hidepid=2"])),
            ("/proc with hidepid=invisible", lambda v: v["/proc"].update(super=["rw", "hidepid=invisible"])),
            ("/proc with hidepid=noaccess", lambda v: v["/proc"].update(super=["rw", "hidepid=noaccess"])),
            ("/proc with hidepid=ptraceable", lambda v: v["/proc"].update(super=["rw", "hidepid=ptraceable"])),
            ("/proc with subset=pid", lambda v: v["/proc"].update(opts=["rw", "subset=pid"])),
            ("/proc not a procfs", lambda v: v["/proc"].update(fstype="tmpfs")),
            ("/proc missing", lambda v: v.pop("/proc")),
            ("/tmp not private", lambda v: v["/tmp"].update(fstype="ext4")),
            ("/sys/fs/cgroup writable", lambda v: v["/sys/fs/cgroup"].update(opts=["rw"]))):
        v = valid_mounts()
        change(v)
        emit("C06", not passes(ev(v, HOST_DEVS, DEVS, "/w", [])), f"rejected: {text}")
    emit("C06", not passes(ev(valid_mounts(), HOST_DEVS, dict(DEVS, **{"/tmp": "2049"}), "/w", [])),
         "rejected: /tmp is the caller's device")
    emit("C06", not passes(ev(valid_mounts(), HOST_DEVS, DEVS, "/w", ["/home"])), "rejected: a writable mount left")


def c07(P, emit):
    ev = P["eval_stdio"]
    for text, kinds in (("a standard descriptor is a Unix socket", [(0, "/dev/null"), (1, "unix socket"), (2, "pipe")]),
                        ("a standard descriptor is a TCP socket", [(0, "/dev/null"), (1, "pipe"), (2, "socket")])):
        emit("C07", not passes(ev(kinds)), f"rejected: {text}")
    emit("C07", passes(ev([(0, "/dev/null"), (1, "pipe"), (2, "pipe")])), "/dev/null and pipes pass")
    for text, kinds in (("a terminal", [(0, "terminal"), (1, "pipe"), (2, "pipe")]),
                        ("a regular file", [(0, "/dev/null"), (1, "file"), (2, "pipe")]),
                        ("a descriptor that cannot be examined (EACCES)", [(0, "/dev/null"), (1, "pipe"), (2, "unreadable (EACCES)")]),
                        ("fd 0 closed", [(0, "closed"), (1, "pipe"), (2, "pipe")])):
        emit("C07", not passes(ev(kinds)), f"rejected: {text}")


def c10(P, emit):
    calls = []
    said = []

    def say(p, t):
        said.append(p)

    def after():
        calls.append(1)

    obs = lambda: valid_obs()
    ok = P["gated"](obs, lambda o: [(True, "a"), (True, "b")], after, say)
    emit("C10", ok and calls == [1], "with every finding passed the write and connect phase runs once")
    for text, observe, evaluate in (
            ("a finding failed", obs, lambda o: [(True, "a"), (False, "b"), (True, "c")]),
            ("no findings", obs, lambda o: []),
            ("the evaluation raised ValueError", obs, lambda o: int("x")),
            ("the evaluation raised KeyError", obs, lambda o: {}["k"]),
            ("the observation raised OSError", lambda: (_ for _ in ()).throw(OSError(errno.EIO, "io")), lambda o: [(True, "a")]),
            ("the whole check on an observation with a writable mount", lambda: valid_obs(writable=["/home"]), P["evaluate_linux"]),
            ("the whole check on a terminal", lambda: valid_obs(tty="opened"), P["evaluate_linux"])):
        calls.clear()
        said.clear()
        ok = P["gated"](observe, evaluate, after, say)
        emit("C10", not ok and calls == [] and False in said, f"not entered when {text}")


NAME = "flowcrm-nd-" + "0123456789abcdef" * 2
LABEL = f"{NAME} (enforce)\n"
ROOT_SH = {"Name": "sh", "Uid": "0\t0\t0\t0"}
OURS = {"Name": "bash", "Uid": "1001\t1001\t1001\t1001"}


def c11(P, emit):
    ev = P["eval_label"]
    emit("C11", passes(ev(LABEL, [], NAME)), "this process confined by exactly NAME in enforce mode passes")
    emit("C11", passes(ev(LABEL, [("1", ROOT_SH, "unconfined\n"), ("21", OURS, LABEL)], NAME)),
         "every other process confined by exactly NAME, pid 1 the root shell, passes")
    for text, own, others in (
            ("a stacked label", f"other//&{NAME} (enforce)\n", []),
            ("complain mode", f"{NAME} (complain)\n", []),
            ("another process unconfined", LABEL, [("1", ROOT_SH, "unconfined\n"), ("21", OURS, "unconfined\n")]),
            ("pid 1 unconfined but not the root shell", LABEL, [("1", OURS, "unconfined\n")]),
            ("the label missing", OSError(errno.ENOENT, "missing"), [])):
        emit("C11", not passes(ev(own, others, NAME)), f"rejected: {text}")


def fds(**over):
    o = {"pid": 20, "listed_pid": 20, "fds": [(0, "/dev/null"), (1, "pipe"), (2, "pipe")]}
    o.update(over)
    return o


STD = [(0, "/dev/null"), (1, "pipe"), (2, "pipe")]


def c12(P, emit):
    ev = P["eval_fds"]
    emit("C12", passes(ev(fds())), "fd 0 /dev/null, fds 1 and 2 pipes, nothing else passes")
    emit("C12", not passes(ev(fds(fds=STD + [(3, "unix socket")]))), "rejected: an extra fd 3 (a Unix socket)")
    emit("C12", not passes(ev(fds(fds=STD + [(7, "file")]))), "rejected: an extra fd 7 (a file)")
    emit("C12", passes(ev(fds(fds=STD + [(3, "closed")]))), "the listing's own descriptor (closed by now) is ignored")
    emit("C12", not passes(ev(fds(fds=[(0, "/dev/null"), (1, "unix socket"), (2, "pipe")]))), "rejected: fd 1 a socket")
    emit("C12", not passes(ev(fds(fds=[(0, "/dev/null"), (1, "pipe"), (2, "file")]))), "rejected: fd 2 a regular file")
    emit("C12", not passes(ev(fds(fds=STD + [(5, "unreadable (EIO)")]))), "rejected: an fd that cannot be examined")
    emit("C12", not passes(ev(fds(fds=[(0, "character device"), (1, "pipe"), (2, "pipe")]))), "rejected: fd 0 not /dev/null (1:3)")
    emit("C12", not passes(ev(fds(listed_pid=4711))), "rejected: the listing of another process")


def fence(**over):
    o = {"stream": {"sock": True, "uid": 1001, "dac": True, "result": "EACCES"},
         "dgram": {"sock": True, "uid": 1001, "dac": True, "result": "EACCES"}, "twin": "ok"}
    for k, v in over.items():
        o[k] = dict(o[k], **v) if isinstance(v, dict) else v
    return o


def c13(P, emit):
    ev = P["eval_fence"]
    emit("C13", passes(ev(fence(), 1001)), "both fence sockets refused with EACCES, the twin connects: passes")
    for text, f in (("both fence sockets reached", fence(stream={"result": "ok"}, dgram={"result": "ok"})),
                    ("the stream connect refused (ECONNREFUSED)", fence(stream={"result": "ECONNREFUSED"})),
                    ("the stream fence missing (ENOENT)", fence(stream={"result": "ENOENT"})),
                    ("the stream connect denied with EPERM", fence(stream={"result": "EPERM"})),
                    ("the datagram timing out", fence(dgram={"result": "timeout"})),
                    ("file permissions not shown to allow the fence", fence(dgram={"dac": False})),
                    ("the datagram refused but the stream reached", fence(stream={"result": "ok"})),
                    ("the twin not connecting", fence(twin="ECONNREFUSED"))):
        emit("C13", not passes(ev(f, 1001)), f"rejected: {text}")


def c14(P, emit):
    ev = P["eval_root_fds"]
    before = [(0, "pipe"), (1, "pipe"), (2, "pipe"), (3, "closed"), (5, "unix socket"), (6, "file")]
    good, closed, _ = ev(before, [(0, "pipe"), (1, "pipe"), (2, "pipe")], "/dev/null")
    emit("C14", good and closed == [5, 6], f"descriptors above 2 closed and none left: proceeds (closed {closed})")
    emit("C14", ev(before, [(0, "pipe"), (1, "pipe"), (2, "pipe"), (5, "unix socket")], "/dev/null")[0] is False,
         "rejected: a descriptor above 2 survives the close")
    emit("C14", ev(before, [(0, "pipe"), (1, "pipe"), (2, "pipe"), (4, "closed")], "/dev/null")[0] is True,
         "the listing's own descriptor (closed by now) is ignored")
    emit("C14", ev(before, [(0, "pipe"), (1, "pipe"), (2, "pipe")], "terminal")[0] is False, "rejected: stdin not /dev/null")


CASES = [("C01", c01), ("C02", c02), ("C03", c03), ("C04", c04), ("C05", c05), ("C06", c06), ("C07", c07),
         ("C10", c10), ("C11", c11), ("C12", c12), ("C13", c13), ("C14", c14)]


def run_case(fn, ns, emit_fn):
    try:
        fn(ns, emit_fn)
    except IOAttempt:
        raise
    except Exception as e:
        emit_fn(fn.__name__.upper(), False, f"raised {type(e).__name__}: {e}")


# --- W: the probe calls what is tested -------------------------------------

def calls_in(tree, fname):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == fname:
            return {n.func.id if isinstance(n.func, ast.Name) else n.func.attr
                    for n in ast.walk(node) if isinstance(n, ast.Call)
                    and isinstance(n.func, (ast.Name, ast.Attribute))} | \
                   {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}
    return set()


def lines_of(tree, fname, names):
    """{name: first line} of the calls of names in function fname."""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == fname:
            found = {}
            for n in ast.walk(node):
                if isinstance(n, ast.Call) and isinstance(n.func, (ast.Name, ast.Attribute)):
                    call = n.func.id if isinstance(n.func, ast.Name) else n.func.attr
                    if call in names:
                        found[call] = min(found.get(call, n.lineno), n.lineno)
            return found
    return {}


def main_mode(tree, flag, fname):
    """True if main calls fname inside an if whose test names flag."""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "main":
            for n in ast.walk(node):
                if isinstance(n, ast.If) and flag in {c.value for c in ast.walk(n.test) if isinstance(c, ast.Constant)}:
                    called = {c.func.id if isinstance(c.func, ast.Name) else c.func.attr
                              for b in n.body for c in ast.walk(b)
                              if isinstance(c, ast.Call) and isinstance(c.func, (ast.Name, ast.Attribute))}
                    if fname in called:
                        return True
    return False


def wiring():
    tree = ast.parse(SOURCE)
    need = [
        ("the gate evaluates the label (G3) and the descriptor table (G8)", "gate_exec", {"evaluate_gate", "eval_fds", "observe_fds"}),
        ("the gate's evaluation goes through gated", "gate_exec", {"gated"}),
        ("the gate checks the fence (G4, G6)", "gate_exec", {"fence_check", "eval_fence"}),
        ("the gate checks the twin (G5)", "gate_exec", {"twin_check"}),
        ("--root-exec closes and verifies the descriptors", "root_exec", {"closerange", "list_fds", "eval_root_fds", "dup2", "execv"}),
        ("the gate runs the kept after-gate checks and the engine check (endpoints)", "gate_exec", {"after_gate_linux", "engine_check"}),
    ]
    for text, fname, names in need:
        missing = names - calls_in(tree, fname)
        emit("W", not missing, f"{text}: {fname} uses {', '.join(sorted(names))}" + (f" (missing: {', '.join(sorted(missing))})" if missing else ""))
    for flag, fname in (("--gate-exec", "gate_exec"), ("--root-exec", "root_exec"), ("--seal", "seal")):
        emit("W", main_mode(tree, flag, fname), f"main runs {fname} for {flag}")
    ok_check = {"check_mechanism_linux", "engine_check"} <= calls_in(tree, "main")
    emit("W", ok_check, "main runs check_mechanism_linux and then engine_check without arguments (--check)")
    nested = calls_in(tree, "check_mechanism_linux")
    emit("W", {"gated", "evaluate_linux", "eval_label", "after_gate_linux"} <= nested and "endpoints" in calls_in(tree, "engine_check"),
         "a nested run gates on G1 (evaluate_linux), G3 (eval_label) and G7 (after_gate_linux, then engine_check with endpoints)")
    at = lines_of(tree, "gate_exec", {"signal", "pthread_sigmask", "execvp", "eval_fds"})
    emit("W", len(at) == 4 and at["eval_fds"] < at["signal"] < at["pthread_sigmask"] < at["execvp"],
         f"the gate checks the descriptors, then resets every signal and clears the mask, then execs ({at})")


# --- M: mutants of the probe, each must fail its case ----------------------

MUTANTS = [
    ("M1", "C01", "the old NSpid rule (two entries or more)",
     '(nspid.split() == [str(pid)], f"/proc shows', '(len(nspid.split()) >= 2, f"/proc shows'),
    ("M4", "C05", "the primary group rule removed",
     '(plain, f"the primary group is not a system group', '(True, f"the primary group is not a system group'),
    ("M6", "C10", "the gate removed",
     '    if not good:\n        return False\n    after()', '    after()\n    if not good:\n        return False'),
    ("M11", "C03", "any unreadable process skipped",
     '            if not gone(st):\n                foreign.append', '            if False:\n                foreign.append'),
    ("M12", "C02", "the caller's pid namespace not checked",
     '(caller == INIT_PID_NS, f"the caller is', '(True, f"the caller is'),
    ("M13", "C02", "NSpid containing the pid accepted",
     '(nspid.split() == [str(pid)], f"/proc shows', '(str(pid) in nspid.split(), f"/proc shows'),
    ("M14", "C13", "any fence error accepted",
     '(e.get("result") == "EACCES", f"{verb}', '(e.get("result") != "ok", f"{verb}'),
    ("M15", "C11", "a stacked label accepted",
     '(mine == want, f"this process is confined', '(mine.endswith(want), f"this process is confined'),
    ("M16", "C12", "descriptors above 2 ignored",
     'for fd, k in sorted(kinds.items()) if fd >= 3 and k != "closed"]', 'for fd, k in sorted(kinds.items()) if False]'),
    ("M17", "C13", "the file permission proof skipped",
     '(e.get("dac") is True, f"file permissions allow', '(True, f"file permissions allow'),
    ("M18", "C12", "a socket on fd 1 accepted",
     '(all(kinds.get(fd) == want for fd, want in std),', '(all(kinds.get(fd) in (want, "unix socket") for fd, want in std),'),
    ("M19", "C13", "the twin ignored",
     '(o.get("twin") == "ok", f"a socket bound inside', '(True, f"a socket bound inside'),
    ("M20", "C12", "a descriptor that cannot be examined taken as closed",
     'for fd, k in sorted(kinds.items()) if fd >= 3 and k != "closed"]',
     'for fd, k in sorted(kinds.items()) if fd >= 3 and k != "closed" and not k.startswith("unreadable")]'),
    ("M21", "C12", "the listing of another process accepted",
     '(o["listed_pid"] == o["pid"], f"the descriptors listed', '(True, f"the descriptors listed'),
]


def mutants():
    for name, case, text, old, new in MUTANTS:
        n = SOURCE.count(old)
        if n != 1:
            print(f"HARNESS ERROR: mutant {name} matches {n} times; the probe changed, the mutant must be updated")
            sys.exit(2)
        ns = load(SOURCE.replace(old, new))
        failed = []
        run_case(dict(CASES)[case], ns, lambda tag, good, t: None if good else failed.append(t))
        emit(name, bool(failed), f"{text}: {'rejected by ' + case if failed else 'NOT rejected by ' + case}")


for tag, fn in CASES:
    run_case(fn, P, emit)
wiring()
mutants()
print(f"SUMMARY {results['ok']} ok, {results['fail']} failed")
sys.exit(0 if results["fail"] == 0 else 1)
