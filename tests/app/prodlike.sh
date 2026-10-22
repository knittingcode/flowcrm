#!/usr/bin/env bash
#
# Production-like stack in a throwaway "<project>-prod" Compose project
# (compose.yaml + compose.prodlike.yaml): Caddy serves the built SPA, the
# API runs from the prod image without dev dependencies, the database is on
# tmpfs and no port is published. Requests come from containers on the
# project's front network (curl, Playwright). Removes only its own project.
#
# Usage: tests/app/prodlike.sh

# shellcheck disable=SC2319
# "<condition>; v NAME $?" records the status of that condition on purpose.

# shellcheck source-path=SCRIPTDIR
set -u
here=$(cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-prodlike.XXXXXX") || exit 2
tally_init "$work/tally"
secrets=$(make_secrets) || exit 2
# Unique per run: concurrent runs from one checkout never share a project.
project=$(project_of "$APP_REPO")-prod-$(sha6 "$work")
net=${project}_front
e2e_image=flowcrm-e2e:$(sha6 "$work")
# The edge's port mapping is removed by compose.prodlike.yaml; the variable
# is only interpolated.
export FLOWCRM_SECRETS_DIR=$secrets FLOWCRM_HTTP_PORT=0 COMPOSE_PROFILES=

dc() { docker compose --project-name "$project" --project-directory "$APP_REPO" -f "$APP_REPO/compose.yaml" -f "$APP_REPO/compose.prodlike.yaml" "$@"; }
docker_cleanup() {
  local id
  case $project in flowcrm-??????-prod-??????) dc down --volumes --remove-orphans >/dev/null 2>&1 ;; esac
  remove_project "$project" "$APP_REPO"
  docker images -q --filter "label=com.docker.compose.project=$project" | sort -u |
    while read -r id; do docker image rm -f "$id" >/dev/null 2>&1; done
  docker image rm -f "$e2e_image" >/dev/null 2>&1
}
trap 'docker_cleanup; rm -rf "$work" "$secrets"' EXIT

# req path [curl args...]: sets CODE, TYPE and the files $work/body, $work/headers
req() {
  local path=$1 r
  shift
  r=$(net_curl "$net" -o /dev/null -w '%{http_code} %{content_type}' "$@" "http://edge:8080$path")
  CODE=${r%% *}
  TYPE=${r#* }
  net_curl "$net" -D - -o /dev/null "$@" "http://edge:8080$path" | tr -d '\r' >"$work/headers"
  net_curl "$net" "$@" "http://edge:8080$path" >"$work/body" 2>/dev/null
}
header() { sed -n "s/^$1: //Ip" "$work/headers" | tail -n 1; }

say "== production-like stack in project $project"
need "build the production images" dc build --quiet || { tally_finish; exit; }
need "start the production-like stack" dc up --detach --wait --wait-timeout 300 --quiet-pull >"$work/up.log" 2>&1 ||
  { tail -n 30 "$work/up.log" | sed 's/^/      | /'; dc logs --no-color --tail 30 api edge | sed 's/^/      | /'; tally_finish; exit; }

published=''
for c in $(dc ps -q); do published="$published$(docker port "$c")"; done
[ "$(dc ps -q | wc -l | tr -d ' ')" = 3 ] && [ -z "$published" ] && [ -z "$(dc ps -q web)" ]
v "PL-01 edge, api and db run; no published ports; no Vite dev server" $? "published: $published"

[ "$(dc exec -T api printenv APP_ENV)" = prod ] && ! dc exec -T api test -d vendor/phpunit &&
  [ "$(dc exec -T api id -u)" = 82 ] && [ "$(dc exec -T edge id -u)" = 65534 ]
v "PL-02 api runs APP_ENV=prod without dev dependencies; non-root api and edge" $?

req /
csp=$(header Content-Security-Policy)
asset=$(grep -o '/assets/index-[A-Za-z0-9_-]*\.js' "$work/body" | head -n 1)
case $TYPE in text/html*) html=0 ;; *) html=1 ;; esac
[ "$CODE" = 200 ] && [ "$html" = 0 ] && grep -q '<div id="root">' "$work/body" && ! grep -q '@vite/client' "$work/body" &&
  [ "$(header Cache-Control)" = no-cache ] && case $csp in *"default-src 'self'"*"frame-ancestors 'none'"*) true ;; *) false ;; esac
v "PL-03 GET / is the built SPA with a strict CSP and no-cache" $?
ev "asset $asset; CSP: $csp"

req "$asset"
[ "$CODE" = 200 ] && [ "$(header Cache-Control)" = "public, max-age=31536000, immutable" ] && case $TYPE in text/javascript* | application/javascript*) true ;; *) false ;; esac
v "PL-04 fingerprinted assets are cached as immutable ($CODE $TYPE)" $?

