#!/usr/bin/env bash
#
# Real-Docker integration tests for bin/devenv (PA-01 .. PA-20) and the
# Makefile targets. Each scenario runs in its own temporary checkout copy,
# so every checkout gets its own Compose project. Only resources created
# here are removed afterwards, each one checked by label first; resources
# that existed before the run are compared at the end.
#
# Usage: tests/devenv/integration.sh
#   DEVENV_TEST_PORT_BASE  first port of the 20-port test range (default 8080)
# Needs: docker with Compose v2, python3 and curl (test tools only).

# shellcheck disable=SC2319,SC2181
# "<condition>; v NAME $?" records the status of that condition on purpose.
# shellcheck disable=SC2016
# Single-quoted $(...) and backticks are injection attempts that must stay literal.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
repo=$(cd -P "$here/../.." && pwd -P)
BASE=${DEVENV_TEST_PORT_BASE:-8080}
LO=$BASE
HI=$((BASE + 19))
OUT=$((BASE + 100))

export FLOWCRM_PORT_RANGE="$LO-$HI" FLOWCRM_PORT_DEFAULT=$LO
export FLOWCRM_WAIT_TIMEOUT=60 FLOWCRM_LOCK_WAIT=120 FLOWCRM_UP_TIMEOUT=600
unset FLOWCRM_HTTP_PORT SERVICE TAIL FOLLOW

work=$(mktemp -d "${TMPDIR:-/tmp}/devenv-it.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
mkdir -p "$work/out"
for f in checkouts holders containers volumes networks; do : >"$work/$f"; done

pass=0
fail=0
n=0

say() { printf '%s\n' "$*"; }
ok() { pass=$((pass + 1)); say "PASS  $1"; }
bad() { fail=$((fail + 1)); say "FAIL  $1"; [ -z "${2-}" ] || say "      $2"; }
# Usage: <condition>; v "ID description" $?
# The whole (possibly compound) condition runs before v records its status.
v() {
  if [ "$2" -eq 0 ]; then
    ok "$1"
  else
    bad "$1"
    [ -z "${LAST_LABEL-}" ] || sed "s/^/      [$LAST_LABEL] /" "$work/out/$LAST_LABEL.err" | tail -n 8
  fi
}
ev() { say "      evidence: $*"; }

# --- environment checks -----------------------------------------------------

for t in docker python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { say "SKIP: $t is required"; exit 77; }
done
docker compose version >/dev/null 2>&1 || { say "SKIP: Docker Compose v2 is required"; exit 77; }
probe() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in $(seq "$LO" "$HI") "$OUT" $((OUT + 1)); do
  if probe "$p"; then say "SKIP: test port $p is in use; set DEVENV_TEST_PORT_BASE to a free 20-port block"; exit 77; fi
done

# Snapshot of everything that existed before the run.
snapshot() {
  docker ps -aq --no-trunc | while read -r id; do
    docker inspect -f '{{.Id}} {{.State.Status}} {{.State.StartedAt}}' "$id" 2>/dev/null
  done | sort
}
snapshot >"$work/before.containers"
docker volume ls -q | sort >"$work/before.volumes"
docker network ls -q --no-trunc | sort >"$work/before.networks"

# --- helpers ----------------------------------------------------------------

project_of() { printf 'flowcrm-%s' "$(printf '%s' "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-6)"; }

new_checkout() { # name -> sets CO
  CO=$work/$1
  mkdir -p "$CO/bin"
  cp "$repo/Makefile" "$repo/compose.fixture.yaml" "$CO/"
  cp "$repo/bin/devenv" "$CO/bin/"
  printf '%s\n' "$CO" >>"$work/checkouts"
}

# dv label dir args... : run bin/devenv, keep stdout/stderr/rc under out/label.*
dv() {
  local label=$1 dir=$2
  shift 2
  (cd "$dir" && ./bin/devenv "$@") >"$work/out/$label.out" 2>"$work/out/$label.err"
  echo $? >"$work/out/$label.rc"
  LAST_LABEL=$label
}
rc_of() { cat "$work/out/$1.rc"; }
err_has() { grep -Eq -- "$2" "$work/out/$1.err"; }
out_has() { grep -Eq -- "$2" "$work/out/$1.out"; }

saved_port() { sed -n 's/^FLOWCRM_HTTP_PORT=//p' "$1/.runtime/dev.env" 2>/dev/null; }
service_id() { docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$1")" --filter "label=com.docker.compose.service=$2" | head -n 1; }
running_id() { docker ps -q --filter "label=com.docker.compose.project=$(project_of "$1")" --filter "label=com.docker.compose.service=$2" | head -n 1; }
mapped_port() { # dir -> host port of the running edge (from Docker, not from devenv)
  local id
  id=$(running_id "$1" edge)
  [ -n "$id" ] || return 1
  docker port "$id" 8080/tcp | sed -n 's/^127\.0\.0\.1://p' | head -n 1
}
http200() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$1/health")" = 200 ]; }
project_containers() { docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$1")" | wc -l | tr -d ' '; }
boot_lines() { docker exec "$(running_id "$1" state)" sh -c 'wc -l < /data/boot.log' | tr -d ' '; }

