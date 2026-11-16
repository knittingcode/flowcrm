"""Unit tests of scripts/ci/fdnorm.py.

Usage: fdnorm-unit.py PATH_TO_FDNORM

Prints one "ok"/"FAIL" line per assertion and a SUMMARY line; exit 0 if all
pass. The commands it starts are this Python printing its own descriptors.
"""

import errno
import importlib.util
import os
import stat
import subprocess
import sys

path = os.path.abspath(sys.argv[1])
spec = importlib.util.spec_from_file_location("fdnorm", path)
fdnorm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fdnorm)

passed = failed = 0
PY = sys.executable
FDDIR = fdnorm.FDDIR
# Prints the descriptors COMMAND has, without the listing's own.
LIST = ("import os\n"
        f"names = os.listdir({FDDIR!r})\n"
        "def live(n):\n"
        "    try:\n"
        "        os.fstat(int(n)); return True\n"
        "    except OSError:\n"
        "        return False\n"
        "print(' '.join(sorted((n for n in names if live(n)), key=int)))\n")


def check(cond, text):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
    print(f"{'ok  ' if cond else 'FAIL'} {text}")


def run(args, **kw):
    return subprocess.run([PY, "-I", path] + args, capture_output=True, text=True, **kw)


# --- real runs
r, w = os.pipe()
high = os.dup2(r, 142, inheritable=True)
p = run(["--", PY, "-I", "-c", LIST], pass_fds=(142,))
check(p.returncode == 0, f"a command runs with an inherited pipe above 2 (rc {p.returncode})")
check(p.stdout.split() == ["0", "1", "2"], f"the command has only 0 1 2 (got {p.stdout.strip()!r})")
check("closed 142" in p.stderr, "the closed descriptor is reported")
check(p.stderr.startswith("ci-fd: before: "), "the report has its prefix")
check("/" not in p.stderr, "the report names no path")
os.close(high)
os.close(r)
os.close(w)

p = run(["--", PY, "-I", "-c", LIST])
check(p.returncode == 0 and p.stdout.split() == ["0", "1", "2"], "with nothing to close the command still runs")

p = run(["--", PY, "-I", "-c", "import sys; sys.exit(7)"])
check(p.returncode == 7, f"the command's own status is returned (rc {p.returncode})")

