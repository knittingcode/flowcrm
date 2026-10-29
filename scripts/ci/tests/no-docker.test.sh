#!/usr/bin/env bash
#
# Regression tests for scripts/ci/no-docker.sh and its use by
# tests/devenv/unit.sh: a mutated bin/devenv that runs Docker commands must
# be refused or neutralized, whether it is passed as DEVENV or edited in
# place, and whichever way it reaches the Docker CLI or the API.
#
# Nothing here can change anything in the Docker daemon of this machine:
#   - the mutant's payload only reads (`docker version`, GET /version and
#     /_ping); it never removes, prunes or creates anything. A pre-flight
#     check refuses to run any case unless every Docker command of the
#     payload is `version` and every API request a GET of /version or /_ping;
#   - its target is a canary engine of this suite: a Unix socket that
#     answers like Docker and records every request; two cases name the real
#     socket paths and must be refused at the socket;
#   - the harness without the containment (T-05) runs, with its canary,
#     behind an outer guard that leaves only the canary reachable: on macOS
#     a sandbox-exec profile denying every other Unix socket, TCP to
#     22/2375/2376 and beyond loopback, writes under $HOME and starting
#     programs outside the sandbox; on Linux no-docker.sh itself, whose
#     probe runs before the canary is started inside it;
#   - the harness under test (T-03, T-04) runs on Linux behind the same
#     guard, where it must refuse because the canary is a reachable engine.
#     On macOS it runs on the host itself, as a developer would run it:
#     macOS applies a second, different sandbox profile inside a sandbox
#     only if it is identical, so the harness's own isolation cannot be
#     tested behind the guard. Should that isolation fail, the read-only
#     payload would reach the real daemon, which the cases detect.
# T-06 and T-07 run plain commands, no mutant, inside no-docker.sh: they
# check the write limits (macOS) and that loopback ports listening before
# the isolation started cannot be reached from inside it.
# This suite itself runs no docker command.
#
# Usage: no-docker.test.sh
# HARNESS=<path> checks another copy of tests/devenv/unit.sh instead of the
# current one, with every case behind the outer guard (it is unreviewed
# code); a harness without the containment must fail T-03 and T-04. On
# macOS a harness with it fails them too, as it cannot nest its sandbox.

# shellcheck disable=SC2016
# Single-quoted $... in sed and grep patterns and in the mutant stay literal.
# shellcheck disable=SC2319
# "<condition>; result NAME $?" records the status of that condition on purpose.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
root=$(cd -P "$here/../../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/no-docker-tests.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
[ -n "$work" ] && [ -d "$work" ] || exit 2
home=$(cd -P "$HOME" && pwd -P)
[ -n "$home" ] && [ -d "$home" ] || exit 2
nonce=$$-$(date +%s)
canary=$work/canary.sock
home_marker=$home/.flowcrm-no-docker-test-$nonce
# Next to $TMPDIR: writable by the user, outside what the sandbox allows.
tmp=$(cd -P "${TMPDIR:-/tmp}" && pwd -P)
[ -n "$tmp" ] && [ "$tmp" != / ] || exit 2
outside_marker=$(dirname "$tmp")/.flowcrm-no-docker-test-$nonce
trap 'rm -f "$home_marker" "$outside_marker"; rm -rf "$work"' EXIT
pass=0
fail=0

result() { # name ok(0|1) [detail]
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s%s\n' "$1" "${3:+ $3}"
  fi
}

# --- the canary engine --------------------------------------------------------
cat >"$work/canary.py" <<'PY'
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
PY

# drive.sh <case dir> <harness command...>: runs inside the outer guard.
# Starts the canary, records that the harness was started, runs it with
# DOCKER_HOST pointing at the canary and stops the canary again.
cat >"$work/drive.sh" <<'DRIVE'
dir=$1 canary=$2 log=$3
shift 3
rm -f "$canary"
python3 -I "$CANARY_PY" "$canary" "$log" &
cpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -S "$canary" ] && break; sleep 0.2; done
[ -S "$canary" ] || { echo "HARNESS ERROR: the canary engine did not start"; kill "$cpid"; exit 2; }
: >"$dir/started"
DOCKER_HOST=unix://$canary "$@"
rc=$?
sleep 0.5 # let the canary finish writing
kill "$cpid" 2>/dev/null
wait "$cpid" 2>/dev/null
exit "$rc"
DRIVE

