"""Show that nothing of an isolated launch is left (WI-9 R2; Linux, as root).

Usage: sudo -n /usr/bin/python3 -I residual.py RUNNER_TEMP

One line per check, then exit 0 only if every check could be made completely
and found nothing:
  - no profile named flowcrm-nd-... is loaded (the profile list, read to its
    end: the kernel hands it out about a page per read);
  - no task carries such a profile (every task's attr/apparmor/current, read
    in one read; a read that fills the buffer may have cut the label);
  - no control or fence directory of a launch is left in RUNNER_TEMP;
  - no fence listener runs (every process's command line).
A task or process that ended while being read (ENOENT or ESRCH, and an
lstat of its /proc directory then fails with ENOENT) is skipped; any other
error, one while its /proc directory still exists, or a follow-up lstat that
fails otherwise (EACCES, EIO, ...), is unknown, and unknown fails.
"""

import errno
import os
import sys

PROFILES = "/sys/kernel/security/apparmor/profiles"
PREFIX = "flowcrm-nd-"
LABEL_MAX = 1 << 16


class Unknown(Exception):
    """A check could not be made completely."""


class System:
    """What the checks read; the tests replace it."""

    def read_all(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            parts = []
            while True:
                b = os.read(fd, 1 << 16)
                if not b:
                    return b"".join(parts)
                parts.append(b)
        finally:
            os.close(fd)

    def read_once(self, path, limit):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            return os.read(fd, limit)
        finally:
            os.close(fd)

    def listdir(self, path):
        return os.listdir(path)

    def gone(self, path):
        """True if lstat finds no path (ENOENT), False if it finds one; any
        other error is raised."""
        try:
            os.lstat(path)
        except FileNotFoundError:
            return True
        return False


def ended(sys_, e, path):
    """True only if e says the task ended (ENOENT or ESRCH) and an lstat of
    its /proc directory confirms it is gone; an lstat that fails otherwise
    leaves it unknown."""
    if not (isinstance(e, OSError) and e.errno in (errno.ENOENT, errno.ESRCH)):
        return False
    try:
        return sys_.gone(path)
    except OSError:
        return False


def pids(sys_):
    try:
        return sorted(d for d in sys_.listdir("/proc") if d.isdigit())
    except OSError as e:
        raise Unknown(f"/proc cannot be listed ({e.strerror})")


def loaded(sys_):
    try:
        text = sys_.read_all(PROFILES).decode("utf-8", "replace")
    except OSError as e:
        raise Unknown(f"the profile list cannot be read ({e.strerror})")
    return [line for line in text.splitlines() if line.startswith(PREFIX)]


def carriers(sys_):
    try:
        if len(sys_.read_once("/proc/self/attr/apparmor/current", LABEL_MAX)) >= LABEL_MAX:
            raise Unknown("this process's label fills the read buffer")
    except OSError as e:
        raise Unknown(f"this process's label cannot be read ({e.strerror})")
    found, unknown = [], []
    for pid in pids(sys_):
        try:
            tids = sorted(t for t in sys_.listdir(f"/proc/{pid}/task") if t.isdigit())
        except OSError as e:
            if not ended(sys_, e, f"/proc/{pid}"):
                unknown.append(f"{pid} ({e.strerror})")
            continue
        for tid in tids:
            path = f"/proc/{pid}/task/{tid}/attr/apparmor/current"
            try:
                label = sys_.read_once(path, LABEL_MAX)
            except OSError as e:
                if not ended(sys_, e, f"/proc/{pid}/task/{tid}"):
                    unknown.append(f"{pid}/{tid} ({e.strerror})")
                continue
            if len(label) >= LABEL_MAX:
                unknown.append(f"{pid}/{tid} (label may be cut)")
            elif PREFIX.encode() in label:
                found.append(f"{pid}/{tid}")
    if unknown:
        raise Unknown("labels unreadable: " + " ".join(unknown[:10]))
    return found


def directories(sys_, runner_temp):
    try:
        names = sys_.listdir(runner_temp)
    except OSError as e:
        raise Unknown(f"{runner_temp} cannot be listed ({e.strerror})")
    return sorted(n for n in names if n.startswith(("no-docker-ctl.", "no-docker-fence.")))


def listeners(sys_):
    found, unknown = [], []
    for pid in pids(sys_):
        try:
            argv = sys_.read_all(f"/proc/{pid}/cmdline")
        except OSError as e:
            if not ended(sys_, e, f"/proc/{pid}"):
                unknown.append(f"{pid} ({e.strerror})")
            continue
        if b"no-docker-fence." in argv and str(os.getpid()) != pid:
            found.append(pid)
    if unknown:
        raise Unknown("command lines unreadable: " + " ".join(unknown[:10]))
    return found


CHECKS = (
    ("no flowcrm-nd- profile is loaded", lambda s, t: loaded(s)),
    ("no task carries a flowcrm-nd- profile", lambda s, t: carriers(s)),
    ("no control or fence directory is left in RUNNER_TEMP", lambda s, t: directories(s, t)),
    ("no fence listener runs", lambda s, t: listeners(s)),
)


def main(argv, sys_=None):
    if len(argv) != 1 or not argv[0].startswith("/"):
        print("usage: residual.py RUNNER_TEMP", file=sys.stderr)
        return 2
    sys_ = sys_ or System()
    good = True
    for text, check in CHECKS:
        try:
            found = check(sys_, argv[0])
        except Unknown as e:
            print(f"wi9-r2: FAIL {text}: unknown: {e}")
            good = False
            continue
        if found:
            print(f"wi9-r2: FAIL {text}: {len(found)} found: {' '.join(found[:10])}")
            good = False
        else:
            print(f"wi9-r2: ok   {text}")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