req /assets/index-does-not-exist.js
[ "$CODE" = 404 ] && ! grep -q '<div id="root">' "$work/body"; v "PL-05 a missing asset is 404, not the SPA" $?

req /accounts/some/deep/link
[ "$CODE" = 200 ] && grep -q '<div id="root">' "$work/body" && [ "$(header Cache-Control)" = no-cache ]
v "PL-06 client-side routes fall back to index.html" $?

req /api/v1/system/status -H 'Accept: application/json'
[ "$CODE $TYPE" = '200 application/json' ] && grep -q '"apiVersion":"v1"' "$work/body"
v "PL-07 the API answers through Caddy and PHP-FPM" $?

req /api/v1/does-not-exist
[ "$CODE $TYPE" = '404 application/problem+json' ] && ! grep -q '<div id="root">' "$work/body"
v "PL-08 API errors stay problem documents; the SPA fallback does not swallow /api" $?

req /health/live
l="$CODE $(cat "$work/body")"
req /health/ready
[ "$l" = '200 {"status":"live"}' ] && [ "$CODE $(cat "$work/body")" = '200 {"status":"ready"}' ]
v "PL-09 /health/live and /health/ready answer 200" $?

req /index.php
[ "$CODE" = 200 ] && grep -q '<div id="root">' "$work/body"; v "PL-10 /index.php is not executed (served as the SPA)" $?

# ADR-017 boundary with raw request paths (curl --path-as-is). Symfony sets
# X-Request-Id on every response; the built SPA never does.
layer() {
  if [ -n "$(header X-Request-Id)" ]; then
    case $TYPE in application/problem+json*) printf 'symfony-problem' ;; application/json*) printf 'symfony-json' ;; *) printf 'symfony-other' ;; esac
  elif grep -q '<div id="root">' "$work/body"; then
    printf 'spa'
  else
    printf 'other:%s' "$CODE"
  fi
}
boundary() { # expected path
  req "$2" --path-as-is
  local got
  got=$(layer)
  [ "$got" = "$1" ]
  v "PL-12 $2 -> $1" $? "got $CODE $TYPE via $got"
}
for p in //health/live /health//live //api/v1/system/status /health/live/ /API/v1/system/status /HEALTH/LIVE \
  /health%2Flive /%68ealth/live /api%2Fv1/system/status /%61pi/v1/system/status /health/./live /index.php /_error/500; do
  boundary spa "$p"
done
for p in /api//v1/system/status /api/v1/does-not-exist /api/../health/live; do
  boundary symfony-problem "$p"
done
req /health/live -X POST
[ "$(layer)" = symfony-other ] && [ "$CODE" = 405 ] && ! grep -qiE 'stack trace|vendor/symfony|/app/src' "$work/body"
v "PL-13 POST /health/live: 405 from Symfony without debug details (production mode)" $? "got $CODE $TYPE"

# Sessions are lazy in production too (FND-008): no cookie and no stored
# session for stateless routes, even with a session cookie in the request.
cookies=''
for route in /api/v1/system/status /health/live /health/ready /api/v1/does-not-exist; do
  req "$route" -H 'Cookie: __Host-flowcrm_sid=pl14unknownsessionid000000000000'
  cookies="$cookies$(header Set-Cookie)"
done
sessions=$(dc exec -T db psql -U flowcrm -d flowcrm -tAq -c 'SELECT count(*) FROM sessions' 2>&1)
[ -z "$cookies" ] && [ "$sessions" = 0 ]
v "PL-14 stateless requests set no cookie and store no session (production mode)" $? "Set-Cookie: $cookies, sessions: $sessions"

need "build the browser test image" docker build --quiet -f "$APP_REPO/docker/e2e/Dockerfile" -t "$e2e_image" "$APP_REPO" >/dev/null && {
  docker run --rm --network "$net" -e BASE_URL=http://edge:8080 -e MODE=prod "$e2e_image" >"$work/browser.out" 2>&1
  r=$?
  [ "$r" = 0 ] || tail -n 25 "$work/browser.out" | sed 's/^/      | /'
  [ "$r" = 0 ] && grep -Eq '[0-9]+ passed' "$work/browser.out" && ! grep -Eq '[0-9]+ failed' "$work/browser.out"
  v "PL-11 browser journey on the built SPA under the CSP (no console errors)" $?
  ev "$(grep -E '[0-9]+ (passed|failed|skipped)' "$work/browser.out" | tr -s ' ' | tr '\n' ' ')"
}

docker_cleanup
[ "$(project_resources "$project")" = 0 ]; v "CLEAN the production-like project left no containers, volumes or networks" $?

tally_finish "(production-like stack)"
