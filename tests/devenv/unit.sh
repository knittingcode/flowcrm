#!/usr/bin/env bash
#
# Unit tests for bin/devenv logic that needs no Docker: configuration
# validation, candidate order, runtime-state parsing and writing, failure
# classification, project naming, the per-checkout lock (including real
# processes in other locales and time zones and an orphaned recorded child)
# and a self-check of the result tally.
#
# Usage: tests/devenv/unit.sh

# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
# Globals assigned here are read by the sourced bin/devenv functions.
# shellcheck disable=SC2319
# "<condition>; result NAME $?" records the status of that condition on purpose.
# shellcheck disable=SC2016
# Single-quoted $(...) strings are injection attempts that must stay literal.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
# DEVENV=<path> runs the suite against another copy (mutation checks).
devenv_script=${DEVENV:-"$here/../../bin/devenv"}
# shellcheck source=../../bin/devenv
. "$devenv_script"
init_paths
# shellcheck source=tally.sh
. "$here/tally.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/devenv-unit.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
tally_init "$work/tally"
# Background processes started here; killed on exit.
bg_pids=''
trap 'for p in $bg_pids; do kill -KILL "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$work"' EXIT

result() { # name ok(0|1) [detail]
  if [ "$2" -eq 0 ]; then pass_result "$1"; else fail_result "$1${3:+ $3}"; fi
}

expect_eq() { # name expected actual
  if [ "$2" = "$3" ]; then result "$1" 0; else result "$1" 1 "(expected [$2], got [$3])"; fi
}

# Run load_config in a subshell with the given environment; print its exit code.
config_rc() {
  (
    unset FLOWCRM_PORT_RANGE FLOWCRM_PORT_DEFAULT FLOWCRM_HTTP_PORT FLOWCRM_UP_TIMEOUT FLOWCRM_WAIT_TIMEOUT FLOWCRM_LOCK_WAIT
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    load_config
  ) >/dev/null 2>&1
  echo $?
}

# --- U-01 port validation (PA-17)
for p in 1024 8080 65535; do
  if valid_port "$p"; then result "U-01 valid port $p" 0; else result "U-01 valid port $p" 1; fi
done
for p in '' 0 80 1023 65536 08080 8080x ' 8080' '8080 ' '$(id)' '1e3' '-8080' 999999; do
  if valid_port "$p"; then result "U-01 reject port $(show "$p")" 1; else result "U-01 reject port $(show "$p")" 0; fi
done

# --- U-02 configuration (PA-17, PA-18)
expect_eq "U-02 defaults accepted" 0 "$(config_rc)"
expect_eq "U-02 custom range" 0 "$(config_rc FLOWCRM_PORT_RANGE=18080-18099 FLOWCRM_PORT_DEFAULT=18085)"
expect_eq "U-02 override outside range allowed" 0 "$(config_rc FLOWCRM_HTTP_PORT=9000)"
for bad in 'FLOWCRM_PORT_RANGE=8099-8080' 'FLOWCRM_PORT_RANGE=abc' 'FLOWCRM_PORT_RANGE=80-90' \
  'FLOWCRM_PORT_RANGE=8080-70000' 'FLOWCRM_PORT_RANGE=8080' 'FLOWCRM_PORT_RANGE=08080-08099' \
  'FLOWCRM_PORT_RANGE=1024-9999' 'FLOWCRM_PORT_DEFAULT=9000' 'FLOWCRM_PORT_DEFAULT=' \
  'FLOWCRM_HTTP_PORT=70000' 'FLOWCRM_HTTP_PORT=80' 'FLOWCRM_HTTP_PORT=8080;id' \
  'FLOWCRM_HTTP_PORT=$(touch PWNED)' 'FLOWCRM_UP_TIMEOUT=0' 'FLOWCRM_WAIT_TIMEOUT=x' \
  'FLOWCRM_LOCK_WAIT=99999'; do
  expect_eq "U-02 reject $(show "$bad")" "$EX_CONFIG" "$(config_rc "$bad")"
done
[ ! -e PWNED ] && [ ! -e "$work/PWNED" ]
result "U-02 no command executed from configuration" $?

# --- U-03 candidate order (PA-01..03, PA-15, PA-18)
PORT_LO=8080 PORT_HI=8084 PORT_DEFAULT=8082 OVERRIDE=''
STATE_STATUS=absent STATE_PORT=''
build_candidates
expect_eq "U-03 default first, then range ascending" "8082 8080 8081 8083 8084" "$CANDIDATES"
STATE_STATUS=valid STATE_PORT=8084
build_candidates
expect_eq "U-03 saved port first" "8084 8082 8080 8081 8083" "$CANDIDATES"
STATE_PORT=8082
build_candidates
expect_eq "U-03 saved equal to default is deduplicated" "8082 8080 8081 8083 8084" "$CANDIDATES"
STATE_PORT=9000
build_candidates
expect_eq "U-03 saved port outside range ignored" "8082 8080 8081 8083 8084" "$CANDIDATES"
build_candidates 8083
expect_eq "U-03 own unhealthy edge port tried first" "8083 8082 8080 8081 8084" "$CANDIDATES"
build_candidates 9000
expect_eq "U-03 own edge outside range ignored" "8082 8080 8081 8083 8084" "$CANDIDATES"
OVERRIDE=9000
build_candidates
expect_eq "U-03 override is the only candidate" "9000" "$CANDIDATES"
if eligible 9000 && ! eligible 8080; then result "U-03 override decides eligibility" 0; else result "U-03 override decides eligibility" 1; fi
OVERRIDE=''
if eligible 8080 && ! eligible 9000; then result "U-03 range decides eligibility" 0; else result "U-03 range decides eligibility" 1; fi
PORT_LO=8080 PORT_HI=8099 PORT_DEFAULT=8080 STATE_STATUS=absent
build_candidates
# shellcheck disable=SC2086 # split the candidate list into words to count it
set -- $CANDIDATES
expect_eq "U-03 all 20 range ports considered" 20 "$#"

# --- U-04 runtime state parsing (PA-07, PA-19, PA-20)
RUNTIME_DIR=$work/rt
STATE_FILE=$RUNTIME_DIR/dev.env
LOCK_DIR=$RUNTIME_DIR/lock
mkdir -p "$RUNTIME_DIR"
# Fixtures are written to $work/st first: piping into state_case would run it
# in a subshell and lose its pass/fail counts.
state_case() { # name expected-status [expected-port]
  cp "$work/st" "$STATE_FILE"
  read_state
  expect_eq "U-04 $1" "$2${3:+:$3}" "$STATE_STATUS${3:+:$STATE_PORT}"
}
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" >"$work/st"; state_case "valid state" valid 8084
printf '# comment\n\nRUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084' "$PROJECT" >"$work/st"; state_case "comments, no final newline" valid 8084
printf 'RUNTIME_SCHEMA=2\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" >"$work/st"; state_case "unknown schema" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=0.0.0.0\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" >"$work/st"; state_case "non-loopback bind" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=$(id)\n' "$PROJECT" >"$work/st"; state_case "command text as port" invalid
printf 'RUNTIME_SCHEMA=1\r\nCOMPOSE_PROJECT_NAME=%s\r\nFLOWCRM_HTTP_BIND=127.0.0.1\r\nFLOWCRM_HTTP_PORT=8084\r\n' "$PROJECT" >"$work/st"; state_case "CRLF line endings" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\nPATH=/tmp\n' "$PROJECT" >"$work/st"; state_case "unknown key" invalid
printf 'garbage\n\001\002\n' >"$work/st"; state_case "garbage" invalid
printf '' >"$work/st"; state_case "empty file" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=flowcrm-000000\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' >"$work/st"; state_case "other project is foreign" foreign
head -c 5000 /dev/zero | tr '\0' 'x' >"$work/st"; state_case "oversized file" invalid
rm -f "$STATE_FILE"
read_state
expect_eq "U-04 missing file is absent" absent "$STATE_STATUS"
printf 'x\n' >"$work/target"
ln -s "$work/target" "$STATE_FILE"
read_state
expect_eq "U-04 symlinked state is invalid" invalid "$STATE_STATUS"

# --- U-05 atomic state write (PA-07, PA-13)
write_state 8091
read_state
expect_eq "U-05 written state reads back" valid:8091 "$STATE_STATUS:$STATE_PORT"
[ ! -L "$STATE_FILE" ] && [ "$(cat "$work/target")" = x ]
result "U-05 symlink replaced, its target untouched" $?
leftovers=$(find "$RUNTIME_DIR" -name '.dev.env.*' | wc -l | tr -d ' ')
expect_eq "U-05 no temporary files left" 0 "$leftovers"

# --- U-06 failure classification (PA-08, PA-12)
classify() { printf '%s\n' "$2" >"$work/err"; if is_port_conflict "$work/err"; then echo conflict; else echo other; fi; }
expect_eq "U-06 engine: port is already allocated" conflict \
  "$(classify x 'Error response from daemon: driver failed programming external connectivity on endpoint p-edge-1: Bind for 127.0.0.1:8080 failed: port is already allocated')"
expect_eq "U-06 docker-proxy: address already in use" conflict \
  "$(classify x 'Error response from daemon: failed to set up container networking: listen tcp4 127.0.0.1:8080: bind: address already in use')"
expect_eq "U-06 Docker Desktop: Ports are not available, address in use" conflict \
  "$(classify x 'Error response from daemon: Ports are not available: exposing port TCP 127.0.0.1:8080 -> 127.0.0.1:0: listen tcp 127.0.0.1:8080: bind: address already in use')"
