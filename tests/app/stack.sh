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

# As the schema owner, through the checkout's migrate job (ADR-018): the api
# runs as flowcrm_app and may not change the schema or the migration history.
owner_console_in() { # dir args...
  local dir=$1
  shift
  (cd "$dir" && FLOWCRM_HTTP_PORT="$(saved_port "$dir")" COMPOSE_PROFILES=dev,migrate docker compose --project-name "$(project_of "$dir")" \
    run --rm --no-deps -T migrate php bin/console --no-interaction "$@") >"$work/out/console.log" 2>&1
}
# psql as a given role over the db container's local socket.
psql_as_in() { # dir role sql
  docker exec "$(cid "$1" db)" psql -U "$2" -d flowcrm -tAq -c "$3" 2>&1
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

# Sessions are lazy (FND-008): stateless routes neither start a session nor
# set a cookie, even when a session cookie is sent; the migration that runs
# during make up created the session and cache tables.
cookies=''
for route in /api/v1/system/status /health/live /health/ready /api/v1/does-not-exist; do
  get "$PA" "$route" -H 'Cookie: flowcrm_sid=st44unknownsessionid0000000000000'
  cookies="$cookies$(header Set-Cookie)"
done
[ -z "$cookies" ] && [ "$(psql_in "$A" 'SELECT count(*) FROM sessions')" = 0 ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('sessions', 'cache_items')")" = 2 ]
v "ST-44 stateless requests set no cookie and store no session (sessions and cache_items exist)" $? "Set-Cookie: $cookies"

sd=$A/.runtime/secrets
perm() { # GNU stat first: its -f means file system status
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
leak=0
for f in db_password db_owner_password db_app_password app_secret; do
  s=$(cat "$sd/$f")
  for p in /health/live /health/ready /api/v1/system/status /api/v1/x; do
    get "$PA" "$p"
    grep -q -- "$s" "$BODY" "$HEADERS" && leak=1
  done
done
[ "$(perm "$sd")" = 700 ] && [ "$(perm "$sd/db_password")" = 444 ] && [ "$(perm "$sd/app_secret")" = 444 ] &&
  [ "$(perm "$sd/db_owner_password")" = 444 ] && [ "$(perm "$sd/db_app_password")" = 444 ] && [ "$leak" = 0 ] &&
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

owner_console_in "$A" doctrine:migrations:migrate prev
get "$PA" /health/ready
r1="$CODE $(cat "$BODY")"
get "$PA" /health/live
dv a-url-pending "$A" url
[ "$r1" = '503 {"status":"not-ready"}' ] && [ "$CODE" = 200 ] && [ "$(rc_of a-url-pending)" = 1 ]
v "ST-17 a pending migration makes /health/ready 503 (live stays 200, make url fails)" $?
owner_console_in "$A" doctrine:migrations:migrate
until_ready "$PA" 200 30; v "ST-18 applying the migration makes it ready again" $?

# The session and cache migration only creates its tables (FND-008). With
# any cache_items relation in the way, even one identical to its own
# definition, make up fails, changes nothing and keeps the verified state;
# after the documented recovery (rename it by hand), make up migrates and
# the renamed table keeps its rows.
fnd008='DoctrineMigrations\Version20261022000000'
state0=$(cat "$A/.runtime/dev.env")
owner_console_in "$A" doctrine:migrations:migrate "$fnd008"
psql_as_in "$A" flowcrm_owner "CREATE TABLE cache_items (item_id VARCHAR(255) NOT NULL, item_data BYTEA NOT NULL, item_lifetime INT DEFAULT NULL, item_time INT NOT NULL, PRIMARY KEY (item_id)); INSERT INTO cache_items VALUES ('st45:kept', 'v', NULL, 1)" >/dev/null
dv a-up-existing "$A" up
[ "$(rc_of a-up-existing)" = 2 ] && err_has a-up-existing 'applying the database migrations failed' &&
  err_has a-up-existing 'Not migrating: cache_items already exist' && [ "$(cat "$A/.runtime/dev.env")" = "$state0" ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM pg_tables WHERE tablename = 'sessions'")" = 0 ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM cache_items WHERE item_id = 'st45:kept'")" = 1 ] &&
  until_ready "$PA" 503 5
v "ST-45 an existing cache_items table stops make up without changes; the saved state is kept" $? "$(tail -n 3 "$work/out/a-up-existing.err")"
# The recovery of docs/architecture/sessions-and-cache.md: rename, then move
# it out of schema public (make up accepts only known objects there).
psql_in "$A" "ALTER TABLE cache_items RENAME TO cache_items_preexisting; ALTER INDEX cache_items_pkey RENAME TO cache_items_preexisting_pkey; CREATE SCHEMA preexisting; ALTER TABLE cache_items_preexisting SET SCHEMA preexisting" >/dev/null
dv a-up-renamed "$A" up
[ "$(rc_of a-up-renamed)" = 0 ] && err_has a-up-renamed 'applied pending database migrations' &&
  [ "$(psql_in "$A" "SELECT count(*) FROM preexisting.cache_items_preexisting WHERE item_id = 'st45:kept'")" = 1 ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('sessions', 'cache_items')")" = 2 ] &&
  until_ready "$PA" 200 10 && ! owner_console_in "$A" doctrine:schema:validate &&
  psql_in "$A" "DROP TABLE preexisting.cache_items_preexisting; DROP SCHEMA preexisting" >/dev/null && owner_console_in "$A" doctrine:schema:validate
v "ST-46 after renaming the existing table by hand, make up migrates; the renamed table keeps its rows until dropped" $? "$(tail -n 3 "$work/out/a-up-renamed.err")"

# --- database roles (ADR-018) ------------------------------------------------

# The api runs as the runtime role with only its own secret; the schema
# belongs to the owner; the superuser cannot be used from the api.
secrets_in_api=$(docker exec "$(cid "$A" api)" ls /run/secrets | tr '\n' ' ')
superuser=$(docker exec "$(cid "$A" api)" php -r 'try { new PDO("pgsql:host=db;dbname=flowcrm", "flowcrm", ""); echo "connected"; } catch (Throwable $e) { echo "refused"; }')
[ "$secrets_in_api" = "app_secret db_app_password " ] && [ "$superuser" = refused ] &&
  console_in "$A" app:database:verify-privileges --runtime &&
  [ "$(psql_in "$A" "SELECT string_agg(DISTINCT pg_get_userbyid(relowner), ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace")" = flowcrm_owner ] &&
  [ "$(psql_in "$A" "SELECT rolsuper OR rolinherit FROM pg_roles WHERE rolname = 'flowcrm_app'")" = f ]
v "ST-47 the api runs as flowcrm_app with only its own secret; the schema belongs to flowcrm_owner" $? "secrets: $secrets_in_api superuser: $superuser"

# Privilege drift fails closed: make up refuses to publish, then works again.
psql_as_in "$A" flowcrm_owner "GRANT TRUNCATE ON users TO flowcrm_app" >/dev/null
dv a-up-drift "$A" up
psql_as_in "$A" flowcrm_owner "REVOKE TRUNCATE ON users FROM flowcrm_app" >/dev/null
dv a-up-nodrift "$A" up
[ "$(rc_of a-up-drift)" = 6 ] && err_has a-up-drift 'VIOLATION: table users' && err_has a-up-drift 'stack was not published' &&
  [ "$(rc_of a-up-nodrift)" = 0 ] && until_ready "$PA" 200 10
v "ST-48 a runtime privilege outside the manifest stops make up (exit 6); removing it restores it" $? "$(grep -m1 VIOLATION "$work/out/a-up-drift.err")"

# A missing or malformed role secret of an existing volume fails closed and
# is never regenerated by make up.
mv "$sd/db_app_password" "$work/db_app_password.kept"
dv a-up-nosecret "$A" up
nosecret=$( [ ! -e "$sd/db_app_password" ] && echo absent)
mv "$work/db_app_password.kept" "$sd/db_app_password"
cp -p "$sd/db_owner_password" "$work/db_owner_password.kept"
chmod 0644 "$sd/db_owner_password" && printf 'short' >"$sd/db_owner_password"
dv a-up-badsecret "$A" up
mv -f "$work/db_owner_password.kept" "$sd/db_owner_password"
dv a-up-secrets-back "$A" up
[ "$(rc_of a-up-nosecret)" = 6 ] && [ "$nosecret" = absent ] && err_has a-up-nosecret 'make db-upgrade-roles' &&
  [ "$(rc_of a-up-badsecret)" = 6 ] && err_has a-up-badsecret 'db_owner_password is malformed' &&
  [ "$(rc_of a-up-secrets-back)" = 0 ] && until_ready "$PA" 200 10
v "ST-49 missing or malformed role secrets of an existing volume: refused (exit 6), never regenerated" $?

# Development rotation of the runtime and owner passwords.
app_pw0=$(cat "$sd/db_app_password")
owner_pw0=$(cat "$sd/db_owner_password")
(cd "$A" && ROLE=app ./bin/devenv rotate-db-password) >"$work/out/a-rot-app.out" 2>"$work/out/a-rot-app.err"
echo $? >"$work/out/a-rot-app.rc"
(cd "$A" && ROLE=owner ./bin/devenv rotate-db-password) >"$work/out/a-rot-owner.out" 2>"$work/out/a-rot-owner.err"
echo $? >"$work/out/a-rot-owner.rc"
ip=$(docker exec "$(cid "$A" db)" sh -c 'hostname -i | cut -d" " -f1')
old_app=$(docker exec -e PGPASSWORD="$app_pw0" "$(cid "$A" db)" psql -X -h "$ip" -U flowcrm_app -d flowcrm -tAc 'SELECT 1' 2>&1)
new_app=$(docker exec -e PGPASSWORD="$(cat "$sd/db_app_password")" "$(cid "$A" db)" psql -X -h "$ip" -U flowcrm_app -d flowcrm -tAc 'SELECT 1' 2>&1)
[ "$(rc_of a-rot-app)" = 0 ] && [ "$(rc_of a-rot-owner)" = 0 ] &&
  [ "$(cat "$sd/db_app_password")" != "$app_pw0" ] && [ "$(cat "$sd/db_owner_password")" != "$owner_pw0" ] &&
  [ "$(perm "$sd/db_app_password")" = 444 ] && [ -z "$(find "$sd" -name '.*' -type f)" ] &&
  printf '%s' "$old_app" | grep -q 'password authentication failed' && [ "$new_app" = 1 ] &&
  owner_console_in "$A" doctrine:migrations:up-to-date && until_ready "$PA" 200 30
v "ST-50 rotate-db-password ROLE=app and ROLE=owner: new passwords work, old ones are refused" $? "$(tail -n 2 "$work/out/a-rot-app.err")"
dv a-up-rotated "$A" up
[ "$(rc_of a-up-rotated)" = 0 ] && until_ready "$PA" 200 10
v "ST-51 make up after the rotations publishes the stack as before" $?

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

# The marker lives outside schema public, which only the migrations and the
# privilege manifest govern (ADR-018).
psql_in "$A" "CREATE SCHEMA st; CREATE TABLE st.marker (v text); INSERT INTO st.marker VALUES ('kept')" >/dev/null
base1=$(psql_in "$A" "SELECT created_at FROM schema_baseline")
mig1=$(psql_in "$A" "SELECT count(*) FROM doctrine_migration_versions")
vol=$(project_of "$A")_db-data
dv a-down "$A" down
[ "$(rc_of a-down)" = 0 ] && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$(project_of "$A")")" ] &&
  docker volume inspect "$vol" >/dev/null 2>&1 && [ "$(saved_port "$A")" = "$PA" ]
v "ST-21 make down removes the containers, keeps the volume and the saved port" $?
dv a-up4 "$A" up
[ "$(rc_of a-up4)" = 0 ] && [ "$(psql_in "$A" "SELECT v FROM st.marker")" = kept ] &&
  [ "$(psql_in "$A" "SELECT created_at FROM schema_baseline")" = "$base1" ] &&
  [ "$(psql_in "$A" "SELECT count(*) FROM doctrine_migration_versions")" = "$mig1" ] && [ "$(mapped_port "$A")" = "$PA" ]
v "ST-22 data survives down/up; the database is not re-initialised; same port" $?

dv a-restart "$A" restart
[ "$(rc_of a-restart)" = 0 ] && [ "$(psql_in "$A" "SELECT v FROM st.marker")" = kept ] && until_ready "$PA" 200 10
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
  [ "$(psql_in "$B" "SELECT to_regclass('st.marker') IS NULL")" = t ] && [ "$(psql_in "$A" "SELECT v FROM st.marker")" = kept ] &&
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
        $this->addSql('GRANT SELECT ON st_added_migration TO flowcrm_app');
    }

    public function down(Schema $schema): void
    {
        $this->addSql('DROP TABLE st_added_migration');
    }
}
PHP
# A new table is classified in the privilege manifest with what its migration grants.
python3 - "$A/backend/config/database/runtime-privileges.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('tables:\n', 'tables:\n  st_added_migration: [SELECT]\n', 1))
PY
dv a-migrate "$A" up
[ "$(rc_of a-migrate)" = 0 ] && err_has a-migrate 'applied pending database migrations' && [ "$(cid "$A" api)" = "$api0" ] &&
  [ "$(psql_in "$A" "SELECT to_regclass('st_added_migration') IS NOT NULL")" = t ] &&
  [ "$(psql_in "$A" "SELECT has_table_privilege('flowcrm_app', 'st_added_migration', 'SELECT') AND NOT has_table_privilege('flowcrm_app', 'st_added_migration', 'INSERT')")" = t ] &&
  until_ready "$PA" 200 5
