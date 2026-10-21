#!/usr/bin/env bash
#
# Fail if the Git index tracks local-only files:
#   - local agent configuration: .claude/, CLAUDE.md, CLAUDE.local.md,
#     .claudeignore (same policy as the local pre-commit hook)
#   - local runtime state: .runtime/
# Each rule applies at the repository root and at any directory depth.
#
# Usage: guard-tracked-files.sh [repository-path]
# Exit codes: 0 clean, 1 protected files tracked, 2 inspection error.
#
# Paths are read NUL-delimited, so names containing spaces, tabs,
# newlines or non-ASCII bytes are matched exactly and never C-quoted.
# Offending paths are printed with %q on a single, indented line, so a
# crafted name cannot inject CI log commands. File contents are never read.

set -u
LC_ALL=C
export LC_ALL

repo=${1:-.}

protected_re='(^|/)(\.claude(/|$)|CLAUDE(\.local)?\.md$|\.claudeignore$|\.runtime/)'

tmp=$(mktemp "${TMPDIR:-/tmp}/guard-tracked-files.XXXXXX") || {
  echo "ERROR: could not create a temporary file." >&2
  exit 2
}
trap 'rm -f "$tmp"' EXIT

# ls-files only lists the current directory's subtree, so always list
# from the top level; a subdirectory argument must not narrow the check.
if ! top=$(git -C "$repo" rev-parse --show-toplevel) || [ -z "$top" ]; then
  echo "ERROR: '$repo' is not inside a Git work tree." >&2
  exit 2
fi

if ! git -C "$top" ls-files -z >"$tmp"; then
  echo "ERROR: could not list tracked files in '$top'." >&2
  exit 2
fi

count=0
while IFS= read -r -d '' path; do
  if [[ $path =~ $protected_re ]]; then
    if [ "$count" -eq 0 ]; then
      echo "ERROR: local-only files are tracked by Git:"
    fi
    printf '  %q\n' "$path"
    count=$((count + 1))
  fi
done <"$tmp"

if [ "$count" -gt 0 ]; then
  echo "Remove them from the index (git rm --cached <path>) and keep them local."
  exit 1
fi

echo "OK: no local-only files are tracked."
exit 0