expect_eq "U-06 Docker Desktop: Ports are not available, access forbidden, is not a conflict" other \
  "$(classify x 'Error response from daemon: Ports are not available: exposing port TCP 127.0.0.1:8080 -> 0.0.0.0:0: listen tcp 127.0.0.1:8080: bind: An attempt was made to access a socket in a way forbidden by its access permissions.')"
expect_eq "U-06 terminated docker compose described" "docker compose was terminated by signal 9" "$(compose_failure 137)"
expect_eq "U-06 failed docker compose described" "docker compose exited with status 1; its error is shown above" "$(compose_failure 1)"
expect_eq "U-06 container exited is not a conflict" other "$(classify x 'container p-edge-1 exited (3)')"
expect_eq "U-06 unhealthy is not a conflict" other "$(classify x 'container p-edge-1 is unhealthy')"
expect_eq "U-06 pull failure is not a conflict" other "$(classify x 'pull access denied for busybox, repository does not exist')"
expect_eq "U-06 daemon down is not a conflict" other "$(classify x 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock')"
expect_eq "U-06 permission denied bind is not a conflict" other "$(classify x 'listen tcp4 127.0.0.1:80: bind: permission denied')"

# --- U-07 project name (PA-04, PA-20)
if [[ $PROJECT =~ $PROJECT_RE ]]; then result "U-07 project name format ($PROJECT)" 0; else result "U-07 project name format" 1; fi
a=$(sha256_prefix /a/flowcrm)
b=$(sha256_prefix /b/flowcrm)
[ "$a" != "$b" ] && [ "$a" = "$(sha256_prefix /a/flowcrm)" ]
result "U-07 deterministic and path-dependent" $?

# --- U-08 lock (PA-11, PA-16)
LOCK_WAIT=1
lock_rc() { (acquire_lock test && release_lock) >/dev/null 2>&1; echo $?; }
owner() { # host pid pstart
  mkdir -p "$LOCK_DIR"
  printf 'token=tok\nhost=%s\npid=%s\npstart=%s\ncommand=test\n' "$1" "$2" "$3" >"$LOCK_DIR/owner"
}
# A start identity of the same kind but of another process instance: a
# reused PID (on Linux: the same PID and ticks in another boot).
other_start() {
  case $1 in
    linux:*) printf 'linux:00000000-0000-0000-0000-000000000000:%s\n' "${1##*:}" ;;
    *) printf 'lstart:Thu Jan  1 00:00:00 1970\n' ;;
  esac
}
bg_sleep() { # -> sets BG_PID (a live process for 60 seconds)
  sleep 60 &
  BG_PID=$!
  bg_pids="$bg_pids $BG_PID"
}
dead_pid() { # -> sets DEAD_PID (a process that has exited and been reaped)
  sh -c 'exit 0' &
  DEAD_PID=$!
  wait "$DEAD_PID"
}
rm -rf "$LOCK_DIR"
expect_eq "U-08 free lock acquired" 0 "$(lock_rc)"
[ ! -e "$LOCK_DIR" ]
result "U-08 released lock removed" $?

bg_sleep
sleeper=$BG_PID
owner "$(host_id)" "$sleeper" "$(proc_start "$sleeper")"
expect_eq "U-08 lock of a live process is not taken" "$EX_LOCK" "$(lock_rc)"
[ -f "$LOCK_DIR/owner" ]
result "U-08 live lock left in place" $?
owner "$(host_id)" "$sleeper" "$(other_start "$(proc_start "$sleeper")")"
expect_eq "U-08 reused PID (other start identity) is stale" 0 "$(lock_rc)"
owner "$(host_id)" "$sleeper" ""
expect_eq "U-08 live PID without a start identity is not taken" "$EX_LOCK" "$(lock_rc)"
owner "$(host_id)" "$sleeper" "Wed Oct 21 14:26:30 2026"
expect_eq "U-08 live PID with an unrecognised (legacy) start record is not taken" "$EX_LOCK" "$(lock_rc)"
owner "$(host_id)" "12x" "x"
expect_eq "U-08 malformed owner PID is not taken" "$EX_LOCK" "$(lock_rc)"
dead_pid
dead=$DEAD_PID
owner "$(host_id)" "$dead" "x"
expect_eq "U-08 dead owner is reaped" 0 "$(lock_rc)"
owner "another-host.example" "$$" "$(proc_start $$)"
expect_eq "U-08 lock from another host is never reaped" "$EX_LOCK" "$(lock_rc)"
[ -f "$LOCK_DIR/owner" ]
result "U-08 foreign lock left in place" $?
if is_pid 4194303 && is_pid 1 && ! is_pid 0 && ! is_pid 12345678901 && ! is_pid ' 1'; then r=0; else r=1; fi
result "U-08 PID syntax (up to Linux pid_max 4194304, no garbage)" $r
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
expect_eq "U-08 young lock without owner is not taken" "$EX_LOCK" "$(lock_rc)"
touch -t 202001010000 "$LOCK_DIR"
expect_eq "U-08 old lock without owner is reaped" 0 "$(lock_rc)"
owner "$(host_id)" "$dead" "x"
mkdir "$RUNTIME_DIR/lock.reap"
expect_eq "U-08 active reap guard blocks reaping" "$EX_LOCK" "$(lock_rc)"
touch -t 202001010000 "$RUNTIME_DIR/lock.reap"
expect_eq "U-08 abandoned reap guard is cleared" 0 "$(lock_rc)"
[ ! -e "$RUNTIME_DIR/lock.reap" ]
result "U-08 reap guard removed" $?
rm -rf "$LOCK_DIR"
# Deterministic: with no time left before the deadline, the abandoned guard
# and the stale lock behind it must still be cleared in the same attempt
# (formerly the reap waited for a second pass, which a one-second deadline
# could miss).
owner "$(host_id)" "$dead" "x"
mkdir "$RUNTIME_DIR/lock.reap"
touch -t 202001010000 "$RUNTIME_DIR/lock.reap"
LOCK_WAIT=0
expect_eq "U-08 abandoned reap guard and stale lock are cleared in one attempt (no time left before the deadline)" 0 "$(lock_rc)"
LOCK_WAIT=1
[ ! -e "$RUNTIME_DIR/lock.reap" ] && [ ! -e "$LOCK_DIR" ]
result "U-08 nothing left after the single-attempt reap" $?
(
  acquire_lock test
  printf 'token=someone-else\n' >"$LOCK_DIR/owner"
  release_lock
) >/dev/null 2>&1
[ -d "$LOCK_DIR" ]
result "U-08 release never removes another owner's lock" $?
rm -rf "$LOCK_DIR"

# --- U-09 static safety checks
if grep -nE '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$devenv_script" >/dev/null; then r=1; else r=0; fi
result "U-09 no eval in bin/devenv" $r
if grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$devenv_script" >/dev/null; then r=1; else r=0; fi
result "U-09 bin/devenv sources no files" $r
if grep -nE 'down[^|]*(-v|--volumes)|volume rm|system prune|container prune|network prune' "$devenv_script" >/dev/null; then r=1; else r=0; fi
result "U-09 no volume removal or global prune in bin/devenv" $r