v "ST-31 a migration added while running is applied by make up (as the owner, with its grant), without recreating the api" $?
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

# --- a volume from before role separation: explicit upgrade (ADR-018) --------
# Checkout C gets a volume exactly as the stack created it before FND-009:
# the upstream PostgreSQL image, one superuser account, the migrations up to
# FND-008 run as that superuser, data in the core tables, the audit log,
# sessions and cache. make up must refuse it; make db-upgrade-roles must
# convert it after a verified backup, keeping every row.
new_checkout c
C=$CO
pc=$(project_of "$C")
cs=$C/.runtime/secrets
(umask 077 && mkdir -p "$cs")
for f in db_password app_secret; do random_secret >"$cs/$f" && chmod 0444 "$cs/$f"; done
legacy_label="devenv.test=stack-$(sha6 "$work")"
legacy_image=$(sed -n 's/^ARG POSTGRES_IMAGE=//p' "$APP_REPO/docker/db/Dockerfile")
docker network create --label "$legacy_label" "$pc-legacy" >/dev/null
docker volume create --label "com.docker.compose.project=$pc" --label com.docker.compose.volume=db-data "${pc}_db-data" >/dev/null
docker run -d --name "$pc-legacy-db" --label "$legacy_label" --network "$pc-legacy" --network-alias db --user postgres \
  -e POSTGRES_DB=flowcrm -e POSTGRES_USER=flowcrm -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
  -v "$cs/db_password:/run/secrets/db_password:ro" -v "${pc}_db-data:/var/lib/postgresql" "$legacy_image" >/dev/null
