"""Prove that this process is isolated by scripts/ci/no-docker.sh.

Run by no-docker.sh inside its isolation, before the command it protects,
and by `no-docker.sh --check`. Exit 0 only if

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
        supplementary group; network, mount, pid and IPC namespaces that
        differ from the caller's (NO_DOCKER_HOST_NS); a pid namespace below
        the caller's whose pid 1 is the root shell of no-docker.sh and whose
        other processes are all ours; a session of our own without a
        controlling terminal; only the loopback interface; /tmp, /var/tmp,
        /dev/shm, /run and /dev/mqueue are new file systems
        (NO_DOCKER_HOST_DEVS) and /sys/fs/cgroup is masked; every other
        mount reachable by path is read-only; writes to $HOME,
        $GITHUB_WORKSPACE and $RUNNER_TEMP (NO_DOCKER_PROTECTED) fail; no
        cgroup file is writable; no socket in the private directories; and
        no Unix socket that no-docker.sh listed outside (NO_DOCKER_SOCKETS)
        accepts a connection;
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

Modes used by no-docker.sh outside the isolation:
  --listening   print the listening TCP port numbers (macOS), one per line;
  --sockets     print, NUL-separated, every Unix socket path on the local
                file systems and every bound pathname socket of this
                network namespace (Linux); fails when its time budget runs
                out;
  --seal WORK   as root in the new mount namespace: make every mount
                reachable by path read-only, except the private file systems
                and WORK, and verify it (Linux).
"""

import concurrent.futures
import ctypes
import errno
import glob
import json
import os
import re
import socket
import stat
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
    path = os.path.join(directory, f".no-docker-probe-{os.getpid()}")
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


# --- Linux -------------------------------------------------------------------

# File systems without files of their own that could be sockets of a
# service, or read-only images (squashfs snaps).
PSEUDO = {"proc", "sysfs", "cgroup", "cgroup2", "devpts", "mqueue", "debugfs", "tracefs", "securityfs",
          "pstore", "bpf", "configfs", "fusectl", "hugetlbfs", "binfmt_misc", "autofs", "efivarfs", "nsfs",
          "rpc_pipefs", "squashfs", "erofs", "iso9660"}
# Mounts that stay writable inside: the private file systems, /proc and /dev
# (device nodes; no file can be created there without root).
WRITABLE = ("/tmp", "/var/tmp", "/dev/shm", "/run", "/var/run", "/dev/mqueue", "/proc", "/dev", "/dev/pts")
PRIVATE = (("/tmp", "tmpfs"), ("/var/tmp", "tmpfs"), ("/dev/shm", "tmpfs"), ("/run", "tmpfs"),
           ("/dev/mqueue", "mqueue"))
HOST_COMMS = {"systemd", "init", "Runner.Worker", "Runner.Listener", "dockerd", "containerd", "sshd",
              "containerd-shim", "rootlesskit", "podman", "dbus-daemon"}


def unescape(s):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


def mounts():
    entries = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            sep = fields.index("-")
            entries.append({"id": int(fields[0]), "point": unescape(fields[4]),
                            "opts": fields[5].split(","), "fstype": fields[sep + 1]})
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


def enumerate_sockets(budget=180):
    """Every socket file on the local file systems (find -xdev per mount)
    and every bound pathname socket of this network namespace
    (/proc/net/unix, what ss -xl shows). Raises when the budget runs out."""
    start = time.monotonic()
    found = set()
    points = sorted({m["point"] for m in mounts() if m["fstype"] not in PSEUDO})
    for p in points:
        left = budget - (time.monotonic() - start)
        if left <= 0:
            raise TimeoutError(f"the {budget}s budget ran out before {p}")
        try:
            r = subprocess.run(["find", p, "-xdev", "-type", "s", "-print0"], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=left)
        except subprocess.TimeoutExpired:
            raise TimeoutError(f"the {budget}s budget ran out in {p}") from None
        if r.returncode not in (0, 1):  # 1: some directories were unreadable
            raise OSError(f"find {p} exited with {r.returncode}")
        found.update(x for x in r.stdout.split(b"\0") if x)
    with open("/proc/net/unix", "rb") as f:
        next(f)
        for line in f:
            parts = line.split(None, 7)
            if len(parts) == 8 and parts[7].startswith(b"/"):
                found.add(parts[7].rstrip(b"\n"))
    return sorted(found), len(points), time.monotonic() - start


def unix_connects(path):
    """The socket type name a connect to path succeeds with, None if none."""
    for kind, name in ((socket.SOCK_STREAM, "stream"), (socket.SOCK_SEQPACKET, "seqpacket"),
                       (socket.SOCK_DGRAM, "dgram")):
        s = socket.socket(socket.AF_UNIX, kind)
        s.settimeout(2)
        try:
            s.connect(path)
            return name
        except socket.timeout:
            return name + " (timeout)"  # a listener with a full backlog
        except OSError as e:
            if e.errno == errno.EPROTOTYPE:
                continue
            return None
        finally:
            s.close()
    return None


def status(pid="self"):
    st = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            st[k] = v.strip()
    return st


def env_pairs(name):
    return dict(x.split("=", 1) for x in os.environ.get(name, "").split() if "=" in x)


