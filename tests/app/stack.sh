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

browser() { # dir mode label: Playwright in the project's front network, with the seeded E2E_* users
  local seeded=()
  [ ! -f "$work/e2e.env" ] || seeded=(--env-file "$work/e2e.env")
  docker run --rm --network "$(project_of "$1")_front" -e BASE_URL=http://edge:8080 -e MODE="$2" "${seeded[@]}" "$e2e_image" \
    >"$work/out/$3.out" 2>&1
}
# The JSON body of a login (written to a private file: no password in argv).
login_json() { # email password -> sets LOGIN (file)
  LOGIN=$work/login.json
  (umask 077 && printf '{"email":"%s","password":"%s"}' "$1" "$2" >"$LOGIN")
}
json_field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$BODY" "$1" 2>/dev/null; }

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
# sent in the query, headers or cookies are in neither, and neither is any
# other query value (search=, whose key does not look sensitive), nor the
# query of the Referer that the framework quotes for an unknown route.
get "$PA" '/api/v1/does-not-exist' -H 'Referer: https://crm.example.test/accounts?search=st40-referer-secret'
rid_nf=$(header X-Request-Id) code_nf=$CODE
get "$PA" '/api/v1/system/status?token=st40-query-secret&search=st40-search-secret' -H 'Authorization: Bearer st40-header-secret' \
  -H 'Cookie: sid=st40-cookie-secret' -H 'X-CSRF-Token: st40-csrf-secret'
rid=$(header X-Request-Id)
i=0
until { docker logs "$(cid "$A" api)" 2>&1 | grep -qF "\"request_id\":\"$rid\"" &&
  docker logs "$(cid "$A" api)" 2>&1 | grep -qF "\"request_id\":\"$rid_nf\""; } || [ "$i" -ge 10 ]; do sleep 1; i=$((i + 1)); done
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
! grep -qE 'st40-(query|search|header|cookie|csrf|referer)-secret' "$api_log" "$edge_log" && [ "$code_nf" = 404 ] &&
  grep -F "\"request_id\":\"$rid_nf\"" "$api_log" | grep -qF 'https://crm.example.test/accounts?[redacted]' &&
  grep -F "$rid_nf" "$edge_log" | grep -qF 'https://crm.example.test/accounts?[redacted]'
v "ST-43 query (token and search), Authorization, Cookie, CSRF and Referer query values are in no log" $? "$(grep -ohE '.{60}st40-[a-z]+-secret' "$api_log" "$edge_log" | head -n 3; grep -F "$rid_nf" "$api_log" | head -c 600)"

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

# --- authentication through the edge (FND-010B, ADR-019) --------------------

# Synthetic users and organizations, created with the operator console of
# the api container (passwords on standard input).
need "seed synthetic users and organizations with the operator console" seed_e2e "$work/e2e.env" "$(cid "$A" api)" && {
  # shellcheck disable=SC1091 # written by seed_e2e
  . "$work/e2e.env"
  origin=http://127.0.0.1:$PA

  login_json "$E2E_REP_EMAIL" "$E2E_PASSWORD"
  get "$PA" /api/v1/auth/login -X POST -H 'Content-Type: application/json' -H "Origin: $origin" --data-binary @"$LOGIN"
  cookie=$(header Set-Cookie)
  sid=${cookie#flowcrm_sid=}
  sid=${sid%%;*}
  token=$(json_field csrfToken)
  lc=$(printf '%s' "$cookie" | tr '[:upper:]' '[:lower:]')
  [ "$CODE" = 200 ] && case $lc in flowcrm_sid=*) true ;; *) false ;; esac &&
    case $lc in *'; path=/'*) true ;; *) false ;; esac && case $lc in *'; httponly'*) true ;; *) false ;; esac &&
    case $lc in *'; samesite=lax'*) true ;; *) false ;; esac && case $lc in *secure* | *domain=*) false ;; *) true ;; esac &&
    header Cache-Control | grep -q no-store && [ -n "$token" ] && [ "$(psql_in "$A" "SELECT count(*) FROM sessions WHERE sess_id = '$sid'")" = 1 ]
  v "ST-69 login through the edge: HttpOnly, SameSite=Lax, Path=/ session cookie (no Secure over HTTP), no-store, session in PostgreSQL" $? "$CODE $cookie"

  get "$PA" /api/v1/me -H "Cookie: flowcrm_sid=$sid"
  me=$CODE
  get "$PA" /api/v1/auth/logout -X POST -H "Cookie: flowcrm_sid=$sid" -H "Origin: $origin"
  forged=$CODE
  get "$PA" /api/v1/auth/logout -X POST -H "Cookie: flowcrm_sid=$sid" -H "Origin: $origin" -H "X-CSRF-Token: $token"
  out=$CODE
  get "$PA" /api/v1/me -H "Cookie: flowcrm_sid=$sid"
  [ "$me" = 200 ] && [ "$forged" = 403 ] && [ "$out" = 204 ] && [ "$CODE" = 401 ] &&
    [ "$(psql_in "$A" "SELECT count(*) FROM sessions WHERE sess_id = '$sid'")" = 0 ]
  v "ST-70 the cookie authenticates; logout needs the CSRF token and ends the session on the server (replay: 401)" $? "me $me, logout without token $forged, with token $out, replay $CODE"

  get "$PA" /api/v1/auth/login -X POST -H 'Content-Type: application/json' -H 'Origin: https://evil.example' --data-binary @"$LOGIN"
  cross=$CODE
  cross_cookie=$(header Set-Cookie)
  get "$PA" /api/v1/auth/login -X POST -H "Origin: $origin" --data-urlencode "email=$E2E_REP_EMAIL" --data-urlencode 'password=x'
  [ "$cross" = 403 ] && [ -z "$cross_cookie" ] && [ "$CODE" = 415 ]
  v "ST-71 login from another origin is refused before authentication (403, no cookie); a form body is refused (415)" $? "cross-origin $cross, form $CODE"

  # Through the real edge a client cannot pick its client IP: with a new
  # spoofed X-Forwarded-For on every attempt, the sixth failure for one
  # account is still refused (the edge replaces the header).
  login_json "spoof-$(random_secret | cut -c1-8)@example.test" 'not the password'
  codes=''
  for i in 1 2 3 4 5 6; do
    get "$PA" /api/v1/auth/login -X POST -H 'Content-Type: application/json' -H "Origin: $origin" -H "X-Forwarded-For: 203.0.113.$i" -H "X-Real-IP: 198.51.100.$i" --data-binary @"$LOGIN"
    codes="$codes $CODE"
  done
  [ "$codes" = ' 401 401 401 401 401 429' ] && [ -n "$(header Retry-After)" ] && body_has 'too-many-requests'
  v "ST-72 spoofed X-Forwarded-For through the edge does not evade the login limit (6th failure: 429 with Retry-After)" $? "codes:$codes"

  api_log=$(docker logs "$(cid "$A" api)" 2>&1)
  edge_log=$(docker logs "$(cid "$A" edge)" 2>&1)
  ! printf '%s\n%s\n' "$api_log" "$edge_log" | grep -qF -e "$E2E_PASSWORD" -e "$E2E_REP_EMAIL" -e "$sid" -e "$token" &&
    printf '%s\n' "$api_log" | grep -q '"event":"login_failed"' && printf '%s\n' "$api_log" | grep -q '"event":"login_succeeded"'
  v "ST-73 the security log records the logins with pseudonyms; no password, e-mail address, session ID or CSRF token in any log" $?
}

