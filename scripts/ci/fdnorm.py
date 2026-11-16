"""Start an isolated CI suite with no descriptor above 2.

Usage: python3 -I scripts/ci/fdnorm.py -- COMMAND

Steps of GitHub-hosted jobs were seen to inherit open pipes above fd 2 (two
pipes on fds 142 and 145 in run 41636839721). Which process opened them is
not known. The isolation launcher refuses any descriptor it did not open
itself (ADR-023), so each isolated step of .github/workflows/ci.yml starts
through this program. It changes nothing in the launcher or in what the
launcher, --root-exec or the gate check, and it is not an isolation: COMMAND
still has to isolate itself (scripts/ci/tests/ci-isolation-order.py).

In this process, which then becomes COMMAND (same pid):
  0. on Linux, its start time (field 22 of /proc/self/stat) must be read
     and be a positive decimal number, else refused (off Linux, where
     this program runs only for local tests, it is reported as "-");
  1. fds 0, 1 and 2 must be open and not close-on-exec; every open
     descriptor is listed from /proc/self/fd (macOS, for local tests:
     /dev/fd) and examined with fstat and fcntl. A listing that fails, a
     name that is not a decimal number, more than MAX_FDS open
     descriptors, an fstat or fcntl error other than the listing's own
     (already closed) descriptor answering EBADF, or more than one such
     descriptor: refused;
  2. the hard RLIMIT_NOFILE must be a finite integer from 3 to MAX_LIMIT,
     and above every open descriptor: else refused (closerange below
     would leave a descriptor at or above it open);
  3. os.closerange(3, that limit): every descriptor above 2, no list of
     numbers kept;
  4. the descriptors are listed and examined again as in 1: only 0, 1 and
     2 may be open, each with the file type, device, inode, device
     number, status flags and descriptor flags it had in 1; else refused;
  5. the two listings are written to fd 2 (lines "ci-fd: ..."; at most
     MAX_OUT bytes, else refused, never cut), then SIGPIPE and SIGXFSZ,
     which the Python runtime ignores, are set back to their default (as
     subprocess does for its children);
  6. COMMAND is executed (os.execvp). Nothing is opened after 4.

A refusal is reported on fd 2 and ends with status 2; COMMAND is not
run. If COMMAND cannot be executed the status is 127. Reported per
descriptor: number, file type, device, inode, device number of a device,
access mode, O_APPEND, O_NONBLOCK and close-on-exec; for the process: its
pid, parent pid, uids and start time (Linux). Nothing else: no path a
descriptor names, no data, no environment, no argument, no other process.
A descriptor the caller marked close-on-exec was closed when Python
started, so it is neither listed nor reported as closed here. Which
process opened an inherited descriptor is not shown and not claimed.
"""

import errno
import fcntl
import os
import resource
import signal
import stat
import sys
import warnings  # noqa: F401  os.execvp imports it while searching PATH: loaded before step 1

PREFIX = b"ci-fd: "
MAX_FDS = 1024
MAX_OUT = 1 << 18
MAX_LIMIT = 1 << 30
LINUX = os.path.isdir("/proc/self/fd")
FDDIR = "/proc/self/fd" if LINUX else "/dev/fd"
STAT = "/proc/self/stat" if LINUX else None  # off Linux: no start time (local tests)
TYPES = ((stat.S_ISFIFO, "fifo"), (stat.S_ISSOCK, "socket"), (stat.S_ISREG, "file"), (stat.S_ISCHR, "char"),
         (stat.S_ISDIR, "dir"), (stat.S_ISBLK, "block"), (stat.S_ISLNK, "link"))
ACCESS = {os.O_RDONLY: "r", os.O_WRONLY: "w", os.O_RDWR: "rw"}


class Refused(Exception):
    pass


class System:
    """The calls this program makes; the tests replace them."""

    listdir = staticmethod(os.listdir)
    fstat = staticmethod(os.fstat)
    closerange = staticmethod(os.closerange)
    write = staticmethod(os.write)
    execvp = staticmethod(os.execvp)
    signal = staticmethod(signal.signal)

    @staticmethod
    def flags(fd):
        return fcntl.fcntl(fd, fcntl.F_GETFL), fcntl.fcntl(fd, fcntl.F_GETFD)

    @staticmethod
    def hard_limit():
        return resource.getrlimit(resource.RLIMIT_NOFILE)[1]

    @staticmethod
    def process():
        """This process's identity; on Linux its start time is required."""
        start = "-"
        if STAT is not None:
            try:
                with open(STAT, "rb") as f:
                    data = f.read(4096)
            except OSError as e:
                raise Refused("cannot read %s (%s)" % (STAT, errname(e)))
            fields = data.rsplit(b")", 1)[1].split() if b")" in data else []
            field = fields[19] if len(fields) > 19 else b""  # field 22: the fields after the name start at 3
            if not (field.isdigit() and field[:1] != b"0" and len(field) <= 20):
                raise Refused("no start time in %s (field 22 is not a positive decimal number)" % STAT)
            start = field.decode("ascii")
        r, e = os.getuid(), os.geteuid()
        return "pid %d ppid %d uid %d euid %d start %s" % (os.getpid(), os.getppid(), r, e, start)


def errname(e):
    return errno.errorcode.get(e.errno, str(e.errno))


