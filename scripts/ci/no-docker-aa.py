"""The AppArmor profile of one Linux launch of scripts/ci/no-docker.sh.

Run as root through sudo by no-docker.sh only, in these argv shapes
(sudo -n timeout N /usr/bin/python3 -I <this file> ...):

  preflight                 refuse unless AppArmor can confine the launch:
                            enabled, global mode enforce, the af_unix network
                            class, apparmor_parser and aa-exec present; print
                            what else matters for the record;
  load NAME CTLDIR          load the pinned production template as NAME
                            (add only, never replace) and record its kernel
                            hash in CTLDIR/hash;
  load-negative-control NEGNAME CTLDIR
                            the same with the pinned negative-control
                            template (attach_disconnected), only for NEGNAME;
  kill-init LAUNCHERPID CTLDIR
                            find pid 1 of the launch's pid namespace from the
                            launcher's process tree, record its namespace in
                            CTLDIR/ns if that is missing, then SIGKILL it
                            through a pidfd; nothing else is ever signalled;
  release NAME|NEGNAME CTLDIR
                            remove the profile only when no task can carry it
                            (P0, P1, P2 and two sweeps); otherwise leave it
                            loaded and fail;
  diag NAME|NEGNAME         print what is known about the profile.

Inputs are the argv, validated, and the two values sudo sets itself,
SUDO_UID and SUDO_USER; no other environment value is read. Exit 0 on
success, 1 when refused or when the profile is left loaded, 2 on a usage
error. Messages go to stderr.

Release (docs/dev-environment.md, "Profile lifecycle"):
  P0  CTLDIR/ns is a root-owned regular file of mode 0444 in the format
      "pid:<inode> mnt:<inode or ->", and its pid namespace is not ours;
  P1  no task is in that pid namespace, except its init as a single-threaded
      zombie: when a pid namespace's init exits, the kernel kills every other
      task of the namespace and lets none be created before init becomes a
      zombie (zap_pid_ns_processes);
  P2  NAME is listed exactly once, in enforce mode, with the kernel hash
      recorded at load time;
  S   two consecutive complete sweeps of every task's
      attr/apparmor/current find no label containing NAME;
  R   NAME is removed and is no longer listed.
State "loading" or "not-forked" with no CTLDIR/ns means no namespace was
ever made: then NAME is removed after P2 and the sweeps, or nothing is done
when it was never loaded. Any error other than a task that ended is unknown,
and unknown means the profile stays loaded.
"""

import errno
import hashlib
import os
import pwd
import re
import signal
import stat
import subprocess
import sys
import time

SECURITYFS = "/sys/kernel/security/apparmor"
PROFILES = SECURITYFS + "/profiles"
REMOVE = SECURITYFS + "/.remove"
POLICY = SECURITYFS + "/policy/profiles"
FEATURES = SECURITYFS + "/features"
PARAMETERS = "/sys/module/apparmor/parameters"
PARSER = "/usr/sbin/apparmor_parser"
AA_EXEC = "/usr/bin/aa-exec"
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = {
    "production": (os.path.join(HERE, "no-docker", "apparmor.profile"),
                   "035a67af7a79fdfd2e9530955f7fba3dfede64bdb5af04651967a8b1d0f2319d"),
    "negative": (os.path.join(HERE, "tests", "no-docker", "apparmor-negative.profile"),
                 "2375d20c5202891297e686ced0976899e36601d9824d475f6f34c204b28ea46e"),
}
NAME_RE = re.compile(r"flowcrm-nd-[0-9a-f]{32}")
NEGNAME_RE = re.compile(r"flowcrm-nd-neg-[0-9a-f]{32}")
CTL_BASE_RE = re.compile(r"no-docker-ctl\.[A-Za-z0-9]{6,}")
USER_RE = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
NS_RE = re.compile(r"pid:([1-9][0-9]{0,19}) mnt:([1-9][0-9]{0,19}|-)\n")
STATE_RE = re.compile(r"(loading|not-forked|entering|entered spid=[1-9][0-9]{0,9})\n")
HASH_RE = re.compile(r"sha256 ([0-9a-f]{64}|none)\n")
# The argv of the sudo that starts the namespaces (no-docker.sh), up to the
# init script.
UNSHARE_ARGV = ["unshare", "--net", "--mount", "--pid", "--fork", "--kill-child", "--mount-proc", "--ipc",
                "--propagation", "private", "--", "/bin/sh", "-c"]
