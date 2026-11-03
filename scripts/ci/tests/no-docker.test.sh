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
#     of /bin/sleep, read a pseudo-terminal of their own, run a bounded
#     chain of forks of their own inside the isolation (T-30), remove the
#     marker file of a run of their own (T-33), or sleep;
#   - T-36 and T-38 run pure tests of the probe's rules and of the AppArmor
#     helper: fixtures only, with every call that would read /proc, open a
#     file or socket, run a program, fork, send a signal or change a
#     descriptor made to raise.
#   - T-39 reads the tracked files and checks static rules on them and on
#     mutant fixtures held in memory.
#   - T-40 runs the Linux cleanup function of no-docker.sh, taken from the
#     script, in a shell of its own against stubs of rm, sudo and chmod,
#     on directories of this suite only; T-41 computes L-16's projection
#     from fixed timings.
#   - the L-tests (Linux CI only) check the kernel-enforced isolation from
#     outside: sockets of this suite (stream, datagram, abstract, behind a
#     bind-mounted alias, in a directory that cannot be listed, bound late,
#     passing a descriptor) must be refused inside and reachable outside;
#     descriptors, signals, escapes, the negative control, the release of
#     the profile with carriers of this suite (aa-exec ... sleep, ended by
#     pid), TERM at chosen moments, SIGKILL of the launch's own unshare,
#     output relaying and the cost of a launch (L-16, last). They use sudo
#     only for: mount and umount of the alias, kill of that unshare, unshare
#     of a listener's network namespace, reading the profile list and a
#     task's AppArmor labels, and no-docker-aa.py load, release and diag of
#     this suite's own profiles (L-13, and releasing what a case left
#     loaded); the profiles a case records as left loaded are released on
#     exit, after its carriers ended.
# This suite itself runs no docker command.
#
# T-06, T-08 to T-15, T-21, T-22 and T-24 to T-35 are macOS only, T-16 to
# T-18 and L-01 to L-18 Linux only (INFO or SKIP on the other platform; on
# Linux CI a missing prerequisite is a failure); T-19,
# T-20, T-23, T-36, T-38, T-39, T-40 and T-41 are static or pure and run on both. Each case says
# how it fails against the no-docker.sh of 38b5ebd, dfb6ee4, e8ed7ed or
# 85cfb37, which these cases were written to catch.
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
  # T-21's canaries in the shared directories, only while they are ours.
  [ -z "${t21a_ino-}" ] || python3 -I -c "$t21_file" remove "$t21a" "$t21a_dev" "$t21a_ino"
  [ -z "${t21b_ino-}" ] || python3 -I -c "$t21_file" remove "$t21b" "$t21b_dev" "$t21b_ino"
  # The L-tests' listeners and carriers (this suite's children, by their
  # recorded pid), the alias mount, and any profile a case left loaded.
  [ ! -f "$work/l-listeners" ] || while read -r f; do
    p=$(cut -d' ' -f1 "$f" 2>/dev/null)
    case $p in "" | *[!0-9]*) ;; *) kill "$p" 2>/dev/null ;; esac
  done <"$work/l-listeners"
  [ ! -f "$work/l-carriers" ] || while read -r p; do
    case $p in "" | *[!0-9]*) ;; *) kill "$p" 2>/dev/null && wait "$p" 2>/dev/null ;; esac
  done <"$work/l-carriers"
  [ -z "${l02_mounted-}" ] || sudo -n umount "$ro/l02alias"
  [ ! -f "$work/l-release" ] || while read -r n c; do
    if [ -d "$c" ]; then
      sudo -n timeout 30 /usr/bin/python3 -I "$root/scripts/ci/no-docker-aa.py" release "$n" "$c" >/dev/null 2>&1 && rm -rf "$c"
    fi
  done <"$work/l-release"
  chmod 700 "$ro/l03n1" "$ro/l03n2" "$ro/l03n0" 2>/dev/null
  rm -rf "$work" "$ro" "$vt"
}
trap cleanup EXIT
pass=0
fail=0

lcount=0
result() { # name ok(0|1) [detail]
  case $1 in L-*) lcount=$((lcount + 1)) ;; esac
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

# The Linux launches of this suite, counted for L-16's projection of the
# guard job (a file: some run in subshells). A launch is counted when it is
# started, so one of L-15c that TERM ends before it made anything counts
# too: the projection can only come out higher, never lower. Refusals
# before any resource (T-18, L-07) are not counted.
count_launch() { printf x >>"$work/launch-count"; }
ndl() { # no-docker.sh, counted on Linux
  [ "$os" != Linux ] || count_launch
  "$nd" "$@"
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
      gmark=$(python3 -I "$root/scripts/ci/no-docker-probe.py" --markers "$ndtmp" "$$") || exit 2
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
(deny file-read-data (literal \"$gmark/a\"))
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
      count_launch
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
# Refused for the right reason: the probe's mechanism check failed, and
# its part that writes and connects never ran.
t02=$(NO_DOCKER_ACTIVE=1 "$nd" touch "$work/t02" 2>&1)
r=$?
t02_after=$(printf '%s\n' "$t02" | grep -cE 'container engine answers|accepts a connection|writes to .* fail')
[ "$r" -eq 125 ] && [ ! -e "$work/t02" ] &&
  printf '%s\n' "$t02" | grep -q '^no-docker: refused: inside no-docker.sh, but the isolation check fails' &&
  printf '%s\n' "$t02" | grep -q '^no-docker: FAIL ' && [ "$t02_after" -eq 0 ]
result "T-02 claimed but unproven isolation (NO_DOCKER_ACTIVE outside it): refused by the mechanism check, command not run" $? \
  "(rc $r, $(printf '%s\n' "$t02" | grep -c '^no-docker: FAIL ') failed checks, $t02_after lines of the write and connect part)"

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
  # Both directories are shared with other users: each canary gets a
  # random name and is created exclusively, without following a link; it
  # is read and removed only while it is still the file created here
  # (same device and inode, a regular file of ours).
  t21_file='
import os, secrets, stat, sys
mode = sys.argv[1]
def same(path, dev, ino):
    st = os.lstat(path)
    return stat.S_ISREG(st.st_mode) and st.st_uid == os.getuid() and (st.st_dev, st.st_ino) == (int(dev), int(ino))
if mode == "create":
    path = os.path.join(sys.argv[2], "sh-thd-flowcrm-test-" + secrets.token_hex(12))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.write(fd, b"original\n")
    st = os.fstat(fd)
    os.close(fd)
    print(path, st.st_dev, st.st_ino)
elif mode == "read":
    path, dev, ino = sys.argv[2:5]
    try:
        if not same(path, dev, ino):
            print("replaced")
            sys.exit(0)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        print("same" if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) == (int(dev), int(ino)) and os.read(fd, 64) == b"original\n" else "changed")
        os.close(fd)
    except FileNotFoundError:
        print("missing")
elif mode == "remove":
    path, dev, ino = sys.argv[2:5]
    try:
        if same(path, dev, ino):
            os.unlink(path)
    except FileNotFoundError:
        pass
'
  read -r t21a t21a_dev t21a_ino < <(python3 -I -c "$t21_file" create /private/tmp) || exit 2
  read -r t21b t21b_dev t21b_ino < <(python3 -I -c "$t21_file" create /private/var/tmp) || exit 2
  case "$t21a $t21b" in /private/tmp/sh-thd-flowcrm-test-*" "/private/var/tmp/sh-thd-flowcrm-test-*) ;; *) echo "HARNESS ERROR: T-21 canaries not created" >&2; exit 2 ;; esac
  w21=$(new_work) || exit 2
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
  t21s=$(python3 -I -c "$t21_file" read "$t21a" "$t21a_dev" "$t21a_ino")
  [ "$t21s" = same ] || t21_left="$t21_left $t21s:$t21a"
  t21s=$(python3 -I -c "$t21_file" read "$t21b" "$t21b_dev" "$t21b_ino")
  [ "$t21s" = same ] || t21_left="$t21_left $t21s:$t21b"
  for f in "$t21a" "$t21b"; do
    for x in "$f.moved" "$f.new"; do [ ! -e "$x" ] && [ ! -L "$x" ] || t21_left="$t21_left $x"; done
  done
  printf '%s\n' "$t21" | grep '^t21 bad' | sed 's/^/INFO    /'
  [ "$r" -eq 0 ] && [ "$(printf '%s\n' "$t21" | grep -c '^t21 ok')" -eq 18 ] && [ -z "$t21_left" ]
  result "T-21 bash 3.2 here-document files (/private/tmp and /private/var/tmp sh-thd-*) cannot be written, replaced or created from inside" $? \
    "(rc $r, $(printf '%s\n' "$t21" | grep -c '^t21 ok') of 18 denied, changed or left:${t21_left:- none})"
  python3 -I -c "$t21_file" remove "$t21a" "$t21a_dev" "$t21a_ino"
  python3 -I -c "$t21_file" remove "$t21b" "$t21b_dev" "$t21b_ino"

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
if how == "linger":
    open(w + "/started", "w").write(f"{time.time():.3f}\n")
    time.sleep(3)
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

  # --- T-30 to T-34 a run is reported done only when it is shown that none
  # of its processes runs any more (B-1). no-docker-probe.py takes one copy
  # of the process table at a time and needs a copy in which every process
  # is shown not to be one of the run's, or was dead before that copy;
  # otherwise the run fails with 125 and keeps its marker directory, and
  # the next run refuses until that is shown.
  # On e8ed7ed: one process table that happened to show no member ended
  # the run as a success.
  #
  # T-30: a "hopper", each generation forking the next and ending, inside
  # the sandbox: bounded (it ends by itself 18 s after it starts, or after
  # 50000 generations) and recording a heartbeat in its run
  # directory. The run must not be reported done while it hops; the next
  # run must refuse while it hops; after it ended, a run starts again (and
  # removes the old marker directory).
  t30_hop='
import os, sys, time
beat, deadline = sys.argv[1], float(sys.argv[2])
g = 0
while g < 50000 and time.time() < deadline:
    g += 1
    if g % 100 == 0:
        with open(beat, "a") as f:
            f.write(f"{time.time():.3f} {g}\n")
    if os.fork():
        os._exit(0)
