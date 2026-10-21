#!/usr/bin/env bash
#
# Regression tests for scripts/ci/guard-tracked-files.sh.
# Every case runs in its own temporary Git repository; nothing is staged
# in the repository under test.
#
# Usage: guard-tracked-files.test.sh
# GUARD=<path> runs the suite against another implementation.

set -u

here=$(cd "$(dirname "$0")" && pwd)
guard=${GUARD:-"$here/../guard-tracked-files.sh"}
work=$(mktemp -d "${TMPDIR:-/tmp}/guard-tests.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
# Never let Git discover a repository above the fixtures.
export GIT_CEILING_DIRECTORIES=$work

TAB=$(printf '\t')
NL=$'\n'
pass=0
fail=0
case_no=0

# new_repo: create an empty repository and set $repo to its path.
# Not called via $(...), so the counter survives between cases.
new_repo() {
  case_no=$((case_no + 1))
  repo="$work/repo-$case_no"
  git init -q "$repo" || exit 2
}

# track <repo> <path>...: create each file and force it into the index.
track() {
  local repo=$1 path
  shift
  for path in "$@"; do
    mkdir -p "$repo/$(dirname "$path")"
    printf 'fixture\n' >"$repo/$path"
    git -C "$repo" add -f -- "$path" || exit 2
  done
  # Isolation check: the index holds exactly the paths of this case.
  local tracked
  tracked=$(git -C "$repo" ls-files -z | tr -cd '\000' | wc -c | tr -d ' ')
  if [ "$tracked" -ne "$#" ]; then
    echo "HARNESS ERROR: $repo tracks $tracked files, expected $#" >&2
    exit 2
  fi
}

# expect <name> <expected-exit> <repo>
expect() {
  local name=$1 want=$2 repo=$3 got
  "$guard" "$repo" >"$work/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1))
    printf 'PASS  %-58s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-58s exit=%s want=%s\n' "$name" "$got" "$want"
    sed 's/^/      | /' "$work/out"
  fi
}

# check <name> <expected-exit> <path>...: one fresh repository per case.
check() {
  local name=$1 want=$2
  shift 2
  new_repo
  track "$repo" "$@"
  expect "$name" "$want" "$repo"
}

# Allowed
check "PHP source file" 0 backend/src/Crm/Account.php
check "TypeScript source file" 0 frontend/src/features/accounts/AccountList.tsx
check "README.md at root" 0 README.md
check "lowercase docs/claude.md" 0 docs/claude.md
check "look-alike CLAUDE.md.bak" 0 docs/CLAUDE.md.bak
check "look-alike myCLAUDE.md" 0 docs/myCLAUDE.md
check "look-alike .claudeignore.txt" 0 docs/.claudeignore.txt
check "look-alike .claude-notes/x" 0 .claude-notes/x.md
check "look-alike runtime/dev.env" 0 runtime/dev.env
check "look-alike .runtimes/x" 0 .runtimes/x
check "non-ASCII ordinary file zażółć/Gęś.php" 0 "zażółć/Gęś.php"
check "space and tab in ordinary name" 0 "src/my file${TAB}x.php"
check "newline in ordinary name" 0 "src/line${NL}break.php"
check "newline before protected-looking text" 0 "notes${NL}CLAUDE.md.txt"

# Rejected
check "root CLAUDE.md" 1 CLAUDE.md
check "nested CLAUDE.md" 1 docs/CLAUDE.md
check "root .claude/settings.local.json" 1 .claude/settings.local.json
check "nested .claude/ file" 1 tools/config/.claude/settings.json
check "root .claudeignore" 1 .claudeignore
check "nested .claudeignore" 1 frontend/.claudeignore
check "root CLAUDE.local.md" 1 CLAUDE.local.md
check ".runtime/dev.env" 1 .runtime/dev.env
check "nested .runtime/ file" 1 backend/.runtime/state
check "non-ASCII dir é/CLAUDE.md" 1 "é/CLAUDE.md"
check "non-ASCII dir zażółć/.claude/x" 1 "zażółć/.claude/x.json"
check "space in dir: my dir/CLAUDE.md" 1 "my dir/CLAUDE.md"
check "tab in dir: tab<TAB>dir/CLAUDE.md" 1 "tab${TAB}dir/CLAUDE.md"
check "newline in dir: a<LF>b/CLAUDE.md" 1 "a${NL}b/CLAUDE.md"
check "quotes in dir: \"q\"/.claudeignore" 1 "\"q\"/.claudeignore"
check "ordinary file plus CLAUDE.md" 1 src/Service.php CLAUDE.md

# Clean repository and empty index
new_repo
expect "empty repository" 0 "$repo"
new_repo
track "$repo" README.md backend/composer.json frontend/package.json
expect "clean repository with ordinary files" 0 "$repo"

# Error handling: not a Git repository
mkdir -p "$work/not-a-repo"
expect "not a Git repository (inspection error)" 2 "$work/not-a-repo"

# Output safety: a newline in a path stays on one escaped line.
new_repo
track "$repo" "a${NL}::warning::x/CLAUDE.md"
"$guard" "$repo" >"$work/out" 2>&1
if grep -q '^::' "$work/out"; then
  fail=$((fail + 1))
  printf 'FAIL  %-58s\n' "offending path printed on a single escaped line"
  sed 's/^/      | /' "$work/out"
else
  pass=$((pass + 1))
  printf 'PASS  %-58s\n' "offending path printed on a single escaped line"
fi

echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
