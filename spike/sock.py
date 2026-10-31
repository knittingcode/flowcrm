"""Test-owned Unix socket helper of the FCRM-SEC-023 AppArmor spike.

Every operation except listen prints two lines: "LABEL <its AppArmor label>"
and "RESULT <OK | errno name | TIMEOUT | NOREPLY>". A missing RESULT line is
read as a failure by the caller.

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
"""
import errno
import os
import socket
import subprocess
import sys
import time


def label():
    try:
        with open("/proc/self/attr/apparmor/current") as f:
            return f.read().strip()
    except OSError as e:
        return "unreadable-" + errno.errorcode.get(e.errno, str(e.errno))


def out(result):
    print("LABEL " + label())
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


def main(argv):
    op = argv[0]
    if op == "listen":
        return listen(argv[1], argv[2], int(argv[3]))
    if op == "label":
        print("LABEL " + label(), flush=True)
        return 0
    if op == "connect":
        a, k = argv[1], argv[2]
        s = socket.socket(socket.AF_UNIX, kind(k))
        s.settimeout(5)
        try:
            s.connect(addr(a))
        except socket.timeout:
            out("TIMEOUT")
            return 0
        except OSError as e:
            out(name(e))
            return 0
        if k == "dgram":
            try:
                s.send(b"x")
                out("OK")
            except OSError as e:
                out(name(e))
        else:
            out(greet(s))
        return 0
    if op == "sendto":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            s.sendto(b"x", addr(argv[1]))
            out("OK")
        except OSError as e:
            out(name(e))
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
            _, fds, _, _ = socket.recv_fds(r, 16, 1)
        except OSError as e:
            out("SETUP-" + name(e))
            return 0
        if not fds:
            out("SETUP-nofd")
            return 0
        out(greet(socket.socket(fileno=fds[0])))
        return 0
    return 2


sys.exit(main(sys.argv[1:]))