# Real processes for U-10, U-11 and U-13. lockctl.sh takes the lock of
# RUNTIME_DIR in its own process and environment, with the signal handling of
# bin/devenv, then runs MODE: "hold" waits for GO itself; the other modes
# run a script from $work through run_op (recorded, own process group).
# await.sh READY GO: create READY, then wait (at most 30 s) for GO.
cat >"$work/await.sh" <<'AWAIT'
: >"$1"
i=0
while [ ! -e "$2" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
AWAIT
# tree.sh READY GO GCPID: like a Docker CLI with its Compose plugin, start a
# descendant that waits for GO, then wait for it.
cat >"$work/tree.sh" <<'TREE'
sh "${0%/*}/await.sh" "$1.gc" "$2" &
echo $! >"$3"
i=0
while [ ! -e "$1.gc" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
: >"$1"
wait
TREE
# termchild.sh READY MARK: record a received SIGTERM in MARK, then exit.
cat >"$work/termchild.sh" <<'TERMCHILD'
trap ': >"$2"; exit 0' TERM
: >"$1"
i=0
while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
TERMCHILD
cat >"$work/lockctl.sh" <<'LOCKCTL'
# lockctl.sh DEVENV RUNTIME_DIR LOCK_WAIT [hold|child|tree|term ARGS...]
. "$1"
SELF=$1
RUNTIME_DIR=$2
LOCK_DIR=$2/lock
LOCK_WAIT=$3
work=${0%/*}
trap on_exit EXIT
trap 'on_signal 143 TERM' TERM
acquire_lock test
case ${4-} in
  hold) sh "$work/await.sh" "$5" "$6" ;;
  child) run_op sh "$work/await.sh" "$5" "$6" ;;
  tree) run_op sh "$work/tree.sh" "$5" "$6" "$7" ;;
  term) run_op sh "$work/termchild.sh" "$5" "$6" ;;
esac
LOCKCTL
# An array, not a function: env and & must start the lock owner itself.
lockctl=("$BASH" "$work/lockctl.sh" "$devenv_script" "$RUNTIME_DIR")
wait_file() { # file: bounded wait (10 s) for a readiness signal
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
lock_token() { sed -n 's/^token=//p' "$LOCK_DIR/owner" 2>/dev/null; }
# Start a command as the leader of its own process group, as run_op does.
as_leader() {
  set -m
  "$@" &
  local j=$!
  set +m
  wait "$j"
}

# --- U-10 start identity independent of locale and time zone (H-1)
bg_sleep
probe_pid=$BG_PID
ref=$(proc_start "$probe_pid")
[[ $ref =~ ^(linux:[0-9a-f-]+:[0-9]+|lstart:[A-Z][a-z]{2}\ [A-Z][a-z]{2}\ +[0-9]{1,2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [0-9]{4})$ ]]
result "U-10 canonical start identity ($ref)" $?
start_in() { # assignments... : proc_start of probe_pid in a new process with that environment
  env "$@" "$BASH" -c '. "$1"; proc_start "$2"' start_in "$devenv_script" "$probe_pid" 2>/dev/null
}
for e in LANG=pl_PL.UTF-8 LANG=de_DE.UTF-8 LC_ALL=pl_PL.UTF-8 LC_ALL=de_DE.UTF-8 LC_ALL=C \
  LC_TIME=pl_PL.UTF-8 TZ=UTC0 TZ=JST-9 TZ=EST5EDT TZ=NZST-12NZDT 'LC_ALL=pl_PL.UTF-8 TZ=JST-9' 'LANG= LC_ALL= TZ='; do
  # shellcheck disable=SC2086 # e holds one or more assignments
  expect_eq "U-10 same identity with $e" "$ref" "$(start_in $e)"
done
raw_lstart() { env "$@" ps -o lstart= -p "$probe_pid" 2>/dev/null; }
[ "$(raw_lstart TZ=UTC0)" != "$(raw_lstart TZ=JST-9)" ]
result "U-10 control: raw ps lstart differs between time zones on this platform" $?
printf 'INFO  raw lstart: LC_ALL=C TZ=UTC0 [%s], LC_ALL=pl_PL.UTF-8 TZ=JST-9 [%s]\n' \
  "$(raw_lstart LC_ALL=C TZ=UTC0)" "$(raw_lstart LC_ALL=pl_PL.UTF-8 TZ=JST-9)"
dead_pid
expect_eq "U-10 no identity for an ended process" "" "$(proc_start "$DEAD_PID")"

rm -rf "$LOCK_DIR" "$work"/a.*
env LANG=pl_PL.UTF-8 LC_ALL=pl_PL.UTF-8 TZ=JST-9 "${lockctl[@]}" 5 hold "$work/a.ready" "$work/a.go" 2>"$work/a.err" &
holder=$!
bg_pids="$bg_pids $holder"
wait_file "$work/a.ready"
result "U-10 holder process under pl_PL.UTF-8 and TZ=JST-9 took the lock" $?
tok=$(lock_token)
for e in 'LC_ALL=C TZ=UTC0' 'LANG=de_DE.UTF-8 TZ=EST5EDT' 'LANG= LC_ALL= TZ='; do
  # shellcheck disable=SC2086 # e holds assignments
  env $e "${lockctl[@]}" 1 2>"$work/b.err"
  r=$?
  [ "$r" = "$EX_LOCK" ] && [ -n "$tok" ] && [ "$(lock_token)" = "$tok" ] && ! grep -q 'removed a stale lock' "$work/b.err"
  result "U-10 live lock not taken by a process with $e" $? "(rc $r: $(tail -n 1 "$work/b.err"))"
done
: >"$work/a.go"
wait "$holder"
expect_eq "U-10 holder finished normally" 0 "$?"
[ ! -e "$LOCK_DIR" ]
result "U-10 holder released its lock" $?

env LANG=pl_PL.UTF-8 LC_ALL=pl_PL.UTF-8 TZ=JST-9 "${lockctl[@]}" 5 hold "$work/a.ready2" "$work/a.go2" 2>/dev/null &
holder=$!
bg_pids="$bg_pids $holder"
wait_file "$work/a.ready2"
kill -KILL "$holder"
wait "$holder" 2>/dev/null
env LC_ALL=C TZ=UTC0 "${lockctl[@]}" 5 2>"$work/b.err"
r=$?
[ "$r" = 0 ] && grep -q 'removed a stale lock' "$work/b.err" && [ ! -e "$LOCK_DIR" ]
result "U-10 lock of a SIGKILLed holder is reaped from another locale and time zone" $? "(rc $r)"
: >"$work/a.go2" # ends the orphaned waiter of the killed holder

# --- U-11 Docker command recorded in the lock (M-1)
rm -rf "$LOCK_DIR" "$work/ran"
mkdir -p "$LOCK_DIR"
printf 'token=tok\nhost=%s\npid=%s\npstart=%s\n' "$(host_id)" "$$" "$(proc_start $$)" >"$LOCK_DIR/owner"
out=$(as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok sh -c 'echo "self=$$"; cat "$1/op"' rec "$LOCK_DIR" 2>&1)
self=$(printf '%s\n' "$out" | sed -n 's/^self=//p')
[ -n "$self" ] && [ "$(printf '%s\n' "$out" | sed -n 's/^pid=//p')" = "$self" ]
result "U-11 record names the process that runs the command (same PID after exec)" $? "($out)"
[ -n "$self" ] && [ "$(printf '%s\n' "$out" | sed -n 's/^pgid=//p')" = "$self" ]
result "U-11 record names the command's own process group" $? "($out)"
rm -f "$work/ran"
"$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
[ "$r" = "$EX_SAFETY" ] && [ ! -e "$work/ran" ]
result "U-11 command refused when it does not lead its own process group" $? "(rc $r)"
case $(printf '%s\n' "$out" | sed -n 's/^pstart=//p') in linux:* | lstart:*) r=0 ;; *) r=1 ;; esac
result "U-11 record carries a canonical start identity" $r
[ -z "$(find "$LOCK_DIR" -name '.op.*')" ] && [ ! -e "$RUNTIME_DIR/lock.reap" ]
result "U-11 no temporary record or reap guard left" $?
as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" other-token touch "$work/ran" 2>/dev/null
r=$?
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ]
result "U-11 command refused for a lock with another token" $? "(rc $r)"
rm -rf "$LOCK_DIR"
as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ] && [ ! -e "$LOCK_DIR" ]
result "U-11 command refused when the lock is gone" $? "(rc $r)"
mkdir -p "$LOCK_DIR"
printf 'token=tok\nhost=%s\npid=%s\npstart=%s\n' "$(host_id)" "$$" "$(proc_start $$)" >"$LOCK_DIR/owner"
mkdir "$RUNTIME_DIR/lock.reap"
(sleep 0.5 && rmdir "$RUNTIME_DIR/lock.reap") &
releaser=$!
as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
wait "$releaser"
[ "$r" = 0 ] && [ -e "$work/ran" ]
result "U-11 waits for a briefly held reap guard, then runs" $? "(rc $r)"
rm -f "$work/ran"
mkdir "$RUNTIME_DIR/lock.reap"
as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
rmdir "$RUNTIME_DIR/lock.reap"
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ]
result "U-11 busy reap guard: bounded wait, command not run" $? "(rc $r)"

# A signal while the reap guard is held (here: a mktemp that blocks inside
# the critical section) releases the guard and does not run the command.
mkdir -p "$work/slowbin"
printf '#!/bin/sh\n: >"$SLOW_READY"\nexec sleep 30\n' >"$work/slowbin/mktemp"
chmod +x "$work/slowbin/mktemp"
rm -f "$work/ran" "$work/slow.ready"
set -m
PATH=$work/slowbin:$PATH SLOW_READY=$work/slow.ready "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null &
slow=$!
set +m
wait_file "$work/slow.ready"
held_guard=$([ -d "$RUNTIME_DIR/lock.reap" ] && echo yes)
kill -TERM -- "-$slow"
wait "$slow"
r=$?
[ "$held_guard" = yes ] && [ "$r" = 143 ] && [ ! -e "$RUNTIME_DIR/lock.reap" ] && [ ! -e "$work/ran" ]
result "U-11 SIGTERM inside the critical section releases the reap guard; command not run" $? "(held $held_guard, rc $r)"
as_leader "$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
[ -e "$work/ran" ]
result "U-11 the next recorded command runs at once" $?
rm -f "$work/ran"

# compose_op() and compose() with a fake docker on PATH that reports its PID,
# its process group and the record.
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho "docker-pid=$$ docker-pgid=$(ps -o pgid= -p $$ | tr -d " ")"\ncat "$FAKE_LOCK/op" 2>/dev/null\n' >"$work/fakebin/docker"
chmod +x "$work/fakebin/docker"
# shellcheck disable=SC2030,SC2031 # PATH and globals change only inside the subshell, on purpose
fake_compose() { # held(0|1) function
  (
    PATH=$work/fakebin:$PATH FAKE_LOCK=$LOCK_DIR LOCK_HELD=$1 LOCK_TOKEN=tok COMPOSE_PORT=8080
    export FAKE_LOCK
    "$2" version
  ) 2>&1
}
out=$(fake_compose 1 compose_op)
self=$(printf '%s\n' "$out" | sed -n 's/^docker-pid=\([0-9]*\) .*/\1/p')
[ -n "$self" ] && [ "$(printf '%s\n' "$out" | sed -n 's/^pid=//p')" = "$self" ] &&
  [ "$(printf '%s\n' "$out" | sed -n 's/.*docker-pgid=//p')" = "$self" ]
result "U-11 compose_op() runs docker as the recorded leader of its own process group" $? "($out)"
rm -f "$LOCK_DIR/op"
out=$(fake_compose 1 compose)
[ -n "$(printf '%s\n' "$out" | sed -n 's/^docker-pid=//p')" ] && [ ! -e "$LOCK_DIR/op" ]
result "U-11 read-only compose() runs docker directly, unrecorded" $? "($out)"
out=$(fake_compose 0 compose_op)
r=$?
[ "$r" = "$EX_SAFETY" ] && ! printf '%s\n' "$out" | grep -q docker-pid=
result "U-11 compose_op() refuses to run without the lock" $? "(rc $r: $out)"

# try_edge() with a fake docker whose `compose up` prints a bind conflict and
# then exits 1 or is killed by SIGKILL; `compose ps` reports no edge.
mkdir -p "$work/fakeedge"
cat >"$work/fakeedge/docker" <<'FAKE'
#!/bin/sh
case " $* " in
  *" up "*)
    echo 'Error response from daemon: Bind for 127.0.0.1:8080 failed: port is already allocated' >&2
    [ "$FAKE_MODE" = killed ] && kill -KILL $$
    exit 1 ;;
esac
exit 0
FAKE
chmod +x "$work/fakeedge/docker"
# shellcheck disable=SC2030,SC2031 # PATH and globals change only inside the subshell, on purpose
edge_rc() { # mode: try_edge result with the fake docker
  (
    PATH=$work/fakeedge:$PATH FAKE_MODE=$1 LOCK_HELD=1 LOCK_TOKEN=tok WAIT_TIMEOUT=5
    export FAKE_MODE
    try_edge 8080 >/dev/null 2>&1
    echo "$?:$LAST_FAILURE"
  )
}
expect_eq "U-11 failed edge start with conflict text is a port conflict" "1:docker compose exited with status 1; its error is shown above" "$(edge_rc exit)"
expect_eq "U-11 terminated edge start is never a port conflict" "2:docker compose was terminated by signal 9" "$(edge_rc killed)"

op() { printf 'pid=%s\npstart=%s\npgid=%s\n' "$1" "$2" "${3-}" >"$LOCK_DIR/op"; }
bg_sleep
child=$BG_PID
dead_pid
owner "$(host_id)" "$DEAD_PID" "x"
op "$child" "$(proc_start "$child")"
lock_status
[ "$LOCK_STATE" = active ] && case $LOCK_INFO in *"Docker command pid $child"*) true ;; *) false ;; esac
result "U-11 ended owner with a running recorded command: lock active" $? "($LOCK_STATE: $LOCK_INFO)"
expect_eq "U-11 that lock is not taken" "$EX_LOCK" "$(lock_rc)"
op "$child" "$(other_start "$(proc_start "$child")")"
expect_eq "U-11 recorded command whose PID was reused does not block" 0 "$(lock_rc)"
owner "$(host_id)" "$DEAD_PID" "x"
op "$DEAD_PID" "x"
expect_eq "U-11 ended recorded command does not block" 0 "$(lock_rc)"
owner "$(host_id)" "$DEAD_PID" "x"
op "abc" "x"
expect_eq "U-11 malformed command record keeps the lock" "$EX_LOCK" "$(lock_rc)"
op "$child" ""
expect_eq "U-11 command record without start identity keeps the lock" "$EX_LOCK" "$(lock_rc)"
# A process group whose recorded leader ended while a member still runs.
rm -f "$work/member"
as_leader sh -c 'sleep 60 & echo $! >"$1"' leader "$work/member"
member=$(cat "$work/member")
bg_pids="$bg_pids $member"
leader=$(ps -o pgid= -p "$member" | tr -d ' ')
owner "$(host_id)" "$DEAD_PID" "x"
op "$leader" "lstart:Thu Jan  1 00:00:00 1970" "$leader"
lock_status
[ "$LOCK_STATE" = active ] && ! ps -p "$leader" >/dev/null 2>&1 && case $LOCK_INFO in *"process group $leader"*) true ;; *) false ;; esac
result "U-11 ended leader with a running group member: lock active" $? "($LOCK_STATE: $LOCK_INFO)"
expect_eq "U-11 that lock is not taken" "$EX_LOCK" "$(lock_rc)"
op "$leader" "x" ""
expect_eq "U-11 legacy command record without process group: member not considered" 0 "$(lock_rc)"
owner "$(host_id)" "$DEAD_PID" "x"
kill "$member"
wait_gone() { local i=0; while kill -0 -- "-$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }
wait_gone "$leader"
op "$leader" "x" "$leader"
expect_eq "U-11 group without members does not block" 0 "$(lock_rc)"
owner "$(host_id)" "$sleeper" "Wed Oct 21 14:26:30 2026"
lock_status
case $LOCK_INFO in *"older version"*) r=0 ;; *) r=1 ;; esac
[ "$LOCK_STATE" = active ]
result "U-11 legacy owner record: kept and explained" $(($? + r)) "($LOCK_INFO)"
rm -rf "$LOCK_DIR"