def check_mechanism_linux():
    me = os.getuid()
    st = status()
    uids = st.get("Uid", "0").split()
    report("0" not in uids, f"not root (uids {' '.join(uids)})")
    caps = {k: st.get(k, "unknown") for k in ("CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb")}
    report(all(v != "unknown" and int(v, 16) == 0 for v in caps.values()),
           "no capabilities (" + " ".join(f"{k}={v}" for k, v in caps.items()) + ")")
    report(st.get("NoNewPrivs") == "1", f"no_new_privs is set ({st.get('NoNewPrivs', 'unknown')})")
    report(st.get("Groups", "x") == "", f"no supplementary groups ({st.get('Groups') or 'none'})")

    host_ns = env_pairs("NO_DOCKER_HOST_NS")
    for ns in ("net", "mnt", "pid", "ipc"):
        own = os.readlink(f"/proc/self/ns/{ns}")
        host = host_ns.get(ns, "")
        report(bool(host) and own != host, f"private {ns} namespace ({own}; caller {host or 'unknown'})")
    nspid = st.get("NSpid", "").split()
    report(len(nspid) >= 2, f"in a pid namespace below the caller's (NSpid {' '.join(nspid)})")
    report(os.readlink("/proc/self") == str(os.getpid()), "/proc belongs to this pid namespace")
    foreign = []
    count = 0
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            pst = status(d)
        except OSError:
            continue  # ended meanwhile
        count += 1
        name, puids = pst.get("Name", "?"), pst.get("Uid", "").split()
        if d == "1":
            if puids[:1] != ["0"] or name not in ("sh", "dash"):
                foreign.append(f"1:{name}:{'/'.join(puids)}")
        elif any(u != str(me) for u in puids) or name in HOST_COMMS:
            foreign.append(f"{d}:{name}:{'/'.join(puids)}")
    report(not foreign, f"only our processes and the root pid 1 of the isolation are visible ({count} processes"
           + (f"; foreign: {' '.join(foreign)}" if foreign else "") + ")")
    sid = os.getsid(0)
    sid_ours = False
    if sid > 1:
        try:
            sid_ours = all(u == str(me) for u in status(sid).get("Uid", "").split())
        except OSError:
            pass
    report(sid_ours, f"a session of our own (session {sid})")
    try:
        os.close(os.open("/dev/tty", os.O_RDWR))
        report(False, "no controlling terminal (TIOCSTI)")
    except OSError as e:
        report(True, f"no controlling terminal ({errno.errorcode.get(e.errno, e.errno)})")

    names = sorted(n for _, n in socket.if_nameindex())
    report(names == ["lo"], f"network namespace has only loopback ({' '.join(names)})")

    work = os.environ.get("NO_DOCKER_RUN_DIR", "")
    report(bool(work), f"the run's directory is known ({work or 'NO_DOCKER_RUN_DIR unset'})")
    host_devs = env_pairs("NO_DOCKER_HOST_DEVS")
    vis = {m["point"]: m for m in visible_mounts()}
    for path, fstype in PRIVATE:
        m = vis.get(path)
        try:
            dev = str(os.stat(path).st_dev)
        except OSError:
            dev = "?"
        host = host_devs.get(path, "")
        report(bool(m) and m["fstype"] == fstype and bool(host) and dev != host,
               f"{path} is a private {fstype} (device {dev}; caller {host or 'unknown'})")
    m = vis.get("/sys/fs/cgroup")
    report(bool(m) and m["fstype"] == "tmpfs" and "ro" in m["opts"], "/sys/fs/cgroup is masked by a read-only tmpfs")
    if work:
        left = writable_mounts(work)
        report(not left, f"every other mount is read-only ({len(vis)} reachable mounts"
               + (f"; writable: {' '.join(left)}" if left else "") + ")")
    try:
        report(mount_id_of(".") == mount_id_of(os.getcwd()), f"the working directory is reachable by its path ({os.getcwd()})")
    except OSError as e:
        report(False, f"the working directory is reachable by its path ({e})")
    if not ok:
        # Not isolated: write nothing and connect to nothing.
        return

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
    listed = os.environ.get("NO_DOCKER_SOCKETS", "")
    try:
        with open(listed, "rb") as f:
            paths = [os.fsdecode(p) for p in f.read().split(b"\0") if p]
    except OSError as e:
        report(False, f"the Unix sockets listed outside can be read ({listed or 'NO_DOCKER_SOCKETS unset'}: {e})")
        return
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        reached = [f"{p} ({k})" for p, k in zip(paths, pool.map(unix_connects, paths)) if k]
    report(not reached, f"none of the {len(paths)} Unix sockets listed outside accepts a connection"
           + (": " + ", ".join(reached) if reached else ""))


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
    if sys.argv[1:] == ["--sockets"]:
        try:
            paths, points, took = enumerate_sockets()
        except (OSError, TimeoutError, StopIteration) as e:
            print(f"no-docker: cannot list the Unix sockets: {e}", file=sys.stderr)
            return 1
        sys.stdout.buffer.write(b"".join(p + b"\0" for p in paths))
        print(f"no-docker: {len(paths)} Unix sockets listed on {points} mounts in {took:.1f}s", file=sys.stderr)
        return 0
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
    try:
        unix, tcp = endpoints()
    except WalkLimit as e:
        report(False, f"every socket of the walked directories was checked ({e})")
        return 1

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
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
