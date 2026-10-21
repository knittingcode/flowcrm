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

# Writes the two application secrets into a new directory; prints its path.
make_secrets() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/flowcrm-secrets.XXXXXX") || return 1
  chmod 0700 "$dir"
  random_secret >"$dir/db_password"
  random_secret >"$dir/app_secret"
  chmod 0444 "$dir/db_password" "$dir/app_secret"
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
