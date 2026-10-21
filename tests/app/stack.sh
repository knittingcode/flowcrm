#!/usr/bin/env bash
#
# Real application stack (FLOWCRM_STACK=app) through bin/devenv, in
# temporary checkout copies, against real Docker: routing through Caddy,
# API and health behaviour, readiness failures, persistence, port conflicts,
# checkout isolation, exposure, privileges and a browser journey (Playwright
# on the project network). Only resources of the temporary checkouts are
# removed; pre-existing containers, volumes and networks are compared.
#
# Usage: tests/app/stack.sh
#   DEVENV_TEST_PORT_BASE  first port of the 20-port test range (default 18300)

# shellcheck disable=SC2319
# "<condition>; v NAME $?" records the status of that condition on purpose.

# shellcheck source-path=SCRIPTDIR
set -u
here=$(cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

BASE=${DEVENV_TEST_PORT_BASE:-18300}
LO=$BASE
HI=$((BASE + 19))
export FLOWCRM_STACK=app FLOWCRM_PORT_RANGE="$LO-$HI" FLOWCRM_PORT_DEFAULT=$LO
export FLOWCRM_WAIT_TIMEOUT=300 FLOWCRM_LOCK_WAIT=120 FLOWCRM_UP_TIMEOUT=900
unset FLOWCRM_HTTP_PORT SERVICE TAIL FOLLOW COMPOSE_PROFILES FLOWCRM_SECRETS_DIR

for t in docker curl python3 git tar; do
  command -v "$t" >/dev/null 2>&1 || { say "SKIP: $t is required"; exit 77; }
done
probe() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in $(seq "$LO" "$HI"); do
  if probe "$p"; then say "SKIP: test port $p is in use; set DEVENV_TEST_PORT_BASE to a free 20-port block"; exit 77; fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-stack.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
mkdir -p "$work/out"
: >"$work/checkouts"
: >"$work/holders"
tally_init "$work/tally"
e2e_image=flowcrm-e2e:$(sha6 "$work")

snapshot() {
  docker ps -aq --no-trunc | while read -r id; do
    docker inspect -f '{{.Id}} {{.State.Status}} {{.State.StartedAt}}' "$id" 2>/dev/null
  done | sort
}
snapshot >"$work/before.containers"
docker volume ls -q | sort >"$work/before.volumes"
docker network ls -q --no-trunc | sort >"$work/before.networks"

final_cleanup() {
  local d id
  while read -r id; do [ -n "$id" ] && kill "$id" 2>/dev/null && wait "$id" 2>/dev/null; done <"$work/holders"
  while read -r d; do
    [ -n "$d" ] || continue
    [ -d "$d" ] && (cd "$d" && ./bin/devenv down) >/dev/null 2>&1
    remove_project "$(project_of "$d")" "$d"
    docker images -q --filter "label=com.docker.compose.project=$(project_of "$d")" | sort -u |
      while read -r id; do docker image rm -f "$id" >/dev/null 2>&1; done
  done <"$work/checkouts"
  docker image rm -f "$e2e_image" >/dev/null 2>&1
  docker ps -aq --filter "label=devenv.test=stack-$(sha6 "$work")" | while read -r id; do docker rm -f "$id" >/dev/null 2>&1; done
}
trap 'final_cleanup; rm -rf "$work"' EXIT

# --- helpers ----------------------------------------------------------------

new_checkout() { # name -> sets CO
  CO=$work/$1
  copy_checkout "$CO" || { say "harness: could not copy the checkout"; exit 2; }
  printf '%s\n' "$CO" >>"$work/checkouts"
}

dv() { # label dir args...
  local label=$1 dir=$2
  shift 2
  (cd "$dir" && ./bin/devenv "$@") >"$work/out/$label.out" 2>"$work/out/$label.err"
  echo $? >"$work/out/$label.rc"
}
rc_of() { cat "$work/out/$1.rc"; }
err_has() { grep -Eq -- "$2" "$work/out/$1.err"; }
show_err() { tail -n 15 "$work/out/$1.err" | sed 's/^/      | /'; }

cid() { docker ps -q --filter "label=com.docker.compose.project=$(project_of "$1")" --filter "label=com.docker.compose.service=$2" | head -n 1; }
cid_all() { docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$1")" --filter "label=com.docker.compose.service=$2" | head -n 1; }
saved_port() { sed -n 's/^FLOWCRM_HTTP_PORT=//p' "$1/.runtime/dev.env" 2>/dev/null; }
mapped_port() { docker port "$(cid "$1" edge)" 8080/tcp 2>/dev/null | sed -n 's/^127\.0\.0\.1://p' | head -n 1; }

# GET http://127.0.0.1:PORT/PATH; sets CODE, TYPE, BODY (file), HEADERS (file)
get() { # port path [curl args...]
  local port=$1 path=$2
  shift 2
  BODY=$work/body HEADERS=$work/headers
  local r
  r=$(curl -s -o "$BODY" -D "$HEADERS" -w '%{http_code} %{content_type}' --max-time 15 "$@" "http://127.0.0.1:$port$path")
  CODE=${r%% *}
  TYPE=${r#* }
}
# Like get, but the path is sent exactly as given (no dot-segment cleanup).
get_raw() { # port path [curl args...]
  local port=$1 path=$2
  shift 2
  get "$port" "$path" --path-as-is "$@"
}
body_has() { grep -q -- "$1" "$BODY"; }
# Symfony sets X-Request-Id on every response; the frontend never does.
served_by() {
  if [ -n "$(header X-Request-Id)" ]; then
    case $TYPE in application/problem+json*) printf 'symfony-problem' ;; application/json*) printf 'symfony-json' ;; *) printf 'symfony-other' ;; esac
  elif body_has '<div id="root">'; then
    printf 'spa'
  else
    printf 'other'
  fi
}

