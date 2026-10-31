"""Pure evaluator of the FCRM-SEC-025 AppArmor spike (revision 4).

It only reads the files named on its command line and its stdin, and prints
to stdout. It never prints a SPIKE-DECISION line: the script does.

cases --profile P --src KIND=PATH...   one spec per stdin line, one output
                                       line "<id> <PASS|FAIL|INCONCLUSIVE>
                                       <detail>" per spec, in order
noise --profile P --sock PATH... --src KIND=PATH...
                                       one line "INFO <counts>"
decide                                 the PRE/CASE ledger, "CLEANUP <s>" and
                                       "SETUP <n>" on stdin; one line
                                       "<GO|NO-GO|INCONCLUSIVE> <detail>"

Spec lines (KIND of a source: netlink, dmesg, journal or auditlog):
  negative ID stream|dgram STEP SOCKET PREFIX   files PREFIX.cb .neg .ca .t
  late ID SOCKET PREFIX                          files PREFIX.c .n .n.order .n.t
  positive ID PROFILE FILE
  abstract ID PREFIX                             files PREFIX.c .n .ca
"""
import re
import sys

PRE_IDS = ("PRE-enabled", "PRE-mode", "PRE-aa-exec", "PRE-unix-feature",
           "PRE-load-a", "PRE-attach")
CASE_IDS = ("S2-host-stream", "S4-unlistable-dir", "S5-bind-alias",
            "S10-dgram-connect", "S10u-dgram-sendto", "S7-late-socket",
            "S2c-attach-disconnected", "S3-inside-socket", "S6a-abstract",
            "S11-exec-inherits", "S11-changeprofile", "S11-aa-exec-unconfined",
            "S12-missing-profile", "S12-complain-visible",
            "S15-cleanup-after-term")
DISCONNECTED = "Failed name lookup - disconnected path"
STAMP = r"audit\((\d+)\.(\d{3}):(\d+)\): (.*)"
HEADERS = {
    "netlink": re.compile(r"REC 1400 " + STAMP),
    "dmesg": re.compile(r"(?:\[\s*\d+\.\d+\] )?audit: type=1400 " + STAMP),
    "journal": re.compile(r"\d+\.\d+ \S+ kernel: audit: type=1400 " + STAMP),
    "auditlog": re.compile(r"type=AVC msg=" + STAMP),
}
TOKEN = re.compile(r'([a-z0-9_]+)=("[^"]*"|[^ "]+)')
TIME = re.compile(r"(\d+)\.(\d{1,9})")


def clean(text):
    return re.sub(r"[^\x20-\x7e]", "?", text)[:300]


