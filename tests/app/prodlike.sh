#!/usr/bin/env bash
#
# Production-like stack in a throwaway "<project>-prod" Compose project
# (compose.yaml + compose.prodlike.yaml): Caddy serves the built SPA, the
# API runs from the prod image without dev dependencies, the database is on
# tmpfs and no port is published. Requests come from containers on the
# project's front network (curl, Playwright). At the end the edge is
# recreated with the HTTPS test sites of tests/app/https (a throwaway
# certificate per run) for the production cookie in a real browser over TLS.
# Removes only its own project.
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

# ADR-017 boundary with raw request paths (curl --path-as-is). Symfony marks
# every response Cache-Control private (its default "no-cache, private"); the
# built SPA and the edge never do (the edge sets X-Request-Id on every
# response, so that is no marker).
layer() {
  if header Cache-Control | grep -qi 'private'; then
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

# Role separation in production mode (ADR-018): the migrate job ran as the
# owner and finished before the api started; the api holds only its own
# secret, runs as flowcrm_app and matches the privilege manifest.
migrate_id=$(dc ps --all --quiet migrate | head -n 1)
api_id=$(dc ps --quiet api | head -n 1)
migrate_exit=$(docker inspect -f '{{.State.ExitCode}}' "$migrate_id" 2>/dev/null)
migrate_end=$(docker inspect -f '{{.State.FinishedAt}}' "$migrate_id" 2>/dev/null)
api_start=$(docker inspect -f '{{.State.StartedAt}}' "$api_id" 2>/dev/null)
api_secrets=$(docker exec "$api_id" ls /run/secrets | tr '\n' ' ')
dc exec -T api php bin/console app:database:verify-privileges --runtime >"$work/verify.log" 2>&1
verify_rc=$?
[ "$migrate_exit" = 0 ] && [[ $migrate_end < $api_start ]] && [ "$api_secrets" = "app_secret db_app_password " ] && [ "$verify_rc" = 0 ]
v "PL-15 migrations ran as the owner before the api; the api runs as flowcrm_app with only its own secret" $? "migrate exit $migrate_exit at $migrate_end, api from $api_start, secrets: $api_secrets, verify: $(tail -n 1 "$work/verify.log")"

# Production session cookie (FND-010B): __Host- prefix, Secure, HttpOnly,
# SameSite=Lax, Path=/, no Domain, here with curl over plain HTTP (a browser
# refuses the Secure cookie there); in a real browser over HTTPS: PL-21.
need "seed synthetic users and organizations with the operator console" seed_e2e "$work/e2e.env" "$(dc ps -q api | head -n 1)" && {
  # shellcheck disable=SC1091 # written by seed_e2e
  . "$work/e2e.env"
  printf '{"email":"%s","password":"%s"}' "$E2E_REP_EMAIL" "$E2E_PASSWORD" |
    docker run --rm -i --network "$net" "$APP_CURL_IMAGE" -sS --max-time 10 -o /dev/null -D - -w 'status=%{http_code}\n' \
      -H 'Content-Type: application/json' -H 'Origin: http://edge:8080' --data-binary @- http://edge:8080/api/v1/auth/login >"$work/login.headers" 2>&1
  cookie=$(tr -d '\r' <"$work/login.headers" | sed -n 's/^set-cookie: //Ip' | tail -n 1 | tr '[:upper:]' '[:lower:]')
  sid=${cookie#__host-flowcrm_sid=}
  sid=${sid%%;*}
  grep -q '^status=200$' "$work/login.headers" && case $cookie in __host-flowcrm_sid=*) true ;; *) false ;; esac &&
    case $cookie in *'; path=/'*) true ;; *) false ;; esac && case $cookie in *'; secure'*) true ;; *) false ;; esac &&
    case $cookie in *'; httponly'*) true ;; *) false ;; esac && case $cookie in *'; samesite=lax'*) true ;; *) false ;; esac &&
    case $cookie in *domain=*) false ;; *) true ;; esac &&
    [ "$(net_curl "$net" -o /dev/null -w '%{http_code}' -H "Cookie: __Host-flowcrm_sid=$sid" http://edge:8080/api/v1/me)" = 200 ]
  v "PL-16 production login: __Host-flowcrm_sid with Secure, HttpOnly, SameSite=Lax, Path=/ and no Domain; the session authenticates" $? "$cookie"
}

need "build the browser test image" docker build --quiet -f "$APP_REPO/docker/e2e/Dockerfile" -t "$e2e_image" "$APP_REPO" >/dev/null && {
  docker run --rm --network "$net" -e BASE_URL=http://edge:8080 -e MODE=prod "$e2e_image" >"$work/browser.out" 2>&1
  r=$?
  [ "$r" = 0 ] || tail -n 25 "$work/browser.out" | sed 's/^/      | /'
  [ "$r" = 0 ] && grep -Eq '[0-9]+ passed' "$work/browser.out" && ! grep -Eq '[0-9]+ failed' "$work/browser.out"
  v "PL-11 browser journey on the built SPA under the CSP (no console errors)" $?
  ev "$(grep -E '[0-9]+ (passed|failed|skipped)' "$work/browser.out" | tr -s ' ' | tr '\n' ' ')"
}

