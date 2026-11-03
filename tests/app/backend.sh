#!/usr/bin/env bash
#
# Backend checks in a throwaway "<project>-test" Compose project: no
# published ports and a database on tmpfs (compose.test.yaml). Runs
# composer validate and audit, the coding standard, PHPStan, the Deptrac
# architecture rules and their tests, migrations from an empty database
# (with a full down/up round trip and a schema check) and PHPUnit (unit +
# integration against the real PostgreSQL, including sessions and the API
# security tests through a real PHP-FPM), the security negative controls
# (mutations that must fail the tests) and the session and cache
# configuration of dev and prod.
# Removes only its own test project afterwards.
#
# Usage: tests/app/backend.sh

# shellcheck source-path=SCRIPTDIR
set -u
here=$(cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-backend.XXXXXX") || exit 2
tally_init "$work/tally"
secrets=$(make_secrets) || exit 2
# Unique per run: concurrent runs from one checkout never share a project.
project=$(project_of "$APP_REPO")-test-$(sha6 "$work")
export FLOWCRM_SECRETS_DIR=$secrets FLOWCRM_HTTP_PORT=0 COMPOSE_PROFILES=

dc() { docker compose --project-name "$project" --project-directory "$APP_REPO" -f "$APP_REPO/compose.yaml" -f "$APP_REPO/compose.test.yaml" "$@"; }
cleanup() {
  case $project in flowcrm-??????-test-??????) dc down --volumes --remove-orphans >/dev/null 2>&1 ;; esac
  remove_project "$project" "$APP_REPO"
  remove_images "$project-"
  remove_untagged_images "$project"
  rm -rf "$work" "$secrets"
}
trap cleanup EXIT

# check "label" "shell command run in the api container" [extra dc run args...]
# The api container connects as the runtime role flowcrm_app; check_owner
# runs the command as the schema owner, like the migrate job (ADR-018).
check() {
  local label=$1 cmd=$2 log
  shift 2
  log=$work/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').log
  if dc run --rm --quiet-pull "$@" api "$cmd" >"$log" 2>&1; then
    ok "$label"
  else
    bad "$label" "exit $?"
    sed 's/^/      | /' "$log" | tail -n 30
  fi
  grep -E '^(OK|Tests:|PHPStan|\[OK\]|No security|Found|Loaded config| +Violations |[0-9]+ of [0-9]+ negative)' "$log" | sed 's/^/      /' | head -n 6
}

say "== backend checks in project $project"
need "build the api image (target dev, PHP $(sed -n 's/^ARG PHP_IMAGE=php:\([0-9.]*\).*/\1/p' "$APP_REPO/docker/api/Dockerfile"))" \
  dc build --quiet api || { tally_finish; exit; }

check "BE-01 PHP runtime and extensions" 'php -v | head -n 1 && php -m | grep -qx pdo_pgsql && echo "OK pdo_pgsql loaded"'
check "BE-02 composer validate --strict" 'composer validate --strict --no-check-publish'
# The api container has no internet access (internal network); the audit
# runs from the same image on Docker's default network instead.
log=$work/audit.log
if docker run --rm -e HOME=/tmp --entrypoint /bin/sh "$project-api" -c 'composer audit --locked --no-interaction' >"$log" 2>&1; then
  ok "BE-03 composer audit (locked dependencies)"
else
  bad "BE-03 composer audit (locked dependencies)" "exit $?"
  tail -n 20 "$log" | sed 's/^/      | /'