def lines(path):
    """Complete (newline-terminated) lines of a file; [] if unreadable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            data = f.read()
    except OSError:
        return []
    return data.split("\n")[:-1]


def last(ls, prefix):
    found = None
    for ln in ls:
        if ln.startswith(prefix):
            found = ln[len(prefix):]
    return found


class Out:
    """LABEL, STEP and RESULT of one captured case output."""

    def __init__(self, path):
        ls = lines(path)
        self.label = last(ls, "LABEL ")
        self.step = last(ls, "STEP ")
        self.result = last(ls, "RESULT ") or "missing"

    def lab(self):
        return "missing" if self.label is None else self.label


def body_fields(body):
    """key=value fields of an audit body, or None unless it parses whole."""
    fields = {}
    pos = 0
    while True:
        m = TOKEN.match(body, pos)
        if not m:
            return None
        key, val = m.group(1), m.group(2)
        if key in fields:
            return None
        quoted = val.startswith('"')
        fields[key] = (val[1:-1] if quoted else val, quoted)
        pos = m.end()
        if pos == len(body):
            return fields
        if body[pos] != " ":
            return None
        pos += 1
        if pos == len(body):
            return None


def parse_record(kind, line):
    m = HEADERS[kind].fullmatch(line)
    if not m:
        return None
    fields = body_fields(m.group(4))
    if fields is None:
        return None
    return {"src": kind, "ms": int(m.group(1)) * 1000 + int(m.group(2)),
            "serial": int(m.group(3)), "fields": fields, "body": m.group(4)}


def load_sources(specs):
    """Parse every source once: {kind: [records]}, plus raw line counts."""
    recs = []
    raw = {}
    for spec in specs:
        kind, _, path = spec.partition("=")
        if kind not in HEADERS:
            raise ValueError("unknown source " + kind)
        ls = lines(path)
        raw[kind] = ls
        for ln in ls:
            r = parse_record(kind, ln)
            if r is not None:
                recs.append(r)
    return recs, raw


def window(path):
    """(t0_ms floor, t1_ms ceiling) from two date +%s.%N lines, or None."""
    ls = lines(path)
    if len(ls) != 2:
        return None
    vals = []
    for ln in ls:
        m = TIME.fullmatch(ln)
        if not m:
            return None
        frac = m.group(2).ljust(9, "0")
        vals.append((int(m.group(1)), int(frac)))
    t0 = vals[0][0] * 1000 + vals[0][1] // 1000000
    t1 = vals[1][0] * 1000 + (vals[1][1] + 999999) // 1000000
    if t1 < t0:
        return None
    return t0, t1


def field_is(fields, key, value, quoted):
    return fields.get(key) == (value, quoted)


def attributed(recs, profile, op, sock, win):
    """The first record that attributes this denial, or None."""
    names = (sock, sock.lstrip("/"))
    for r in recs:
        f = r["fields"]
        if (field_is(f, "apparmor", "DENIED", True)
                and field_is(f, "operation", op, True)
                and field_is(f, "class", "file", True)
                and field_is(f, "info", DISCONNECTED, True)
                and field_is(f, "error", "-13", False)
                and field_is(f, "profile", profile, True)
                and f.get("name", ("", False))[1]
                and f["name"][0] in names
                and win[0] - 2000 <= r["ms"] <= win[1] + 2000):
            return r
    return None


def unconfined(o):
    return o.result == "OK" and o.label == "unconfined"


def negative(args, profile, recs):
    cid, kind, step, sock, prefix = args
    cb, neg, ca = Out(prefix + ".cb"), Out(prefix + ".neg"), Out(prefix + ".ca")
    want = profile + " (enforce)"
    if not (unconfined(cb) and unconfined(ca)):
        return "INCONCLUSIVE", "control before=%s after=%s labels=%s/%s" % (
            cb.result, ca.result, cb.lab(), ca.lab())
    if neg.label != want:
        return "INCONCLUSIVE", "confined label=%s result=%s" % (neg.lab(), neg.result)
    if neg.result == "OK":
        return "FAIL", "a host-bound socket was reached under " + want
    if kind == "stream" and neg.step is not None and neg.step != "connect":
        return "FAIL", "connect() to a host-bound socket succeeded (step %s, result %s)" % (
            neg.step, neg.result)
    if neg.result != "EACCES":
        return "INCONCLUSIVE", "errno=%s step=%s (controls OK)" % (neg.result, neg.step)
    if neg.step != step:
        return "INCONCLUSIVE", "EACCES at step %s, expected %s" % (neg.step, step)
    win = window(prefix + ".t")
    if win is None:
        return "INCONCLUSIVE", "EACCES; no valid time window"
    r = attributed(recs, profile, "connect" if kind == "stream" else "sendmsg", sock, win)
    base = sock.rsplit("/", 1)[-1]
    if r is None:
        return "INCONCLUSIVE", "EACCES at %s without an attributed audit record for %s" % (step, base)
    return "PASS", "EACCES at %s; audit %s serial %d: disconnected path, %s; controls OK" % (
        step, r["src"], r["serial"], base)


def late(args, profile, recs):
    cid, sock, prefix = args
    c, n = Out(prefix + ".c"), Out(prefix + ".n")
    want = profile + " (enforce)"
    order = lines(prefix + ".n.order")
    if not unconfined(c):
        return "INCONCLUSIVE", "control %s label %s" % (c.result, c.lab())
    if n.label != want:
        return "INCONCLUSIVE", "confined label=%s result=%s" % (n.lab(), n.result)
    if order != ["after"]:
        return "INCONCLUSIVE", "ordering not proven (%s)" % "|".join(order)
    if n.result == "OK":
        return "FAIL", "a late host socket was reached under " + want
    if n.step is not None and n.step != "connect":
        return "FAIL", "connect() to a late host socket succeeded (step %s, result %s)" % (
            n.step, n.result)
    if n.result != "EACCES" or n.step != "connect":
        return "INCONCLUSIVE", "result %s step %s" % (n.result, n.step)
    win = window(prefix + ".n.t")
    if win is None:
        return "INCONCLUSIVE", "EACCES; no valid time window"
    r = attributed(recs, profile, "connect", sock, win)
    if r is None:
        return "INCONCLUSIVE", "EACCES without an attributed audit record for s7.sock"
    return "PASS", "EACCES at connect; audit %s serial %d: disconnected path, %s; control OK; bound after start" % (
        r["src"], r["serial"], sock.rsplit("/", 1)[-1])


def positive(args):
    cid, prof, path = args
    o = Out(path)
    if o.label != prof + " (enforce)":
        return "INCONCLUSIVE", "label=%s result=%s (the profile did not attach as expected)" % (
            o.lab(), o.result)
    if o.result == "OK":
        return "PASS", "OK under %s (enforce)" % prof
    if o.result == "EACCES":
        return "FAIL", "EACCES under %s (enforce)" % prof
    return "INCONCLUSIVE", "result=" + o.result


def abstract(args):
    cid, prefix = args
    c, n, ca = Out(prefix + ".c"), Out(prefix + ".n"), Out(prefix + ".ca")
    if not (unconfined(c) and unconfined(ca)):
        return "INCONCLUSIVE", "control before %s after %s labels %s/%s" % (
            c.result, ca.result, c.lab(), ca.lab())
    if n.result == "ECONNREFUSED":
        return "PASS", "ECONNREFUSED from a private netns; controls OK"
    if n.result == "OK":
        return "FAIL", "an abstract host socket was reached from a private netns"
    return "INCONCLUSIVE", "private netns result " + n.result


def options(argv, names):
    opts = {k: [] for k in names}
    i = 0
    while i < len(argv):
        key = argv[i][2:] if argv[i].startswith("--") else None
        if key not in opts or i + 1 >= len(argv):
            raise ValueError("bad argument " + argv[i])
        opts[key].append(argv[i + 1])
        i += 2
    return opts


SHAPES = {"negative": 5, "late": 3, "positive": 3, "abstract": 2}


def cases(argv, stdin):
    opts = options(argv, ("profile", "src"))
    if len(opts["profile"]) != 1:
        raise ValueError("one --profile")
    profile = opts["profile"][0]
    recs, _ = load_sources(opts["src"])
    result = []
    for ln in stdin:
        parts = ln.split(" ")
        kind, args = parts[0], parts[1:]
        if kind not in SHAPES or len(args) != SHAPES[kind]:
            raise ValueError("bad spec")
        if kind == "negative":
            cls, det = negative(args, profile + "-a", recs)
        elif kind == "late":
            cls, det = late(args, profile + "-a", recs)
        elif kind == "positive":
            cls, det = positive(args)
        else:
            cls, det = abstract(args)
        result.append("%s %s %s" % (args[0], cls, clean(det)))
    return result


def noise(argv):
    opts = options(argv, ("profile", "sock", "src"))
    prefix = opts["profile"][0]
    socks = set()
    for s in opts["sock"]:
        socks.update((s, s.lstrip("/")))
    recs, raw = load_sources(opts["src"])
    seen = set()
    other = 0
    for r in recs:
        f = r["fields"]
        key = (r["serial"], r["body"])
        if key in seen:
            continue
        seen.add(key)
        prof = f.get("profile", ("", False))[0]
        if field_is(f, "apparmor", "DENIED", True) and prof.startswith(prefix + "-") \
                and f.get("name", ("", False))[0] not in socks:
            other += 1
    parts = ["unrelated-denials=%d" % other]
    for kind in sorted(raw):
        serials = sorted({r["serial"] for r in recs if r["src"] == kind})
        gaps = sum(1 for a, b in zip(serials, serials[1:]) if b - a > 1)
        parts.append("%s:records=%d,serial-gaps=%d" % (kind, len(serials), gaps))
    supp = sum(1 for k in raw for ln in raw[k] if "callbacks suppressed" in ln)
    lost = sum(1 for k in raw for ln in raw[k] if re.search(r"audit:.*lost", ln))
    parts.append("suppressed-lines=%d lost-lines=%d" % (supp, lost))
    return "INFO " + clean(" ".join(parts))


def decide(stdin):
    pre = {}
    case = {}
    other = {}
    bad = []
    for ln in stdin:
        p = ln.split(" ")
        if len(p) == 3 and p[0] == "PRE" and p[1] in PRE_IDS and p[2] in ("PASS", "FAIL", "INCONCLUSIVE"):
            pre.setdefault(p[1], []).append(p[2])
        elif len(p) == 3 and p[0] == "CASE" and p[1] in CASE_IDS and p[2] in ("PASS", "FAIL", "INCONCLUSIVE", "NOT-RUN"):
            case.setdefault(p[1], []).append(p[2])
        elif len(p) == 2 and p[0] in ("CLEANUP", "SETUP") and p[0] not in other:
            other[p[0]] = p[1]
        else:
            bad.append(clean(ln)[:60])
    if bad or "CLEANUP" not in other or "SETUP" not in other:
        return "INCONCLUSIVE", "malformed ledger (%s)" % "; ".join(bad[:3] or ["missing CLEANUP/SETUP"])
    dup = sorted(k for d in (pre, case) for k, v in d.items() if len(v) > 1)
    if dup:
        failed = sorted(k for d in (pre, case) for k, v in d.items() if "FAIL" in v)
        return "INCONCLUSIVE", "duplicate: %s; failed: %s" % (" ".join(dup), " ".join(failed) or "none")
    pre_fail = [k for k in PRE_IDS if pre.get(k) == ["FAIL"]]
    if pre_fail:
        return "NO-GO", "precondition: %s" % " ".join(pre_fail)
    pre_bad = [k for k in PRE_IDS if pre.get(k) != ["PASS"]]
    if pre_bad:
        return "INCONCLUSIVE", "precondition: %s" % " ".join(pre_bad)
    failed = [k for k in CASE_IDS if case.get(k) == ["FAIL"]]
    notpass = [k for k in CASE_IDS if case.get(k) != ["PASS"]]
    if failed:
        return "NO-GO", "failed: %s; inconclusive: %s" % (
            " ".join(failed), " ".join(k for k in notpass if k not in failed) or "none")
    if notpass or other["SETUP"] != "0" or other["CLEANUP"] != "OK":
        return "INCONCLUSIVE", "inconclusive: %s; setup failures: %s; cleanup: %s" % (
            " ".join(notpass) or "none", other["SETUP"], other["CLEANUP"])
    return "GO", "all %d preconditions and %d gating cases PASS; cleanup OK" % (
        len(PRE_IDS), len(CASE_IDS))


def main(argv, stdin):
    cmd = argv[0] if argv else ""
    body = [ln.rstrip("\n") for ln in stdin] if cmd in ("cases", "decide") else []
    if cmd == "cases":
        out = cases(argv[1:], body)
    elif cmd == "noise":
        out = [noise(argv[1:])]
    elif cmd == "decide":
        out = ["%s %s" % decide(body)]
    else:
        raise ValueError("unknown command")
    sys.stdout.write("".join(ln + "\n" for ln in out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin))