SUDO_ARGV = ["sudo", "-n"] + UNSHARE_ARGV
KILL_INIT_DEADLINE = 8.0
SWEEPS = 2


class Refused(Exception):
    """The operation cannot be done safely; the message says why."""


def say(text):
    print(f"no-docker-aa: {text}", file=sys.stderr, flush=True)


def gone(e):
    """True for the errors of a task that ended meanwhile."""
    return isinstance(e, OSError) and e.errno in (errno.ENOENT, errno.ESRCH)


# --- pure decisions ------------------------------------------------------------

def name_ok(op, name):
    """The profile names each operation accepts."""
    production = NAME_RE.fullmatch(name) is not None
    negative = NEGNAME_RE.fullmatch(name) is not None
    if op == "load":
        return production
    if op == "load-negative-control":
        return negative
    if op in ("release", "diag"):
        return production or negative
    return False


def template_for(op, name):
    """(kind, path, pinned sha256) of the template an operation loads."""
    if op == "load" and name_ok("load", name):
        return ("production",) + TEMPLATES["production"]
    if op == "load-negative-control" and name_ok("load-negative-control", name):
        return ("negative",) + TEMPLATES["negative"]
    raise Refused(f"{op} does not load {name}")


def render(data, kind, sha, name):
    """The profile text for name, from the template bytes data; refused
    unless the bytes are the pinned ones and the result is plain."""
    if hashlib.sha256(data).hexdigest() != sha:
        raise Refused("the template is not the reviewed one (sha256 differs)")
    text = data.decode("ascii").replace("@NAME@", name)
    problems = []
    if "@" in text:
        problems.append("a placeholder is left")
    for token in ("change_profile", "complain", "userns", "include"):
        if token in text:
            problems.append(token)
    if re.search(r"\b[pPcCuU]i?x\b|\bix\b", text):
        problems.append("an exec transition")
    if "attach_disconnected" in text and kind != "negative":
        problems.append("attach_disconnected")
    if kind == "negative" and "flags=(enforce,attach_disconnected)" not in text:
        problems.append("the negative template without attach_disconnected")
    if not re.search(r"^profile " + re.escape(name) + r" flags=\(", text, re.M):
        problems.append("the profile is not named " + name)
    if problems:
        raise Refused("the rendered profile is not plain: " + ", ".join(problems))
    return text


def parse_label(line):
    """(name, mode) of a label or profile list line "NAME (mode)"; (name,
    None) for a label without a mode (unconfined); None if empty."""
    line = line.rstrip("\n")
    if not line.strip():
        return None
    m = re.fullmatch(r"(.+) \(([a-z_]+)\)", line)
    if m:
        return m.group(1), m.group(2)
    return line, None


def listed_modes(text, name):
    """The modes NAME is listed with in the profile list text."""
    modes = []
    for line in text.splitlines():
        label = parse_label(line)
        if label and label[0] == name:
            modes.append(label[1])
    return modes


def preflight_findings(o):
    """(passed, text) for each gating check of the preflight observation o;
    the sysctl values are recorded, not gating."""
    return [
        (o.get("enabled") == "Y", f"AppArmor is enabled ({o.get('enabled')})"),
        (o.get("mode") == "enforce", f"the global mode is enforce ({o.get('mode')})"),
        (o.get("af_unix") is True, f"the kernel mediates af_unix (features/network/af_unix: {o.get('af_unix')})"),
        (o.get("parser") is True, f"{PARSER} is present ({o.get('parser')})"),
        (o.get("aa_exec") is True, f"{AA_EXEC} is present ({o.get('aa_exec')})"),
    ]


def parse_state(text):
    """The launch state CTLDIR/state names; "unknown" for anything else."""
    if text is None or STATE_RE.fullmatch(text) is None:
        return "unknown"
    return text.rstrip("\n").split(" ")[0]


def parse_ns(text):
    """(pid namespace inode, mount namespace inode or None) of CTLDIR/ns;
    ValueError unless it is exactly "pid:<n> mnt:<n or ->" and a newline."""
    m = NS_RE.fullmatch(text)
    if not m:
        raise ValueError(f"not a namespace record: {text[:80]!r}")
    pid, mnt = int(m.group(1)), m.group(2)
    if pid >= 1 << 64 or (mnt != "-" and int(mnt) >= 1 << 64):
        raise ValueError("a namespace inode out of range")
    return pid, None if mnt == "-" else int(mnt)