def describe(st, fl, fdfl):
    """The reported identity of one descriptor (a tuple, compared in 4)."""
    kind = next((name for test, name in TYPES if test(st.st_mode)), "other")
    rdev = st.st_rdev if kind in ("char", "block") else None
    return (kind, st.st_dev, st.st_ino, rdev, fl, fdfl)


def row(fd, ident):
    kind, dev, ino, rdev, fl, fdfl = ident
    extra = [] if rdev is None else ["rdev %d" % rdev]
    flags = [n for n, b in (("append", os.O_APPEND), ("nonblock", os.O_NONBLOCK)) if fl & b]
    return "fd %d: %s, dev %d, ino %d%s, %s%s, cloexec %d" % (
        fd, kind, dev, ino, "".join(", " + x for x in extra), ACCESS.get(fl & os.O_ACCMODE, "?"),
        "".join(", " + x for x in flags), 1 if fdfl & fcntl.FD_CLOEXEC else 0)


def listing(system):
    """{fd: identity} of every open descriptor of this process."""
    try:
        names = system.listdir(FDDIR)
    except OSError as e:
        raise Refused("cannot list %s (%s)" % (FDDIR, errname(e)))
    if len(names) > MAX_FDS + 1:
        raise Refused("%d descriptors listed, more than %d" % (len(names), MAX_FDS))
    found, gone = {}, []
    for name in names:
        if not (isinstance(name, str) and name.isascii() and name.isdigit()):
            raise Refused("%r in %s is not a descriptor number" % (name, FDDIR))
        fd = int(name)
        try:
            st = system.fstat(fd)
        except OSError as e:
            if e.errno == errno.EBADF and fd > 2:
                gone.append(fd)
                continue
            raise Refused("fd %d cannot be examined (fstat: %s)" % (fd, errname(e)))
        try:
            fl, fdfl = system.flags(fd)
        except OSError as e:
            raise Refused("fd %d cannot be examined (fcntl: %s)" % (fd, errname(e)))
        found[fd] = describe(st, fl, fdfl)
    if len(gone) > 1:
        raise Refused("fds %s were listed but are closed (only the listing's own may be)" % sorted(gone))
    if len(found) > MAX_FDS:
        raise Refused("%d descriptors open, more than %d" % (len(found), MAX_FDS))
    return found


def write_all(system, data):
    while data:
        n = system.write(2, data)
        if n <= 0:
            raise OSError(errno.EIO, "short write")
        data = data[n:]


def report(system, lines):
    """Write LINES to fd 2, all of them or (more than MAX_OUT bytes) none."""
    text = b"".join(PREFIX + line.encode("ascii", "backslashreplace") + b"\n" for line in lines)
    if len(text) > MAX_OUT:
        raise Refused("the report would be %d bytes, more than %d" % (len(text), MAX_OUT))
    write_all(system, text)


def normalize(argv, lines, system=System):
    """Steps 1 to 5, the report collected in LINES; returns COMMAND.
    Raises Refused, or OSError if the report cannot be written."""
    if len(argv) < 3 or argv[1] != "--":
        raise Refused("usage: fdnorm.py -- COMMAND [ARG...]")
    command = argv[2:]
    lines.append("before: " + system.process())
    before = listing(system)
    lines += [row(fd, before[fd]) for fd in sorted(before)]
    for fd in (0, 1, 2):
        if fd not in before:
            raise Refused("fd %d is not open" % fd)
        if before[fd][5] & fcntl.FD_CLOEXEC:
            raise Refused("fd %d is close-on-exec" % fd)
    limit = system.hard_limit()
    if type(limit) is not int or limit == resource.RLIM_INFINITY or not 3 <= limit <= MAX_LIMIT:
        raise Refused("the hard RLIMIT_NOFILE (%r) is not a finite number from 3 to %d" % (limit, MAX_LIMIT))
    high = sorted(fd for fd in before if fd >= limit)
    if high:
        raise Refused("fds %s are at or above the hard RLIMIT_NOFILE %d" % (high, limit))
    system.closerange(3, limit)
    after = listing(system)
    left = sorted(fd for fd in after if fd > 2)
    if left:
        raise Refused("fds %s are still open" % left)
    for fd in (0, 1, 2):
        if after.get(fd) != before[fd]:
            raise Refused("fd %d changed" % fd)
    closed = sorted(fd for fd in before if fd > 2)
    lines += ["after: " + row(fd, after[fd]) for fd in (0, 1, 2)]
    lines.append("closed %s (up to the hard limit %d); open now: 0 1 2, as before; executing the command"
                 % (" ".join(map(str, closed)) or "none", limit))
    report(system, lines)
    system.signal(signal.SIGPIPE, signal.SIG_DFL)
    system.signal(signal.SIGXFSZ, signal.SIG_DFL)
    return command


def main(argv, system=System):
    lines = []
    try:
        command = normalize(argv, lines, system)
    except Refused as e:
        refusal = "refused: %s; the command was not run" % e
        try:
            report(system, lines + [refusal])
        except (Refused, OSError):
            try:
                report(system, [refusal])
            except (Refused, OSError):
                pass
        return 2
    except OSError:
        return 2
    try:
        system.execvp(command[0], command)
    except OSError as e:
        system.signal(signal.SIGPIPE, signal.SIG_IGN)
        try:
            report(system, ["the command could not be executed (%s)" % errname(e)])
        except (Refused, OSError):
            pass
        return 127
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv))