hold_ports() { # mode ports...
  local mode=$1 ready=$work/holder.$RANDOM i=0
  shift
  python3 "$here/port-holder.py" "$mode" "$ready" "$@" >/dev/null 2>"$work/out/holder.err" &
  HOLDER=$!
  printf '%s\n' "$HOLDER" >>"$work/holders"
  while [ ! -e "$ready" ] && kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 700 ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    say "harness: port holder for $* did not start: $(tail -n 1 "$work/out/holder.err")"
    for p in "$@"; do
      say "      published on $p: $(docker ps --filter "publish=$p" --format '{{.Names}} {{.Label "com.docker.compose.project.working_dir"}}' | tr '\n' ' ')"
      command -v lsof >/dev/null 2>&1 && say "      listeners on $p: $(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1, $2 }' | tr '\n' ' ')"
    done
    exit 2
  fi
}
release() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

cleanup_checkout() {
  local dir=$1 p v
  p=$(project_of "$dir")
  [ -d "$dir" ] && (cd "$dir" && ./bin/devenv down) >/dev/null 2>&1
  # Containers left by refused or failed scenarios: only this project's, from this checkout.
  docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.project.working_dir=$dir" |
    while read -r c; do docker rm -f "$c" >/dev/null 2>&1; done
  for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$p"); do
    docker volume rm "$v" >/dev/null 2>&1
  done
  docker network ls -q --filter "label=com.docker.compose.project=$p" | while read -r nw; do docker network rm "$nw" >/dev/null 2>&1; done
}

final_cleanup() {
  local d id
  while read -r id; do [ -n "$id" ] && release "$id"; done <"$work/holders"
  while read -r d; do [ -n "$d" ] && cleanup_checkout "$d"; done <"$work/checkouts"
  while read -r id; do [ -n "$id" ] && docker rm -f "$id" >/dev/null 2>&1; done <"$work/containers"
  while read -r id; do [ -n "$id" ] && docker volume rm "$id" >/dev/null 2>&1; done <"$work/volumes"
  while read -r id; do [ -n "$id" ] && docker network rm "$id" >/dev/null 2>&1; done <"$work/networks"
}
trap 'final_cleanup; rm -rf "$work"' EXIT

# --- scenarios ----------------------------------------------------------------

say "== bin/devenv integration tests: range $LO-$HI, outside port $OUT, work dir $work"

pa01() {
  new_checkout pa01
  dv pa01 "$CO" up
  [ "$(rc_of pa01)" = 0 ]; v "PA-01 default port free: exit 0" $?
  [ "$(mapped_port "$CO")" = "$LO" ]; v "PA-01 uses the default port $LO" $?
  [ "$(saved_port "$CO")" = "$LO" ]; v "PA-01 saved port equals Docker mapping" $?
  out_has pa01 "http://127.0.0.1:$LO\$"; v "PA-01 prints the URL" $?
  http200 "$LO"; v "PA-01 HTTP 200 on /health" $?
  ev "$(docker port "$(running_id "$CO" edge)" 8080/tcp) project=$(project_of "$CO") edge=$(running_id "$CO" edge | cut -c1-12)"
  cleanup_checkout "$CO"
}