need "build the browser test image" docker build --quiet -f "$APP_REPO/docker/e2e/Dockerfile" -t "$e2e_image" "$APP_REPO" >/dev/null && {
  browser "$A" dev a-browser
  r=$?
  [ "$r" = 0 ] || tail -n 25 "$work/out/a-browser.out" | sed 's/^/      | /'
  [ "$r" = 0 ] && grep -Eq '[0-9]+ passed' "$work/out/a-browser.out" && ! grep -Eq '[0-9]+ failed' "$work/out/a-browser.out" &&
    grep -q 'Vite HMR connection is established' "$work/out/a-browser.out" && grep -q 'logout ends the session' "$work/out/a-browser.out" &&
    ! grep -Eq '[0-9]+ skipped' "$work/out/a-browser.out"
  v "ST-16 browser journeys through Caddy: login page with API data, client route, login and logout, roles, two organizations, foreign organization, CSRF, HMR (dev)" $?
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
  until_ready "$PA" 000 5 && dv a-status-existing "$A" status && grep -q '^blocked: *applying database migrations' "$work/out/a-status-existing.out"
v "ST-45 an existing cache_items table stops make up without changes; the saved state is kept; the stack stays blocked (the migration phase is protected)" $? "$(tail -n 3 "$work/out/a-up-existing.err")"
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

# Privilege drift on a stack that is already serving fails closed (FND-009V
# F-01): the gate stops the edge, so nothing is served; make status and make
# url report the block; the database and the saved port are kept; make up
# serves again once the drift is removed.
get "$PA" /health/ready
drift_before=$CODE
psql_as_in "$A" flowcrm_owner "GRANT TRUNCATE ON users TO flowcrm_app" >/dev/null
dv a-up-drift "$A" up
get "$PA" /health/ready
drift_code=$CODE
dv a-status-drift "$A" status
dv a-url-drift "$A" url
drift_db=$(docker inspect -f '{{.State.Running}}' "$(cid "$A" db)" 2>/dev/null)
psql_as_in "$A" flowcrm_owner "REVOKE TRUNCATE ON users FROM flowcrm_app" >/dev/null
dv a-up-nodrift "$A" up
[ "$drift_before" = 200 ] && [ "$(rc_of a-up-drift)" = 6 ] && err_has a-up-drift 'VIOLATION: table users' &&
  err_has a-up-drift 'stopped the edge' && err_has a-up-drift 'the stack is not served' && [ "$drift_code" = 000 ] &&
  [ "$(rc_of a-status-drift)" = 1 ] && grep -q '^blocked: ' "$work/out/a-status-drift.out" &&
  [ "$(rc_of a-url-drift)" = 1 ] && err_has a-url-drift 'blocked by the security gate' &&
  [ "$drift_db" = true ] && [ "$(saved_port "$A")" = "$PA" ] &&
  [ "$(rc_of a-up-nodrift)" = 0 ] && until_ready "$PA" 200 10 && [ ! -e "$A/.runtime/gate/security-gate" ]
v "ST-48 privilege drift on a running stack: make up exits 6 and stops the edge (no request served, status and url blocked, db and port kept); after the fix make up serves again" $? "before=$drift_before during=$drift_code $(grep -m1 VIOLATION "$work/out/a-up-drift.err")"

# A missing or malformed role secret of an existing volume fails closed and
# is never regenerated by make up, not even when the caller's environment
# sets the former switch (FND-009V F-02).
mv "$sd/db_app_password" "$work/db_app_password.kept"
dv a-up-nosecret "$A" up
(export ALLOW_ROLE_SECRETS=1 && dv a-up-nosecret-env "$A" up)
nosecret=$( [ ! -e "$sd/db_app_password" ] && echo absent)
mv "$work/db_app_password.kept" "$sd/db_app_password"
cp -p "$sd/db_owner_password" "$work/db_owner_password.kept"
chmod 0644 "$sd/db_owner_password" && printf 'short' >"$sd/db_owner_password"
dv a-up-badsecret "$A" up
mv -f "$work/db_owner_password.kept" "$sd/db_owner_password"
dv a-up-secrets-back "$A" up
[ "$(rc_of a-up-nosecret)" = 6 ] && [ "$(rc_of a-up-nosecret-env)" = 6 ] && [ "$nosecret" = absent ] &&
  err_has a-up-nosecret 'make db-upgrade-roles' && err_has a-up-nosecret-env 'so none was generated' &&
  [ "$(rc_of a-up-badsecret)" = 6 ] && err_has a-up-badsecret 'db_owner_password is malformed' &&
  [ "$(rc_of a-up-secrets-back)" = 0 ] && until_ready "$PA" 200 10
v "ST-49 missing or malformed role secrets of an existing volume: refused (exit 6), never regenerated, also with ALLOW_ROLE_SECRETS=1 in the environment" $?

# --- development rotation of the role passwords (ADR-018, FND-009V F-03) -----
# Each phase boundary is interrupted with a real SIGTERM (FLOWCRM_DEVENV_FAULT)
# and recovered with the documented commands; every check is a SCRAM login
# over TCP inside the db container, never just the presence of a file.
rot() { # label role [fault] [command]
  (cd "$A" && ROLE=$2 FLOWCRM_DEVENV_FAULT=${3-} ./bin/devenv "${4:-rotate-db-password}") >"$work/out/$1.out" 2>"$work/out/$1.err"
  echo $? >"$work/out/$1.rc"
}
login_ok() { # role password-file: SCRAM login as flowcrm_<role>
  [ -s "$2" ] && docker exec -e PGPASSWORD="$(cat "$2")" "$(cid "$A" db)" \
    sh -c 'psql -X -w -h "$(hostname -i | cut -d" " -f1)" -U "flowcrm_$0" -d flowcrm -tAc "SELECT 1"' "$1" 2>/dev/null | grep -qx 1
}
no_leftovers() { [ -z "$(find "$sd" -name '.*' -type f ! -name '.db_*_password.pending')" ]; }
pend() { printf '%s/.db_%s_password.pending' "$sd" "$1"; }
# Diagnostics for a failed check, never a secret value: container identity
# (ID, start time, restart count) of db and api, and whether each mounted
# role secret equals the host file (same, different or missing).
lifecycle() { # -> one line
  local svc id name host inside out=''
  for svc in db api; do
    id=$(cid "$A" "$svc")
    if [ -z "$id" ]; then out="$out $svc=none"; continue; fi
    out="$out $svc=$(docker inspect -f '{{printf "%.12s" .Id}}@{{.State.StartedAt}}/restarts={{.RestartCount}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$id")"
    for name in db_app_password db_owner_password; do
      host=$(sha256sum "$sd/$name" 2>/dev/null || shasum -a 256 "$sd/$name" 2>/dev/null)
      inside=$(docker exec "$id" sha256sum "/run/secrets/$name" 2>/dev/null) || { out="$out:$name=missing"; continue; }
      [ "${host%% *}" = "${inside%% *}" ] && out="$out:$name=same" || out="$out:$name=different"
    done
  done
  printf '%s\n' "${out# }"
}

# Interrupted after the pending password was written: the database still
# has the current one, the stack keeps serving; running the command again
# finishes the rotation.
cp -p "$sd/db_app_password" "$work/app.0"
rot a-rot1 app rotate-after-pending
r1_pending=$(perm "$(pend app)")
r1_current=$(login_ok app "$sd/db_app_password" && echo ok)
get "$PA" /health/ready
r1_ready=$CODE
rot a-rot1b app
[ "$(rc_of a-rot1)" = 143 ] && [ "$r1_pending" = 600 ] && [ "$r1_current" = ok ] && [ "$r1_ready" = 200 ] &&
  [ "$(rc_of a-rot1b)" = 0 ] && err_has a-rot1b 'resuming the unfinished rotation' && [ ! -e "$(pend app)" ] &&
  ! cmp -s "$sd/db_app_password" "$work/app.0" && login_ok app "$sd/db_app_password" && ! login_ok app "$work/app.0" &&
  [ "$(perm "$sd/db_app_password")" = 444 ] && no_leftovers && until_ready "$PA" 200 30
v "ST-50 rotation interrupted after the pending password (SIGTERM): the current password keeps working; running it again finishes it (new password logs in, old refused)" $? "$(tail -n 2 "$work/out/a-rot1b.err")"

# Interrupted after the database got the new password, before the file was
# replaced: the abort gives the database the current password back.
cp -p "$sd/db_app_password" "$work/app.1"
rot a-rot2 app rotate-after-db
r2_db=$(login_ok app "$(pend app)" && echo pending)
r2_old=$(login_ok app "$sd/db_app_password" && echo current)
rot a-rot2a app '' rotate-db-password-abort
[ "$(rc_of a-rot2)" = 143 ] && [ "$r2_db" = pending ] && [ -z "$r2_old" ] &&
  [ "$(rc_of a-rot2a)" = 0 ] && err_has a-rot2a 'aborted the rotation' && [ ! -e "$(pend app)" ] &&
  cmp -s "$sd/db_app_password" "$work/app.1" && login_ok app "$sd/db_app_password" && no_leftovers && until_ready "$PA" 200 30
v "ST-50 rotation interrupted after the database change (SIGTERM): the abort restores the current password (SCRAM login checked) and the stack serves" $? "$(tail -n 2 "$work/out/a-rot2a.err")"

# Interrupted after the file was replaced, before the api was recreated: the
# running api still mounts the replaced file; make up recreates it.
rot a-rot3 app rotate-after-promote
r3_seen=$(docker exec "$(cid "$A" api)" sh -c 'cat /run/secrets/db_app_password 2>/dev/null' || true)
if [ -z "$r3_seen" ]; then r3_mount=missing; elif [ "$r3_seen" = "$(cat "$sd/db_app_password")" ]; then r3_mount=new; else r3_mount=old; fi
dv a-up-rot3 "$A" up
[ "$(rc_of a-rot3)" = 143 ] && [ ! -e "$(pend app)" ] && login_ok app "$sd/db_app_password" &&
  [ "$(rc_of a-up-rot3)" = 0 ] && err_has a-up-rot3 'recreating api: its secret files changed' && until_ready "$PA" 200 30 &&
  console_in "$A" app:database:verify-privileges --runtime
