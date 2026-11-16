"""Prove that this process is isolated by scripts/ci/no-docker.sh.

Run by no-docker.sh inside its isolation, before the command it protects
(macOS: from --inner; Linux: as --gate-exec, the process that becomes the
command), and by `no-docker.sh --check`. Exit 0 only if

  - every mechanism of the isolation is in effect in this process:
      macOS: a connect to a Unix socket of our own, a TCP connect to
        loopback port 2375 and to a non-loopback address are refused by the
        sandbox (EPERM), not merely unanswered; no loopback port that was
        listening before the sandbox started (NO_DOCKER_HELD_PORTS) can be
        connected to; no signal reaches no-docker.sh outside the sandbox
        (NO_DOCKER_OUTER_PID, EPERM); no file can be created under $HOME, in
        the user's temporary directory (NO_DOCKER_USER_TMP), in /tmp or in
        /private/var/tmp, while $TMPDIR (inside the run's directory) is
        writable;
      Linux: not uid 0, no capability in any set, no_new_privs, no
        supplementary group, a primary group that is not a system group;
        network, mount, pid and IPC namespaces that differ from the caller's
        (NO_DOCKER_HOST_NS); a pid namespace below the caller's (the caller's
        is the initial one, ours is not), with a /proc of its own (NSpid is
        our pid alone, /proc/self is our pid) that hides no process, whose
        pid 1 is the root shell of no-docker.sh and whose other processes
        are all ours; a session of our own without a controlling terminal;
        standard descriptors that are pipes or /dev/null; only the loopback
        interface; /tmp, /var/tmp,
        /dev/shm, /run and /dev/mqueue are new file systems
        (NO_DOCKER_HOST_DEVS) and /sys/fs/cgroup is masked; every other
        mount reachable by path is read-only; this process, and every other
        one but the root pid 1, confined by exactly the AppArmor profile of
        the launch in enforce mode (NO_DOCKER_PROFILE); writes to $HOME,
        $GITHUB_WORKSPACE and $RUNNER_TEMP (NO_DOCKER_PROTECTED) fail; no
        cgroup file is writable; and no socket in the private directories.
        As --gate-exec, in addition: the namespace record of the launch
        (NO_DOCKER_CTL/ns) names this pid namespace and the control and
        fence directories are read-only; the two sockets no-docker.sh bound
        outside (NO_DOCKER_FENCE), which file permissions let us reach,
        refuse a connect and a datagram with EACCES, while a socket bound
        inside connects; and, last, the descriptors are exactly /dev/null
        on fd 0 and pipes on fds 1 and 2. Only then are the signal
        dispositions reset, the start recorded and the command run in this
        process. Host-bound Unix sockets are not listed: the kernel denies
        them (scripts/ci/no-docker/apparmor.profile);
  - and no container engine answers on any endpoint we can find: the
    usual socket paths of Docker Engine, Docker Desktop, rootless Docker,
    Podman, Colima, OrbStack and Rancher Desktop; every endpoint of the
    Docker contexts under ~/.docker; DOCKER_HOST and the DOCKER_HOST the
    caller of no-docker.sh had (NO_DOCKER_ORIGINAL_HOST); every socket under
    /run, /var/run, /tmp, $TMPDIR and ~/.docker; loopback ports 2375 and
    2376; and every listening TCP port.

An endpoint is an engine if it accepts a connection and answers
`GET /_ping` (sent with the User-Agent no-docker-probe) with an API version
header. Nothing is written, connected to or sent to an engine before the
mechanism checks passed. Prints one line per check.

Modes used by no-docker.sh:
  --listening   print the listening TCP port numbers (macOS), one per line;
  --root-exec UID GID NAME -- NAME=VALUE... -- COMMAND...
                as root inside the namespaces (Linux): close every
                descriptor above 2 and show that none is left, open
                /dev/null as fd 0, then exec setpriv (uid and gid, no groups,
                capabilities or new privileges), aa-exec -p NAME, setsid and
                env -i with the given environment, which run --gate-exec;
  --gate-exec -- COMMAND...
                the checks above, then COMMAND in this process (Linux; reports
                on fd 2, 125 if refused);
  --seal WORK   as root in the new mount namespace: make every mount
                reachable by path read-only, except the private file systems
                and WORK, and verify it (Linux);
  --markers TMP OWNER
                make a marker directory for a new run in the per-user
                temporary directory TMP, recording the process OWNER that
                supervises it, and print its path (macOS);
  --orphans TMP fail if a run that ended without its supervisor may still
                have processes (macOS);
  --supervise MARKDIR STARTED REMOVE -- COMMAND...
                run COMMAND (sandbox-exec), then end every process left in
                the sandbox of MARKDIR; signals end it at once; 125 unless
                the file STARTED exists; removes MARKDIR and the directory
                REMOVE ("-": none) (macOS, no-docker.sh's last step);
  --end MARKDIR end every process of the sandbox of MARKDIR, and remove it
                once that is shown (macOS).
"""

import concurrent.futures
import ctypes
import errno
import glob
import grp
import json
import os
import re
import resource
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

ok = True


def report(passed, text):
    global ok
    if not passed:
        ok = False
    print(f"no-docker: {'ok  ' if passed else 'FAIL'} {text}")


def denied(family, address):
    """True if connecting is refused by the sandbox (EPERM/EACCES)."""
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        s.connect(address)
    except OSError as e:
        return e.errno in (errno.EPERM, errno.EACCES)
    finally:
        s.close()
    return False


def engine_answers(family, address, timeout=2):
    """Return a description if an engine answers at address, else None."""
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(address)
        s.sendall(b"GET /_ping HTTP/1.0\r\nHost: docker\r\nUser-Agent: no-docker-probe\r\n\r\n")
        data = b""
        # Stop at the end of the headers: an engine may keep the connection
        # open (HTTP/1.1 keep-alive) instead of closing it after the answer.
        while len(data) < 4096 and b"\r\n\r\n" not in data:
            try:
                chunk = s.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
    except OSError:
        return None
    finally:
        s.close()
    head = data.split(b"\r\n\r\n", 1)[0].lower()
    if b"api-version:" in head or b"libpod-api-version:" in head:
        return head.split(b"\r\n", 1)[0].decode("ascii", "replace")
    return None