pa02() {
  new_checkout pa02
  hold_ports listen "$LO"
  local h=$HOLDER
  dv pa02 "$CO" up
  [ "$(rc_of pa02)" = 0 ]; v "PA-02 default occupied by unrelated process: exit 0" $?
  [ "$(mapped_port "$CO")" = $((LO + 1)) ]; v "PA-02 uses $((LO + 1))" $?
  err_has pa02 "skipped: $LO"; v "PA-02 reports the skipped port" $?
  kill -0 "$h"; v "PA-02 unrelated listener still alive" $?
  release "$h"
  cleanup_checkout "$CO"
}

pa03() {
  new_checkout pa03
  hold_ports listen "$LO" $((LO + 1)) $((LO + 2)) $((LO + 3))
  local h=$HOLDER
  dv pa03 "$CO" up
  [ "$(rc_of pa03)" = 0 ]; v "PA-03 four consecutive ports occupied: exit 0" $?
  [ "$(mapped_port "$CO")" = $((LO + 4)) ]; v "PA-03 uses $((LO + 4))" $?
  release "$h"
  cleanup_checkout "$CO"
}

pa04() {
  new_checkout pa04a
  local a=$CO
  new_checkout pa04b
  local b=$CO pa pb
  dv pa04a "$a" up &
  dv pa04b "$b" up &
  wait
  pa=$(mapped_port "$a")
  pb=$(mapped_port "$b")
  [ "$(rc_of pa04a)$(rc_of pa04b)" = 00 ]; v "PA-04 both checkouts start (exit 0/0)" $?
  [ -n "$pa" ] && [ -n "$pb" ] && [ "$pa" != "$pb" ]; v "PA-04 different ports ($pa, $pb)" $?
  [ "$(project_of "$a")" != "$(project_of "$b")" ]; v "PA-04 different Compose projects" $?
  [ "$(saved_port "$a")" = "$pa" ] && [ "$(saved_port "$b")" = "$pb" ]; v "PA-04 each saved port matches its own mapping" $?
  http200 "$pa" && http200 "$pb"; v "PA-04 both answer HTTP 200" $?
  cleanup_checkout "$a"
  cleanup_checkout "$b"
}

pa05() {
  new_checkout pa05
  dv pa05a "$CO" up
  local e1 s1 sum1
  e1=$(running_id "$CO" edge)
  s1=$(running_id "$CO" state)
  sum1=$(cksum <"$CO/.runtime/dev.env")
  dv pa05b "$CO" up
  [ "$(rc_of pa05b)" = 0 ]; v "PA-05 second up exit 0" $?
  err_has pa05b "already running"; v "PA-05 reports already running" $?
  [ "$(running_id "$CO" edge)" = "$e1" ] && [ "$(running_id "$CO" state)" = "$s1" ]; v "PA-05 edge and state containers unchanged" $?
  [ "$(cksum <"$CO/.runtime/dev.env")" = "$sum1" ]; v "PA-05 saved state unchanged" $?
  cleanup_checkout "$CO"
}

pa06() {
  new_checkout pa06
  hold_ports listen $(seq "$LO" "$HI")
  local h=$HOLDER
  dv pa06 "$CO" up
  [ "$(rc_of pa06)" = 3 ]; v "PA-06 whole range occupied: exit 3" $?
  err_has pa06 "no free port in $LO-$HI"; v "PA-06 clear message naming the range" $?
  [ -z "$(running_id "$CO" edge)" ]; v "PA-06 no edge running" $?
  [ -z "$(service_id "$CO" edge)" ]; v "PA-06 no port outside the range used" $?
  [ ! -e "$CO/.runtime/dev.env" ]; v "PA-06 no runtime state written" $?
  release "$h"
  cleanup_checkout "$CO"
}

pa07() {
  new_checkout pa07
  mkdir -p "$CO/.runtime"
  printf 'garbage\nFLOWCRM_HTTP_PORT=$(touch PWNED)\n' >"$CO/.runtime/dev.env"
  dv pa07a "$CO" up
  [ "$(rc_of pa07a)" = 0 ]; v "PA-07 corrupt state: exit 0" $?
  err_has pa07a "ignoring invalid" && [ "$(saved_port "$CO")" = "$LO" ]; v "PA-07 corrupt state reported and replaced" $?
  [ ! -e "$CO/PWNED" ] && [ ! -e "$repo/PWNED" ]; v "PA-07 nothing executed from the state file" $?
  dv pa07b "$CO" down
  hold_ports listen "$LO"
  local h=$HOLDER
  dv pa07c "$CO" up
  [ "$(rc_of pa07c)" = 0 ]; v "PA-07 stale saved port ($LO now taken): exit 0" $?
  [ "$(mapped_port "$CO")" = $((LO + 1)) ] && [ "$(saved_port "$CO")" = $((LO + 1)) ]; v "PA-07 moves to $((LO + 1)) and saves it" $?
  release "$h"
  cleanup_checkout "$CO"
}