# Prints the missing protections of a running container (empty: hardened).
hardening_problems() { # container
  local uid ro capdrop secopt priv net
  uid=$(docker exec "$1" id -u 2>/dev/null)
  IFS='|' read -r ro capdrop secopt priv net <<EOF
$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}' "$1")
EOF
  { [ -n "$uid" ] && [ "$uid" != 0 ]; } || printf 'runs-as-root '
  [ "$ro" = true ] || printf 'writable-rootfs '
  case $capdrop in *'"ALL"'*) ;; *) printf 'capabilities-kept ' ;; esac
  case $secopt in *no-new-privileges:true*) ;; *) printf 'new-privileges-allowed ' ;; esac
  [ "$priv" = false ] || printf 'privileged '
  [ "$net" != host ] || printf 'host-network '
}
header() { tr -d '\r' <"$HEADERS" | sed -n "s/^$1: //Ip" | tail -n 1; }

until_ready() { # port expected-code [seconds]: poll /health/ready
  local i=0 max=${3:-60}
  while [ "$i" -lt "$max" ]; do
    get "$1" /health/ready
    [ "$CODE" = "$2" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

psql_in() { # dir sql
  docker exec "$(cid "$1" db)" psql -U flowcrm -d flowcrm -tAq -c "$2" 2>&1
}

console_in() { # dir args...
  local dir=$1
  shift
  docker exec "$(cid "$dir" api)" php bin/console --no-interaction "$@" >"$work/out/console.log" 2>&1
}

hold_port() { # port -> sets HOLDER
  local ready=$work/holder.$1 i=0
  python3 "$APP_REPO/tests/devenv/port-holder.py" listen "$ready" "$1" >/dev/null 2>"$work/out/holder.err" &
  HOLDER=$!
  printf '%s\n' "$HOLDER" >>"$work/holders"
  while [ ! -e "$ready" ] && kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 700 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$ready" ]
}

browser() { # dir mode label: Playwright in the project's front network
  docker run --rm --network "$(project_of "$1")_front" -e BASE_URL=http://edge:8080 -e MODE="$2" "$e2e_image" \
    >"$work/out/$3.out" 2>&1
}

say "== application stack tests: range $LO-$HI, work dir $work"

# --- checkout A: start, routing, exposure, health --------------------------

new_checkout a
A=$CO
dv a-up "$A" up
[ "$(rc_of a-up)" = 0 ] || show_err a-up
[ "$(rc_of a-up)" = 0 ] && grep -qx "FlowCRM: http://127.0.0.1:$LO" "$work/out/a-up.out"; v "ST-01 make up starts the application stack and prints the URL" $?
need "ST-01 stack is running" [ "$(rc_of a-up)" = 0 ] || { tally_finish; exit; }
PA=$(saved_port "$A")
[ "$PA" = "$LO" ] && [ "$(mapped_port "$A")" = "$PA" ]; v "ST-02 saved port equals the Docker mapping ($PA)" $?

published=''
for s in web api db; do published="$published$(docker port "$(cid "$A" "$s")")"; done
[ -z "$published" ] && [ "$(docker port "$(cid "$A" edge)")" = "8080/tcp -> 127.0.0.1:$PA" ]
v "ST-03 only the edge publishes a port, on 127.0.0.1 (web, api and db: none)" $?

nets() { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(cid "$A" "$1")" | sed "s/$(project_of "$A")_//g; s/ $//"; }
[ "$(nets db)" = back ] && [ "$(nets api)" = back ] && [ "$(nets web)" = front ] && [ "$(nets edge)" = "back front" ] &&
  [ "$(docker network inspect -f '{{.Internal}}' "$(project_of "$A")_back")" = true ]
v "ST-04 api and db only on the internal back network, web only on front" $?

for s in edge web api db; do
  problems=$(hardening_problems "$(cid "$A" "$s")")
  [ -z "$problems" ]
  v "ST-05 $s: non-root, read-only, all capabilities dropped, no-new-privileges, unprivileged" $? "missing: $problems"
done
ev "$(for s in edge web api db; do printf '%s:uid=%s ' "$s" "$(docker exec "$(cid "$A" "$s")" id -u)"; done)"

# Negative controls: containers that each lack one protection are reported.
control_label=devenv.test=stack-$(sha6 "$work")
control() { # expected-problem docker-run-args...
  local expect=$1 c problems
  shift
  c=$(docker run -d --label "$control_label" "$@" "$APP_FIXTURE_IMAGE" sleep 300) || return 1
  problems=$(hardening_problems "$c")
  docker rm -f "$c" >/dev/null 2>&1
  if [ -z "$expect" ]; then [ -z "$problems" ]; else case " $problems" in *" $expect "*) true ;; *) false ;; esac; fi
}
hard=(--user 65534:65534 --read-only --cap-drop ALL --security-opt no-new-privileges:true)
control '' "${hard[@]}"
v "ST-05 control: a fully hardened container passes" $?
control runs-as-root --read-only --cap-drop ALL --security-opt no-new-privileges:true
v "ST-05 control: a root container is detected" $?
control writable-rootfs --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges:true
v "ST-05 control: a writable root filesystem is detected" $?
control capabilities-kept --user 65534:65534 --read-only --security-opt no-new-privileges:true
v "ST-05 control: kept capabilities are detected" $?
control new-privileges-allowed --user 65534:65534 --read-only --cap-drop ALL
v "ST-05 control: a missing no-new-privileges is detected" $?

get "$PA" /
[ "$CODE" = 200 ] && case $TYPE in text/html*) true ;; *) false ;; esac && body_has '<div id="root">' && body_has '/@vite/client'
v "ST-06 GET / through Caddy is the Vite-served SPA ($CODE $TYPE)" $?

