"""Pure tests of the Linux rules of scripts/ci/no-docker-probe.py.

Usage: python3 -I -B no-docker-probe-unit.py <path of no-docker-probe.py>

The probe's source is read once, then every call that would read /proc,
open a file or socket, run a program, fork or enter a namespace is replaced
by one that raises: the rules are tested on fixtures only, never on this
machine. Each assertion prints "ok   <case> <text>" or "FAIL <case> <text>";
the cases are C01 to C10 (the regression cases of FCRM-SEC-019), W (the
probe calls the tested functions) and M1 to M11 (mutated copies of the
probe, each of which must fail at least one assertion of its case). The
last line is "SUMMARY <ok> ok, <failed> failed". Exit 0 only if nothing
failed; 2 if a mutant cannot be made exactly.
"""

import ast
import builtins
import errno
import os
import socket
import stat
import struct
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
                         "scandir", "walk", "pipe", "kill", "waitpid")),
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
         "stdio": [(0, "pipe"), (1, "pipe"), (2, "pipe")], "interfaces": ["lo"], "work": "/tmp/no-docker.x",
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
    ev = P["eval_reached"]
    emit("C07", passes(ev(["/a", "/b"], [])), "listed sockets that do not connect pass")
    emit("C07", not passes(ev(["/a", "/b"], ["/b (stream)"])), "rejected: a listed socket accepts a connection")
    emit("C07", not passes(ev([], [])), "rejected: an empty list proves nothing")
    emit("C07", not passes(P["eval_stdio"]([(0, "unix socket"), (1, "pipe"), (2, "pipe")])),
         "rejected: a standard descriptor is a Unix socket")
    emit("C07", passes(P["eval_stdio"]([(0, "character device"), (1, "pipe"), (2, "pipe")])), "pipes and /dev/null pass")


# netlink fixtures: the layout of include/uapi/linux/{netlink,sock_diag,unix_diag}.h
def nlmsg(mtype, payload, seq=1, flags=0x2):
    return struct.pack("<IHHII", 16 + len(payload), mtype, flags, seq, 4242) + payload + b"\0" * (-len(payload) % 4)


def rta(atype, body):
    return struct.pack("<HH", 4 + len(body), atype) + body + b"\0" * (-len(body) % 4)


def diag_msg(ino, name=None, vfs=None):
    body = struct.pack("<BBBBIII", 1, 1, 10, 0, ino, 0, 0)
    if name is not None:
        body += rta(0, name)
    if vfs is not None:
        body += rta(1, struct.pack("<II", *vfs))
    return body


DONE = nlmsg(3, struct.pack("<i", 0))
REC_PATH = diag_msg(100, b"/run/docker.sock\0", (5, (259 << 20) | 0))
REC_ABSTRACT = diag_msg(101, b"\0@abstract")
REC_UNBOUND = diag_msg(102)