def ns_record(pid_ino, mnt_ino):
    return f"pid:{pid_ino} mnt:{'-' if mnt_ino is None else mnt_ino}\n"


def release_plan(state, ns_exists):
    """"no-namespace" when no namespace can have been made (the state says
    no fork happened and no namespace was recorded), else "namespace"."""
    if state in ("loading", "not-forked") and not ns_exists:
        return "no-namespace"
    return "namespace"


def p0(rec, host_ino):
    """None if the namespace record rec ({"uid", "mode", "regular", "text"} or
    None if missing) is valid and names another pid namespace, else why not."""
    if rec is None:
        return "no namespace record (CTLDIR/ns)"
    if not rec["regular"] or rec["uid"] != 0 or rec["mode"] != 0o444:
        return f"the namespace record is not a root-owned file of mode 0444 (uid {rec['uid']}, mode {rec['mode']:o})"
    try:
        pid_ino, _ = parse_ns(rec["text"])
    except ValueError as e:
        return str(e)
    if pid_ino == host_ino:
        return "the namespace record names the host's pid namespace"
    return None


def p1(tasks, pid_ino):
    """None if no task is in the pid namespace pid_ino except its init as a
    single-threaded zombie, else why not. tasks: (pid, its pid namespace
    inode or an OSError, its status or an OSError)."""
    found = []
    for pid, ino, st in tasks:
        if isinstance(ino, OSError):
            if not gone(ino):
                return f"task {pid}: its pid namespace cannot be read ({ino.strerror})"
            continue
        if ino != pid_ino:
            continue
        if isinstance(st, OSError):
            if gone(st):
                continue
            return f"task {pid} of the namespace cannot be read ({st.strerror})"
        nspid = st.get("NSpid", "").split()
        init = (len(nspid) >= 2 and nspid[-1] == "1" and st.get("Name") == "sh" and st.get("Threads") == "1"
                and st.get("State", "").startswith("Z"))
        if not init:
            found.append(f"{pid}:{st.get('Name', '?')}:{st.get('State', '?')[:1]}")
    if found:
        return "tasks still in the namespace: " + " ".join(found)
    return None


def p2(modes, hash_now, hash_load):
    """None if NAME is listed once in enforce mode with its load-time hash
    (hash_load: "none" if the kernel exported none at load), else why not."""
    if modes != ["enforce"]:
        return f"the profile vanished or was replaced during the run (listed as {modes or 'nothing'})"
    if hash_load is None:
        return "no load-time hash was recorded"
    if (hash_now or "none") != hash_load:
        return f"the profile's kernel hash changed ({hash_load} at load, {hash_now or 'none'} now)"
    return None


def sweep_result(entries, name):
    """(carriers, unknown) of one sweep. entries: (path, the label or the
    OSError reading it). Any label containing NAME counts (stacked and
    prefixed renderings, and longer names that contain it)."""
    carriers, unknown = [], []
    for path, label in entries:
        if isinstance(label, OSError):
            if not gone(label):
                unknown.append(f"{path} ({label.strerror})")
        elif name in label:
            carriers.append(path)
    return carriers, unknown


def sweeps_clear(sweep, name, count=SWEEPS):
    """None if count consecutive complete sweeps find no carrier, else why."""
    for i in range(count):
        carriers, unknown = sweep_result(sweep(), name)
        if unknown:
            return f"sweep {i + 1} could not read: {' '.join(unknown[:5])}"
        if carriers:
            return f"sweep {i + 1} found {len(carriers)} tasks carrying the profile: {' '.join(carriers[:5])}"
    return None


def parse_stat(text):
    """{"comm", "state", "ppid", "start"} of a /proc/<pid>/stat line."""
    head, _, rest = text.rpartition(")")
    f = rest.split()
    return {"comm": head.partition("(")[2], "state": f[0], "ppid": int(f[1]), "start": int(f[19])}