i=0
until docker logs "$pc-legacy-db" 2>&1 | grep -q 'init process complete' && docker exec "$pc-legacy-db" pg_isready -q -h 127.0.0.1 -U flowcrm -d flowcrm || [ "$i" -ge 90 ]; do sleep 1; i=$((i + 1)); done
docker run --rm --network "$pc-legacy" --read-only --tmpfs /tmp --tmpfs /app/var:uid=82,gid=82 \
  -e APP_ENV=dev -e DATABASE_USER=flowcrm -e DATABASE_PASSWORD_FILE=/run/secrets/db_password \
  -v "$cs/db_password:/run/secrets/db_password:ro" -v "$cs/app_secret:/run/secrets/app_secret:ro" \
  -v "$C/backend/src:/app/src:ro" -v "$C/backend/config:/app/config:ro" -v "$C/backend/migrations:/app/migrations:ro" \
  "$(project_of "$A")-api" php bin/console doctrine:migrations:migrate --no-interaction 'DoctrineMigrations\Version20261022100000' >"$work/out/c-legacy-migrate.log" 2>&1
legacy_rc=$?
legacy_sql() { docker exec "$pc-legacy-db" psql -U flowcrm -d flowcrm -tAq -c "$1" 2>&1; }
legacy_sql "INSERT INTO users (id, email, password_hash, display_name, created_at) VALUES ('0192f0c4-7d1e-7b8a-9f3c-00000000c001', 'legacy@example.com', 'h', 'Legacy', now());
  INSERT INTO organizations (id, name, currency, timezone, created_at) VALUES ('0192f0c4-7d1e-7b8a-9f3c-00000000c002', 'Legacy Org', 'EUR', 'Europe/Warsaw', now());
  INSERT INTO audit_events (id, organization_id, occurred_at, actor_type, action, entity_type, changes) VALUES ('0192f0c4-7d1e-7b8a-9f3c-00000000c003', '0192f0c4-7d1e-7b8a-9f3c-00000000c002', now(), 'system', 'organization.created', 'organization', '{}');
  INSERT INTO sessions VALUES ('legacysession', 'data', 2000000000, 1);
  INSERT INTO cache_items VALUES ('ns:legacy', 'v', NULL, 1)" >/dev/null