pa08() {
  # The bound-only port is the default; a port near the top of the range
  # has served no HTTP in this run, so it is not held in TIME_WAIT.
  local race=$((HI - 1))
  new_checkout pa08
  hold_ports bind "$race"
  local h=$HOLDER
  ! probe "$race"; v "PA-08 probe cannot see the bound-only port $race" $?
  FLOWCRM_PORT_DEFAULT=$race dv pa08 "$CO" up
  [ "$(rc_of pa08)" = 0 ]; v "PA-08 probe/bind race: exit 0" $?
  err_has pa08 "could not bind 127.0.0.1:$race \(port conflict\)"; v "PA-08 Docker conflict on $race detected" $?
  [ "$(mapped_port "$CO")" = "$LO" ] && [ "$(saved_port "$CO")" = "$LO" ]; v "PA-08 retried and uses the next candidate $LO" $?
  ev "$(grep -m1 'port conflict' "$work/out/pa08.err")"
  release "$h"
  cleanup_checkout "$CO"
}

unrelated_fingerprint() { docker inspect -f '{{.Id}} {{.State.Status}} {{.State.StartedAt}} {{json .NetworkSettings.Ports}}' "$1"; }

pa09() {
  local u v nw before
  u=$(docker run -d --label devenv.test=unrelated -p "127.0.0.1:$LO:8080" \
    busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e httpd -f -p 8080)
  printf '%s\n' "$u" >>"$work/containers"
  v=$(docker volume create --label devenv.test=unrelated "devenv-test-unrelated-$$")
  printf '%s\n' "$v" >>"$work/volumes"
  nw=$(docker network create --label devenv.test=unrelated "devenv-test-unrelated-$$")
  printf '%s\n' "$nw" >>"$work/networks"
  before=$(unrelated_fingerprint "$u")
  new_checkout pa09
  dv pa09a "$CO" up
  [ "$(rc_of pa09a)" = 0 ] && [ "$(mapped_port "$CO")" = $((LO + 1)) ]; v "PA-09 unrelated container on $LO: exit 0 on $((LO + 1))" $?
  dv pa09b "$CO" restart
  dv pa09c "$CO" down
  [ "$(rc_of pa09b)$(rc_of pa09c)" = 00 ]; v "PA-09 restart and down exit 0" $?
  [ "$(unrelated_fingerprint "$u")" = "$before" ]; v "PA-09 unrelated container unchanged (id, state, start time, ports)" $?
  docker volume inspect "$v" >/dev/null && docker network inspect "$nw" >/dev/null; v "PA-09 unrelated volume and network kept" $?
  ev "$before"
  cleanup_checkout "$CO"
  # Remove this scenario's unrelated resources now, so later scenarios get a free $LO.
  docker rm -f "$u" >/dev/null 2>&1
  docker volume rm "$v" >/dev/null 2>&1
  docker network rm "$nw" >/dev/null 2>&1
}

pa10() {
  new_checkout pa10
  dv pa10a "$CO" up
  local sum p vol
  p=$(project_of "$CO")
  vol=${p}_state-data
  [ "$(boot_lines "$CO")" = 1 ]; v "PA-10 first boot recorded in the volume" $?
  sum=$(cksum <"$CO/.runtime/dev.env")
  dv pa10b "$CO" down
  [ "$(rc_of pa10b)" = 0 ]; v "PA-10 down exit 0" $?
  [ "$(project_containers "$CO")" = 0 ]; v "PA-10 own containers removed" $?
  docker volume inspect "$vol" >/dev/null; v "PA-10 volume kept" $?
  [ "$(cksum <"$CO/.runtime/dev.env")" = "$sum" ]; v "PA-10 saved state kept" $?
  dv pa10c "$CO" up
  [ "$(boot_lines "$CO")" = 2 ]; v "PA-10 data preserved across down/up (2 boots in volume)" $?
  cleanup_checkout "$CO"
}

