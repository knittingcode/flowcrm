#!/bin/sh
# Prepares the Symfony application, then runs the container command.
# FLOWCRM_MIGRATE_ON_START=1 applies pending Doctrine migrations first; the
# command is idempotent and fails the container start if a migration fails.
set -eu

if [ "${FLOWCRM_MIGRATE_ON_START:-0}" = 1 ]; then
  php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration --all-or-nothing
fi
php bin/console cache:warmup --no-interaction >/dev/null

exec "$@"
