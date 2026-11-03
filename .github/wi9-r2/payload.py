"""The raw evidence of a WI-9 R2 job, carried through its job log.

Usage:
  payload.py digest DIR            sha256, size and path of every file under DIR;
                                   fails on anything that is not a regular file
                                   or cannot be read
  payload.py export DIR JOB        print every file under DIR as one framed
                                   payload in the job log (stdout), or withhold
                                   it (exit 3) if a secret may be in it
  payload.py extract LOG JOB OUT   rebuild the payload of JOB from a downloaded
                                   job log LOG into the empty directory OUT and
                                   check every file against its manifest

The workflow has no action, no token permission and no artifact upload, so
the job log is the only output. The payload is a gzip-compressed tar of the
regular files under DIR (fixed metadata, sorted) plus PAYLOAD-MANIFEST.sha256,
printed as base64 lines:

  wi9-r2-payload-begin JOB BYTES SHA256 CHUNKS FILES
  wi9-r2-payload JOB I/CHUNKS SHA256-OF-THE-LINE'S-TEXT(16 HEX) BASE64
  wi9-r2-payload-end JOB SHA256

(a timestamp the runner adds in front of each line of a downloaded log is
ignored). Extraction is bounded before anything is allocated from what the
log claims: the log at most MAX_LOG bytes; the begin line's size at most
MAX_BYTES, its file count at most MAX_FILES and its chunk count exactly the
one that size needs; each chunk line's index and count within that, its
text at most CHUNK characters; the archive is decompressed with a cap
(MAX_UNPACKED plus its headers) and read one member at a time, at most
MAX_FILES + 1 of them. It refuses a missing, repeated or changed chunk, a size or
sha256 that differs, and any archive member that is not a regular file with
a safe relative path (no absolute path, no "..", no link, device or FIFO);
files are written with O_EXCL and O_NOFOLLOW, never through tarfile's own
extraction. Export refuses non-regular files and unsafe names, and withholds
the payload if a file holds the value of an environment variable whose name
suggests a secret, or a GitHub token or private key pattern (the payload is
base64, so the runner's secret masking could not hide it).
"""

import base64
import errno
import gzip
import hashlib
import io
import os
import re
import stat
import sys
import tarfile
import zlib

PREFIX = "wi9-r2-payload"
MANIFEST = "PAYLOAD-MANIFEST.sha256"
CHUNK = 3000
MAX_BYTES = 48 << 20
MAX_FILES = 20000
MAX_UNPACKED = 192 << 20
MAX_LOG = 256 << 20
SAFE = re.compile(r"[A-Za-z0-9._@+=,-]+")
JOB = re.compile(r"[a-z][a-z0-9-]{0,31}")
SECRET_NAME = re.compile(r"TOKEN|SECRET|PASSW|CREDENTIAL|PRIVATE|_KEY$|^KEY$", re.I)
SECRET_PATTERNS = [re.compile(p) for p in (
    rb"gh[pousr]_[A-Za-z0-9]{30,}", rb"github_pat_[A-Za-z0-9_]{30,}",
    rb"-----BEGIN [A-Z ]*PRIVATE KEY-----", rb'"scheme"\s*:\s*"OAuth"')]
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z ")


class Bad(Exception):
    """The payload cannot be made or trusted; the message says why."""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(path):
    parts = path.split("/")
    return bool(path) and all(SAFE.fullmatch(p) and p not in (".", "..") for p in parts)