pa11() {
  new_checkout pa11
  dv pa11a "$CO" up &
  dv pa11b "$CO" up &
  wait
  [ "$(rc_of pa11a)$(rc_of pa11b)" = 00 ]; v "PA-11 concurrent up in one checkout: exit 0/0" $?
  err_has pa11a "waiting for another" || err_has pa11b "waiting for another"; v "PA-11 one waited for the lock" $?
  [ "$(docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$CO")" --filter label=com.docker.compose.service=edge | wc -l | tr -d ' ')" = 1 ]; v "PA-11 exactly one edge container" $?
  [ "$(saved_port "$CO")" = "$(mapped_port "$CO")" ]; v "PA-11 state valid and equal to mapping" $?
  [ ! -e "$CO/.runtime/lock" ] && [ -z "$(find "$CO/.runtime" -name '.*' -type f)" ]; v "PA-11 lock released, no temporary files" $?
  cleanup_checkout "$CO"
}

pa12() {
  new_checkout pa12
  sed -i.orig 's#exec httpd -f -v -p 8080 -h /tmp/www#exit 3#' "$CO/compose.fixture.yaml"
  grep -q 'exit 3' "$CO/compose.fixture.yaml" || { bad "PA-12 harness could not break the fixture"; return; }
  dv pa12 "$CO" up
  [ "$(rc_of pa12)" = 2 ]; v "PA-12 edge that crashes: exit 2" $?
  err_has pa12 "other than a port conflict"; v "PA-12 classified as non-port failure" $?
  ! err_has pa12 "port conflict\); trying"; v "PA-12 no other port tried" $?
  [ ! -e "$CO/.runtime/dev.env" ]; v "PA-12 no runtime state written" $?
  [ -n "$(service_id "$CO" edge)" ]; v "PA-12 containers left for diagnosis" $?
  DOCKER_HOST=unix:///nonexistent/docker.sock dv pa12b "$CO" up
  [ "$(rc_of pa12b)" = 5 ] && err_has pa12b "daemon is not reachable"; v "PA-12 unreachable Docker daemon: exit 5, nothing tried" $?
  cleanup_checkout "$CO"
}

pa13() {
  new_checkout pa13
  [ ! -e "$CO/.runtime" ]; v "PA-13 fresh checkout has no .runtime" $?
  dv pa13 "$CO" up
  [ "$(rc_of pa13)" = 0 ]; v "PA-13 fresh checkout: exit 0" $?
  [ -f "$CO/.runtime/dev.env" ] && [ ! -e "$CO/.runtime/lock" ]; v "PA-13 .runtime/dev.env created, lock released" $?
  cleanup_checkout "$CO"
}

pa14() {
  new_checkout pa14
  local want=$((LO + 5)) busy=$((LO + 6)) s1
  hold_ports listen "$want"
  local h=$HOLDER
  FLOWCRM_HTTP_PORT=$want dv pa14a "$CO" up
  [ "$(rc_of pa14a)" = 3 ]; v "PA-14 explicit port in use: exit 3" $?
  [ -z "$(running_id "$CO" edge)" ] && [ ! -e "$CO/.runtime/dev.env" ]; v "PA-14 no fallback to another port" $?
  err_has pa14a "no other port is tried"; v "PA-14 message says no fallback" $?
  release "$h"
  dv pa14b "$CO" up
  [ "$(rc_of pa14b)" = 0 ] && [ "$(mapped_port "$CO")" = "$LO" ]; v "PA-14 baseline edge starts on $LO" $?
  s1=$(running_id "$CO" state)
  hold_ports bind "$busy"
  h=$HOLDER
  FLOWCRM_HTTP_PORT=$busy dv pa14c "$CO" up
  [ "$(rc_of pa14c)" = 3 ]; v "PA-14 explicit port lost the bind race: exit 3" $?
  [ "$(mapped_port "$CO")" = "$LO" ] && http200 "$LO" && err_has pa14c "restored"; v "PA-14 previous edge restored on $LO" $?
  [ "$(saved_port "$CO")" = "$LO" ] && [ "$(running_id "$CO" state)" = "$s1" ]; v "PA-14 saved state still $LO, state container untouched" $?
  release "$h"
  cleanup_checkout "$CO"
}