fi
grep -E 'No security|Found' "$log" | sed 's/^/      /'
# No PHP_CS_FIXER_IGNORE_ENV: the fixer must refuse a PHP version it does not support.
check "BE-04 coding standard (PHP-CS-Fixer)" 'vendor/bin/php-cs-fixer check --diff --using-cache=no --show-progress=none'
check "BE-05 static analysis (PHPStan, level max)" 'vendor/bin/phpstan analyse --no-progress --memory-limit=1G'
check_owner() { check "$1" "$2" -e DATABASE_USER=flowcrm_owner -e DATABASE_PASSWORD_FILE=/run/secrets/db_owner_password; }
check_owner "BE-06 migrations from an empty database" 'bin/console doctrine:migrations:migrate --no-interaction --all-or-nothing && bin/console doctrine:migrations:up-to-date'
check_owner "BE-07 ORM mapping matches the migrated schema" 'bin/console doctrine:schema:validate'
check_owner "BE-08 migrations down to empty and up again" 'bin/console doctrine:migrations:migrate first --no-interaction && if bin/console dbal:run-sql "SELECT 1 FROM schema_baseline" >/dev/null 2>&1; then echo "schema_baseline still exists after migrating down" >&2; exit 1; fi && bin/console doctrine:migrations:migrate --no-interaction && bin/console doctrine:migrations:up-to-date'
# As the runtime role: the migrated database matches the privilege manifest
# (config/database/runtime-privileges.yaml), and this connection is flowcrm_app.
check "BE-16 runtime privileges match the manifest (as flowcrm_app)" 'bin/console app:database:verify-privileges --runtime'
check "BE-09 PHPUnit unit suite" 'vendor/bin/phpunit --colors=never --testsuite unit'
check "BE-10 PHPUnit integration suite (real PostgreSQL)" 'vendor/bin/phpunit --colors=never --testsuite integration'
# Each security control of FND-010B removed in a copy of the backend must make
# its tests fail (tests/Mutation/controls.php); the checkout is not changed.
check "BE-18 security negative controls: every removed protection fails its tests" 'php tests/Mutation/run-controls.php'
check "BE-11 module boundaries (Deptrac, deptrac.modules.yaml)" 'vendor/bin/deptrac analyse --config-file=deptrac.modules.yaml --no-cache --no-progress'
check "BE-12 layer rules (Deptrac, deptrac.layers.yaml)" 'vendor/bin/deptrac analyse --config-file=deptrac.layers.yaml --no-cache --no-progress'
check "BE-13 architecture tests (rules on fixtures, source layout)" 'vendor/bin/phpunit --colors=never --testsuite architecture'
# The integration suite checks the test environment; this checks dev and
# prod, and that the test-only session routes exist in no other environment
# (the control proves the route check finds them where they do exist).
# shellcheck disable=SC2016 # $e expands in the api container
check "BE-14 dev and prod: PostgreSQL sessions and cache, no test-only routes" '
  APP_ENV=test bin/console debug:router | grep -qF /api/_test/session || { echo "control: test routes not found in test" >&2; exit 1; }
  for e in dev prod; do
    APP_ENV=$e bin/console debug:container session.handler | grep -qF PdoSessionHandler &&
      APP_ENV=$e bin/console debug:container cache.app | grep -qF DoctrineDbalAdapter &&
      APP_ENV=$e bin/console debug:container --parameter=cache.prefix.seed | grep -qw flowcrm &&
      ! APP_ENV=$e bin/console debug:router | grep -qF /_test/ || { echo "$e: unexpected session or cache configuration" >&2; exit 1; }
    echo "OK $e: PdoSessionHandler, DoctrineDbalAdapter, prefix seed flowcrm, no test routes"
  done'
# PHP-FPM bounds the wall-clock time of a request (docker/api/php-fpm.conf),
# read from the configuration PHP-FPM itself parsed.
check "BE-15 PHP-FPM ends requests after 60 seconds (request_terminate_timeout)" \
  'php-fpm -tt 2>&1 | grep -E "^\[[^]]+\] NOTICE:[[:space:]]+request_terminate_timeout = 60s$" && echo "OK request_terminate_timeout = 60s"'

# Who gets which database secret (ADR-018), read from the resolved Compose
# configuration of development and production-like mode: the bootstrap
# superuser's password only in db, the owner's only in db and migrate, the
# api only the runtime role's.
log=$work/secrets.log
if (
  for files in compose.yaml "compose.yaml compose.prodlike.yaml"; do
    args=()
    for f in $files; do args+=(--file "$APP_REPO/$f"); done
    COMPOSE_PROFILES=dev,migrate FLOWCRM_HTTP_PORT=8080 docker compose --project-name "$project-cfg" "${args[@]}" config --format json |
      python3 -c '
import json, sys
services = json.load(sys.stdin)["services"]
got = {n: sorted(x["source"] for x in s.get("secrets", [])) for n, s in services.items()}
want = {"db": ["db_app_password", "db_owner_password", "db_password"], "api": ["app_secret", "db_app_password"], "migrate": ["app_secret", "db_owner_password"]}
for name, secrets in got.items():
    expected = want.get(name, [])
    assert secrets == expected, (sys.argv[1], name, secrets, expected)
users = {n: s.get("environment", {}).get("DATABASE_USER") for n, s in services.items() if n in ("api", "migrate")}
assert users == {"api": None, "migrate": "flowcrm_owner"}, users
# The API trusts no proxy: forwarding headers could only come from the client (ADR-019).
assert "TRUSTED_PROXIES" not in services["api"].get("environment", {}), "api trusts a proxy"
print("OK", sys.argv[1], got)
' "$files" || exit 1
  done
) >"$log" 2>&1; then
  ok "BE-17 only db gets the superuser secret; only db and migrate the owner's; the api only its own and trusts no proxy"
else
  bad "BE-17 only db gets the superuser secret; only db and migrate the owner's; the api only its own and trusts no proxy" "see below"
  sed 's/^/      | /' "$log" | tail -n 10
fi
grep '^OK' "$log" | sed 's/^/      /'

tally_finish "(backend)"
