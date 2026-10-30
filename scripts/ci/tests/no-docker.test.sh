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
#     canary.py) and the payload are tracked files (no-docker/) pinned to
#     reviewed sha256 values in this file; their copies are kept outside
#     every directory the code under test can write, and checked against
#     those values immediately before each such run (T-14, T-23);
#   - the other cases run plain commands that only print, connect to this
#     suite's own listeners, write marker files in directories of this
#     suite (and in protected places, where the write must fail; a marker
#     that was written anyway is removed), send signal 0 or TERM to this
#     suite's own `sleep` canaries, start processes of their own that
#     sleep and must be ended by no-docker.sh (any left over are killed by
#     pid only while their arguments carry the case's marker), attach a
#     debugger to or read the memory map of this suite's own canary copies
#     of /bin/sleep, read a pseudo-terminal of their own, or sleep.
# This suite itself runs no docker command.
#
# T-06, T-08 to T-15, T-21, T-22 and T-24 to T-29 are macOS only, T-16 to
# T-18 Linux only (each prints INFO on the other platform); T-19, T-20 and
# T-23 are static and run on both. Each case says how it fails against the
# no-docker.sh of 38b5ebd or dfb6ee4, which these cases were written to
# catch.
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
# macOS: the per-user temporary directory no-docker.sh uses (its markers).
ndtmp=$tmp
[ "$os" != Darwin ] || [ -n "${TMPDIR-}" ] || ndtmp=$(cd -P "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P) || exit 2
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

# --- the helpers -------------------------------------------------------------
# Tracked files of this suite (scripts/ci/tests/no-docker/), copied to
# $helpers and checked against the sha256 below, which is part of this
# reviewed source: a copy that differs in any way is never run. Changing
# a helper needs a new review and a new hash here.
#   canary.py <socket> <log>: the canary engine, a Unix socket that answers
#     like Docker and records every request;
#   drive.sh <canary.py> <data dir> <canary socket> <harness command...>:
#     starts the canary (logging to <data dir>/canary.log), records that
#     the harness was started (<data dir>/drive-started), runs it with
#     DOCKER_HOST pointing at the canary and stops the canary again;
#   payload: the mutant's payload (below).
helper_sums="canary.py=35dae9af68f8ec8a8a8668a1468fb192ed14f35461d893e3ab9525db11d69ce5 drive.sh=bb13bfa8771d611cc6be3bacf709b769b0c7d0868f0d2821b040107019a7d283 payload=7fd727d79f1eb2e8e3a6f52e25da8f0fe35851b79d262384f6bbc5f5c946ed25"
cp "$here/no-docker/canary.py" "$here/no-docker/drive.sh" "$here/no-docker/payload" "$helpers/" || exit 2

# A Docker configuration whose context "canary" points at a canary socket.
ctx=$(printf 'canary' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-64)
ctxcfg() { # dir canary
  mkdir -p "$1/contexts/meta/$ctx" || return 1
  printf '{"Name":"canary","Metadata":{},"Endpoints":{"docker":{"Host":"unix://%s","SkipTLSVerify":false}}}\n' \
    "$2" >"$1/contexts/meta/$ctx/meta.json"
}

# --- the mutant ---------------------------------------------------------------
# The payload is inserted after the first line of bin/devenv, so it runs as
# soon as the file is sourced or executed. Each case appends
# "<case> rc=<status> out=<output>" to the log; the mutant then exits 97.
# It is exactly the reviewed text: on macOS the cases T-03 and T-04 run
# without the outer guard, so their safety rests on it only reading.

# verify_helpers <dir>: the helpers and the payload in <dir> are regular
# files with the reviewed sha256 of helper_sums. Called right after they
# are copied, immediately before every run of drive.sh and before every
# mutant is made.
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
      echo "HARNESS ERROR: $1/$f is not the reviewed one ($got); refusing to run" >&2
      return 1
    fi
  done
}
verify_helpers "$helpers" || exit 2

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
      # The write policy of no-docker.sh: only the case's directories and
      # the /dev nodes of its profile; plus its other denies and the ports
      # listening now. Only the canary socket is reachable. The guard's
      # sandbox carries markers like no-docker.sh's, and no-docker-probe.py
      # supervises it the same way: whatever the harness leaves running is
      # ended when drive.sh returns, and the case fails if that cannot be
      # shown (125).
      verify_helpers "$helpers" || exit 2
      held=""
      for port in $(python3 -I "$root/scripts/ci/no-docker-probe.py" --listening) ; do
        case $port in *[!0-9]* | "") echo "HARNESS ERROR: unexpected port $port" >&2; exit 2 ;; esac
        held="$held (remote ip \"localhost:$port\")"
      done
      gmark=$(python3 -I "$root/scripts/ci/no-docker-probe.py" --markers "$ndtmp") || exit 2
      case $gmark in "$ndtmp"/no-docker-mark.?*) ;; *) echo "HARNESS ERROR: unexpected marker directory $gmark" >&2; exit 2 ;; esac
      python3 -I "$root/scripts/ci/no-docker-probe.py" --supervise "$gmark" "$data/drive-started" - -- /usr/bin/sandbox-exec -p "(version 1)
