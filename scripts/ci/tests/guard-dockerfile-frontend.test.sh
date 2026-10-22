#!/usr/bin/env bash
#
# Regression tests for scripts/ci/guard-dockerfile-frontend.sh.
# Every case runs in its own temporary Git repository; the repository
# under test is only read (its tracked Dockerfiles are copied as fixtures).
#
# Usage: guard-dockerfile-frontend.test.sh
# GUARD=<path> runs the suite against another implementation.

set -u

here=$(cd "$(dirname "$0")" && pwd)
guard=${GUARD:-"$here/../guard-dockerfile-frontend.sh"}
real=$(git -C "$here" rev-parse --show-toplevel) || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/guard-frontend-tests.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
# Never let Git discover a repository above the fixtures.
export GIT_CEILING_DIRECTORIES=$work

NL=$'\n'
CR=$'\r'
D=4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
PINNED="docker/dockerfile:1.27.1@sha256:$D"
BODY="FROM scratch${NL}COPY a /a${NL}"
pass=0
fail=0
case_no=0

new_repo() {
  case_no=$((case_no + 1))
  repo="$work/repo-$case_no"
  git init -q "$repo" || exit 2
}

# put <repo> <path> <content>: write the file and add it to the index.
put() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%s' "$3" >"$1/$2"
  git -C "$1" add -f -- "$2" || exit 2
}

# expect <name> <expected-exit> <repo>
expect() {
  local name=$1 want=$2 repo=$3 got
  "$guard" "$repo" >"$work/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    printf 'PASS  %-62s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-62s exit=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/      | /' "$work/out"
  fi
}

# directive <name> <expected-exit> <line-1>: one Dockerfile per case.
directive() {
  new_repo
  put "$repo" Dockerfile "$3${NL}${BODY}"
  expect "$1" "$2" "$repo"
}

# Accepted references
directive "pinned tag and digest" 0 "# syntax=$PINNED"
directive "fully qualified docker.io reference" 0 "# syntax=docker.io/$PINNED"
directive "registry with port" 0 "# syntax=registry.example:5000/tools/frontend:1.0@sha256:$D"
directive "spaces around '=' and after '#'" 0 "#  syntax = $PINNED"
directive "no space after '#'" 0 "#syntax=$PINNED"
directive "upper-case directive key" 0 "# SYNTAX=$PINNED"
directive "trailing whitespace" 0 "# syntax=$PINNED  "

# Mutable references
directive "docker/dockerfile:1" 1 "# syntax=docker/dockerfile:1"
directive "docker/dockerfile:1 with upper-case key" 1 "# SYNTAX=docker/dockerfile:1"
directive "docker/dockerfile:1 with spaces" 1 "#  syntax = docker/dockerfile:1"
directive "docker/dockerfile:latest" 1 "# syntax=docker/dockerfile:latest"
directive "docker/dockerfile without tag" 1 "# syntax=docker/dockerfile"
directive "exact version tag without digest" 1 "# syntax=docker/dockerfile:1.27.1"
directive "docker.io/docker/dockerfile:1-labs" 1 "# syntax=docker.io/docker/dockerfile:1-labs"
directive "other external frontend by tag" 1 "# syntax=registry.example/custom/frontend:v2"
directive "other frontend with registry port, no digest" 1 "# syntax=registry.example:5000/fe:1"

# Malformed digest references
directive "digest without tag" 1 "# syntax=docker/dockerfile@sha256:$D"
directive "digest with 63 hex digits" 1 "# syntax=docker/dockerfile:1.27.1@sha256:${D:1}"
directive "digest with 65 hex digits" 1 "# syntax=docker/dockerfile:1.27.1@sha256:${D}0"
directive "upper-case hex digest" 1 "# syntax=docker/dockerfile:1.27.1@sha256:$(printf '%s' "$D" | tr a-f A-F)"
directive "non-hex digest character" 1 "# syntax=docker/dockerfile:1.27.1@sha256:g${D:1}"
directive "sha512 algorithm" 1 "# syntax=docker/dockerfile:1.27.1@sha512:$D$D"
directive "empty digest" 1 "# syntax=docker/dockerfile:1.27.1@sha256:"
directive "missing algorithm" 1 "# syntax=docker/dockerfile:1.27.1@$D"
directive "two digests" 1 "# syntax=$PINNED@sha256:$D"
directive "trailing text after digest" 1 "# syntax=$PINNED extra"
directive "upper-case image name" 1 "# syntax=Docker/Dockerfile:1.27.1@sha256:$D"
directive "empty value" 1 "# syntax="