rm -f "$work"/c.*
"${lockctl[@]}" 5 child "$work/c.ready" "$work/c.go" 2>/dev/null &
parent=$!
bg_pids="$bg_pids $parent"
wait_file "$work/c.ready"
result "U-11 devenv process runs a recorded child" $?
child=$(sed -n 's/^pid=//p' "$LOCK_DIR/op" 2>/dev/null)
tok=$(lock_token)
kill -KILL "$parent"
wait "$parent" 2>/dev/null
[ -n "$child" ] && ps -p "$child" >/dev/null 2>&1 && [ -f "$LOCK_DIR/owner" ]
result "U-11 recorded child survives SIGKILL of its devenv process" $? "(child $child)"
env LC_ALL=C TZ=UTC0 "${lockctl[@]}" 1 2>"$work/b.err"
r=$?
[ "$r" = "$EX_LOCK" ] && [ "$(lock_token)" = "$tok" ] && ! grep -q 'removed a stale lock' "$work/b.err" &&
  grep -q 'Docker command pid' "$work/b.err"
result "U-11 lock kept while the orphaned child runs (exit 4)" $? "(rc $r: $(tail -n 1 "$work/b.err"))"
: >"$work/c.go"
i=0
while [ -n "$child" ] && ps -p "$child" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
"${lockctl[@]}" 5 2>"$work/b.err"
r=$?
[ "$r" = 0 ] && grep -q 'removed a stale lock' "$work/b.err" && [ ! -e "$LOCK_DIR" ]
result "U-11 lock reaped once the orphaned child ended" $? "(rc $r)"

# --- U-13 Docker CLI killed while its Compose plugin runs (process group)
rm -rf "$LOCK_DIR" "$work"/t.*
"${lockctl[@]}" 5 tree "$work/t.ready" "$work/t.go" "$work/t.gc" 2>"$work/t.err" &
parent=$!
bg_pids="$bg_pids $parent"
wait_file "$work/t.ready"
result "U-13 recorded leader started a descendant" $?
leader=$(sed -n 's/^pid=//p' "$LOCK_DIR/op" 2>/dev/null)
gc=$(cat "$work/t.gc" 2>/dev/null)
[ -n "$leader" ] && [ "$(ps -o pgid= -p "$leader" | tr -d ' ')" = "$leader" ] && [ "$(ps -o pgid= -p "$gc" | tr -d ' ')" = "$leader" ]
result "U-13 leader and descendant share the recorded process group $leader" $?
kill -KILL "$leader"
env LC_ALL=C TZ=UTC0 "${lockctl[@]}" 1 2>"$work/b.err"
r=$?
[ "$r" = "$EX_LOCK" ] && kill -0 "$parent" 2>/dev/null && kill -0 "$gc" 2>/dev/null && ! grep -q 'removed a stale lock' "$work/b.err"
result "U-13 leader SIGKILLed: owner keeps the lock while the descendant runs" $? "(rc $r)"
: >"$work/t.go"
wait "$parent"
r=$?
! kill -0 "$gc" 2>/dev/null && [ ! -e "$LOCK_DIR" ] && [ "$r" = 137 ]
result "U-13 lock released only after the descendant ended (status of the killed leader: 137)" $? "(rc $r)"

rm -f "$work"/t.*
"${lockctl[@]}" 5 tree "$work/t.ready" "$work/t.go" "$work/t.gc" 2>/dev/null &
parent=$!
bg_pids="$bg_pids $parent"
wait_file "$work/t.ready"
leader=$(sed -n 's/^pid=//p' "$LOCK_DIR/op" 2>/dev/null)
gc=$(cat "$work/t.gc" 2>/dev/null)
kill -KILL "$leader" "$parent"
wait "$parent" 2>/dev/null
env LC_ALL=C TZ=UTC0 "${lockctl[@]}" 1 2>"$work/b.err"
r=$?
[ "$r" = "$EX_LOCK" ] && grep -q "process group $leader" "$work/b.err" && kill -0 "$gc" 2>/dev/null
result "U-13 owner and leader SIGKILLed: lock kept while the descendant runs" $? "(rc $r: $(tail -n 1 "$work/b.err"))"
: >"$work/t.go"
wait_gone "$leader"
"${lockctl[@]}" 5 2>"$work/b.err"
r=$?
[ "$r" = 0 ] && grep -q 'removed a stale lock' "$work/b.err"
result "U-13 lock reaped once the whole group ended" $? "(rc $r)"

rm -f "$work"/t.*
"${lockctl[@]}" 1 tree "$work/t.ready" "$work/t.go" "$work/t.gc" 2>"$work/t.err" &
parent=$!
bg_pids="$bg_pids $parent"
wait_file "$work/t.ready"
leader=$(sed -n 's/^pid=//p' "$LOCK_DIR/op" 2>/dev/null)
kill -KILL "$leader"
wait "$parent"
r=$?
[ "$r" = "$EX_LOCK" ] && [ -f "$LOCK_DIR/owner" ] && grep -q 'kept .runtime/lock' "$work/t.err"
result "U-13 descendant outlives FLOWCRM_LOCK_WAIT: owner fails with exit 4 and keeps the lock" $? "(rc $r: $(tail -n 1 "$work/t.err"))"
: >"$work/t.go"
wait_gone "$leader"
"${lockctl[@]}" 5 2>/dev/null
expect_eq "U-13 that lock is reaped after the group ended" 0 "$?"

