import json, os, socketserver, sys
path, log = sys.argv[1], sys.argv[2]
class H(socketserver.StreamRequestHandler):
    def handle(self):
        while True:
            line = self.rfile.readline()
            if not line:
                return
            headers = {}
            while True:
                h = self.rfile.readline()
                if h in (b"\r\n", b"\n", b""):
                    break
                k, _, v = h.decode("latin-1").partition(":")
                headers[k.strip().lower()] = v.strip()
            if headers.get("user-agent") != "no-docker-probe":
                with open(log, "a") as f:
                    f.write(line.decode("latin-1").strip() + " ua=" + headers.get("user-agent", "-") + "\n")
            target = line.split()[1].decode("latin-1") if len(line.split()) > 1 else "/"
            if target.endswith("/_ping"):
                body = b"OK"
            elif target.endswith("/version"):
                body = json.dumps({"Version": "canary-engine", "ApiVersion": "1.45", "MinAPIVersion": "1.24",
                                   "Os": "linux", "Arch": "amd64"}).encode()
            else:
                body = json.dumps({"message": "canary-engine"}).encode()
            self.wfile.write(b"HTTP/1.1 200 OK\r\nApi-Version: 1.45\r\nOstype: linux\r\n"
                             b"Content-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body))
            if not line.startswith(b"HEAD"):
                self.wfile.write(body)
            self.wfile.flush()
class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
S(path, H).serve_forever()