def c08(P, emit):
    Inc, NoEnd = P["Incomplete"], P["NoEnd"]

    def raises(fn, kind=None):
        try:
            fn()
        except IOAttempt:
            raise
        except Exception as e:
            return isinstance(e, kind or Inc)
        return False

    req = P["diag_request"](1)
    length, mtype, flags, seq, _ = struct.unpack_from("<IHHII", req)
    fam, _, _, states, ino, show, c1, c2 = struct.unpack_from("<BBHIIIII", req, 16)
    emit("C08", (length, mtype, flags, fam, states, show) == (40, 20, 0x301, 1, 0xFFFFFFFF, 3) and len(req) == 40,
         "the dump request asks for every AF_UNIX socket in every state, with name and file")
    good = [(nlmsg(20, REC_PATH) + nlmsg(20, REC_ABSTRACT) + nlmsg(20, REC_UNBOUND), 0, 0), (DONE, 0, 0)]
    recs = P["parse_diag"](good, 1)
    emit("C08", [(r["ino"], r["path"], r["vfs"]) for r in recs]
         == [(100, b"/run/docker.sock", (5, (259 << 20))), (101, None, None), (102, None, None)],
         "a whole dump in two replies is read: the bound name without its NUL, abstract and unbound without a path")
    for text, batches, kind in (
            ("a reply truncated (MSG_TRUNC)", [(nlmsg(20, REC_PATH) + DONE, 0x20, 0)], None),
            ("an interrupted dump (NLM_F_DUMP_INTR)", [(nlmsg(20, REC_PATH, flags=0x12) + DONE, 0, 0)], None),
            ("an error answer first (no unix_diag)", [(nlmsg(2, struct.pack("<i", -2) + b"\0" * 16), 0, 0)], None),
            ("an error in the middle", [(nlmsg(20, REC_PATH) + nlmsg(2, struct.pack("<i", -12)), 0, 0)], None),
            ("a wrong sequence number", [(nlmsg(20, REC_PATH, seq=7) + DONE, 0, 0)], None),
            ("a reply not from the kernel", [(nlmsg(20, REC_PATH) + DONE, 0, 777)], None),
            ("a header cut short", [(nlmsg(20, REC_PATH)[:10], 0, 0)], None),
            ("a length beyond the reply", [(struct.pack("<IHHII", 999, 20, 2, 1, 0) + REC_PATH, 0, 0)], None),
            ("a length below the header", [(struct.pack("<IHHII", 8, 20, 2, 1, 0) + REC_PATH, 0, 0)], None),
            ("an attribute overrunning its record",
             [(nlmsg(20, struct.pack("<BBBBIII", 1, 1, 10, 0, 9, 0, 0) + struct.pack("<HH", 64, 0) + b"/x"), 0, 0)], None),
            ("no end marker", [(nlmsg(20, REC_PATH), 0, 0)], NoEnd),
            ("no end marker over several replies", [(nlmsg(20, REC_PATH), 0, 0), (nlmsg(20, REC_UNBOUND), 0, 0)], NoEnd),
            ("data after the end marker", [(nlmsg(20, REC_PATH) + DONE + nlmsg(20, REC_UNBOUND), 0, 0)], None),
            ("a reply after the end marker", [(DONE, 0, 0), (nlmsg(20, REC_PATH), 0, 0)], None),
            ("a bound name without its file", [(nlmsg(20, diag_msg(103, b"/x\0")) + DONE, 0, 0)], None),
            ("a file without a bound name", [(nlmsg(20, diag_msg(104, b"\0abs", (1, 2))) + DONE, 0, 0)], None),
            ("a file attribute of the wrong size", [(nlmsg(20, diag_msg(105, b"/x\0") + rta(1, b"\0" * 4)) + DONE, 0, 0)], None),
            ("a message of another type", [(nlmsg(16, REC_PATH) + DONE, 0, 0)], None)):
        emit("C08", raises(lambda: P["parse_diag"](batches, 1), kind), f"rejected: {text}")
    emit("C08", P["kernel_dev"]((259 << 20) | 0) == (259, 0) and P["kernel_dev"](1000) == (0, 1000)
         and P["kernel_dev"]((8 << 20) | 300) == (8, 300), "kernel device numbers (259:0, 0:1000, 8:300) are read")
    emit("C08", P["cross_check"]({5, (1 << 32) | 7}, [5, 7]) == [], "held sockets in a dump are complete (low 32 bits)")
    emit("C08", P["cross_check"]({5, 9}, [5]) == [9], "a held socket in no dump is found missing")
    emit("C08", P["uring_sockets"]("pos:\t0\nUserFiles:\t2\n    0: socket:[12]\n    1: /tmp/f\nUserBufs:\t0\n") == {12},
         "the sockets of an io_uring's registered files are read")
    emit("C08", raises(lambda: P["uring_sockets"]("pos:\t0\nSqThread:\t-1\n")), "rejected: an io_uring without its file table")
    host = P["parse_mountinfo"](
        b"25 1 259:1 / / rw - ext4 /dev/root rw\n"
        b"40 25 259:1 /home/runner/x /mnt/x rw - ext4 /dev/root rw\n"
        b"41 25 259:1 /home/runner/x/s /srv/s rw - ext4 /dev/root rw\n"
        b"42 25 259:1 /home/runner/xy /q rw - ext4 /dev/root rw\n"
        b"43 25 0:50 / /home/runner/x rw - tmpfs t rw\n"
        b"44 25 259:1 /home/runner/x /m\\040n rw - ext4 /dev/root rw\n")
    emit("C08", host[5]["point"] == b"/m n" and host[0]["dev"] == (259, 1), "mountinfo is read as bytes, escapes undone")
    got = P["aliases"](host, (259, 1), b"/home/runner/x/s")
    emit("C08", got == [b"/home/runner/x/s", b"/m n/s", b"/mnt/x/s", b"/srv/s"],
         f"every path to the file through a mount of its file system, hidden ones too, not /qs ({got})")
    emit("C08", P["fs_path"](b"/home/runner/x", b"/mnt/x", b"/mnt/x/s") == b"/home/runner/x/s"
         and P["fs_path"](b"/", b"/", b"/a/s") == b"/a/s" and P["fs_path"](b"/a/b", b"/a/b", b"/a/bc/s") is None,
         "a path within its file system is found by whole path components")
    lr = P["locate_reason"]
    sock = stat.S_IFSOCK | 0o666
    m = {"dev": (259, 1), "fstype": "ext4"}
    vfs = (5, (259 << 20) | 1)
    emit("C08", lr(sock, 5, 1, vfs, m, b"/run/docker.sock") is None, "the bound file with one link is located")
    emit("C08", lr(sock, (1 << 32) | 5, 1, vfs, m, b"/s") is None, "an inode is compared by its low 32 bits")
    for text, args in (("not a socket", (stat.S_IFREG | 0o644, 5, 1, vfs, m, b"/s")),
                       ("another inode", (sock, 6, 1, vfs, m, b"/s")),
                       ("two links", (sock, 5, 2, vfs, m, b"/s")),
                       ("no link", (sock, 5, 0, vfs, m, b"/s")),
                       ("its mount unknown", (sock, 5, 1, vfs, None, b"/s")),
                       ("another device", (sock, 5, 1, vfs, {"dev": (259, 2), "fstype": "ext4"}, b"/s")),
                       ("on FUSE", (sock, 5, 1, vfs, {"dev": (259, 1), "fstype": "fuse.sshfs"}, b"/s")),
                       ("on NFS", (sock, 5, 1, vfs, {"dev": (259, 1), "fstype": "nfs4"}, b"/s")),
                       ("on overlayfs", (sock, 5, 1, vfs, {"dev": (259, 1), "fstype": "overlay"}, b"/s")),
                       ("removed", (sock, 5, 1, vfs, m, b"/s (deleted)"))):
        emit("C08", lr(*args) is not None, f"not located: {text}")
    emit("C08", raises(lambda: P["locate"]({"path": b"run/x", "vfs": vfs}, [])), "not located: a relative name")
    seen = {}
    P["claim"](seen, ((259, 1), b"/s"), vfs)
    P["claim"](seen, ((259, 1), b"/s"), vfs)
    emit("C08", raises(lambda: P["claim"](seen, ((259, 1), b"/s"), (6, vfs[1]))), "rejected: two live sockets located at one path")


