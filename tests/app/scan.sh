#!/usr/bin/env bash
#
# Container vulnerability scan (Trivy) of the images built from this
# checkout. Policy (docs/security/container-vulnerabilities.md):
#
# - Runtime images (production-like api and edge, db) fail on every HIGH or
#   CRITICAL finding, with or without an available fix, unless the CVE has
#   an explicit, expiring exception in security/trivyignore.yaml.
# - Development and test images (dev api, dev edge, web) are scanned and
#   their HIGH and CRITICAL findings are reported, without failing.
# - A control scan of a known-vulnerable pinned image must fail, so the
#   gate cannot pass vacuously.
#
# Trivy reads `docker save` archives; it gets no access to the Docker
# socket. Built images are tagged per run and removed afterwards.
#
# Usage: tests/app/scan.sh

# shellcheck source-path=SCRIPTDIR
set -u
here=$(cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

TRIVY_IMAGE=aquasec/trivy:0.67.2@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08
# The PostgreSQL base image with its gosu binary (see docker/db/Dockerfile).
CONTROL_IMAGE=postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873
IGNORE_FILE=$APP_REPO/security/trivyignore.yaml
# One line per scanned target (class, type, path, number of packages), one
# per finding: severity, CVE, package, installed and fixed versions, target,
# and one per finding suppressed by an exception of the ignore file, so an
# excepted finding stays visible in the log. Trivy passes the suppressed
# findings to a template as .ModifiedFindings whatever --show-suppressed
# says (that option only affects the table and JSON formats), and they do
# not count towards --exit-code.
# shellcheck disable=SC2016 # a Go template, not shell expansion
TEMPLATE='{{- range . }}{{- $t := .Target }}TARGET {{ .Class }} {{ .Type }} {{ $t }} pkgs={{ len .Packages }}
{{ range .Vulnerabilities }}{{ .Severity }} {{ .VulnerabilityID }} {{ .PkgName }} {{ .InstalledVersion }} fixed={{ if .FixedVersion }}{{ .FixedVersion }}{{ else }}none{{ end }} in={{ $t }}
{{ end }}{{ range .ModifiedFindings }}SUPPRESSED {{ .Status }} {{ .Finding.Severity }} {{ .Finding.VulnerabilityID }} {{ .Finding.PkgName }} {{ .Finding.InstalledVersion }} in={{ $t }} by={{ .Source }}
{{ end }}{{- end }}'

work=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-scan.XXXXXX") || exit 2
work=$(cd -P "$work" && pwd -P)
mkdir -p "$work/cache" "$work/images"
tally_init "$work/tally"
tag=flowcrm-scan-$(sha6 "$work")
# The control image is the PostgreSQL base image re-tagged as $tag:control:
# removing by name keeps the base image, which other builds use.
cleanup() {
  remove_images "$tag:"
  rm -rf "$work"
}
trap cleanup EXIT

build() { # name dockerfile target
  docker build --quiet -f "$APP_REPO/$2" ${3:+--target "$3"} -t "$tag:$1" "$APP_REPO" >/dev/null
}

trivy() { # archive args...
  local archive=$1
  shift
  docker run --rm --network bridge -v "$work/cache:/root/.cache" -v "$work/images:/images:ro" \
    -v "$APP_REPO/security:/policy:ro" "$TRIVY_IMAGE" image --quiet --scanners vuln --list-all-pkgs --input "/images/$archive" "$@"
}

# inventoried log pattern...: every pattern (class type target) must name a
# scanned target with at least one package, so an image whose contents
# Trivy did not recognise cannot pass as "no findings".
inventoried() {
  local log=$1 pattern
  shift
  for pattern in "$@"; do
    grep -E "^TARGET $pattern.* pkgs=[1-9]" "$log" >/dev/null || return 1
  done
}

# scan name gate|report pattern...: records PASS/FAIL for gated images and
# checks the package inventory (see inventoried)
scan() {
  local name=$1 mode=$2 archive=$1.tar log=$work/$1.log rc
  shift 2
  docker save -o "$work/images/$archive" "$tag:$name" || { bad "SC $name: could not export the image"; return; }
  if [ "$mode" = gate ]; then
    trivy "$archive" --severity HIGH,CRITICAL --exit-code 1 --ignorefile /policy/trivyignore.yaml --format template --template "$TEMPLATE" >"$log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then ok "SC $name (runtime): no HIGH or CRITICAL vulnerabilities"; else bad "SC $name (runtime): HIGH or CRITICAL vulnerabilities (exit $rc)"; fi
  else
    trivy "$archive" --severity HIGH,CRITICAL --exit-code 0 --format template --template "$TEMPLATE" >"$log" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then ok "SC $name (dev/test): scanned, findings reported below"; else bad "SC $name (dev/test): scan failed (exit $rc)"; fi
  fi
  inventoried "$log" "$@"
  v "SC $name: Trivy inventoried the expected package sources ($*)" $?
  say "      $(grep -cE '^(HIGH|CRITICAL) ' "$log") HIGH/CRITICAL findings in $name, $(grep -c '^SUPPRESSED ' "$log") suppressed by an exception"
  grep -E '^(HIGH|CRITICAL|SUPPRESSED) |FATAL|ERROR' "$log" | sed 's/^/      /' | head -n 40
  rm -f "$work/images/$archive"
}

say "== container vulnerability scan ($TRIVY_IMAGE)"
need "the exception file exists" test -f "$IGNORE_FILE" || { tally_finish; exit; }
need "download the Trivy database" docker run --rm --network bridge -v "$work/cache:/root/.cache" "$TRIVY_IMAGE" image --download-db-only --quiet ||
  { tally_finish; exit; }

need "build the production-like api image" build api-prod docker/api/Dockerfile prod || { tally_finish; exit; }
need "build the production-like edge image" build edge-prod docker/edge/Dockerfile prod || { tally_finish; exit; }
need "build the db image" build db docker/db/Dockerfile '' || { tally_finish; exit; }
need "build the dev api image" build api-dev docker/api/Dockerfile dev || { tally_finish; exit; }
need "build the dev edge image" build edge-dev docker/edge/Dockerfile dev || { tally_finish; exit; }
need "build the web image" build web-dev docker/web/Dockerfile dev || { tally_finish; exit; }

scan api-prod gate 'os-pkgs alpine' 'lang-pkgs composer'
scan edge-prod gate 'os-pkgs alpine' 'lang-pkgs gobinary usr/bin/caddy'
scan db gate 'os-pkgs alpine'
scan api-dev report 'os-pkgs alpine' 'lang-pkgs composer'
scan edge-dev report 'os-pkgs alpine' 'lang-pkgs gobinary usr/bin/caddy'
scan web-dev report 'os-pkgs alpine' 'lang-pkgs node-pkg'

# Control for the inventory check: a log without packages must not pass.
printf 'TARGET os-pkgs alpine x pkgs=0\n' >"$work/empty.log"
! inventoried "$work/empty.log" 'os-pkgs alpine'
v "SC control: an image without inventoried packages is rejected" $?

# Control: the base image with gosu has known HIGH/CRITICAL findings; the
# gate must reject it.
if ! docker image inspect "$CONTROL_IMAGE" >/dev/null 2>&1; then docker pull -q "$CONTROL_IMAGE" >/dev/null; fi
need "prepare the control image" docker tag "$CONTROL_IMAGE" "$tag:control" || { tally_finish; exit; }
docker save -o "$work/images/control.tar" "$tag:control"
trivy control.tar --severity HIGH,CRITICAL --exit-code 1 --ignorefile /policy/trivyignore.yaml --format template --template "$TEMPLATE" >"$work/control.log" 2>&1
rc=$?
[ "$rc" = 1 ] && grep -q 'in=usr/local/bin/gosu' "$work/control.log"
v "SC control: the gate rejects the known-vulnerable PostgreSQL base image" $? "(exit $rc)"
say "      control: $(grep -cE '^(HIGH|CRITICAL) ' "$work/control.log") HIGH/CRITICAL findings, e.g. $(grep -m1 -E '^CRITICAL ' "$work/control.log")"

# Edge configuration (docs/security/container-vulnerabilities.md, edge
# configuration guard): the JSON the built binary adapts from every
# configuration the edge images run keeps the admin API, config
# persistence, the PKI app, issuers, ACME and the acme_server handler off
# (scripts/ci/edge-adapted-config.jq). The images run the Caddy base
# image's command unchanged, without a CADDY_* variable (the admin address).
say "== edge configuration (adapted to JSON by the Caddy of the built images)"
adapt() { # id docker-run-args...: the adapted JSON goes to $work/<id>.json
  local id=$1
  shift
  docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true "$@" \
    >"$work/$id.json" 2>"$work/$id.adapt.log"
}
adapted_ok() { # id: no violation in the adapted JSON
  jq -r -f "$APP_REPO/scripts/ci/edge-adapted-config.jq" "$work/$1.json" >"$work/$1.violations" 2>&1 &&
    [ ! -s "$work/$1.violations" ]
}
edge_cmd='null ["caddy","run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"]'
if need "jq is available" command -v jq >/dev/null; then
  for image in edge-prod edge-dev; do
    run_cmd=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$tag:$image")
    env=$(docker image inspect -f '{{json .Config.Env}}' "$tag:$image")
    [ "$run_cmd" = "$edge_cmd" ] &&
      printf '%s' "$env" | jq -e 'map(select(startswith("CADDY_") and (startswith("CADDY_VERSION=") | not))) == []' >/dev/null
    v "SC $image: runs the Caddy base image's command on /etc/caddy/Caddyfile; no CADDY_* variable but CADDY_VERSION" $? "$run_cmd $env"
  done
  adapt edge-prod "$tag:edge-prod" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile &&
    adapted_ok edge-prod
  v "SC edge-prod config: admin off, persist_config off, automatic HTTPS off, no pki, issuer or acme_server" $? "$(cat "$work/edge-prod.violations" "$work/edge-prod.adapt.log" 2>/dev/null | head -n 20)"
  adapt edge-dev "$tag:edge-dev" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile &&
    adapted_ok edge-dev
  v "SC edge-dev config: admin off, persist_config off, automatic HTTPS off, no pki, issuer or acme_server" $? "$(cat "$work/edge-dev.violations" "$work/edge-dev.adapt.log" 2>/dev/null | head -n 20)"
  # The HTTPS test edge of prodlike.sh (tests/app/https/compose.https.yaml).
  adapt edge-https -v "$APP_REPO/tests/app/https/Caddyfile:/etc/caddy/https/Caddyfile:ro" "$tag:edge-prod" \
    caddy adapt --config /etc/caddy/https/Caddyfile --adapter caddyfile &&
    adapted_ok edge-https && [ "$(jq -c '.apps.tls.certificates | keys' "$work/edge-https.json")" = '["load_files"]' ]
  v "SC edge-https config: as edge-prod, certificates from files only" $? "$(cat "$work/edge-https.violations" "$work/edge-https.adapt.log" 2>/dev/null | head -n 20)"
  # Control: an unsafe configuration in an image derived from edge-prod
  # (its own command) must be rejected for each of its unsafe settings.
  mkdir -p "$work/control-edge"
  printf '%s\n' '{' '	admin localhost:2019' '	local_certs' '}' ':8080 {' '	acme_server' '}' >"$work/control-edge/Caddyfile"
  printf 'FROM %s\nCOPY Caddyfile /etc/caddy/Caddyfile\n' "$tag:edge-prod" |
    docker build --quiet -t "$tag:edge-control" -f - "$work/control-edge" >/dev/null &&
    adapt edge-control "$tag:edge-control" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile &&
    ! adapted_ok edge-control && grep -q 'admin.disabled is not true' "$work/edge-control.violations" &&
    grep -q 'admin.config.persist is not false' "$work/edge-control.violations" &&
    grep -q 'acme_server handler found' "$work/edge-control.violations" &&
    grep -q 'issuer modules found: internal' "$work/edge-control.violations" &&
    grep -q 'automatic_https.disable is not true' "$work/edge-control.violations"
  v "SC control: the adapted-config check rejects admin, persistence, local_certs, acme_server and automatic HTTPS" $? "$(cat "$work/edge-control.violations" "$work/edge-control.adapt.log" 2>/dev/null | head -n 20)"
fi

tally_finish "(container scan)"