rm -f "$work"/t.*
"${lockctl[@]}" 5 term "$work/t.ready" "$work/t.mark" 2>/dev/null &
parent=$!
bg_pids="$bg_pids $parent"
wait_file "$work/t.ready"
SECONDS=0
kill -TERM "$parent"
wait "$parent"
r=$?
[ "$r" = 143 ] && [ -e "$work/t.mark" ] && [ ! -e "$LOCK_DIR" ] && [ "$SECONDS" -lt 5 ]
result "U-13 SIGTERM is forwarded to the Docker process group; exit 143 after it ended" $? "(rc $r, ${SECONDS}s)"

# --- U-14 Makefile interface (kept stable for the application stack)
mk_root=$(cd -P "$here/../.." && pwd -P)
mk() { (cd "$mk_root" && make "$@") 2>&1; }
expect_eq "U-14 make help lists the public targets" "help up down restart status url ports logs doctor db-upgrade-roles db-rotate-password db-rotate-password-abort test-devenv test-app" \
  "$(mk -s help | awk '/^  [a-z-]+ / { printf "%s%s", sep, $1; sep = " " }')"
for t in up down restart status url ports logs doctor; do
  expect_eq "U-14 make $t runs bin/devenv $t" "./bin/devenv $t" "$(mk -n "$t")"
done
expect_eq "U-14 make db-upgrade-roles runs bin/devenv upgrade-roles" "./bin/devenv upgrade-roles" "$(mk -n db-upgrade-roles)"
expect_eq "U-14 make db-rotate-password runs bin/devenv rotate-db-password" "./bin/devenv rotate-db-password" "$(mk -n db-rotate-password)"
expect_eq "U-14 make db-rotate-password-abort runs bin/devenv rotate-db-password-abort" "./bin/devenv rotate-db-password-abort" "$(mk -n db-rotate-password-abort)"
expect_eq "U-14 make test-devenv runs both suites" "tests/devenv/unit.sh tests/devenv/integration.sh" "$(mk -n test-devenv | tr '\n' ' ' | sed 's/ $//')"
expect_eq "U-14 make test-app runs the application suites" "tests/app/backend.sh tests/app/frontend.sh tests/app/stack.sh tests/app/prodlike.sh" "$(mk -n test-app | tr '\n' ' ' | sed 's/ $//')"
expect_eq "U-14 make without a target shows help" "$(mk -s help)" "$(mk -s)"
mk -s no-such-target >/dev/null
r=$?
[ "$r" -ne 0 ]
result "U-14 unknown make target fails" $? "(rc $r)"

# --- U-15 stack selection (app by default, fixture for the allocator tests)
stack_of() { # FLOWCRM_STACK value: prints the selected settings or the exit code
  (
    if [ "$1" = unset ]; then unset FLOWCRM_STACK; else FLOWCRM_STACK=$1; fi
    select_stack
    printf '%s|%s|%s|%s|%s|%s' "$COMPOSE_FILE_NAME" "$INTERNAL_SERVICES" "$COMPOSE_PROFILES_VALUE" "$READY_PATH" "$SECRETS" "$URL_LABEL"
  ) 2>/dev/null || echo "exit $?"
}
expect_eq "U-15 default stack is the application" "compose.yaml|db api web|dev,migrate|/health/ready|db_password app_secret db_owner_password db_app_password|FlowCRM" "$(stack_of unset)"
expect_eq "U-15 FLOWCRM_STACK=app" "$(stack_of unset)" "$(stack_of app)"
expect_eq "U-15 FLOWCRM_STACK=fixture" "compose.fixture.yaml|state||/health||FlowCRM development fixture" "$(stack_of fixture)"
for bad in APP Fixture 'app;id' '$(id)' ' app'; do
  expect_eq "U-15 reject FLOWCRM_STACK=$(show "$bad")" "exit $EX_CONFIG" "$(stack_of "$bad")"
done
FLOWCRM_STACK=fixture select_stack
is_log_service state && ! is_log_service web && ! is_log_service 'edge state' && ! is_log_service ''
result "U-15 fixture log services are an exact allow-list" $?
unset FLOWCRM_STACK
select_stack
is_log_service api && is_log_service db && ! is_log_service state && ! is_log_service 'api db'
result "U-15 application log services are an exact allow-list" $?
[ "$(report_url 18080)" = "FlowCRM: http://127.0.0.1:18080" ]
result "U-15 the URL label follows the stack" $?

# http_ok requests the stack's readiness path and requires the stack's own
# body: one local server answers like the application (/health/ready) and
# the fixture (/health); another answers every path with an SPA page.
cat >"$work/ready_server.py" <<'PYSERVER'
import http.server, sys
mode = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == "spa":
            status, body = 200, b"<!doctype html><div id=root></div>"
        elif self.path == "/health/ready":
            status, body = 200, b'{"status":"ready"}'
        elif self.path == "/health":
            status, body = 200, b"ok\n"
        else:
            status, body = 404, b"not found"
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PYSERVER
python3 "$work/ready_server.py" "$work/ready.port" stacks &
bg_pids="$bg_pids $!"
python3 "$work/ready_server.py" "$work/spa.port" spa &
bg_pids="$bg_pids $!"
wait_file "$work/ready.port" && wait_file "$work/spa.port"
ready_port=$(cat "$work/ready.port")
spa_port=$(cat "$work/spa.port")
http_ok "$ready_port"
result "U-15 application readiness: /health/ready with the application's body" $?
if http_ok "$spa_port"; then r=1; else r=0; fi
result "U-15 application readiness rejects a 200 with another body (SPA)" $r
FLOWCRM_STACK=fixture select_stack
http_ok "$ready_port"
result "U-15 fixture readiness: /health with the fixture's body" $?
if http_ok "$spa_port"; then r=1; else r=0; fi
result "U-15 fixture readiness rejects a 200 with another body (the application's SPA)" $r
unset FLOWCRM_STACK
select_stack

# Stack identity: a fake docker lists one container of this project.
mkdir -p "$work/fakeps"
printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_PS"\n' >"$work/fakeps/docker"
chmod +x "$work/fakeps/docker"
# shellcheck disable=SC2030,SC2031 # PATH and globals change only inside the subshell, on purpose
owned_rc() { # "id|working_dir|config_files" line
  (
    PATH=$work/fakeps:$PATH FAKE_PS=$1 STATE_STATUS=absent
    export FAKE_PS
    require_owned_project
  ) >/dev/null 2>"$work/owned.err"
  echo $?
}
expect_eq "U-15 a container of this checkout and stack is accepted" 0 "$(owned_rc "c1|$ROOT|$ROOT/compose.yaml")"
expect_eq "U-15 a container of the fixture stack is refused for the application" "$EX_SAFETY" "$(owned_rc "c1|$ROOT|$ROOT/compose.fixture.yaml")"
grep -q 'FLOWCRM_STACK=fixture make down' "$work/owned.err"
result "U-15 the refusal names the stack that owns the containers" $? "($(cat "$work/owned.err"))"
FLOWCRM_STACK=fixture select_stack
COMPOSE_FILE=$ROOT/$COMPOSE_FILE_NAME
expect_eq "U-15 a container of the application stack is refused for the fixture" "$EX_SAFETY" "$(owned_rc "c1|$ROOT|$ROOT/compose.yaml")"
grep -q 'FLOWCRM_STACK=app make down' "$work/owned.err"
result "U-15 ... and names the application stack" $?
unset FLOWCRM_STACK
select_stack
COMPOSE_FILE=$ROOT/$COMPOSE_FILE_NAME
expect_eq "U-15 a container without a recorded Compose file is refused" "$EX_SAFETY" "$(owned_rc "c1|$ROOT|")"
expect_eq "U-15 a container of another checkout is still refused" "$EX_SAFETY" "$(owned_rc "c1|/elsewhere|$ROOT/compose.yaml")"