export CANARY_PY=$work/canary.py

# A Docker configuration whose context "canary" points at the canary.
ctx=$(printf 'canary' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-64)
mkdir -p "$work/ctxcfg/contexts/meta/$ctx"
printf '{"Name":"canary","Metadata":{},"Endpoints":{"docker":{"Host":"unix://%s","SkipTLSVerify":false}}}\n' \
  "$canary" >"$work/ctxcfg/contexts/meta/$ctx/meta.json"

# --- the mutant ---------------------------------------------------------------
# Inserted after the first line of bin/devenv, so it runs as soon as the file
# is sourced or executed. Each case appends "<case> rc=<status> out=<output>"
# to the log; the mutant then exits 97.
cat >"$work/payload" <<'MUT'
qa_log=@LOG@ qa_canary=@CANARY@ qa_cfg=@CFG@ qa_marker=@MARKER@
qa() { # case command...
  qa_n=$1
  shift
  qa_out=$("$@" 2>&1)
  printf '%s rc=%s out=%s\n' "$qa_n" "$?" "$(printf '%s' "$qa_out" | tr '\n' ' ' | cut -c1-200)" >>"$qa_log"
}
qa_fmt='{{.Server.Version}}'
qa inherited-env docker version --format "$qa_fmt"
qa path-lookup docker -H "unix://$qa_canary" version --format "$qa_fmt"
for qa_p in /usr/local/bin/docker /usr/bin/docker /opt/homebrew/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker; do
  [ ! -x "$qa_p" ] || qa "absolute-path:$qa_p" "$qa_p" -H "unix://$qa_canary" version --format "$qa_fmt"
done
qa builtin-command command docker -H "unix://$qa_canary" version --format "$qa_fmt"
qa env-wrapper env docker -H "unix://$qa_canary" version --format "$qa_fmt"
qa env-docker-host env DOCKER_HOST="unix://$qa_canary" docker version --format "$qa_fmt"
qa context env DOCKER_CONFIG="$qa_cfg" docker --context canary version --format "$qa_fmt"
qa nested-bash bash -c 'docker -H "unix://$1" version --format "$2"' _ "$qa_canary" "$qa_fmt"
qa nested-sh sh -c 'docker -H "unix://$1" version --format "$2"' _ "$qa_canary" "$qa_fmt"
qa_x=$(docker -H "unix://$qa_canary" version --format "$qa_fmt" 2>&1)
printf 'command-substitution rc=%s out=%s\n' "$?" "$(printf '%s' "$qa_x" | tr '\n' ' ')" >>"$qa_log"
qa_x=`docker -H "unix://$qa_canary" version --format "$qa_fmt" 2>&1`
printf 'backticks rc=%s out=%s\n' "$?" "$(printf '%s' "$qa_x" | tr '\n' ' ')" >>"$qa_log"
qa_dk=docker
qa variable "$qa_dk" -H "unix://$qa_canary" version --format "$qa_fmt"
qa quoted "docker" -H "unix://$qa_canary" version --format "$qa_fmt"
qa exec-subshell sh -c 'exec docker -H "unix://$1" version --format "$2"' _ "$qa_canary" "$qa_fmt"
qa xargs sh -c 'echo version | xargs docker -H "unix://$1"' _ "$qa_canary"
(docker -H "unix://$qa_canary" version --format "$qa_fmt" >"$qa_log.bg" 2>&1; echo "background rc=$? out=$(tr '\n' ' ' <"$qa_log.bg")" >>"$qa_log") &
wait
qa sudo sudo -n docker -H "unix://$qa_canary" version --format "$qa_fmt"
qa curl-unix-socket curl -sS --max-time 5 --unix-socket "$qa_canary" http://docker/version
qa python-raw-socket python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"GET /version HTTP/1.0\r\n\r\n"); print(s.recv(4096).decode())' "$qa_canary"
qa real-socket-cli docker -H unix:///var/run/docker.sock version --format "$qa_fmt"
qa real-socket-curl curl -sS --max-time 5 --unix-socket /var/run/docker.sock http://docker/_ping
qa home-write touch "$qa_marker"
exit 97
MUT