# --- HTTPS (FND-010V): the edge terminates TLS ------------------------------

# A throwaway CA and a certificate for the test host names, valid for two
# days; Chromium trusts exactly this certificate's key (HTTPS_SPKI).
make_test_cert() { # dir
  local d=$1
  mkdir -p "$d" && chmod 0755 "$d" &&
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj '/CN=FlowCRM HTTPS test CA' \
      -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign' -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null &&
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj '/CN=flowcrm.test' -keyout "$d/edge.key" -out "$d/edge.csr" 2>/dev/null &&
    printf '%s\n' 'subjectAltName=DNS:flowcrm.test,DNS:attacker.test,DNS:proxied.test' 'extendedKeyUsage=serverAuth' \
      'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' >"$d/edge.ext" &&
    openssl x509 -req -in "$d/edge.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial -days 2 -extfile "$d/edge.ext" -out "$d/edge.crt" 2>/dev/null &&
    rm -f "$d/ca.key" "$d/edge.csr" "$d/edge.ext" "$d"/*.srl &&
    # The unprivileged edge reads the key; it exists only for this run.
    chmod 0644 "$d/edge.key" "$d/edge.crt" "$d/ca.crt"
}
export FLOWCRM_HTTPS_DIR=$work/https
dch() { dc -f "$APP_REPO/tests/app/https/compose.https.yaml" "$@"; }
# tls_req url [curl args...]: like req, over the front network with the test
# CA; the request body (if any) is read from the file in TLS_BODY.
tls_req() {
  local url=$1 r
  shift
  r=$(docker run --rm -i --network "$net" -v "$FLOWCRM_HTTPS_DIR/ca.crt:/ca.crt:ro" "$APP_CURL_IMAGE" -sS --max-time 10 --cacert /ca.crt \
    -D /dev/stderr -o /dev/stdout -w '\n%{http_code}' "$@" "$url" <"${TLS_BODY:-/dev/null}" 2>"$work/headers.raw")
  CODE=${r##*$'\n'}
  printf '%s' "${r%$'\n'*}" >"$work/body"
  tr -d '\r' <"$work/headers.raw" >"$work/headers"
}
pseudonym() { python3 -c 'import hashlib, hmac, sys; print(hmac.new(open(sys.argv[1]).read().strip().encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest()[:16])' "$secrets/app_secret" "$1"; }

need "make a throwaway test certificate (openssl)" make_test_cert "$FLOWCRM_HTTPS_DIR" &&
  need "recreate the edge with the HTTPS test sites (tests/app/https)" dch up --detach --wait --wait-timeout 120 --no-deps edge >"$work/https-up.log" 2>&1 && {
  spki=$(openssl x509 -in "$FLOWCRM_HTTPS_DIR/edge.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)

  published=''
  for c in $(dc ps -q); do published="$published$(docker port "$c")"; done
  tls_req https://flowcrm.test:8443/
  [ -z "$published" ] && [ "$CODE" = 200 ] && grep -q '<div id="root">' "$work/body" &&
    header Content-Security-Policy | grep -q "frame-ancestors 'none'" && [ "$(header X-Content-Type-Options)" = nosniff ]
  v "PL-17 the edge serves the production site over TLS (test certificate), with its CSP and headers; still no published port" $? "$CODE"

  printf '{"email":"%s","password":"%s"}' "$E2E_REP_EMAIL" "$E2E_PASSWORD" >"$work/login.json"
  chmod 0600 "$work/login.json"
  TLS_BODY=$work/login.json tls_req https://flowcrm.test:8443/api/v1/auth/login -H 'Content-Type: application/json' \
    -H 'Origin: https://flowcrm.test:8443' -H 'X-Forwarded-Proto: http' --data-binary @-
  ok_login=$CODE
  # A client claiming HTTPS (and another host) on the plain listener: the
  # edge replaces X-Forwarded-Proto and the API ignores X-Forwarded-Host, so
  # an Origin built from the claims never matches.
  codes=''
  for spoof in 'https://flowcrm.test:8080|X-Forwarded-Proto: https' 'http://evil.example|X-Forwarded-Host: evil.example' \
    'https://evil.example|X-Forwarded-Proto: https|X-Forwarded-Host: evil.example|X-Forwarded-Port: 443'; do
    IFS='|' read -r origin h1 h2 h3 <<<"$spoof"
    args=(-H "Origin: $origin" -H "$h1")
    [ -z "${h2-}" ] || args+=(-H "$h2")
    [ -z "${h3-}" ] || args+=(-H "$h3")
    codes="$codes $(docker run --rm -i --network "$net" "$APP_CURL_IMAGE" -sS --max-time 10 -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: application/json' "${args[@]}" --data-binary @- http://flowcrm.test:8080/api/v1/auth/login <"$work/login.json")"
  done
  [ "$ok_login" = 200 ] && [ "$codes" = ' 403 403 403' ]
  v "PL-18 the API sees HTTPS only from the edge: the TLS login works (a client X-Forwarded-Proto is replaced); spoofed forwarding headers on plain HTTP are refused" $? "TLS login $ok_login, spoofed:$codes"

  tls_req https://flowcrm.test:8443/api/v1/auth/login -X OPTIONS -H 'Origin: https://attacker.test:8444' \
    -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: content-type, x-csrf-token'
  preflight=$CODE
  cors=$(grep -ci '^access-control-' "$work/headers")
  tls_req https://flowcrm.test:8443/api/v1/auth/session -H 'Origin: https://attacker.test:8444'
  cors=$((cors + $(grep -ci '^access-control-' "$work/headers")))
  [ "$cors" = 0 ] && [ "$CODE" = 200 ]
  v "PL-19 no CORS: neither a preflight nor a cross-origin read gets an Access-Control-* header" $? "preflight $preflight, Access-Control headers: $cors"

  TLS_BODY=$work/login.json tls_req https://proxied.test:8445/api/v1/auth/login -H 'Content-Type: application/json' \
    -H 'Origin: https://proxied.test:8445' --data-binary @-
  [ "$CODE" = 403 ] && grep -q 'csrf-invalid' "$work/body"
  v "PL-20 TLS terminated by a proxy the edge does not trust fails closed (403 csrf-invalid, no login)" $? "$CODE"

  # Chromium trusts the certificate's key (HTTPS_SPKI); Playwright's own
  # HTTP client (page.request) trusts the test CA (NODE_EXTRA_CA_CERTS).
  docker run --rm --network "$net" --env-file "$work/e2e.env" -e MODE=https -e BASE_URL=https://flowcrm.test:8443 \
    -e HTTP_URL=http://flowcrm.test:8080 -e ATTACKER_URL=https://attacker.test:8444/ -e HTTPS_SPKI="$spki" \
    -v "$FLOWCRM_HTTPS_DIR/ca.crt:/run/flowcrm-https/ca.crt:ro" -e NODE_EXTRA_CA_CERTS=/run/flowcrm-https/ca.crt "$e2e_image" >"$work/https-browser.out" 2>&1
  r=$?
  [ "$r" = 0 ] || tail -n 60 "$work/https-browser.out" | sed 's/^/      | /'
  # Only the dev-only HMR test may be skipped: every HTTPS and logged-in test ran.
  [ "$r" = 0 ] && grep -Eq '[0-9]+ passed' "$work/https-browser.out" && ! grep -Eq '[0-9]+ failed' "$work/https-browser.out" &&
    [ "$(sed -n 's/^ *\([0-9]*\) skipped$/\1/p' "$work/https-browser.out")" = 1 ] && grep -q 'over HTTPS' "$work/https-browser.out"
  v "PL-21 real browser over HTTPS: __Host- Secure HttpOnly SameSite=Lax host-only cookie, login, API calls and logout; never sent over plain HTTP; cross-site requests refused" $?
  ev "$(grep -E '[0-9]+ (passed|failed|skipped)' "$work/https-browser.out" | tr -s ' ' | tr '\n' ' ')"

  ip=$(sed -n 's/.*browser-client-ip=\([0-9.]*\).*/\1/p' "$work/https-browser.out" | head -n 1)
  api_log=$(dc logs --no-color api 2>&1)
  edge_log=$(dch logs --no-color edge 2>&1)
  forged=$(printf '%s\n' "$edge_log" | grep '"uri":"/api/v1/auth/logout"' | grep -c 'https://attacker.test:8444')
  forged_ok=$(printf '%s\n' "$edge_log" | grep '"uri":"/api/v1/auth/logout"' | grep 'https://attacker.test:8444' | grep -c '"status":403')
  [ -n "$ip" ] && printf '%s\n' "$api_log" | grep '"event":"login_failed"' | grep -q "\"client_ref\":\"$(pseudonym "$ip")\"" &&
    ! printf '%s\n' "$api_log" | grep -q "$(pseudonym 203.0.113.50)" && [ "$forged" -ge 2 ] && [ "$forged" = "$forged_ok" ]
  v "PL-22 behind the TLS edge the client IP is the browser's (security log pseudonym), not a forwarded address it sent; every cross-site logout was refused with 403" $? "browser $ip, cross-site logouts $forged (403: $forged_ok)"
}

docker_cleanup
[ "$(project_resources "$project")" = 0 ]; v "CLEAN the production-like project left no containers, volumes or networks" $?

tally_finish "(production-like stack)"