get "$PA" /api/v1/system/status -H 'Accept: application/json'
[ "$CODE" = 200 ] && [ "$TYPE" = application/json ] && body_has '"apiVersion":"v1"' && grep -Eq '"databaseTime":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' "$BODY"
v "ST-07 GET /api/v1/system/status reaches Symfony and PostgreSQL ($CODE $TYPE)" $?
ev "$(cat "$BODY")"

get "$PA" /health/live
live="$CODE $(cat "$BODY")"
get "$PA" /health/ready
ready="$CODE $(cat "$BODY")"
[ "$live" = '200 {"status":"live"}' ] && [ "$ready" = '200 {"status":"ready"}' ] && header Cache-Control | grep -q no-store
v "ST-08 /health/live and /health/ready answer 200 without details" $?

get "$PA" /api/v1/does-not-exist
c1="$CODE $TYPE"
grep -q '"type":"\\/problems\\/not-found"' "$BODY" && ! body_has '<html'
nohtml=$?
get "$PA" /api
[ "$c1" = '404 application/problem+json' ] && [ "$nohtml" = 0 ] && [ "$CODE $TYPE" = '404 application/problem+json' ]
v "ST-09 unknown API routes are problem documents, not the SPA" $?

# ADR-017 boundary with raw request paths (curl --path-as-is): only /api,
# /api/... and exactly /health/live and /health/ready reach Symfony.
boundary() { # expected-layer path
  get_raw "$PA" "$2"
  local layer
  layer=$(served_by)
  if body_has 'An Error Occurred' || body_has 'symfony/error-handler' || body_has 'sf-toolbar'; then layer="$layer+symfony-error-page"; fi
  [ "$layer" = "$1" ]
  v "ST-10 $2 -> $1" $? "got $CODE $TYPE via $layer"
}
for p in //health/live /health//live //api/v1/system/status /health/live/ /API/v1/system/status /HEALTH/LIVE \
  /health%2Flive /%68ealth/live /api%2Fv1/system/status /%61pi/v1/system/status /health/./live /health/live/.. \
  /index.php /_error/500 /bundles/x /health/other /apix /api.php; do
  boundary spa "$p"