# --- U-16 generated secrets
# A fake docker answers `docker volume inspect` (FAKE_VOLUME=exists or not),
# so the tests never look at this checkout's real database volume.
mkdir -p "$work/fakevol"
printf '#!/bin/sh\n[ "$FAKE_VOLUME" = exists ]\n' >"$work/fakevol/docker"
chmod +x "$work/fakevol/docker"
# shellcheck disable=SC2030,SC2031 # PATH and globals change only inside the subshell, on purpose
secrets_rc() { # volume-state [ensure_secrets argument]: runs ensure_secrets, prints its exit code
  (
    PATH=$work/fakevol:$PATH FAKE_VOLUME=$1
    export FAKE_VOLUME
    ensure_secrets ${2:+"$2"}
  ) >/dev/null 2>"$work/secrets.err"
  echo $?
}
RUNTIME_DIR=$work/rt16 SECRETS_DIR=$work/rt16/secrets
mode_of() { # GNU stat first: its -f means file system status
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
r=$(secrets_rc absent)
[ "$r" = 0 ] && [ "$(mode_of "$SECRETS_DIR")" = 700 ] && [ "$(mode_of "$SECRETS_DIR/db_password")" = 444 ] &&
  [ "$(mode_of "$SECRETS_DIR/app_secret")" = 444 ]
result "U-16 secrets created: directory 0700, files 0444" $? "(rc $r)"
[[ $(cat "$SECRETS_DIR/db_password") =~ ^[0-9a-f]{48}$ ]] && [ "$(cat "$SECRETS_DIR/db_password")" != "$(cat "$SECRETS_DIR/app_secret")" ]
result "U-16 each secret is 192 random bits, distinct" $?
before=$(cat "$SECRETS_DIR/db_password")
r=$(secrets_rc exists)
[ "$r" = 0 ] && [ "$(cat "$SECRETS_DIR/db_password")" = "$before" ] && [ -z "$(find "$SECRETS_DIR" -name '.*' -type f)" ]
result "U-16 an existing secret is never replaced; no temporary files" $? "(rc $r)"
chmod 0755 "$SECRETS_DIR"
chmod 0644 "$SECRETS_DIR/db_password"
r=$(secrets_rc exists)
[ "$r" = 0 ] && [ "$(mode_of "$SECRETS_DIR")" = 700 ] && [ "$(mode_of "$SECRETS_DIR/db_password")" = 444 ]
result "U-16 a too-open secrets directory and secret file are tightened (0700, 0444)" $? "(rc $r)"
if sudo -n -u nobody true 2>/dev/null; then
  if sudo -n -u nobody cat "$SECRETS_DIR/db_password" >/dev/null 2>&1; then r=1; else r=0; fi
  result "U-16 another local user (nobody) cannot read a secret" $r
else
  printf 'INFO  U-16 cross-user read check needs passwordless sudo (runs in CI); permissions checked above\n'
fi
rm -f "$SECRETS_DIR/db_password"
r=$(secrets_rc exists)
[ "$r" = "$EX_SAFETY" ] && [ ! -e "$SECRETS_DIR/db_password" ] && grep -q "db-data was initialised with it" "$work/secrets.err" &&
  grep -q 'Data persistence and reset' "$work/secrets.err"
result "U-16 missing database secret with an existing volume: refused, nothing generated, recovery explained" $? "(rc $r)"
r=$(secrets_rc absent)
[ "$r" = 0 ] && [ -s "$SECRETS_DIR/db_password" ] && [ "$(cat "$SECRETS_DIR/db_password")" != "$before" ]
result "U-16 without a volume the missing database secret is generated" $? "(rc $r)"
rm -f "$SECRETS_DIR/app_secret"
r=$(secrets_rc exists)
[ "$r" = 0 ] && [ -s "$SECRETS_DIR/app_secret" ]
result "U-16 a secret not bound to a volume is regenerated even if the volume exists" $? "(rc $r)"
# Role secrets (ADR-018): never generated by up for an existing volume.
[[ $(cat "$SECRETS_DIR/db_owner_password") =~ ^[0-9a-f]{48}$ ]] && [[ $(cat "$SECRETS_DIR/db_app_password") =~ ^[0-9a-f]{48}$ ]] &&
  [ "$(cat "$SECRETS_DIR/db_owner_password")" != "$(cat "$SECRETS_DIR/db_app_password")" ] && [ "$(mode_of "$SECRETS_DIR/db_app_password")" = 444 ]
result "U-16 the owner and runtime role secrets are created for a new volume (distinct, 0444)" $?
rm -f "$SECRETS_DIR/db_app_password"
r=$(secrets_rc exists)
[ "$r" = "$EX_SAFETY" ] && [ ! -e "$SECRETS_DIR/db_app_password" ] && grep -q 'make db-upgrade-roles' "$work/secrets.err" &&
  grep -q 'make db-rotate-password ROLE=app' "$work/secrets.err"
result "U-16 missing role secret with an existing volume: refused, nothing generated, upgrade and rotation explained" $? "(rc $r)"
# The former environment switch, and similar names, must not authorise it.
r=$(export ALLOW_ROLE_SECRETS=1 ALLOW_NEW_ROLE_SECRETS=1 allow=allow-new-role-secrets && secrets_rc exists)
[ "$r" = "$EX_SAFETY" ] && [ ! -e "$SECRETS_DIR/db_app_password" ] && grep -q 'so none was generated' "$work/secrets.err"
result "U-16 a role secret is not generated for an existing volume when the caller sets ALLOW_ROLE_SECRETS=1 (or similar) in the environment" $? "(rc $r)"
r=$(secrets_rc exists allow-new-role-secrets)
[ "$r" = 0 ] && [[ $(cat "$SECRETS_DIR/db_app_password") =~ ^[0-9a-f]{48}$ ]]
result "U-16 only the explicit upgrade (internal argument allow-new-role-secrets) creates a role secret for an existing volume" $? "(rc $r)"
chmod 0644 "$SECRETS_DIR/db_owner_password" && printf 'not-a-secret' >"$SECRETS_DIR/db_owner_password"
r=$(secrets_rc exists)
[ "$r" = "$EX_SAFETY" ] && grep -q 'db_owner_password is malformed' "$work/secrets.err" && grep -q 'ROLE=owner' "$work/secrets.err"
result "U-16 a malformed role secret is refused" $? "(rc $r)"
rm -f "$SECRETS_DIR/db_owner_password"
rm -f "$SECRETS_DIR/app_secret"
ln -s "$work/target" "$SECRETS_DIR/app_secret"
expect_eq "U-16 a symlinked secret is refused" "$EX_SAFETY" "$(secrets_rc absent)"
rm -rf "$work/rt16"
mkdir -p "$work/rt16" "$work/elsewhere"
ln -s "$work/elsewhere" "$SECRETS_DIR"
r=$(secrets_rc absent)
[ "$r" = "$EX_SAFETY" ] && [ -z "$(ls -A "$work/elsewhere")" ]
result "U-16 a symlinked secrets directory is refused" $? "(rc $r)"
rm -f "$SECRETS_DIR"
: >"$SECRETS_DIR"
expect_eq "U-16 a secrets path that is not a directory is refused" "$EX_SAFETY" "$(secrets_rc absent)"
rm -f "$SECRETS_DIR"
FLOWCRM_STACK=fixture select_stack
rm -rf "$work/rt16"
[ "$(secrets_rc absent)" = 0 ] && [ ! -e "$SECRETS_DIR" ]
result "U-16 the fixture stack needs no secrets" $?
unset FLOWCRM_STACK
select_stack
RUNTIME_DIR=$work/rt
SECRETS_DIR=$RUNTIME_DIR/secrets

# --- U-17 a recreated container is checked, not only Compose's exit status (FND-009S)
# Compose 2.38 was seen to exit 0 at its wait timeout while the new container
# was still starting. Fake compose and docker describe the container that
# runs after the recreation; recreated_ok must accept only a new, healthy
# container whose mounted secrets equal the host files.
saved_compose=$(declare -f compose)
saved_secrets_dir=$SECRETS_DIR
SECRETS_DIR=$work/u17-secrets
mkdir -p "$SECRETS_DIR"
printf 'new-password\n' >"$SECRETS_DIR/db_app_password"
FAKE_ID=new FAKE_HEALTH=healthy FAKE_SECRET=new-password
compose() { [ "$1 $2" = "ps --quiet" ] && [ -n "$FAKE_ID" ] && printf '%s\n' "$FAKE_ID"; return 0; }
docker() {
  case $1 in
    inspect)
      case $3 in
        *Health*) printf '%s\n' "$FAKE_HEALTH" ;;
        *Mounts*) printf '/app/var\n/run/secrets/db_app_password\n' ;;
      esac ;;
    exec)
      printf '%s\n' "$FAKE_SECRET" >"$work/u17-inside"
      printf '%s  /run/secrets/db_app_password\n' "$(sha256_of "$work/u17-inside")" ;;
  esac
}
u17() { # name expect-ok(0|1) expected-state-fragment
  local r=0
  recreated_ok api old || r=1
  if [ "$r" = "$2" ] && case $RECREATE_STATE in *"$3"*) true ;; *) false ;; esac; then
    result "U-17 $1" 0
  else
    result "U-17 $1" 1 "(returned $r, state [$RECREATE_STATE])"
  fi
}
u17 "a new healthy container with the current secret passes" 0 ""
FAKE_HEALTH=starting
u17 "a container still starting fails (the Compose false success)" 1 "not healthy (starting)"
FAKE_HEALTH=unhealthy
u17 "an unhealthy container fails" 1 "not healthy (unhealthy)"
FAKE_HEALTH=none
u17 "a container without a health check fails" 1 "not healthy (none)"
FAKE_HEALTH=healthy FAKE_ID=old
u17 "the previous container, not replaced, fails" 1 "was not replaced"
FAKE_ID=''
u17 "no running container fails" 1 "no api container is running"
FAKE_ID=new FAKE_SECRET=old-password
u17 "a container that mounts an old secret fails" 1 "does not mount the current db_app_password"
unset -f docker
eval "$saved_compose"
SECRETS_DIR=$saved_secrets_dir