v "ST-50 rotation interrupted after the file replacement (SIGTERM): make up recreates the api that still mounts the replaced file, and it logs in" $? "mount=$r3_mount $(tail -n 2 "$work/out/a-up-rot3.err")"
say "      INFO  a running container saw a secret file replaced on the host as: $r3_mount ($(docker info --format '{{.OperatingSystem}}' 2>/dev/null))"

# Owner rotation, interrupted after the database change and resumed; the
# migrate job proves the login, the old owner password is refused.
cp -p "$sd/db_owner_password" "$work/owner.0"
rot a-rot4 owner rotate-after-db
rot a-rot4b owner
[ "$(rc_of a-rot4)" = 143 ] && [ "$(rc_of a-rot4b)" = 0 ] && [ ! -e "$(pend owner)" ] &&
  login_ok owner "$sd/db_owner_password" && ! login_ok owner "$work/owner.0" &&
  owner_console_in "$A" doctrine:migrations:up-to-date && no_leftovers
v "ST-50 owner rotation interrupted after the database change and resumed: the migrate job logs in with the new password, the old one is refused" $? "$(tail -n 2 "$work/out/a-rot4b.err")"

# Repeated rotations, and a failed recreation of the api (it does not get
# healthy): the rotation reports it; after the cause is fixed, make up serves.
cp -p "$sd/db_app_password" "$work/app.2"
r5_before=$(lifecycle)
rot a-rot5 app
r5_after=$(lifecycle)
cp -p "$sd/db_app_password" "$work/app.3"
cp -p "$A/backend/public/index.php" "$work/index.php.kept"
printf '<?php syntax error\n' >"$A/backend/public/index.php"
r6_before=$(lifecycle)
api_id() { printf '%s' "$1" | sed -n 's/.*api=\([0-9a-f]*\)@.*/\1/p'; }
(cd "$A" && ROLE=app FLOWCRM_WAIT_TIMEOUT=20 ./bin/devenv rotate-db-password) >"$work/out/a-rot6.out" 2>"$work/out/a-rot6.err"
echo $? >"$work/out/a-rot6.rc"
r6_after=$(lifecycle)
get "$PA" /health/live
r6_edge=$CODE
dv a-status-rot6 "$A" status
cp -p "$work/index.php.kept" "$A/backend/public/index.php"
dv a-up-rot6 "$A" up
# The api was replaced (the recreation was attempted), but it never got
# healthy: the rotation fails whatever Compose's exit status says, the stack
# stays blocked and the edge does not serve until make up succeeds.
[ "$(rc_of a-rot5)" = 0 ] && ! cmp -s "$work/app.2" "$work/app.3" && [ "$(rc_of a-rot6)" = 2 ] &&
  err_has a-rot6 'recreating api with the current secret files failed' && ! cmp -s "$work/app.3" "$sd/db_app_password" &&
  [ -n "$(api_id "$r6_before")" ] && [ -n "$(api_id "$r6_after")" ] && [ "$(api_id "$r6_before")" != "$(api_id "$r6_after")" ] && [ "$r6_edge" = 000 ] &&
  [ "$(rc_of a-status-rot6)" = 1 ] && grep -q '^blocked: ' "$work/out/a-status-rot6.out" &&
  login_ok app "$sd/db_app_password" && [ "$(rc_of a-up-rot6)" = 0 ] && until_ready "$PA" 200 30 &&
  console_in "$A" app:database:verify-privileges --runtime && no_leftovers
v "ST-50 repeated rotations; a failed api recreation is reported (exit 2) and make up serves once the cause is fixed" $? \
  "rotation 5 exit $(rc_of a-rot5), rotation 6 exit $(rc_of a-rot6), make up exit $(rc_of a-up-rot6)
      before 5: $r5_before
      after 5:  $r5_after
      before 6: $r6_before
      after 6:  $r6_after
$(sed 's/^/      | /' "$work/out/a-rot5.err" | tail -n 15)
$(sed 's/^/      | /' "$work/out/a-rot6.err" | tail -n 25)"
# Always recorded (no values): which containers each rotation recreated.
ev "rotation 5: $(grep -E '^devenv: (recreating|rotated|the edge|WARNING|ERROR)' "$work/out/a-rot5.err" | sed 's/^devenv: //; s/ (.*//' | paste -sd ';' -)"
ev "rotation 6: $(grep -E '^devenv: (recreating|rotated|the edge|WARNING|ERROR)' "$work/out/a-rot6.err" | sed 's/^devenv: //; s/ (.*//' | paste -sd ';' -)"
ev "api before/after 6: ${r6_before#* api=} -> ${r6_after#* api=}"

# A rotation that passes every check, but whose edge cannot get ready again
# (FND-009E): the owner rotation recreates only the db, so the api keeps the
# broken index.php and the edge's health check through it fails. The
# command fails (exit 2) instead of warning, the started edge is stopped, the
# stack is blocked again, and make up serves once the cause is fixed.
printf '<?php syntax error\n' >"$A/backend/public/index.php"
(cd "$A" && ROLE=owner FLOWCRM_WAIT_TIMEOUT=20 ./bin/devenv rotate-db-password) >"$work/out/a-rot7.out" 2>"$work/out/a-rot7.err"
echo $? >"$work/out/a-rot7.rc"
r7_edge_ps=$(docker ps -q --filter "label=com.docker.compose.project=$(project_of "$A")" --filter label=com.docker.compose.service=edge)
get "$PA" /
r7_code=$CODE
dv a-status-rot7 "$A" status
cp -p "$work/index.php.kept" "$A/backend/public/index.php"
# The api turned unhealthy while index.php was broken; make up's wait fails
# fast on an unhealthy container, so give its health check time to recover.
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid "$A" api)" 2>/dev/null)" = healthy ] || [ "$i" -ge 60 ]; do sleep 1; i=$((i + 1)); done
dv a-up-rot7 "$A" up
[ "$(rc_of a-rot7)" = 2 ] && err_has a-rot7 'rotated the password of flowcrm_owner' &&
  err_has a-rot7 'was rotated and verified, but the edge did not serve again' && [ -z "$r7_edge_ps" ] && [ "$r7_code" = 000 ] &&
  [ "$(rc_of a-status-rot7)" = 1 ] && grep -q '^blocked: .*did not serve again' "$work/out/a-status-rot7.out" &&
  [ "$(rc_of a-up-rot7)" = 0 ] && until_ready "$PA" 200 30 && no_leftovers
v "ST-50 a verified rotation whose edge cannot get ready fails (exit 2): the started edge is stopped, nothing is served, the stack is blocked; make up serves once fixed" $? \
  "rotation exit $(rc_of a-rot7), edge container [$r7_edge_ps], GET / $r7_code, make up exit $(rc_of a-up-rot7)
$(sed 's/^/      | /' "$work/out/a-rot7.err" | tail -n 12)
$(sed 's/^/      | /' "$work/out/a-status-rot7.out" | head -n 3)"

# The security gate is enforced by the running edge itself (FND-009E): while
# .runtime/gate/security-gate exists, every request but exactly /health/live
# and /health/ready is answered with the gate's 503 (raw URI, as ADR-017).
gate_probe() { # -> "path=code ..." for the paths that matter
  local out='' p
  for p in / /api/v1/system/status /health/live /health/ready /HEALTH/READY //health/ready /health/readyz /health/ready/x; do
    out="$out $p=$(curl -s -o /dev/null -m 5 -w '%{http_code}' --path-as-is "http://127.0.0.1:$PA$p")"
  done
  printf '%s' "${out# }"
}
GATED="/=503 /api/v1/system/status=503 /health/live=200 /health/ready=200 /HEALTH/READY=503 //health/ready=503 /health/readyz=503 /health/ready/x=503"
OPEN="/=200 /api/v1/system/status=200 /health/live=200 /health/ready=200 /HEALTH/READY=200 //health/ready=200 /health/readyz=200 /health/ready/x=200"
probe_until() { # expected [seconds]: poll (a bind mount can show a change a moment late)
  local i=0
  PROBE=$(gate_probe)
  while [ "$PROBE" != "$1" ] && [ "$i" -lt "${2:-10}" ]; do sleep 1; i=$((i + 1)); PROBE=$(gate_probe); done
  [ "$PROBE" = "$1" ]
}
printf 'a gate recorded by the test\n' >"$A/.runtime/gate/security-gate"
chmod 0644 "$A/.runtime/gate/security-gate"
probe_until "$GATED"
g_on=$PROBE
g_body=$(curl -s -m 5 "http://127.0.0.1:$PA/")
rm -f "$A/.runtime/gate/security-gate"
probe_until "$OPEN"
g_off=$PROBE
[ "$g_on" = "$GATED" ] && case $g_body in *"blocked by its security gate"*) true ;; *) false ;; esac && [ "$g_off" = "$OPEN" ]
v "ST-50 the running edge enforces the gate: only /health/live and /health/ready pass while it is recorded, everything serves once it is removed" $? "gated: $g_on; open: $g_off"

