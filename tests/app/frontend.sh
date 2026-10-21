#!/usr/bin/env bash
#
# Frontend checks in the web image (Node 24, as the node user): dependency
# audit, type check, lint, component tests and the production build.
#
# Usage: tests/app/frontend.sh

# shellcheck source-path=SCRIPTDIR
set -u
here=$(cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-frontend.XXXXXX") || exit 2
tally_init "$work/tally"
image=flowcrm-web-check:$(sha6 "$APP_REPO")
trap 'docker image rm "$image" >/dev/null 2>&1; rm -rf "$work"' EXIT

# check "label" command... (run in a throwaway container of the web image)
check() {
  local label=$1 log
  shift
  log=$work/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').log
  if docker run --rm "$image" "$@" >"$log" 2>&1; then
    ok "$label"
  else
    bad "$label" "exit $?"
    sed 's/^/      | /' "$log" | tail -n 30
  fi
  grep -E 'Tests |Test Files|vulnerabilities|built in|gzip' "$log" | sed -E 's/\x1b\[[0-9;]*m//g; s/^/      /' | head -n 6
}

say "== frontend checks"
need "build the web image (target dev, Node $(sed -n 's/^ARG NODE_IMAGE=node:\([0-9.]*\).*/\1/p' "$APP_REPO/docker/web/Dockerfile"))" \
  docker build --quiet -f "$APP_REPO/docker/web/Dockerfile" --target dev -t "$image" "$APP_REPO" >/dev/null || { tally_finish; exit; }

check "FE-01 npm audit (high and critical)" npm audit --audit-level=high
check "FE-02 TypeScript type check (strict)" npm run typecheck
check "FE-03 ESLint (no warnings)" npm run lint
check "FE-04 component tests (Vitest)" npm test -- --color=false
check "FE-05 production build" npm run build

tally_finish "(frontend)"
