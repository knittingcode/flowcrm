"""Test-owned Unix socket helper of the FCRM-SEC-025 AppArmor spike (revision 4).

Every socket operation except listen prints "LABEL <its AppArmor label>",
"STEP <call>" (connect and sendto only: the failing call, or the last one on
success) and "RESULT <OK | errno name | TIMEOUT | NOREPLY>". A missing RESULT
line is read as a failure by the caller.

listen ADDR stream|dgram SECONDS   bind ADDR (@name: abstract), print READY;
                                   a stream client gets SPIKE-OK, then the
                                   connection closes; datagrams are read and
                                   dropped; exits after SECONDS (max 280)
connect ADDR stream|dgram          connect (5 s timeout); a stream peer is
                                   used by reading its SPIKE-OK, a datagram
                                   peer by sending one byte
sendto ADDR                        one unconnected datagram
holdexec ADDR -- CMD...            connect ADDR, keep it as fd 5 across exec
usefd FD                           read SPIKE-OK on the inherited fd FD
scm ADDR -- CMD...                 run CMD with one end of a socketpair as
                                   fd 6, connect ADDR, pass that socket to CMD
                                   with SCM_RIGHTS; print CMD's lines
recvfd FD                          receive one socket on FD and read SPIKE-OK
label                              the label only
fds                                the label and "FDS <open descriptors>"
auditread SECONDS UID GID          (root) bind the audit netlink multicast
                                   group, drop to UID/GID, print every record
                                   as "REC <type> <text>" until stdin EOF or
                                   SECONDS (max 600); never sends anything
"""
import errno
import os
import select
import socket
import struct
import subprocess
import sys
import time

NETLINK_AUDIT = 9
AUDIT_NLGRP_READLOG_MASK = 1
SO_RCVBUFFORCE = getattr(socket, "SO_RCVBUFFORCE", 33)


def label():
    try:
        with open("/proc/self/attr/apparmor/current") as f:
            return f.read().strip()
    except OSError as e:
        return "unreadable-" + errno.errorcode.get(e.errno, str(e.errno))


def out(result, step=None):
    print("LABEL " + label())
    if step is not None:
        print("STEP " + step)
    print("RESULT " + result, flush=True)


def name(e):
    return errno.errorcode.get(e.errno, str(e.errno))


def addr(a):
    return "\0" + a[1:] if a.startswith("@") else a


def kind(k):
    return {"stream": socket.SOCK_STREAM, "dgram": socket.SOCK_DGRAM}[k]


def greet(s):
    try:
        s.settimeout(5)
        return "OK" if s.recv(16) == b"SPIKE-OK" else "NOREPLY"
    except socket.timeout:
        return "TIMEOUT"
    except OSError as e:
        return name(e)


def listen(a, k, secs):
    s = socket.socket(socket.AF_UNIX, kind(k))
    s.bind(addr(a))
    if k == "stream":
        s.listen(16)
    print("READY", flush=True)
    end = time.monotonic() + min(secs, 280)
    s.settimeout(1)
    while time.monotonic() < end:
        try:
            if k == "stream":
                c, _ = s.accept()
                c.sendall(b"SPIKE-OK")
                c.close()
            else:
                s.recv(64)
        except (socket.timeout, OSError):
            continue
    return 0


def parse_nl(data):
    """Split one netlink datagram into (type, payload) pairs; stops at the
    first header whose length is impossible."""
    msgs = []
    off = 0
    while len(data) - off >= 16:
        ln, typ, _flags, _seq, _pid = struct.unpack_from("=IHHII", data, off)
        if ln < 16 or ln > len(data) - off:
            break
        msgs.append((typ, data[off + 16:off + ln]))
        off += (ln + 3) & ~3
    return msgs


def clean(payload):
    t = payload.rstrip(b"\0").decode("utf-8", "backslashreplace")
    return t.replace("\r", "?").replace("\n", "?").replace("\0", "?")


def say(line):
    print(line, flush=True)


def dropped(uid, gid):
    if os.getresuid() != (uid, uid, uid) or os.getresgid() != (gid, gid, gid) or os.getgroups():
        return False
    with open("/proc/self/status") as f:
        for ln in f:
            if ln.startswith("CapEff:"):
                return int(ln.split()[1], 16) == 0
    return False