# Interrupted while the edge comes back after a verified rotation: the gate
# is cleared only once the edge answers readiness, so whatever kills the
# command leaves the gate recorded, and the edge (if it already started)
# serves nothing but its health paths. make up reconciles and serves.
interrupted_restore() { # label fault expected-exit
  (cd "$A" && ROLE=owner FLOWCRM_DEVENV_FAULT=$2 ./bin/devenv rotate-db-password) >"$work/out/$1.out" 2>"$work/out/$1.err"
  echo $? >"$work/out/$1.rc"
  IR_EDGE=$(docker ps -q --filter "label=com.docker.compose.project=$(project_of "$A")" --filter label=com.docker.compose.service=edge)
  IR_PROBE=$(gate_probe)
  dv "$1-status" "$A" status
  IR_GATE=$([ -f "$A/.runtime/gate/security-gate" ] && echo recorded || echo absent)
  dv "$1-up" "$A" up
  [ "$(rc_of "$1")" = "$3" ] && [ "$IR_GATE" = recorded ] && [ "$(rc_of "$1-status")" = 1 ] && grep -q '^blocked: ' "$work/out/$1-status.out" &&
    [ "$(rc_of "$1-up")" = 0 ] && until_ready "$PA" 200 30 && [ ! -e "$A/.runtime/gate/security-gate" ] && probe_until "$OPEN"
}
interrupted_restore a-ir-kill edge-started:kill 137
r=$?
[ "$r" = 0 ] && [ -n "$IR_EDGE" ] && [ "$IR_PROBE" = "$GATED" ]
v "ST-50 SIGKILL right after the edge started again: the gate stays recorded, the running edge serves only its health paths, make up serves" $? "exit $(rc_of a-ir-kill), edge [$IR_EDGE], gate $IR_GATE, probe: $IR_PROBE, make up $(rc_of a-ir-kill-up)"
interrupted_restore a-ir-int edge-started:int 130
r=$?
[ "$r" = 0 ] && [ -n "$IR_EDGE" ] && [ "$IR_PROBE" = "$GATED" ]
v "ST-50 SIGINT right after the edge started again: the gate stays recorded, nothing but the health paths is served, make up serves" $? "exit $(rc_of a-ir-int), edge [$IR_EDGE], gate $IR_GATE, probe: $IR_PROBE, make up $(rc_of a-ir-int-up)"
interrupted_restore a-ir-term restore-before-edge 143
r=$?
[ "$r" = 0 ] && [ -z "$IR_EDGE" ] && [ "$IR_PROBE" = "/=000 /api/v1/system/status=000 /health/live=000 /health/ready=000 /HEALTH/READY=000 //health/ready=000 /health/readyz=000 /health/ready/x=000" ]
v "ST-50 SIGTERM before the edge started again: the gate stays recorded, nothing listens, make up serves" $? "exit $(rc_of a-ir-term), edge [$IR_EDGE], gate $IR_GATE, probe: $IR_PROBE, make up $(rc_of a-ir-term-up)"

# An edge created without the gate directory (by bin/devenv before
# FND-009E, or by a plain docker compose up) does not enforce the gate:
# make up recreates it instead of reporting it as already running.
gate_src() { docker inspect -f '{{range .Mounts}}{{if eq .Destination "/run/flowcrm-gate"}}{{.Source}}{{end}}{{end}}' "$(cid "$A" edge)" 2>/dev/null; }
(cd "$A" && FLOWCRM_HTTP_PORT=$PA COMPOSE_PROFILES=dev,migrate docker compose --project-name "$(project_of "$A")" up --detach --no-deps --force-recreate edge) >"$work/out/a-legacy-edge.out" 2>&1
until_ready "$PA" 200 30
legacy_src=$(gate_src)
dv a-up-legacy "$A" up
new_src=$(gate_src)
printf 'a gate recorded by the test\n' >"$A/.runtime/gate/security-gate"
chmod 0644 "$A/.runtime/gate/security-gate"
probe_until "$GATED"
legacy_probe=$PROBE
rm -f "$A/.runtime/gate/security-gate"
probe_until "$OPEN"
[ "$(rc_of a-up-legacy)" = 0 ] && case $legacy_src in */docker/edge/no-gate) true ;; *) false ;; esac &&
  case $new_src in *"$A/.runtime/gate") true ;; *) false ;; esac && err_has a-up-legacy 'does not mount .runtime/gate' &&
  [ "$legacy_probe" = "$GATED" ] && [ "$PROBE" = "$OPEN" ] && [ "$(saved_port "$A")" = "$PA" ]
v "ST-50 an edge created without the gate directory is recreated by make up and then enforces the gate" $? "make up $(rc_of a-up-legacy), mount before [$legacy_src] after [$new_src], gated probe: $legacy_probe; open: $PROBE
$(sed 's/^/      | /' "$work/out/a-up-legacy.err" | tail -n 5)"

# Interrupted while the password change waits inside PostgreSQL (another
# session holds the operations' advisory lock): the interrupted transaction
# is ended before the command exits, and nothing commits later.
docker exec -d -e PGAPPNAME=st-holder "$(cid "$A" db)" psql -U flowcrm -d flowcrm -c 'SELECT pg_advisory_lock(1179796833)' -c 'SELECT pg_sleep(120)'
cp -p "$sd/db_app_password" "$work/app.4"
(cd "$A" && ROLE=app exec ./bin/devenv rotate-db-password) >"$work/out/a-rot7.out" 2>"$work/out/a-rot7.err" &
rot7=$!
i=0
until [ "$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%' AND wait_event = 'advisory'")" = 1 ] || [ "$i" -ge 120 ]; do sleep 0.5; i=$((i + 1)); done
r7_waiting=$i
kill -TERM "$rot7"
wait "$rot7"
r7_rc=$?
r7_left=$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")
psql_in "$A" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'st-holder'" >/dev/null
sleep 3
r7_current=$(login_ok app "$sd/db_app_password" && echo ok)
rot a-rot7a app '' rotate-db-password-abort
[ "$r7_waiting" -lt 120 ] && [ "$r7_rc" = 143 ] && grep -q 'the interrupted database operation ended' "$work/out/a-rot7.err" &&
  [ "$r7_left" = 0 ] && [ "$r7_current" = ok ] && cmp -s "$sd/db_app_password" "$work/app.4" &&
  [ "$(rc_of a-rot7a)" = 0 ] && login_ok app "$sd/db_app_password" && no_leftovers && until_ready "$PA" 200 30
v "ST-50 rotation interrupted while its transaction waits on a PostgreSQL lock: the session is ended before exit, no delayed commit, the abort restores a clean state" $? "rc=$r7_rc left=$r7_left current=$r7_current $(tail -n 2 "$work/out/a-rot7.err")"

# --- unconfirmed cancellation (FND-009G) --------------------------------------
# The cancellation of an interrupted operation cannot always be confirmed
# (here: the db container is paused, so nothing can be executed in it). The
# stack must then stay blocked, and the next command must end the old
# operation, or find it finished, before it changes anything.
holder_up() { docker exec -d -e PGAPPNAME=st-holder "$(cid "$A" db)" psql -U flowcrm -d flowcrm -c 'SELECT pg_advisory_lock(1179796833)' -c 'SELECT pg_sleep(300)'; }
holder_down() { psql_in "$A" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'st-holder'" >/dev/null; }
waiting_op() { # seconds: until a role operation waits for the advisory lock
  local i=0
  until [ "$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%' AND wait_event = 'advisory'")" = 1 ] || [ "$i" -ge $(($1 * 2)) ]; do sleep 0.5; i=$((i + 1)); done
  [ "$i" -lt $(($1 * 2)) ]
}
db_healthy() { local i=0; until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(cid "$A" db)" 2>/dev/null)" = healthy ] || [ "$i" -ge 120 ]; do sleep 1; i=$((i + 1)); done; }
paused_interrupt() { # label: rotation blocked on the advisory lock, db paused, SIGTERM
  holder_up
  (cd "$A" && ROLE=app exec ./bin/devenv rotate-db-password) >"$work/out/$1.out" 2>"$work/out/$1.err" &
  local p=$!
  waiting_op 60
  OLD_OP=$(psql_in "$A" "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")
  docker pause "$(cid "$A" db)" >/dev/null
  kill -TERM "$p"
  wait "$p"
  echo $? >"$work/out/$1.rc"
  get "$PA" /health/live
  PAUSED_EDGE=$CODE
  dv "$1-status" "$A" status
  dv "$1-url" "$A" url
  docker unpause "$(cid "$A" db)" >/dev/null
  db_healthy
}

