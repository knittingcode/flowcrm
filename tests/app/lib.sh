# shellcheck shell=bash
#
# Shared helpers of the application-stack test runners (sourced).
# Every Docker resource is created under a Compose project name that the
# runner owns; cleanup removes only those projects, checked by label.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../devenv/tally.sh
. "$(dirname "${BASH_SOURCE[0]}")/../devenv/tally.sh"

APP_REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
APP_CURL_IMAGE=curlimages/curl:8.17.0@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40
# The BusyBox image of compose.fixture.yaml, for throwaway control containers.
# shellcheck disable=SC2034 # used by stack.sh
APP_FIXTURE_IMAGE=busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e

say() { printf '%s\n' "$*"; }
ok() { pass_result "$1"; }
bad() { fail_result "$1"; [ -z "${2-}" ] || say "      $2"; }
# Usage: <condition>; v "ID description" $?
v() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3-}"; fi; }
ev() { say "      evidence: $*"; }
# A setup step that must succeed; otherwise a FAIL is recorded and the
# runner stops. Usage: need "what" command...
need() {
  local what=$1
  shift
  "$@" && return 0
  bad "$what (setup failed)"
  return 1
}

sha6() { printf '%s' "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -c1-6; }
project_of() { printf 'flowcrm-%s' "$(sha6 "$1")"; }

random_secret() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }

# Writes the application secrets (bootstrap, owner and runtime database
# passwords, app secret) into a new directory; prints its path.
make_secrets() {
  local dir name
  dir=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-secrets.XXXXXX") || return 1
  chmod 0700 "$dir"
  for name in db_password db_owner_password db_app_password app_secret; do
    random_secret >"$dir/$name"
    chmod 0444 "$dir/$name"
  done
  printf '%s\n' "$dir"
}

# Copies the tracked and new (not ignored) files the stack needs into DIR.
copy_checkout() { # dir
  mkdir -p "$1" &&
    (cd "$APP_REPO" && git ls-files -z -co --exclude-standard -- \
      .dockerignore Makefile bin compose.yaml compose.fixture.yaml docker backend frontend) |
    (cd "$APP_REPO" && tar -cf - --null -T -) | (cd "$1" && tar -xf -)
}

# Removes the containers, volumes and networks of PROJECT, but only those
# labelled with PROJECT and, for containers, created from DIR.
remove_project() { # project dir
  local p=$1 dir=$2 id
  docker ps -aq --filter "label=com.docker.compose.project=$p" --filter "label=com.docker.compose.project.working_dir=$dir" |
    while read -r id; do docker rm -f "$id" >/dev/null 2>&1; done
  docker volume ls -q --filter "label=com.docker.compose.project=$p" |
    while read -r id; do docker volume rm "$id" >/dev/null 2>&1; done
  docker network ls -q --filter "label=com.docker.compose.project=$p" |
    while read -r id; do docker network rm "$id" >/dev/null 2>&1; done
}

project_resources() { # project: number of containers + volumes + networks left
  local p=$1
  echo $(($(docker ps -aq --filter "label=com.docker.compose.project=$p" | wc -l) +
    $(docker volume ls -q --filter "label=com.docker.compose.project=$p" | wc -l) +
    $(docker network ls -q --filter "label=com.docker.compose.project=$p" | wc -l)))
}

# curl from a throwaway container on a project network (no host port).
# Usage: net_curl network curl-args...
net_curl() {
  local net=$1
  shift
  docker run --rm --network "$net" "$APP_CURL_IMAGE" -sS --max-time 10 "$@"
}

# Synthetic demonstration data through the operator console of an api
# container (FND-010B): users admin, rep, multi, other and spare (.test
# addresses with a random part), organization A (admin ADMIN, rep REP, multi
# REP) and B (other ADMIN, multi MANAGER); spare has no membership, for the
# member administration journeys (FND-010C). Passwords go to the console's standard
# input, never into an argument. Writes the E2E_* variables for the browser
# tests into ENV-FILE (which holds the synthetic password: keep it in the
# runner's work directory). Values have no spaces: the file is both sourced
# by bash and read by docker --env-file.
seed_e2e() { # env-file api-container
  local env=$1 api=$2 password suffix who org_a org_b
  password=$(random_secret)
  suffix=$(random_secret | cut -c1-8)
  console() { docker exec -i "$api" php bin/console --no-interaction "$@"; }
  for who in Admin Rep Multi Other Spare; do
    printf '%s\n' "$password" |
      console flowcrm:user:create --email="$(printf '%s' "$who" | tr '[:upper:]' '[:lower:]')-$suffix@example.test" --display-name="$who Tester" >/dev/null || return 1
  done
  org_a=$(console flowcrm:organization:create --name="Alpha-$suffix" --admin-email="admin-$suffix@example.test") || return 1
  org_b=$(console flowcrm:organization:create --name="Beta-$suffix" --admin-email="other-$suffix@example.test") || return 1
  console flowcrm:membership:add --organization="$org_a" --email="rep-$suffix@example.test" --role=REP >/dev/null &&
    console flowcrm:membership:add --organization="$org_a" --email="multi-$suffix@example.test" --role=REP >/dev/null &&
    console flowcrm:membership:add --organization="$org_b" --email="multi-$suffix@example.test" --role=MANAGER >/dev/null || return 1
  (umask 077 && printf '%s\n' \
    "E2E_PASSWORD=$password" \
    "E2E_ADMIN_EMAIL=admin-$suffix@example.test" \
    "E2E_REP_EMAIL=rep-$suffix@example.test" \
    "E2E_MULTI_EMAIL=multi-$suffix@example.test" \
    "E2E_SPARE_EMAIL=spare-$suffix@example.test" \
    "E2E_ORG_A=$org_a" "E2E_ORG_A_NAME=Alpha-$suffix" \
    "E2E_ORG_B=$org_b" "E2E_ORG_B_NAME=Beta-$suffix" >"$env")
}