def auditread(secs, uid, gid):
    end = time.monotonic() + min(secs, 600)
    try:
        s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_AUDIT)
        try:
            s.setsockopt(socket.SOL_SOCKET, SO_RCVBUFFORCE, 4 << 20)
        except OSError:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        s.bind((0, AUDIT_NLGRP_READLOG_MASK))
    except OSError as e:
        say("AUDITREAD BINDFAIL " + name(e))
        return 0
    try:
        os.setgroups([])
        os.setgid(gid)
        os.setuid(uid)
        ok = dropped(uid, gid)
    except OSError:
        ok = False
    if not ok:
        say("AUDITREAD DROPFAIL")
        return 0
    rcv = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    say("AUDITREAD READY pid=%d rcvbuf=%d uid=%d" % (os.getpid(), rcv, os.getuid()))
    n = lost = 0
    reason = "deadline"
    while True:
        left = end - time.monotonic()
        if left <= 0:
            break
        r, _, _ = select.select([s, 0], [], [], min(left, 1.0))
        if 0 in r and os.read(0, 4096) == b"":
            reason = "eof"
            break
        if s not in r:
            continue
        try:
            data, _, flags, src = s.recvmsg(1 << 20)
        except OSError as e:
            if e.errno == errno.ENOBUFS:
                lost += 1
                say("AUDITREAD LOST enobufs")
                continue
            say("AUDITREAD ERROR " + name(e))
            reason = "error"
            break
        if src[0] != 0 or src[1] != AUDIT_NLGRP_READLOG_MASK:
            continue
        if flags & socket.MSG_TRUNC:
            say("REC TRUNC")
            continue
        for typ, payload in parse_nl(data):
            n += 1
            say("REC %d %s" % (typ, clean(payload)))
    say("AUDITREAD END records=%d enobufs_events=%d reason=%s" % (n, lost, reason))
    return 0


def fds():
    listed = sorted(int(x) for x in os.listdir("/proc/self/fd"))
    still = []
    for fd in listed:
        try:
            os.fstat(fd)
            still.append(str(fd))
        except OSError:
            pass
    print("LABEL " + label())
    print("FDS " + " ".join(still), flush=True)
    return 0


def main(argv):
    op = argv[0]
    if op == "listen":
        return listen(argv[1], argv[2], int(argv[3]))
    if op == "label":
        print("LABEL " + label(), flush=True)
        return 0
    if op == "fds":
        return fds()
    if op == "auditread":
        return auditread(int(argv[1]), int(argv[2]), int(argv[3]))
    if op == "connect":
        a, k = argv[1], argv[2]
        s = socket.socket(socket.AF_UNIX, kind(k))
        s.settimeout(5)
        try:
            s.connect(addr(a))
        except socket.timeout:
            out("TIMEOUT", "connect")
            return 0
        except OSError as e:
            out(name(e), "connect")
            return 0
        if k == "dgram":
            try:
                s.send(b"x")
                out("OK", "send")
            except OSError as e:
                out(name(e), "send")
        else:
            out(greet(s), "recv")
        return 0
    if op == "sendto":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            s.sendto(b"x", addr(argv[1]))
            out("OK", "sendto")
        except OSError as e:
            out(name(e), "sendto")
        return 0
    if op == "holdexec":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        try:
            s.connect(addr(argv[1]))
        except OSError as e:
            out("SETUP-" + name(e))
            return 0
        os.dup2(s.fileno(), 5)
        os.set_inheritable(5, True)
        cmd = argv[argv.index("--") + 1:]
        os.execvp(cmd[0], cmd)
    if op == "usefd":
        try:
            s = socket.socket(fileno=os.dup(int(argv[1])))
        except OSError as e:
            out("NOFD-" + name(e))
            return 0
        out(greet(s))
        return 0
    if op == "scm":
        a, b = socket.socketpair()
        os.dup2(b.fileno(), 6)
        os.set_inheritable(6, True)
        cmd = argv[argv.index("--") + 1:]
        p = subprocess.Popen(cmd, pass_fds=(6,))
        os.close(6)
        t = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        t.settimeout(5)
        try:
            t.connect(addr(argv[1]))
        except OSError as e:
            p.kill()
            p.wait()
            out("SETUP-" + name(e))
            return 0
        socket.send_fds(a, [b"f"], [t.fileno()])
        try:
            p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
        return 0
    if op == "recvfd":
        r = socket.socket(fileno=int(argv[1]))
        r.settimeout(5)
        try:
            _, fdl, _, _ = socket.recv_fds(r, 16, 1)
        except OSError as e:
            out("SETUP-" + name(e))
            return 0
        if not fdl:
            out("SETUP-nofd")
            return 0
        out(greet(socket.socket(fileno=fdl[0])))
        return 0
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        os._exit(1)