# The new make up ends the old operation; it never commits.
cp -p "$sd/db_app_password" "$work/app.5"
paused_interrupt a-unconf
u_old=$OLD_OP
(cd "$A" && exec ./bin/devenv up) >"$work/out/a-unconf-up.out" 2>"$work/out/a-unconf-up.err" &
upp=$!
i=0
until [ "$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE pid = $u_old")" = 0 ] || [ "$i" -ge 120 ]; do sleep 0.5; i=$((i + 1)); done
u_ended=$i
holder_down
wait "$upp"
u_up=$?
[ "$(rc_of a-unconf)" = 143 ] && err_has a-unconf 'could not confirm that the interrupted database operation ended' &&
  err_has a-unconf 'stopped the edge' && [ "$PAUSED_EDGE" = 000 ] && [ "$(rc_of a-unconf-status)" = 1 ] &&
  grep -q '^blocked: .*could not be confirmed' "$work/out/a-unconf-status.out" && [ "$(rc_of a-unconf-url)" = 1 ] &&
  [ "$u_ended" -lt 120 ] && [ "$u_up" = 0 ] && login_ok app "$sd/db_app_password" && ! login_ok app "$(pend app)" &&
  cmp -s "$sd/db_app_password" "$work/app.5" && until_ready "$PA" 200 30 && [ ! -e "$A/.runtime/gate/security-gate" ]
v "ST-59 unconfirmed cancellation (db paused): the stack is blocked (edge stopped, status and url refuse); the next make up ends the old operation before changing anything, and it never commits" $? "rc=$(rc_of a-unconf) edge=$PAUSED_EDGE ended=$u_ended up=$u_up $(tail -n 1 "$work/out/a-unconf-up.err")"
rot a-unconf-abort app '' rotate-db-password-abort

# The old operation commits before any newer command runs: the next make up
# finds the database and the files disagree and stays blocked; finishing the
# rotation restores a consistent state.
paused_interrupt a-unconf2
holder_down
sleep 3
c_pending=$(login_ok app "$(pend app)" && echo committed)
dv a-unconf2-up "$A" up
get "$PA" /health/ready
c_code=$CODE
rot a-unconf2-finish app
dv a-unconf2-up2 "$A" up
[ "$(rc_of a-unconf2)" = 143 ] && [ "$c_pending" = committed ] && [ "$(rc_of a-unconf2-up)" = 6 ] && [ "$c_code" = 000 ] &&
  [ "$(rc_of a-unconf2-finish)" = 0 ] && [ "$(rc_of a-unconf2-up2)" = 0 ] && login_ok app "$sd/db_app_password" &&
  until_ready "$PA" 200 30 && no_leftovers
v "ST-59 unconfirmed cancellation whose operation later commits: make up stays blocked (exit 6, edge stopped); finishing the rotation and make up restore a consistent, served stack" $? "pending=$c_pending up=$(rc_of a-unconf2-up) code=$c_code"

# Cancellation times out although the database is reachable: the old
# operation's psql client is stopped (SIGSTOP), so its script cannot end.
# The command reports it, the stack is blocked, and a new rotation refuses
# to change anything until the old operation ended.
holder_up
(cd "$A" && ROLE=app exec ./bin/devenv rotate-db-password) >"$work/out/a-ctimeout.out" 2>"$work/out/a-ctimeout.err" &
ctp=$!
waiting_op 60
cpid=$(docker exec "$(cid "$A" db)" sh -c 'for p in /proc/[0-9]*; do tr "\0" "\n" <"$p/environ" 2>/dev/null | grep -q "^PGAPPNAME=flowcrm-db-roles:" && tr "\0" " " <"$p/cmdline" | grep -q "^psql " && echo "${p#/proc/}"; done' | head -n 1)
docker exec "$(cid "$A" db)" kill -STOP "$cpid"
kill -TERM "$ctp"
wait "$ctp"
ct_rc=$?
rot a-ctimeout-next app
docker exec "$(cid "$A" db)" kill -CONT "$cpid"
holder_down
sleep 3
ct_db=$(login_ok app "$sd/db_app_password" && echo current)
rot a-ctimeout-abort app '' rotate-db-password-abort
dv a-ctimeout-up "$A" up
[ -n "$cpid" ] && [ "$ct_rc" = 143 ] && grep -q 'could not confirm .*(exit 14)' "$work/out/a-ctimeout.err" &&
  [ "$(rc_of a-ctimeout-next)" = 6 ] && err_has a-ctimeout-next 'an earlier operation is still running' && [ "$ct_db" = current ] &&
  [ "$(rc_of a-ctimeout-abort)" = 0 ] && [ "$(rc_of a-ctimeout-up)" = 0 ] && until_ready "$PA" 200 30 && no_leftovers
v "ST-60 cancellation timeout with the database reachable: reported (exit 14), stack blocked; a new rotation refuses (earlier operation still running, nothing changed); recovery after the old one ended" $? "client=$cpid rc=$ct_rc next=$(rc_of a-ctimeout-next) $(tail -n 1 "$work/out/a-ctimeout-next.err")"

# A session outside the role script holds the operations' advisory lock: the
# role check does not wait forever; make up fails closed (edge stopped) and
# serves again once the session ended.
holder_up
sleep 1
dv a-holder-up "$A" up
get "$PA" /health/ready
h_code=$CODE
holder_down
dv a-holder-up2 "$A" up
[ "$(rc_of a-holder-up)" != 0 ] && err_has a-holder-up 'lock timeout' && [ "$h_code" = 000 ] &&
  [ "$(rc_of a-holder-up2)" = 0 ] && until_ready "$PA" 200 30
v "ST-61 a foreign holder of the advisory lock: make up does not wait forever (lock timeout), stays blocked, and serves after the holder ended" $? "rc=$(rc_of a-holder-up) code=$h_code"

# --- SIGKILL of bin/devenv during privileged changes (FND-009G2) ---------------
# A killed command runs no handler, so the stack must already be protected
# when the change starts: the edge is stopped and the security gate is
# recorded before any role, password, ownership or grant changes.
blocked_now() { # label: make status and make url report the gate
  dv "$1-status" "$A" status
  dv "$1-url" "$A" url
  [ "$(rc_of "$1-status")" = 1 ] && grep -q '^blocked: ' "$work/out/$1-status.out" && [ "$(rc_of "$1-url")" = 1 ] &&
    err_has "$1-url" 'blocked by the security gate'
}
killed_rotation() { # label: rotation blocked on the advisory lock, then SIGKILL -> sets K_EDGE (while blocked), K_OLD (pid)
  holder_up
  (cd "$A" && ROLE=app exec ./bin/devenv rotate-db-password) >"$work/out/$1.out" 2>"$work/out/$1.err" &
  local p=$!
  waiting_op 60
  K_OLD=$(psql_in "$A" "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")
  get "$PA" /health/ready
  K_EDGE=$CODE
  kill -KILL "$p"
  wait "$p"
  echo $? >"$work/out/$1.rc"
}

# Killed while ALTER ROLE ... PASSWORD waits: the edge was already stopped.
# The killed command's docker compose exec outlives it, so the checkout
# lock stays held and the newer command (the abort) waits instead of
# overlapping; the old operation ends by its lock timeout (rolled back,
# never committed); then the abort runs and the edge serves again.
get "$PA" /health/ready
k_before=$CODE
cp -p "$sd/db_app_password" "$work/app.6"
killed_rotation a-kill1
k1_edge=$K_EDGE
k1_blocked=$(blocked_now a-kill1 && echo yes)
k1_alive=$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE pid = $K_OLD")
(cd "$A" && ROLE=app FLOWCRM_LOCK_WAIT=300 exec ./bin/devenv rotate-db-password-abort) >"$work/out/a-kill1-abort.out" 2>"$work/out/a-kill1-abort.err" &
abp=$!
i=0
until [ "$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE pid = $K_OLD")" = 0 ] || [ "$i" -ge 400 ]; do sleep 0.5; i=$((i + 1)); done
k1_waited=$(grep -c 'waiting for another devenv command' "$work/out/a-kill1-abort.err")
holder_down
wait "$abp"
k1_abort=$?
[ "$k_before" = 200 ] && [ "$k1_edge" = 000 ] && [ "$(rc_of a-kill1)" = 137 ] && [ "$k1_blocked" = yes ] && [ "$k1_alive" = 1 ] &&
  [ "$i" -lt 400 ] && [ "$k1_waited" = 1 ] && [ "$k1_abort" = 0 ] && login_ok app "$sd/db_app_password" && ! login_ok app "$(pend app)" &&
  cmp -s "$sd/db_app_password" "$work/app.6" && until_ready "$PA" 200 30 && [ ! -e "$A/.runtime/gate/security-gate" ]
