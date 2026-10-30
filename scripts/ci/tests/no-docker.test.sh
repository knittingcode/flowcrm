#!/usr/bin/env bash
#
# Regression tests for scripts/ci/no-docker.sh and its use by
# tests/devenv/unit.sh: a mutated bin/devenv that runs Docker commands must
# be refused or neutralized, whether it is passed as DEVENV or edited in
# place, and whichever way it reaches the Docker CLI or the API; and the
# isolation's limits on writes, signals, processes, namespaces and supported
# platforms must hold.
#
# Nothing here can change anything in the Docker daemon of this machine:
#   - the mutant's payload only reads (`docker version`, GET /version and
#     /_ping); it never removes, prunes or creates anything. A pre-flight
#     check refuses to run any case unless every Docker command of the
#     payload is `version` and every API request a GET of /version or /_ping,
#     and its sha256 is checked again before every mutant is made from it;
#   - its target is a canary engine of this suite: a Unix socket that
#     answers like Docker and records every request; two cases name the real
#     socket paths and must be refused at the socket;
#   - the harness without the containment (T-05) runs, with its canary,
#     behind an outer guard that leaves only the canary reachable: on macOS
#     a sandbox-exec profile denying every other Unix socket, TCP to
#     22/2375/2376 and beyond loopback, writes under $HOME and to this
#     suite's helpers and starting programs outside the sandbox; on Linux
#     no-docker.sh itself, whose probe runs before the canary is started
#     inside it;
#   - the harness under test (T-03, T-04) runs on Linux behind the same
#     guard, where it must refuse because the canary is a reachable engine.
#     On macOS it runs on the host itself, as a developer would run it:
#     macOS applies a second, different sandbox profile inside a sandbox
#     only if it is identical, so the harness's own isolation cannot be
#     tested behind the guard. Should that isolation fail, the read-only
#     payload would reach the real daemon, which the cases detect;
#   - the helpers this suite runs outside any isolation (drive.sh,
#     canary.py) and the payload are kept outside every directory the code
#     under test can write, and their sha256 is checked immediately before
#     each such run (T-14);
#   - the other cases run plain commands that only print, connect to this
#     suite's own listeners, write marker files in directories of this
#     suite (and in protected places, where the write must fail; a marker
#     that was written anyway is removed), send signal 0 or TERM to this
#     suite's own `sleep` canaries, or sleep.
# This suite itself runs no docker command.
#
# T-11 to T-15 are macOS only, T-16 to T-18 Linux only (each prints INFO on
# the other platform); T-19 is static and runs on both. Each case says how
# it fails against the no-docker.sh of 38b5ebd, which these cases were
# written to catch.
#
# Usage: no-docker.test.sh
# HARNESS=<path> checks another copy of tests/devenv/unit.sh instead of the
# current one, with every case behind the outer guard (it is unreviewed
# code); a harness without the containment must fail T-03 and T-04. On
# macOS a harness with it fails them too, as it cannot nest its sandbox.

# shellcheck disable=SC2016
# Single-quoted $... in sed and grep patterns and in the payloads stay literal.
# shellcheck disable=SC2319
# "<condition>; result NAME $?" records the status of that condition on purpose.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
root=$(cd -P "$here/../../.." && pwd -P)
nd=$root/scripts/ci/no-docker.sh
os=$(uname -s)
work=$(mktemp -d "${TMPDIR:-/tmp}/no-docker-tests.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
[ -n "$work" ] && [ -d "$work" ] || exit 2
# Read-only material (helpers, payload, harness trees): outside every
# directory code under test may write. On Linux it must also be visible
# inside the isolation, which hides /tmp and /var/tmp: $RUNNER_TEMP is
# mounted read-only there.
if [ "$os" = Linux ] && [ -n "${RUNNER_TEMP-}" ]; then
  ro=$(mktemp -d "$RUNNER_TEMP/no-docker-tests-ro.XXXXXX") || exit 2
else
  ro=$work/ro
  mkdir "$ro" || exit 2
fi
ro=$(cd -P "$ro" && pwd -P)
helpers=$ro/helpers
mkdir "$helpers" || exit 2
# Directories for --work: fresh and empty; on Linux under /var/tmp.
if [ "$os" = Linux ]; then
  vt=$(mktemp -d /var/tmp/no-docker-tests.XXXXXX) || exit 2
else
  vt=$work/w
  mkdir -m 700 "$vt" || exit 2
fi
vt=$(cd -P "$vt" && pwd -P)
home=$(cd -P "$HOME" && pwd -P)
[ -n "$home" ] && [ -d "$home" ] || exit 2
nonce=$$-$(date +%s)
home_marker=$home/.flowcrm-no-docker-test-$nonce
tmp=$(cd -P "${TMPDIR:-/tmp}" && pwd -P)
[ -n "$tmp" ] && [ "$tmp" != / ] || exit 2
# Next to $TMPDIR: writable by the user, outside what the sandbox allows.
outside_marker=$(dirname "$tmp")/.flowcrm-no-docker-test-$nonce
tmp_marker=/private/tmp/.flowcrm-no-docker-test-$nonce
# In $TMPDIR itself, outside the run's directory.
t11_marker=$tmp/.flowcrm-no-docker-test-t11-$nonce
cleanup() {
  rm -f "$home_marker" "$outside_marker" "$tmp_marker" "$t11_marker"
  rm -rf "$work" "$ro" "$vt"
}
trap cleanup EXIT
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

sha() { # file: its sha256
  { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } <"$1" | cut -c1-64
}

# Files that code under test could write are read only when they are
# regular files, so a planted FIFO or link cannot hang or redirect a read.
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
count_in() { # pattern file: number of matching lines, 0 if not a regular file
  local n=0
  regular "$2" && n=$(grep -c -- "$1" <"$2" 2>/dev/null)
  echo "${n:-0}"
}

new_work() { # a fresh, empty directory for --work
  mktemp -d "$vt/w.XXXXXX"
}

# --- the canary engine --------------------------------------------------------
cat >"$helpers/canary.py" <<'PY'
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

# drive.sh <canary.py> <data dir> <canary socket> <harness command...>:
# starts the canary (logging to <data dir>/canary.log), records that the
# harness was started (<data dir>/drive-started), runs it with DOCKER_HOST
# pointing at the canary and stops the canary again.
cat >"$helpers/drive.sh" <<'DRIVE'
canary_py=$1 data=$2 canary=$3
shift 3
mkdir -p "$data" || exit 2
: >"$data/canary.log" || exit 2
rm -f "$canary"
python3 -I "$canary_py" "$canary" "$data/canary.log" &
cpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -S "$canary" ] && break; sleep 0.2; done
[ -S "$canary" ] || { echo "HARNESS ERROR: the canary engine did not start"; kill "$cpid"; exit 2; }
: >"$data/drive-started"
DOCKER_HOST=unix://$canary "$@"
rc=$?
sleep 0.5 # let the canary finish writing
kill "$cpid" 2>/dev/null
wait "$cpid" 2>/dev/null
exit "$rc"
DRIVE