'
  t30_beats() { count_in . "$1"; }
  w30=$(new_work) || exit 2
  t30_end=$(($(date +%s) + 18))
  t0=$(date +%s)
  "$nd" --work "$w30" python3 -I -B -c "$t30_hop" "$w30/beat" "$t30_end" "t30-$nonce" >"$work/t30.out" 2>&1
  r=$?
  took=$(($(date +%s) - t0))
  n0=$(t30_beats "$w30/beat")
  sleep 1
  n1=$(t30_beats "$w30/beat")
  t30_hopping=no
  [ "$n1" -gt "$n0" ] && t30_hopping=yes
  w30b=$(new_work) || exit 2
  "$nd" --work "$w30b" /usr/bin/touch "$w30b/ran" >"$work/t30b.out" 2>&1
  r2=$?
  # Still hopping after that run returned? Then it must have refused.
  n2=$(t30_beats "$w30/beat")
  sleep 1
  t30_still=no
  [ "$(t30_beats "$w30/beat")" -gt "$n2" ] && t30_still=yes
  while [ "$(date +%s)" -le $((t30_end + 2)) ]; do sleep 1; done
  w30c=$(new_work) || exit 2
  "$nd" --work "$w30c" /usr/bin/touch "$w30c/ran" >"$work/t30c.out" 2>&1
  r3=$?
  # Not done while it hops: either the run failed (125, "could not be
  # shown") or, if it ended anyway, the hopper had stopped.
  { [ "$r" -eq 125 ] && grep -q 'could not be shown to have ended' "$work/t30.out"; } ||
    { [ "$r" -ne 125 ] && [ "$t30_hopping" = no ]; }
  t30_ok1=$?
  [ "$t30_ok1" -eq 0 ] && [ "$n0" -gt 0 ] &&
    { [ "$t30_still" = no ] || { [ "$r2" -eq 125 ] && [ ! -e "$w30b/ran" ]; }; } &&
    [ "$r3" -eq 0 ] && [ -e "$w30c/ran" ]
  t30_ok=$?
  echo "INFO  T-30 run rc $r after ${took}s, hopping afterwards $t30_hopping; next run rc $r2, hopping after it $t30_still; after its end rc $r3"
  [ "$t30_ok" -eq 0 ]
  result "T-30 a process that keeps forking and ending is never reported as ended; new runs refuse while it runs, and start after it ended" $? \
    "(run rc $r after ${took}s, hopping afterwards $t30_hopping; next run rc $r2, hopping after it $t30_still; after its end rc $r3)"

  # T-31: two runs at the same time, each leaving a daemon: both are
  # reported done, neither refuses the other, each ends its own daemon.
  w31a=$(new_work) || exit 2
  w31b=$(new_work) || exit 2
  "$nd" --work "$w31a" python3 -I -B -c "$t24_leaver" "$w31a" "t31a-$nonce" linger >"$work/t31a.out" 2>&1 &
  t31pa=$!
  "$nd" --work "$w31b" python3 -I -B -c "$t24_leaver" "$w31b" "t31b-$nonce" linger >"$work/t31b.out" 2>&1 &
  t31pb=$!
  wait "$t31pa"
  ra=$?
  wait "$t31pb"
  rb=$?
  sleep 0.5
  la=$(t24_left "$w31a" "t31a-$nonce")
  lb=$(t24_left "$w31b" "t31b-$nonce")
  t24_clean "$w31a" "t31a-$nonce"
  t24_clean "$w31b" "t31b-$nonce"
  [ "$ra" -eq 0 ] && [ "$rb" -eq 0 ] && regular "$w31a/started" && regular "$w31b/started" &&
    [ "$(count_in . "$w31a/pids")" -eq 4 ] && [ "$(count_in . "$w31b/pids")" -eq 4 ] && [ -z "$la$lb" ] &&
    ! grep -q 'refused' "$work/t31a.out" "$work/t31b.out"
  result "T-31 two runs at the same time each end their own processes and do not refuse each other" $? \
    "(rc $ra and $rb, survivors:${la}${lb:- none})"

  # T-32: unrelated processes that start and end while the run's
  # processes are checked (here: this suite's own short-lived /usr/bin/true
  # runs, outside) do not make the run fail: a process that ended before
  # it could be checked is ended, not unknown, once a later copy of the
  # table no longer has it.
  w32=$(new_work) || exit 2
  ( i=0; while [ "$i" -lt 3000 ]; do /usr/bin/true; i=$((i + 1)); done ) &
  t32churn=$!
  "$nd" --work "$w32" python3 -I -B -c "$t24_leaver" "$w32" "t32-$nonce" ok >"$work/t32.out" 2>&1
  r=$?
  # The churn must still have been running when the run ended.
  t32_overlap=no
  ps -o args= -p "$t32churn" 2>/dev/null | grep -q . && t32_overlap=yes
  wait "$t32churn"
  sleep 0.5
  left=$(t24_left "$w32" "t32-$nonce")
  t24_clean "$w32" "t32-$nonce"
  [ "$r" -eq 0 ] && [ "$t32_overlap" = yes ] && [ "$(count_in . "$w32/pids")" -eq 4 ] && [ -z "$left" ]
  result "T-32 processes that start and end outside meanwhile do not make the ending fail" $? \
    "(rc $r, churn still running at the end $t32_overlap, survivors:${left:- none})"

  # T-33: if the ending cannot be shown (here: this case removes the run's
  # marker file A while the command waits, then sends TERM), the run fails
  # (125), the supervisor's own child does not survive, and the marker
  # directory is kept. The case then ends the leftovers it recorded (by
  # pid, while their arguments carry its tag), removes that directory and
  # checks that a new run starts.
  w33=$(new_work) || exit 2
  t33_before=$(cd "$ndtmp" && ls -d no-docker-mark.* 2>/dev/null)
  python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$nd" --work "$w33" python3 -I -B -c "$t24_leaver" "$w33" "t33-$nonce" wait >"$work/t33.out" 2>&1 &
  ndpid=$!
  for _ in $(seq 1 100); do [ "$(count_in . "$w33/pids")" -ge 5 ] && regular "$w33/mark" && break; sleep 0.1; done
  t33_mark=""
  regular "$w33/mark" && t33_mark=$(cat "$w33/mark")
  case ${t33_mark#"$ndtmp"/} in no-docker-mark.*[!A-Za-z0-9_]* | "$t33_mark") t33_mark="" ;; no-docker-mark.?*) ;; *) t33_mark="" ;; esac
  case "
$t33_before
" in *"
${t33_mark#"$ndtmp"/}
"*) t33_mark="" ;; esac
  [ -n "$t33_mark" ] && [ -d "$t33_mark" ] && [ ! -L "$t33_mark" ] && [ -f "$t33_mark/a" ] && [ ! -L "$t33_mark/a" ] &&
    regular "$t33_mark/owner" && [ "$(cut -d' ' -f1 "$t33_mark/owner")" = "$ndpid" ] || t33_mark=""
  t33_main=$(sed -n 5p "$w33/pids" 2>/dev/null | tr -cd '0-9')
  r=none
  if [ -n "$t33_mark" ] && ps -o args= -p "$ndpid" 2>/dev/null | grep -q -- no-docker; then
    rm -f "$t33_mark/a"
    kill -TERM "$ndpid"
    wait "$ndpid"
    r=$?
  else
    ps -o args= -p "$ndpid" 2>/dev/null | grep -q -- no-docker && kill -TERM "$ndpid"
    wait "$ndpid" 2>/dev/null
  fi
  t33_child=gone
  [ -n "$t33_main" ] && ps -o args= -p "$t33_main" 2>/dev/null | grep -q -- "t33-$nonce" && t33_child=alive
  t33_kept=no
  [ -n "$t33_mark" ] && [ -d "$t33_mark" ] && t33_kept=yes
  t24_clean "$w33" "t33-$nonce"
  [ -n "$t33_mark" ] && rm -rf "$t33_mark"
  w33b=$(new_work) || exit 2
  "$nd" --work "$w33b" /usr/bin/touch "$w33b/ran" >/dev/null 2>&1
  r2=$?
  [ "$r" = 125 ] && grep -q 'could not be shown to have ended' "$work/t33.out" && [ "$t33_child" = gone ] &&
    [ "$t33_kept" = yes ] && [ "$r2" -eq 0 ] && [ -e "$w33b/ran" ]
  result "T-33 an ending that cannot be shown fails the run (125), ends the supervisor's own child and keeps the marker" $? \
    "(rc $r, command $t33_child, marker kept $t33_kept, next run rc $r2)"

  # T-35: a zombie outside (a child of this suite that has ended and is
  # not reaped for 15 s) does not make the ending unprovable: it is found
  # as a zombie and counts as dead from the next copy of the table on.
  # On 980d6a5 before the fix: zombies were not found (they read as
  # vanished), so every copy stayed open and the run failed with 125.
  python3 -I -c 'import subprocess, sys, time
p = subprocess.Popen(["/usr/bin/true"])
open(sys.argv[1], "w").write(str(p.pid))
time.sleep(15)
p.wait()' "$work/t35.zombie" &
  t35holder=$!
  for _ in $(seq 1 50); do regular "$work/t35.zombie" && break; sleep 0.1; done
  sleep 0.5
  t35z=$(tr -cd '0-9' <"$work/t35.zombie" 2>/dev/null)
  t35_state=$(ps -o stat= -p "${t35z:-0}" 2>/dev/null | tr -d ' ')
  w35=$(new_work) || exit 2
  "$nd" --work "$w35" python3 -I -B -c "$t24_leaver" "$w35" "t35-$nonce" ok >"$work/t35.out" 2>&1
  r=$?
  sleep 0.5
  left=$(t24_left "$w35" "t35-$nonce")
  t24_clean "$w35" "t35-$nonce"
  wait "$t35holder"
  echo "INFO  T-35 zombie ${t35z:-?} state ${t35_state:-gone} during the run; rc $r; survivors:${left:- none}"
  case $t35_state in Z*) t35_zombie=yes ;; *) t35_zombie=no ;; esac
  [ "$t35_zombie" = yes ] && [ "$r" -eq 0 ] && [ -z "$left" ]
  result "T-35 a zombie outside does not make the ending of a run unprovable" $? "(zombie $t35_zombie, rc $r)"

  # T-34: TERM to no-docker.sh while the command is starting processes
  # (at 0, 0.15 and 0.4 s after it recorded its first one; it starts one
  # every 50 ms for 1 s): processes must have been recorded when TERM is
  # sent; each run ends within 15 s, interrupted (143) or, if the ending
  # could not be shown, 125 with that message; none of the processes it
  # recorded survives once the run ended or was ended through its own
  # marker directory.
  t34_spawn='
import os, sys, time
w, tag = sys.argv[1], sys.argv[2]
open(w + "/mark", "w").write(os.environ.get("NO_DOCKER_MARK", ""))
SLEEP = [sys.executable, "-I", "-B", "-c", "import os, sys, time; open(sys.argv[1], \"a\").write(f\"{os.getpid()}\\n\"); time.sleep(30)", w + "/pids", tag]
for _ in range(20):
    if os.fork() == 0:
        os.setsid()
        os.execv(SLEEP[0], SLEEP)
    time.sleep(0.05)