done
for p in /api//v1/system/status /api/v1/does-not-exist /api/v1/%2e%2e/%2e%2e/health/live /api/../health/live; do
  boundary symfony-problem "$p"
done
boundary symfony-json '/health/live?probe=1'

get "$PA" /accounts/some/deep/link
[ "$CODE" = 200 ] && body_has '<div id="root">'; v "ST-11 client-side routes fall back to the SPA" $?

get "$PA" /api/v1/system/status -H 'X-Request-Id: attacker-chosen'
rid=$(header X-Request-Id)
[[ $rid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [ -z "$(header Server)" ] && [ -z "$(header X-Powered-By)" ] &&
  [ "$(header X-Content-Type-Options)" = nosniff ]
v "ST-12 the edge replaces client request IDs and hides server details" $?

# Structured logs (FCRM-003 section Q): the request ID of a response is in
# the api's JSON record of that request and in the edge access log; tokens
# sent in the query, headers or cookies are in neither.
get "$PA" '/api/v1/system/status?token=st40-query-secret' -H 'Authorization: Bearer st40-header-secret' \
  -H 'Cookie: sid=st40-cookie-secret' -H 'X-CSRF-Token: st40-csrf-secret'
rid=$(header X-Request-Id)
i=0
until docker logs "$(cid "$A" api)" 2>&1 | grep -qF "\"request_id\":\"$rid\"" || [ "$i" -ge 10 ]; do sleep 1; i=$((i + 1)); done
api_log=$work/api.log edge_log=$work/edge.log
docker logs "$(cid "$A" api)" >"$api_log" 2>&1
docker logs "$(cid "$A" edge)" >"$edge_log" 2>&1
[ "$CODE" = 200 ] && grep -F "\"request_id\":\"$rid\"" "$api_log" | grep -F '"channel":"http"' | grep -F '"route":"api_v1_system_status"' |
  grep -F '"status":200' | grep -qF '"message":"request completed"'
v "ST-40 the api logs the request as one JSON record with the response's request ID" $? "$(grep -F "$rid" "$api_log" | head -n 2)"
grep -F "$rid" "$edge_log" | grep -qF '"uri":"/api/v1/system/status?[redacted]"'
v "ST-41 the edge access log has the same request ID and no query string" $? "$(grep -F "$rid" "$edge_log" | head -c 600)"
# Every JSON line of the api is a complete record with the baseline fields.
json_check=$(grep '^{' "$api_log" | docker exec -i "$(cid "$A" api)" php -r '
  $n = 0; $bad = 0;
  while (false !== ($l = fgets(STDIN))) {
    $n++; $d = json_decode($l, true);
    if (!is_array($d) || array_slice(array_keys($d), 0, 5) !== ["ts", "level", "channel", "message", "request_id"]) { $bad++; }
  }
  echo "$n $bad";')
[ "${json_check%% *}" -gt 0 ] && [ "${json_check#* }" = 0 ]
v "ST-42 api log lines are complete JSON records (lines, invalid: $json_check)" $?
! grep -qE 'st40-(query|header|cookie|csrf)-secret' "$api_log" "$edge_log"
v "ST-43 query, Authorization, Cookie and CSRF values are in no log" $? "$(grep -ohE '.{60}st40-[a-z]+-secret' "$api_log" "$edge_log" | head -n 3)"

sd=$A/.runtime/secrets
perm() { # GNU stat first: its -f means file system status
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
leak=0
for f in db_password app_secret; do
  s=$(cat "$sd/$f")
  for p in /health/live /health/ready /api/v1/system/status /api/v1/x; do
    get "$PA" "$p"
    grep -q -- "$s" "$BODY" "$HEADERS" && leak=1
  done
done
[ "$(perm "$sd")" = 700 ] && [ "$(perm "$sd/db_password")" = 444 ] && [ "$(perm "$sd/app_secret")" = 444 ] && [ "$leak" = 0 ] &&
  git -C "$APP_REPO" check-ignore -q .runtime/secrets/db_password
v "ST-13 generated secrets: private directory, ignored by Git, never in responses" $?

ids1=$(for s in edge web api db; do cid "$A" "$s"; done)
sum1=$(cksum <"$A/.runtime/dev.env")
dv a-up2 "$A" up
ids2=$(for s in edge web api db; do cid "$A" "$s"; done)
[ "$(rc_of a-up2)" = 0 ] && err_has a-up2 'already running' && [ "$ids1" = "$ids2" ] && [ "$(cksum <"$A/.runtime/dev.env")" = "$sum1" ]
v "ST-14 repeated make up changes nothing" $?

dv a-status "$A" status
dv a-url "$A" url
[ "$(rc_of a-status)" = 0 ] && grep -q 'result:     running' "$work/out/a-status.out" &&
  [ "$(rc_of a-url)" = 0 ] && [ "$(cat "$work/out/a-url.out")" = "http://127.0.0.1:$PA" ]
v "ST-15 make status and make url report the verified stack" $?

need "build the browser test image" docker build --quiet -f "$APP_REPO/docker/e2e/Dockerfile" -t "$e2e_image" "$APP_REPO" >/dev/null && {
  browser "$A" dev a-browser
  r=$?
  [ "$r" = 0 ] || tail -n 25 "$work/out/a-browser.out" | sed 's/^/      | /'
  [ "$r" = 0 ] && grep -Eq '[0-9]+ passed' "$work/out/a-browser.out" && ! grep -Eq '[0-9]+ failed' "$work/out/a-browser.out" &&
    grep -q 'Vite HMR connection is established' "$work/out/a-browser.out"
  v "ST-16 browser journey through Caddy: SPA, API data, client route, HMR (dev)" $?
  ev "$(grep -E '[0-9]+ (passed|failed|skipped)' "$work/out/a-browser.out" | tr -s ' ' | tr '\n' ' ')"
}

# --- readiness failures -----------------------------------------------------

console_in "$A" doctrine:migrations:migrate prev
get "$PA" /health/ready
r1="$CODE $(cat "$BODY")"
get "$PA" /health/live
dv a-url-pending "$A" url
[ "$r1" = '503 {"status":"not-ready"}' ] && [ "$CODE" = 200 ] && [ "$(rc_of a-url-pending)" = 1 ]
v "ST-17 a pending migration makes /health/ready 503 (live stays 200, make url fails)" $?
console_in "$A" doctrine:migrations:migrate
until_ready "$PA" 200 30; v "ST-18 applying the migration makes it ready again" $?

docker stop "$(cid "$A" db)" >/dev/null
until_ready "$PA" 503 60
down503=$?
get "$PA" /health/live
live_code=$CODE
get "$PA" /api/v1/system/status
[ "$down503" = 0 ] && [ "$live_code" = 200 ] && [ "$CODE $TYPE" = '503 application/problem+json' ] && ! grep -qi 'sqlstate\|password\|db:5432' "$BODY"
v "ST-19 database stopped: ready 503, live 200, API 503 problem without details" $?
dv a-up3 "$A" up
[ "$(rc_of a-up3)" = 0 ] && until_ready "$PA" 200 30
v "ST-20 make up restarts the database and the stack is ready again" $?

# --- persistence ------------------------------------------------------------

psql_in "$A" "CREATE TABLE st_marker (v text); INSERT INTO st_marker VALUES ('kept')" >/dev/null
base1=$(psql_in "$A" "SELECT created_at FROM schema_baseline")
mig1=$(psql_in "$A" "SELECT count(*) FROM doctrine_migration_versions")
vol=$(project_of "$A")_db-data
dv a-down "$A" down
[ "$(rc_of a-down)" = 0 ] && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$A")")" ] &&
  docker volume inspect "$vol" >/dev/null 2>&1 && [ "$(saved_port "$A")" = "$PA" ]
v "ST-21 make down removes the containers, keeps the volume and the saved port" $?
dv a-up4 "$A" up
[ "$(rc_of a-up4)" = 0 ] && [ "$(psql_in "$A" "SELECT v FROM st_marker")" = kept ] &&
  [ "$(psql_in "$A" "SELECT created_at FROM schema_baseline")" = "$base1" ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM doctrine_migration_versions")" = "$mig1" ] && [ "$(mapped_port "$A")" = "$PA" ]
v "ST-22 data survives down/up; the database is not re-initialised; same port" $?

dv a-restart "$A" restart
[ "$(rc_of a-restart)" = 0 ] && [ "$(psql_in "$A" "SELECT v FROM st_marker")" = kept ] && until_ready "$PA" 200 10
v "ST-23 make restart keeps the data and the port" $?

# --- port conflict and a second checkout ------------------------------------

need "hold port $((LO + 1))" hold_port $((LO + 1)) || { tally_finish; exit; }
new_checkout b
B=$CO
dv b-up "$B" up
PB=$(saved_port "$B")
[ "$(rc_of b-up)" = 0 ] || show_err b-up
[ "$(rc_of b-up)" = 0 ] && [ "$PB" = $((LO + 2)) ] && [ "$(mapped_port "$B")" = "$PB" ] && err_has b-up "skipped: $LO $((LO + 1))"
v "ST-24 ports in use (checkout A, an unrelated listener) are skipped: B starts on $((LO + 2))" $?
kill -0 "$HOLDER" 2>/dev/null; v "ST-25 the unrelated listener is untouched" $?

[ "$(project_of "$A")" != "$(project_of "$B")" ] && docker volume inspect "$(project_of "$B")_db-data" >/dev/null 2>&1 &&
  [ "$(psql_in "$B" "SELECT to_regclass('st_marker') IS NULL")" = t ] && [ "$(psql_in "$A" "SELECT v FROM st_marker")" = kept ] &&
  until_ready "$PA" 200 5 && until_ready "$PB" 200 5
v "ST-26 checkouts are isolated: own projects, volumes, databases and ports" $?
ev "A=$(project_of "$A"):$PA B=$(project_of "$B"):$PB"

dv b-down "$B" down
until_ready "$PA" 200 5 && [ "$(rc_of b-down)" = 0 ]; v "ST-27 stopping checkout B leaves checkout A running" $?

# --- secrets lost while the database volume exists (checkout B is down) ---

mv "$B/.runtime/secrets" "$work/b-secrets"
sum_b=$(cksum <"$B/.runtime/dev.env")
dv b-nosecret "$B" up
[ "$(rc_of b-nosecret)" = 6 ] && err_has b-nosecret "$(project_of "$B")_db-data was initialised with it" &&
  [ ! -e "$B/.runtime/secrets/db_password" ] && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$B")")" ] &&
  [ "$(cksum <"$B/.runtime/dev.env")" = "$sum_b" ] && docker volume inspect "$(project_of "$B")_db-data" >/dev/null 2>&1
v "ST-28 lost secrets with an existing volume: refused (exit 6), nothing generated or started, volume and state kept" $?
ev "$(grep -m1 ERROR "$work/out/b-nosecret.err" | cut -c1-200)"
rm -rf "$B/.runtime/secrets"
mv "$work/b-secrets" "$B/.runtime/secrets"
dv b-up2 "$B" up
PB=$(saved_port "$B")
[ "$(rc_of b-up2)" = 0 ] && until_ready "$PB" 200 10
v "ST-29 restoring the secrets recovers the stack" $?
dv b-down2 "$B" down

# --- changes while running: no needless rebuilds, migrations applied ---------

api0=$(cid "$A" api)
printf '\n// stack test: an ordinary source edit\n' >>"$A/backend/src/Kernel.php"
dv a-edit "$A" up
[ "$(rc_of a-edit)" = 0 ] && err_has a-edit 'already running; nothing to change' && [ "$(cid "$A" api)" = "$api0" ]
v "ST-30 a PHP source edit needs no rebuild: api not recreated, nothing to change" $?
cat >"$A/backend/migrations/Version20991231000000.php" <<'PHP'
<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20991231000000 extends AbstractMigration
{
    public function up(Schema $schema): void
    {
        $this->addSql('CREATE TABLE st_added_migration (id INT NOT NULL, PRIMARY KEY (id))');
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE st_added_migration');
    }
}
PHP
dv a-migrate "$A" up
[ "$(rc_of a-migrate)" = 0 ] && err_has a-migrate 'applied pending database migrations' && [ "$(cid "$A" api)" = "$api0" ] &&
  [ "$(psql_in "$A" "SELECT to_regclass('st_added_migration') IS NOT NULL")" = t ] && until_ready "$PA" 200 5
v "ST-31 a migration added while running is applied by make up, without recreating the api" $?
dv a-noop "$A" up
[ "$(rc_of a-noop)" = 0 ] && err_has a-noop 'already running; nothing to change'
v "ST-32 the next make up changes nothing" $?
printf '\n# stack test: a file baked into the image\n' >>"$A/backend/.env"
dv a-rebuild "$A" up
[ "$(rc_of a-rebuild)" = 0 ] && err_has a-rebuild 'recreated: api' && [ "$(cid "$A" api)" != "$api0" ] && until_ready "$PA" 200 10
v "ST-33 a change to a file baked into the image is rebuilt and reported (recreated: api)" $?

chmod 0755 "$A/.runtime/secrets"
dv a-perm "$A" up
[ "$(rc_of a-perm)" = 0 ] && [ "$(perm "$A/.runtime/secrets")" = 700 ]
v "ST-34 a too-open secrets directory is restored to 0700 by make up" $?
if sudo -n -u nobody true 2>/dev/null; then
  if sudo -n -u nobody cat "$A/.runtime/secrets/db_password" >/dev/null 2>&1; then r=1; else r=0; fi
  v "ST-34 another local user cannot read the secrets" $r
else
  say "      INFO ST-34 cross-user read check needs passwordless sudo (runs in CI)"
fi

# --- one checkout, two stacks: the other stack's commands are refused --------

app_ids=$(for s in edge web api db; do cid "$A" "$s"; done)
refused=''
for cmd in up down restart status url logs; do
  FLOWCRM_STACK=fixture dv "fx-$cmd" "$A" "$cmd"
  [ "$(rc_of "fx-$cmd")" = 6 ] && err_has "fx-$cmd" 'containers of another stack' && err_has "fx-$cmd" 'FLOWCRM_STACK=app make down' ||
    refused="$refused $cmd:$(rc_of "fx-$cmd")"
done
[ -z "$refused" ] && [ "$(for s in edge web api db; do cid "$A" "$s"; done)" = "$app_ids" ] && [ -z "$(cid_all "$A" state)" ] && until_ready "$PA" 200 5
v "ST-35 app running: fixture up/down/restart/status/url/logs refused (exit 6), app untouched" $? "not refused:$refused"

FLOWCRM_STACK=fixture dv fx-concurrent "$A" up &
fx=$!
dv a-concurrent "$A" restart
wait "$fx"
[ "$(rc_of a-concurrent)" = 0 ] && [ "$(rc_of fx-concurrent)" = 6 ] && [ -z "$(cid_all "$A" state)" ] && until_ready "$PA" 200 10
v "ST-36 concurrent app restart and fixture up: app restarts, fixture refused" $? "app $(rc_of a-concurrent), fixture $(rc_of fx-concurrent)"

dv a-down2 "$A" down
FLOWCRM_STACK=fixture dv fx-up "$A" up
fx_ids=$(for s in edge state; do cid "$A" "$s"; done)
[ "$(rc_of fx-up)" = 0 ] && grep -q 'FlowCRM development fixture' "$work/out/fx-up.out" && [ -z "$(cid_all "$A" api)" ]
v "ST-37 after app down the fixture starts in the same checkout" $?
refused=''
for cmd in up down restart status url logs; do
  dv "ax-$cmd" "$A" "$cmd"
  [ "$(rc_of "ax-$cmd")" = 6 ] && err_has "ax-$cmd" 'FLOWCRM_STACK=fixture make down' || refused="$refused $cmd:$(rc_of "ax-$cmd")"
done
[ -z "$refused" ] && [ "$(for s in edge state; do cid "$A" "$s"; done)" = "$fx_ids" ] && [ -z "$(cid_all "$A" api)" ]
v "ST-38 fixture running: app up/down/restart/status/url/logs refused (exit 6), fixture untouched" $? "not refused:$refused"
FLOWCRM_STACK=fixture dv fx-down "$A" down
dv a-up5 "$A" up
[ "$(rc_of fx-down)" = 0 ] && [ "$(rc_of a-up5)" = 0 ] && until_ready "$PA" 200 10 && [ "$(psql_in "$A" "SELECT v FROM st_marker")" = kept ]
v "ST-39 back to the app: data kept, stack ready" $?

# --- cleanup verification ---------------------------------------------------

final_cleanup
: >"$work/checkouts"
: >"$work/holders"
left=0
for d in "$A" "$B"; do left=$((left + $(project_resources "$(project_of "$d")"))); done
[ "$left" = 0 ]; v "CLEAN no containers, volumes or networks of the test checkouts left" $?
snapshot >"$work/after.containers"
missing=$(comm -23 "$work/before.containers" "$work/after.containers")
[ -z "$missing" ]; v "CLEAN pre-existing containers unchanged" $?
[ -z "$missing" ] || say "      changed: $missing"
[ -z "$(comm -23 "$work/before.volumes" <(docker volume ls -q | sort))" ] &&
  [ -z "$(comm -23 "$work/before.networks" <(docker network ls -q --no-trunc | sort))" ]
v "CLEAN pre-existing volumes and networks kept" $?
say "      pre-existing: $(wc -l <"$work/before.containers" | tr -d ' ') containers, $(wc -l <"$work/before.volumes" | tr -d ' ') volumes, $(wc -l <"$work/before.networks" | tr -d ' ') networks"

tally_finish "(application stack)"
