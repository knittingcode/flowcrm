#!/usr/bin/env bash
#
# Cross-user check of the generated secrets (U-16): another local user
# (nobody) can neither list the secrets directory nor read a secret that
# bin/devenv generated.
#
# This suite owns that check; tests/devenv/unit.sh cannot run it, because
# setuid programs such as sudo do not work inside scripts/ci/no-docker.sh.
# It is split in two parts so that no code under test runs with the
# caller's privileges outside the isolation:
#   1. The checkout's own bin/devenv (never a copy named by DEVENV or any
#      other input) runs ensure_secrets under scripts/ci/no-docker.sh, with
#      its runtime directory in a fresh directory below /tmp and a fake
#      docker that reports no volume.
#   2. Outside the isolation, this script checks the result as data (file
#      type, owner, modes; never the contents) and then runs only fixed
#      commands as nobody on fixed paths: /bin/cat FILE and /bin/ls DIR.
# A control file that this script makes in a 0755 directory next to the
# secrets directory, and that nobody must be able to read, proves that the
# path is reachable for nobody and that the read check detects an exposed
# file.
#
# The check needs passwordless sudo. Without it the suite prints INFO and
# exits 0, except in CI (CI=true), where that is a failure.
#
# It certifies the committed code, so it refuses (exit 64) when DEVENV,
# GUARD, ADAPTED or NO_DOCKER_ACTIVE is set, outside a Git checkout, and
# when one of the files it runs differs from HEAD. It is not a mutation
# harness: run mutated code only through unit.sh and scripts/ci/tests/.
#
# Usage: tests/devenv/cross-user.sh
# Exit codes: 0 passed (or skipped locally), 1 a check failed,
#             2 result tally mismatch, 64 refused

# shellcheck source-path=SCRIPTDIR

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P) || exit 64
root=$(cd -P "$here/../.." && pwd -P) || exit 64

refuse() {
  printf 'cross-user: refused: %s\n' "$1" >&2
  exit 64
}

[ $# -eq 0 ] || refuse "no arguments are accepted"
for var in DEVENV GUARD ADAPTED NO_DOCKER_ACTIVE; do
  [ -z "${!var+set}" ] || refuse "$var is set; this check runs only the checkout's own code, outside the isolation"
done

# The files this suite runs, outside or inside the isolation.
involved='bin/devenv tests/devenv/cross-user.sh tests/devenv/tally.sh scripts/ci/no-docker.sh scripts/ci/no-docker-probe.py'
# shellcheck disable=SC2086 # the fixed list of paths is split into words
{
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    git -C "$root" ls-files --error-unmatch -- $involved >/dev/null 2>&1
} || refuse "not a Git checkout with $involved tracked"
# shellcheck disable=SC2086
git -C "$root" -c core.fsmonitor=false diff --no-ext-diff --no-textconv --quiet HEAD -- $involved ||
  refuse "local modifications to $involved; commit them first (an edited file cannot be told from a mutated one)"

# shellcheck source=tally.sh
. "$here/tally.sh"

cd / || exit 64
if ! sudo -n -u nobody -- /usr/bin/true 2>/dev/null; then
  if [ "${CI-}" = true ]; then
    printf 'FAIL  CU-00 passwordless sudo to the user nobody is required in CI\n'
    exit 1
  fi
  printf 'INFO  CU cross-user read check needs passwordless sudo to the user nobody (runs in CI); skipped\n'
  exit 0
fi

# Below /tmp, not $TMPDIR: on macOS $TMPDIR is a 0700 per-user directory, so
# nobody could not reach anything below it and the check would pass for the
# wrong reason. The parents of the runtime directory are 0755 for the same
# reason; the control file below proves it.
base=$(mktemp -d /tmp/flowcrm-cross-user.XXXXXX) || exit 2
base=$(cd -P "$base" && pwd -P) || exit 2
trap 'rm -rf "$base"' EXIT
tally_init "$base/tally"

result() { # name ok(0|1) [detail]
  if [ "$2" -eq 0 ]; then pass_result "$1"; else fail_result "$1${3:+ $3}"; fi
}

rt=$base/rt
secrets_dir=$rt/secrets
names='db_password db_owner_password db_app_password app_secret'
mkdir "$base/bin" "$rt" && chmod 0755 "$base" "$rt" || exit 2
printf '#!/bin/sh\nexit 1\n' >"$base/bin/docker" && chmod 0755 "$base/bin/docker" || exit 2
# The control: a directory as open as the secrets directory must not be,
# with a 0444 file at the depth of a secret, made by this script.
{ mkdir "$rt/control" && chmod 0755 "$rt/control" && printf 'control\n' >"$rt/control/file" &&
  chmod 0444 "$rt/control/file"; } || exit 2

# --- part 1, isolated: the checkout's bin/devenv generates the secrets
# shellcheck disable=SC2016 # expanded by the isolated shell
"$root/scripts/ci/no-docker.sh" "$BASH" -c '
  set -u
  . "$1" || exit 2
  FLOWCRM_STACK=app
  init_paths
  RUNTIME_DIR=$2 SECRETS_DIR=$2/secrets STATE_FILE=$2/dev.env LOCK_DIR=$2/lock
  GATE_DIR=$2/gate GATE_FILE=$2/gate/security-gate
  PATH=$3:$PATH
  ensure_secrets
' cross-user "$root/bin/devenv" "$rt" "$base/bin" 2>"$base/generate.err"
rc=$?

# --- part 2, outside the isolation: checks as data, then fixed reads as nobody
mode_of() { # GNU stat first: its -f means file system status
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
ok=0
{ [ "$rc" = 0 ] && [ ! -L "$rt" ] && [ -d "$rt" ] && [ ! -L "$secrets_dir" ] && [ -d "$secrets_dir" ] &&
  [ -O "$secrets_dir" ] && [ "$(mode_of "$secrets_dir")" = 700 ]; } || ok=1
for name in $names; do
  f=$secrets_dir/$name
  { [ ! -L "$f" ] && [ -f "$f" ] && [ -s "$f" ] && [ -O "$f" ] && [ "$(mode_of "$f")" = 444 ]; } || ok=1
done
result "CU-01 the checkout's bin/devenv created the secrets in the isolation (directory 0700, regular files 0444)" $ok \
  "(rc $rc: $(head -c 2000 "$base/generate.err" | tr '\n' ' ' | tr -cd '[:print:]'))"

as_nobody() { sudo -n -u nobody -- "$@" >/dev/null 2>&1; }

as_nobody /bin/cat "$rt/control/file"
result "CU-02 control: nobody can read a 0444 file in a 0755 directory next to the secrets directory (the path is reachable and the read check detects an exposed file)" $?

if as_nobody /bin/ls "$secrets_dir"; then r=1; else r=0; fi
result "CU-03 nobody cannot list the secrets directory" $r
for name in $names; do
  if as_nobody /bin/cat "$secrets_dir/$name"; then r=1; else r=0; fi
  result "CU-04 nobody cannot read the secret $name" $r
done
# Nothing here changes, follows or executes a path that the isolated code
# could have replaced (such as a symbolic link to a file of the caller):
# the paths are only tested, stat'ed and read by nobody.

tally_finish ""