time.sleep(30)
'
  t34_bad=""
  for t34_delay in 0 0.15 0.4; do
    w34=$(new_work) || exit 2
    t34_before=$(cd "$ndtmp" && ls -d no-docker-mark.* 2>/dev/null)
    python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])' "$nd" --work "$w34" python3 -I -B -c "$t34_spawn" "$w34" "t34-$nonce" >"$work/t34.out" 2>&1 &
    ndpid=$!
    for _ in $(seq 1 200); do [ "$(count_in . "$w34/pids")" -ge 1 ] && break; sleep 0.05; done
    sleep "$t34_delay"
    t34_n=$(count_in . "$w34/pids")
    t0=$(date +%s)
    ps -o args= -p "$ndpid" 2>/dev/null | grep -q -- no-docker && kill -TERM "$ndpid"
    wait "$ndpid"
    r=$?
    took=$(($(date +%s) - t0))
    t34_all=$(count_in . "$w34/pids")
    sleep 0.5
    left=$(t24_left "$w34" "t34-$nonce")
    if [ "$r" -eq 125 ]; then
      # Not shown: the kept marker directory of this run ends what is left.
      # It is the one the command recorded, if that is a directory that did
      # not exist before this iteration and whose owner record names this
      # run's no-docker.sh (now gone); --end also refuses a directory whose
      # owner still runs.
      t34_mark=""
      regular "$w34/mark" && t34_mark=$(cat "$w34/mark")
      case ${t34_mark#"$ndtmp"/} in no-docker-mark.*[!A-Za-z0-9_]* | "$t34_mark") t34_mark="" ;; no-docker-mark.?*) ;; *) t34_mark="" ;; esac
      case "
$t34_before
" in *"
${t34_mark#"$ndtmp"/}
"*) t34_mark="" ;; esac
      if [ -n "$t34_mark" ] && [ -d "$t34_mark" ] && [ ! -L "$t34_mark" ] && regular "$t34_mark/owner" &&
        [ "$(cut -d' ' -f1 "$t34_mark/owner")" = "$ndpid" ]; then
        python3 -I "$root/scripts/ci/no-docker-probe.py" --end "$t34_mark" >/dev/null 2>&1
      fi
      sleep 0.5
      left=$(t24_left "$w34" "t34-$nonce")
    fi
    t24_clean "$w34" "t34-$nonce"
    echo "INFO  T-34 after ${t34_delay}s: $t34_n recorded at TERM, $t34_all in all, rc $r, ${took}s, survivors:${left:- none}"
    [ "$t34_n" -ge 1 ] || t34_bad="$t34_bad delay$t34_delay:nothing-recorded-at-TERM"
    case $r in
      143) ;;
      125) grep -q 'could not be shown to have ended' "$work/t34.out" || t34_bad="$t34_bad delay$t34_delay:125-without-message" ;;
      *) t34_bad="$t34_bad delay$t34_delay:rc$r" ;;
    esac
    [ "$took" -le 15 ] || t34_bad="$t34_bad delay$t34_delay:${took}s"
    [ -z "$left" ] || t34_bad="$t34_bad delay$t34_delay:survivors$left"
  done
  [ -z "$t34_bad" ]
  result "T-34 TERM while the command starts processes: every run ends in time and none of its processes survives" $? "(${t34_bad:- all ok})"

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
  echo "INFO  T-06, T-08 to T-15, T-21, T-22, T-24 to T-35 skipped: macOS sandbox profile only"
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
t07=$(ndl python3 -I -c '
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
  ndl findmnt -rn -o TARGET,FSTYPE,OPTIONS 2>&1 | sed 's/^/INFO    /'

  # --- L-tests: the kernel-enforced isolation (Linux CI only). Each case
  # prints a fixed number of result lines (97 in all with L-16 at the end)
  # and has its control: a denial counts only where the same target is
  # shown reachable outside. Sockets, carriers and mounts here are this
  # suite's own and are ended or undone in cleanup.
  profiles() { sudo -n cat /sys/kernel/security/apparmor/profiles; }
  # listed NAME-PREFIX: the number of loaded profiles whose name starts so.
  listed() {
    local l
    l=$(profiles 2>/dev/null) || {
      echo unknown
      return
    }
    printf '%s\n' "$l" | grep -c "^$1"
  }
  ctl_dirs() { find "$RUNNER_TEMP" -maxdepth 1 -name 'no-docker-ctl.*' 2>/dev/null | wc -l | tr -d ' '; }
  # The listeners and the client the cases use (outside and inside).
  cat >"$ro/lsock.py" <<'PY'
import os, socket, sys, time
kind, path, ready = sys.argv[1:4]
fam = socket.SOCK_DGRAM if kind == "dgram" else socket.SOCK_STREAM
s = socket.socket(socket.AF_UNIX, fam)
s.bind("\0" + path if kind == "abstract" else path)
if kind != "dgram":
    s.listen(64)
with open(ready + ".tmp", "w") as f:
    f.write(f"{os.getpid()} {time.time_ns()}")
os.rename(ready + ".tmp", ready)
count = 0
end = time.time() + 900
while time.time() < end:
    if kind == "dgram":
        s.recv(65536)
    else:
        c = s.accept()[0]
        if kind == "scm":
            fd = os.open(sys.argv[4], os.O_RDONLY)
            socket.send_fds(c, [b"x"], [fd])
            os.close(fd)
        c.close()
    count += 1
    with open(ready + ".count.tmp", "w") as f:
        f.write(str(count))
    os.rename(ready + ".count.tmp", ready + ".count")
PY
  cat >"$ro/lclient.py" <<'PY'
import errno, os, socket, sys, time
def name(e):
    return "timeout" if isinstance(e, socket.timeout) else errno.errorcode.get(e.errno, str(e.errno))
def unix(kind):
    s = socket.socket(socket.AF_UNIX, kind)
    opened.append(s)
    return s
args = sys.argv[1:]
for op, target in zip(args[0::2], args[1::2]):
    opened = []
    try:
        if op == "stream":
            s = unix(socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(target)
            r = "OK"
        elif op == "dgram-connect":
            unix(socket.SOCK_DGRAM).connect(target)
            r = "OK"
        elif op == "dgram-send":
            unix(socket.SOCK_DGRAM).sendto(b"x", target)
            r = "OK"
        elif op == "abstract":
            s = unix(socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect("\0" + target)
            r = "OK"
        elif op == "scm":
            s = unix(socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(target)
            fds = socket.recv_fds(s, 16, 4)[1]
            for fd in fds:
                os.close(fd)
            r = f"OK fds={len(fds)}"
        elif op == "vsock":
            opened.append(socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM))
            r = "OK"
        elif op == "late":
            # The listener writes "ready" next to its socket once it listens.
            ready = os.path.join(os.path.dirname(target), "ready")
            for _ in range(600):
                if os.path.exists(ready):
                    break
                time.sleep(0.05)
            print(f"TIME {time.time_ns()}", flush=True)
            s = unix(socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(target)
            r = "OK"
        elif op == "label":
            with open("/proc/self/attr/apparmor/current") as f:
                r = f.read().strip()
            print(f"PROFILE {os.environ.get('NO_DOCKER_PROFILE', '')}", flush=True)
        elif op == "fds":
            open_fds = []
            for fd in sorted(int(x) for x in os.listdir("/proc/self/fd")):
                try:
                    os.fstat(fd)
                    open_fds.append(str(fd))
                except OSError:
                    pass
            r = " ".join(open_fds)
        else:
            r = "unknown-op"
    except OSError as e:
        r = name(e)
    finally:
        for s in opened:
            s.close()
    print(f"RESULT {op} {target} {r}", flush=True)
PY
  # res FILE OP TARGET: the result the client printed for OP on TARGET.
  res() { sed -n "s|^RESULT $2 $3 ||p" "$1" 2>/dev/null | tail -n 1; }
  # lsock KIND PATH READY [ARG]: start a listener of this suite and wait
  # until it is ready; its pid is the first word of READY.
  lsock() {
    python3 -I "$ro/lsock.py" "$@" </dev/null >/dev/null 2>&1 &
    for _ in $(seq 1 80); do [ -s "$3" ] && break; sleep 0.1; done
    [ -s "$3" ] || return 1
    printf '%s\n' "$3" >>"$work/l-listeners"
  }
  # lstop READY: end the listener recorded there (by its pid, then forgotten).
  lstop() {
    local p
    p=$(cut -d' ' -f1 "$1" 2>/dev/null)
    case $p in "" | *[!0-9]*) return ;; esac
    kill "$p" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    rm -f "$1"
  }
  # wait_bounded PID SECONDS: wait for a child of this suite; 124 if it is
  # still running after SECONDS (then it is killed).
  wait_bounded() {
    local i=0
    while kill -0 "$1" 2>/dev/null; do
      if [ "$i" -ge $(($2 * 10)) ]; then
        kill -KILL "$1" 2>/dev/null
        wait "$1" 2>/dev/null
        return 124
      fi
      sleep 0.1
      i=$((i + 1))
    done
    wait "$1"
  }
  # left_loaded LOG: release a profile a launch reported left loaded, once
  # its namespace's processes are gone (RR-06); recorded for cleanup too.
  left_loaded() {
    local line n c
    line=$(grep -m1 '^no-docker: refused: profile .* still loaded' "$1" 2>/dev/null) || return 1
    n=${line#no-docker: refused: profile }
    n=${n%% *}
    c=${line##*control directory }
    c=${c%% is kept}
    printf '%s %s\n' "$n" "$c" >>"$work/l-release"
    for _ in $(seq 1 20); do
      # shellcheck disable=SC2024 # this shell appends the helper's messages to the log
      if sudo -n timeout 30 /usr/bin/python3 -I "$root/scripts/ci/no-docker-aa.py" release "$n" "$c" >>"$1" 2>&1; then
        rm -rf "$c"
        return 0
      fi
      sleep 2
    done
    return 1
  }
  nd_listed_before=$(listed flowcrm-nd-)


  # --- T-16 a canary inside the isolation: private pid view, read-only
  # $HOME/workspace/RUNNER_TEMP, private /tmp, read-only mounts, masked
  # cgroups, private IPC, loopback only; confined by exactly its profile,
  # descriptors 0 to 2 only, the launch's fence refused; and every host
  # socket gathered outside by this suite classified: (i) reachable outside
  # and visible inside must be refused with EACCES exactly; (ii) under a
  # directory the isolation hides (/run, /var/run, /tmp, /var/tmp, /dev/shm)
  # is not found inside; (iii) not reachable outside is only reported; none
  # is ever reached inside. A socket of this suite in $RUNNER_TEMP makes
  # sure class (i) is not empty.
  # On 38b5ebd: no pid namespace (pid 1 is the runner's systemd, foreign
  # processes visible), and $HOME and the workspace were writable.
  cat >"$ro/t16.py" <<'PY'
import errno, glob, os, socket, sys
ipc_host, pid_host, out_tmp, out_shm, in_tmp, classes, nonce = sys.argv[1:8]
targets = sys.argv[8:]
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
def reach(path):
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        s = socket.socket(socket.AF_UNIX, kind)
        s.settimeout(2)
        try:
            s.connect(path)
            return "OK"
        except socket.timeout:
            return "timeout"
        except OSError as e:
            if e.errno == errno.EPROTOTYPE:
                continue
            return errno.errorcode.get(e.errno, str(e.errno))
        finally:
            s.close()
    return "EPROTOTYPE"
st = status("self")
say(st.get("NSpid", "").split() == [str(os.getpid())], f"NSpid {st.get('NSpid')} is this pid alone (a /proc of its own pid namespace)")
own = os.readlink("/proc/self/ns/pid")
say(pid_host == "pid:[4026531836]" and own not in (pid_host, "pid:[4026531836]"),
    f"a pid namespace below the caller's, the initial one ({own}; caller {pid_host})")
s1 = status(1)
say(s1["Uid"].split()[0] == "0" and s1["Name"] == "sh", f"pid 1 is the isolation's root shell ({s1['Name']}, uid {s1['Uid'].split()[0]})")
others = []
for d in os.listdir("/proc"):
    if d.isdigit() and d != "1":
        try:
            s = status(d)
        except OSError as e:
            if e.errno not in (errno.ENOENT, errno.ESRCH):
                others.append(f"{d}:unreadable")
            continue
        if any(u != me for u in s["Uid"].split()) or s["Name"] in ("systemd", "Runner.Worker", "Runner.Listener", "dockerd", "containerd"):
            others.append(f"{d}:{s['Name']}")
say(not others, f"no foreign process visible ({' '.join(others) or 'none'})")
with open("/proc/self/mountinfo") as f:
    procs = [l.split() for l in f if l.split()[4] == "/proc"]
hidden = [o for r in procs for o in r[5].split(",") + r[r.index("-") + 3].split(",")
          if (o.startswith("hidepid=") and o not in ("hidepid=0", "hidepid=off")) or o.startswith("subset=")]
say(len(procs) >= 1 and not hidden, f"/proc hides no process ({','.join(hidden) or 'no hidepid or subset'})")
try:
    os.listdir("/proc/1/root")
    say(False, "/proc/1/root is not readable")
except OSError as e:
    say(e.errno in (errno.EACCES, errno.EPERM), f"/proc/1/root is not readable ({errno.errorcode.get(e.errno)})")
with open(classes) as f:
    rows = [line.rstrip("\n").split(" ", 2) for line in f if line.strip()]
for cls, outside, path in rows:
    got = reach(path)
    if cls == "i":
        good = got == "EACCES"
    elif cls == "ii":
        good = got in ("ENOENT", "EACCES")
    else:
        good = got != "OK"
    say(good, f"host socket class ({cls}) {path}: outside {outside}, inside {got}")
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
with open("/proc/self/attr/apparmor/current") as f:
    label = f.read().strip()
profile = os.environ.get("NO_DOCKER_PROFILE", "")
say(bool(profile) and label == f"{profile} (enforce)", f"confined by exactly the launch's profile ({label})")
fds = []
for fd in sorted(int(x) for x in os.listdir("/proc/self/fd")):
    try:
        os.fstat(fd)
        fds.append(fd)
    except OSError:
        pass
say(fds == [0, 1, 2], f"only descriptors 0 to 2 are open ({' '.join(map(str, fds))})")
fence = glob.glob(os.path.join(os.environ.get("HOME", "/nonexistent"), "work/_temp/no-docker-fence.*"))
got = [reach(os.path.join(fence[0], k)) for k in ("stream", "dgram")] if len(fence) == 1 else [f"{len(fence)} fence directories"]
say(got == ["EACCES", "EACCES"], f"the launch's fence refuses the command too ({' '.join(got)})")
PY
  t16_tmp=/tmp/.flowcrm-no-docker-test-t16-$nonce
  t16_shm=/dev/shm/.flowcrm-no-docker-test-t16-$nonce
  t16_in=/tmp/.flowcrm-no-docker-test-t16-in-$nonce
  : >"$t16_tmp"
  : 2>/dev/null >"$t16_shm"
  # Sockets of the host, found here independently of no-docker.sh, and one
  # of this suite where nothing hides it.
  mkdir -m 700 "$ro/t16own" || exit 2
  lsock stream "$ro/t16own/s" "$work/t16own.ready"
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
    printf '%s\0' "$ro/t16own/s"
  } | sort -zu >"$ro/t16-sockets"
  # Classify each outside: reachable here, and under a directory the
  # isolation hides.
  python3 -I -c '
import errno, socket, sys
masked = ("/run/", "/var/run/", "/tmp/", "/var/tmp/", "/dev/shm/")
for raw in open(sys.argv[1], "rb").read().split(b"\0"):
    if not raw or b" " in raw or b"\n" in raw:
        continue
    path = raw.decode("utf-8", "replace")
    got = "EPROTOTYPE"
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        s = socket.socket(socket.AF_UNIX, kind)
        s.settimeout(2)
        try:
            s.connect(path)
            got = "OK"
            break
        except socket.timeout:
            got = "timeout"
            break
        except OSError as e:
            got = errno.errorcode.get(e.errno, str(e.errno))
            if e.errno != errno.EPROTOTYPE:
                break
        finally:
            s.close()
    cls = "iii" if got != "OK" else "ii" if path.startswith(masked) else "i"
    print(cls, got, path)
' "$ro/t16-sockets" >"$ro/t16-classes"
  t16_targets=("$home")
  for v in GITHUB_WORKSPACE RUNNER_TEMP; do [ -z "${!v-}" ] || t16_targets+=("${!v}"); done
  [ ! -d /opt/hostedtoolcache ] || t16_targets+=(/opt/hostedtoolcache)
  t16=$(ndl python3 -I "$ro/t16.py" "$(readlink /proc/self/ns/ipc)" "$(readlink /proc/self/ns/pid)" "$t16_tmp" "$t16_shm" "$t16_in" \
    "$ro/t16-classes" "$nonce" "${t16_targets[@]}" 2>&1)
  r=$?
  lstop "$work/t16own.ready"
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
  t16_n=$(grep -c . "$ro/t16-classes")
  t16_i=$(grep -c '^i ' "$ro/t16-classes")
  # One line per check: 13, the label, the descriptors and the fence (3),
  # one per protected directory and one per host socket.
  t16_want=$((16 + ${#t16_targets[@]} + t16_n))
  [ "$r" -eq 0 ] && ! printf '%s\n' "$t16" | grep -q '^t16 bad' && [ "$t16_ok" -eq "$t16_want" ] && [ -z "$t16_left" ] &&
    [ "$t16_i" -ge 1 ]
  result "T-16 inside the isolation: private pids, confined, host sockets refused, read-only \$HOME/workspace/RUNNER_TEMP, private /tmp, read-only mounts, masked cgroups, private IPC" $? \
    "(rc $r, $t16_ok of $t16_want ok, $t16_n host sockets, $t16_i of class (i), markers left in:${t16_left:- none})"
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
  t17=$(ndl /bin/sh -c 'setsid -f /bin/sh -c "sleep 60; :" "$1-in" </dev/null >/dev/null 2>&1
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
  count_launch
  "$nd" /bin/sh -c 'setsid -f /bin/sh -c "sleep 60; :" "$1-in" </dev/null >/dev/null 2>&1; sleep 60; :' _ "$t17c" >/dev/null 2>&1 &
  t17pid=$!
  # Up to 150 s: longer than the bound of the cleanup (112 s).
  for _ in $(seq 1 300); do pgrep -f -- "$t17c-in" >/dev/null && break; sleep 0.5; done
  started=no
  pgrep -f -- "$t17c-in" >/dev/null && started=yes
  kill -TERM "$t17pid" 2>/dev/null
  wait "$t17pid" 2>/dev/null
  r=$?
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f -- "$t17c-in" >/dev/null || break; sleep 0.5; done
  pgrep -f -- "$t17c-in" >/dev/null
  left=$?
  pkill -TERM -f -- "$t17c" 2>/dev/null
  [ "$started" = yes ] && [ "$left" -ne 0 ] && [ "$r" -eq 143 ]
  result "T-17 TERM delivered to no-docker.sh itself kills every process inside the isolation (143)" $? \
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
  t18 "--negative-control off a GitHub-hosted runner" "GitHub-hosted" env RUNNER_ENVIRONMENT=self-hosted "$nd" --negative-control /usr/bin/true
  t18 "--negative-control in a nested run" "refused inside the isolation" env NO_DOCKER_ACTIVE=1 "$nd" --negative-control /usr/bin/true

  # --- L-01 host pathname stream, datagram connect and sendto, abstract:
  # refused inside, reachable outside before and after.
  mkdir -m 700 "$ro/l01" || exit 2
  l01_ok=yes
  lsock stream "$ro/l01/s" "$work/l01s.ready" && lsock dgram "$ro/l01/d" "$work/l01d.ready" &&
    lsock abstract "flowcrm-l01-$nonce" "$work/l01a.ready" || l01_ok=no
  l01_targets=(stream "$ro/l01/s" dgram-connect "$ro/l01/d" dgram-send "$ro/l01/d" abstract "flowcrm-l01-$nonce")
  python3 -I "$ro/lclient.py" "${l01_targets[@]}" >"$work/l01.before" 2>&1
  ndl python3 -I "$ro/lclient.py" "${l01_targets[@]}" label - >"$work/l01.in" 2>"$work/l01.err"
  r=$?
  python3 -I "$ro/lclient.py" "${l01_targets[@]}" >"$work/l01.after" 2>&1
  for t in "stream $ro/l01/s EACCES" "dgram-connect $ro/l01/d EACCES" "dgram-send $ro/l01/d EACCES" \
    "abstract flowcrm-l01-$nonce ECONNREFUSED"; do
    read -r op tgt want <<<"$t"
    [ "$l01_ok" = yes ] && [ "$r" -eq 0 ] && [ "$(res "$work/l01.in" "$op" "$tgt")" = "$want" ]
    result "L-01 inside: $op to a socket of the host is refused with $want" $? "(rc $r, got $(res "$work/l01.in" "$op" "$tgt"))"
  done
  l01_profile=$(sed -n 's/^PROFILE //p' "$work/l01.in")
  case $l01_profile in flowcrm-nd-????????????????????????????????) ;; *) l01_profile=none ;; esac
  [ "$(res "$work/l01.in" label -)" = "$l01_profile (enforce)" ]
  result "L-01 inside: the command is confined by exactly its profile in enforce mode" $? "($(res "$work/l01.in" label -))"
  for when in before after; do
    for t in "stream $ro/l01/s" "dgram-connect $ro/l01/d" "dgram-send $ro/l01/d" "abstract flowcrm-l01-$nonce"; do
      read -r op tgt <<<"$t"
      [ "$(res "$work/l01.$when" "$op" "$tgt")" = OK ]
      result "L-01 control $when: $op outside reaches the same socket" $? "($(res "$work/l01.$when" "$op" "$tgt"))"
    done
  done
  lstop "$work/l01s.ready"
  lstop "$work/l01d.ready"
  lstop "$work/l01a.ready"

  # --- L-02 a bind-mounted alias of a host socket's directory.
  mkdir -m 700 "$ro/l02src" "$ro/l02alias" || exit 2
  lsock stream "$ro/l02src/s" "$work/l02.ready" && sudo -n mount --bind "$ro/l02src" "$ro/l02alias" && l02_mounted=yes
  python3 -I "$ro/lclient.py" stream "$ro/l02alias/s" >"$work/l02.out" 2>&1
  [ "${l02_mounted-}" = yes ] && [ "$(res "$work/l02.out" stream "$ro/l02alias/s")" = OK ]
  result "L-02 control: outside, the socket is reachable through the alias" $?
  ndl python3 -I "$ro/lclient.py" stream "$ro/l02alias/s" >"$work/l02.in" 2>"$work/l02.err"
  r=$?
  [ "$(res "$work/l02.in" stream "$ro/l02alias/s")" = EACCES ]
  result "L-02 inside: a connect through the alias is refused with EACCES" $? "($(res "$work/l02.in" stream "$ro/l02alias/s"))"
  [ "$r" -eq 0 ]
  result "L-02 the run proceeds (the command ran)" $? "(rc $r)"
  sudo -n umount "$ro/l02alias" && l02_mounted=""
  lstop "$work/l02.ready"

  # --- L-03 a directory that cannot be listed (0311): N1 a listener in the
  # host network namespace, N2 in one of its own, N0 the socket file of a
  # listener that ended.
  l03() { # n1|n2|n0 listener-prefix...: start the listener of a case in a 0311 directory
    local n=$1
    shift
    mkdir -m 700 "$ro/l03$n" || return 1
    "$@" python3 -I "$ro/lsock.py" stream "$ro/l03$n/s" "$work/l03$n.ready" </dev/null >/dev/null 2>&1 &
    for _ in $(seq 1 80); do [ -s "$work/l03$n.ready" ] && break; sleep 0.1; done
    [ -s "$work/l03$n.ready" ] && printf '%s\n' "$work/l03$n.ready" >>"$work/l-listeners" && chmod 311 "$ro/l03$n"
  }
  l03 n1
  l03 n2 sudo -n unshare --net -- setpriv --reuid "$(id -u)" --regid "$(id -g)" --clear-groups --
  l03 n0 && lstop "$work/l03n0.ready"
  for n in n1:N1 n2:N2; do
    case=${n#*:} n=${n%%:*}
    python3 -I "$ro/lclient.py" stream "$ro/l03$n/s" >"$work/l03$n.out" 2>&1
    ndl python3 -I "$ro/lclient.py" stream "$ro/l03$n/s" >"$work/l03$n.in" 2>"$work/l03$n.err"
    r=$?
    [ "$(res "$work/l03$n.out" stream "$ro/l03$n/s")" = OK ]
    result "L-03 $case control: outside, the socket in the unlistable directory is reachable" $?
    [ "$r" -eq 0 ] && [ "$(res "$work/l03$n.in" stream "$ro/l03$n/s")" = EACCES ]
    result "L-03 $case inside: the run proceeds and the connect is refused with EACCES" $? \
      "(rc $r, $(res "$work/l03$n.in" stream "$ro/l03$n/s"))"
  done
  python3 -I "$ro/lclient.py" stream "$ro/l03n0/s" >"$work/l03n0.out" 2>&1
  ndl python3 -I "$ro/lclient.py" stream "$ro/l03n0/s" >"$work/l03n0.in" 2>"$work/l03n0.err"
  r=$?
  [ "$r" -eq 0 ] && [ "$(res "$work/l03n0.in" stream "$ro/l03n0/s")" = ECONNREFUSED ] &&
    [ "$(res "$work/l03n0.out" stream "$ro/l03n0/s")" = ECONNREFUSED ]
  result "L-03 N0: a socket file without a listener is ECONNREFUSED inside and outside" $? \
    "(rc $r, inside $(res "$work/l03n0.in" stream "$ro/l03n0/s"))"
  lstop "$work/l03n1.ready"
  lstop "$work/l03n2.ready"
  chmod 700 "$ro/l03n1" "$ro/l03n2" "$ro/l03n0" 2>/dev/null

  # --- L-04 a socket bound outside after the command started.
  mkdir -m 700 "$ro/l04" || exit 2
  g=$(new_work) || exit 2
  count_launch
  "$nd" --work "$g" python3 -I "$ro/lclient.py" late "$ro/l04/s" >"$work/l04.in" 2>"$work/l04.err" &
  l04pid=$!
  for _ in $(seq 1 300); do [ -e "$g/started" ] && break; sleep 0.1; done
  l04_started=$(python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$g/started" 2>/dev/null || echo 0)
  lsock stream "$ro/l04/s" "$ro/l04/ready"
  wait_bounded "$l04pid" 150
  r=$?
  python3 -I "$ro/lclient.py" stream "$ro/l04/s" >"$work/l04.out" 2>&1
  [ "$(res "$work/l04.out" stream "$ro/l04/s")" = OK ]
  result "L-04 control: outside, the late socket is reachable" $?
  [ "$r" -eq 0 ] && [ "$(res "$work/l04.in" late "$ro/l04/s")" = EACCES ]
  result "L-04 inside: a socket bound after the start is refused with EACCES" $? "(rc $r, $(res "$work/l04.in" late "$ro/l04/s"))"
  l04_bound=$(cut -d' ' -f2 "$ro/l04/ready" 2>/dev/null)
  l04_tried=$(sed -n 's/^TIME //p' "$work/l04.in")
  [ "${l04_started:-0}" -gt 0 ] && [ "${l04_bound:-0}" -gt "$l04_started" ] && [ "${l04_tried:-0}" -gt "${l04_bound:-0}" ]
  result "L-04 the order: the command started, then the socket was bound, then the connect" $? \
    "(started $l04_started, bound ${l04_bound:-?}, connect ${l04_tried:-?})"
  lstop "$ro/l04/ready"

  # --- L-05 sockets of the command's own still work.
  ndl python3 -I -c '
import socket
for kind, name in ((socket.SOCK_STREAM, "stream"), (socket.SOCK_DGRAM, "dgram")):
    path = f"/tmp/l05-{name}"
    a = socket.socket(socket.AF_UNIX, kind)
    a.bind(path)
    b = socket.socket(socket.AF_UNIX, kind)
    try:
        if kind == socket.SOCK_STREAM:
            a.listen(1)
            b.settimeout(2)
            b.connect(path)
        else:
            b.sendto(b"x", path)
            a.settimeout(2)
            a.recv(10)
        print(f"RESULT pair {name} OK")
    except OSError as e:
        print(f"RESULT pair {name} {e}")
' >"$work/l05.in" 2>"$work/l05.err"
  r=$?
  grep -q '^no-docker: ok   a socket bound inside the isolation connects (ok)$' "$work/l05.err"
  result "L-05 the gate's twin socket inside connected" $?
  [ "$r" -eq 0 ] && [ "$(res "$work/l05.in" pair stream)" = OK ]
  result "L-05 a stream socket pair of the command in /tmp connects" $? "($(res "$work/l05.in" pair stream))"
  [ "$(res "$work/l05.in" pair dgram)" = OK ]
  result "L-05 a datagram socket pair of the command in /tmp exchanges a message" $? "($(res "$work/l05.in" pair dgram))"

  # --- L-06 exec and children, escapes, signal dispositions, vsock. The
  # command is /bin/sh, which reads its own status with builtins (a CPython
  # would ignore SIGPIPE and SIGXFSZ itself).
  ndl /bin/sh -c '
while read -r k v rest; do
  case $k in SigIgn:) echo "SIGIGN $v" ;; SigBlk:) echo "SIGBLK $v" ;; esac
done </proc/self/status
echo "PID $$"
sh -c "sh -c \"cat /proc/self/attr/apparmor/current\"" | sed "s/^/GRANDCHILD /"
if printf "changeprofile unconfined" >/proc/self/attr/apparmor/current 2>/dev/null; then echo "CHANGEPROFILE CHANGED"; else echo "CHANGEPROFILE DENIED"; fi
if aa-exec -p unconfined -- true 2>/dev/null; then echo "AAEXEC CHANGED"; else echo "AAEXEC DENIED"; fi
if unshare -U true 2>/dev/null; then echo "USERNS CREATED"; else echo "USERNS DENIED"; fi
python3 -I "$1" vsock -
echo "PROFILE $NO_DOCKER_PROFILE"
' l06 "$ro/lclient.py" >"$work/l06.in" 2>"$work/l06.err"
  l06p=$(sed -n 's/^PROFILE //p' "$work/l06.in")
  [ "$(sed -n 's/^GRANDCHILD //p' "$work/l06.in")" = "$l06p (enforce)" ] && [ -n "$l06p" ]
  result "L-06 a grandchild of the command carries exactly the profile" $? "($(sed -n 's/^GRANDCHILD //p' "$work/l06.in"))"
  l06pid=$(sed -n 's/^PID //p' "$work/l06.in")
  grep -q "^no-docker: info the gate passed in [0-9.]*s (pid $l06pid)\$" "$work/l06.err" && [ -n "$l06pid" ]
  result "L-06 the command runs in the gate's own process" $? "(command pid ${l06pid:-?})"
  for t in "CHANGEPROFILE change_profile to unconfined" "AAEXEC aa-exec -p unconfined" "USERNS unshare -U"; do
    read -r tag what <<<"$t"
    grep -qx "$tag DENIED" "$work/l06.in"
    result "L-06 inside: $what is denied" $?
  done
  grep -qx 'SIGIGN 0000000000000000' "$work/l06.in"
  result "L-06 the command ignores no signal (SigIgn)" $? "($(grep '^SIGIGN' "$work/l06.in"))"
  grep -qx 'SIGBLK 0000000000000000' "$work/l06.in"
  result "L-06 the command blocks no signal (SigBlk)" $? "($(grep '^SIGBLK' "$work/l06.in"))"
  [ "$(res "$work/l06.in" vsock -)" = EACCES ]
  result "L-06 inside: an AF_VSOCK socket is refused with EACCES" $? "($(res "$work/l06.in" vsock -))"
  unshare -U true 2>/dev/null
  result "L-06 control: outside, unshare -U true succeeds" $?
  aa-exec -p unconfined -- true 2>/dev/null
  result "L-06 control: outside, aa-exec -p unconfined true succeeds" $?
  python3 -I "$ro/lclient.py" vsock - >"$work/l06.out" 2>&1
  echo "INFO  L-06 outside AF_VSOCK: $(res "$work/l06.out" vsock -)"
  [ -n "$(res "$work/l06.out" vsock -)" ] && [ "$(res "$work/l06.out" vsock -)" != EACCES ]
  result "L-06 control: outside, an AF_VSOCK socket is not refused with EACCES" $?

  # --- L-18 (with L-17) the command's output through the relays, read by
  # a pipe consumer: complete, with its last stdout line a workflow command
  # that must stay ignored (the resume token comes after it).
  # shellcheck disable=SC2016
  l18_py='
import sys
out = b"".join(b"%07d" % i + b"." * 120 + b"\n" for i in range(8000)) + b"::error::injected-by-test\n"
err = b"e" * 65535 + b"\n"
if sys.argv[1:] == ["sums"]:
    import hashlib
    print(hashlib.sha256(out).hexdigest(), hashlib.sha256(err).hexdigest())
else:
    sys.stdout.buffer.write(out)
    sys.stdout.flush()
    sys.stderr.buffer.write(err)
'
  ndl python3 -I -c "$l18_py" 2>"$work/l18.err" | cat >"$work/l18.out"
  l18_rc=${PIPESTATUS[0]}
  l18_out_sum=$(python3 -I -c "$l18_py" sums | cut -d' ' -f1)
  l18_token=$(sed -n 's/^::stop-commands::\([0-9a-f]*\)$/\1/p' "$work/l18.out" | head -n 1)
  python3 -I -c '
import hashlib, sys
lines = open(sys.argv[1], "rb").read().split(b"\n")
tok = sys.argv[2].encode()
try:
    a = lines.index(b"::stop-commands::" + tok)
    b = lines.index(b"::" + tok + b"::")
except ValueError:
    sys.exit(1)
# The launcher puts the resume token on a line of its own: one empty line
# precedes it.
if b < 1 or lines[b - 1] != b"":
    sys.exit(1)
body = b"\n".join(lines[a + 1:b - 1]) + b"\n"
sys.exit(0 if hashlib.sha256(body).hexdigest() == sys.argv[3] else 1)
' "$work/l18.out" "$l18_token" "$l18_out_sum"
  l18_body=$?
  [ "$l18_rc" -eq 0 ] && [ "$l18_body" -eq 0 ]
  result "L-18 the command's 1 MiB of stdout arrives complete through a pipe" $? "(rc $l18_rc)"
  l18_e=$(grep -ac '^e\{65535\}$' "$work/l18.err")
  [ "$l18_e" -eq 1 ]
  result "L-18 the command's 64 KiB of stderr arrives complete" $?
  [ -n "$l18_token" ] && [ "$(tail -n 1 "$work/l18.out")" = "::$l18_token::" ]
  result "L-18 the resume token is the last stdout line" $? "($(tail -n 1 "$work/l18.out" | cut -c1-40))"
  l17_err=$(grep -n '^::error::injected-by-test$' "$work/l18.out" | cut -d: -f1)
  l17_res=$(grep -n "^::$l18_token::\$" "$work/l18.out" | cut -d: -f1)
  [ -n "$l17_err" ] && [ -n "$l17_res" ] && [ "$l17_err" -lt "$l17_res" ]
  result "L-17 the command's last workflow command comes before the resume token (ignored)" $? \
    "(line ${l17_err:-?}, resume ${l17_res:-?})"

  # --- L-14 (with L-11) a normal launch, its stdout a regular file; while
  # it runs, the profile is listed and root reads the command's pending
  # exec label.
  g=$(new_work) || exit 2
  l14_before_ctl=$(ctl_dirs)
  count_launch
  "$nd" --work "$g" /bin/sh -c 'echo "$NO_DOCKER_PROFILE" >"$1/name"; i=0
while [ ! -e "$1/go" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done; echo l14-out' "l14-$nonce" "$g" \
    >"$work/l14.out" 2>"$work/l14.err" &
  l14pid=$!
  for _ in $(seq 1 300); do [ -s "$g/name" ] && break; sleep 0.1; done
  l14_name=$(cat "$g/name" 2>/dev/null)
  l14_list=$(profiles 2>/dev/null | grep -c "^$l14_name (enforce)\$")
  l14_cmd=""
  for p in $(pgrep -f -- "l14-$nonce"); do
    if [ "$(sudo -n cat "/proc/$p/attr/apparmor/current" 2>/dev/null)" = "$l14_name (enforce)" ]; then l14_cmd=$p; fi
  done
  l14_exec="" l14_exec_rc=1
  if [ -n "$l14_cmd" ]; then
    l14_exec=$(sudo -n cat "/proc/$l14_cmd/attr/apparmor/exec" 2>&1)
    l14_exec_rc=$?
  fi
  : >"$g/go"
  wait_bounded "$l14pid" 150
  l14_rc=$?
  echo "INFO  L-11 root's view of the command's attr/apparmor/exec: ${l14_exec:-unread}"
  grep -q '^no-docker-aa: info parser ' "$work/l14.err" && grep -q '^no-docker-aa: info features ' "$work/l14.err"
  result "L-11 the preflight recorded the parser and the kernel's network features" $?
  grep -q '^no-docker-aa: info apparmor_restrict_unprivileged_unconfined ' "$work/l14.err" &&
    grep -q '^no-docker-aa: info core_pattern ' "$work/l14.err"
  result "L-11 the preflight recorded the AppArmor sysctl values and core_pattern" $?
  grep -qi '^no-docker-aa: info sudo[ ].*environment' "$work/l14.err" && grep -qi '^no-docker-aa: info sudo[ ].*descriptors' "$work/l14.err"
  result "L-11 the preflight recorded sudo's env_reset and closefrom" $?
  [ "$l14_list" = 1 ]
  result "L-11 while the command runs its profile is listed as exactly \"NAME (enforce)\"" $? "(${l14_name:-?}: $l14_list)"
  grep -q '^no-docker: info the gate passed in ' "$work/l14.err"
  result "L-11 the gate passed" $?
  # Information only (design 7.3): the kernel answers attr/apparmor/exec
  # from the reader's own context, so its content or error is recorded.
  [ -n "$l14_cmd" ]
  result "L-11 root's view of the command's exec label is recorded (information)" $? "(rc $l14_exec_rc)"
  [ "$l14_rc" -eq 0 ] && [ "$(grep -cx l14-out "$work/l14.out")" -eq 1 ] && [ "$(listed "$l14_name")" = 0 ]
  result "L-14 the command ran and its profile was removed" $? "(rc $l14_rc)"
  [ "$(ctl_dirs)" = "$l14_before_ctl" ] && [ -z "$(find "$RUNNER_TEMP" -maxdepth 1 -name 'no-docker-fence.*')" ]
  result "L-14 no control or fence directory is left" $?
  ! pgrep -f -- 'no-docker-fence\.' >/dev/null
  result "L-14 no fence listener is left" $?
  grep -qE '^no-docker: info descriptors of no-docker.sh before the start: 0 1 2( [0-9]+)+; relays: stdout pid [0-9]+ on fd [0-9]+, stderr pid [0-9]+ on fd [0-9]+, both children of [0-9]+$' "$work/l14.err"
  result "L-14 the launcher's descriptors and the relays' pids, fds and parent are logged" $? \
    "($(grep '^no-docker: info descriptors' "$work/l14.err" | cut -c1-120))"
  l14_relays=$(sed -n 's/^no-docker: info the relays ended \([0-9]*\)\.\([0-9]*\)s after the command$/\1\2/p' "$work/l14.err")
  [ -n "$l14_relays" ] && [ "$l14_relays" -le 100 ]
  result "L-14 the relays ended within 1 s of the command" $? "(${l14_relays:-?} hundredths)"
  ! grep -qE '^no-docker: (refused|.*still loaded|the control directory .* is kept)|^no-docker-aa: (killed pid 1|pid 1 of the launch not found|refused)' "$work/l14.err"
  result "L-14 no cleanup message and no kill-init in the log of a normal end" $?

  # --- L-07 the caller's stdout a socket or a terminal: refused before
  # anything is made. Controls: a pipe (L-18) and a file (L-14).
  for kind in socketpair pty; do
    c0=$(ctl_dirs)
    p0=$(listed flowcrm-nd-)
    python3 -I -c '
import os, pty, socket, sys
if sys.argv[1] == "socketpair":
    a, b = socket.socketpair()
    os.dup2(a.fileno(), 1, inheritable=True)
else:
    m, s = pty.openpty()
    os.dup2(s, 1, inheritable=True)
os.execv(sys.argv[2], [sys.argv[2], "/usr/bin/true"])
' "$kind" "$nd" 2>"$work/l07-$kind.err"
    r=$?
    [ "$r" -eq 125 ] && grep -q "the caller's fd 1 is a socket or a terminal" "$work/l07-$kind.err" &&
      [ "$(ctl_dirs)" = "$c0" ] && [ "$(listed flowcrm-nd-)" = "$p0" ]
    result "L-07 the caller's stdout a $kind: refused (125) before anything was made" $? "(rc $r)"
  done
  [ "$l18_rc" -eq 0 ]
  result "L-07 control: the caller's stdout a pipe runs (L-18)" $?
  [ "$l14_rc" -eq 0 ]
  result "L-07 control: the caller's stdout a regular file runs (L-14)" $?

  # --- L-08 the gate run directly, outside, with an extra fd 5 and fd 1 a
  # socket: every step is evaluated, its report names both and the label,
  # and the command does not run. The G1 findings outside are expected.
  l08_py='
import os, socket, sys
a, b = socket.socketpair()
if sys.argv[1] == "dirty":
    fd = os.open("/etc/hostname", os.O_RDONLY)
    if fd != 5:
        os.dup2(fd, 5)
    os.set_inheritable(5, True)
    os.dup2(a.fileno(), 1, inheritable=True)
os.execv("/usr/bin/python3", ["/usr/bin/python3", "-I", sys.argv[2], "--gate-exec", "--", "/usr/bin/touch", sys.argv[3]])
'
  python3 -I -c "$l08_py" dirty "$root/scripts/ci/no-docker-probe.py" "$work/l08.marker" </dev/null 2>"$work/l08.err"
  r=$?
  [ "$r" -eq 125 ] && [ ! -e "$work/l08.marker" ]
  result "L-08 the gate run with a stray descriptor refuses (125); the command did not run" $? "(rc $r)"
  grep -q '^no-docker: FAIL no other descriptor is open (.*5: file' "$work/l08.err" &&
    grep -q '^no-docker: FAIL fd 0 is /dev/null and fds 1 and 2 are pipes (.*1: unix socket' "$work/l08.err"
  result "L-08 the gate's report names fd 5 and the socket on fd 1" $?
  grep -q '^no-docker: FAIL this process is confined by exactly ' "$work/l08.err"
  result "L-08 the gate's report names the missing confinement" $?
  { python3 -I -c "$l08_py" clean "$root/scripts/ci/no-docker-probe.py" "$work/l08.marker" </dev/null 2>&1; } |
    cat >"$work/l08c.err"
  grep -q '^no-docker: ok   fd 0 is /dev/null and fds 1 and 2 are pipes' "$work/l08c.err" &&
    grep -q '^no-docker: ok   no other descriptor is open$' "$work/l08c.err" && [ ! -e "$work/l08.marker" ]
  result "L-08 control: clean descriptors give no descriptor finding" $?

  # --- L-09 --root-exec run directly as this user with fds 5 and 6.
  l09_py='
import os, sys
for n in map(int, sys.argv[3:]):
    fd = os.open("/etc/hostname", os.O_RDONLY)
    if fd != n:
        os.dup2(fd, n)
        os.close(fd)
    os.set_inheritable(n, True)
os.execv("/usr/bin/python3", ["/usr/bin/python3", "-I", sys.argv[1], "--root-exec", str(os.getuid()), str(os.getgid()),
         "flowcrm-nd-" + "0" * 32, "--", "PATH=/usr/bin:/bin", "--", "/usr/bin/touch", sys.argv[2]])
'
  python3 -I -c "$l09_py" "$root/scripts/ci/no-docker-probe.py" "$work/l09.marker" 5 6 </dev/null >/dev/null 2>"$work/l09.err"
  r=$?
  grep -q '^no-docker: closed: 5 6; remaining: 0 1 2; stdin char 1:3$' "$work/l09.err"
  result "L-09 --root-exec closed the inherited fds 5 and 6 and made stdin /dev/null" $? "($(grep closed: "$work/l09.err"))"
  [ "$r" -ne 0 ] && [ ! -e "$work/l09.marker" ] && grep -q '^setpriv: ' "$work/l09.err"
  result "L-09 then setpriv failed without privileges; the command did not run" $? "(rc $r)"
  python3 -I -c "$l09_py" "$root/scripts/ci/no-docker-probe.py" "$work/l09.marker" </dev/null >/dev/null 2>"$work/l09b.err"
  grep -q '^no-docker: closed: (none); remaining: 0 1 2; stdin char 1:3$' "$work/l09b.err"
  result "L-09 control: without them nothing is closed" $?

  # --- L-10 a host process that would pass a descriptor (SCM_RIGHTS).
  mkdir -m 700 "$ro/l10" || exit 2
  printf 'l10 secret\n' >"$ro/l10/secret"
  lsock scm "$ro/l10/s" "$work/l10.ready" "$ro/l10/secret"
  python3 -I "$ro/lclient.py" scm "$ro/l10/s" >"$work/l10.out" 2>&1
  ndl python3 -I "$ro/lclient.py" scm "$ro/l10/s" fds - >"$work/l10.in" 2>"$work/l10.err"
  [ "$(res "$work/l10.in" scm "$ro/l10/s")" = EACCES ]
  result "L-10 inside: the connect to the descriptor-passing socket is refused with EACCES" $? "($(res "$work/l10.in" scm "$ro/l10/s"))"
  [ "$(res "$work/l10.out" scm "$ro/l10/s")" = "OK fds=1" ] && [ "$(res "$work/l10.in" scm "$ro/l10/s")" != "OK fds=1" ]
  result "L-10 no descriptor reached the command (outside, a client receives one)" $?
  [ "$(res "$work/l10.in" fds -)" = "0 1 2" ]
  result "L-10 the command's descriptors are 0, 1 and 2" $? "($(res "$work/l10.in" fds -))"
  lstop "$work/l10.ready"

  # --- L-12 the negative control: a profile that does not deny host
  # sockets must make the gate refuse; only /usr/bin/true may run.
  ndl --negative-control /usr/bin/touch "$work/l12.marker" >"$work/l12.out" 2>"$work/l12.err"
  r=$?
  [ "$r" -eq 125 ]
  result "L-12 the negative control exits 125" $? "(rc $r)"
  grep -q '^no-docker: FAIL connect to the stream fence is refused with EACCES (ok)$' "$work/l12.err" &&
    grep -q '^no-docker: FAIL sendto to the dgram fence is refused with EACCES (ok)$' "$work/l12.err" &&
    grep -q '^no-docker: ok   connect to the stream fence is refused with EACCES (EACCES)$' "$work/l14.err"
  result "L-12 the gate reports the fence reachable (stream and datagram); L-14's normal launch found it refused" $?
  [ ! -e "$work/l12.marker" ] && ! grep -q 'no-docker: info the gate passed' "$work/l12.err"
  result "L-12 only /usr/bin/true could have run (the given command did not)" $?
  [ "$(listed flowcrm-nd-neg-)" = 0 ] && grep -q '^no-docker-aa: released flowcrm-nd-neg-' "$work/l12.err"
  result "L-12 the negative-control profile was released" $?

  # --- L-13 the helper keeps a profile a process outside still carries.
  l13n=flowcrm-nd-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  l13c=$(mktemp -d "$RUNNER_TEMP/no-docker-ctl.XXXXXX") || exit 2
  printf 'loading\n' >"$l13c/state"
  printf '%s %s\n' "$l13n" "$l13c" >>"$work/l-release"
  sudo -n timeout 20 /usr/bin/python3 -I "$root/scripts/ci/no-docker-aa.py" load "$l13n" "$l13c" 2>"$work/l13.err"
  aa-exec -p "$l13n" -- sleep 120 &
  l13carrier=$!
  printf '%s\n' "$l13carrier" >>"$work/l-carriers"
  sleep 0.5
  sudo -n timeout 30 /usr/bin/python3 -I "$root/scripts/ci/no-docker-aa.py" release "$l13n" "$l13c" 2>>"$work/l13.err"
  r=$?
  [ "$r" -ne 0 ] && grep -q 'tasks carrying the profile' "$work/l13.err"
  result "L-13 release is refused while a process outside carries the profile" $? "(rc $r)"
  [ "$(listed "$l13n (enforce)")" = 1 ]
  result "L-13 the profile is still loaded after the refusal" $?
  kill "$l13carrier" 2>/dev/null
  wait "$l13carrier" 2>/dev/null
  sudo -n timeout 30 /usr/bin/python3 -I "$root/scripts/ci/no-docker-aa.py" release "$l13n" "$l13c" 2>>"$work/l13.err"
  r=$?
  [ "$r" -eq 0 ] && [ "$(listed "$l13n")" = 0 ]
  result "L-13 once the carrier ended the release removes it" $? "(rc $r)"
  rm -rf "$l13c"

  # --- L-13b the launcher's own release refused: 125, the control
  # directory kept, the profile releasable afterwards.
  g=$(new_work) || exit 2
  count_launch
  "$nd" --work "$g" /bin/sh -c 'echo "$NO_DOCKER_PROFILE" >"$1/name"; i=0
while [ ! -e "$1/go" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done' l13b "$g" >"$work/l13b.out" 2>"$work/l13b.err" &
  l13bpid=$!
  for _ in $(seq 1 300); do [ -s "$g/name" ] && break; sleep 0.1; done
  l13b_name=$(cat "$g/name" 2>/dev/null)
  case $l13b_name in flowcrm-nd-????????????????????????????????) aa-exec -p "$l13b_name" -- sleep 120 & ;; *) sleep 120 & ;; esac
  l13bcarrier=$!
  printf '%s\n' "$l13bcarrier" >>"$work/l-carriers"
  sleep 0.5
  : >"$g/go"
  wait_bounded "$l13bpid" 150
  r=$?
  l13b_line=$(grep -m1 '^no-docker: refused: profile .* still loaded' "$work/l13b.err")
  l13b_ctl=${l13b_line##*control directory }
  l13b_ctl=${l13b_ctl%% is kept}
  [ "$r" -eq 125 ] && [ -n "$l13b_line" ]
  result "L-13b with a carrier outside the launch ends 125 and says the profile is still loaded" $? "(rc $r)"
  [ -d "$l13b_ctl" ] && [ -e "$l13b_ctl/ns" ]
  result "L-13b its control directory is kept" $? "(${l13b_ctl:-none})"
  kill "$l13bcarrier" 2>/dev/null
  wait "$l13bcarrier" 2>/dev/null
  left_loaded "$work/l13b.err" && [ "$(listed "$l13b_name")" = 0 ]
  result "L-13b without the carrier the profile is released with that control directory" $?

  # --- L-13c two launches at once: each releases only its own profile.
  l13c_tmp=$(find /tmp -maxdepth 1 -name 'no-docker.*' 2>/dev/null | wc -l | tr -d ' ')
  count_launch
  "$nd" /bin/sh -c 'sleep 2; echo l13c-a' >"$work/l13c-a.out" 2>"$work/l13c-a.err" &
  l13ca=$!
  count_launch
  "$nd" /bin/sh -c 'sleep 2; echo l13c-b' >"$work/l13c-b.out" 2>"$work/l13c-b.err" &
  l13cb=$!
  wait_bounded "$l13ca" 150
  ra=$?
  wait_bounded "$l13cb" 150
  rb=$?
  na=$(sed -n 's/^no-docker-aa: released \(flowcrm-nd-[0-9a-f]*\) .*/\1/p' "$work/l13c-a.err")
  nb=$(sed -n 's/^no-docker-aa: released \(flowcrm-nd-[0-9a-f]*\) .*/\1/p' "$work/l13c-b.err")
  [ "$ra" -eq 0 ] && [ "$rb" -eq 0 ] && grep -qx l13c-a "$work/l13c-a.out" && grep -qx l13c-b "$work/l13c-b.out"
  result "L-13c two concurrent launches both run" $? "(rc $ra, $rb)"
  [ -n "$na" ] && [ -n "$nb" ] && [ "$na" != "$nb" ] && [ "$(grep -c '^no-docker-aa: released' "$work/l13c-a.err")" = 1 ] &&
    [ "$(grep -c '^no-docker-aa: released' "$work/l13c-b.err")" = 1 ]
  result "L-13c each released its own profile, once" $?
  [ "$(listed flowcrm-nd-)" = "$nd_listed_before" ] && [ "$(ctl_dirs)" = 0 ] &&
    [ "$(find /tmp -maxdepth 1 -name 'no-docker.*' 2>/dev/null | wc -l | tr -d ' ')" = "$l13c_tmp" ]
  result "L-13c no profile, control directory or run directory of theirs is left" $?

  # --- L-15 TERM to no-docker.sh (not a runner cancellation, RR-01): 143,
  # pid 1 killed, the profile released only after P1, nothing left.
  g=$(new_work) || exit 2
  count_launch
  "$nd" --work "$g" /bin/sh -c 'sleep 120' "l15-$nonce" >"$work/l15.out" 2>"$work/l15.err" &
  l15pid=$!
  for _ in $(seq 1 300); do [ -e "$g/started" ] && break; sleep 0.1; done
  kill -TERM "$l15pid"
  wait_bounded "$l15pid" 150
  r=$?
  [ "$r" -eq 143 ]
  result "L-15 TERM: no-docker.sh exits 143 within 150 s" $? "(rc $r)"
  grep -q '^no-docker-aa: killed pid 1 of the launch' "$work/l15.err"
  result "L-15 pid 1 of the namespace was killed (kill-init)" $?
  grep -q '^no-docker-aa: released flowcrm-nd-[0-9a-f]* (namespace, state entered)$' "$work/l15.err"
  result "L-15 the profile was released after P0 and P1" $?
  ! pgrep -f -- "l15-$nonce" >/dev/null
  result "L-15 no process of the launch is left" $?

  # --- L-15b unshare killed by this suite while the command forks and
  # tries a host socket: released only after P1, or left loaded (125); the
  # host socket never accepted a connection.
  mkdir -m 700 "$ro/l15b" || exit 2
  lsock stream "$ro/l15b/s" "$work/l15b.ready"
  g=$(new_work) || exit 2
  count_launch
  "$nd" --work "$g" /bin/sh -c 'while :; do python3 -I "$1" stream "$2" >/dev/null 2>&1 & sleep 0.05; done' \
    "l15b-$nonce" "$ro/lclient.py" "$ro/l15b/s" >"$work/l15b.out" 2>"$work/l15b.err" &
  l15bpid=$!
  for _ in $(seq 1 300); do [ -e "$g/started" ] && break; sleep 0.1; done
  sleep 1
  l15b_unshare=""
  for p in $(pgrep -x unshare); do
    q=$p
    for _ in 1 2 3 4 5 6; do
      q=$(awk '{print $4}' "/proc/$q/stat" 2>/dev/null) || break
      [ "$q" = "$l15bpid" ] && l15b_unshare=$p && break
    done
  done
  [ -z "$l15b_unshare" ] || sudo -n kill -KILL "$l15b_unshare"
  wait_bounded "$l15bpid" 150
  r=$?
  if [ "$r" -eq 125 ]; then
    left_loaded "$work/l15b.err"
    l15b_ok=$?
  else
    grep -q '^no-docker-aa: released flowcrm-nd-[0-9a-f]* (namespace, state entered)$' "$work/l15b.err"
    l15b_ok=$?
  fi
  [ -n "$l15b_unshare" ] && [ "$l15b_ok" -eq 0 ] && { [ "$r" -eq 125 ] || [ "$r" -eq 137 ]; }
  result "L-15b unshare killed: released after P1, or left loaded (125) and released afterwards" $? \
    "(rc $r, unshare ${l15b_unshare:-not found})"
  ! grep -q '^no-docker-aa: released .*(no-namespace, state entere' "$work/l15b.err"
  result "L-15b never released as if no namespace had been made" $?
  [ "$(cat "$work/l15b.ready.count" 2>/dev/null || echo 0)" -eq 0 ]
  result "L-15b the host socket never accepted a connection from inside" $?
  lstop "$work/l15b.ready"

  # --- L-15c TERM early in the launch, at six moments. Each launch ends in
  # one of: 143 with nothing made or loaded; 143 released (after P1, or as
  # loading/not-forked without a namespace); 125 left loaded, released
  # afterwards once its processes are gone. Never released in "entering" or
  # "entered" without P1.
  for ms in 0 20 50 100 200 300; do
    count_launch
    "$nd" /usr/bin/true >"$work/l15c-$ms.out" 2>"$work/l15c-$ms.err" &
    l15cpid=$!
    sleep "$(printf '0.%03d' "$ms")"
    kill -TERM "$l15cpid" 2>/dev/null
    wait_bounded "$l15cpid" 150
    r=$?
    l15c_ok=no
    if [ "$r" -eq 143 ] && ! grep -q 'still loaded' "$work/l15c-$ms.err"; then
      l15c_ok=yes
    elif [ "$r" -eq 125 ] && left_loaded "$work/l15c-$ms.err"; then
      l15c_ok=yes
    fi
    grep -q '^no-docker-aa: released .*(no-namespace, state entere' "$work/l15c-$ms.err" && l15c_ok=no
    if [ "$ms" = 300 ]; then
      [ "$(listed flowcrm-nd-)" = "$nd_listed_before" ] || l15c_ok=no
    fi
    [ "$l15c_ok" = yes ]
    result "L-15c TERM at ${ms} ms: an allowed outcome$([ "$ms" = 300 ] && echo '; no profile of these launches is left')" $? \
      "(rc $r)"
  done
else
  echo "INFO  T-16, T-17, T-18 skipped: Linux (GitHub-hosted runner) only"
  for c in L-01 L-02 L-03 L-04 L-05 L-06 L-07 L-08 L-09 L-10 L-11 L-12 L-13 L-13b L-13c L-14 L-15 L-15b L-15c L-17 L-18; do
    echo "SKIP  $c (Linux CI only)"
  done
  # --- T-18 (macOS) the negative control is refused off Linux.
  err=$("$nd" --negative-control /usr/bin/true 2>&1 >/dev/null)
  r=$?
  [ "$r" -eq 125 ] && printf '%s' "$err" | grep -q -- "--negative-control is for Linux on GitHub-hosted runners only"
  result "T-18 --negative-control on macOS: refused" $? "(rc $r)"
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

# --- T-36 the Linux rules of no-docker-probe.py as pure functions, on both
# platforms: fixtures only (every call that would read /proc, open, close or
# duplicate a descriptor, open a socket, run or exec a program, fork or set
# a signal raises), the gate's label, descriptor and fence rules and
# --root-exec's sanitation (C11 to C14), the probe's functions called by
# what runs (W) and mutated copies of the probe rejected (M1 to M21). The
# numbers of assertions are fixed here: a case that loses one fails.
# On 85cfb37: the NSpid rule accepted only a /proc of an ancestor namespace
# (M1).
t36=$(python3 -I -B "$here/no-docker-probe-unit.py" "$root/scripts/ci/no-docker-probe.py" 2>&1)
t36_rc=$?
printf '%s\n' "$t36" | grep -vE '^ok   ' | sed 's/^/INFO    /'
for want in C01=2 C02=13 C03=12 C04=14 C05=9 C06=15 C07=7 C10=8 C11=7 C12=9 C13=9 C14=4 W=12 M=14; do
  tag=${want%=*}
  n=$(printf '%s\n' "$t36" | grep -cE "^ok   ${tag}[0-9]* ")
  bad=$(printf '%s\n' "$t36" | grep -cE "^FAIL ${tag}[0-9]* ")
  [ "$t36_rc" -eq 0 ] && [ "$n" -eq "${want#*=}" ] && [ "$bad" -eq 0 ] &&
    printf '%s\n' "$t36" | grep -qx 'SUMMARY 135 ok, 0 failed'
  result "T-36 $tag: $n of ${want#*=} assertions pass" $? "(rc $t36_rc, $bad failed)"
done

# --- T-39 the static rules of the Linux isolation (no-docker-static.py), on
# both platforms: each rule passes on the tracked files and fails on its
# mutant fixture; the AppArmor templates are the reviewed rule set. The
# numbers of checks are fixed here: a rule that loses one fails.
t39=$(python3 -I -B "$here/no-docker-static.py" "$root" 2>&1)
t39_rc=$?
printf '%s\n' "$t39" | grep -vE '^ok   ' | sed 's/^/INFO    /'
for want in S-02=2 S-02b=2 S-03=2 S-03b=2 S-04=2 S-05=4 S-06=2 S-07=2 S-08=2 S-09=2; do
  tag=${want%=*}
  n=$(printf '%s\n' "$t39" | grep -cE "^ok   ${tag} ")
  bad=$(printf '%s\n' "$t39" | grep -cE "^FAIL ${tag} ")
  [ "$t39_rc" -eq 0 ] && [ "$n" -eq "${want#*=}" ] && [ "$bad" -eq 0 ] &&
    printf '%s\n' "$t39" | grep -qx 'SUMMARY 22 ok, 0 failed'
  result "T-39 $tag: $n of ${want#*=} checks pass" $? "(rc $t39_rc, $bad failed)"
done

# --- T-40 the Linux cleanup's failure propagation, as a pure harness, on
# both platforms: the cleanup function of no-docker.sh and the functions it
# calls, taken from the script unchanged, run in a subshell in the state of
# a launch whose command exited 0, with rm, sudo and chmod replaced by shell
# functions (only this suite's own directories are removed; nothing runs as
# root; no namespace or profile exists). A failed removal of the fence, the
# control or the run directory must end 125 with a refusal naming that
# directory by its path, and leave the directories the design keeps (design
# section 10, C3, C6, C7): after a fence failure the control directory is
# kept too; after a control or run failure what was removed before stays
# removed. Without a failure the command's status stays 0 and nothing is
# left. Four mutants of the propagation must each change an outcome. The
# shell logic only: on Linux, L-14 and L-13c show at run time that nothing
# is left.
t40_src=$work/t40-cleanup.sh
awk '
  /^    (proc_stat|alive|wait_gone|wait_all|put_state|resolve_pending|sudo_may_run|close_relay_ends|secs|cleanup)\(\) \{$/ { f = 1 }
  f { print }
  f && /^    }$/ { f = 0 }
' "$nd" >"$t40_src"
# The harness, a shell of its own: $1 the functions, $2 the case's
# directory, $3 the directory whose removal fails.
t40_harness='
set -u
EX_REFUSED=125 aa=/nonexistent EPOCHREALTIME=1700000000.000000 bad=$3
ctldir=$2/ctl fencedir=$2/fence work=$2/run work_made=yes profile=flowcrm-nd-00000000000000000000000000000000
load_op=load state="entered spid=1" lpid=1 lstart=1 load_done=yes spid=1 sstart=1 sudo_reaped=yes
o="" e="" opid="" ostart="" epid="" estart="" fspid="" fsstart="" fdpid="" fdstart=""
pending="" kept="" token="" stopped="" signalled="" normal=yes cleaning="" rc=0 negative=""
t_launch=0 t_preflight=0 t_load=0 t_fence=0 t_relays=0 t_run=0 t_release=0
sudo() { :; }
chmod() { :; }
rm() {
  for last; do :; done
  [ "$last" != "$bad" ] || return 1
  command rm "$@"
}
. "$1"
cleanup
'
# t40_case SOURCE fence|ctl|run|none: "<status>:<refusals naming that
# directory by its path>:<directories left, f c r or ->".
t40_case() {
  local d r x name left=""
  d=$(mktemp -d "$work/t40.XXXXXX") || return 2
  mkdir "$d/fence" "$d/ctl" "$d/run" && : >"$d/run/started" || return 2
  "$BASH" -c "$t40_harness" t40 "$1" "$d" "$d/$2" >"$d/out" 2>"$d/err"
  r=$?
  case $2 in fence) name=fence ;; ctl) name=control ;; *) name=run ;; esac
  for x in fence ctl run; do
    if [ -e "$d/$x" ]; then left=$left$(printf %.1s "$x"); else left=$left-; fi
  done
  echo "$r:$(grep -cxF "no-docker: refused: cleanup failed (the $name directory $d/$2 could not be removed)" "$d/err"):$left"
}
t40_all() { # SOURCE: the outcomes of the four cases, space-separated
  echo "none=$(t40_case "$1" none) fence=$(t40_case "$1" fence) ctl=$(t40_case "$1" ctl) run=$(t40_case "$1" run)"
}
t40_want="none=0:0:--- fence=125:1:fc- ctl=125:1:-c- run=125:1:--r"
t40_got=$(t40_all "$t40_src")
[ "$(grep -c '() {$' "$t40_src")" -eq 10 ] && [ "$t40_got" = "$t40_want" ]
result "T-40 cleanup against stubs: a failed removal of the fence, control or run directory ends 125 naming it and keeps what the design keeps; otherwise status 0, nothing left" $? \
  "($t40_got; $(grep -c '() {$' "$t40_src") of 10 functions)"
# The mutants: the fence removal unchecked; the failure cleared before the
# status; the status not raised by a cleanup failure; the fence failure
# naming another directory.
awk '/^      if \[ -n "\$fencedir" \] && ! rm -rf "\$fencedir"; then$/ { print "      [ -z \"$fencedir\" ] || rm -rf \"$fencedir\""; skip = 2; next }
  skip > 0 { skip--; next } { print }' "$t40_src" >"$work/t40-m1.sh"
awk '/^      # C7: the status\./ { print "      fail=\"\"" } { print }' "$t40_src" >"$work/t40-m2.sh"
awk '/^      # C7: the status\./ { c7 = 1 } c7 && /^        status=\$EX_REFUSED$/ && !done { print "        status=$rc"; done = 1; next } { print }' \
  "$t40_src" >"$work/t40-m3.sh"
awk '/the fence directory \$fencedir could not be removed/ { sub(/\$fencedir could/, "$ctldir could") } { print }' \
  "$t40_src" >"$work/t40-m4.sh"
t40_caught=""
for m in 1 2 3 4; do
  if ! cmp -s "$t40_src" "$work/t40-m$m.sh" && [ "$(t40_all "$work/t40-m$m.sh")" != "$t40_want" ]; then
    t40_caught="$t40_caught M$m"
  fi
done
[ "$t40_caught" = " M1 M2 M3 M4" ]
result "T-40 mutants of the propagation are caught (fence removal unchecked, failure cleared, status not raised, another directory named)" $? \
  "(caught:${t40_caught:- none})"

# --- T-41 L-16's projection is compared with 540 s exactly (pure, both
# platforms): l16_project, which L-16 uses, sums the launch timings (two
# decimals, as the launch notices print them) in integer hundredths, so a
# projection of 540.04 s is over the limit although it would print as 540.
# Cases: exactly 540 s passes (N = 40, ten launches of 8.90 s); 540.004 s
# fails (N = 4, nine of 89.00 s and one of 89.01 s); 540.04 s fails (N = 45,
# nine of 7.91 s and one of 7.93 s); 539.95 s passes (N = 45, ten of 7.91 s);
# a malformed timing is refused. The printed c and projection are rounded
# up.
# l16_project N TIMING...: "<c in s, 3 decimals, rounded up> <projection in
# whole s, rounded up> <ok|over>", or "- - bad"; the projection is 184 s
# plus N times c, c the mean of the timings.
l16_project() {
  local n=$1 k=0 s=0 t c p
  shift
  for t in "$@"; do
    case $t in
      "" | *[!0-9.]* | *.*.*) echo "- - bad"; return 1 ;;
      [0-9]*.[0-9][0-9]) s=$((s + 10#${t%.*} * 100 + 10#${t#*.})) k=$((k + 1)) ;;
      *) echo "- - bad"; return 1 ;;
    esac
  done
  case $n in "" | *[!0-9]*) echo "- - bad"; return 1 ;; esac
  [ "$k" -gt 0 ] || { echo "- - bad"; return 1; }
  # c = s / (100 k) s; 100 k times the projection = 18400 k + n s.
  c=$(((10 * s + k - 1) / k))
  p=$(((18400 * k + n * s + 100 * k - 1) / (100 * k)))
  if [ $((18400 * k + n * s)) -le $((54000 * k)) ]; then t=ok; else t=over; fi
  printf '%d.%03d %d %s\n' $((c / 1000)) $((c % 1000)) "$p" "$t"
}
t41_got="$(l16_project 40 8.90 8.90 8.90 8.90 8.90 8.90 8.90 8.90 8.90 8.90)|$(l16_project 4 89.00 89.00 89.00 89.00 89.00 89.00 89.00 89.00 89.00 89.01)|$(l16_project 45 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.93)|$(l16_project 45 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.91 7.91)|$(l16_project 45 7.9 8.00)"
[ "$t41_got" = "8.900 540 ok|89.001 541 over|7.912 541 over|7.910 540 ok|- - bad" ] &&
  grep -q '^  l16=$(l16_project "$l16_launches" $l16_t)$' "$here/no-docker.test.sh"
result "T-41 L-16's projection is compared with 540 s exactly: 540 s passes, 540.004 s and 540.04 s fail, 539.95 s passes" $? \
  "($t41_got)"

# --- T-38 the AppArmor lifecycle helper no-docker-aa.py as pure functions, on
# both platforms: fixtures only (every call that would open, list or write a
# file, read a link, run a program, open a pidfd or send a signal raises),
# its operations against a fake system (P-01 to P-11), the helper's
# functions called by what runs (W) and mutated copies of the helper
# rejected (M1 to M19). The numbers of assertions are fixed here.
t38=$(python3 -I -B "$here/no-docker-aa-unit.py" "$root/scripts/ci/no-docker-aa.py" 2>&1)
t38_rc=$?
printf '%s\n' "$t38" | grep -vE '^ok   ' | sed 's/^/INFO    /'
for want in P-01=8 P-02=7 P-03=13 P-04=7 P-05=10 P-06=15 P-07=6 P-08=4 P-09=6 P-10=4 P-11=6 W=9 M=19; do
  tag=${want%=*}
  n=$(printf '%s\n' "$t38" | grep -cE "^ok   ${tag}[0-9]* ")
  bad=$(printf '%s\n' "$t38" | grep -cE "^FAIL ${tag}[0-9]* ")
  [ "$t38_rc" -eq 0 ] && [ "$n" -eq "${want#*=}" ] && [ "$bad" -eq 0 ] &&
    printf '%s\n' "$t38" | grep -qx 'SUMMARY 114 ok, 0 failed'
  result "T-38 $tag: $n of ${want#*=} assertions pass" $? "(rc $t38_rc, $bad failed)"
done

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
    # The harness runs on the host and runs the mutant in its own sandbox.
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

# --- L-16 the cost of a launch, measured last of all the cases that launch
# (after T-03 to T-05), so the count of launches is complete: 10 launches
# of true; c, the mean of their timing notices; the guard job projected as
# 184 s (its work besides launches, measured) + N * c, N = the 4 launches
# of the guard suites + this suite's. Above 540 s fails, compared exactly
# (l16_project, T-41; c and the projection are printed rounded up); above
# 360 s (the 6-minute target) is a warning only.
if [ "$os" = Linux ]; then
  : >"$work/l16.err"
  l16_bad=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ndl /usr/bin/true >/dev/null 2>>"$work/l16.err" || l16_bad=$((l16_bad + 1))
  done
  l16_t=$(sed -n 's/^::notice title=no-docker::launch \([0-9]*\.[0-9]*\)s: .*/\1/p' "$work/l16.err")
  l16_n=$(printf '%s\n' "$l16_t" | grep -c .)
  [ "$l16_bad" -eq 0 ] && [ "$l16_n" -eq 10 ]
  result "L-16 10 launches ran and timed themselves" $? "($l16_bad failed, $l16_n timings)"
  l16_launches=$(($(wc -c <"$work/launch-count") + 4))
  # shellcheck disable=SC2086 # one word per timing
  l16=$(l16_project "$l16_launches" $l16_t)
  read -r l16_c l16_proj l16_verdict <<<"$l16"
  echo "INFO  L-16 c = ${l16_c:-?} s per launch, N = $l16_launches launches, projected guard job ${l16_proj:-?} s"
  [ "$l16_verdict" = ok ]
  result "L-16 the projected guard job is at most 540 s" $? "(${l16_proj:-?} s rounded up, $l16_verdict)"
  case $l16_proj in
    "" | *[!0-9]*) ;;
    *) [ "$l16_proj" -le 360 ] || echo "::warning title=no-docker::the projected guard job ($l16_proj s) is above the 6-minute target" ;;
  esac
  [ "$(listed flowcrm-nd-)" = "$nd_listed_before" ]
  result "L-16 no profile is left" $?
else
  echo "SKIP  L-16 (Linux CI only)"
fi

echo
for s in "${shown[@]}"; do
  read -r f log out <<<"$s"
  printf 'INFO  %s cases:\n' "$f"
  ! regular "$log" || sed 's/^/INFO    /' <"$log" 2>/dev/null
  printf 'INFO  %s harness output (last lines):\n' "$f"
  tail -n 8 "$out" 2>/dev/null | sed 's/^/INFO    /'
done
# The L-tests print a fixed number of result lines: one lost or added is a
# failure of the suite, not a count to adjust.
if [ "$os" = Linux ] && [ "$lcount" -ne 97 ]; then
  echo "HARNESS ERROR: $lcount L-test result lines, not 97"
  fail=$((fail + 1))
fi
echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
