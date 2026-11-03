"""Hold TCP ports on 127.0.0.1 for the bin/devenv integration tests.

Usage: port-holder.py listen|bind READY_FILE PORT...

listen  accepts connections, like an unrelated server process
bind    binds without listening: invisible to a connect probe, but Docker
        still cannot bind the port, which reproduces a probe/bind race

READY_FILE is created once every port is held. Exits on SIGTERM.

A port that just served HTTP may still be in TIME_WAIT. listen mode sets
SO_REUSEADDR (a listening socket still blocks other binds). bind mode must
not: on Linux two non-listening SO_REUSEADDR sockets could share the port and
Docker would bind successfully; it retries for up to 60 seconds instead.
"""

import errno
import signal
import socket
import sys
import time


def hold(mode: str, port: int) -> socket.socket:
    deadline = time.monotonic() + 60
    while True:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        if mode == "listen":
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError as exc:
            sock.close()
            if exc.errno != errno.EADDRINUSE or time.monotonic() > deadline:
                raise
            time.sleep(1)
            continue
        if mode == "listen":
            sock.listen(16)
        return sock


def main() -> None:
    mode, ready, *ports = sys.argv[1:]
    if mode not in ("listen", "bind") or not ports:
        sys.exit(__doc__)
    held = [hold(mode, int(port)) for port in ports]
    with open(ready, "w", encoding="ascii"):
        pass
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