pa15() {
  new_checkout pa15
  hold_ports listen "$LO"
  local h=$HOLDER p
  dv pa15a "$CO" up
  p=$(mapped_port "$CO")
  release "$h"
  dv pa15b "$CO" down
  dv pa15c "$CO" up
  [ "$(mapped_port "$CO")" = "$p" ]; v "PA-15 saved port $p reused after down/up although $LO is free again" $?
  dv pa15d "$CO" restart
  [ "$(rc_of pa15d)" = 0 ] && [ "$(mapped_port "$CO")" = "$p" ] && [ "$(saved_port "$CO")" = "$p" ]; v "PA-15 restart exit 0 and reuses $p" $?
  cleanup_checkout "$CO"
}

start_up_bg() { # dir label -> sets BG
  (cd "$1" && exec ./bin/devenv up) >"$work/out/$2.out" 2>"$work/out/$2.err" &
  BG=$!
  local i=0
  while [ ! -d "$1/.runtime/lock" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
}

pa16() {
  new_checkout pa16
  local rc
  start_up_bg "$CO" pa16a
  kill -TERM "$BG"
  wait "$BG"
  rc=$?
  [ "$rc" = 143 ]; v "PA-16 SIGTERM during up: exit 143" $?
  [ ! -e "$CO/.runtime/lock" ]; v "PA-16 lock released after SIGTERM" $?
  [ ! -e "$CO/.runtime/dev.env" ] && [ -z "$(find "$CO/.runtime" -name '.*' -type f)" ]; v "PA-16 no partial state or temporary files" $?
  dv pa16b "$CO" up
  [ "$(rc_of pa16b)" = 0 ]; v "PA-16 next up succeeds" $?
  dv pa16c "$CO" down
  start_up_bg "$CO" pa16d
  kill -KILL "$BG"
  wait "$BG" 2>/dev/null
  [ -f "$CO/.runtime/lock/owner" ]; v "PA-16 SIGKILL leaves the lock behind" $?
  # Let the orphaned docker compose child of the killed process finish.
  sleep 10
  dv pa16e "$CO" up
  [ "$(rc_of pa16e)" = 0 ] && err_has pa16e "removed a stale lock"; v "PA-16 stale lock of the killed process reaped; up exit 0" $?
  [ "$(saved_port "$CO")" = "$(mapped_port "$CO")" ]; v "PA-16 state consistent with mapping" $?
  cleanup_checkout "$CO"
}

pa17() {
  new_checkout pa17
  local i=0 v
  for v in 'FLOWCRM_PORT_RANGE=8099-8080' 'FLOWCRM_PORT_RANGE=abc' 'FLOWCRM_PORT_RANGE=80-90' \
    "FLOWCRM_PORT_DEFAULT=$OUT" 'FLOWCRM_HTTP_PORT=70000' 'FLOWCRM_HTTP_PORT=$(touch PWNED)' \
    'FLOWCRM_HTTP_PORT=8080;touch PWNED' 'FLOWCRM_PORT_RANGE=8080-8099`touch PWNED`'; do
    i=$((i + 1))
    (export "${v?}" && dv "pa17-$i" "$CO" up)
    [ "$(rc_of "pa17-$i")" = 64 ]; v "PA-17 rejects $v with exit 64" $?
  done
  [ "$(project_containers "$CO")" = 0 ] && [ ! -e "$CO/.runtime" ]; v "PA-17 nothing created: no containers, no .runtime" $?
  [ ! -e "$CO/PWNED" ] && [ ! -e "$repo/PWNED" ]; v "PA-17 no injected command ran" $?
  cleanup_checkout "$CO"
}

pa18() {
  new_checkout pa18
  mkdir -p "$CO/.runtime"
  printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=%s\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=%s\n' "$(project_of "$CO")" "$OUT" >"$CO/.runtime/dev.env"
  dv pa18a "$CO" up
  [ "$(rc_of pa18a)" = 0 ] && [ "$(mapped_port "$CO")" = "$LO" ]; v "PA-18 saved port outside the range is not used" $?
  FLOWCRM_HTTP_PORT=$OUT dv pa18b "$CO" up
  [ "$(rc_of pa18b)" = 0 ] && [ "$(mapped_port "$CO")" = "$OUT" ]; v "PA-18 explicit override may leave the range" $?
  local s1
  s1=$(running_id "$CO" state)
  dv pa18c "$CO" up
  [ "$(rc_of pa18c)" = 0 ] && [ "$(mapped_port "$CO")" = "$LO" ] && [ "$(saved_port "$CO")" = "$LO" ]; v "PA-18 without override the edge moves back into the range" $?
  [ "$(running_id "$CO" state)" = "$s1" ]; v "PA-18 only the edge was recreated" $?
  cleanup_checkout "$CO"
}

pa19() {
  new_checkout pa19
  dv pa19a "$CO" up
  sed -i.orig "s/^FLOWCRM_HTTP_PORT=.*/FLOWCRM_HTTP_PORT=$((LO + 7))/" "$CO/.runtime/dev.env"
  dv pa19b "$CO" url
  [ "$(rc_of pa19b)" = 1 ] && err_has pa19b "saved port is $((LO + 7))"; v "PA-19 url refuses a mismatched mapping (exit 1)" $?
  dv pa19c "$CO" status
  [ "$(rc_of pa19c)" = 1 ] && out_has pa19c "does not match"; v "PA-19 status reports the mismatch (exit 1)" $?
  dv pa19d "$CO" up
  [ "$(rc_of pa19d)" = 0 ] && err_has pa19d "did not match" && [ "$(saved_port "$CO")" = "$LO" ]; v "PA-19 up reconciles the saved state" $?
  dv pa19e "$CO" url
  [ "$(rc_of pa19e)" = 0 ] && out_has pa19e "^http://127.0.0.1:$LO\$"; v "PA-19 url works again" $?
  cleanup_checkout "$CO"
}

pa20() {
  new_checkout pa20a
  mkdir -p "$CO/.runtime"
  printf 'RUNTIME_SCHEMA=1\nCOMPOSE_PROJECT_NAME=flowcrm-000000\nFLOWCRM_HTTP_BIND=127.0.0.1\nFLOWCRM_HTTP_PORT=%s\n' "$LO" >"$CO/.runtime/dev.env"
  dv pa20-up "$CO" up
  dv pa20-down "$CO" down
  dv pa20-logs "$CO" logs
  [ "$(rc_of pa20-up)$(rc_of pa20-down)$(rc_of pa20-logs)" = 666 ]; v "PA-20 state naming another project: up/down/logs refused (exit 6)" $?
  [ "$(project_containers "$CO")" = 0 ]; v "PA-20 nothing started" $?
  cleanup_checkout "$CO"

  new_checkout pa20b
  local f p
  p=$(project_of "$CO")
  f=$(docker run -d --label devenv.test=foreign --label "com.docker.compose.project=$p" \
    --label com.docker.compose.project.working_dir=/somewhere/else --label com.docker.compose.service=edge \
    busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e sleep 300)
  printf '%s\n' "$f" >>"$work/containers"
  dv pa20-down2 "$CO" down
  dv pa20-up2 "$CO" up
  [ "$(rc_of pa20-down2)$(rc_of pa20-up2)" = 66 ]; v "PA-20 container of another checkout under our project name: refused (exit 6)" $?
  [ "$(docker inspect -f '{{.State.Running}}' "$f")" = true ]; v "PA-20 foreign container still running" $?
  ev "$(head -n 1 "$work/out/pa20-down2.err")"
  cleanup_checkout "$CO"
}

makefile_targets() {
  new_checkout mk
  local rc
  (cd "$CO" && make help) >"$work/out/mk-help.out" 2>&1
  grep -q 'up ' "$work/out/mk-help.out"; v "MK-01 make help lists all mandatory targets" $?
  for t in up down restart status url ports logs doctor help; do
    grep -Eq "^  $t " "$work/out/mk-help.out" || bad "MK-01 make help misses $t"
  done
  (cd "$CO" && make doctor) >"$work/out/mk-doctor.out" 2>&1
  [ $? = 0 ] && [ ! -e "$CO/.runtime" ]; v "MK-02 make doctor exit 0, read-only" $?
  (cd "$CO" && make url) >/dev/null 2>&1
  rc=$?
  [ "$rc" != 0 ]; v "MK-03 make url fails before up" $?
  (cd "$CO" && make up) >"$work/out/mk-up.out" 2>&1
  [ $? = 0 ] && grep -q "http://127.0.0.1:$LO" "$work/out/mk-up.out"; v "MK-04 make up exit 0 and prints URL" $?
  [ "$(cd "$CO" && make url 2>/dev/null)" = "http://127.0.0.1:$LO" ]; v "MK-05 make url prints the verified URL" $?
  (cd "$CO" && make status) >"$work/out/mk-status.out" 2>&1
  [ $? = 0 ] && grep -q 'result:     running' "$work/out/mk-status.out"; v "MK-06 make status shows running" $?
  (cd "$CO" && make ports) >"$work/out/mk-ports.out" 2>&1
  [ "$(grep -cE "^[0-9]+ " "$work/out/mk-ports.out")" = $((HI - LO + 1)) ]; v "MK-07 make ports lists $((HI - LO + 1)) candidates, read-only" $?
  curl -s -o /dev/null "http://127.0.0.1:$LO/"
  (cd "$CO" && make logs SERVICE=edge TAIL=20) >"$work/out/mk-logs.out" 2>&1
  [ $? = 0 ] && grep -Eq '^edge-1 +\| .*response:200' "$work/out/mk-logs.out" && ! grep -q '^state-1' "$work/out/mk-logs.out"; v "MK-08 make logs SERVICE=edge shows the edge request log only" $?
  (cd "$CO" && make logs SERVICE='edge;id') >/dev/null 2>&1
  [ $? != 0 ]; v "MK-08 make logs rejects an invalid SERVICE" $?
  (cd "$CO" && make restart) >/dev/null 2>&1
  [ $? = 0 ] && [ "$(mapped_port "$CO")" = "$LO" ]; v "MK-09 make restart exit 0, same port" $?
  (cd "$CO" && make down) >/dev/null 2>&1
  [ $? = 0 ] && [ "$(project_containers "$CO")" = 0 ]; v "MK-10 make down exit 0, containers gone" $?
  cleanup_checkout "$CO"
}

for t in pa01 pa02 pa03 pa04 pa05 pa06 pa07 pa08 pa09 pa10 pa11 pa12 pa13 pa14 pa15 pa16 pa17 pa18 pa19 pa20 makefile_targets; do
  n=$((n + 1))
  "$t"
done

# --- cleanup verification -----------------------------------------------------

final_cleanup
: >"$work/checkouts"
: >"$work/containers"
: >"$work/volumes"
: >"$work/networks"
left=$(docker ps -aq --filter label=devenv.test | wc -l | tr -d ' ')
[ "$left" = 0 ]; v "CLEAN no test helper containers left" $?
left=0
for d in "$work"/*/; do
  p=$(project_of "${d%/}")
  c=$(docker ps -aq --filter "label=com.docker.compose.project=$p" | wc -l | tr -d ' ')
  v=$(docker volume ls -q --filter "label=com.docker.compose.project=$p" | wc -l | tr -d ' ')
  left=$((left + c + v))
done
[ "$left" = 0 ]; v "CLEAN no test project containers or volumes left" $?
snapshot >"$work/after.containers"
missing=$(comm -23 "$work/before.containers" "$work/after.containers")
[ -z "$missing" ]; v "CLEAN pre-existing containers unchanged (id, state, start time)" $?
[ -z "$missing" ] || say "      changed: $missing"
[ -z "$(comm -23 "$work/before.volumes" <(docker volume ls -q | sort))" ]; v "CLEAN pre-existing volumes kept" $?
[ -z "$(comm -23 "$work/before.networks" <(docker network ls -q --no-trunc | sort))" ]; v "CLEAN pre-existing networks kept" $?
say "      pre-existing: $(wc -l <"$work/before.containers" | tr -d ' ') containers, $(wc -l <"$work/before.volumes" | tr -d ' ') volumes, $(wc -l <"$work/before.networks" | tr -d ' ') networks"

echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail (scenarios run: $n)"
[ "$fail" -eq 0 ]
