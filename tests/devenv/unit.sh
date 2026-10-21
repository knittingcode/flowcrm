#!/usr/bin/env bash
#
# Unit tests for bin/devenv logic that needs no Docker: configuration
# validation, candidate order, runtime-state parsing and writing, failure
# classification, project naming and the per-checkout lock.
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

work=$(mktemp -d "${TMPDIR:-/tmp}/devenv-unit.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
sleeper=''
trap 'rm -rf "$work"; [ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null' EXIT

pass=0
fail=0

result() { # name ok(0|1) [detail]
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'PASS  %s\n' "$1"
  else
    fail=$((fail + 1))
    printf 'FAIL  %s %s\n' "$1" "${3-}"
  fi
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
state_case() { # name expected-status [expected-port] -- content via stdin
  cat >"$STATE_FILE"
  read_state
  expect_eq "U-04 $1" "$2${3:+:$3}" "$STATE_STATUS${3:+:$STATE_PORT}"
}
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" | state_case "valid state" valid 8084
printf '# comment\n\nRUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084' "$PROJECT" | state_case "comments, no final newline" valid 8084
printf 'RUNTIME_SCHEMA=2\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" | state_case "unknown schema" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=0.0.0.0\nFLOWCRM_HTTP_PORT=8084\n' "$PROJECT" | state_case "non-loopback bind" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=$(id)\n' "$PROJECT" | state_case "command text as port" invalid
printf 'RUNTIME_SCHEMA=1\r\nCOMPOSE_PROJECT_NAME=%s\r\nFLOWCRM_HTTP_BIND=127.0.0.1\r\nFLOWCRM_HTTP_PORT=8084\r\n' "$PROJECT" | state_case "CRLF line endings" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\nPATH=/tmp\n' "$PROJECT" | state_case "unknown key" invalid
printf 'garbage\n\001\002\n' | state_case "garbage" invalid
printf '' | state_case "empty file" invalid
printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=flowcrm-000000\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=8084\n' | state_case "other project is foreign" foreign
head -c 5000 /dev/zero | tr '\0' 'x' | state_case "oversized file" invalid
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
owner() { # host boot pid pstart
  mkdir -p "$LOCK_DIR"
  printf 'token=tok\nhost=%s\nboot=%s\npid=%s\npstart=%s\ncommand=test\n' "$1" "$2" "$3" "$4" >"$LOCK_DIR/owner"
}
rm -rf "$LOCK_DIR"
expect_eq "U-08 free lock acquired" 0 "$(lock_rc)"
[ ! -e "$LOCK_DIR" ]
result "U-08 released lock removed" $?

sleep 30 &
sleeper=$!
owner "$(host_id)" "$(boot_id)" "$sleeper" "$(proc_start "$sleeper")"
expect_eq "U-08 lock of a live process is not taken" "$EX_LOCK" "$(lock_rc)"
[ -f "$LOCK_DIR/owner" ]
result "U-08 live lock left in place" $?
owner "$(host_id)" "$(boot_id)" "$sleeper" "Thu Jan  1 00:00:00 1970"
expect_eq "U-08 reused PID (start time differs) is stale" 0 "$(lock_rc)"
kill "$sleeper" 2>/dev/null
wait "$sleeper" 2>/dev/null
dead=$sleeper
sleeper=''
owner "$(host_id)" "$(boot_id)" "$dead" "x"
expect_eq "U-08 dead owner is reaped" 0 "$(lock_rc)"
owner "another-host.example" "$(boot_id)" "$$" "$(proc_start $$)"
expect_eq "U-08 lock from another host is never reaped" "$EX_LOCK" "$(lock_rc)"
[ -f "$LOCK_DIR/owner" ]
result "U-08 foreign lock left in place" $?
if [ -n "$(boot_id)" ]; then
  owner "$(host_id)" "other-boot" "$$" "$(proc_start $$)"
  expect_eq "U-08 lock from an earlier boot is reaped" 0 "$(lock_rc)"
fi
rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
expect_eq "U-08 young lock without owner is not taken" "$EX_LOCK" "$(lock_rc)"
touch -t 202001010000 "$LOCK_DIR"
expect_eq "U-08 old lock without owner is reaped" 0 "$(lock_rc)"
owner "$(host_id)" "$(boot_id)" "$dead" "x"
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

echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