v "ST-62 SIGKILL while ALTER ROLE PASSWORD waits: the edge was already stopped (200 -> 000), status and url blocked; the abort waits for the old operation (no overlap), which rolls back and never commits; the abort then serves again" $? "before=$k_before during=$k1_edge rc=$(rc_of a-kill1) blocked=$k1_blocked alive=$k1_alive waited=$k1_waited/$i abort=$k1_abort"

# Killed, and the old operation commits before a newer command runs: the
# stack stays blocked; finishing the rotation serves again.
killed_rotation a-kill2
holder_down
sleep 3
k2_committed=$(login_ok app "$(pend app)" && echo committed)
get "$PA" /health/ready
k2_code=$CODE
k2_blocked=$(blocked_now a-kill2b && echo yes)
rot a-kill2-finish app
[ "$K_EDGE" = 000 ] && [ "$(rc_of a-kill2)" = 137 ] && [ "$k2_committed" = committed ] && [ "$k2_code" = 000 ] && [ "$k2_blocked" = yes ] &&
  [ "$(rc_of a-kill2-finish)" = 0 ] && login_ok app "$sd/db_app_password" && until_ready "$PA" 200 30 && no_leftovers &&
  [ ! -e "$A/.runtime/gate/security-gate" ]
v "ST-63 SIGKILL during a rotation whose password change commits later: no edge and blocked throughout; finishing the rotation serves again" $? "committed=$k2_committed code=$k2_code blocked=$k2_blocked"

# Killed after the change committed, before it was verified: a rotation
# (after the database change) and make up (after the migrations).
rot a-kill3 app rotate-after-db:kill
get "$PA" /health/ready
k3_code=$CODE
k3_blocked=$(blocked_now a-kill3 && echo yes)
rot a-kill3-finish app
cat >"$A/backend/migrations/Version20991231000002.php" <<'PHP'
<?php

declare(strict_types=1);

namespace DoctrineMigrations;

use Doctrine\DBAL\Schema\Schema;
use Doctrine\Migrations\AbstractMigration;

final class Version20991231000002 extends AbstractMigration
{
    public function up(Schema $schema): void
    {
        $this->addSql("COMMENT ON TABLE users IS 'stack test'");
    }

    public function down(Schema $schema): void
    {
        $this->addSql('COMMENT ON TABLE users IS NULL');
    }
}
PHP
(cd "$A" && FLOWCRM_DEVENV_FAULT=up-after-migrations:kill ./bin/devenv up) >"$work/out/a-kill4.out" 2>"$work/out/a-kill4.err"
echo $? >"$work/out/a-kill4.rc"
get "$PA" /health/ready
k4_code=$CODE
k4_blocked=$(blocked_now a-kill4 && echo yes)
k4_migrated=$(psql_in "$A" "SELECT count(*) FROM doctrine_migration_versions WHERE version LIKE '%20991231000002'")
dv a-kill4-up "$A" up
[ "$(rc_of a-kill3)" = 137 ] && [ "$k3_code" = 000 ] && [ "$k3_blocked" = yes ] && [ "$(rc_of a-kill3-finish)" = 0 ] &&
  [ "$(rc_of a-kill4)" = 137 ] && err_has a-kill4 'stopped the edge before changing the database' && [ "$k4_code" = 000 ] &&
  [ "$k4_blocked" = yes ] && [ "$k4_migrated" = 1 ] && [ "$(rc_of a-kill4-up)" = 0 ] && until_ready "$PA" 200 30 &&
  [ ! -e "$A/.runtime/gate/security-gate" ]
v "ST-64 SIGKILL after a committed change but before its verification (rotation, migrations): blocked, no edge; the rotation or make up verifies and serves again" $? "rot=$(rc_of a-kill3)/$k3_code/$k3_blocked up=$(rc_of a-kill4)/$k4_code/$k4_blocked/$k4_migrated"

# Recovery while PostgreSQL is temporarily unreachable: make up fails and
# the stack stays blocked; once the database is back, make up ends the old
# operation (it never commits) and serves after every check.
killed_rotation a-kill5
docker pause "$(cid "$A" db)" >/dev/null
(cd "$A" && FLOWCRM_WAIT_TIMEOUT=10 ./bin/devenv up) >"$work/out/a-kill5-up.out" 2>"$work/out/a-kill5-up.err"
echo $? >"$work/out/a-kill5-up.rc"
get "$PA" /health/ready
k5_code=$CODE
k5_blocked=$(blocked_now a-kill5 && echo yes)
docker unpause "$(cid "$A" db)" >/dev/null
db_healthy
(cd "$A" && FLOWCRM_LOCK_WAIT=300 exec ./bin/devenv up) >"$work/out/a-kill5-up2.out" 2>"$work/out/a-kill5-up2.err" &
upp=$!
i=0
until [ "$(psql_in "$A" "SELECT count(*) FROM pg_stat_activity WHERE pid = $K_OLD")" = 0 ] || [ "$i" -ge 400 ]; do sleep 0.5; i=$((i + 1)); done
holder_down
wait "$upp"
k5_up=$?
k5_pending=$(login_ok app "$(pend app)" && echo committed)
rot a-kill5-abort app '' rotate-db-password-abort
[ "$(rc_of a-kill5)" = 137 ] && [ "$(rc_of a-kill5-up)" != 0 ] && [ "$k5_code" = 000 ] && [ "$k5_blocked" = yes ] &&
  [ "$i" -lt 400 ] && [ "$k5_up" = 0 ] && [ -z "$k5_pending" ] && [ "$(rc_of a-kill5-abort)" = 0 ] &&
  until_ready "$PA" 200 30 && [ ! -e "$A/.runtime/gate/security-gate" ] && no_leftovers
v "ST-65 after SIGKILL, recovery while PostgreSQL is paused fails and stays blocked; once reachable, make up ends the old operation (no commit) and serves" $? "up=$(rc_of a-kill5-up) code=$k5_code blocked=$k5_blocked up2=$k5_up pending=$k5_pending"

dv a-up-rotated "$A" up
[ "$(rc_of a-up-rotated)" = 0 ] && err_has a-up-rotated 'already running' && until_ready "$PA" 200 10
v "ST-51 make up after the rotations publishes the stack as before and changes nothing" $? "$(tail -n 2 "$work/out/a-up-rotated.err")"

# A database credential the api cannot read makes it not ready (503 through
# the edge, with a request ID), not a 500 (FND-009V F-08).
printf 'services:\n  api:\n    environment:\n      DATABASE_PASSWORD_FILE: /run/secrets/does-not-exist\n' >"$work/f08.yaml"
(cd "$A" && FLOWCRM_HTTP_PORT=$PA COMPOSE_PROFILES=dev,migrate docker compose --project-name "$(project_of "$A")" -f compose.yaml -f "$work/f08.yaml" \
  up --detach --no-deps --wait api) >/dev/null 2>&1
get "$PA" /health/ready
f08="$CODE $(cat "$BODY")"
f08_id=$(grep -ci '^x-request-id:' "$HEADERS")
get "$PA" /health/live
f08_live=$CODE
# Back to the stack's own Compose file (bin/devenv refuses containers that
# another file created), then make up.
(cd "$A" && FLOWCRM_HTTP_PORT=$PA COMPOSE_PROFILES=dev,migrate docker compose --project-name "$(project_of "$A")" -f compose.yaml \
  up --detach --no-deps --wait api) >/dev/null 2>&1
dv a-up-f08 "$A" up
[ "$f08" = '503 {"status":"not-ready"}' ] && [ "$f08_id" = 1 ] && [ "$f08_live" = 200 ] &&
  [ "$(rc_of a-up-f08)" = 0 ] && until_ready "$PA" 200 30
v "ST-58 an unreadable database credential: /health/ready answers 503 not-ready with a request ID through the edge (live 200); make up restores it" $? "ready: $f08 live: $f08_live"

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

# Failure injection before the real upgrade (FND-009V F-04, F-07). The
# legacy database must be unchanged after each one: same rows, same owner,
# no leftover dump, scratch database or session of the role script.
legacy_same() {
  local db
  db=$(cid "$C" db)
  [ -n "$db" ] && [ "$(docker exec "$db" flowcrm-db-roles state)" = legacy ] &&
    [ "$(docker exec "$db" psql -U flowcrm -d flowcrm -tAq -c "$rows_sql")" = "$legacy_rows" ] &&
    [ "$(docker exec "$db" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_database WHERE datname LIKE '%restore_check'")" = 0 ] &&
    [ "$(docker exec "$db" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")" = 0 ] &&
    [ "$(docker exec "$db" sh -c 'ls /tmp/*.dump /tmp/flowcrm-db-roles.*.pid 2>/dev/null | wc -l' | tr -d ' ')" = 0 ]
}
backups() { find "$C/.runtime/backups" -name '*.dump' -type f 2>/dev/null | wc -l | tr -d ' '; }
cupg() { # label [fault]
  (cd "$C" && FLOWCRM_DEVENV_FAULT=${2-} ./bin/devenv upgrade-roles) >"$work/out/$1.out" 2>"$work/out/$1.err"
  echo $? >"$work/out/$1.rc"
}

