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
expect_eq "U-14 make help lists the public targets" "help up down restart status url ports logs doctor test-devenv test-app" \
  "$(mk -s help | awk '/^  [a-z-]+ / { printf "%s%s", sep, $1; sep = " " }')"
for t in up down restart status url ports logs doctor; do
  expect_eq "U-14 make $t runs bin/devenv $t" "./bin/devenv $t" "$(mk -n "$t")"
done
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
expect_eq "U-15 default stack is the application" "compose.yaml|db api web|dev|/health/ready|db_password app_secret|FlowCRM" "$(stack_of unset)"
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

# http_ok requests the stack's readiness path: a local server answers 200
# only for /health/ready.
cat >"$work/ready_server.py" <<'PYSERVER'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/health/ready" else 404)
        self.end_headers()
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PYSERVER
python3 "$work/ready_server.py" "$work/ready.port" &
bg_pids="$bg_pids $!"
wait_file "$work/ready.port"
ready_port=$(cat "$work/ready.port")
http_ok "$ready_port"
result "U-15 application readiness requests /health/ready" $?
FLOWCRM_STACK=fixture select_stack
if http_ok "$ready_port"; then r=1; else r=0; fi
result "U-15 fixture readiness requests /health (404 here: not ready)" $r
unset FLOWCRM_STACK
select_stack

# --- U-16 generated secrets
RUNTIME_DIR=$work/rt16 SECRETS_DIR=$work/rt16/secrets
mode_of() { # GNU stat first: its -f means file system status
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
(ensure_secrets) 2>/dev/null
r=$?
[ "$r" = 0 ] && [ "$(mode_of "$SECRETS_DIR")" = 700 ] && [ "$(mode_of "$SECRETS_DIR/db_password")" = 444 ] &&
  [ "$(mode_of "$SECRETS_DIR/app_secret")" = 444 ]
result "U-16 secrets created: directory 0700, files 0444" $? "(rc $r)"
[[ $(cat "$SECRETS_DIR/db_password") =~ ^[0-9a-f]{48}$ ]] && [ "$(cat "$SECRETS_DIR/db_password")" != "$(cat "$SECRETS_DIR/app_secret")" ]
result "U-16 each secret is 192 random bits, distinct" $?
before=$(cat "$SECRETS_DIR/db_password")
(ensure_secrets) 2>/dev/null
[ "$(cat "$SECRETS_DIR/db_password")" = "$before" ] && [ -z "$(find "$SECRETS_DIR" -name '.*' -type f)" ]
result "U-16 an existing secret is never replaced; no temporary files" $?
rm -f "$SECRETS_DIR/app_secret"
ln -s "$work/target" "$SECRETS_DIR/app_secret"
(ensure_secrets) 2>/dev/null
expect_eq "U-16 a symlinked secret is refused" "$EX_SAFETY" "$?"
rm -rf "$work/rt16"
mkdir -p "$work/rt16" "$work/elsewhere"
ln -s "$work/elsewhere" "$SECRETS_DIR"
(ensure_secrets) 2>/dev/null
r=$?
[ "$r" = "$EX_SAFETY" ] && [ -z "$(ls -A "$work/elsewhere")" ]
result "U-16 a symlinked secrets directory is refused" $? "(rc $r)"
FLOWCRM_STACK=fixture select_stack
rm -rf "$work/rt16"
(ensure_secrets) 2>/dev/null && [ ! -e "$SECRETS_DIR" ]
result "U-16 the fixture stack needs no secrets" $?
unset FLOWCRM_STACK
select_stack
RUNTIME_DIR=$work/rt
SECRETS_DIR=$RUNTIME_DIR/secrets

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