# --- U-18 the rotation's refresh fails when Compose reports a false success
# refresh_secret_mounts with fake Compose calls: the api mounts an old secret,
# the recreation "succeeds" at once, and the new container is healthy or
# still starting. Only the healthy one may pass; the other must stop the
# command with EX_DOCKER before anything else runs.
saved_compose_op=$(declare -f compose_op)
saved_roles=$ROLES saved_runtime=$RUNTIME_DIR
ROLES=1 RUNTIME_DIR=$work/u18-runtime WAIT_TIMEOUT=20 SECRETS_DIR=$work/u17-secrets
mkdir -p "$RUNTIME_DIR"
docker() {
  case $1 in
    inspect)
      case $3 in
        *Health*) printf '%s\n' "$FAKE_HEALTH" ;;
        *Mounts*) printf '/run/secrets/db_app_password\n' ;;
      esac ;;
    exec)
      if [ "$2" = old ]; then printf 'old-password\n' >"$work/u18-inside"; else printf 'new-password\n' >"$work/u18-inside"; fi
      printf '%s  /run/secrets/db_app_password\n' "$(sha256_of "$work/u18-inside")" ;;
  esac
}
compose() { [ "$1 $2 $3" = "ps --quiet api" ] && printf '%s\n' "$FAKE_ID"; return 0; }
compose_op() { FAKE_ID=new; return 0; }
u18() { # name health expected-exit message-fragment
  local out r
  FAKE_ID=old FAKE_HEALTH=$2
  out=$( (refresh_secret_mounts) 2>&1)
  r=$?
  if [ "$r" = "$3" ] && case $out in *"$4"*) true ;; *) false ;; esac; then
    result "U-18 $1" 0
  else
    result "U-18 $1" 1 "(exit $r: $out)"
  fi
}
u18 "a recreated api that is healthy passes" healthy 0 "recreating api: its secret files changed"
u18 "Compose reports success for an api still starting: the command fails" starting "$EX_DOCKER" "recreating api with the current secret files failed: docker compose reported success, but the new api container is not healthy (starting)"
unset -f docker
eval "$saved_compose_op"
eval "$saved_compose"
ROLES=$saved_roles RUNTIME_DIR=$saved_runtime SECRETS_DIR=$saved_secrets_dir

# --- U-19 edge recovery after a rotation fails closed (FND-009E)
# restore_edge with fake lower layers: try_edge (Compose), gate_blocks and
# wait_http (what the edge answers), the edge's running state and compose_op
# stop. The rotation has recorded the gate (with "edge": it was serving), as
# protect_for does. The gate must stay recorded until the edge answers
# readiness, the edge must be seen blocking while gated, and a failure must
# leave the gate (with the reason), no running edge, and exit 2.
saved_fns=$(declare -f try_edge wait_http gate_blocks edge_state compose compose_op)
saved_runtime=$RUNTIME_DIR saved_gate=$GATE_FILE saved_gate_dir=$GATE_DIR saved_port=$STATE_PORT
# shellcheck disable=SC2031 # read here, in the main shell
saved_state=$STATE_STATUS
RUNTIME_DIR=$work/u19-runtime GATE_DIR=$work/u19-runtime/gate STATE_STATUS=valid STATE_PORT=18555
GATE_FILE=$GATE_DIR/security-gate
mkdir -p "$GATE_DIR"
# The fake edge's state is in files: restore_edge runs in a subshell (it may exit).
fake_running() { cat "$work/u19-running" 2>/dev/null || echo false; }
try_edge() {
  printf 'try gate=%s\n' "$([ -f "$GATE_FILE" ] && echo yes || echo no)" >>"$work/u19-calls"
  LAST_ERROR="compose output" LAST_FAILURE="docker compose exited with status 1; its error is shown above"
  [ "$FAKE_START" = failed ] && return 2
  [ "$FAKE_START" = conflict ] && { LAST_FAILURE="port 18555 is in use"; return 1; }
  echo true >"$work/u19-running"
  [ "$FAKE_START" = killed ] && exit 137 # interrupted right after the edge started
  return "$FAKE_TRY"
}
gate_blocks() { printf 'blocks gate=%s\n' "$([ -f "$GATE_FILE" ] && echo yes || echo no)" >>"$work/u19-calls"; [ "$FAKE_BLOCKS" = yes ]; }
wait_http() { printf 'ready gate=%s\n' "$([ -f "$GATE_FILE" ] && echo yes || echo no)" >>"$work/u19-calls"; [ "$FAKE_READY" = yes ]; }
edge_state() { EDGE_RUNNING=$(fake_running); }
compose() { [ "$1 $2 $3" = "ps --quiet edge" ] && [ "$(fake_running)" = true ] && printf 'edge-id\n'; return 0; }
compose_op() {
  if [ "$1" = run ]; then printf 'preflight\n' >>"$work/u19-calls"; [ "${FAKE_SEES:-yes}" = yes ]; return; fi
  [ "$1" = stop ] || return 0
  printf 'stop %s\n' "$2" >>"$work/u19-calls"
  [ "$FAKE_STOP" = fails ] && return 1
  echo false >"$work/u19-running"
}
u19() { # name start(created|failed|killed) try-rc blocks ready stop(ok|fails) expected-exit
  local out r
  rm -f "$work/u19-calls" "$work/u19-running"
  printf 'rotating the password of flowcrm_app\nedge\n' >"$GATE_FILE"
  FAKE_START=$2 FAKE_TRY=$3 FAKE_BLOCKS=$4 FAKE_READY=$5 FAKE_STOP=$6
  out=$( (restore_edge edge "the password of flowcrm_app was rotated and verified") 2>&1)
  r=$?
  U19_OUT=$out U19_RUNNING=$(fake_running)
  U19_GATE=$(head -n 1 "$GATE_FILE" 2>/dev/null) U19_GATE_EDGE=$(grep -cx edge "$GATE_FILE" 2>/dev/null)
  U19_CALLS=$(paste -sd ';' - <"$work/u19-calls" 2>/dev/null)
  [ "$r" = "$7" ]
  result "U-19 $1: exit $7" $? "(got $r: $out)"
}
u19 "the edge comes back, blocks while gated, then answers readiness" created 0 yes yes ok 0
[ ! -e "$GATE_FILE" ] && [ "$U19_RUNNING" = true ] && [ "$U19_CALLS" = "preflight;try gate=yes;blocks gate=yes;ready gate=yes" ] &&
  case $U19_OUT in *"serves again on port 18555"*) true ;; *) false ;; esac
result "U-19 the gate stays recorded while the edge starts and is checked, and is cleared only after it is ready" $? "(calls [$U19_CALLS])"
u19 "Compose cannot create the edge" failed 2 yes no ok "$EX_DOCKER"
[ "$U19_RUNNING" = false ] && [ "$U19_GATE_EDGE" = 1 ] && case $U19_GATE in *"was rotated and verified, but the edge did not serve again on port 18555"*) true ;; *) false ;; esac &&
  case $U19_OUT in *"compose output"*) true ;; *) false ;; esac
result "U-19 a failed creation keeps the gate (reason, edge line), keeps what was done and shows Compose's error" $? "(gate [$U19_GATE])"
u19 "the saved port is taken by another program" conflict 1 yes no ok "$EX_DOCKER"
[ "$U19_RUNNING" = false ] && [ "$U19_GATE_EDGE" = 1 ] && case $U19_GATE in *"did not serve again on port 18555 (port 18555 is in use"*) true ;; *) false ;; esac
result "U-19 a port conflict (try_edge 1) is a failed return like any other: the gate is kept with try_edge's reason" $? "(gate [$U19_GATE])"
FAKE_SEES=no
u19 "the edge image does not enforce the gate (or cannot read it)" created 0 yes yes ok "$EX_DOCKER"
FAKE_SEES=yes
[ "$U19_RUNNING" = false ] && [ "$U19_CALLS" = preflight ] && [ "$U19_GATE_EDGE" = 1 ] && case $U19_GATE in *"its image does not enforce the security gate"*"run make up"*) true ;; *) false ;; esac
result "U-19 an edge that would not see the gate is never started; the gate is kept and points to make up" $? "(calls [$U19_CALLS], gate [$U19_GATE])"
u19 "the edge container runs but is not healthy" created 2 yes no ok "$EX_DOCKER"
[ "$U19_RUNNING" = false ] && [ -n "$U19_GATE" ] && ! grep '^stop' "$work/u19-calls" | grep -vqx "stop $EDGE"
result "U-19 an unhealthy started edge is stopped (only the edge) and the gate kept" $? "(calls [$U19_CALLS])"
u19 "Compose reports success before the edge is ready" created 0 yes no ok "$EX_DOCKER"
[ "$U19_RUNNING" = false ] && case $U19_GATE in *"does not answer"*) true ;; *) false ;; esac
result "U-19 an edge that Compose accepted but that does not answer readiness never serves" $? "(gate [$U19_GATE])"
u19 "the edge does not block while gated" created 0 no yes ok "$EX_DOCKER"
[ "$U19_RUNNING" = false ] && case $U19_CALLS in *ready*) false ;; *) true ;; esac && case $U19_GATE in *"does not block requests while the security gate is recorded"*) true ;; *) false ;; esac
result "U-19 an edge not seen blocking while gated is stopped before readiness is trusted" $? "(calls [$U19_CALLS], gate [$U19_GATE])"
u19 "the edge cannot be stopped, but the gate blocks it" created 0 yes no fails "$EX_DOCKER"
[ "$U19_RUNNING" = true ] && [ -f "$GATE_FILE" ] && case $U19_OUT in *"does not answer"*"could not be stopped, but it answers only with the gate's 503 (checked)"*) true ;; *) false ;; esac
result "U-19 a failed stop keeps the original failure, says the stop failed and that blocking was checked" $? "($U19_OUT)"
u19 "the edge cannot be stopped and does not block" created 0 no no fails "$EX_DOCKER"
[ -f "$GATE_FILE" ] && case $U19_OUT in *"WARNING: the started edge could not be stopped and was not seen blocking requests; stop the stack now: make down"*) true ;; *) false ;; esac
result "U-19 a failed stop of an edge not seen blocking does not claim it is blocked" $? "($U19_OUT)"
u19 "interrupted right after the edge started" killed 0 yes yes ok 137
[ "$U19_RUNNING" = true ] && [ "$U19_GATE" = "rotating the password of flowcrm_app" ] && [ "$U19_GATE_EDGE" = 1 ]
result "U-19 an interruption after the edge started leaves the gate recorded (so the edge serves only its health paths)" $? "(gate [$U19_GATE])"
STATE_STATUS=invalid
u19 "no saved port: nothing to restore" created 0 yes yes ok 0
[ ! -e "$work/u19-calls" ] && [ ! -e "$GATE_FILE" ]
result "U-19 without an edge to restore the gate is cleared and nothing is started" $?
STATE_STATUS=valid
# serve_edge alone (also used by make up to restore the previous edge after a
# port failure, with no gate): a started edge that does not answer readiness
# is stopped by serve_edge itself; no gate check without a gate.
rm -f "$work/u19-calls" "$work/u19-running" "$GATE_FILE"
FAKE_START=created FAKE_TRY=0 FAKE_BLOCKS=no FAKE_READY=no FAKE_STOP=ok
serve_edge 18555 >/dev/null 2>&1
r=$?
[ "$r" = 1 ] && [ "$(fake_running)" = false ] && [ "$(grep -cx "stop $EDGE" "$work/u19-calls" 2>/dev/null)" = 1 ] &&
  ! grep -q '^blocks' "$work/u19-calls" && case $EDGE_FAILURE in *"does not answer"*"the started edge was stopped"*) true ;; *) false ;; esac