# A Docker configuration whose context "canary" points at a canary socket.
ctx=$(printf 'canary' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-64)
ctxcfg() { # dir canary
  mkdir -p "$1/contexts/meta/$ctx" || return 1
  printf '{"Name":"canary","Metadata":{},"Endpoints":{"docker":{"Host":"unix://%s","SkipTLSVerify":false}}}\n' \
    "$2" >"$1/contexts/meta/$ctx/meta.json"
}

# --- the mutant ---------------------------------------------------------------
# Inserted after the first line of bin/devenv, so it runs as soon as the file
# is sourced or executed. Each case appends "<case> rc=<status> out=<output>"
# to the log; the mutant then exits 97.
cat >"$helpers/payload" <<'MUT'
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

# The payload is exactly the reviewed text: on macOS the cases T-03 and T-04
# run without the outer guard, so their safety rests on it only reading.
# Changing it needs a new safety review and a new hash here.
payload_sha256=7fd727d79f1eb2e8e3a6f52e25da8f0fe35851b79d262384f6bbc5f5c946ed25
helper_sums="canary.py=$(sha "$helpers/canary.py") drive.sh=$(sha "$helpers/drive.sh") payload=$(sha "$helpers/payload")"
case " $helper_sums " in
  *" payload=$payload_sha256 "*) ;;
  *) echo "HARNESS ERROR: the mutant payload differs from the reviewed one; refusing to run" >&2; exit 2 ;;
esac

# verify_helpers <dir>: the helpers and the payload in <dir> are regular
# files with the sha256 recorded when this suite wrote them. Called
# immediately before every run of drive.sh and before every mutant is made.
verify_helpers() {
  local f want got
  for f in canary.py drive.sh payload; do
    want=${helper_sums#*"$f="}
    want=${want%% *}
    if [ ! -f "$1/$f" ] || [ -L "$1/$f" ]; then
      echo "HARNESS ERROR: $1/$f is not a regular file; refusing to run" >&2
      return 1
    fi
    got=$(sha "$1/$f")
    if [ "$got" != "$want" ]; then
      echo "HARNESS ERROR: $1/$f changed since it was written ($got); refusing to run" >&2
      return 1
    fi
  done
}

# bare <helpers dir> <data dir> <canary> <command...>: drive.sh outside any
# isolation, only after its helpers verified.
bare() {
  local dir=$1
  shift
  verify_helpers "$dir" || return 2
  "$BASH" "$dir/drive.sh" "$dir/canary.py" "$@"
}

# The paths substituted into the mutant and the profiles are plain.
for p in "$work" "$ro" "$vt" "$home_marker" "$tmp"; do
  case $p in *[!A-Za-z0-9/._-]*) echo "HARNESS ERROR: unexpected character in $p; refusing to run" >&2; exit 2 ;; esac
done

# mutant <devenv> <log> <canary> <cfg>: print bin/devenv with the payload
# after line 1.
mutant() {
  verify_helpers "$helpers" || return 1
  sed -n '1p' "$1"
  sed -e "s|@LOG@|'$2'|" -e "s|@CANARY@|'$3'|" -e "s|@CFG@|'$4'|" -e "s|@MARKER@|'$home_marker'|" "$helpers/payload"
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
}

# run_case <name> <harness> <inplace|devenv> <guard|bare>: run the harness
# against the mutant; sets RC, LOG, OUT, STARTED (the harness was started)
# and REQ (requests the canary engine received).
#   macOS: the canary and drive.sh's records are in <data>, outside the
#     isolation; the mutant's log is in the run directory W the harness's
#     no-docker.sh gets (NO_DOCKER_WORK), the only place it may write.
#   Linux: the guard is `no-docker.sh --work G`; the canary, the records
#     and the log are in G, the tree and helpers are visible read-only.
run_case() {
  local name=$1 harness=$2 how=$3 mode=$4 t=$ro/$1 g="" w="" data canary cmd
  tree "$t" "$harness"
  if [ "$os" = Linux ]; then
    g=$(new_work) || exit 2
    data=$g/d
    LOG=$data/mutant.log
  else
    data=$work/$name
    mkdir "$data" || exit 2
    w=$(new_work) || exit 2
    LOG=$w/mutant.log
  fi
  canary=$data/c
  OUT=$work/$name.out
  ctxcfg "$t/ctxcfg" "$canary" || exit 2
  mutant "$root/bin/devenv" "$LOG" "$canary" "$t/ctxcfg" >"$t/mutant" || exit 2
  [ "$how" = inplace ] && cp "$t/mutant" "$t/bin/devenv"
  cmd=(/usr/bin/env)
  [ -z "$w" ] || cmd+=("NO_DOCKER_WORK=$w")
  [ "$how" = inplace ] || cmd+=("DEVENV=$t/mutant")
  cmd+=("$BASH" "$t/tests/devenv/unit.sh")
  rm -f "$home_marker"
  case $os-$mode in
    Darwin-bare) bare "$helpers" "$data" "$canary" "${cmd[@]}" ;;
    Darwin-guard)
      # The write policy of no-docker.sh: only the case's directories, the
      # /dev nodes of its profile and bash 3.2's here-documents; plus its
      # other denies and the ports listening now. Only the canary socket
      # is reachable.
      verify_helpers "$helpers" || exit 2
      held=""
      for port in $(python3 -I "$root/scripts/ci/no-docker-probe.py" --listening) ; do
        case $port in *[!0-9]* | "") echo "HARNESS ERROR: unexpected port $port" >&2; exit 2 ;; esac
        held="$held (remote ip \"localhost:$port\")"
      done
      sandbox-exec -p "(version 1)