def collect(root):
    """[(relative path, bytes)] of every regular file under root, sorted."""
    files, failures = [], []

    def onerror(e):
        failures.append(f"{e.filename}: {e.strerror}")

    for dirpath, dirnames, filenames in os.walk(root, onerror=onerror):
        rel = os.path.relpath(dirpath, root)
        for d in dirnames:
            if os.path.islink(os.path.join(dirpath, d)):
                raise Bad(f"{os.path.join(rel, d)}: a symbolic link")
        for f in filenames:
            path = f if rel == "." else f"{rel}/{f}"
            if not safe_path(path):
                raise Bad(f"{path!r}: not a safe path")
            try:
                fd = os.open(os.path.join(dirpath, f), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            except OSError as e:
                raise Bad(f"{path}: {errno.errorcode.get(e.errno, e.errno)} (a link, socket or unreadable file)")
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    raise Bad(f"{path}: not a regular file")
                parts = []
                while True:
                    b = os.read(fd, 1 << 20)
                    if not b:
                        break
                    parts.append(b)
            finally:
                os.close(fd)
            files.append((path, b"".join(parts)))
    if failures:
        raise Bad("cannot read: " + "; ".join(failures[:5]))
    if len(files) > MAX_FILES:
        raise Bad(f"{len(files)} files, more than {MAX_FILES}")
    if any(path == MANIFEST for path, _ in files):
        raise Bad(f"a file is named {MANIFEST}")
    return sorted(files)


def secret_findings(files, env):
    """(path, what) of every file that may hold a secret; values are never shown."""
    values = sorted({v.encode() for k, v in env.items() if SECRET_NAME.search(k) and len(v) >= 8})
    found = []
    for path, data in files:
        for v in values:
            if v in data:
                found.append((path, "the value of a secret-like environment variable"))
                break
        for p in SECRET_PATTERNS:
            if p.search(data):
                found.append((path, f"a token or key pattern ({p.pattern[:12].decode()}...)"))
                break
    return found


def build(files):
    """The gzip-compressed tar of files and their manifest (deterministic)."""
    members = list(files) + [(MANIFEST, "".join(f"{sha(d)}  {p}\n" for p, d in files).encode())]
    if sum(len(d) for _, d in members) > MAX_UNPACKED:
        raise Bad(f"the raw outputs are more than {MAX_UNPACKED} bytes")
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path, data in members:
            info = tarfile.TarInfo(path)
            info.size, info.mode, info.mtime, info.type = len(data), 0o600, 0, tarfile.REGTYPE
            tar.addfile(info, io.BytesIO(data))
    blob = gzip.compress(raw.getvalue(), mtime=0)
    if len(blob) > MAX_BYTES:
        raise Bad(f"the payload is {len(blob)} bytes, more than {MAX_BYTES}")
    return blob


def chunks_for(size):
    """The number of chunk lines of a payload of size bytes."""
    return max(1, (4 * ((size + 2) // 3) + CHUNK - 1) // CHUNK)


def frame(blob, job, files):
    """The log lines of a payload."""
    text = base64.b64encode(blob).decode()
    chunks = [text[i:i + CHUNK] for i in range(0, len(text), CHUNK)] or [""]
    n = len(chunks)
    lines = [f"{PREFIX}-begin {job} {len(blob)} {sha(blob)} {n} {files}"]
    lines += [f"{PREFIX} {job} {i}/{n} {sha(c.encode())[:16]} {c}" for i, c in enumerate(chunks, 1)]
    lines.append(f"{PREFIX}-end {job} {sha(blob)}")
    return lines


def parse(text, job):
    """The payload of job in the log text; Bad if it is incomplete or changed."""
    begins, ends, chunks = [], [], {}
    for raw in text.splitlines():
        line = STAMP.sub("", raw, count=1)
        word = line.split(" ", 2)
        if len(word) < 2 or word[1] != job or not word[0].startswith(PREFIX):
            continue
        f = line.split(" ")
        if f[0] == f"{PREFIX}-begin" and len(f) == 6:
            begins.append(f)
        elif f[0] == f"{PREFIX}-end" and len(f) == 3:
            ends.append(f)
        elif f[0] == PREFIX and len(f) in (4, 5):
            m = re.fullmatch(r"([1-9][0-9]{0,8})/([1-9][0-9]{0,8})", f[2])
            if not m:
                raise Bad(f"a chunk line without an index: {line[:60]}")
            i, n = int(m.group(1)), int(m.group(2))
            body = f[4] if len(f) == 5 else ""
            if n > chunks_for(MAX_BYTES) or i > n or len(body) > CHUNK or len(chunks) >= chunks_for(MAX_BYTES):
                raise Bad(f"a chunk line out of bounds: {line[:60]}")
            if i in chunks:
                raise Bad(f"chunk {i} appears twice")
            if sha(body.encode())[:16] != f[3]:
                raise Bad(f"chunk {i} was changed (its sha256 differs)")
            chunks[i] = (n, body)
        else:
            raise Bad(f"an unexpected payload line: {line[:60]}")
    if len(begins) != 1 or len(ends) != 1:
        raise Bad(f"{len(begins)} begin and {len(ends)} end lines for {job}, not one each")
    _, _, size, total, count, nfiles = begins[0]
    if not (all(re.fullmatch("[0-9]{1,9}", v) for v in (size, count, nfiles)) and re.fullmatch("[0-9a-f]{64}", total)):
        raise Bad("a malformed begin line")
    size, count = int(size), int(count)
    if size > MAX_BYTES or int(nfiles) > MAX_FILES or count != chunks_for(size):
        raise Bad(f"a begin line out of bounds (size {size}, {count} chunks, {nfiles} files)")
    if ends[0][2] != total:
        raise Bad("the end line names another payload")
    if sorted(chunks) != list(range(1, count + 1)) or any(n != count for n, _ in chunks.values()):
        missing = sorted(set(range(1, count + 1)) - set(chunks))
        raise Bad(f"chunks missing or out of range (missing: {missing[:10]})")
    try:
        blob = base64.b64decode("".join(chunks[i][1] for i in range(1, count + 1)), validate=True)
    except ValueError as e:
        raise Bad(f"not base64: {e}")
    if len(blob) != size or sha(blob) != total:
        raise Bad("the payload's size or sha256 differs from its begin line")
    return blob, int(nfiles)


def unpack(blob, nfiles, out):
    """Write the files of blob into the empty directory out and check them."""
    if os.listdir(out):
        raise Bad(f"{out} is not empty")
    # Decompressed with a cap, then read one member at a time.
    limit = MAX_UNPACKED + (MAX_FILES + 2) * 3072 + 10240
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        raw = d.decompress(blob, limit + 1)
    except zlib.error as e:
        raise Bad(f"not a payload archive: {e}")
    if len(raw) > limit or d.unconsumed_tail:
        raise Bad(f"the archive unpacks to more than {limit} bytes")
    if not d.eof or d.unused_data:
        raise Bad("not a payload archive: the gzip stream is cut or followed by other data")
    members = []
    try:
        tar = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
        while True:
            m = tar.next()
            if m is None:
                break
            if len(members) > MAX_FILES:
                raise Bad(f"more than {MAX_FILES + 1} archive members")
            members.append(m)
    except (tarfile.TarError, OSError, EOFError) as e:
        raise Bad(f"not a payload archive: {e}")
    if len(members) != nfiles + 1:
        raise Bad(f"{len(members)} archive members for {nfiles} files and the manifest")
    seen, total, data = set(), 0, {}
    for m in members:
        if not m.isreg() or not safe_path(m.name) or m.name in seen:
            raise Bad(f"unsafe or repeated archive member {m.name!r} (type {m.type!r})")
        seen.add(m.name)
        total += m.size
        if total > MAX_UNPACKED:
            raise Bad("the archive unpacks to too much data")
        try:
            data[m.name] = tar.extractfile(m).read()
        except (tarfile.TarError, OSError, EOFError, zlib.error) as e:
            raise Bad(f"{m.name}: cannot be read from the archive: {e}")
    if MANIFEST not in data:
        raise Bad("no manifest in the payload")
    listed = {}
    for line in data.pop(MANIFEST).decode().splitlines():
        h, _, p = line.partition("  ")
        listed[p] = h
    if set(listed) != set(data) or len(data) != nfiles:
        raise Bad("the files and the manifest differ")
    for p, d in data.items():
        if sha(d) != listed[p]:
            raise Bad(f"{p}: sha256 differs from the manifest")
    for p, d in sorted(data.items()):
        target = os.path.join(out, p)
        os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(d)
            while view:
                view = view[os.write(fd, view):]
        finally:
            os.close(fd)
    with open(os.path.join(out, MANIFEST), "x") as f:
        f.write("".join(f"{listed[p]}  {p}\n" for p in sorted(listed)))
    return sorted(data)


def main(argv, env, out=sys.stdout):
    try:
        if argv[:1] == ["digest"] and len(argv) == 2:
            for path, d in collect(argv[1]):
                print(f"{sha(d)}  {len(d)}  {path}", file=out)
            return 0
        if argv[:1] == ["export"] and len(argv) == 3 and JOB.fullmatch(argv[2]):
            files = collect(argv[1])
            found = secret_findings(files, env)
            if found:
                for path, what in found:
                    print(f"{PREFIX}-withheld {argv[2]}: {path} may hold {what}", file=sys.stderr)
                return 3
            for line in frame(build(files), argv[2], len(files)):
                print(line, file=out)
            return 0
        if argv[:1] == ["extract"] and len(argv) == 4 and JOB.fullmatch(argv[2]):
            with open(argv[1], "rb") as f:
                data = f.read(MAX_LOG + 1)
            if len(data) > MAX_LOG:
                raise Bad(f"the log is larger than {MAX_LOG} bytes")
            text = data.decode("utf-8", "replace")
            blob, nfiles = parse(text, argv[2])
            names = unpack(blob, nfiles, argv[3])
            print(f"{PREFIX}: {len(names)} files of {argv[2]} checked and written to {argv[3]} (sha256 {sha(blob)})", file=out)
            return 0
    except Bad as e:
        print(f"{PREFIX}: refused: {e}", file=sys.stderr)
        return 1
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], dict(os.environ)))
