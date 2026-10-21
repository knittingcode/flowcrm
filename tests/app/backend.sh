#!/usr/bin/env bash
#
# Backend checks in a throwaway "<project>-test" Compose project: no
# published ports and a database on tmpfs (compose.test.yaml). Runs
# composer validate and audit, the coding standard, PHPStan, migrations
# from an empty database (with a full down/up round trip and a schema
# check) and PHPUnit (unit + integration against the real PostgreSQL).
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
project=$(project_of "$APP_REPO")-test
export FLOWCRM_SECRETS_DIR=$secrets FLOWCRM_HTTP_PORT=0 COMPOSE_PROFILES=

dc() { docker compose --project-name "$project" --project-directory "$APP_REPO" -f "$APP_REPO/compose.yaml" -f "$APP_REPO/compose.test.yaml" "$@"; }
cleanup() {
  case $project in flowcrm-??????-test) dc down --volumes --remove-orphans >/dev/null 2>&1 ;; esac
  remove_project "$project" "$APP_REPO"
  rm -rf "$work" "$secrets"
}
trap cleanup EXIT

# check "label" "shell command run in the api container"
check() {
  local label=$1 log
  log=$work/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').log
  if dc run --rm --quiet-pull api "$2" >"$log" 2>&1; then
    ok "$label"
  else
    bad "$label" "exit $?"
    sed 's/^/      | /' "$log" | tail -n 30
  fi
  grep -E '^(OK|Tests:|PHPStan|\[OK\]|No security|Found|Loaded config)' "$log" | sed 's/^/      /' | head -n 6
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
check "BE-04 coding standard (PHP-CS-Fixer)" 'PHP_CS_FIXER_IGNORE_ENV=1 vendor/bin/php-cs-fixer check --diff --using-cache=no --show-progress=none'
check "BE-05 static analysis (PHPStan, level max)" 'vendor/bin/phpstan analyse --no-progress --memory-limit=1G'
check "BE-06 migrations from an empty database" 'bin/console doctrine:migrations:migrate --no-interaction --all-or-nothing && bin/console doctrine:migrations:up-to-date'
check "BE-07 ORM mapping matches the migrated schema" 'bin/console doctrine:schema:validate'
check "BE-08 migrations down to empty and up again" 'bin/console doctrine:migrations:migrate first --no-interaction && if bin/console dbal:run-sql "SELECT 1 FROM schema_baseline" >/dev/null 2>&1; then echo "schema_baseline still exists after migrating down" >&2; exit 1; fi && bin/console doctrine:migrations:migrate --no-interaction && bin/console doctrine:migrations:up-to-date'
check "BE-09 PHPUnit unit suite" 'vendor/bin/phpunit --colors=never --testsuite unit'
check "BE-10 PHPUnit integration suite (real PostgreSQL)" 'vendor/bin/phpunit --colors=never --testsuite integration'

tally_finish "(backend)"