child = subprocess.Popen([PY, "-I", path, "--", PY, "-I", "-c", "import os; print(os.getpid())"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
out = child.communicate()[0].strip()
check(out == str(child.pid), f"the command replaces the wrapper, same pid ({out} and {child.pid})")

for args, label in (([], "no arguments"), (["--"], "no command"), ([PY], "no --"), ([PY, "--", "x"], "-- not first")):
    p = run(args)
    check(p.returncode == 2, f"usage refused, {label} (rc {p.returncode})")
    check("the command was not run" in p.stderr, f"the refusal says the command did not run, {label}")

p = run(["--", "/nonexistent/fdnorm-test-command"])
check(p.returncode == 127, f"a command that cannot be executed is 127 (rc {p.returncode})")

p = subprocess.run([PY, "-I", path, "--", PY, "-I", "-c", "print('ran')"], capture_output=True, text=True,
                   stdin=subprocess.DEVNULL, preexec_fn=lambda: os.close(0))
check(p.returncode == 2 and "ran" not in p.stdout, f"a closed fd 0 is refused (rc {p.returncode})")


# --- the failure paths, through a replaced System
def identity(fd):
    return os.stat_result((stat.S_IFIFO | 0o600, 100 + fd, 1, 1, 0, 0, 0, 0, 0, 0))


class Fake(fdnorm.System):
    """Three standard descriptors plus OPEN, until closerange runs."""

    def __init__(self):
        self.open = {0, 1, 2, 142}
        self.closed = False
        self.ran = None
        self.out = b""
        self.limit = 1024
        self.keep_after_close = set()
        self.names = None
        self.change = None
        self.flagset = {}
        self.signals = []
        self.fail_write = False
        self.listerr = None
        self.fstaterr = {}
        self.fcntlerr = {}

    def listdir(self, _):
        if self.listerr:
            raise OSError(self.listerr, "x")
        return list(self.names) if self.names is not None else [str(fd) for fd in sorted(self.open)]

    def fstat(self, fd):
        if fd in self.fstaterr:
            raise OSError(self.fstaterr[fd], "x")
        if fd not in self.open:
            raise OSError(errno.EBADF, "x")
        return identity(fd + (1000 if self.closed and self.change == fd else 0))

    def flags(self, fd):
        if fd in self.fcntlerr:
            raise OSError(self.fcntlerr[fd], "x")
        return self.flagset.get(fd, (os.O_RDWR, 0))

    def closerange(self, low, high):
        self.closed = True
        self.open = {fd for fd in self.open if fd < low or fd >= high or fd in self.keep_after_close}

    def write(self, fd, data):
        if self.fail_write:
            raise OSError(errno.EPIPE, "x")
        self.out += bytes(data)
        return len(data)

    def execvp(self, name, argv):
        self.ran = argv

    def signal(self, num, handler):
        self.signals.append(num)

    def hard_limit(self):
        return self.limit

    def process(self):
        return "pid 1 ppid 1 uid 1 euid 1 start -"


ARGV = ["fdnorm.py", "--", "suite"]


f = Fake()
rc = fdnorm.main(ARGV, f)  # the fake exec returns, so main ends as after a failed exec
check(rc == 127, f"after the exec call main returns 127 (status {rc})")
check(f.ran == ["suite"], "COMMAND is what is executed")
check(b"closed 142" in f.out, "142 is reported closed")

for label, setup in (
    ("a listing that fails", lambda f: setattr(f, "listerr", errno.EACCES)),
    ("a name that is not a number", lambda f: setattr(f, "names", ["0", "1", "2", "x"])),
    ("a descriptor kept open after closerange", lambda f: f.keep_after_close.add(142)),
    ("an fstat error", lambda f: f.fstaterr.__setitem__(142, errno.EIO)),
    ("an EBADF on fd 1", lambda f: f.fstaterr.__setitem__(1, errno.EBADF)),
    ("an fcntl error", lambda f: f.fcntlerr.__setitem__(142, errno.EIO)),
    ("fd 2 missing", lambda f: f.open.discard(2)),
    ("fd 1 close-on-exec", lambda f: f.flagset.__setitem__(1, (os.O_RDWR, 1))),
    ("an infinite limit", lambda f: setattr(f, "limit", fdnorm.resource.RLIM_INFINITY)),
    ("a limit below 3", lambda f: setattr(f, "limit", 2)),
    ("a limit above the maximum", lambda f: setattr(f, "limit", fdnorm.MAX_LIMIT + 1)),
    ("a limit that is not an integer", lambda f: setattr(f, "limit", 1.5)),
    ("a descriptor at the limit", lambda f: setattr(f, "limit", 142)),
    ("a standard descriptor that changes", lambda f: setattr(f, "change", 1)),
    ("too many descriptors", lambda f: setattr(f, "names", [str(n) for n in range(fdnorm.MAX_FDS + 2)])),
):
    f = Fake()
    setup(f)
    rc = fdnorm.main(ARGV, f)
    check(rc == 2 and f.ran is None, f"refused: {label} (status {rc}, ran {f.ran})")

f = Fake()
f.fail_write = True
rc = fdnorm.main(ARGV, f)
check(rc == 2 and f.ran is None, "a report that cannot be written stops the run")

f = Fake()
f.names = ["0", "1", "2", "9"]
f.fstaterr[9] = errno.EBADF
rc = fdnorm.main(ARGV, f)
check(f.ran == ["suite"], "the listing's own closed descriptor is allowed")

f = Fake()
f.names = ["0", "1", "2", "8", "9"]
f.fstaterr[8] = f.fstaterr[9] = errno.EBADF
rc = fdnorm.main(ARGV, f)
check(rc == 2 and f.ran is None, "two closed descriptors in a listing are refused")

f = Fake()
fdnorm.main(ARGV, f)
check(fdnorm.signal.SIGPIPE in f.signals and fdnorm.signal.SIGXFSZ in f.signals, "SIGPIPE and SIGXFSZ are reset")

src = open(path, encoding="utf-8").read()
check("no-docker" not in src, "the wrapper does not name the launcher's script")
code = src[src.index("import errno"):]
check("execvp" in code and "import subprocess" not in code and "os.fork" not in code and "os.system" not in code,
      "the wrapper executes COMMAND and starts no child")

print(f"SUMMARY {passed} ok, {failed} failed")
sys.exit(0 if failed == 0 else 1)
