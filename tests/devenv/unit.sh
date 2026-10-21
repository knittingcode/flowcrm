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
expect_eq "U-06 Docker Desktop: Ports are not available" conflict \
  "$(classify x 'Error response from daemon: Ports are not available: exposing port TCP 127.0.0.1:8080 -> 127.0.0.1:0: listen tcp 127.0.0.1:8080: bind: address already in use')"
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

# Real processes for U-10 and U-11. lockctl.sh takes the lock of RUNTIME_DIR
# in its own process and environment; with "hold" it then waits for GO, with
# "child" it runs a recorded child (__run-recorded) that waits for GO.
cat >"$work/lockctl.sh" <<'LOCKCTL'
# lockctl.sh DEVENV RUNTIME_DIR LOCK_WAIT [hold|child READY GO]
. "$1"
RUNTIME_DIR=$2
LOCK_DIR=$2/lock
LOCK_WAIT=$3
trap on_exit EXIT
acquire_lock test
await='i=0; while [ ! -e "$2" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done'
case ${4-} in
  hold) sh -c ": >\"\$1\"; $await" await "$5" "$6" ;;
  child) "$BASH" "$1" __run-recorded "$LOCK_DIR" "$LOCK_TOKEN" sh -c ": >\"\$1\"; $await" child "$5" "$6" ;;
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
out=$("$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok sh -c 'echo "self=$$"; cat "$1/op"' rec "$LOCK_DIR" 2>&1)
self=$(printf '%s\n' "$out" | sed -n 's/^self=//p')
[ -n "$self" ] && [ "$(printf '%s\n' "$out" | sed -n 's/^pid=//p')" = "$self" ]
result "U-11 record names the process that runs the command (same PID after exec)" $? "($out)"
case $(printf '%s\n' "$out" | sed -n 's/^pstart=//p') in linux:* | lstart:*) r=0 ;; *) r=1 ;; esac
result "U-11 record carries a canonical start identity" $r
[ -z "$(find "$LOCK_DIR" -name '.op.*')" ] && [ ! -e "$RUNTIME_DIR/lock.reap" ]
result "U-11 no temporary record or reap guard left" $?
"$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" other-token touch "$work/ran" 2>/dev/null
r=$?
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ]
result "U-11 command refused for a lock with another token" $? "(rc $r)"
rm -rf "$LOCK_DIR"
"$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ] && [ ! -e "$LOCK_DIR" ]
result "U-11 command refused when the lock is gone" $? "(rc $r)"
mkdir -p "$LOCK_DIR"
printf 'token=tok\nhost=%s\npid=%s\npstart=%s\n' "$(host_id)" "$$" "$(proc_start $$)" >"$LOCK_DIR/owner"
mkdir "$RUNTIME_DIR/lock.reap"
(sleep 0.5 && rmdir "$RUNTIME_DIR/lock.reap") &
releaser=$!
"$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
wait "$releaser"
[ "$r" = 0 ] && [ -e "$work/ran" ]
result "U-11 waits for a briefly held reap guard, then runs" $? "(rc $r)"
rm -f "$work/ran"
mkdir "$RUNTIME_DIR/lock.reap"
"$BASH" "$devenv_script" __run-recorded "$LOCK_DIR" tok touch "$work/ran" 2>/dev/null
r=$?
rmdir "$RUNTIME_DIR/lock.reap"
[ "$r" = "$EX_LOCK" ] && [ ! -e "$work/ran" ]
result "U-11 busy reap guard: bounded wait, command not run" $? "(rc $r)"

# compose() with a fake docker on PATH that reports its PID and the record.
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho "docker-pid=$$"\ncat "$FAKE_LOCK/op" 2>/dev/null\n' >"$work/fakebin/docker"
chmod +x "$work/fakebin/docker"
fake_compose() { # held(0|1)
  (
    PATH=$work/fakebin:$PATH FAKE_LOCK=$LOCK_DIR LOCK_HELD=$1 LOCK_TOKEN=tok COMPOSE_PORT=8080
    export FAKE_LOCK
    compose version
  ) 2>&1
}
out=$(fake_compose 1)
self=$(printf '%s\n' "$out" | sed -n 's/^docker-pid=//p')
[ -n "$self" ] && [ "$(printf '%s\n' "$out" | sed -n 's/^pid=//p')" = "$self" ]
result "U-11 compose() runs docker as the recorded child while the lock is held" $? "($out)"
rm -f "$LOCK_DIR/op"
out=$(fake_compose 0)
[ -n "$(printf '%s\n' "$out" | sed -n 's/^docker-pid=//p')" ] && [ ! -e "$LOCK_DIR/op" ]
result "U-11 compose() without the lock runs docker directly, unrecorded" $? "($out)"

op() { printf 'pid=%s\npstart=%s\n' "$1" "$2" >"$LOCK_DIR/op"; }
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