def connects(address):
    """True if a TCP connect succeeds; nothing is sent."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect(address)
    except OSError:
        return False
    finally:
        s.close()
    return True


def create_error(directory):
    """None if a new file can be created in directory (it is removed again),
    else the errno of the failure."""
    return create_error_named(directory, f".no-docker-probe-{os.getpid()}")


def create_error_named(directory, name):
    """As create_error, for a file of the given name."""
    path = os.path.join(directory, name)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        return None
    except OSError as e:
        return e.errno
    os.close(fd)
    os.unlink(path)
    return None


def not_writable(directory):
    return create_error(directory) is not None


class WalkLimit(Exception):
    pass


def walk_sockets(roots, limit=20000):
    """Socket paths under roots; raises WalkLimit instead of stopping
    silently when more than limit entries would have to be looked at."""
    found = []
    seen = 0
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
            for name in dirnames + filenames:
                seen += 1
                if seen > limit:
                    raise WalkLimit(f"more than {limit} entries under {' '.join(r for r in roots if r)}")
                p = os.path.join(dirpath, name)
                try:
                    if stat.S_ISSOCK(os.lstat(p).st_mode):
                        found.append(p)
                except OSError:
                    pass
    return found


# --- macOS -------------------------------------------------------------------

def check_mechanism_darwin():
    d = tempfile.mkdtemp(prefix="no-docker-probe.")
    # Bound and connected by a relative path: the absolute one can exceed
    # the 104 bytes of sun_path.
    cwd = os.open(".", os.O_RDONLY)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.chdir(d)
        srv.bind("s")
        srv.listen(1)
        report(denied(socket.AF_UNIX, "s"), "macOS sandbox denies Unix socket connects")
    finally:
        srv.close()
        try:
            os.unlink("s")
        except OSError:
            pass
        os.fchdir(cwd)
        os.close(cwd)
        os.rmdir(d)
    report(denied(socket.AF_INET, ("127.0.0.1", 2375)), "macOS sandbox denies loopback port 2375")
    report(denied(socket.AF_INET, ("192.0.2.1", 2375)), "macOS sandbox denies non-loopback TCP")
    if not ok:
        # Not sandboxed: write nothing, signal nothing and connect to nothing else.
        return
    held = os.environ.get("NO_DOCKER_HELD_PORTS", "").split()
    reached = [p for p in held if p.isdigit() and connects(("127.0.0.1", int(p)))]
    report(not reached, f"macOS sandbox denies the {len(held)} loopback ports listening before it started"
           + (": reached " + " ".join(reached) if reached else ""))
    outer = os.environ.get("NO_DOCKER_OUTER_PID", "")
    result = "unknown"
    if outer.isdigit():
        try:
            os.kill(int(outer), 0)
            result = "reached"
        except PermissionError:
            result = "EPERM"
        except OSError as e:
            result = errno.errorcode.get(e.errno, str(e.errno))
    report(result == "EPERM", f"macOS sandbox denies signals to processes outside it (no-docker.sh {outer or '?'}: {result})")
    home = os.path.realpath(os.path.expanduser("~"))
    user_tmp = os.environ.get("NO_DOCKER_USER_TMP", "")
    report(bool(user_tmp), "the user's temporary directory is known (NO_DOCKER_USER_TMP)")
    for where, d in (("under $HOME", home), ("in the user's temporary directory", user_tmp),
                     ("in /tmp", "/private/tmp"), ("in /private/var/tmp", "/private/var/tmp")):
        if d:
            report(not_writable(d), f"macOS sandbox denies writes {where} ({d})")
    tmpdir = os.environ.get("TMPDIR", "")
    report(bool(tmpdir) and create_error(tmpdir) is None, f"$TMPDIR of the run is writable ({tmpdir})")
    # bash 3.2 keeps here-documents in /private/tmp/sh-thd-*: none of another
    # bash outside may be created, replaced or rewritten from here.
    e = create_error_named("/private/tmp", f"sh-thd-no-docker-probe-{os.getpid()}")
    report(e is not None, "macOS sandbox denies writes to here-document files of bash 3.2 (/private/tmp/sh-thd-*)"
           + ("" if e is not None else ": written"))
    # The markers by which no-docker.sh finds this sandbox's processes from
    # outside: reading A is denied, reading B is not.
    for d in (os.environ.get("NO_DOCKER_MARK", ""),):
        result = "unknown"
        if d:
            try:
                open(os.path.join(d, "b"), "rb").close()
                try:
                    open(os.path.join(d, "a"), "rb").close()
                    result = "not denied"
                except PermissionError:
                    result = "ok"
            except OSError as err:
                result = errno.errorcode.get(err.errno, str(err))
        report(result == "ok", f"the sandbox carries the marker of {d or '?'} ({result})")


# The processes of one sandbox, seen from outside it. no-docker.sh (and the
# suite's own guard) add to the profile `(deny file-read-data (literal A))`
# for file A of the run's marker directory and leave file B next to it
# alone; no other profile names these files. sandbox_check() asks the
# kernel how a process's sandbox would decide, so a process is in the
# run's sandbox exactly when it is sandboxed at all, denied A and allowed
# B (measured: an unsandboxed process is allowed both; the files must
# exist, or every process is "denied"). A process cannot leave its
# sandbox, and every process it starts inherits it. The marker directory
# is in the per-user temporary directory, outside every directory the
# sandbox may write, so the command cannot remove or replace it; it also
# records the run's owner (the supervisor), so a run that ended without
# its supervisor can be recognised later.
MARK_PREFIX = "no-docker-mark."
SZOMB = 5


class ProcShortInfo(ctypes.Structure):
    # struct proc_bsdshortinfo (PROC_PIDT_SHORTBSDINFO): answers for
    # processes of other users too.
    _fields_ = [("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                ("status", ctypes.c_uint32), ("comm", ctypes.c_char * 16), ("flags", ctypes.c_uint32),
                ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
                ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32),
                ("rfu", ctypes.c_uint32)]


class ProcUniqIdentifierInfo(ctypes.Structure):
    # struct proc_uniqidentifierinfo (PROC_PIDUNIQIDENTIFIERINFO): an id
    # the kernel never reuses while it runs.
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("uniqueid", ctypes.c_uint64), ("puniqueid", ctypes.c_uint64),
                ("idversion", ctypes.c_int32), ("orig_ppidversion", ctypes.c_uint32),
                ("reserve3", ctypes.c_uint64), ("reserve4", ctypes.c_uint64)]


def private_dir(path):
    """True if path is a directory of ours, mode 0700, not a symbolic link."""
    st = os.lstat(path)
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) == 0o700


def regular_file(path):
    st = os.lstat(path)
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid()


def marker_files(directory):
    """The marker files A and B of directory, which must be a private
    directory with two empty regular files of ours."""
    if not private_dir(directory):
        raise OSError(f"{directory} is not a directory of ours with mode 0700")
    files = []
    for name in ("a", "b"):
        path = os.path.join(directory, name)
        if not regular_file(path):
            raise OSError(f"{path} is not a regular file of ours")
        files.append(os.fsencode(path))
    return files


class Gone(Exception):
    """The process ended (or its pid now names another process)."""


class ProcTable:
    """The process table (libproc). Raises OSError if it is unavailable or
    gives an answer that cannot be interpreted, so every caller fails
    closed."""

    PROC_PIDT_SHORTBSDINFO = 13
    PROC_PIDUNIQIDENTIFIERINFO = 17

    def __init__(self):
        try:
            self.proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        except OSError as e:
            raise OSError(f"libproc is not available: {e}") from None
        self.proc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]

    def snapshot(self):
        """Every pid, from one copy of the kernel's process lists (taken
        under one lock, so it holds every process that existed at that
        instant, zombies included). A full buffer may mean a cut list, so
        it is taken again with a larger one."""
        for _ in range(8):
            n = self.proc.proc_listallpids(None, 0)
            if n <= 0:
                raise OSError("cannot list the processes")
            room = n + 4096
            buf = (ctypes.c_int * room)()
            got = self.proc.proc_listallpids(buf, ctypes.sizeof(buf))
            if got <= 0:
                raise OSError("cannot list the processes")
            if got < room:
                return [buf[i] for i in range(got) if buf[i] > 0 and buf[i] != os.getpid()]
        raise OSError("the process list did not fit")

    def _info(self, pid, flavor, struct, arg=0):
        ctypes.set_errno(0)
        n = self.proc.proc_pidinfo(pid, flavor, arg, ctypes.byref(struct), ctypes.sizeof(struct))
        if n == ctypes.sizeof(struct):
            return True
        if ctypes.get_errno() in (errno.ESRCH, 0):
            return False
        raise OSError(f"cannot read process {pid} ({os.strerror(ctypes.get_errno())})")

    def identity(self, pid):
        """The kernel's unique id of the process, or None if it is gone (or
        a zombie)."""
        u = ProcUniqIdentifierInfo()
        return u.uniqueid if self._info(pid, self.PROC_PIDUNIQIDENTIFIERINFO, u) else None

    def parent_identity(self, pid):
        """The unique id of the process's parent, or None if it is gone."""
        u = ProcUniqIdentifierInfo()
        return u.puniqueid if self._info(pid, self.PROC_PIDUNIQIDENTIFIERINFO, u) else None

    def zombie(self, pid):
        """True if pid is a zombie (only an argument of 1 finds those)."""
        s = ProcShortInfo()
        return self._info(pid, self.PROC_PIDT_SHORTBSDINFO, s, arg=1) and s.status == SZOMB


class Sandboxes(ProcTable):
    """The process table and sandbox_check() for the marker of one run.
    Raises OSError if either is unavailable or gives an answer it cannot
    interpret, so every caller fails closed."""

    FILTER_PATH = 1

    def __init__(self, directory):
        super().__init__()
        self.directory = directory
        self.deny, self.allow = marker_files(directory)
        try:
            sb = ctypes.CDLL("/usr/lib/system/libsystem_sandbox.dylib", use_errno=True)
            self.check_fn = sb.sandbox_check
            no_report = ctypes.c_int.in_dll(sb, "SANDBOX_CHECK_NO_REPORT").value
        except (OSError, AttributeError, ValueError) as e:
            raise OSError(f"sandbox_check() is not available: {e}") from None
        # Variadic after the third parameter: with exactly three argtypes,
        # ctypes passes the path as a variadic argument (on the stack on
        # arm64), as the function expects.
        self.check_fn.restype = ctypes.c_int
        self.check_fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
        self.kind = self.FILTER_PATH | no_report
        self.verify()
        if self.identity(os.getpid()) is None:
            raise OSError("process identities cannot be read")

    def verify(self):
        """The marker files still exist and this (unsandboxed) process is
        allowed both and is not sandboxed. A missing file reads as denied
        for every process, so this runs before every scan, after every
        membership answer and before every signal."""
        marker_files(self.directory)
        me = os.getpid()
        if (self._check(me, self.deny), self._check(me, self.allow), self.check_fn(me, None, 0)) != (0, 0, 0):
            raise OSError("sandbox_check() does not answer as expected for this process")

    def _check(self, pid, path):
        return self.check_fn(pid, b"file-read-data", self.kind, ctypes.c_char_p(path))

    def classify(self, pid):
        """("member" | "other" | "zombie", unique id) of pid; raises Gone if
        it ended meanwhile, OSError if it cannot be told. Membership is read
        between two identity reads, so the answer belongs to one process."""
        first = self.identity(pid)
        if first is None:
            if self.zombie(pid):
                return "zombie", None
            raise Gone()
        s = ProcShortInfo()
        if not self._info(pid, self.PROC_PIDT_SHORTBSDINFO, s):
            raise Gone()
        if s.status == SZOMB:
            return "zombie", first
        sandboxed = self.check_fn(pid, None, 0)
        a, b = self._check(pid, self.deny), self._check(pid, self.allow)
        self.verify()
        if self.identity(pid) != first:
            raise Gone()
        if sandboxed not in (0, 1) or a not in (0, 1) or b not in (0, 1):
            raise OSError(f"sandbox_check() failed for pid {pid} ({sandboxed}, {a}, {b})")
        return ("member" if sandboxed == 1 and a == 1 and b == 0 else "other"), first