# mutant <devenv> <log>: print bin/devenv with the payload after line 1.
mutant() {
  sed -n '1p' "$1"
  sed -e "s|@LOG@|'$2'|" -e "s|@CANARY@|'$canary'|" -e "s|@CFG@|'$work/ctxcfg'|" -e "s|@MARKER@|'$home_marker'|" "$work/payload"
  sed '1d' "$1"
}

# tree <dir> <harness>: a copy of the files the harness needs, with <harness>
# as tests/devenv/unit.sh.
tree() {
  mkdir -p "$1/bin" "$1/tests/devenv" "$1/scripts/ci"
  cp "$root/bin/devenv" "$1/bin/devenv"
  cp "$2" "$1/tests/devenv/unit.sh"
  cp "$root/tests/devenv/tally.sh" "$root/tests/devenv/port-holder.py" "$1/tests/devenv/"
  cp "$root/scripts/ci/no-docker.sh" "$root/scripts/ci/no-docker-probe.py" "$1/scripts/ci/"
  chmod +x "$1/bin/devenv" "$1/tests/devenv/unit.sh" "$1/scripts/ci/no-docker.sh"
  mkdir "$1/sub"
}

# guarded <guard|bare> <command...>: run the command behind the outer guard
# (bare: on macOS without it, see the header).
guarded() {
  local mode=$1
  shift
  case $(uname -s)-$mode in
    Darwin-bare) "$BASH" "$work/drive.sh" "$@" ;;
    Darwin-guard)
      sandbox-exec -p "(version 1)