(allow default)
(deny network-outbound (remote unix-socket))
(allow network-outbound (remote unix-socket (path-literal \"$canary\")))
(deny network-outbound (remote ip))
(allow network-outbound (remote ip \"localhost:*\"))
(deny network-outbound (remote ip \"localhost:22\") (remote ip \"localhost:2375\") (remote ip \"localhost:2376\")$held)
(deny file-write*)
(allow file-write* (subpath \"$data\") (subpath \"$w\") (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/[0-9]+\$\"))
(deny file-read-data (literal \"$ndtmp/no-docker-mark/a\") (literal \"$gmark/a\"))
(deny file-read* (regex #\"^/dev/ttys[0-9]+\$\"))
(deny user-preference-write)
(deny file-ioctl (ioctl-command #x80017472))
(deny system-debug)
(deny mach-task-name mach-task-read mach-task-inspect mach-priv-task-port)
(allow mach-task-name mach-task-read mach-task-inspect mach-priv-task-port (target same-sandbox))
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
  # --- T-06 plain commands (no mutant): the write limits. A bash 3.2
  # here-document from a working directory outside the run's directory
  # fails: bash keeps it in /tmp (it cannot use /var/tmp inside), which the
  # sandbox does not allow, so code run inside uses none.
  # On dfb6ee4: /private/tmp/sh-thd* was writable, so the here-document
  # worked (rc 0 and "here-document" in t06).
  w6=$(new_work) || exit 2
  "$nd" --work "$w6" /bin/bash -c 'touch "$1" "$2" "$3" 2>/dev/null; cd / && cat >"$4" <<EOF
here-document
EOF' _ "$home_marker" "$outside_marker" "$tmp_marker" "$w6/t06" >"$work/t06.out" 2>&1
  r=$?
  [ "$r" -eq 1 ] && [ ! -s "$w6/t06" ] && grep -q 'cannot create temp file for here.document' "$work/t06.out" &&
    [ ! -e "$home_marker" ] && [ ! -e "$outside_marker" ] && [ ! -e "$tmp_marker" ]
  result "T-06 writes only in the run's directory: not under \$HOME, next to \$TMPDIR or in /tmp (a bash 3.2 here-document fails)" $? "(rc $r)"
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

  # --- T-21 here-document files of bash 3.2 cannot be changed from inside.
  # Outside the sandbox bash 3.2 keeps them in /private/var/tmp, inside it
  # (and in other sandboxes that allow /tmp but not /var/tmp) in
  # /private/tmp. Two canaries named like them, made here: none can be
  # opened for writing, truncated, appended to, removed, renamed or
  # replaced from inside, and no new one can be created.
  # On dfb6ee4: the profile allowed writes to /private/tmp/sh-thd*, so every
  # operation on that canary succeeded.
  t21a=/private/tmp/sh-thd-flowcrm-test-$nonce
  t21b=/private/var/tmp/sh-thd-flowcrm-test-$nonce
  w21=$(new_work) || exit 2
  for f in "$t21a" "$t21b"; do (umask 077 && printf 'original\n' >"$f") || exit 2; done
  t21=$("$nd" --work "$w21" python3 -I -c '
import errno, os, sys
w = sys.argv[1]
for path in sys.argv[2:]:
    open(os.path.join(w, "x"), "w").close()
    tries = {
        "write": lambda: os.open(path, os.O_WRONLY),
        "read-write": lambda: os.open(path, os.O_RDWR),
        "append": lambda: os.open(path, os.O_WRONLY | os.O_APPEND),
        "truncate": lambda: os.truncate(path, 0),
        "unlink": lambda: os.unlink(path),
        "rename-away": lambda: os.rename(path, path + ".moved"),
        "replace": lambda: os.rename(os.path.join(w, "x"), path),
        "create": lambda: os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600),
        "chmod": lambda: os.chmod(path, 0o666),
    }
    for name, f in tries.items():
        try:
            r = f()
            if isinstance(r, int):
                os.close(r)
            print("t21 bad ", path, name, "allowed")
        except OSError as e:
            print("t21 " + ("ok  " if e.errno in (errno.EPERM, errno.EACCES) else "bad ") , path, name,
                  errno.errorcode.get(e.errno, e.errno))
' "$w21" "$t21a" "$t21b" 2>/dev/null)
  r=$?
  t21_left=""
  for f in "$t21a" "$t21b"; do
    [ "$(cat "$f" 2>/dev/null)" = original ] || t21_left="$t21_left changed:$f"
    for x in "$f.moved" "$f.new"; do [ ! -e "$x" ] || t21_left="$t21_left $x"; done
  done
  printf '%s\n' "$t21" | grep '^t21 bad' | sed 's/^/INFO    /'
  [ "$r" -eq 0 ] && [ "$(printf '%s\n' "$t21" | grep -c '^t21 ok')" -eq 18 ] && [ -z "$t21_left" ]
  result "T-21 bash 3.2 here-document files (/private/tmp and /private/var/tmp sh-thd-*) cannot be written, replaced or created from inside" $? \
    "(rc $r, $(printf '%s\n' "$t21" | grep -c '^t21 ok') of 18 denied, changed or left:${t21_left:- none})"
  rm -f "$t21a" "$t21b" "$t21a.moved" "$t21b.moved" "$t21a.new" "$t21b.new"

  # --- T-22 a file outside the run's directory cannot be changed through a
  # hard link, a symbolic link, a rename over it or an exchange (all on
  # the same volume as the run's directory).
  # (A-M3: measured on 38b5ebd, no regression case until now.)
  t22f=$work/t22-target
  printf 'original\n' >"$t22f" || exit 2
  w22=$(new_work) || exit 2
  t22=$("$nd" --work "$w22" python3 -I -c '
import ctypes, errno, os, sys
w, target = sys.argv[1], sys.argv[2]
libc = ctypes.CDLL(None, use_errno=True)
def say(ok, text):
    print(("t22 ok   " if ok else "t22 bad  ") + text)
try:
    os.link(target, os.path.join(w, "hard"))
    try:
        with open(os.path.join(w, "hard"), "a") as f:
            f.write("changed\n")
        say(False, "hard link made and written through")
    except OSError as e:
        say(True, f"hard link made, but not writable ({errno.errorcode.get(e.errno)})")
except OSError as e:
    say(True, f"hard link refused ({errno.errorcode.get(e.errno)})")
os.symlink(target, os.path.join(w, "soft"))
try:
    with open(os.path.join(w, "soft"), "a") as f:
        f.write("changed\n")
    say(False, "written through a symbolic link")
except OSError as e:
    say(True, f"symbolic link not writable ({errno.errorcode.get(e.errno)})")
mine = os.path.join(w, "mine")
with open(mine, "w") as f:
    f.write("replaced\n")
try:
    os.rename(mine, target)
    say(False, "renamed over the target")
except OSError as e:
    say(True, f"rename over the target refused ({errno.errorcode.get(e.errno)})")
RENAME_SWAP = 0x2
r = libc.renamex_np(os.fsencode(mine), os.fsencode(target), RENAME_SWAP)
say(r != 0, f"exchange with the target refused ({errno.errorcode.get(ctypes.get_errno(), r)})")
r = libc.exchangedata(os.fsencode(mine), os.fsencode(target), 0)
say(r != 0, f"exchangedata with the target refused ({errno.errorcode.get(ctypes.get_errno(), r)})")
' "$w22" "$t22f" 2>/dev/null)
  r=$?
  printf '%s\n' "$t22" | grep '^t22 ' | sed 's/^/INFO    /'
  [ "$r" -eq 0 ] && [ "$(printf '%s\n' "$t22" | grep -c '^t22 ok')" -eq 5 ] && [ "$(cat "$t22f")" = original ]
  result "T-22 a file outside the run's directory cannot be changed through links, a rename or an exchange" $? \
    "(rc $r, target $(cat "$t22f" 2>/dev/null | head -n 1))"

  # --- T-24 to T-27 no process of the command outlives it. The command is a
  # Python "leaver" that starts four processes meant to survive it: a plain
  # child, a setsid daemon after a double fork, a posix_spawn child with
  # POSIX_SPAWN_SETSID and a child in a process group of its own. Each
  # appends its pid to <run dir>/pids once it runs and then sleeps 60 s;
  # every one carries the case's marker in its arguments, which is how the
  # checks below (and their clean-up) recognise them. The leaver waits until
  # all four are recorded, then ends as the case says. The pids are read
  # back as data and a pid counts as a survivor only while its arguments
  # still carry the marker.
  # On dfb6ee4: nothing ended them, so all four survived each case.
  t24_leaver='
import ctypes, os, signal, sys, time
w, tag, how = sys.argv[1], sys.argv[2], sys.argv[3]
SLEEP = [sys.executable, "-I", "-B", "-c", "import os, sys, time; open(sys.argv[1], \"a\").write(f\"{os.getpid()}\\n\"); time.sleep(60)", w + "/pids", tag]
if os.fork() == 0:
    os.execv(SLEEP[0], SLEEP)
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.execv(SLEEP[0], SLEEP)
    os._exit(0)
libc = ctypes.CDLL(None, use_errno=True)
attr = ctypes.c_void_p()
libc.posix_spawnattr_init(ctypes.byref(attr))
libc.posix_spawnattr_setflags(ctypes.byref(attr), ctypes.c_short(0x0400))  # POSIX_SPAWN_SETSID
argv = (ctypes.c_char_p * (len(SLEEP) + 1))(*[a.encode() for a in SLEEP], None)
pid = ctypes.c_int()
libc.posix_spawn(ctypes.byref(pid), SLEEP[0].encode(), None, ctypes.byref(attr), argv, None)
if os.fork() == 0:
    os.setpgid(0, 0)
    os.execv(SLEEP[0], SLEEP)
for _ in range(100):
    try:
        if len(open(w + "/pids").read().split()) >= 4:
            break
    except OSError:
        pass
    time.sleep(0.05)
open(w + "/mark", "w").write(os.environ.get("NO_DOCKER_MARK", ""))
if how == "fail":
    sys.exit(3)
if how == "kill-self":
    os.kill(os.getpid(), signal.SIGKILL)
if how == "wait":
    open(w + "/pids", "a").write(f"{os.getpid()}\n")
    time.sleep(60)
'
  t24_left() { # run-dir tag: the recorded pids that still run as the case's processes
    local p
    regular "$1/pids" || return 0
    for p in $(tr -c '0-9\n' ' ' <"$1/pids"); do
      ps -o args= -p "$p" 2>/dev/null | grep -q -- "$2" && printf ' %s' "$p"
    done
  }
  t24_clean() { # run-dir tag: end only processes that still carry the case's marker
    local p
    for p in $(t24_left "$1" "$2"); do kill -KILL "$p" 2>/dev/null; done
  }
  t24() { # name how expected-rc
    local w tag=t24-$2-$nonce left n
    w=$(new_work) || exit 2
    "$nd" --work "$w" python3 -I -B -c "$t24_leaver" "$w" "$tag" "$2" >"$work/t24-$2.out" 2>&1
    r=$?
    sleep 0.5
    left=$(t24_left "$w" "$tag")
    n=$(count_in . "$w/pids")
    t24_clean "$w" "$tag"
    [ "$r" -eq "$3" ] && [ "$n" -eq 4 ] && [ -z "$left" ] && grep -q 'no-docker: ended [0-9]* processes' "$work/t24-$2.out"
    result "T-24 $1: none of the 4 processes it left survives" $? "(rc $r, $n recorded, survivors:${left:- none})"
  }
  t24 "normal end" ok 0
  t24 "failed command" fail 3
  t24 "command killed by SIGKILL" kill-self 137

  # T-25: SIGINT, SIGTERM or SIGHUP to no-docker.sh while the command runs
  # ends the command and all it started at once. no-docker.sh is started
  # with SIGINT at its default (an asynchronous command of this script
  # would otherwise ignore it).
  t25() { # signal expected-rc
    local w tag=t25-$1-$nonce ndpid left n t0 took
    w=$(new_work) || exit 2
    python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$nd" --work "$w" python3 -I -B -c "$t24_leaver" "$w" "$tag" wait >"$work/t25-$1.out" 2>&1 &
    ndpid=$!
    for _ in $(seq 1 100); do [ "$(count_in . "$w/pids")" -ge 5 ] && break; sleep 0.1; done
    n=$(count_in . "$w/pids")
    t0=$(date +%s)
    # Our own child, still running (its arguments name no-docker.sh).
    ps -o args= -p "$ndpid" 2>/dev/null | grep -q -- no-docker && kill -"$1" "$ndpid"
    wait "$ndpid"
    r=$?
    took=$(($(date +%s) - t0))
    sleep 0.5
    left=$(t24_left "$w" "$tag")
    t24_clean "$w" "$tag"
    [ "$n" -eq 5 ] && [ "$r" -eq "$2" ] && [ "$took" -le 10 ] && [ -z "$left" ]
    result "T-25 SIG$1 to no-docker.sh ends the command and the 4 processes it left" $? \
      "(rc $r, $n recorded, ${took}s, survivors:${left:- none})"
  }
  t25 INT 130
  t25 TERM 143
  t25 HUP 129

  # T-26: SIGKILL of no-docker.sh cannot be handled: what the command left
  # keeps running, still sandboxed, and no new isolated run starts while it
  # does (125, command not run). The case then ends them through the run's
  # marker (no-docker-probe.py --end) and a new run starts again.
  w=$(new_work) || exit 2
  tag=t26-$nonce
  t26_before=$(cd "$ndtmp" && ls -d no-docker-mark.* 2>/dev/null)
  python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$nd" --work "$w" python3 -I -B -c "$t24_leaver" "$w" "$tag" wait >"$work/t26.out" 2>&1 &
  ndpid=$!
  for _ in $(seq 1 100); do [ "$(count_in . "$w/pids")" -ge 5 ] && break; sleep 0.1; done
  ps -o args= -p "$ndpid" 2>/dev/null | grep -q -- no-docker && kill -KILL "$ndpid"
  wait "$ndpid" 2>/dev/null
  sleep 0.5
  t26_alive=$(t24_left "$w" "$tag")
  w26=$(new_work) || exit 2
  "$nd" --work "$w26" /usr/bin/touch "$w26/ran" >"$work/t26b.out" 2>&1
  r=$?
  t26_mark=""
  regular "$w/mark" && t26_mark=$(cat "$w/mark")
  # Data the sandboxed command wrote: accepted only as the name of a marker
  # directory that did not exist before this case (one path component).
  case ${t26_mark#"$ndtmp"/} in no-docker-mark.*[!A-Za-z0-9_]* | "$t26_mark") t26_mark="" ;; no-docker-mark.?*) ;; *) t26_mark="" ;; esac
  case "
$t26_before
" in *"
${t26_mark#"$ndtmp"/}
"*) t26_mark="" ;; esac
  [ -n "$t26_mark" ] && [ -d "$t26_mark" ] && [ ! -L "$t26_mark" ] || t26_mark=""
  t26_end=1
  if [ -n "$t26_mark" ] && python3 -I "$root/scripts/ci/no-docker-probe.py" --end "$t26_mark" >/dev/null 2>&1; then
    t26_end=0
    rm -rf "$t26_mark"
  fi
  t26_left=$(t24_left "$w" "$tag")
  t24_clean "$w" "$tag"
  w26c=$(new_work) || exit 2
  "$nd" --work "$w26c" /usr/bin/touch "$w26c/ran" >/dev/null 2>&1
  r2=$?
  [ -n "$t26_alive" ] && [ "$r" -eq 125 ] && [ ! -e "$w26/ran" ] && grep -q 'earlier isolated run' "$work/t26b.out" &&
    [ "$t26_end" -eq 0 ] && [ -z "$t26_left" ] && [ "$r2" -eq 0 ] && [ -e "$w26c/ran" ]
  result "T-26 after SIGKILL of no-docker.sh its leftovers keep every new run from starting until they are ended" $? \
    "(left after SIGKILL:${t26_alive:- none}; new run rc $r; ended through the marker $t26_end; afterwards rc $r2)"

  # T-27: if the processes of the isolation cannot be found or ended (here:
  # no-docker-probe.py fails), nothing runs.
  mkdir -p "$work/t27"
  t27() { # mode
    local w
    printf '#!/bin/sh\ncase " $* " in *" %s "*) exit 1 ;; esac\nexec %s "$@"\n' "$1" "$(command -v python3)" >"$work/t27/python3"
    chmod +x "$work/t27/python3"
    w=$(new_work) || exit 2
    PATH=$work/t27:$PATH "$nd" --work "$w" /usr/bin/touch "$w/ran" >/dev/null 2>&1
    r=$?
    [ "$r" -ne 0 ] && [ ! -e "$w/ran" ]
    result "T-27 no-docker-probe.py $1 fails: the command is not run" $? "(rc $r)"
  }
  t27 --markers
  t27 --orphans
  t27 --supervise

  # --- T-28 no debugger access to a process outside (A-M2). The canaries
  # are copies of /bin/sleep in this suite's directory, signed ad hoc with
  # get-task-allow, so that a debugger of the same user may attach to them;
  # the control attaches to one from outside and reads the other's memory
  # map. Inside, ptrace(PT_ATTACHEXC) on the other must fail (EPERM), its
  # task name port and its memory map (vmmap) must be refused, and it must
  # still run.
  # On dfb6ee4: the profile denied none of these, so the attach from inside
  # succeeded (and ended the canary when the attacher exited).
  t28c=$work/t28-sleep
  cp /bin/sleep "$t28c" &&
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>' >"$work/t28.plist" &&
    codesign -f -s - --entitlements "$work/t28.plist" "$t28c" >/dev/null 2>&1 || exit 2
  t28_attach='
import ctypes, errno, subprocess, sys
libc = ctypes.CDLL(None, use_errno=True)
pid = int(sys.argv[1])
if sys.argv[2] == "inside":
    me = ctypes.c_uint.in_dll(libc, "mach_task_self_").value
    port = ctypes.c_uint(0)
    kr = libc.task_name_for_pid(me, pid, ctypes.byref(port))
    vm = subprocess.run(["/usr/bin/vmmap", "--summary", str(pid)], capture_output=True, timeout=60).returncode
    print("task-name " + ("got" if kr == 0 else "refused") + " vmmap " + ("read" if vm == 0 else "refused"), end=" ")
r = libc.ptrace(14, pid, None, 0)  # PT_ATTACHEXC
print("attached" if r == 0 else "denied " + errno.errorcode.get(ctypes.get_errno(), "?"))
'
  "$t28c" 60 &
  t28a=$!
  "$t28c" 60 &
  t28b=$!
  sleep 0.3
  t28_vm=$(/usr/bin/vmmap --summary "$t28b" >/dev/null 2>&1 && echo read || echo refused)
  t28_out=$(python3 -I -c "$t28_attach" "$t28a" outside 2>&1)
  t28_in=$("$nd" python3 -I -c "$t28_attach" "$t28b" inside 2>/dev/null)
  r=$?
  t28_state=$(ps -o stat= -p "$t28b" 2>/dev/null | tr -d ' ')
  for p in "$t28a" "$t28b"; do
    ps -o args= -p "$p" 2>/dev/null | grep -q -- "$t28c" && kill -KILL "$p" 2>/dev/null
  done
  wait "$t28a" "$t28b" 2>/dev/null
  [ "$t28_out" = attached ] && [ "$t28_vm" = read ] && [ "$r" -eq 0 ] &&
    [ "$t28_in" = "task-name refused vmmap refused denied EPERM" ] && case $t28_state in S*) true ;; *) false ;; esac
  result "T-28 a debugger attach, task port or memory map of a process outside is refused from inside (control: they work from outside)" $? \
    "(outside: $t28_out, vmmap $t28_vm; inside rc $r: $t28_in; canary state ${t28_state:-gone})"

  # --- T-29 another terminal cannot be read from inside: a pseudo-terminal
  # this case opens outside stands for one; its device is opened by path
  # (control: outside it can be, and a line written to it is read).
  # On dfb6ee4: the profile allowed reading /dev/ttys*, so the line typed
  # into another terminal was read.
  t29=$(python3 -I -c '
import os, pty, select, subprocess, sys
probe = "import os, select, sys\ntry:\n    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOCTTY)\nexcept OSError as e:\n    print(\"denied\", e.errno)\n    sys.exit(0)\nr, _, _ = select.select([fd], [], [], 5)\nprint(\"read\" if r and os.read(fd, 64) else \"opened\")\n"
out = []
for where in ("outside", "inside"):
    master, slave = pty.openpty()
    argv = [sys.executable, "-I", "-c", probe, os.ttyname(slave)]
    if where == "inside":
        argv = [sys.argv[1]] + argv
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    select.select([], [], [], 1.5)
    os.write(master, b"typed\n")
    try:
        o, _ = p.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        p.kill()
        o, _ = p.communicate()
    out.append(f"{where}:{o.strip()}")
    os.close(master)
    os.close(slave)
print(" ".join(out))
' "$nd" 2>&1)
  [ "$t29" = "outside:read inside:denied 1" ]
  result "T-29 another terminal's device cannot be read from inside (control: it can from outside)" $? "($t29)"
else
  echo "INFO  T-06, T-08 to T-15, T-21, T-22, T-24 to T-29 skipped: macOS sandbox profile only"
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
  # with a unique marker, after a normal end and after TERM delivered to
  # no-docker.sh itself (as by Ctrl-C or a caller forwarding the signal; a
  # cancelled GitHub step does not signal no-docker.sh and is not covered). The
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
  result "T-17 TERM delivered to no-docker.sh itself kills every process inside the isolation" $? \
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

# --- T-20 code that runs inside the isolation uses no here-document or
# here-string (static): on macOS bash 3.2 would need /tmp for them, which
# the sandbox does not allow, so one would fail there (and a missed failure
# can look like a pass). The suites, the scripts they run and bin/devenv;
# the payload is checked by its hash. The one allowed match is the edge
# guard's test text for a Caddyfile here-document.
t20=$(cd "$root" && grep -nE "(^|[^<])<<-?[[:space:]]*[\"'\\\\]?[A-Za-z_]|<<<" -- bin/devenv tests/devenv/unit.sh \
  tests/devenv/tally.sh scripts/ci/no-docker.sh scripts/ci/guard-*.sh scripts/ci/tests/guard-*.test.sh 2>&1 |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vF 'heredoc (<<) is not supported')
printf '%s\n' "$t20" | grep . | sed 's/^/INFO    /'
[ -z "$t20" ]
result "T-20 code run inside the isolation has no here-document or here-string" $?

# --- T-23 the helpers this suite runs outside any isolation are pinned to
# reviewed hashes in this file (static): none is hashed after it was
# written. On dfb6ee4: canary.py and drive.sh were written with
# here-documents and their sha256 taken afterwards.
grep -qE '^helper_sums="canary\.py=[0-9a-f]{64} drive\.sh=[0-9a-f]{64} payload=[0-9a-f]{64}"$' "$here/no-docker.test.sh" &&
  ! grep -nE '^[^#]*helper_sums=.*\$\(' "$here/no-docker.test.sh" >/dev/null &&
  ! grep -nE '^[^#]*>"?\$helpers/' "$here/no-docker.test.sh" >/dev/null
result "T-23 the helpers run outside any isolation are pinned to reviewed sha256 values, not hashed after writing" $?

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