rows_sql="SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (SELECT u::text t FROM users u UNION ALL SELECT o::text FROM organizations o UNION ALL SELECT a::text FROM audit_events a UNION ALL SELECT s::text FROM sessions s UNION ALL SELECT c::text FROM cache_items c UNION ALL SELECT v.version::text FROM doctrine_migration_versions v) x"
legacy_rows=$(legacy_sql "$rows_sql")
legacy_versions=$(legacy_sql "SELECT string_agg(version, ',' ORDER BY version) FROM doctrine_migration_versions")
docker rm -f "$pc-legacy-db" >/dev/null 2>&1
docker network rm "$pc-legacy" >/dev/null 2>&1

dv c-up "$C" up
c_running=$(docker ps -q --filter "label=com.docker.compose.project=$pc" | wc -l | tr -d ' ')
dv c-upgrade "$C" upgrade-roles
dump=$(find "$C/.runtime/backups" -name 'roles_upgrade_*.dump' -type f 2>/dev/null | head -n 1)
psql_c() { docker exec "$(cid "$C" db)" psql -U flowcrm -d flowcrm -tAq -c "$1" 2>&1; }
[ "$legacy_rc" = 0 ] && [ -n "$legacy_rows" ] && [ "$(rc_of c-up)" = 6 ] && err_has c-up 'make db-upgrade-roles' && [ "$c_running" = 0 ] &&
  [ "$(rc_of c-upgrade)" = 0 ] && err_has c-upgrade 'verified backup: .runtime/backups/roles_upgrade_' &&
  [ -s "$dump" ] && [ "$(perm "$dump")" = 600 ] && [ "$(perm "$C/.runtime/backups")" = 700 ] &&
  [ "$(docker exec "$(cid "$C" db)" flowcrm-db-roles state)" = complete ] &&
  [ "$(psql_c "SELECT string_agg(DISTINCT pg_get_userbyid(relowner), ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace")" = flowcrm_owner ] &&
  [ "$(psql_c "SELECT string_agg(tgname || ':' || tgenabled::text, ' ' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'audit_events'::regclass AND NOT tgisinternal")" = 'audit_events_append_only:O audit_events_no_truncate:O' ] &&
  [ "$(psql_c "SELECT string_agg(version, ',' ORDER BY version) FROM doctrine_migration_versions WHERE version <> 'DoctrineMigrations\Version20261023000000'")" = "$legacy_versions" ] &&
  [ "$(psql_c "SELECT count(*) FROM pg_database WHERE datname LIKE '%restore_check'")" = 0 ] &&
  [ "$(psql_c "SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (SELECT u::text t FROM users u UNION ALL SELECT o::text FROM organizations o UNION ALL SELECT a::text FROM audit_events a UNION ALL SELECT s::text FROM sessions s UNION ALL SELECT c::text FROM cache_items c UNION ALL SELECT v.version::text FROM doctrine_migration_versions v WHERE v.version <> 'DoctrineMigrations\Version20261023000000') x")" = "$legacy_rows" ]
v "ST-52 a volume from before role separation: make up refuses it; make db-upgrade-roles converts it after a verified backup, keeping every row" $? "$(tail -n 3 "$work/out/c-upgrade.err")"
dv c-up2 "$C" up
[ "$(rc_of c-up2)" = 0 ] && until_ready "$(saved_port "$C")" 200 30 && console_in "$C" app:database:verify-privileges --runtime
c_published=$?
c_rows=$(psql_c "$rows_sql")
# A second upgrade stops api, web and edge, re-checks and converts nothing.
dv c-upgrade2 "$C" upgrade-roles
[ "$c_published" = 0 ] && [ "$(rc_of c-upgrade2)" = 0 ] && err_has c-upgrade2 'nothing to upgrade' &&
  ! err_has c-upgrade2 'verified backup' && [ "$(psql_c "$rows_sql")" = "$c_rows" ] &&
  [ "$(docker exec "$(cid "$C" db)" flowcrm-db-roles state)" = complete ]
v "ST-53 after the upgrade make up publishes the stack as flowcrm_app; a second upgrade changes nothing" $? "$(tail -n 2 "$work/out/c-up2.err")"
dv c-down "$C" down

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
[ "$(rc_of fx-down)" = 0 ] && [ "$(rc_of a-up5)" = 0 ] && until_ready "$PA" 200 10 && [ "$(psql_in "$A" "SELECT v FROM st.marker")" = kept ]
v "ST-39 back to the app: data kept, stack ready" $?

# --- cleanup verification ---------------------------------------------------

final_cleanup
: >"$work/checkouts"
: >"$work/holders"
left=0
for d in "$A" "$B" "$C"; do left=$((left + $(project_resources "$(project_of "$d")"))); done
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