def ctldir_findings(path, info, real, sudo_uid, sudo_user, user_uid):
    """Why the CTLDIR argument is refused ([] if valid). info: lstat of path
    ({"dir", "link", "uid", "mode"}) or None; real: its realpath; user_uid:
    the uid of sudo_user in the user database (None if unknown)."""
    f = []
    if not path.startswith("/") or os.path.normpath(path) != path:
        f.append("not an absolute canonical path")
    if real != path:
        f.append("a symbolic link in its path")
    if info is None or not info["dir"] or info["link"]:
        f.append("not a directory")
    elif info["mode"] != 0o700 or info["uid"] != sudo_uid:
        f.append(f"not mode 0700 owned by uid {sudo_uid}")
    if not (sudo_user and USER_RE.fullmatch(sudo_user)) or user_uid is None or user_uid != sudo_uid:
        f.append("SUDO_USER and SUDO_UID do not name one user")
    elif os.path.dirname(path) != f"/home/{sudo_user}/work/_temp":
        f.append(f"not in /home/{sudo_user}/work/_temp (the runner's temporary directory)")
    if not CTL_BASE_RE.fullmatch(os.path.basename(path)):
        f.append("its name is not no-docker-ctl.XXXXXX")
    return f


def launcher_findings(launcher, procs, me, sudo_uid):
    """Why LAUNCHERPID is refused ([] if valid): it must be a process of
    SUDO_UID, and walking up from this helper (helper, timeout, sudo, maybe
    sudo's monitor; at most 5 levels) must reach a sudo whose parent it is.
    procs: {pid: {"ppid", "comm", "ruid"}}."""
    p = procs.get(launcher)
    if p is None:
        return ["the launcher does not exist"]
    if p["ruid"] != sudo_uid:
        return [f"the launcher runs as uid {p['ruid']}, not {sudo_uid}"]
    cur = me
    for _ in range(5):
        info = procs.get(cur)
        if info is None:
            break
        cur = info["ppid"]
        up = procs.get(cur)
        if up and up["comm"] == "sudo" and up["ppid"] == launcher:
            return []
    return ["this helper was not started by a sudo of the launcher"]


def find_init(procs, launcher, host_ino, recorded):
    """("found", pid), ("none", why) or ("ambiguous", why): pid 1 of the
    launch's namespace, found from the launcher's process tree. procs: {pid:
    {"ppid", "comm", "argv", "start", "nspid", "pidns"}}; recorded: the
    pid namespace inode of CTLDIR/ns or None."""
    children = {}
    for pid, p in procs.items():
        children.setdefault(p["ppid"], []).append(pid)
    sudos = [c for c in children.get(launcher, []) if procs[c]["comm"] == "sudo"
             and procs[c]["argv"][:len(SUDO_ARGV)] == SUDO_ARGV]
    if not sudos:
        return "none", "no sudo of the launcher starts the namespaces"
    if len(sudos) > 1:
        return "ambiguous", f"{len(sudos)} sudo processes of the launcher start namespaces"
    level, unshares = [sudos[0]], []
    for _ in range(3):
        level = [c for p in level for c in children.get(p, [])]
        unshares += [c for c in level if procs[c]["comm"] == "unshare"
                     and procs[c]["argv"][:len(UNSHARE_ARGV)] == UNSHARE_ARGV]
    if not unshares:
        return "none", "the sudo has not started unshare"
    if len(unshares) > 1:
        return "ambiguous", f"{len(unshares)} unshare processes under the sudo"
    kids = children.get(unshares[0], [])
    if not kids:
        return "none", "unshare has not started pid 1"
    if len(kids) > 1:
        return "ambiguous", f"unshare has {len(kids)} children"
    init = procs[kids[0]]
    if init["pidns"] is None or init["pidns"] == host_ino:
        return "none", "unshare's child is not in a new pid namespace yet"
    if not init["nspid"] or init["nspid"][-1] != "1":
        return "none", f"unshare's child is not pid 1 of its namespace (NSpid {' '.join(init['nspid'])})"
    if recorded is not None and init["pidns"] != recorded:
        return "ambiguous", "unshare's child is not in the recorded pid namespace"
    return "found", kids[0]


# --- what the kernel and the files show (as root) --------------------------------

