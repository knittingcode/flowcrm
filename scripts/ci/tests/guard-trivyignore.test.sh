#!/usr/bin/env bash
#
# Regression tests for scripts/ci/guard-trivyignore.sh.
# Every case runs in its own temporary Git repository with a fixed date
# (GUARD_TODAY); the repository under test is only read.
#
# Usage: guard-trivyignore.test.sh
# GUARD=<path> runs the suite against another implementation.

set -u

here=$(cd "$(dirname "$0")" && pwd)
guard=${GUARD:-"$here/../guard-trivyignore.sh"}
real=$(git -C "$here" rev-parse --show-toplevel) || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/guard-trivyignore-tests.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
# Never let Git discover a repository above the fixtures.
export GIT_CEILING_DIRECTORIES=$work
export GUARD_TODAY=2026-10-24

NL=$'\n'
HEADER="# Exceptions (fixture).${NL}#${NL}"
DOC="# Container vulnerabilities${NL}${NL}CVE-2026-0001 and GHSA-xjj6-f33q-929c are documented here.${NL}"
pass=0
fail=0
case_no=0

# expect <name> <expected-exit> <trivyignore content> [doc content]
expect() {
  local name=$1 want=$2 repo got
  case_no=$((case_no + 1))
  repo="$work/repo-$case_no"
  git init -q "$repo" || exit 2
  mkdir -p "$repo/security" "$repo/docs/security"
  printf '%s' "$3" >"$repo/security/trivyignore.yaml"
  printf '%s' "${4-$DOC}" >"$repo/docs/security/container-vulnerabilities.md"
  run "$name" "$want" "$repo"
}

run() { # name expected-exit repo
  local name=$1 want=$2 got
  "$guard" "$3" >"$work/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    printf 'PASS  %-66s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-66s exit=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/      | /' "$work/out"
  fi
}

# entry <id> <expired_at> [paths-line] [statement-line]: one documented entry.
entry() {
  printf '  - id: %s\n%s\n%s\n    expired_at: %s\n' "$1" \
    "${3-    paths: [\"usr/local/bin/example\"]}" \
    "${4-    statement: \"Not reachable: the binary is never executed (evidence in the docs).\"}" "$2"
}

run "the repository's own exception file" 0 "$real"
expect "no exceptions" 0 "${HEADER}vulnerabilities: []${NL}"
expect "no exceptions, CRLF line endings" 0 "# c"$'\r'"${NL}vulnerabilities: []"$'\r'"${NL}"
expect "one documented entry" 0 "${HEADER}vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}"
expect "a GHSA entry with purls" 0 "vulnerabilities:${NL}$(entry GHSA-xjj6-f33q-929c 2026-11-30 '    purls: ["pkg:npm/undici@6.29.0"]')${NL}"
expect "expiry exactly 90 days ahead" 0 "vulnerabilities:${NL}$(entry CVE-2026-0001 2027-01-22)${NL}"
expect "an already expired entry (Trivy no longer applies it)" 0 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-10-01)${NL}"
expect "expiry 91 days ahead" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2027-01-23)${NL}"
expect "no expiry (permanent)" 1 "vulnerabilities:${NL}  - id: CVE-2026-0001${NL}    paths: [\"a\"]${NL}    statement: \"why\"${NL}"
expect "invalid date (30 February)" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-02-30)${NL}"
expect "date in another format" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 01.12.2026)${NL}"
expect "no statement" 1 "vulnerabilities:${NL}  - id: CVE-2026-0001${NL}    paths: [\"a\"]${NL}    expired_at: 2026-12-01${NL}"
expect "empty statement" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["a"]' '    statement: ""')${NL}"
expect "no paths or purls" 1 "vulnerabilities:${NL}  - id: CVE-2026-0001${NL}    statement: \"why\"${NL}    expired_at: 2026-12-01${NL}"
expect "wildcard path" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["usr/**"]')${NL}"
expect "empty paths list" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: []')${NL}"
expect "wildcard id" 1 "vulnerabilities:${NL}$(entry 'CVE-2026-*' 2026-12-01)${NL}"
expect "not a vulnerability id" 1 "vulnerabilities:${NL}$(entry HIGH 2026-12-01)${NL}"
expect "duplicate id" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}$(entry CVE-2026-0001 2026-12-02)${NL}"
expect "entry not listed in the docs" 1 "vulnerabilities:${NL}$(entry CVE-2026-0002 2026-12-01)${NL}"
expect "unknown key in an entry" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}    severity: HIGH${NL}"
expect "another top-level section" 1 "vulnerabilities: []${NL}misconfigurations:${NL}  - id: AVD-DS-0001${NL}"
expect "section without entries" 1 "vulnerabilities:${NL}"
expect "no section at all" 1 "# only comments${NL}"
expect "a different YAML style" 1 "vulnerabilities:${NL}- id: CVE-2026-0001${NL}  paths: [\"a\"]${NL}  statement: \"why\"${NL}  expired_at: 2026-12-01${NL}"
mkdir -p "$work/nofile" && git init -q "$work/nofile" || exit 2
run "missing exception file" 2 "$work/nofile"
mkdir -p "$work/nogit"
run "not a Git work tree" 2 "$work/nogit"

printf '\nTOTAL %d passed=%d failed=%d\n' $((pass + fail)) "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