def c09(P, emit):
    now = [0.0]
    d = P["Deadline"](10, clock=lambda: now[0])
    d.check("at the start")
    now[0] = 9.9
    d.check("just before the end")
    now[0] = 10.0
    try:
        d.check("at the end")
        emit("C09", False, "rejected: the fast listing at its 10 s budget")
    except P["Incomplete"]:
        emit("C09", True, "rejected: the fast listing at its 10 s budget (the walk runs)")
    clock = [0.0]

    def slow(cmd, **kw):
        clock[0] += 100
        return subprocess.CompletedProcess(cmd, 0, b"", b"")

    entries = [{"point": "/", "fstype": "ext4"}, {"point": "/home", "fstype": "ext4"}]
    try:
        P["enumerate_sockets"](90, clock=lambda: clock[0], run=slow, entries=entries)
        emit("C09", False, "rejected: a walk past its budget")
    except TimeoutError:
        emit("C09", True, "rejected: a walk past its budget (no-docker refuses)")

    def hangs(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))

    try:
        P["enumerate_sockets"](150, clock=lambda: 0.0, run=hangs, entries=entries)
        emit("C09", False, "rejected: a find killed at the budget")
    except TimeoutError:
        emit("C09", True, "rejected: a find killed at the budget")

    def broken(cmd, **kw):
        return subprocess.CompletedProcess(cmd, 2, b"", b"")

    try:
        P["enumerate_sockets"](150, clock=lambda: 0.0, run=broken, entries=entries)
        emit("C09", False, "rejected: a find that failed")
    except OSError:
        emit("C09", True, "rejected: a find that failed (status 2)")


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