def read_text(path, limit=1 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        return os.read(fd, limit).decode("utf-8", "replace")
    finally:
        os.close(fd)


def proc_pids():
    return [int(d) for d in os.listdir("/proc") if d.isdigit()]


def ns_inode(pid, kind):
    """The inode of /proc/<pid>/ns/<kind> ("pid:[N]")."""
    link = os.readlink(f"/proc/{pid}/ns/{kind}")
    m = re.fullmatch(kind + r":\[([0-9]+)\]", link)
    if not m:
        raise OSError(f"unexpected namespace link {link!r}")
    return int(m.group(1))


def proc_status(pid):
    st = {}
    for line in read_text(f"/proc/{pid}/status").splitlines():
        k, _, v = line.partition(":")
        st[k] = v.strip()
    return st


def process_table(with_argv=True):
    """{pid: {"ppid", "comm", "argv", "start", "nspid", "pidns", "ruid"}} of
    every process that did not end while being read; any other error
    raises."""
    procs = {}
    for pid in proc_pids():
        try:
            s = parse_stat(read_text(f"/proc/{pid}/stat"))
            st = proc_status(pid)
            argv = read_text(f"/proc/{pid}/cmdline").split("\0")[:-1] if with_argv else []
            try:
                pidns = ns_inode(pid, "pid")
            except OSError as e:
                if not gone(e):
                    raise
                pidns = None
        except OSError as e:
            if gone(e):
                continue
            raise
        procs[pid] = {"ppid": s["ppid"], "comm": s["comm"], "start": s["start"], "argv": argv,
                      "nspid": st.get("NSpid", "").split(), "pidns": pidns,
                      "ruid": int(st.get("Uid", "-1").split()[0])}
    return procs


def still_there(e, path):
    """e, or an error that does not count as "ended" when path (the task's
    /proc directory) still exists: only a task that is gone may be skipped."""
    if gone(e) and os.path.exists(path):
        return OSError(errno.EIO, f"unreadable although {path} exists")
    return e


def pidns_tasks():
    """(pid, pid namespace inode or OSError, status or OSError) of every
    process, for P1."""
    tasks = []
    for pid in proc_pids():
        try:
            ino = ns_inode(pid, "pid")
        except OSError as e:
            tasks.append((pid, still_there(e, f"/proc/{pid}"), None))
            continue
        try:
            st = proc_status(pid)
        except OSError as e:
            st = e
        tasks.append((pid, ino, st))
    return tasks


def label_sweep():
    """(path, label or OSError) of every task's attr/apparmor/current. A
    kernel without that file would make every task look ended: the sweep
    refuses unless it can read its own."""
    read_text("/proc/self/attr/apparmor/current", 4096)
    entries = []
    for pid in proc_pids():
        try:
            tids = [d for d in os.listdir(f"/proc/{pid}/task") if d.isdigit()]
        except OSError as e:
            entries.append((f"/proc/{pid}/task", e))
            continue
        for tid in tids:
            path = f"/proc/{pid}/task/{tid}/attr/apparmor/current"
            try:
                entries.append((path, read_text(path, 4096)))
            except OSError as e:
                entries.append((path, still_there(e, f"/proc/{pid}/task/{tid}")))
    return entries


def profile_list():
    return read_text(PROFILES, 1 << 24)


def kernel_hash(name):
    """The kernel's sha256 of the loaded profile name, or None if it exports
    none."""
    try:
        dirs = os.listdir(POLICY)
    except FileNotFoundError:
        return None
    found = []
    for d in dirs:
        try:
            if read_text(f"{POLICY}/{d}/name", 4096).strip() != name:
                continue
        except FileNotFoundError:
            continue
        try:
            found.append(read_text(f"{POLICY}/{d}/sha256", 4096).strip() or None)
        except FileNotFoundError:
            found.append(None)
    if len(found) > 1:
        raise OSError(f"{name} appears {len(found)} times in the policy tree")
    return found[0] if found else None


class CtlDir:
    """The launch's control directory, opened once (no symbolic link
    followed) and used relative to that descriptor."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def lstat(self, name):
        try:
            return os.lstat(name, dir_fd=self.fd)
        except FileNotFoundError:
            return None

    def read(self, name, limit=4096):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
        try:
            return os.read(fd, limit).decode("utf-8", "replace")
        finally:
            os.close(fd)

    def record(self, name):
        """{"uid", "mode", "regular", "text"} of a file here, None if missing."""
        st = self.lstat(name)
        if st is None:
            return None
        return {"uid": st.st_uid, "mode": stat.S_IMODE(st.st_mode), "regular": stat.S_ISREG(st.st_mode),
                "text": self.read(name) if stat.S_ISREG(st.st_mode) else ""}

    def write_new(self, tmp, final, text, replace):
        """Write text to tmp (created exclusively, root, 0444, synced), then
        rename it over final (replace) or link it to final (no replace: False
        if final exists)."""
        if self.lstat(tmp) is not None:
            os.unlink(tmp, dir_fd=self.fd)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o444, dir_fd=self.fd)
        try:
            os.fchmod(fd, 0o444)
            os.write(fd, text.encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            if replace:
                os.rename(tmp, final, src_dir_fd=self.fd, dst_dir_fd=self.fd)
                return True
            try:
                os.link(tmp, final, src_dir_fd=self.fd, dst_dir_fd=self.fd)
                return True
            except FileExistsError:
                return False
        finally:
            if self.lstat(tmp) is not None:
                os.unlink(tmp, dir_fd=self.fd)
            os.fsync(self.fd)


def validated_ctldir(path):
    sudo_uid, sudo_user = sudo_identity()
    try:
        st = os.lstat(path)
        info = {"dir": stat.S_ISDIR(st.st_mode), "link": stat.S_ISLNK(st.st_mode), "uid": st.st_uid,
                "mode": stat.S_IMODE(st.st_mode)}
    except FileNotFoundError:
        info = None
    found = ctldir_findings(path, info, os.path.realpath(path), sudo_uid, sudo_user, user_uid(sudo_user))
    if found:
        raise Refused(f"CTLDIR {path} refused: {'; '.join(found)}")
    ctl = CtlDir(path)
    st = os.fstat(ctl.fd)
    if st.st_uid != sudo_uid or stat.S_IMODE(st.st_mode) != 0o700:
        raise Refused(f"CTLDIR {path} changed while it was opened")
    return ctl


def sudo_identity():
    uid = os.environ.get("SUDO_UID", "")
    if not uid.isdigit() or int(uid) == 0:
        raise Refused("SUDO_UID is not the uid of an unprivileged caller")
    return int(uid), os.environ.get("SUDO_USER", "")


def user_uid(user):
    try:
        return pwd.getpwnam(user).pw_uid if user and USER_RE.fullmatch(user) else None
    except KeyError:
        return None


# --- the operations --------------------------------------------------------------

class System:
    """The I/O of the operations, as root. The unit tests replace it."""

    def preflight_observation(self):
        def param(name):
            try:
                return read_text(f"{PARAMETERS}/{name}", 4096).strip()
            except OSError:
                return None

        def present(path):
            try:
                st = os.stat(path)
                return stat.S_ISREG(st.st_mode) and bool(st.st_mode & 0o111)
            except FileNotFoundError:
                return False
            except OSError:
                return None

        try:
            af_unix = os.path.isdir(f"{FEATURES}/network/af_unix")
        except OSError:
            af_unix = None
        return {"enabled": param("enabled"), "mode": param("mode"), "af_unix": af_unix,
                "parser": present(PARSER), "aa_exec": present(AA_EXEC)}

    def preflight_record(self):
        """What the launch log records, never gating."""
        lines = []

        def read(label, path):
            try:
                lines.append(f"{label} {read_text(path, 4096).strip() or '(empty)'}")
            except OSError as e:
                lines.append(f"{label} unreadable ({e.strerror})")

        def run(label, argv):
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=5, stdin=subprocess.DEVNULL)
                out = (r.stdout + r.stderr).strip().splitlines()
                return out
            except (OSError, subprocess.SubprocessError) as e:
                lines.append(f"{label} unavailable ({e})")
                return []

        out = run("parser", [PARSER, "--version"])
        if out:
            lines.append(f"parser {out[0]}")
        try:
            lines.append("features " + " ".join(sorted(d for d in os.listdir(FEATURES) if d.startswith("network"))))
        except OSError as e:
            lines.append(f"features unreadable ({e.strerror})")
        for s in ("apparmor_restrict_unprivileged_unconfined", "apparmor_restrict_unprivileged_userns"):
            read(s, f"/proc/sys/kernel/{s}")
        read("core_pattern", "/proc/sys/kernel/core_pattern")
        defaults = run("sudo defaults", ["/usr/bin/sudo", "-V"])
        for line in defaults:
            low = line.lower()
            if "reset the environment" in low or "file descriptors" in low or "closefrom" in low:
                lines.append(f"sudo {line.strip()}")
        return lines

    def template_bytes(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            return os.read(fd, 1 << 16)
        finally:
            os.close(fd)

    def profile_list(self):
        return profile_list()

    def kernel_hash(self, name):
        return kernel_hash(name)

    def parser_add(self, text):
        r = subprocess.run([PARSER, "-a", "-K", "-q"], input=text, capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            raise Refused(f"apparmor_parser failed with status {r.returncode}: {(r.stderr or r.stdout).strip()[:500]}")

    def remove(self, name):
        fd = os.open(REMOVE, os.O_WRONLY)
        try:
            os.write(fd, name.encode())
        finally:
            os.close(fd)

    def host_pidns(self):
        return ns_inode("self", "pid")

    def pidns_tasks(self):
        return pidns_tasks()

    def label_sweep(self):
        return label_sweep()

    def process_table(self):
        return process_table()

    def pidfd_open(self, pid):
        return os.pidfd_open(pid)

    def start_time(self, pid):
        return parse_stat(read_text(f"/proc/{pid}/stat"))["start"]

    def ns_inodes(self, pid):
        """(pid namespace inode, mount namespace inode or None)."""
        pid_ino = ns_inode(pid, "pid")
        try:
            mnt_ino = ns_inode(pid, "mnt")
        except FileNotFoundError:
            mnt_ino = None  # an exiting task loses its mount namespace first
        return pid_ino, mnt_ino

    def pidfd_signal(self, pidfd, sig):
        signal.pidfd_send_signal(pidfd, sig)

    def close(self, fd):
        os.close(fd)

    def sleep(self, seconds):
        time.sleep(seconds)

    def clock(self):
        return time.monotonic()


def preflight(sys_):
    good = True
    for passed, text in preflight_findings(sys_.preflight_observation()):
        say(f"{'ok  ' if passed else 'FAIL'} {text}")
        good = good and passed
    for line in sys_.preflight_record():
        say(f"info {line}")
    if not good:
        raise Refused("AppArmor cannot confine the launch")


def load(op, name, ctl, sys_):
    kind, path, sha = template_for(op, name)
    text = render(sys_.template_bytes(path), kind, sha, name)
    if listed_modes(sys_.profile_list(), name):
        raise Refused(f"{name} is loaded already")
    sys_.parser_add(text)
    modes = listed_modes(sys_.profile_list(), name)
    if modes != ["enforce"]:
        raise Refused(f"{name} is listed as {modes or 'nothing'} after the load, not once in enforce mode")
    h = sys_.kernel_hash(name)
    if not ctl.write_new(".hash.load", "hash", f"sha256 {h or 'none'}\n", replace=False):
        raise Refused("CTLDIR/hash exists already")
    say(f"loaded {name} ({kind} template; kernel hash {h or 'not exported'})")


def kill_init_once(launcher, ctl, sys_):
    """One attempt: "killed", "not found" or Refused. The order is the
    safety argument: the pid is held by a pidfd and its start time is the
    one seen in the lookup, before and after its namespace is read, so the
    namespace recorded and the process signalled are those of pid 1."""
    host = sys_.host_pidns()
    rec = ctl.record("ns")
    recorded = None
    if rec is not None:
        if p0(rec, host) is not None:
            raise Refused(f"CTLDIR/ns is not usable: {p0(rec, host)}")
        recorded = parse_ns(rec["text"])[0]
    procs = sys_.process_table()
    found, what = find_init(procs, launcher, host, recorded)
    if found == "ambiguous":
        raise Refused(what)
    if found == "none":
        return "not found"
    pid, start = what, procs[what]["start"]
    pidfd = sys_.pidfd_open(pid)
    try:
        if sys_.start_time(pid) != start:
            return "not found"
        pid_ino, mnt_ino = sys_.ns_inodes(pid)
        if sys_.start_time(pid) != start:
            return "not found"
        sys_.pidfd_signal(pidfd, 0)
        if pid_ino == host:
            raise Refused("pid 1 of the launch is in the host's pid namespace")
        if recorded is None:
            if not ctl.write_new(".ns.killinit", "ns", ns_record(pid_ino, mnt_ino), replace=False):
                rec = ctl.record("ns")
                if p0(rec, host) is not None or parse_ns(rec["text"])[0] != pid_ino:
                    raise Refused("CTLDIR/ns appeared with another namespace; not signalling")
        elif recorded != pid_ino:
            raise Refused("pid 1 is not in the recorded pid namespace; not signalling")
        sys_.pidfd_signal(pidfd, signal.SIGKILL)
        say(f"killed pid 1 of the launch (pid {pid}, pid namespace {pid_ino})")
        return "killed"
    finally:
        sys_.close(pidfd)


def kill_init(launcher, ctl, sys_):
    end = sys_.clock() + KILL_INIT_DEADLINE
    while True:
        try:
            result = kill_init_once(launcher, ctl, sys_)
        except ProcessLookupError:
            result = "not found"
        if result == "killed":
            return
        if sys_.clock() >= end:
            say("pid 1 of the launch not found; P1 decides")
            return
        sys_.sleep(0.1)


def release(name, ctl, sys_):
    state_rec = ctl.record("state")
    state = parse_state(state_rec["text"] if state_rec and state_rec["regular"] else None)
    ns_exists = ctl.lstat("ns") is not None
    plan = release_plan(state, ns_exists)
    if plan == "no-namespace":
        if not listed_modes(sys_.profile_list(), name):
            say(f"{name} was never loaded; nothing to release (state {state})")
            return
    else:
        host = sys_.host_pidns()
        rec = ctl.record("ns")
        why = p0(rec, host)
        if why:
            raise Refused(f"P0: {why}")
        why = p1(sys_.pidns_tasks(), parse_ns(rec["text"])[0])
        if why:
            raise Refused(f"P1: {why}")
    hrec = ctl.record("hash")
    hash_load = None
    if hrec and hrec["regular"] and hrec["uid"] == 0 and hrec["mode"] == 0o444 and HASH_RE.fullmatch(hrec["text"]):
        hash_load = hrec["text"].split()[1]
    why = p2(listed_modes(sys_.profile_list(), name), sys_.kernel_hash(name), hash_load)
    if why:
        raise Refused(f"P2: {why}")
    why = sweeps_clear(sys_.label_sweep, name)
    if why:
        raise Refused(f"sweep: {why}")
    sys_.remove(name)
    left = listed_modes(sys_.profile_list(), name)
    if left:
        raise Refused(f"{name} is still listed after its removal ({left})")
    say(f"released {name} ({plan}, state {state})")


def diag(name, sys_):
    try:
        say(f"diag list: {listed_modes(sys_.profile_list(), name) or 'not listed'}")
    except OSError as e:
        say(f"diag list unreadable ({e.strerror})")
    try:
        carriers, unknown = sweep_result(sys_.label_sweep(), name)
        say(f"diag tasks carrying it: {len(carriers)} {' '.join(carriers[:20])}")
        if unknown:
            say(f"diag labels unreadable: {len(unknown)} {' '.join(unknown[:5])}")
    except OSError as e:
        say(f"diag sweep failed ({e.strerror})")


USAGE = {"preflight": 0, "load": 2, "load-negative-control": 2, "kill-init": 2, "release": 2, "diag": 1}


def main(argv, sys_=None):
    if not sys.platform.startswith("linux"):
        say("Linux only")
        return 2
    if len(argv) < 1 or argv[0] not in USAGE or len(argv) - 1 != USAGE[argv[0]]:
        say(f"usage: {' | '.join(USAGE)} (got {' '.join(argv) or 'nothing'})")
        return 2
    if os.geteuid() != 0:
        say("must run as root (through sudo)")
        return 2
    sys_ = sys_ or System()
    op = argv[0]
    try:
        if op == "preflight":
            preflight(sys_)
        elif op in ("load", "load-negative-control"):
            if not name_ok(op, argv[1]):
                raise Refused(f"{op} does not accept the name {argv[1]!r}")
            load(op, argv[1], validated_ctldir(argv[2]), sys_)
        elif op == "kill-init":
            if not argv[1].isdigit():
                raise Refused(f"LAUNCHERPID {argv[1]!r} is not a pid")
            launcher = int(argv[1])
            sudo_uid, _ = sudo_identity()
            found = launcher_findings(launcher, sys_.process_table(), os.getpid(), sudo_uid)
            if found:
                raise Refused(f"LAUNCHERPID {launcher} refused: {'; '.join(found)}")
            kill_init(launcher, validated_ctldir(argv[2]), sys_)
        elif op == "release":
            if not name_ok(op, argv[1]):
                raise Refused(f"release does not accept the name {argv[1]!r}")
            release(argv[1], validated_ctldir(argv[2]), sys_)
        else:
            if not name_ok(op, argv[1]):
                raise Refused(f"diag does not accept the name {argv[1]!r}")
            diag(argv[1], sys_)
    except Refused as e:
        say(f"refused: {e}")
        return 1
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        say(f"refused: {op} failed: {type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