(allow default)
(deny network-outbound (remote unix-socket))
(allow network-outbound (remote unix-socket (path-literal \"$canary\")))
(deny network-outbound (remote ip))
(allow network-outbound (remote ip \"localhost:*\"))
(deny network-outbound (remote ip \"localhost:22\") (remote ip \"localhost:2375\") (remote ip \"localhost:2376\"))
(deny file-write* (subpath \"$home\"))
(deny process-exec (literal \"/usr/bin/open\") (literal \"/usr/bin/osascript\") (literal \"/bin/launchctl\") (literal \"/usr/bin/ssh\"))
(deny mach-lookup (global-name \"com.apple.coreservices.launchservicesd\") (global-name \"com.apple.coreservices.appleevents\") (global-name-regex #\"^com\\.apple\\.lsd\\.\"))" \
        "$BASH" "$work/drive.sh" "$@"
      ;;
    *) "$root/scripts/ci/no-docker.sh" "$BASH" "$work/drive.sh" "$@" ;;
  esac
}

# run_case <name> <harness> <inplace|devenv> <guard|bare>: run the harness against the
# mutant; sets RC, LOG, OUT, STARTED (the harness was started inside the
# guard) and REQ (requests the canary engine received).
run_case() {
  local dir=$work/$1
  tree "$dir" "$2"
  LOG=$dir/mutant.log
  OUT=$dir/out
  : >"$LOG"
  : >"$dir/canary.log"
  mutant "$root/bin/devenv" "$LOG" >"$dir/mutant"
  rm -f "$home_marker"
  if [ "$3" = inplace ]; then
    cp "$dir/mutant" "$dir/bin/devenv"
    guarded "$4" "$dir/sub" "$canary" "$dir/canary.log" "$BASH" "$dir/tests/devenv/unit.sh" >"$OUT" 2>&1
  else
    guarded "$4" "$dir/sub" "$canary" "$dir/canary.log" /usr/bin/env DEVENV="$dir/mutant" "$BASH" "$dir/tests/devenv/unit.sh" >"$OUT" 2>&1
  fi
  RC=$?
  STARTED=1
  [ -e "$dir/sub/started" ] || STARTED=0
  REQ=$(grep -c . "$dir/canary.log")
}

# The harness without the containment: the lines that re-execute it under
# no-docker.sh removed.
sed '/^# The suite sources and runs bin\/devenv/,/scripts\/ci\/no-docker.sh" "\$BASH"/d' \
  "$root/tests/devenv/unit.sh" >"$work/unit-uncontained.sh"
if cmp -s "$work/unit-uncontained.sh" "$root/tests/devenv/unit.sh" || grep -q no-docker "$work/unit-uncontained.sh" ||
  ! grep -q '^\. "\$devenv_script"$' "$work/unit-uncontained.sh"; then
  echo "HARNESS ERROR: could not remove the containment from tests/devenv/unit.sh" >&2
  exit 2
fi
harness=${HARNESS:-"$root/tests/devenv/unit.sh"}
# Another harness is unreviewed code: run every case behind the guard.
t0304=bare
[ -z "${HARNESS-}" ] || t0304=guard

# The payload is exactly the reviewed text: on macOS the cases T-03 and T-04
# run without the outer guard, so their safety rests on it only reading.
# Changing it needs a new safety review and a new hash here.
payload_sha256=7fd727d79f1eb2e8e3a6f52e25da8f0fe35851b79d262384f6bbc5f5c946ed25
sum=$( { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } <"$work/payload" | cut -c1-64)
if [ "$sum" != "$payload_sha256" ]; then
  echo "HARNESS ERROR: the mutant payload differs from the reviewed one ($sum); refusing to run" >&2
  exit 2
fi
# The paths substituted into it are plain.
for p in "$work" "$home_marker"; do
  case $p in *[!A-Za-z0-9/._-]*) echo "HARNESS ERROR: unexpected character in $p; refusing to run" >&2; exit 2 ;; esac
done

# read_only <payload>: lint (in addition to the hash): every docker command is
# `version` (the xargs case gets it on stdin), and no word of a command that
# changes anything appears (Docker subcommands, HTTP methods other than GET).
# A static check cannot be complete; the hash above is what is relied on.
read_only() {
  local words
  ! grep -qE '(^|[[:space:]"(=;|&])(rm|rmi|prune|kill|stop|restart|pause|create|run|start|push|pull|build|buildx|builder|load|tag|commit|cp|attach|update|rename|login|logout|volume|network|system|compose|swarm|service|stack|secret|config|plugin|image|container|DELETE|POST|PUT|PATCH|-XDELETE|-XPOST|-XPUT|-d|--data|--json|-F|-T)([[:space:]"'"'"');|&]|$)' "$1" || return 1
  words=$(grep -oE '"?(docker|\$qa_dk|\$qa_p)"?( -H "unix://[^"]*"| -H unix:///var/run/docker.sock| --context canary)? [a-z]+' "$1" |
    awk '{print $NF}' | sort -u | tr '\n' ' ')
  [ "$words" = "version " ]
}
read_only "$work/payload" || { echo "HARNESS ERROR: the mutant payload fails the read-only lint; refusing to run" >&2; exit 2; }

# --- T-00 the read-only check itself (payload copies are only read here)
t00_bad=0
for extra in 'docker image ls' '"docker" rmi x' 'docker system df' 'qa_x=$(docker volume ls)' \
  'curl -X DELETE --unix-socket "$qa_canary" http://d/images/x' "python3 -c 's.sendall(b\"POST /x\")'" \
  'docker exec c true' 'docker --context canary info' 'curl -d x --unix-socket "$qa_canary" http://d/x'; do
  { cat "$work/payload"; printf '%s\n' "$extra"; } >"$work/payload-t00"
  if read_only "$work/payload-t00"; then
    t00_bad=$((t00_bad + 1))
    printf 'INFO  T-00 accepted: %s\n' "$extra"
  fi
done
[ "$t00_bad" -eq 0 ]
result "T-00 the read-only lint rejects a payload with a non-read-only command (9 variants)" $?

# --- T-01/T-02 no-docker.sh itself
"$root/scripts/ci/no-docker.sh" --check >/dev/null 2>&1
r=$?
[ "$r" -ne 0 ]
result "T-01 --check fails outside the isolation" $? "(rc $r)"
NO_DOCKER_ACTIVE=1 "$root/scripts/ci/no-docker.sh" touch "$work/t02" >/dev/null 2>&1
r=$?
[ "$r" -eq 125 ] && [ ! -e "$work/t02" ]
result "T-02 claimed but unproven isolation (NO_DOCKER_ACTIVE outside it): refused, command not run" $? "(rc $r)"

# --- T-06/T-07 plain commands (no mutant) inside no-docker.sh
if [ "$(uname -s)" = Darwin ]; then
  "$root/scripts/ci/no-docker.sh" /bin/sh -c 'touch "$1" "$2" 2>/dev/null; : >"$3"' _ \
    "$home_marker" "$outside_marker" "$work/t06" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 0 ] && [ -e "$work/t06" ] && [ ! -e "$home_marker" ] && [ ! -e "$outside_marker" ]
  result "T-06 writes only under \$TMPDIR: not under \$HOME, not next to \$TMPDIR" $? "(rc $r)"
  rm -f "$home_marker" "$outside_marker"
else
  echo "INFO  T-06 skipped: on Linux writes are not restricted (see docs/dev-environment.md)"
fi
cat >"$work/t07.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(60)
PY
python3 -I "$work/t07.py" "$work/t07.port" &
t07pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/t07.port" ] && break; sleep 0.2; done
t07=$("$root/scripts/ci/no-docker.sh" python3 -I -c '
import socket, sys
def reach(port):
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect(("127.0.0.1", port))
        return "reached"
    except OSError:
        return "refused"
    finally:
        s.close()
own = socket.socket()
own.bind(("127.0.0.1", 0))
own.listen(1)
print(reach(int(sys.argv[1])), reach(own.getsockname()[1]))
' "$(cat "$work/t07.port" 2>/dev/null || echo 0)" 2>/dev/null)
r=$?
kill "$t07pid" 2>/dev/null
wait "$t07pid" 2>/dev/null
[ "$r" -eq 0 ] && [ -s "$work/t07.port" ] && [ "$t07" = "refused reached" ]
result "T-07 a loopback port listening before the isolation is unreachable, one opened inside it is reachable" $? "(rc $r: $t07)"

# --- T-03/T-04 the harness against the mutant
check_safe() { # name
  # Refused (125, the mutant never ran) or run isolated (97, every case ran
  # and none reached an engine); either way the canary engine got nothing.
  local cases answered
  cases=$(grep -c ' rc=' "$LOG")
  answered=$(grep -c 'canary-engine' "$LOG")
  [ "$REQ" -eq 0 ] && [ "$answered" -eq 0 ]
  result "$1: no request reached an engine" $? "(canary requests $REQ, answered cases $answered, rc $RC)"
  [ "$STARTED" -eq 1 ]
  result "$1: the harness was started" $?
  if [ "$(uname -s)" = Darwin ] && [ "$t0304" = bare ]; then
    # The harness nests its own sandbox inside the guard and runs the mutant.
    [ "$RC" -eq 97 ] && [ "$cases" -ge 20 ]
    result "$1: the mutant ran to its end inside the harness's isolation" $? "(rc $RC, $cases cases)"
  else
    # The canary is a reachable engine on Linux: the harness must refuse.
    [ "$RC" -eq 125 ] && [ "$cases" -eq 0 ] &&
      grep -q '^no-docker: refused: inside no-docker.sh, but the isolation check fails' "$OUT"
    result "$1: the harness refused before the mutant ran (an engine is reachable)" $? "(rc $RC, $cases cases)"
  fi
  ! grep -E '^(real-socket-cli|real-socket-curl) rc=0 ' "$LOG" >/dev/null
  result "$1: the real Docker socket paths were not reached" $?
  [ ! -e "$home_marker" ]
  result "$1: nothing written under \$HOME" $?
  rm -f "$home_marker"
}
run_case t03 "$harness" devenv "$t0304"
check_safe "T-03 mutant as DEVENV"
run_case t04 "$harness" inplace "$t0304"
check_safe "T-04 mutant edited into bin/devenv"

# --- T-05 control: the same check catches a harness without containment
run_case t05 "$work/unit-uncontained.sh" inplace guard
answered=$(grep -c 'canary-engine' "$LOG")
[ "$STARTED" -eq 1 ] && [ "$REQ" -gt 0 ] && [ "$answered" -gt 0 ] && [ "$RC" -eq 97 ]
result "T-05 control: without the containment the mutant's commands reach the canary engine" $? "(canary requests $REQ, answered cases $answered, rc $RC)"

echo
for f in t03 t04 t05; do
  printf 'INFO  %s cases:\n' "$f"
  sed 's/^/INFO    /' "$work/$f/mutant.log" 2>/dev/null
  printf 'INFO  %s harness output (last lines):\n' "$f"
  tail -n 8 "$work/$f/out" 2>/dev/null | sed 's/^/INFO    /'
done
echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