result "U-19 serve_edge without a gate stops an edge that does not answer readiness and says so" $? "(r $r, failure [$EDGE_FAILURE])"
rm -f "$work/u19-calls" "$work/u19-running"
FAKE_READY=yes
serve_edge 18555 >/dev/null 2>&1 && [ "$(fake_running)" = true ] && ! grep -q '^stop' "$work/u19-calls"
result "U-19 serve_edge keeps an edge that answers readiness" $?
eval "$saved_fns"
RUNTIME_DIR=$saved_runtime GATE_FILE=$saved_gate GATE_DIR=$saved_gate_dir STATE_STATUS=$saved_state STATE_PORT=$saved_port

# --- U-20 the gate is stored where the edge can read it (FND-009E)
# The edge's unprivileged user must see the gate or it would serve: the
# directory is 0755 and every record 0644, written by rename; a gate left at
# the old place (.runtime/security-gate) by an earlier version is moved, and
# read-only commands see it until then.
saved_runtime=$RUNTIME_DIR saved_gate=$GATE_FILE saved_gate_dir=$GATE_DIR
RUNTIME_DIR=$work/u20/.runtime GATE_DIR=$work/u20/.runtime/gate
GATE_FILE=$GATE_DIR/security-gate
mkdir -p "$RUNTIME_DIR"
printf 'an older gate\nedge\n' >"$RUNTIME_DIR/security-gate"
chmod 0600 "$RUNTIME_DIR/security-gate"
[ "$(gate_record)" = "$RUNTIME_DIR/security-gate" ]
result "U-20 a gate at the old place is still reported before it is moved" $?
(ensure_runtime_dir) && [ "$(mode_of "$GATE_DIR")" = 755 ] && [ -f "$GATE_FILE" ] && [ ! -e "$RUNTIME_DIR/security-gate" ] &&
  [ "$(mode_of "$GATE_FILE")" = 644 ] && [ "$(cat "$GATE_FILE")" = "$(printf 'an older gate\nedge')" ]
result "U-20 the gate directory is 0755 and an old gate is moved into it, readable (0644)" $?
printf 'a new reason\n' | write_gate && [ "$(mode_of "$GATE_FILE")" = 644 ] && [ "$(head -n 1 "$GATE_FILE")" = "a new reason" ] &&
  [ -z "$(find "$GATE_DIR" -name '.security-gate.*')" ]
result "U-20 write_gate replaces the record by rename, readable, with no temporary file left" $?
gate_clear
[ ! -e "$GATE_FILE" ] && ! gate_record >/dev/null
result "U-20 gate_clear removes the record" $?
RUNTIME_DIR=$saved_runtime GATE_FILE=$saved_gate GATE_DIR=$saved_gate_dir

# --- U-21 gate_blocks reads the edge's real answer (FND-009E)
# Against one-shot local listeners: only the gate's own 503 counts as
# blocked, not any other 503 and not a 200.
cat >"$work/u21-serve.py" <<'PY'
import socket, sys
status, body = sys.argv[2], sys.argv[3]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
c, _ = s.accept(); c.recv(4096)
c.sendall(("HTTP/1.1 %s\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n%s" % (status, body)).encode())
c.close(); s.close()
PY
u21() { # name status body expected(0 blocked|1 not)
  local pf=$work/u21.port i=0 r
  rm -f "$pf"
  python3 "$work/u21-serve.py" "$pf" "$2" "$3" &
  bg_pids="$bg_pids $!"
  while [ ! -s "$pf" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  BIND=127.0.0.1 gate_blocks "$(cat "$pf")"
  r=$?
  [ "$r" = "$4" ]
  result "U-21 $1" $? "(gate_blocks returned $r)"
}
u21 "the gate's 503 is blocked" "503 Service Unavailable" "FlowCRM is blocked by its security gate: run make status" 0
u21 "another 503 is not the gate" "503 Service Unavailable" "upstream unavailable" 1
u21 "a 200 is not blocked" "200 OK" "<!doctype html>" 1

# --- U-22 a gate that cannot be recorded is reported, never silent (FND-009E)
# gate_failed and cancel_db_op (fake Compose: no running edge, the cancel
# call fails) with a gate directory that cannot be written: the failure to
# record the gate is reported on stderr, gate_failed still reports the
# original failure with its exit code, and cancel_db_op returns non-zero.
# Controls: the same calls with a writable gate directory record the gate.
saved_fns=$(declare -f compose compose_op)
saved_runtime=$RUNTIME_DIR saved_gate=$GATE_FILE saved_gate_dir=$GATE_DIR
compose() { return 0; }
compose_op() { [ "$1" != exec ]; }
u22_paths() { # writable(yes|no)
  RUNTIME_DIR=$work/u22-$1/.runtime GATE_DIR=$work/u22-$1/.runtime/gate
  GATE_FILE=$GATE_DIR/security-gate
  mkdir -p "$RUNTIME_DIR"
  # A regular file where the directory should be: unwritable even for root.
  if [ "$1" = yes ]; then mkdir -p "$GATE_DIR"; else : >"$GATE_DIR"; fi
}
for w in no yes; do
  u22_paths "$w"
  out=$( (gate_failed "$EX_SAFETY" "the roles of the test project are inconsistent") 2>&1)
  r=$?
  rec=$(head -n 1 "$GATE_FILE" 2>/dev/null)
  case $out in *"security gate could not be recorded"*) said=yes ;; *) said=no ;; esac
  if [ "$w" = no ]; then
    [ "$r" = "$EX_SAFETY" ] && [ "$said" = yes ] && [ -z "$rec" ] &&
      case $out in *"devenv: ERROR: the roles of the test project are inconsistent"*) true ;; *) false ;; esac
    result "U-22 gate_failed reports an unrecordable gate on stderr and still fails with the original error" $? "(exit $r: $out)"
  else
    [ "$r" = "$EX_SAFETY" ] && [ "$said" = no ] && [ "$rec" = "the roles of the test project are inconsistent" ]
    result "U-22 control: gate_failed records the gate when it can and does not report a failure" $? "(exit $r: $out)"
  fi
  rm -f "$GATE_FILE" 2>/dev/null
  DB_OP_ID=u22-op
  out=$( (cancel_db_op) 2>&1)
  r=$?
  rec=$(head -n 1 "$GATE_FILE" 2>/dev/null)
  case $out in *"security gate could not be recorded"*) said=yes ;; *) said=no ;; esac
  if [ "$w" = no ]; then
    [ "$r" != 0 ] && [ "$said" = yes ] && [ -z "$rec" ] && case $out in *"stack is blocked"*) false ;; *) true ;; esac
    result "U-22 cancel_db_op reports an unrecordable gate, does not claim the stack is blocked, and returns non-zero" $? "(exit $r: $out)"
  else
    [ "$r" = 0 ] && [ "$said" = no ] && case $rec in *"u22-op"*"could not be confirmed as ended"*) true ;; *) false ;; esac
    result "U-22 control: cancel_db_op records the gate when it can" $? "(exit $r: $out)"
  fi
done
DB_OP_ID=
eval "$saved_fns"
RUNTIME_DIR=$saved_runtime GATE_FILE=$saved_gate GATE_DIR=$saved_gate_dir

# --- U-12 tally self-check (negative controls for the result bookkeeping)
tally_rc() { # snippet: exit status of a minimal suite running it
  "$BASH" -c '. "$0"; tally_init "$1"; '"$1"'; tally_finish' "$here/tally.sh" "$work/self.tally" >/dev/null 2>&1
  echo $?
}
expect_eq "U-12 all results passed: exit 0" 0 "$(tally_rc 'pass_result a; pass_result b')"
expect_eq "U-12 a failed result: exit 1" 1 "$(tally_rc 'pass_result a; fail_result b')"
expect_eq "U-12 no results: exit 1" 1 "$(tally_rc ':')"
expect_eq "U-12 failure recorded in a subshell: harness error" 2 "$(tally_rc 'pass_result a; (fail_result b)')"
expect_eq "U-12 result recorded in a pipeline: harness error" 2 "$(tally_rc 'pass_result a; echo | pass_result b')"
expect_eq "U-12 result captured by command substitution: harness error" 2 "$(tally_rc 'x=$(fail_result b); pass_result a')"

tally_finish ""
