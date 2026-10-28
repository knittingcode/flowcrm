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

# fixture <trivyignore content> [doc content]: a new repository in $repo.
fixture() {
  case_no=$((case_no + 1))
  repo="$work/repo-$case_no"
  git init -q "$repo" || exit 2
  mkdir -p "$repo/security" "$repo/docs/security"
  printf '%s' "$1" >"$repo/security/trivyignore.yaml"
  printf '%s' "${2-$DOC}" >"$repo/docs/security/container-vulnerabilities.md"
}

# expect <name> <expected-exit> <trivyignore content> [doc content]
expect() {
  fixture "$3" ${4+"$4"}
  run "$1" "$2" "$repo"
}

# expect_bytes <name> <expected-exit> <printf format of the trivyignore
# content>: for bytes a shell string cannot hold (NUL).
expect_bytes() {
  fixture ''
  # shellcheck disable=SC2059 # the format is the fixture
  printf "$3" >"$repo/security/trivyignore.yaml"
  run "$1" "$2" "$repo"
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
expect "a key repeated in an entry (a parser taking the first would apply 2099)" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2099-01-01)${NL}    expired_at: 2026-12-01${NL}"
expect "paths repeated in an entry" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}    paths: [\"other\"]${NL}"
expect "a blank path" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: [" "]')${NL}"
expect "the same key in two entries" 0 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}$(entry GHSA-xjj6-f33q-929c 2026-12-02)${NL}"
expect "unknown key in an entry" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}    severity: HIGH${NL}"
expect "another top-level section" 1 "vulnerabilities: []${NL}misconfigurations:${NL}  - id: AVD-DS-0001${NL}"
expect "section without entries" 1 "vulnerabilities:${NL}"
expect "no section at all" 1 "# only comments${NL}"
# Content that YAML reads differently from the line-based check: escapes
# inside double quotes, and characters that YAML treats as line breaks
# (CR, NEL U+0085, LS U+2028) hiding lines inside what the check sees as a
# comment or a value. Each was applied by Trivy 0.67.2 while the guard
# reported OK.
expect "an escaped quote continues the statement over expired_at (YAML: no expiry)" 1 \
  "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["a"]' '    statement: "why\"')${NL}    # \"${NL}"
expect "an escaped wildcard in paths (YAML: \\x2a is *)" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["\x2a"]')${NL}"
expect "an escape in purls" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    purls: ["pkg:npm/a@1\u002a"]')${NL}"
expect "an entry hidden behind a CR in a comment" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}# note"$'\r'"  - id: CVE-2026-0002${NL}"
expect "an entry hidden behind a CR in a statement" 1 \
  "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["a"]' '    statement: "why" #'$'\r''  - id: CVE-2026-0002 #"')${NL}"
expect "an entry hidden behind NEL (U+0085) in a comment" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}# note"$'\xc2\x85'"  - id: CVE-2026-0002${NL}"
expect "an entry hidden behind LS (U+2028) in a comment" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01)${NL}# note"$'\xe2\x80\xa8'"  - id: CVE-2026-0002${NL}"
expect "one documented entry, CRLF line endings" 0 "vulnerabilities:"$'\r'"${NL}$(entry CVE-2026-0001 2026-12-01 | sed $'s/$/\r/')${NL}"
expect "a statement with apostrophes and #" 0 \
  "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["a"]' "    statement: \"The binary isn't run (see #12).\"")${NL}"
# Glob syntax of the path patterns (Trivy matches paths with doublestar):
# besides * and ?, a character class or braces match other paths. Each was
# applied by Trivy 0.67.2 while the guard reported OK.
expect "a character class in paths (doublestar: [p] matches p)" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["[p]ackage-lock.json"]')${NL}"
expect "a negated class in paths" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    paths: ["[!x]ackage-lock.json"]')${NL}"
# (in a variable: bash 3.2 brace-expands a quoted word inside "$(...)")
braces='    paths: ["{package-lock.json,other}"]'
expect "braces in paths (doublestar alternatives)" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 "$braces")${NL}"
expect "a closing bracket alone in purls" 1 "vulnerabilities:${NL}$(entry CVE-2026-0001 2026-12-01 '    purls: ["pkg:npm/a@1]"]')${NL}"
# bash drops a NUL byte when it reads a line; Trivy refuses the file.
expect_bytes "a NUL byte in a comment" 1 'vulnerabilities: []\n# a\000b\n'
expect_bytes "a NUL byte in a statement" 1 'vulnerabilities:\n  - id: CVE-2026-0001\n    paths: ["a"]\n    statement: "wh\000y"\n    expired_at: 2026-12-01\n'
expect "a different YAML style" 1 "vulnerabilities:${NL}- id: CVE-2026-0001${NL}  paths: [\"a\"]${NL}  statement: \"why\"${NL}  expired_at: 2026-12-01${NL}"
mkdir -p "$work/nofile" && git init -q "$work/nofile" || exit 2
run "missing exception file" 2 "$work/nofile"
mkdir -p "$work/nogit"
run "not a Git work tree" 2 "$work/nogit"

printf '\nTOTAL %d passed=%d failed=%d\n' $((pass + fail)) "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