# Interrupted after the verified backup (SIGTERM): nothing converted; the
# verified backup is kept for the operator.
cupg c-upg-fault upgrade-after-backup
[ "$(rc_of c-upg-fault)" = 143 ] && [ "$(backups)" = 1 ] && legacy_same
v "ST-54 upgrade interrupted after the verified backup (SIGTERM): nothing converted, the verified backup is kept" $? "$(tail -n 2 "$work/out/c-upg-fault.err")"

# Interrupted while the ownership change waits on a real PostgreSQL lock
# (another session reads audit_events): the conversion transaction is ended
# before the command exits and never commits later, even once the lock is
# released; a retry later succeeds (ST-52).
cdb=$(cid "$C" db)
docker exec -d -e PGAPPNAME=st-holder "$cdb" psql -U flowcrm -d flowcrm -c 'BEGIN' -c 'LOCK TABLE audit_events IN ACCESS SHARE MODE' -c 'SELECT pg_sleep(180)' -c 'COMMIT'
i=0
until [ "$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE a.application_name = 'st-holder' AND l.relation = 'audit_events'::regclass AND l.granted")" = 1 ] || [ "$i" -ge 60 ]; do sleep 0.5; i=$((i + 1)); done
(cd "$C" && exec ./bin/devenv upgrade-roles) >"$work/out/c-upg-lock.out" 2>"$work/out/c-upg-lock.err" &
upg=$!
i=0
until [ "$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%' AND wait_event_type = 'Lock' AND query LIKE 'ALTER TABLE%'")" = 1 ] || [ "$i" -ge 240 ]; do sleep 0.5; i=$((i + 1)); done
lock_waited=$i
kill -TERM "$upg"
wait "$upg"
upg_rc=$?
lock_left=$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'st-holder'" >/dev/null
sleep 5
[ "$lock_waited" -lt 240 ] && [ "$upg_rc" = 143 ] && grep -q 'the interrupted database operation ended' "$work/out/c-upg-lock.err" &&
  [ "$lock_left" = 0 ] && legacy_same && [ "$(backups)" = 2 ]
v "ST-55 upgrade interrupted while ALTER TABLE waits on a real lock (SIGTERM): the transaction is ended before exit and never commits later; the data are unchanged" $? "rc=$upg_rc waited=$lock_waited left=$lock_left $(tail -n 2 "$work/out/c-upg-lock.err")"