(allow default)
(deny network-outbound (remote unix-socket))
(allow network-outbound (remote unix-socket (path-literal \"$canary\")))
(deny network-outbound (remote ip))
(allow network-outbound (remote ip \"localhost:*\"))
(deny network-outbound (remote ip \"localhost:22\") (remote ip \"localhost:2375\") (remote ip \"localhost:2376\")$held)
(deny file-write*)
(allow file-write* (subpath \"$data\") (subpath \"$w\") (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/[0-9]+\$\") (literal \"/private/tmp\") (regex #\"^/private/tmp/sh-thd[^/]*\$\"))
(deny user-preference-write)
(deny file-ioctl (ioctl-command #x80017472))
(deny signal)
(allow signal (target same-sandbox))
(deny process-exec (literal \"/usr/bin/open\") (literal \"/usr/bin/osascript\") (literal \"/bin/launchctl\") (literal \"/usr/bin/ssh\"))
(deny job-creation)
(deny lsopen)
(deny appleevent-send)
(deny mach-lookup (global-name \"com.apple.coreservices.launchservicesd\") (global-name \"com.apple.coreservices.appleevents\") (global-name-regex #\"^com\\.apple\\.lsd\\.\") (global-name \"com.apple.xpc.smd\") (global-name-regex #\"^com\\.apple\\.backgroundtaskmanagement\") (global-name-regex #\"^com\\.apple\\.coreservices\\.sharedfilelistd\") (global-name-regex #\"^com\\.docker\\.\") (global-name-regex #\"^com\\.electron\\.dockerdesktop\\.\"))" \
        "$BASH" "$helpers/drive.sh" "$helpers/canary.py" "$data" "$canary" "${cmd[@]}"
      ;;
    *)
      verify_helpers "$helpers" || exit 2
      "$nd" --work "$g" "$BASH" "$helpers/drive.sh" "$helpers/canary.py" "$data" "$canary" "${cmd[@]}"
      ;;
  esac >"$OUT" 2>&1
  RC=$?
  STARTED=1
  [ -e "$data/drive-started" ] || STARTED=0
  REQ=$(count_in . "$data/canary.log")
}

# The harness without the containment: the lines that re-execute it under
# no-docker.sh removed.
sed '/^# The suite sources and runs bin\/devenv/,/^  exec .*scripts\/ci\/no-docker.sh" /d' \
  "$root/tests/devenv/unit.sh" >"$ro/unit-uncontained.sh"
if cmp -s "$ro/unit-uncontained.sh" "$root/tests/devenv/unit.sh" || grep -q no-docker "$ro/unit-uncontained.sh" ||
  ! grep -q '^\. "\$devenv_script"$' "$ro/unit-uncontained.sh"; then
  echo "HARNESS ERROR: could not remove the containment from tests/devenv/unit.sh" >&2
  exit 2
fi
harness=${HARNESS:-"$root/tests/devenv/unit.sh"}
# Another harness is unreviewed code: run every case behind the guard.
t0304=bare
[ -z "${HARNESS-}" ] || t0304=guard

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
read_only "$helpers/payload" || { echo "HARNESS ERROR: the mutant payload fails the read-only lint; refusing to run" >&2; exit 2; }

# --- T-00 the read-only check itself (payload copies are only read here)
t00_bad=0
for extra in 'docker image ls' '"docker" rmi x' 'docker system df' 'qa_x=$(docker volume ls)' \
  'curl -X DELETE --unix-socket "$qa_canary" http://d/images/x' "python3 -c 's.sendall(b\"POST /x\")'" \
  'docker exec c true' 'docker --context canary info' 'curl -d x --unix-socket "$qa_canary" http://d/x'; do
  { cat "$helpers/payload"; printf '%s\n' "$extra"; } >"$work/payload-t00"
  if read_only "$work/payload-t00"; then
    t00_bad=$((t00_bad + 1))
    printf 'INFO  T-00 accepted: %s\n' "$extra"
  fi
done
[ "$t00_bad" -eq 0 ]
result "T-00 the read-only lint rejects a payload with a non-read-only command (9 variants)" $?

# --- T-01/T-02 no-docker.sh itself
"$nd" --check >/dev/null 2>&1
r=$?
[ "$r" -ne 0 ]
result "T-01 --check fails outside the isolation" $? "(rc $r)"
NO_DOCKER_ACTIVE=1 "$nd" touch "$work/t02" >/dev/null 2>&1
r=$?
[ "$r" -eq 125 ] && [ ! -e "$work/t02" ]
result "T-02 claimed but unproven isolation (NO_DOCKER_ACTIVE outside it): refused, command not run" $? "(rc $r)"

if [ "$os" = Darwin ]; then
  # --- T-06 plain commands (no mutant): the write limits
  w6=$(new_work) || exit 2
  "$nd" --work "$w6" /bin/bash -c 'touch "$1" "$2" "$3" 2>/dev/null; cat >"$4" <<EOF
here-document
EOF' _ "$home_marker" "$outside_marker" "$tmp_marker" "$w6/t06" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 0 ] && [ "$(cat "$w6/t06" 2>/dev/null)" = here-document ] &&
    [ ! -e "$home_marker" ] && [ ! -e "$outside_marker" ] && [ ! -e "$tmp_marker" ]
  result "T-06 writes only in the run's directory (bash 3.2 here-documents work): not under \$HOME, next to \$TMPDIR or in /tmp" $? "(rc $r)"
  rm -f "$home_marker" "$outside_marker" "$tmp_marker"

  # T-08: the held-port list must be complete. A netstat without its column
  # header, or with a LISTEN row that cannot be parsed, refuses; one with
  # the header and no LISTEN row is a provably empty list.
  mkdir -p "$work/t08"
  t08() { # name netstat-output expected-rc
    local w
    printf '#!/bin/sh\nprintf "%%b" %s\n' "'$2'" >"$work/t08/netstat"
    chmod +x "$work/t08/netstat"
    w=$(new_work) || exit 2
    PATH=$work/t08:$PATH "$nd" --work "$w" /usr/bin/touch "$w/ran" >/dev/null 2>&1
    r=$?
    if [ "$3" -eq 0 ]; then
      [ "$r" -eq 0 ] && [ -e "$w/ran" ]
    else
      [ "$r" -eq 125 ] && [ ! -e "$w/ran" ]
    fi
    result "T-08 $1" $? "(rc $r)"
  }
  hdr='Active Internet connections (including servers)\nProto Recv-Q Send-Q  Local Address          Foreign Address        (state)\n'
  t08 "netstat without its column header: refused, command not run" 'tcp4 0 0 127.0.0.1.1 *.* LISTEN\n' 125
  t08 "an unparsable LISTEN row: refused, command not run" "${hdr}tcp4 0 0 garbage *.* LISTEN\n" 125
  t08 "header and no LISTEN row: an empty list is accepted" "${hdr}tcp4 0 0 127.0.0.1.1 127.0.0.1.2 ESTABLISHED\n" 0

  # T-09: $TMPDIR must not be /tmp.
  TMPDIR=/tmp "$nd" /usr/bin/touch "$work/t09" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 125 ] && [ ! -e "$work/t09" ]
  result "T-09 TMPDIR=/tmp: refused, command not run" $? "(rc $r)"

  # T-10: no preference written through cfprefsd, no keystroke injected
  # into the terminal (TIOCSTI), run in a pseudo-terminal of its own.
  t10_domain=com.flowcrm.no-docker-test-$nonce
  "$nd" /usr/bin/defaults write "$t10_domain" k v >/dev/null 2>&1
  t10_pref=$(defaults read "$t10_domain" k 2>/dev/null)
  defaults delete "$t10_domain" >/dev/null 2>&1
  rm -f "$home/Library/Preferences/$t10_domain.plist"
  [ -z "$t10_pref" ]
  result "T-10 defaults write inside the isolation changes no preference" $?
  t10=$(script -q /dev/null "$nd" python3 -I -c '
import fcntl, os
fd = os.open("/dev/tty", os.O_RDWR)
try:
    fcntl.ioctl(fd, 0x80017472, b" ")
    print("t10-injected")
except OSError as e:
    print("t10-denied", e.errno)
' </dev/null 2>/dev/null | tr -d '\r')
  case $t10 in *"t10-denied 1"*) r=0 ;; *) r=1 ;; esac
  result "T-10 TIOCSTI on the controlling terminal is denied" $r "($(printf '%s' "$t10" | grep t10-))"

  # --- T-11 writes in $TMPDIR outside the run's directory are denied; in it
  # they work, and the command's $TMPDIR is inside it.
  # On 38b5ebd: the profile allowed the whole $TMPDIR, so the marker in
  # $TMPDIR is written (and --work is not an option there: rc 127).
  w11=$(new_work) || exit 2
  "$nd" --work "$w11" /bin/sh -c 'touch "$1" 2>/dev/null; touch "$2" && touch "$TMPDIR/t11"' _ "$t11_marker" "$w11/inside" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 0 ] && [ ! -e "$t11_marker" ] && [ -e "$w11/inside" ] && [ -e "$w11/tmp/t11" ]
  result "T-11 --work: writes in the run's directory and its \$TMPDIR work, in \$TMPDIR outside it are denied" $? "(rc $r)"
  rm -f "$t11_marker"
  t11=$("$nd" /bin/sh -c 'touch "$1" 2>/dev/null; touch "$TMPDIR/t11" && printf "%s" "$TMPDIR"' _ "$t11_marker" 2>/dev/null)
  r=$?
  case $t11 in "$tmp"/no-docker.*/tmp) t11ok=0 ;; *) t11ok=1 ;; esac
  [ "$r" -eq 0 ] && [ "$t11ok" -eq 0 ] && [ ! -e "$t11_marker" ]
  result "T-11 without --work: \$TMPDIR is in a fresh directory of the run; \$TMPDIR itself is not writable" $? "(rc $r, TMPDIR $t11)"
  rm -f "$t11_marker"

  # --- T-12 $TMPDIR allowlist: only the per-user /private/var/folders/../T.
  # On 38b5ebd: a denylist accepted a user-owned directory that is not that
  # one, and /private/var/tmp; the command ran there (rc 0, marker written).
  mkdir -m 700 "$work/t12" "$work/t12/T"
  t12v=$(mktemp -d /private/var/tmp/no-docker-tests-t12.XXXXXX) || exit 2
  t12() { # name tmpdir expected-rc
    local m=$2/.t12-ran-$nonce
    if [ "$3" -eq 0 ]; then
      if [ -n "$2" ]; then env TMPDIR="$2" "$nd" /usr/bin/true; else env -u TMPDIR "$nd" /usr/bin/true; fi >/dev/null 2>&1
      r=$?
      [ "$r" -eq 0 ]
    else
      env TMPDIR="$2" "$nd" /usr/bin/touch "$m" >/dev/null 2>&1
      r=$?
      [ "$r" -eq 125 ] && [ ! -e "$m" ]
    fi
    result "T-12 $1" $? "(rc $r)"
    rm -f "$m"
  }
  t12 "a user-owned directory named T, not the per-user one: refused" "$work/t12/T" 125
  t12 "/private/var/tmp/<own directory>: refused" "$t12v" 125
  t12 "/private/var/tmp: refused" /private/var/tmp 125
  t12 "/: refused" / 125
  t12 "the per-user directory: accepted" "$tmp" 0
  t12 "TMPDIR unset (getconf DARWIN_USER_TEMP_DIR): accepted" "" 0
  rmdir "$t12v" 2>/dev/null

  # --- T-13 signals: a canary `sleep` started here, outside, cannot be
  # signalled from inside (kill -0 gives EPERM) and is alive afterwards; the
  # command can signal its own child and its own process group.
  # On 38b5ebd: the profile had no signal rule, so kill -0 succeeded.
  sleep 120 &
  t13pid=$!
  t13=$("$nd" python3 -I -c '
import os, signal, subprocess, sys
try:
    os.kill(int(sys.argv[1]), 0)
    print("outside-reached")
except PermissionError:
    print("outside-eperm")
except OSError as e:
    print("outside-error", e.errno)
c = subprocess.Popen(["/bin/sleep", "30"])
os.kill(c.pid, signal.SIGTERM)
print("own-child", c.wait())
g = subprocess.Popen(["/bin/sleep", "30"], preexec_fn=os.setpgrp)
os.killpg(g.pid, signal.SIGTERM)
print("own-group", g.wait())
' "$t13pid" 2>/dev/null | tr '\n' ' ')
  r=$?
  kill -0 "$t13pid" 2>/dev/null
  alive=$?
  kill -TERM "$t13pid" 2>/dev/null
  wait "$t13pid" 2>/dev/null
  [ "$t13" = "outside-eperm own-child -15 own-group -15 " ] && [ "$alive" -eq 0 ]
  result "T-13 no signal to a process outside (EPERM, canary alive); own child and process group can be signalled" $? "($t13, canary alive rc $alive)"

  # --- T-14 integrity of what this suite runs outside any isolation.
  # On 38b5ebd: the helpers were in $TMPDIR, which the sandbox allowed to
  # write, so the append below succeeded.
  cp "$helpers/drive.sh" "$ro/t14-target"
  t14_before=$(sha "$ro/t14-target")
  t14=$("$nd" /bin/sh -c 'printf "# changed\n" >>"$1" 2>/dev/null; echo "append-rc=$?"' _ "$ro/t14-target" 2>/dev/null)
  [ "$t14" = "append-rc=1" ] && [ "$(sha "$ro/t14-target")" = "$t14_before" ]
  result "T-14 the suite's helpers cannot be changed from inside the isolation" $? "($t14)"
  # The check before a bare run, on a tampered copy: drive.sh is not run.
  mkdir "$work/t14-copy"
  cp "$helpers/canary.py" "$helpers/drive.sh" "$helpers/payload" "$work/t14-copy/"
  printf '# tampered\n' >>"$work/t14-copy/drive.sh"
  bare "$work/t14-copy" "$work/t14-data" "$work/t14-data/c" /usr/bin/touch "$work/t14-ran" >/dev/null 2>&1
  r=$?
  verify_helpers "$helpers" 2>/dev/null
  intact=$?
  [ "$r" -eq 2 ] && [ ! -e "$work/t14-ran" ] && [ ! -e "$work/t14-data" ] && [ "$intact" -eq 0 ]
  result "T-14 a changed helper is detected before a bare run, which is then not made" $? "(rc $r, intact helpers $intact)"

  # --- T-15 --work DIR: accepted for a fresh, empty, own 0700 directory
  # under $TMPDIR or /private/var/tmp (writes work there and only there);
  # refused otherwise. (New option: on 38b5ebd "--work" was run as the
  # command, rc 127, so every case fails there.)
  w15=$(new_work) || exit 2
  "$nd" --work "$w15" /bin/sh -c 'touch "$1" && { touch "$2" 2>/dev/null; true; }' _ "$w15/inside" "$work/t15-outside" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 0 ] && [ -e "$w15/inside" ] && [ ! -e "$work/t15-outside" ]
  result "T-15 --work under \$TMPDIR: accepted, writable, nothing outside it" $? "(rc $r)"
  w15v=$(mktemp -d /private/var/tmp/no-docker-tests-t15.XXXXXX) || exit 2
  "$nd" --work "$w15v" /usr/bin/touch "$w15v/inside" >/dev/null 2>&1
  r=$?
  [ "$r" -eq 0 ] && [ -e "$w15v/inside" ]
  result "T-15 --work under /private/var/tmp: accepted" $? "(rc $r)"
  rm -rf "$w15v"
  mkdir -m 700 "$work/t15" "$work/t15/full" "$work/t15/m755" "$work/t15/real" "$work/t15/real/w"
  chmod 755 "$work/t15/m755"
  : >"$work/t15/full/x"
  ln -s "$work/t15/real" "$work/t15/link"
  ln -s "$work/t15" "$work/t15/plink"
  t15() { # name dir
    local out
    out=$("$nd" --work "$2" /bin/echo ran 2>/dev/null)
    r=$?
    [ "$r" -eq 125 ] && [ -z "$out" ]
    result "T-15 --work $1: refused, command not run" $? "(rc $r)"
  }
  t15 "a symbolic link" "$work/t15/link"
  t15 "with a symbolic link in its path" "$work/t15/plink/real/w"
  t15 "a non-empty directory" "$work/t15/full"
  t15 "mode 0755" "$work/t15/m755"
  t15 "\$HOME" "$home"
  t15 "/tmp" /tmp
  t15 "/private/var/tmp itself" /private/var/tmp
  t15 "a relative path" t15
else
  echo "INFO  T-06, T-08 to T-15 skipped: macOS sandbox profile only"
fi

# --- T-07 loopback ports listening before the isolation
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
# On Linux, no-docker.sh frames the output with ::stop-commands:: lines.
t07=$("$nd" python3 -I -c '
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
' "$(cat "$work/t07.port" 2>/dev/null || echo 0)" 2>/dev/null | grep -v '^::')
r=$?
kill "$t07pid" 2>/dev/null
wait "$t07pid" 2>/dev/null
[ "$r" -eq 0 ] && [ -s "$work/t07.port" ] && [ "$t07" = "refused reached" ]
result "T-07 a loopback port listening before the isolation is unreachable, one opened inside it is reachable" $? "(rc $r: $t07)"

if [ "$os" = Linux ]; then
  echo "INFO  mount: $(mount --version 2>&1 | head -n 1)"
  echo "INFO  mounts outside the isolation:"
  findmnt -rn -o TARGET,FSTYPE,OPTIONS 2>&1 | sed 's/^/INFO    /'
  echo "INFO  mounts inside the isolation (and the probe's report):"
  "$nd" findmnt -rn -o TARGET,FSTYPE,OPTIONS 2>&1 | sed 's/^/INFO    /'

  # --- T-16 a canary inside the isolation: private pid view, no engine or
  # session socket, read-only $HOME/workspace/RUNNER_TEMP, private /tmp,
  # read-only mounts, masked cgroups, private IPC, loopback only.
  # On 38b5ebd: no pid namespace (pid 1 is the runner's systemd, foreign
  # processes visible), and $HOME and the workspace were writable.
  cat >"$ro/t16.py" <<'PY'
import errno, os, socket, sys
ipc_host, out_tmp, out_shm, in_tmp, socklist, nonce = sys.argv[1:7]
targets = sys.argv[7:]
me = str(os.getuid())
def say(good, text):
    print(("t16 ok   " if good else "t16 bad  ") + text)
def status(pid):
    st = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            st[k] = v.strip()
    return st
st = status("self")
say(len(st.get("NSpid", "").split()) >= 2, f"NSpid {st.get('NSpid')}")
s1 = status(1)
say(s1["Uid"].split()[0] == "0" and s1["Name"] == "sh", f"pid 1 is the isolation's root shell ({s1['Name']}, uid {s1['Uid'].split()[0]})")
others = []
for d in os.listdir("/proc"):
    if d.isdigit() and d != "1":
        try:
            s = status(d)
        except OSError:
            continue
        if any(u != me for u in s["Uid"].split()) or s["Name"] in ("systemd", "Runner.Worker", "Runner.Listener", "dockerd", "containerd"):
            others.append(f"{d}:{s['Name']}")
say(not others, f"no foreign process visible ({' '.join(others) or 'none'})")
try:
    os.listdir("/proc/1/root")
    say(False, "/proc/1/root is not readable")
except OSError as e:
    say(e.errno in (errno.EACCES, errno.EPERM), f"/proc/1/root is not readable ({errno.errorcode.get(e.errno)})")
paths = ["/var/run/docker.sock", "/run/docker.sock", "/run/containerd/containerd.sock", "/run/dbus/system_bus_socket",
         f"/run/user/{me}/bus", f"/run/user/{me}/docker.sock", "/proc/1/root/var/run/docker.sock"]
with open(socklist, "rb") as f:
    paths += [os.fsdecode(p) for p in f.read().split(b"\0") if p]
reached = []
for p in paths:
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        s = socket.socket(socket.AF_UNIX, kind)
        s.settimeout(2)
        try:
            s.connect(p)
            reached.append(p)
            break
        except OSError:
            pass
        finally:
            s.close()
say(not reached, f"none of {len(paths)} engine, session and host sockets connects ({' '.join(reached) or 'none'})")
for t in targets:
    p = os.path.join(t, f".flowcrm-no-docker-test-t16-{nonce}")
    try:
        os.close(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        os.unlink(p)
        say(False, f"write in {t} fails (written, removed again)")
    except OSError as e:
        say(e.errno == errno.EROFS, f"write in {t} fails with EROFS ({errno.errorcode.get(e.errno)})")
say(not os.path.exists(out_tmp), "a file in the caller's /tmp is not visible")
say(not os.path.exists(out_shm), "a file in the caller's /dev/shm is not visible")
try:
    os.close(os.open(in_tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    say(True, "the private /tmp is writable")
except OSError as e:
    say(False, f"the private /tmp is writable ({e})")
allowed = {"/tmp", "/var/tmp", "/dev/shm", "/run", "/var/run", "/dev/mqueue", "/proc", "/dev", "/dev/pts",
           os.environ.get("NO_DOCKER_RUN_DIR", "")}
rw = []
cgroup_fs = "none"
with open("/proc/self/mountinfo") as f:
    rows = [line.split() for line in f]
for r in rows:
    point = r[4].replace("\\040", " ")
    try:
        fd = os.open(point, os.O_PATH | os.O_NOFOLLOW)
    except OSError:
        continue
    try:
        mnt = [l.split()[1] for l in open(f"/proc/self/fdinfo/{fd}") if l.startswith("mnt_id:")][0]
    finally:
        os.close(fd)
    if mnt != r[0]:
        continue
    if point == "/sys/fs/cgroup":
        cgroup_fs = r[r.index("-") + 1]
    if point not in allowed and "ro" not in r[5].split(","):
        rw.append(point)
say(not rw, f"every other reachable mount is read-only ({' '.join(rw) or 'none writable'})")
say(cgroup_fs != "cgroup2" and not os.access("/sys/fs/cgroup/cgroup.procs", os.W_OK)
    and not os.access("/sys/fs/cgroup/cgroup.kill", os.W_OK), f"/sys/fs/cgroup is masked ({cgroup_fs})")
say(os.readlink("/proc/self/ns/ipc") != ipc_host, f"private IPC namespace ({os.readlink('/proc/self/ns/ipc')}, caller {ipc_host})")
names = sorted(n for _, n in socket.if_nameindex())
say(names == ["lo"], f"only loopback ({' '.join(names)})")
PY
  t16_tmp=/tmp/.flowcrm-no-docker-test-t16-$nonce
  t16_shm=/dev/shm/.flowcrm-no-docker-test-t16-$nonce
  t16_in=/tmp/.flowcrm-no-docker-test-t16-in-$nonce
  : >"$t16_tmp"
  : 2>/dev/null >"$t16_shm"
  # Sockets of the host, found here independently of no-docker.sh.
  { python3 -I -c '
import sys
with open("/proc/net/unix", "rb") as f:
    next(f)
    for line in f:
        p = line.split(None, 7)
        if len(p) == 8 and p[7].startswith(b"/"):
            sys.stdout.buffer.write(p[7].rstrip(b"\n") + b"\0")
'
    find "$home" -xdev -type s -print0 2>/dev/null
  } >"$ro/t16-sockets"
  t16_targets=("$home")
  for v in GITHUB_WORKSPACE RUNNER_TEMP; do [ -z "${!v-}" ] || t16_targets+=("${!v}"); done
  [ ! -d /opt/hostedtoolcache ] || t16_targets+=(/opt/hostedtoolcache)
  t16=$("$nd" python3 -I "$ro/t16.py" "$(readlink /proc/self/ns/ipc)" "$t16_tmp" "$t16_shm" "$t16_in" \
    "$ro/t16-sockets" "$nonce" "${t16_targets[@]}" 2>&1)
  r=$?
  printf '%s\n' "$t16" | grep '^t16 ' | sed 's/^/INFO    /'
  t16_left=""
  for t in "${t16_targets[@]}"; do
    if [ -e "$t/.flowcrm-no-docker-test-t16-$nonce" ]; then
      t16_left="$t16_left $t"
      rm -f "$t/.flowcrm-no-docker-test-t16-$nonce"
    fi
  done
  [ ! -e "$t16_in" ] || t16_left="$t16_left /tmp"
  t16_ok=$(printf '%s\n' "$t16" | grep -c '^t16 ok')
  [ "$r" -eq 0 ] && ! printf '%s\n' "$t16" | grep -q '^t16 bad' && [ "$t16_ok" -ge 12 ] && [ -z "$t16_left" ]
  result "T-16 inside the isolation: private pids, no reachable socket, read-only \$HOME/workspace/RUNNER_TEMP, private /tmp, read-only mounts, masked cgroups, private IPC" $? \
    "(rc $r, $t16_ok ok, markers left in:${t16_left:- none})"
  rm -f "$t16_tmp" "$t16_shm" "$t16_in"

  # --- T-17 no process survives the isolated command: a `setsid -f` canary
  # with a unique marker, after a normal end and after the isolation was
  # cancelled (TERM to no-docker.sh, as a cancelled CI step does). The
  # canary is a shell kept alive by "sleep 60; :", so the process with the
  # marker in its command line is the one that must die; the command checks
  # that it runs before it returns. Checked from outside, after
  # no-docker.sh returned.
  # On 38b5ebd: no pid namespace and no --kill-child, so the canary
  # survives; and TERM to no-docker.sh left sudo, unshare and the command
  # running.
  t17m=t17-$nonce
  t17=$("$nd" /bin/sh -c 'setsid -f /bin/sh -c "sleep 60; :" "$1-in" </dev/null >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if pgrep -f -- "$1-in" >/dev/null; then echo canary-started; exit 0; fi
  sleep 0.1
done
echo canary-missing' _ "$t17m" 2>/dev/null | grep -v '^::')
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- "$t17m-in" >/dev/null || break; sleep 0.5; done
  pgrep -f -- "$t17m-in" >/dev/null
  left=$?
  pkill -TERM -f -- "$t17m-in" 2>/dev/null
  [ "$t17" = canary-started ] && [ "$left" -ne 0 ]
  result "T-17 a daemonised process does not outlive the isolated command" $? \
    "($t17, survivor $([ "$left" -eq 0 ] && echo yes || echo no))"

  t17c=t17c-$nonce
  "$nd" /bin/sh -c 'setsid -f /bin/sh -c "sleep 60; :" "$1-in" </dev/null >/dev/null 2>&1; sleep 60; :' _ "$t17c" >/dev/null 2>&1 &
  t17pid=$!
  for _ in $(seq 1 240); do pgrep -f -- "$t17c-in" >/dev/null && break; sleep 0.5; done
  started=no
  pgrep -f -- "$t17c-in" >/dev/null && started=yes
  kill -TERM "$t17pid" 2>/dev/null
  wait "$t17pid" 2>/dev/null
  r=$?
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- "$t17c-in" >/dev/null || break; sleep 0.5; done
  pgrep -f -- "$t17c-in" >/dev/null
  left=$?
  pkill -TERM -f -- "$t17c" 2>/dev/null
  [ "$started" = yes ] && [ "$left" -ne 0 ]
  result "T-17 TERM to no-docker.sh (a cancelled step) kills every process inside the isolation" $? \
    "(canary started $started, rc $r, survivor $([ "$left" -eq 0 ] && echo yes || echo no))"

  # --- T-18 unsupported use is refused: uid 0 (a real sudo run) and a Linux
  # that is not a GitHub-hosted runner. The command is `true`.
  # On 38b5ebd: neither was checked, so every case ran `true` (rc 0).
  t18() { # name expected-message command...
    local name=$1 msg=$2 err
    shift 2
    err=$("$@" 2>&1 >/dev/null)
    r=$?
    [ "$r" -eq 125 ] && printf '%s' "$err" | grep -q -- "$msg"
    result "T-18 $name: refused" $? "(rc $r)"
  }
  t18 "uid 0 (sudo)" "running as root" sudo -n "$nd" /usr/bin/true
  t18 "RUNNER_ENVIRONMENT unset" "GitHub-hosted" env -u RUNNER_ENVIRONMENT "$nd" /usr/bin/true
  t18 "RUNNER_ENVIRONMENT=self-hosted" "GitHub-hosted" env RUNNER_ENVIRONMENT=self-hosted "$nd" /usr/bin/true
  t18 "GITHUB_ACTIONS unset" "GitHub-hosted" env -u GITHUB_ACTIONS "$nd" /usr/bin/true
  t18 "GITHUB_WORKSPACE outside \$HOME" "GitHub-hosted" env GITHUB_WORKSPACE=/var/tmp "$nd" /usr/bin/true
  # Without a Runner.Worker ancestor: started through setsid -f, so it is
  # reparented away from this job's process tree; its status comes back in
  # a file.
  setsid -f /bin/sh -c '"$1" /usr/bin/true >/dev/null 2>"$2.err"; echo $? >"$2.tmp"; mv "$2.tmp" "$2"' _ "$nd" "$work/t18.rc"
  for _ in $(seq 1 240); do [ -s "$work/t18.rc" ] && break; sleep 0.5; done
  r=$(cat "$work/t18.rc" 2>/dev/null)
  [ "$r" = 125 ] && grep -q "no Runner.Worker ancestor" "$work/t18.rc.err" 2>/dev/null
  result "T-18 no Runner.Worker ancestor: refused" $? "(rc ${r:-none})"
else
  echo "INFO  T-16, T-17, T-18 skipped: Linux (GitHub-hosted runner) only"
fi

# --- T-19 CI order (static): no step that is not isolated follows an
# isolated one in a job; the required jobs exist; no if: conditions.
# On 38b5ebd: "Allocator unit tests" came before the real-Docker steps and
# the guard suites before ShellCheck and actionlint.
t19=$(python3 -I "$here/ci-isolation-order.py" "$root" 2>&1)
r=$?
printf '%s\n' "$t19" | grep -v '^ci-isolation-order: ok' | sed 's/^/INFO    /'
[ "$r" -eq 0 ]
result "T-19 isolated steps are the last steps of their CI jobs; required jobs exist; no if: conditions" $? "(rc $r)"

# --- T-03/T-04 the harness against the mutant
check_safe() { # name
  # Refused (125, the mutant never ran) or run isolated (97, every case ran
  # and none reached an engine); either way the canary engine got nothing.
  local cases answered
  cases=$(count_in ' rc=' "$LOG")
  answered=$(count_in 'canary-engine' "$LOG")
  [ "$REQ" -eq 0 ] && [ "$answered" -eq 0 ]
  result "$1: no request reached an engine" $? "(canary requests $REQ, answered cases $answered, rc $RC)"
  [ "$STARTED" -eq 1 ]
  result "$1: the harness was started" $?
  if [ "$os" = Darwin ] && [ "$t0304" = bare ]; then
    # The harness nests its own sandbox inside the guard and runs the mutant.
    [ "$RC" -eq 97 ] && [ "$cases" -ge 20 ]
    result "$1: the mutant ran to its end inside the harness's isolation" $? "(rc $RC, $cases cases)"
  else
    # The canary is a reachable engine on Linux: the harness must refuse.
    [ "$RC" -eq 125 ] && [ "$cases" -eq 0 ] &&
      grep -q '^no-docker: refused: inside no-docker.sh, but the isolation check fails' "$OUT"
    result "$1: the harness refused before the mutant ran (an engine is reachable)" $? "(rc $RC, $cases cases)"
  fi
  [ "$(count_in '^real-socket-c[a-z]* rc=0 ' "$LOG")" -eq 0 ]
  result "$1: the real Docker socket paths were not reached" $?
  [ ! -e "$home_marker" ]
  result "$1: nothing written under \$HOME" $?
  rm -f "$home_marker"
}
run_case t03 "$harness" devenv "$t0304"
shown=("t03 $LOG $OUT")
check_safe "T-03 mutant as DEVENV"
run_case t04 "$harness" inplace "$t0304"
shown+=("t04 $LOG $OUT")
check_safe "T-04 mutant edited into bin/devenv"

# --- T-05 control: the same check catches a harness without containment
run_case t05 "$ro/unit-uncontained.sh" inplace guard
shown+=("t05 $LOG $OUT")
answered=$(count_in 'canary-engine' "$LOG")
[ "$STARTED" -eq 1 ] && [ "$REQ" -gt 0 ] && [ "$answered" -gt 0 ] && [ "$RC" -eq 97 ]
result "T-05 control: without the containment the mutant's commands reach the canary engine" $? "(canary requests $REQ, answered cases $answered, rc $RC)"

echo
for s in "${shown[@]}"; do
  read -r f log out <<<"$s"
  printf 'INFO  %s cases:\n' "$f"
  ! regular "$log" || sed 's/^/INFO    /' <"$log" 2>/dev/null
  printf 'INFO  %s harness output (last lines):\n' "$f"
  tail -n 8 "$out" 2>/dev/null | sed 's/^/INFO    /'
done
echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
