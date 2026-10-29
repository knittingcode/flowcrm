"""Prove that this process cannot reach a container engine.

Run by scripts/ci/no-docker.sh inside its isolation, before the command it
protects, and by `no-docker.sh --check`. `--listening` only prints the TCP
ports listening on loopback or on all addresses, one per line (no-docker.sh
denies them inside the macOS sandbox). Otherwise exit 0 only if

  - the isolation mechanism is in effect in this process:
      macOS: a connect to a Unix socket of our own and a TCP connect to
        loopback port 2375 and to a non-loopback address are refused by
        the sandbox (EPERM), not merely unanswered; no loopback port that
        was listening before the sandbox started (NO_DOCKER_HELD_PORTS)
        can be connected to; and no file can be created under $HOME or
        next to $TMPDIR;
      Linux: no_new_privs is set, no supplementary group is held, the
        network namespace has only the loopback interface, and /run is a
        tmpfs without any socket;
  - and no container engine answers on any endpoint we can find: the
    usual socket paths of Docker Engine, Docker Desktop, rootless Docker,
    Podman, Colima, OrbStack and Rancher Desktop; every endpoint of the
    Docker contexts under ~/.docker; DOCKER_HOST and the DOCKER_HOST the
    caller of no-docker.sh had (NO_DOCKER_ORIGINAL_HOST); every socket under /run, /var/run, /tmp,
    $TMPDIR and ~/.docker; loopback ports 2375 and 2376; and every TCP
    port listening on loopback or on all addresses (a socket proxy or a
    published engine port).

An endpoint is an engine if it accepts a connection and answers
`GET /_ping` (sent with the User-Agent no-docker-probe) with an API version
header. The endpoints are only contacted once the mechanism is proven, so
outside the isolation nothing is sent to an engine. Prints one line per
check.
"""

import concurrent.futures
import errno
import glob
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile

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


def check_mechanism_darwin():
    d = tempfile.mkdtemp(prefix="no-docker-probe.")
    path = os.path.join(d, "s")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(path)
        srv.listen(1)
        report(denied(socket.AF_UNIX, path), "macOS sandbox denies Unix socket connects")
    finally:
        srv.close()
        os.unlink(path)
        os.rmdir(d)
    report(denied(socket.AF_INET, ("127.0.0.1", 2375)), "macOS sandbox denies loopback port 2375")
    report(denied(socket.AF_INET, ("192.0.2.1", 2375)), "macOS sandbox denies non-loopback TCP")
    if not ok:
        # Not sandboxed: write nothing and connect to nothing else.
        return
    held = os.environ.get("NO_DOCKER_HELD_PORTS", "").split()
    reached = [p for p in held if p.isdigit() and connects(("127.0.0.1", int(p)))]
    report(not reached, f"macOS sandbox denies the {len(held)} loopback ports listening before it started"
           + (": reached " + " ".join(reached) if reached else ""))
    home = os.path.realpath(os.path.expanduser("~"))
    tmp = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")
    for where, d in (("under $HOME", home), ("outside $TMPDIR", os.path.dirname(tmp))):
        report(not_writable(d), f"macOS sandbox denies writes {where} ({d})")


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


def not_writable(directory):
    """True if a new file cannot be created in directory."""
    path = os.path.join(directory, f".no-docker-probe-{os.getpid()}")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return False
    except OSError:
        return True
    os.close(fd)
    os.unlink(path)
    return False


def check_mechanism_linux():
    nnp = ""
    groups = ""
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("NoNewPrivs:"):
                nnp = line.split()[1]
            elif line.startswith("Groups:"):
                groups = line[len("Groups:"):].strip()
    report(nnp == "1", f"no_new_privs is set ({nnp or 'unknown'})")
    report(groups == "", f"no supplementary groups ({groups or 'none'})")
    names = sorted(n for _, n in socket.if_nameindex())
    report(names == ["lo"], f"network namespace has only loopback ({' '.join(names)})")
    run_tmpfs = False
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            sep = fields.index("-")
            if fields[4] == "/run" and fields[sep + 1] == "tmpfs":
                run_tmpfs = True  # the last mount on /run is the visible one
            elif fields[4] == "/run":
                run_tmpfs = False
    report(run_tmpfs, "/run is a private tmpfs")
    sockets = [p for p in walk_sockets(["/run"])]
    report(not sockets, f"no socket under /run ({' '.join(sockets) or 'none'})")


def walk_sockets(roots, limit=20000):
    seen = 0
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
            for name in dirnames + filenames:
                seen += 1
                if seen > limit:
                    return
                p = os.path.join(dirpath, name)
                try:
                    if stat.S_ISSOCK(os.lstat(p).st_mode):
                        yield p
                except OSError:
                    pass


def listening_ports(strict=False):
    """(host, port) of TCP ports listening on loopback or on all addresses.

    strict: raise instead of returning an incomplete list (macOS)."""
    ports = set()
    if sys.platform == "darwin":
        try:
            run = subprocess.run(["netstat", "-an", "-p", "tcp"], capture_output=True, text=True, timeout=10)
            if run.returncode != 0:
                raise OSError(f"netstat exited with {run.returncode}")
            out = run.stdout
        except (OSError, subprocess.SubprocessError):
            if strict:
                raise
            out = ""
        for line in out.splitlines():
            f = line.split()
            if len(f) >= 6 and f[-1] == "LISTEN":
                host, _, port = f[3].rpartition(".")
                if host in ("127.0.0.1", "::1", "*") and port.isdigit():
                    ports.add(("::1" if host == "::1" else "127.0.0.1", int(port)))
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
    unix.update(walk_sockets(roots))
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
    if sys.platform == "darwin":
        check_mechanism_darwin()
    elif sys.platform.startswith("linux"):
        check_mechanism_linux()
    else:
        report(False, f"no isolation mechanism for platform {sys.platform}")
    if not ok:
        # Not isolated: do not send anything to an engine that may answer.
        return 1
    unix, tcp = endpoints()
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