def sweep(sbx, seconds, kill, owner=None):
    """Show that no process of the sandbox runs any more, killing each one
    found if kill (SIGKILL, after its identity and the markers were read
    again). Returns (ended, members) once a round proves it: in one
    snapshot every pid is a process that is not a member (membership never
    changes), or one already dead (a zombie or gone) before that snapshot
    was taken. Every process started later descends from a process in the
    snapshot (a child is listed before it can run, its parent until it is
    reaped), so none of them can be a member either. A pid that ended
    before it could be told apart, or became a zombie only now, leaves the
    round open: it may have started a member before it died. Raises
    OSError when no round proves it within seconds (for example a process
    that keeps starting new ones and ending); the caller fails closed.
    owner (the unique id of a run's owner that is gone): a process the
    owner started that is not a member (yet) keeps every round open, as it
    may be the run's sandbox-exec before it applied the profile, the one
    process that becomes a member after it was checked. Relies on pids not
    being reused within one round (the kernel's counter would have to wrap
    at 99999)."""
    deadline = time.monotonic() + seconds
    others = {}  # pid: unique id of a process that is not a member
    dead = set()  # pids seen dead before the current snapshot
    ended = 0
    members = set()
    rounds = 0
    while True:
        rounds += 1
        sbx.verify()
        snap = sbx.snapshot()
        present = set(snap)
        proven = True
        dead_now = set()
        for pid in snap:
            if pid in dead:
                continue
            try:
                kind, uid = sbx.classify(pid)
            except Gone:
                if pid not in others:
                    proven = False
                continue
            if kind == "other":
                if owner is not None and sbx.parent_identity(pid) == owner:
                    proven = False
                    continue
                others[pid] = uid
            elif kind == "zombie":
                dead_now.add(pid)
                if pid not in others:
                    proven = False
            else:
                proven = False
                members.add(pid)
                if kill and sbx.identity(pid) == uid:
                    sbx.verify()
                    try:
                        os.kill(pid, signal.SIGKILL)
                        ended += 1
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        pass  # another user's (a setuid program): still found next round
        if proven:
            return ended, members
        # A pid absent from a snapshot may name a new process later.
        dead = (dead | dead_now) & present
        others = {p: u for p, u in others.items() if p in present}
        if time.monotonic() > deadline:
            live = sorted(p for p in members if sbx.identity(p) is not None)
            raise OSError(f"cannot show within {seconds:.0f}s that every process of the isolation ended "
                          f"({rounds} rounds; still running: {' '.join(map(str, live)) or 'none seen'})")
        time.sleep(0.005)


def owner_record(directory):
    """(pid, unique id) the marker directory records as its owner; raises
    OSError if the record is unreadable."""
    rec = os.path.join(directory, "owner")
    if not regular_file(rec) or os.lstat(rec).st_size > 64:
        raise OSError(f"{rec} is not a regular file of ours")
    with open(rec) as f:
        fields = f.read().split()
    if len(fields) != 2 or not fields[0].isdigit() or not fields[1].isdigit():
        raise OSError(f"{rec} is not an owner record")
    return int(fields[0]), int(fields[1])


def owner_alive(table, directory):
    """True if the owner the marker directory records still runs (same pid
    and unique id), False if it is gone; raises OSError if the record is
    unreadable."""
    pid, uid = owner_record(directory)
    return table.identity(pid) == uid