# Placement
directive "no directive" 1 "# Just a comment"
directive "instruction on line 1" 1 "FROM scratch"
new_repo
put "$repo" Dockerfile "# comment${NL}# syntax=$PINNED${NL}${BODY}"
expect "pinned directive on line 2 (ignored by BuildKit)" 1 "$repo"
new_repo
put "$repo" Dockerfile "${NL}# syntax=$PINNED${NL}${BODY}"
expect "pinned directive after an empty line" 1 "$repo"
new_repo
put "$repo" Dockerfile "# syntax=$PINNED${NL}${BODY}# syntax=docker/dockerfile:1${NL}"
expect "second, mutable directive further down" 1 "$repo"
new_repo
put "$repo" Dockerfile "# syntax=$PINNED${NL}${BODY}# syntax=$PINNED${NL}"
expect "second, identical directive further down" 1 "$repo"
new_repo
put "$repo" Dockerfile ""
expect "empty Dockerfile" 1 "$repo"
new_repo
put "$repo" Dockerfile "# syntax=$PINNED${CR}${NL}FROM scratch${CR}${NL}"
expect "CRLF line endings" 0 "$repo"
new_repo
put "$repo" Dockerfile $'\xef\xbb\xbf'"# syntax=$PINNED${NL}${BODY}"
expect "UTF-8 byte order mark" 0 "$repo"
new_repo
put "$repo" Dockerfile "# syntax=$PINNED"
expect "single line without final newline" 0 "$repo"

# File names
for name in dockerfile Dockerfile.prod docker/x/build.Dockerfile app.dockerfile Containerfile; do
  new_repo
  put "$repo" "$name" "# syntax=docker/dockerfile:1${NL}${BODY}"
  expect "unpinned $name" 1 "$repo"
done
new_repo
put "$repo" Dockerfile "# syntax=$PINNED${NL}${BODY}"
put "$repo" README.md "# syntax=docker/dockerfile:1${NL}"
put "$repo" docs/Dockerfile-notes.txt "# syntax=docker/dockerfile:1${NL}"
put "$repo" mydockerfile "# syntax=docker/dockerfile:1${NL}"
expect "non-Dockerfiles are not checked" 0 "$repo"
new_repo
put "$repo" README.md "text${NL}"
expect "no tracked Dockerfile (inspection error)" 2 "$repo"
mkdir -p "$work/not-a-repo"
expect "not a Git repository (inspection error)" 2 "$work/not-a-repo"
new_repo
printf '# syntax=docker/dockerfile:1\n' >"$repo/Dockerfile"
expect "untracked Dockerfile only (inspection error)" 2 "$repo"

# Consistency
new_repo
put "$repo" a/Dockerfile "# syntax=$PINNED${NL}${BODY}"
put "$repo" b/Dockerfile "# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b${NL}${BODY}"
expect "two different pinned references" 1 "$repo"
new_repo
put "$repo" a/Dockerfile "# syntax=$PINNED${NL}${BODY}"
put "$repo" b/Dockerfile "# syntax=docker/dockerfile:1${NL}${BODY}"
expect "one pinned, one mutable" 1 "$repo"

# The actual repository and mutations of its own Dockerfiles.
expect "actual repository" 0 "$real"
real_files=()
while IFS= read -r -d '' f; do
  real_files+=("$f")
done < <(git -C "$real" ls-files -z -- 'docker/*/Dockerfile')
if [ "${#real_files[@]}" -ge 5 ] &&
  grep -q "^OK: ${#real_files[@]} Dockerfiles " "$work/out"; then
  pass=$((pass + 1))
  printf 'PASS  %-62s\n' "actual repository: all ${#real_files[@]} docker/*/Dockerfile checked"
else
  fail=$((fail + 1))
  printf 'FAIL  %-62s\n' "actual repository: every docker/*/Dockerfile checked"
  sed 's/^/      | /' "$work/out"
fi

# copy_real <repo>: track copies of every real Dockerfile in <repo>.
copy_real() {
  local f
  for f in "${real_files[@]}"; do
    mkdir -p "$1/$(dirname "$f")"
    cp "$real/$f" "$1/$f"
    git -C "$1" add -f -- "$f" || exit 2
  done
}

new_repo
copy_real "$repo"
expect "copy of the actual Dockerfiles" 0 "$repo"
for f in "${real_files[@]}"; do
  for mutation in \
    "unpinned:1s|^# syntax=.*|# syntax=docker/dockerfile:1|" \
    "tag-only:1s|@sha256:[0-9a-f]*$||" \
    "short-digest:1s|[0-9a-f]\$||" \
    "removed:1d"; do
    new_repo
    copy_real "$repo"
    sed "${mutation#*:}" "$real/$f" >"$repo/$f"
    if cmp -s "$real/$f" "$repo/$f"; then
      echo "HARNESS ERROR: mutation ${mutation%%:*} did not change $f" >&2
      exit 2
    fi
    git -C "$repo" add -f -- "$f" || exit 2
    expect "actual $f: ${mutation%%:*}" 1 "$repo"
  done
done

# Output safety: crafted names and values stay on escaped, indented lines.
new_repo
put "$repo" "a${NL}::error::x/Dockerfile" "# syntax=::warning::x${NL}${BODY}"
"$guard" "$repo" >"$work/out" 2>&1
if grep -q '^::' "$work/out"; then
  fail=$((fail + 1))
  printf 'FAIL  %-62s\n' "crafted path and value printed on escaped lines"
  sed 's/^/      | /' "$work/out"
else
  pass=$((pass + 1))
  printf 'PASS  %-62s\n' "crafted path and value printed on escaped lines"
fi

echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