CASES = [("C01", c01), ("C02", c02), ("C03", c03), ("C04", c04), ("C05", c05), ("C06", c06), ("C07", c07),
         ("C08", c08), ("C09", c09), ("C10", c10)]


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


def wiring():
    tree = ast.parse(SOURCE)
    need = {
        "check_mechanism_linux": {"gated", "observe_linux", "evaluate_linux", "after_gate_linux"},
        "evaluate_linux": {"eval_creds", "eval_pidns", "eval_processes", "eval_stdio", "eval_mounts"},
        "after_gate_linux": {"eval_reached", "unix_connects"},
        "fast_listing": {"scan_tasks", "dump_netns", "cross_check", "locate", "claim", "aliases", "proc_net_unix_paths"},
        "scan_tasks": {"uring_sockets", "parse_mountinfo", "proc_entries", "proc_readlink"},
        "locate": {"locate_reason", "fs_path"},
        "dump_netns": {"diag_dump", "setns"},
        "diag_dump": {"parse_diag", "diag_request"},
        "parse_diag": {"parse_diag_msg"},
        "main": {"fast_listing", "enumerate_sockets", "Deadline", "check_mechanism_linux"},
    }
    for fname, names in need.items():
        missing = names - calls_in(tree, fname)
        emit("W", not missing, f"{fname} uses {', '.join(sorted(names))}" + (f" (missing: {', '.join(sorted(missing))})" if missing else ""))


# --- M: mutants of the probe, each must fail its case ----------------------

MUTANTS = [
    ("M1", "C01", "the old NSpid rule (two entries or more)",
     '(nspid.split() == [str(pid)], f"/proc shows', '(len(nspid.split()) >= 2, f"/proc shows'),
    ("M2", "C08", "the cross-check finds nothing missing",
     'return sorted({i & 0xFFFFFFFF for i in held} - {i & 0xFFFFFFFF for i in dumped})', 'return []'),
    ("M3", "C07", "an empty socket list accepted",
     '(bool(paths) and not reached, f"none of', '(not reached, f"none of'),
    ("M4", "C05", "the primary group rule removed",
     '(plain, f"the primary group is not a system group', '(True, f"the primary group is not a system group'),
    ("M5", "C09", "the fast listing's budget ignored",
     '        if self.left() <= 0:\n            raise Incomplete', '        if False:\n            raise Incomplete'),
    ("M6", "C10", "the gate removed",
     '    if not good:\n        return False\n    after()', '    after()\n    if not good:\n        return False'),
    ("M7", "C08", "the link count not checked",
     '    if nlink != 1:\n        return f"its file has', '    if False:\n        return f"its file has'),
    ("M8", "C08", "an io_uring without its file table tolerated",
     '    if not sep:\n        raise Incomplete("an io_uring', '    if False:\n        raise Incomplete("an io_uring'),
    ("M9", "C08", "only the path itself, no alias",
     'return sorted({rebase(path, m["root"], m["point"]) for m in entries\n                   if m["dev"] == dev and under(path, m["root"])})',
     'return [path]'),
    ("M10", "C08", "only listening sockets dumped",
     'struct.pack("<BBHIIIII", LINUX_AF_UNIX, 0, 0, 0xFFFFFFFF,', 'struct.pack("<BBHIIIII", LINUX_AF_UNIX, 0, 0, 1 << 10,'),
    ("M11", "C03", "any unreadable process skipped",
     '            if not gone(st):\n                foreign.append', '            if False:\n                foreign.append'),
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