def darwin_markers(tmp, owner):
    """For no-docker.sh and the suite: make a marker directory for a new run
    in the per-user temporary directory tmp, recording its owner (pid and
    unique id; the supervisor that owner becomes, or the suite), and print
    its path."""
    run = tempfile.mkdtemp(prefix=MARK_PREFIX, dir=tmp)
    for name in ("a", "b"):
        os.close(os.open(os.path.join(run, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
    table = ProcTable()
    uid = table.identity(int(owner)) if owner.isdigit() else None
    if uid is None:
        shutil.rmtree(run, ignore_errors=True)
        raise OSError(f"the owner {owner} of the run does not exist")
    # Complete or absent for a reader: written aside, then renamed.
    part = os.path.join(run, "owner.part")
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"{owner} {uid}\n")
    os.rename(part, os.path.join(run, "owner"))
    print(run)
    return 0


def darwin_orphans(tmp, seconds=5.0):
    """Before a sandbox starts: refuse if an earlier run ended without its
    supervisor (no-docker.sh killed, or its ending failed) and processes of
    it may still run. Each run's marker directory records its owner; one
    whose owner is gone is checked with sweep(), without killing: proven
    empty, it is removed; otherwise (members found, or not provable in
    time) the run is refused and they are named. Directories of runs whose
    owner lives (other runs in progress) are left alone."""
    table = ProcTable()
    stale = []
    for name in sorted(os.listdir(tmp)):
        if not name.startswith(MARK_PREFIX):
            continue
        d = os.path.join(tmp, name)
        try:
            if not private_dir(d):
                continue
            if not os.path.lexists(os.path.join(d, "owner")):
                # Renamed into place right after the directory is made; an
                # old one without it is a run of an earlier version.
                if time.time() - os.lstat(d).st_mtime < 60:
                    continue
                stale.append(d)
                continue
            if not owner_alive(table, d):
                stale.append(d)
        except FileNotFoundError:
            continue  # removed meanwhile by its own run
        except OSError:
            stale.append(d)
    left = []
    for d in stale:
        if not os.path.lexists(d):
            continue  # removed meanwhile by its own run
        try:
            try:
                gone_owner = owner_record(d)[1]
            except FileNotFoundError:
                gone_owner = None
            _, members = sweep(Sandboxes(d), seconds, kill=False, owner=gone_owner)
        except OSError as e:
            # Among others: a marker file is missing, so its processes
            # cannot be found any more; the directory stays until someone
            # who knows that none runs removes it.
            left.append(f"{d}: {e}")
            continue
        if members:
            left.append(f"{d}: processes {' '.join(map(str, sorted(members)))}")
        else:
            shutil.rmtree(d, ignore_errors=True)
    if left:
        print("no-docker: an earlier isolated run ended without its supervisor and may have processes left; "
              "end them with: python3 -I " + os.path.abspath(__file__) + " --end <marker directory>: "
              + "; ".join(left), file=sys.stderr)
        return 1
    return 0


def darwin_end(sbx, seconds=10.0):
    """End every process of the run's sandbox (sweep with kill)."""
    return sweep(sbx, seconds, kill=True)[0]


class Interrupted(Exception):
    pass


def darwin_supervise(markdir, started_file, remove, argv):
    """no-docker.sh's last step on macOS, in its process: run argv (the
    sandbox-exec command line), wait for it, then end whatever is left in
    its sandbox; SIGINT, SIGTERM, SIGHUP or SIGQUIT end it at once the same
    way. Everything that needs a library is loaded before the command
    starts, and ending it needs no new process, so a command that uses up
    the processes it may start cannot prevent it. The run succeeds only
    when a round of sweep() proved that none of its processes runs any
    more. Removes the run's marker directory (kept when that could not be
    shown, so that the next run refuses and the processes can still be
    ended through it) and the directory remove (if not "-"). The status is
    the command's, or 125 if the isolation could not be applied
    (started_file, which the command's start creates, is missing) or its
    processes could not be shown to have ended; after a signal, 128 plus
    its number."""
    def refused(why):
        print(f"no-docker: refused: {why}", file=sys.stderr)
        return 125

    try:
        sbx = Sandboxes(markdir)
    except OSError as e:
        shutil.rmtree(markdir, ignore_errors=True)
        if remove != "-":
            shutil.rmtree(remove, ignore_errors=True)
        return refused(f"cannot identify the processes of the isolation: {e}; the command was not run")
    caught = []
    waiting = [False]

    def on_signal(signum, frame):
        # Only the wait for the command is cut short; ending the processes
        # always runs to its end.
        caught.append(signum)
        if waiting[0]:
            waiting[0] = False
            raise Interrupted()

    # A signal the caller ignores stays ignored, for the command too.
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        if signal.getsignal(s) != signal.SIG_IGN:
            signal.signal(s, on_signal)
    child = None
    status = 125
    ended, failure = 0, None
    try:
        try:
            child = subprocess.Popen(argv, close_fds=False)
        except OSError as e:
            print(f"no-docker: cannot start the isolation: {e}", file=sys.stderr)
        try:
            try:
                # A signal that came while it was being started is not
                # lost: the wait is skipped.
                waiting[0] = True
                if child is not None and not caught:
                    status = child.wait()
            finally:
                waiting[0] = False
        except Interrupted:
            # Also when it arrives in the finally clause above (the handler
            # clears waiting before it raises, so it raises only once).
            pass
        if child is not None:
            if child.poll() is None:
                # Interrupted: our own child, not yet reaped, so its pid is
                # still its own (also when sandbox-exec has not applied the
                # profile yet).
                child.kill()
            status = child.wait(timeout=10)
        ended = darwin_end(sbx)
    except BaseException as e:  # noqa: BLE001 - every failure fails closed
        failure = str(e) or type(e).__name__
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                failure = failure or f"the isolation tool (pid {child.pid}) does not end"
        started = os.path.exists(started_file)
        if not failure:
            shutil.rmtree(markdir, ignore_errors=True)
        if remove != "-":
            shutil.rmtree(remove, ignore_errors=True)
    if ended:
        print(f"no-docker: ended {ended} processes the command left running", file=sys.stderr)
    if failure:
        return refused(f"the processes of the isolated command could not be shown to have ended: {failure}; "
                       f"end them with: python3 -I {os.path.abspath(__file__)} --end {markdir}")
    if not started:
        return refused(f"the isolation tool returned {status} without starting the command; the command was not run")
    if caught:
        print(f"no-docker: interrupted by signal {caught[0]}; every process of the command was ended", file=sys.stderr)
        return 128 + caught[0]
    return 128 - status if status < 0 else status


# --- Linux -------------------------------------------------------------------

# Mounts that stay writable inside: the private file systems, /proc and /dev
# (device nodes; no file can be created there without root).
WRITABLE = ("/tmp", "/var/tmp", "/dev/shm", "/run", "/var/run", "/dev/mqueue", "/proc", "/dev", "/dev/pts")
PRIVATE = (("/tmp", "tmpfs"), ("/var/tmp", "tmpfs"), ("/dev/shm", "tmpfs"), ("/run", "tmpfs"),
           ("/dev/mqueue", "mqueue"))
HOST_COMMS = {"systemd", "init", "Runner.Worker", "Runner.Listener", "dockerd", "containerd", "sshd",
              "containerd-shim", "rootlesskit", "podman", "dbus-daemon"}
# The initial pid namespace, from which every other one descends: its inode
# number is fixed (PROC_PID_INIT_INO); every other namespace gets a number
# of 0xF0000000 or above.
INIT_PID_NS = "pid:[4026531836]"
# Debian and Ubuntu give system groups (docker, disk, adm, shadow,
# systemd-journal, ...) gids up to 999.
SYS_GID_MAX = 999
# The AppArmor profile of a launch (no-docker-aa.py) and the namespace
# record pid 1 writes (CTLDIR/ns: "pid:<inode> mnt:<inode or ->").
NAME_RE = re.compile(r"flowcrm-nd-(neg-)?[0-9a-f]{32}")
NS_RE = re.compile(r"pid:([1-9][0-9]{0,19}) mnt:([1-9][0-9]{0,19}|-)\n")
ENV_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.S)
# The chain --root-exec starts: credentials dropped, then the profile
# attached at the next exec, a session of its own, the allowlisted
# environment and the gate.
SETPRIV, AA_EXEC, SETSID, ENV, PYTHON = "/usr/bin/setpriv", "/usr/bin/aa-exec", "/usr/bin/setsid", "/usr/bin/env", \
    "/usr/bin/python3"
EX_REFUSED = 125


def unescape(s):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def mounts():
    entries = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.rstrip("\n").split(" ")
            sep = fields.index("-")
            entries.append({"id": int(fields[0]), "point": unescape(fields[4]),
                            "opts": fields[5].split(","), "fstype": fields[sep + 1],
                            "super": fields[sep + 3].split(",") if len(fields) > sep + 3 else []})
    return entries


def mount_id_of(path):
    """The mount id of the file at path (not following a final symbolic
    link), or None if path cannot be reached."""
    try:
        fd = os.open(path, os.O_PATH | os.O_NOFOLLOW)
    except OSError as e:
        if e.errno in (errno.ENOENT, errno.EACCES, errno.ENOTDIR, errno.ELOOP):
            return None
        raise
    try:
        with open(f"/proc/self/fdinfo/{fd}") as f:
            for line in f:
                if line.startswith("mnt_id:"):
                    return int(line.split()[1])
    finally:
        os.close(fd)
    raise OSError(f"no mnt_id for {path}")


def visible_mounts():
    """The mounts reachable by path: a mount hidden under another one, or
    under a path that no longer leads to it, cannot be written through."""
    return [m for m in mounts() if mount_id_of(m["point"]) == m["id"]]


def writable_mounts(work):
    keep = set(WRITABLE) | {work}
    return [m["point"] for m in visible_mounts() if m["point"] not in keep and "ro" not in m["opts"]]


MS_RDONLY, MS_NOSUID, MS_NODEV, MS_NOEXEC, MS_REMOUNT = 1, 2, 4, 8, 32
MS_NOSYMFOLLOW, MS_NOATIME, MS_NODIRATIME, MS_BIND = 256, 1024, 2048, 4096
MS_RELATIME, MS_STRICTATIME = 1 << 21, 1 << 24
KEEP_FLAGS = {"nosuid": MS_NOSUID, "nodev": MS_NODEV, "noexec": MS_NOEXEC, "nosymfollow": MS_NOSYMFOLLOW,
              "noatime": MS_NOATIME, "nodiratime": MS_NODIRATIME, "relatime": MS_RELATIME,
              "strictatime": MS_STRICTATIME}


def seal(work):
    """As root in the new mount namespace: remount every reachable mount
    except WRITABLE and work read-only (a bind remount changes only this
    namespace's copy and keeps its other per-mount flags), then verify."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
    keep = set(WRITABLE) | {work}
    count = 0
    for m in visible_mounts():
        if m["point"] in keep or "ro" in m["opts"]:
            continue
        flags = MS_REMOUNT | MS_BIND | MS_RDONLY
        for o in m["opts"]:
            flags |= KEEP_FLAGS.get(o, 0)
        if libc.mount(None, os.fsencode(m["point"]), None, flags, None) != 0:
            e = ctypes.get_errno()
            print(f"no-docker: cannot make {m['point']} read-only: {os.strerror(e)}", file=sys.stderr)
            return 1
        count += 1
    left = writable_mounts(work)
    if left:
        print(f"no-docker: still writable after the remount: {' '.join(left)}", file=sys.stderr)
        return 1
    print(f"no-docker: {count} mounts made read-only", file=sys.stderr)
    return 0


def gone(e):
    """True for the errors of a process or fd that ended meanwhile."""
    return e.errno in (errno.ENOENT, errno.ESRCH)


def status(pid="self"):
    st = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            st[k] = v.strip()
    return st


def env_pairs(name):
    return dict(x.split("=", 1) for x in os.environ.get(name, "").split() if "=" in x)


def eval_creds(st, group):
    """Findings on this process's credentials (st: /proc/self/status)."""
    uids = st.get("Uid", "0").split()
    caps = {k: st.get(k, "unknown") for k in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")}

    def zero(v):
        return re.fullmatch(r"[0-9a-f]+", v) is not None and int(v, 16) == 0

    gids = st.get("Gid", "").split()
    plain = len(gids) == 4 and len(set(gids)) == 1 and gids[0].isdigit() and int(gids[0]) > SYS_GID_MAX
    return [
        ("0" not in uids, f"not root (uids {' '.join(uids)})"),
        (all(zero(v) for v in caps.values()), "no capabilities (" + " ".join(f"{k}={v}" for k, v in caps.items()) + ")"),
        (st.get("NoNewPrivs") == "1", f"no_new_privs is set ({st.get('NoNewPrivs', 'unknown')})"),
        (st.get("Groups", "x") == "", f"no supplementary groups ({st.get('Groups') or 'none'})"),
        # The primary group is the caller's: not one of the system groups,
        # which include the one of the engine socket.
        (plain, f"the primary group is not a system group (gids {' '.join(gids) or 'unknown'}; {group})"),
    ]


def eval_pidns(nspid, pid, own, host_ns, proc_self):
    """Findings on the pid namespace. host_ns: NO_DOCKER_HOST_NS as given."""
    callers = [x[len("pid="):] for x in host_ns.split() if x.startswith("pid=")]
    caller = callers[0] if len(callers) == 1 else ""
    well_formed = re.fullmatch(r"pid:\[\d+\]", own) is not None
    return [
        (caller == INIT_PID_NS, f"the caller is in the initial pid namespace (caller {caller or 'unknown'})"),
        # Every pid namespace descends from the initial one: one that is
        # not it is below the caller's.
        (well_formed and own != INIT_PID_NS and own != caller,
         f"in a pid namespace below the caller's ({own}; caller {caller or 'unknown'})"),
        # A procfs shows NSpid from its own namespace down: one entry, this
        # pid, in the namespace's own /proc; more from an ancestor's.
        (nspid.split() == [str(pid)], f"/proc shows this process in its own pid namespace only (NSpid {nspid or 'missing'})"),
        (proc_self == str(pid), "/proc belongs to this pid namespace"),
    ]


def eval_processes(entries, me):
    """entries: (pid, its status or the OSError reading it) for every pid in
    /proc. Only an ended process may be skipped: one that cannot be read
    (hidepid) counts as foreign, and pid 1 must have been read."""
    foreign = []
    count = 0
    root = False
    for d, st in entries:
        if isinstance(st, OSError):
            if not gone(st):
                foreign.append(f"{d}:unreadable({errno.errorcode.get(st.errno, st.errno)})")
            continue
        count += 1
        name, puids = st.get("Name", "?"), st.get("Uid", "").split()
        if d == "1":
            root = puids[:1] == ["0"] and name in ("sh", "dash")
            if not root:
                foreign.append(f"1:{name}:{'/'.join(puids)}")
        elif not puids or any(u != str(me) for u in puids) or name in HOST_COMMS:
            foreign.append(f"{d}:{name}:{'/'.join(puids)}")
    if not root and not any(f.startswith("1:") for f in foreign):
        foreign.append("1:missing")
    return [(not foreign, f"only our processes and the root pid 1 of the isolation are visible ({count} processes"
             + (f"; foreign: {' '.join(foreign)}" if foreign else "") + ")")]


def eval_mounts(vis, host_devs, devs, work, left):
    """vis: the reachable mounts by mount point; devs: st_dev of the private
    paths; left: the mounts still writable (None without a run directory)."""
    f = []
    proc = vis.get("/proc")
    hidden = [o for o in (proc or {}).get("opts", []) + (proc or {}).get("super", [])
              if (o.startswith("hidepid=") and o not in ("hidepid=0", "hidepid=off")) or o.startswith("subset=")]
    f.append((bool(proc) and proc["fstype"] == "proc" and not hidden,
              f"/proc shows every process of the namespace ({','.join(hidden) or 'no hidepid or subset'})"))
    for path, fstype in PRIVATE:
        m = vis.get(path)
        dev = devs.get(path, "?")
        host = host_devs.get(path, "")
        f.append((bool(m) and m["fstype"] == fstype and bool(host) and dev != host,
                  f"{path} is a private {fstype} (device {dev}; caller {host or 'unknown'})"))
    # A second procfs, or a namespace file, reachable by path would lead to
    # the host's processes (/proc/<pid>/root) or namespaces.
    extra = [f"{m['point']} ({m['fstype']})" for m in vis.values()
             if (m["fstype"] == "proc" and m["point"] != "/proc") or m["fstype"] == "nsfs"]
    f.append((not extra, "no other proc or nsfs mount is reachable" + (f" ({' '.join(extra)})" if extra else "")))
    m = vis.get("/sys/fs/cgroup")
    f.append((bool(m) and m["fstype"] == "tmpfs" and "ro" in m["opts"], "/sys/fs/cgroup is masked by a read-only tmpfs"))
    if work:
        f.append((not left, f"every other mount is read-only ({len(vis)} reachable mounts"
                  + (f"; writable: {' '.join(left)}" if left else "") + ")"))
    return f


def eval_stdio(kinds):
    """kinds: (fd, kind) of fds 0 to 2 (fd_kind). Only a pipe or /dev/null:
    a socket could reach a host service without a connect, a terminal or a
    file is the caller's."""
    return [(len(kinds) == 3 and all(k in ("pipe", "/dev/null") for _, k in kinds),
             "the standard descriptors are pipes or /dev/null (" + ", ".join(f"{fd}: {k}" for fd, k in kinds) + ")")]


def eval_label(own, others, name):
    """Findings on AppArmor confinement (G3). own: this process's label or
    the OSError reading it; others: (pid, its status or OSError, its label
    or OSError) of every other process of the namespace. Every process but
    pid 1 (the root shell of the isolation) must carry exactly NAME in
    enforce mode: a stacked, complain-mode or other label is refused."""
    want = f"{name} (enforce)"
    f = [(bool(NAME_RE.fullmatch(name)), f"the profile name is known ({name or 'NO_DOCKER_PROFILE unset'})")]
    mine = own.rstrip("\n") if isinstance(own, str) else f"unreadable ({own})"
    f.append((mine == want, f"this process is confined by exactly {want} ({mine})"))
    bad = []
    for pid, st, label in others:
        if isinstance(st, OSError) or isinstance(label, OSError):
            err = st if isinstance(st, OSError) else label
            if not gone(err):
                bad.append(f"{pid}:unreadable({errno.errorcode.get(err.errno, err.errno)})")
            continue
        if pid == "1" and st.get("Uid", "").split()[:1] == ["0"] and st.get("Name") in ("sh", "dash"):
            continue
        if label.rstrip("\n") != want:
            bad.append(f"{pid}:{st.get('Name', '?')}:{label.rstrip()}")
    f.append((not bad, f"every other process but the root pid 1 is confined by exactly {want}"
              + (f" (not: {' '.join(bad)})" if bad else "")))
    return f


def eval_fds(o):
    """Findings on the descriptor table of the process that becomes the
    command (G8). o: {"pid", "listed_pid", "fds": [(fd, fd_kind)]} from a
    listing of /proc/self/fd. Exactly fd 0 /dev/null and fds 1 and 2 pipes;
    an fd 3 or above listed but closed (EBADF) is the listing's own."""
    kinds = dict(o["fds"])
    std = [(0, "/dev/null"), (1, "pipe"), (2, "pipe")]
    f = [(o["listed_pid"] == o["pid"], f"the descriptors listed are this process's (pid {o['pid']}, "
          f"listed {o['listed_pid']})")]
    f.append((all(kinds.get(fd) == want for fd, want in std),
              "fd 0 is /dev/null and fds 1 and 2 are pipes (" + ", ".join(f"{fd}: {kinds.get(fd, 'closed')}"
                                                                         for fd, _ in std) + ")"))
    extra = [f"{fd}: {k}" for fd, k in sorted(kinds.items()) if fd >= 3 and k != "closed"]
    f.append((not extra, "no other descriptor is open" + (f" ({', '.join(extra)})" if extra else "")))
    return f


def eval_fence(o, uid):
    """Findings on the fence (G4) and the twin (G5). o: {"stream": {...},
    "dgram": {...}, "twin": result}, each fence entry {"sock", "uid", "dac",
    "result"}. A host-bound socket of our own, which file permissions let
    us reach, must be refused with EACCES exactly (only AppArmor gives
    that); a socket bound inside must connect."""
    f = []
    for kind, verb in (("stream", "connect"), ("dgram", "sendto")):
        e = o.get(kind) or {}
        f.append((e.get("sock") is True and e.get("uid") == uid,
                  f"the {kind} fence is a socket of ours ({e.get('sock')}, uid {e.get('uid')})"))
        f.append((e.get("dac") is True, f"file permissions allow the {kind} fence ({e.get('dac')})"))
        f.append((e.get("result") == "EACCES", f"{verb} to the {kind} fence is refused with EACCES ({e.get('result')})"))
    f.append((o.get("twin") == "ok", f"a socket bound inside the isolation connects ({o.get('twin')})"))
    return f


def eval_root_fds(before, after, stdin):
    """(proceed, closed, findings) of --root-exec's descriptor sanitation.
    before, after: (fd, fd_kind) listed before and after the close; stdin:
    fd_kind of the new fd 0."""
    closed = [fd for fd, k in before if fd >= 3 and k != "closed"]
    left = [f"{fd}: {k}" for fd, k in after if fd >= 3 and k != "closed"]
    f = [(not left, "no descriptor above 2 is left" + (f" ({', '.join(left)})" if left else "")),
         (stdin == "/dev/null", f"stdin is /dev/null opened inside ({stdin})")]
    return all(p for p, _ in f), closed, f


def eval_ns_record(text, own_ino):
    """Findings on CTLDIR/ns (G2): the record names this pid namespace."""
    m = NS_RE.fullmatch(text) if isinstance(text, str) else None
    rec = int(m.group(1)) if m else None
    return [(rec is not None and rec == own_ino,
             f"the namespace record names this pid namespace ({rec if m else text}; ours {own_ino})")]


def evaluate_linux(o):
    """Every finding of the mechanism check, from the observations o."""
    f = eval_creds(o["status"], o["group"])
    for ns in ("net", "mnt", "pid", "ipc"):
        own, host = o["ns"][ns], o["host_ns"].get(ns, "")
        f.append((bool(host) and own != host, f"private {ns} namespace ({own}; caller {host or 'unknown'})"))
    f += eval_pidns(o["status"].get("NSpid", ""), o["pid"], o["ns"]["pid"], o["host_ns_raw"], o["proc_self"])
    f += eval_processes(o["processes"], o["uid"])
    f.append((o["sid_ours"], f"a session of our own (session {o['sid']})"))
    f.append((o["tty"] != "opened", f"no controlling terminal ({o['tty']})"))
    f += eval_stdio(o["stdio"])
    f.append((o["interfaces"] == ["lo"], f"network namespace has only loopback ({' '.join(o['interfaces'])})"))
    f.append((bool(o["work"]), f"the run's directory is known ({o['work'] or 'NO_DOCKER_RUN_DIR unset'})"))
    f += eval_mounts(o["mounts"], o["host_devs"], o["devs"], o["work"], o["writable"])
    f.append((o["cwd_reachable"] is True, f"the working directory is reachable by its path ({o['cwd']}"
              + ("" if o["cwd_reachable"] in (True, False) else f": {o['cwd_reachable']}") + ")"))
    return f


def fd_kind(fd):
    """What an fd is: "pipe", "/dev/null", "terminal", "character device",
    "file", "directory", "unix socket", "socket" or "other"; "closed" if
    fstat says EBADF; "unreadable (<errno>)" for any other error."""
    try:
        st = os.fstat(fd)
    except OSError as e:
        if e.errno == errno.EBADF:
            return "closed"
        return f"unreadable ({errno.errorcode.get(e.errno, e.errno)})"
    mode = st.st_mode
    if stat.S_ISFIFO(mode):
        return "pipe"
    if stat.S_ISCHR(mode):
        if st.st_rdev == os.makedev(1, 3):
            return "/dev/null"
        return "terminal" if os.isatty(fd) else "character device"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISSOCK(mode):
        s = socket.socket(fileno=os.dup(fd))
        try:
            return "unix socket" if s.family == socket.AF_UNIX else "socket"
        finally:
            s.close()
    return "other"


def list_fds():
    """(fd, fd_kind) of every entry of /proc/self/fd (the listing's own fd
    shows as closed), with the pid /proc/self named at the time."""
    listed_pid = int(os.readlink("/proc/self"))
    return listed_pid, [(fd, fd_kind(fd)) for fd in sorted(int(x) for x in os.listdir("/proc/self/fd"))]


def observe_fds():
    listed_pid, fds = list_fds()
    return {"pid": os.getpid(), "listed_pid": listed_pid, "fds": fds}


def read_label(pid):
    with open(f"/proc/{pid}/attr/apparmor/current") as f:
        return f.read()


def observe_labels():
    """(this process's label, (pid, status, label) of every other process)."""
    try:
        own = read_label("self")
    except OSError as e:
        own = e
    others = []
    me = str(os.getpid())
    for d in os.listdir("/proc"):
        if d.isdigit() and d != me:
            try:
                st = status(d)
            except OSError as e:
                others.append((d, e, e))
                continue
            try:
                others.append((d, st, read_label(d)))
            except OSError as e:
                others.append((d, st, e))
    return own, others


def observe_linux():
    """What the mechanism check looks at, read once (no write, no connect)."""
    st = status()
    try:
        group = grp.getgrgid(os.getgid()).gr_name
    except KeyError:
        group = "no group name"
    processes = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                processes.append((d, status(d)))
            except OSError as e:
                processes.append((d, e))
    sid = os.getsid(0)
    sid_ours = False
    if sid > 1:
        try:
            sid_ours = all(u == str(os.getuid()) for u in status(sid).get("Uid", "").split())
        except OSError:
            pass
    try:
        os.close(os.open("/dev/tty", os.O_RDWR))
        tty = "opened"
    except OSError as e:
        tty = errno.errorcode.get(e.errno, str(e.errno))
    stdio = [(fd, fd_kind(fd)) for fd in (0, 1, 2)]
    work = os.environ.get("NO_DOCKER_RUN_DIR", "")
    vis = {m["point"]: m for m in visible_mounts()}
    devs = {}
    for path, _ in PRIVATE:
        try:
            devs[path] = str(os.stat(path).st_dev)
        except OSError:
            devs[path] = "?"
    try:
        cwd_reachable = mount_id_of(".") == mount_id_of(os.getcwd())
    except OSError as e:
        cwd_reachable = str(e)
    return {
        "status": st, "group": group, "uid": os.getuid(), "pid": os.getpid(), "proc_self": os.readlink("/proc/self"),
        "ns": {ns: os.readlink(f"/proc/self/ns/{ns}") for ns in ("net", "mnt", "pid", "ipc")},
        "host_ns": env_pairs("NO_DOCKER_HOST_NS"), "host_ns_raw": os.environ.get("NO_DOCKER_HOST_NS", ""),
        "processes": processes, "sid": sid, "sid_ours": sid_ours, "tty": tty, "stdio": stdio,
        "interfaces": sorted(n for _, n in socket.if_nameindex()), "work": work, "mounts": vis,
        "host_devs": env_pairs("NO_DOCKER_HOST_DEVS"), "devs": devs,
        "writable": writable_mounts(work) if work else None, "cwd": os.getcwd(), "cwd_reachable": cwd_reachable,
    }


def gated(observe, evaluate, after, say):
    """Report every finding, and only if there are findings and all passed
    run after (the part that writes and connects). Any error before that is
    a failure."""
    try:
        findings = evaluate(observe())
    except Exception as e:
        say(False, f"the isolation check failed: {type(e).__name__}: {e}")
        return False
    if not findings:
        say(False, "the isolation check found nothing to check")
        return False
    good = True
    for passed, text in findings:
        say(passed, text)
        good = good and passed
    if not good:
        return False
    after()
    return True


def after_gate_linux():
    """Isolated: writes must fail, no cgroup file is writable and no socket
    is in the private directories."""
    protected = [p for p in os.environ.get("NO_DOCKER_PROTECTED", "").split(":") if p]
    report(bool(protected), "the protected directories are known (NO_DOCKER_PROTECTED)")
    for p in protected:
        e = create_error(p)
        report(e in (errno.EROFS, errno.EACCES), f"writes to {p} fail ({errno.errorcode.get(e, e) if e else 'written'})")
    writable = []
    try:
        for dirpath, dirnames, filenames in os.walk("/sys/fs/cgroup"):
            for n in dirnames + filenames:
                if os.access(os.path.join(dirpath, n), os.W_OK):
                    writable.append(os.path.join(dirpath, n))
        writable += [p for p in ("/sys/fs/cgroup/cgroup.kill", "/sys/fs/cgroup/cgroup.procs") if os.access(p, os.W_OK)]
    except OSError as e:
        writable.append(str(e))
    report(not writable, f"no cgroup file is writable ({' '.join(writable) or 'none'})")
    try:
        found = walk_sockets(["/run", "/tmp", "/var/tmp", "/dev/shm"], limit=20000)
        report(not found, f"no socket in the private directories ({' '.join(found) or 'none'})")
    except WalkLimit as e:
        report(False, f"no socket in the private directories ({e})")


def check_mechanism_linux():
    """--check, and a nested run (a suite re-executing itself inside the
    isolation): the rules of this process (G1), its own confinement (G3)
    and, only if they pass, the after-gate checks (G7); the engine check
    follows in main. The descriptor table is reported, not gating: the
    first-level gate checked it before the command started."""
    print(f"no-docker: info uids {status().get('Uid', '?')}; gids {status().get('Gid', '?')}")
    for passed, text in eval_fds(observe_fds()):
        print(f"no-docker: info {'' if passed else 'not: '}{text}")

    def observe():
        o = observe_linux()
        try:
            o["label"] = read_label("self")
        except OSError as e:
            o["label"] = e
        return o

    gated(observe, lambda o: evaluate_linux(o) + eval_label(o["label"], [], os.environ.get("NO_DOCKER_PROFILE", "")),
          after_gate_linux, report)


def dac_allows(path):
    """True if file permissions alone let this process connect to the
    socket at path: write on it and search on every directory above it,
    as the effective ids (faccessat AT_EACCESS; AppArmor does not mediate
    access(2), so this proves a refusal comes from the profile)."""
    try:
        if not os.access(path, os.W_OK, effective_ids=True):
            return False
        d = os.path.dirname(path)
        while True:
            if not os.access(d, os.X_OK, effective_ids=True):
                return False
            if d == "/":
                return True
            d = os.path.dirname(d)
    except OSError as e:
        return f"unreadable ({errno.errorcode.get(e.errno, e.errno)})"


def fence_check(fencedir):
    """G4 and G6: the two sockets no-docker.sh bound outside, in fencedir,
    looked at, connected and sent to, then closed."""
    o = {}
    for kind, stype in (("stream", socket.SOCK_STREAM), ("dgram", socket.SOCK_DGRAM)):
        path = os.path.join(fencedir, kind)
        e = {}
        try:
            st = os.lstat(path)
            e["sock"], e["uid"] = stat.S_ISSOCK(st.st_mode), st.st_uid
        except OSError as x:
            e["sock"] = f"unreadable ({errno.errorcode.get(x.errno, x.errno)})"
        e["dac"] = dac_allows(path)
        s = socket.socket(socket.AF_UNIX, stype)
        s.settimeout(2)
        try:
            if kind == "stream":
                s.connect(path)
            else:
                s.sendto(b"no-docker fence", path)
            e["result"] = "ok"
        except socket.timeout:
            e["result"] = "timeout"
        except OSError as x:
            e["result"] = errno.errorcode.get(x.errno, str(x.errno))
        finally:
            s.close()
        o[kind] = e
    return o


def twin_check():
    """G5 and G6: a stream socket bound inside the isolation (in its private
    /tmp) accepts a connection; both are closed and the path removed."""
    path = f"/tmp/.no-docker-twin-{os.getpid()}-{os.urandom(8).hex()}"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(path)
        srv.listen(1)
        cli.settimeout(2)
        cli.connect(path)
        return "ok"
    except socket.timeout:
        return "timeout"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
    finally:
        cli.close()
        srv.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def observe_gate(ctldir, fencedir):
    """observe_linux, plus what G2 and G3 look at."""
    o = observe_linux()
    o["labels"] = observe_labels()
    try:
        with open(os.path.join(ctldir, "ns")) as f:
            o["ns_text"] = f.read(4096)
    except OSError as e:
        o["ns_text"] = f"unreadable ({e})"
    own = re.fullmatch(r"pid:\[([0-9]+)\]", o["ns"]["pid"])
    o["own_pidns"] = int(own.group(1)) if own else None
    o["ro"] = {}
    for d in (ctldir, fencedir):
        try:
            o["ro"][d] = bool(os.statvfs(d).f_flag & os.ST_RDONLY)
        except OSError as e:
            o["ro"][d] = f"unreadable ({e})"
    return o


def evaluate_gate(o, name, ctldir, fencedir):
    """G1, G2 and G3."""
    f = evaluate_linux(o)
    f += eval_ns_record(o["ns_text"], o["own_pidns"])
    for d, what in ((ctldir, "control"), (fencedir, "fence")):
        f.append((bool(d) and o["ro"].get(d) is True, f"the {what} directory is read-only inside ({d or 'unknown'}: "
                  f"{o['ro'].get(d)})"))
    f += eval_label(o["labels"][0], o["labels"][1], name)
    return f


def gate_exec(cmd):
    """--gate-exec -- CMD: run as the command will, confined, by --root-exec.
    Check G1 to G8, report every finding on fd 2, and only if all passed
    reset the signal dispositions, record the start and exec CMD in this
    same process, so what was checked is what runs."""
    sys.stdout = sys.stderr  # fd 1 is the command's
    began = time.monotonic()
    name = os.environ.get("NO_DOCKER_PROFILE", "")
    ctldir, fencedir = os.environ.get("NO_DOCKER_CTL", ""), os.environ.get("NO_DOCKER_FENCE", "")
    print(f"no-docker: info uids {status().get('Uid', '?')}; gids {status().get('Gid', '?')}")
    passed = gated(lambda: observe_gate(ctldir, fencedir), lambda o: evaluate_gate(o, name, ctldir, fencedir),
                   lambda: None, report)
    fence = fence_check(fencedir) if fencedir else {}
    fence["twin"] = twin_check()
    for p, t in eval_fence(fence, os.getuid()):
        report(p, t)
    if passed and ok:
        after_gate_linux()
        engine_check()
    else:
        report(False, "the after-gate checks did not run (an earlier check failed)")
    # G8, last: nothing below opens a descriptor that the command inherits.
    for p, t in eval_fds(observe_fds()):
        report(p, t)
    if not ok:
        print("no-docker: refused: the isolation could not be proven; the command was not run")
        return EX_REFUSED
    try:
        for sig in signal.valid_signals():
            if sig not in (signal.SIGKILL, signal.SIGSTOP):
                signal.signal(sig, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        started = os.environ.pop("NO_DOCKER_STARTED")
        os.close(os.open(started, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600))
    except (OSError, ValueError, KeyError) as e:
        print(f"no-docker: refused: cannot start the command ({type(e).__name__}: {e}); the command was not run")
        return EX_REFUSED
    for v in ("NO_DOCKER_CTL", "NO_DOCKER_FENCE"):
        os.environ.pop(v, None)
    print(f"no-docker: info the gate passed in {time.monotonic() - began:.2f}s (pid {os.getpid()})")
    sys.stderr.flush()
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        print(f"no-docker: cannot run {cmd[0]}: {e.strerror}")
        return 127 if e.errno == errno.ENOENT else 126


def parse_root_exec(args):
    """(uid, gid, name, env, cmd) of `UID GID NAME -- ENV... -- CMD...`;
    ValueError for anything else."""
    if len(args) < 6 or args[3] != "--" or "--" not in args[4:]:
        raise ValueError("expected UID GID NAME -- NAME=VALUE... -- COMMAND...")
    uid, gid, name = args[:3]
    if not (uid.isdigit() and gid.isdigit() and int(uid) > 0 and int(gid) > 0):
        raise ValueError(f"not an unprivileged uid and gid: {uid} {gid}")
    if not NAME_RE.fullmatch(name):
        raise ValueError(f"not a profile name: {name!r}")
    rest = args[4:]
    i = rest.index("--")
    env, cmd = rest[:i], rest[i + 1:]
    if not cmd or not all(ENV_RE.fullmatch(e) for e in env):
        raise ValueError("a malformed environment entry or no command")
    return uid, gid, name, env, cmd


def root_exec(args):
    """--root-exec UID GID NAME -- ENV... -- CMD...: as root inside the
    namespaces (a child of pid 1): close every descriptor above 2 and show
    that none is left, make fd 0 /dev/null opened here, then exec the chain
    that drops the credentials, attaches NAME and runs the gate."""
    try:
        uid, gid, name, env, cmd = parse_root_exec(args)
    except ValueError as e:
        print(f"no-docker: refused: --root-exec: {e}", file=sys.stderr)
        return EX_REFUSED
    _, before = list_fds()
    hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
    # No descriptor can be above the kernel's nr_open limit (at most 2^30).
    os.closerange(3, hard if 0 <= hard < 1 << 30 else 1 << 30)
    _, after = list_fds()
    fd = os.open("/dev/null", os.O_RDONLY)
    if fd != 0:
        os.dup2(fd, 0, inheritable=True)
        os.close(fd)
    else:
        os.set_inheritable(0, True)
    stdin = fd_kind(0)
    proceed, closed, findings = eval_root_fds(before, after, stdin)
    remaining = [str(f) for f, k in list_fds()[1] if f < 3 and k != "closed"]
    print(f"no-docker: closed: {' '.join(map(str, closed)) or '(none)'}; remaining: {' '.join(remaining)}; "
          f"stdin {'char 1:3' if stdin == '/dev/null' else stdin}", file=sys.stderr)
    for p, t in findings:
        if not p:
            print(f"no-docker: FAIL {t}", file=sys.stderr)
    if not proceed:
        print("no-docker: refused: the descriptors could not be cleaned; the command was not run", file=sys.stderr)
        return EX_REFUSED
    chain = [SETPRIV, "--reuid", uid, "--regid", gid, "--clear-groups", "--no-new-privs", "--inh-caps=-all",
             "--bounding-set=-all", "--", AA_EXEC, "-p", name, "--", SETSID, "--wait", ENV, "-i", *env,
             PYTHON, "-I", os.path.abspath(__file__), "--gate-exec", "--", *cmd]
    sys.stderr.flush()
    try:
        os.execv(SETPRIV, chain)
    except OSError as e:
        print(f"no-docker: refused: cannot run {SETPRIV}: {e.strerror}", file=sys.stderr)
        return EX_REFUSED


def listening_ports(strict=False):
    """(host, port) of listening TCP ports.

    strict (macOS): raise instead of returning a list that may be
    incomplete. The list is accepted, even empty, only if netstat succeeded,
    printed its column header and every LISTEN row has a parsable local
    address. Every address counts (loopback, all, link-local or another):
    no-docker.sh holds the port number."""
    ports = set()
    if sys.platform == "darwin":
        try:
            run = subprocess.run(["netstat", "-an", "-p", "tcp"], capture_output=True, text=True, timeout=10)
            if run.returncode != 0:
                raise OSError(f"netstat exited with {run.returncode}")
            out = run.stdout
            if strict and not any(line.split()[:4] == ["Proto", "Recv-Q", "Send-Q", "Local"]
                                  for line in out.splitlines()):
                raise OSError("netstat printed no column header")
        except (OSError, subprocess.SubprocessError):
            if strict:
                raise
            out = ""
        for line in out.splitlines():
            f = line.split()
            if not f or f[-1] != "LISTEN":
                continue
            host, _, port = f[3].rpartition(".") if len(f) >= 6 else ("", "", "")
            if not host or not port.isdigit():
                if strict:
                    raise OSError(f"unparsable netstat LISTEN row: {line.strip()}")
                continue
            ports.add(("::1" if ":" in host else "127.0.0.1", int(port)))
    else:
        for name in ("/proc/net/tcp", "/proc/net/tcp6"):
            try:
                with open(name) as f:
                    next(f)
                    for line in f:
                        local, state = line.split()[1], line.split()[3]
                        if state == "0A":
                            ports.add(("::1" if name.endswith("6") else "127.0.0.1", int(local.rsplit(":", 1)[1], 16)))
            except OSError:
                pass
    return ports


def endpoints():
    home = os.path.expanduser("~")
    uid = os.getuid()
    unix = {
        "/var/run/docker.sock",
        "/run/docker.sock",
        "/run/containerd/containerd.sock",
        "/run/podman/podman.sock",
        f"/run/user/{uid}/docker.sock",
        f"/run/user/{uid}/podman/podman.sock",
        f"{home}/.docker/run/docker.sock",
        f"{home}/.docker/desktop/docker.sock",
        f"{home}/.colima/default/docker.sock",
        f"{home}/.orbstack/run/docker.sock",
        f"{home}/.rd/docker.sock",
        f"{home}/Library/Containers/com.docker.docker/Data/docker.raw.sock",
        f"{home}/Library/Containers/com.docker.docker/Data/docker-cli.sock",
    }
    tcp = {("127.0.0.1", 2375), ("127.0.0.1", 2376), ("::1", 2375), ("::1", 2376)}
    tcp.update(listening_ports())
    hosts = [os.environ.get("NO_DOCKER_ORIGINAL_HOST", ""), os.environ.get("DOCKER_HOST", "")]
    for meta in glob.glob(f"{home}/.docker/contexts/meta/*/meta.json"):
        try:
            with open(meta) as f:
                hosts.append(json.load(f)["Endpoints"]["docker"]["Host"])
        except (OSError, ValueError, KeyError, TypeError):
            pass
    for h in hosts:
        if h.startswith("unix://"):
            unix.add(h[len("unix://"):])
        elif h.startswith("tcp://"):
            hostport = h[len("tcp://"):].split("/", 1)[0]
            host, _, port = hostport.rpartition(":")
            if host and port.isdigit():
                tcp.add((host.strip("[]"), int(port)))
    roots = ["/run", "/var/run", "/tmp", os.environ.get("TMPDIR", ""), f"{home}/.docker",
             f"{home}/Library/Containers/com.docker.docker/Data"]
    try:
        unix.update(walk_sockets(roots))
    except WalkLimit as e:
        if sys.platform != "darwin":
            raise
        # The sandbox denies every Unix socket connect (checked first); the
        # walk is a second line only. Said, not hidden.
        print(f"no-docker: info socket walk incomplete, {e}; Unix sockets are denied by the sandbox")
    return sorted(unix), sorted(tcp)


def main():
    if sys.argv[1:] == ["--listening"]:
        # For no-docker.sh, before the isolation: the ports to deny inside it.
        try:
            ports = listening_ports(strict=True)
        except (OSError, subprocess.SubprocessError) as e:
            print(f"no-docker: cannot list the listening ports: {e}", file=sys.stderr)
            return 1
        print("\n".join(sorted({str(port) for _, port in ports}, key=int)))
        return 0
    if sys.platform == "darwin" and (sys.argv[1:2] == ["--markers"] and len(sys.argv) == 4
                                     or sys.argv[1:2] in (["--orphans"], ["--end"]) and len(sys.argv) == 3):
        try:
            if sys.argv[1] == "--markers":
                return darwin_markers(sys.argv[2], sys.argv[3])
            if sys.argv[1] == "--orphans":
                return darwin_orphans(sys.argv[2])
            sbx = Sandboxes(sys.argv[2])
            try:
                alive = owner_alive(sbx, sys.argv[2])
            except FileNotFoundError:
                alive = False
            if alive:
                raise OSError(f"the run of {sys.argv[2]} is still in progress (its owner runs); not ending it")
            try:
                gone_owner = owner_record(sys.argv[2])[1]
            except FileNotFoundError:
                gone_owner = None
            n = sweep(sbx, 10.0, kill=True, owner=gone_owner)[0]
            shutil.rmtree(sys.argv[2], ignore_errors=True)
            print(f"no-docker: ended {n} processes; none is left", file=sys.stderr)
            return 0
        except OSError as e:
            print(f"no-docker: cannot check the processes of the isolation: {e}", file=sys.stderr)
            return 1
    if sys.platform == "darwin" and sys.argv[1:2] == ["--supervise"] and len(sys.argv) > 6 and sys.argv[5] == "--":
        return darwin_supervise(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[6:])
    if sys.argv[1:2] == ["--root-exec"] and sys.platform.startswith("linux"):
        try:
            return root_exec(sys.argv[2:])
        except Exception as e:  # nothing was run
            print(f"no-docker: refused: --root-exec failed ({type(e).__name__}: {e})", file=sys.stderr)
            return EX_REFUSED
    if sys.argv[1:3] == ["--gate-exec", "--"] and len(sys.argv) > 3 and sys.platform.startswith("linux"):
        try:
            return gate_exec(sys.argv[3:])
        except Exception as e:  # any doubt: the command does not run
            print(f"no-docker: refused: the gate failed ({type(e).__name__}: {e}); the command was not run",
                  file=sys.stderr)
            return EX_REFUSED
    if sys.argv[1:2] == ["--seal"] and len(sys.argv) == 3:
        try:
            return seal(sys.argv[2])
        except OSError as e:
            print(f"no-docker: cannot make the mounts read-only: {e}", file=sys.stderr)
            return 1
    if sys.argv[1:]:
        print(f"no-docker: unknown arguments {' '.join(sys.argv[1:])}", file=sys.stderr)
        return 2
    try:
        if sys.platform == "darwin":
            check_mechanism_darwin()
        elif sys.platform.startswith("linux"):
            check_mechanism_linux()
        else:
            report(False, f"no isolation mechanism for platform {sys.platform}")
    except OSError as e:
        report(False, f"the isolation check failed: {e}")
    if not ok:
        # Not isolated: do not send anything to an engine that may answer.
        return 1
    engine_check()
    return 0 if ok else 1


def engine_check():
    """No container engine answers on any endpoint endpoints() finds. Run
    only once the mechanism checks passed."""
    try:
        unix, tcp = endpoints()
    except WalkLimit as e:
        report(False, f"every socket of the walked directories was checked ({e})")
        return

    def ask(target):
        kind, addr = target
        try:
            if kind == "unix":
                a = engine_answers(socket.AF_UNIX, addr)
            else:
                a = engine_answers(socket.AF_INET6 if ":" in addr[0] else socket.AF_INET, addr, 1)
        except OSError:
            a = None
        if not a:
            return None
        return f"unix://{addr} ({a})" if kind == "unix" else f"tcp://{addr[0]}:{addr[1]} ({a})"

    targets = [("unix", p) for p in unix] + [("tcp", t) for t in tcp]
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        found = [r for r in pool.map(ask, targets) if r]
    report(not found, f"no container engine answers on {len(unix)} socket and {len(tcp)} TCP endpoints"
           + (": " + ", ".join(found) if found else ""))


if __name__ == "__main__":
    sys.exit(main())