# The same with SIGINT, delivered as in a terminal (job control on, so the
# background command does not ignore it), and with the connection of the
# operation cut from outside: both roll back, nothing commits later.
cupg_blocked() { # label: upgrade in the background, waiting for ALTER TABLE on the held lock -> sets UPG, UPG_T0
  local i=0
  docker exec -d -e PGAPPNAME=st-holder "$cdb" psql -U flowcrm -d flowcrm -c 'BEGIN' -c 'LOCK TABLE audit_events IN ACCESS SHARE MODE' -c 'SELECT pg_sleep(180)' -c 'COMMIT'
  # The upgrade starts only once the holder has its lock, so its ALTER TABLE
  # is the one that waits.
  until [ "$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE a.application_name = 'st-holder' AND l.relation = 'audit_events'::regclass AND l.granted")" = 1 ] || [ "$i" -ge 60 ]; do sleep 0.5; i=$((i + 1)); done
  # SIGINT at its default disposition, as from a terminal: a background job
  # of a non-interactive shell would otherwise ignore it.
  (cd "$C" && exec python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' ./bin/devenv upgrade-roles) >"$work/out/$1.out" 2>"$work/out/$1.err" &
  UPG=$!
  UPG_T0=$SECONDS
  i=0
  until [ "$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%' AND wait_event_type = 'Lock' AND query LIKE 'ALTER TABLE%'")" = 1 ] || [ "$i" -ge 240 ]; do sleep 0.5; i=$((i + 1)); done
}
holder_c_down() { docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'st-holder'" >/dev/null; }
cupg_blocked c-upg-int
kill -INT "$UPG"
wait "$UPG"
int_rc=$?
int_secs=$((SECONDS - UPG_T0))
holder_c_down
sleep 5
int_same=$(legacy_same && echo same)
cupg_blocked c-upg-conn
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'" >/dev/null
wait "$UPG"
conn_rc=$?
holder_c_down
sleep 5
[ "$int_rc" = 130 ] && [ "$int_secs" -lt 60 ] && grep -q 'the interrupted database operation ended' "$work/out/c-upg-int.err" && [ "$int_same" = same ] &&
  [ "$conn_rc" = 6 ] && grep -q 'the role upgrade failed .* and was rolled back' "$work/out/c-upg-conn.err" && legacy_same
v "ST-55 the same with SIGINT (exit 130) and with the operation's connection cut from outside (reported as failed and rolled back): nothing commits later" $? "int=$int_rc after ${int_secs}s conn=$conn_rc | int: $(tail -n 3 "$work/out/c-upg-int.err" | tr '\n' ' ') | conn: $(tail -n 1 "$work/out/c-upg-conn.err")"

# A backup that does not restore, a restored copy whose contents differ, and
# a damaged host copy: each stops the upgrade with nothing changed, and no
# unverified dump is kept (neither in the container nor on the host).
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "CREATE TABLE st_poison (i int CHECK (current_database() = 'flowcrm')); INSERT INTO st_poison VALUES (1)" >/dev/null
cupg c-upg-norestore
# A generated column is recomputed on restore; this one (falsely declared
# immutable) yields the scratch database's name there.
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "DROP TABLE st_poison; CREATE FUNCTION st_dbname() RETURNS text IMMUTABLE LANGUAGE sql AS 'SELECT current_database()'; CREATE TABLE st_poison (i int, db text GENERATED ALWAYS AS (st_dbname()) STORED); INSERT INTO st_poison (i) VALUES (1)" >/dev/null
cupg c-upg-differs
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "DROP TABLE st_poison; DROP FUNCTION st_dbname()" >/dev/null
cupg c-upg-corrupt upgrade-corrupt-copy
[ "$(rc_of c-upg-norestore)" = 6 ] && err_has c-upg-norestore 'the backup did not restore' &&
  [ "$(rc_of c-upg-differs)" = 6 ] && err_has c-upg-differs 'the restored copy differs in the contents of st_poison' &&
  [ "$(rc_of c-upg-corrupt)" = 6 ] && err_has c-upg-corrupt 'did not match the verified one' &&
  [ "$(backups)" = 4 ] && legacy_same
v "ST-56 a backup that does not restore, differs in its contents or is damaged on the host stops the upgrade (exit 6); nothing changed, no unverified dump kept" $? "$(tail -n 1 "$work/out/c-upg-norestore.err") | $(tail -n 1 "$work/out/c-upg-differs.err") | $(tail -n 1 "$work/out/c-upg-corrupt.err")"

# SIGKILL while ALTER TABLE ... OWNER waits (FND-009G2): the security gate
# was recorded before the conversion. The newer upgrade waits for the
# checkout lock (the killed command's docker compose exec still runs) until
# the old operation ended by its lock timeout, rolled back; it never
# commits, also after the lock on audit_events is released.
cupg_blocked c-upg-kill
kill -KILL "$UPG"
wait "$UPG"
ck_rc=$?
ck_old=$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'flowcrm-db-roles:%'")
dv c-kill-status "$C" status
dv c-kill-url "$C" url
(cd "$C" && FLOWCRM_DEVENV_FAULT=upgrade-after-backup FLOWCRM_LOCK_WAIT=300 exec ./bin/devenv upgrade-roles) >"$work/out/c-upg-retry.out" 2>"$work/out/c-upg-retry.err" &
retry=$!
i=0
until [ "$(docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c "SELECT count(*) FROM pg_stat_activity WHERE pid = ${ck_old:-0}")" = 0 ] || [ "$i" -ge 400 ]; do sleep 0.5; i=$((i + 1)); done
holder_c_down
wait "$retry"
sleep 5
[ "$ck_rc" = 137 ] && [ -n "$ck_old" ] && [ "$(rc_of c-kill-status)" = 1 ] && grep -q '^blocked: *upgrading the database roles' "$work/out/c-kill-status.out" &&
  [ "$(rc_of c-kill-url)" = 1 ] && [ "$i" -lt 400 ] && legacy_same && [ -e "$C/.runtime/gate/security-gate" ]
v "ST-66 SIGKILL while ALTER TABLE OWNER waits: blocked (status, url); the next upgrade ends the old operation first and it never commits; the gate stays until an upgrade passes every check" $? "rc=$ck_rc old=$ck_old waited=$i"

# The backup check requires an intact audit log once its migration is
# recorded (FND-009U): a disabled or a dropped trigger stops the upgrade
# before anything changes; the triggers are then restored exactly.
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c 'ALTER TABLE audit_events DISABLE TRIGGER audit_events_append_only' >/dev/null
cupg c-upg-trgoff
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c 'ALTER TABLE audit_events ENABLE TRIGGER audit_events_append_only; DROP TRIGGER audit_events_no_truncate ON audit_events' >/dev/null
cupg c-upg-trgdrop
docker exec "$cdb" psql -U flowcrm -d flowcrm -tAq -c 'CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON audit_events FOR EACH STATEMENT EXECUTE FUNCTION audit_events_reject_change()' >/dev/null
[ "$(rc_of c-upg-trgoff)" = 6 ] && err_has c-upg-trgoff 'the audit log is not intact \(audit_events_append_only:D' &&
  [ "$(rc_of c-upg-trgdrop)" = 6 ] && err_has c-upg-trgdrop 'the audit log is not intact \(audit_events_append_only:O;' && legacy_same
v "ST-67 a disabled or a dropped audit trigger stops the upgrade in the backup check (exit 6); nothing changed" $? "$(tail -n 1 "$work/out/c-upg-trgoff.err") | $(tail -n 1 "$work/out/c-upg-trgdrop.err")"

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

# --- a volume from FND-004, before the audit log existed (FND-009U) -----------
# Checkout D gets a volume as the stack created it at FND-004: one superuser,
# only the baseline migration and its row, no audit_events. The backup check
# must accept the missing audit log there, but not when the history records
# the migration that creates it; the upgrade then runs every later migration
# as flowcrm_owner and keeps the baseline row and its history.
new_checkout d
D=$CO
pd=$(project_of "$D")
ds=$D/.runtime/secrets
(umask 077 && mkdir -p "$ds")
for f in db_password app_secret; do random_secret >"$ds/$f" && chmod 0444 "$ds/$f"; done
docker network create --label "$legacy_label" "$pd-legacy" >/dev/null
docker volume create --label "com.docker.compose.project=$pd" --label com.docker.compose.volume=db-data "${pd}_db-data" >/dev/null
docker run -d --name "$pd-legacy-db" --label "$legacy_label" --network "$pd-legacy" --network-alias db --user postgres \
  -e POSTGRES_DB=flowcrm -e POSTGRES_USER=flowcrm -e POSTGRES_PASSWORD_FILE=/run/secrets/db_password \
  -v "$ds/db_password:/run/secrets/db_password:ro" -v "${pd}_db-data:/var/lib/postgresql" "$legacy_image" >/dev/null
i=0
until docker logs "$pd-legacy-db" 2>&1 | grep -q 'init process complete' && docker exec "$pd-legacy-db" pg_isready -q -h 127.0.0.1 -U flowcrm -d flowcrm || [ "$i" -ge 90 ]; do sleep 1; i=$((i + 1)); done
docker run --rm --network "$pd-legacy" --read-only --tmpfs /tmp --tmpfs /app/var:uid=82,gid=82 \
  -e APP_ENV=dev -e DATABASE_USER=flowcrm -e DATABASE_PASSWORD_FILE=/run/secrets/db_password \
  -v "$ds/db_password:/run/secrets/db_password:ro" -v "$ds/app_secret:/run/secrets/app_secret:ro" \
  -v "$D/backend/src:/app/src:ro" -v "$D/backend/config:/app/config:ro" -v "$D/backend/migrations:/app/migrations:ro" \
  "$(project_of "$A")-api" php bin/console doctrine:migrations:migrate --no-interaction 'DoctrineMigrations\Version20261021180000' >"$work/out/d-legacy-migrate.log" 2>&1
d_legacy_rc=$?
d_rows_sql="SELECT md5(string_agg(t, '|' ORDER BY t)) FROM (SELECT b::text t FROM schema_baseline b UNION ALL SELECT v.version || ' ' || v.executed_at FROM doctrine_migration_versions v WHERE v.version = 'DoctrineMigrations\Version20261021180000') x"
d_rows=$(docker exec "$pd-legacy-db" psql -U flowcrm -d flowcrm -tAq -c "$d_rows_sql")
d_shape=$(docker exec "$pd-legacy-db" psql -U flowcrm -d flowcrm -tAq -c "SELECT string_agg(relname, ',' ORDER BY relname) FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind = 'r'")
docker rm -f "$pd-legacy-db" >/dev/null 2>&1
docker network rm "$pd-legacy" >/dev/null 2>&1
psql_d() { docker exec "$(cid "$D" db)" psql -U flowcrm -d flowcrm -tAq -c "$1" 2>&1; }

dv d-up "$D" up
# The history records the audit log's migration, but the table is missing:
# the backup check fails closed.
(cd "$D" && FLOWCRM_DEVENV_FAULT=upgrade-after-backup ./bin/devenv upgrade-roles) >/dev/null 2>&1
psql_d "INSERT INTO doctrine_migration_versions (version, executed_at, execution_time) VALUES ('DoctrineMigrations\Version20261022000000', now(), 1)" >/dev/null
dv d-upg-fake "$D" upgrade-roles
psql_d "DELETE FROM doctrine_migration_versions WHERE version = 'DoctrineMigrations\Version20261022000000'" >/dev/null
d_fake_state=$(docker exec "$(cid "$D" db)" flowcrm-db-roles state)
dv d-upgrade "$D" upgrade-roles
d_dump=$(find "$D/.runtime/backups" -name 'roles_upgrade_*.dump' -type f -newer "$work/out/d-upg-fake.rc" 2>/dev/null | head -n 1)
[ "$d_legacy_rc" = 0 ] && [ "$d_shape" = doctrine_migration_versions,schema_baseline ] && [ -n "$d_rows" ] &&
  [ "$(rc_of d-up)" = 6 ] && err_has d-up 'make db-upgrade-roles' &&
  [ "$(rc_of d-upg-fake)" = 6 ] && err_has d-upg-fake 'audit_events missing although its migration is recorded' && [ "$d_fake_state" = legacy ] &&
  [ "$(rc_of d-upgrade)" = 0 ] && err_has d-upgrade 'verified backup: .runtime/backups/roles_upgrade_' && [ -s "$d_dump" ] && [ "$(perm "$d_dump")" = 600 ] &&
  [ "$(docker exec "$(cid "$D" db)" flowcrm-db-roles state)" = complete ] &&
  [ "$(psql_d "SELECT string_agg(DISTINCT pg_get_userbyid(relowner), ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace")" = flowcrm_owner ] &&
  [ "$(psql_d "$d_rows_sql")" = "$d_rows" ] &&
  [ "$(psql_d "SELECT count(*) FROM doctrine_migration_versions")" = "$(find "$D/backend/migrations" -name 'Version*.php' | wc -l | tr -d ' ')" ] &&
  [ "$(psql_d "SELECT string_agg(tgname || ':' || tgenabled::text, ' ' ORDER BY tgname) FROM pg_trigger WHERE tgrelid = 'audit_events'::regclass AND NOT tgisinternal")" = 'audit_events_append_only:O audit_events_no_truncate:O' ]
v "ST-68 a volume from FND-004 (no audit log yet): a recorded audit migration without its table is refused; the upgrade then succeeds after a verified backup, runs every later migration as flowcrm_owner and keeps the baseline row and history" $? "legacy=$d_legacy_rc shape=$d_shape fake=$(rc_of d-upg-fake) upgrade=$(rc_of d-upgrade) $(tail -n 2 "$work/out/d-upgrade.err" | tr '\n' ' ')"
dv d-up2 "$D" up
d_ready=$(until_ready "$(saved_port "$D")" 200 30 && echo ready)
if console_in "$D" app:database:verify-privileges --runtime; then d_verify=ok; else d_verify=$(tail -n 3 "$work/out/console.log" | tr '\n' ' '); fi
dv d-upgrade2 "$D" upgrade-roles
[ "$(rc_of d-up2)" = 0 ] && [ "$d_ready" = ready ] && [ "$d_verify" = ok ] &&
  [ "$(rc_of d-upgrade2)" = 0 ] && err_has d-upgrade2 'nothing to upgrade' && ! err_has d-upgrade2 'verified backup' && [ "$(psql_d "$d_rows_sql")" = "$d_rows" ]
v "ST-68 after the FND-004 upgrade make up serves as flowcrm_app (runtime manifest OK); a second upgrade changes nothing" $? "up=$(rc_of d-up2) ready=$d_ready verify=$d_verify upgrade2=$(rc_of d-upgrade2) $(tail -n 2 "$work/out/d-upgrade2.err" | tr '\n' ' ')"
dv d-down "$D" down

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
for d in "$A" "$B" "$C" "$D"; do left=$((left + $(project_resources "$(project_of "$d")"))); done
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
