#!/usr/bin/env bash
#
# Fail unless every tracked Dockerfile pins its BuildKit frontend:
#   - line 1 is a "# syntax=" parser directive (BuildKit honours it only
#     at the top of the file);
#   - its value is <image>:<tag>@sha256:<64 lowercase hex>, so a mutable
#     tag such as docker/dockerfile:1 cannot select a different frontend;
#   - every Dockerfile uses the same reference, and no other "syntax"
#     directive appears anywhere in the file.
# Dockerfiles are tracked files named Dockerfile, Dockerfile.<x>,
# <x>.Dockerfile or Containerfile (any case), at any directory depth.
#
# Usage: guard-dockerfile-frontend.sh [repository-path]
# Exit codes: 0 all pinned, 1 unpinned or malformed reference,
#             2 inspection error (including no Dockerfiles found).
#
# Paths are read NUL-delimited and printed with %q on single, indented
# lines, as are directive values, so crafted content cannot inject CI log
# commands.

set -u
LC_ALL=C
export LC_ALL

repo=${1:-.}

name_re='(^|/)([Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee](\.[^/]+)?|[^/]+\.[Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee]|[Cc][Oo][Nn][Tt][Aa][Ii][Nn][Ee][Rr][Ff][Ii][Ll][Ee])$'
directive_re='^[[:space:]]*#[[:space:]]*[Ss][Yy][Nn][Tt][Aa][Xx][[:space:]]*=[[:space:]]*(.*)$'
# [registry[:port]/]path:tag@sha256:digest (OCI distribution reference).
component='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
pinned_re="^([a-zA-Z0-9.-]+(:[0-9]+)?/)?$component(/$component)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}@sha256:[0-9a-f]{64}$"

tmp=$(mktemp "${TMPDIR:-/tmp}/guard-dockerfile-frontend.XXXXXX") || {
  echo "ERROR: could not create a temporary file." >&2
  exit 2
}
trap 'rm -f "$tmp"' EXIT

if ! top=$(git -C "$repo" rev-parse --show-toplevel) || [ -z "$top" ]; then
  echo "ERROR: '$repo' is not inside a Git work tree." >&2
  exit 2
fi

if ! git -C "$top" ls-files -z >"$tmp"; then
  echo "ERROR: could not list tracked files in '$top'." >&2
  exit 2
fi

# report <path> <message> [value]
errors=0
report() {
  if [ "$errors" -eq 0 ]; then
    echo "ERROR: Dockerfile frontend is not pinned by digest:"
  fi
  if [ $# -ge 3 ]; then
    printf '  %q: %s: %q\n' "$1" "$2" "$3"
  else
    printf '  %q: %s\n' "$1" "$2"
  fi
  errors=$((errors + 1))
}

checked=0
first_ref=
while IFS= read -r -d '' path; do
  [[ $path =~ $name_re ]] || continue
  file="$top/$path"
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "ERROR: cannot read tracked Dockerfile $(printf '%q' "$path")." >&2
    exit 2
  fi
  checked=$((checked + 1))
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    line=${line%$'\r'}
    if [ "$line_no" -eq 1 ]; then
      line=${line#$'\xef\xbb\xbf'}
    fi
    if [[ $line =~ $directive_re ]]; then
      value=${BASH_REMATCH[1]}
      value=${value%"${value##*[![:space:]]}"}
      if [ "$line_no" -ne 1 ]; then
        report "$path" "line $line_no: syntax directive outside line 1" "$value"
      elif [[ ! $value =~ $pinned_re ]]; then
        report "$path" "line 1: not <image>:<tag>@sha256:<digest>" "$value"
      elif [ -z "$first_ref" ]; then
        first_ref=$value
      elif [ "$value" != "$first_ref" ]; then
        report "$path" "line 1: differs from the other Dockerfiles" "$value"
      fi
    elif [ "$line_no" -eq 1 ]; then
      report "$path" "line 1: missing '# syntax=' directive"
    fi
  done <"$file"
  if [ "$line_no" -eq 0 ]; then
    report "$path" "empty file"
  fi
done <"$tmp"

if [ "$checked" -eq 0 ]; then
  echo "ERROR: no tracked Dockerfiles found in '$top'." >&2
  exit 2
fi

if [ "$errors" -gt 0 ]; then
  echo "Pin the frontend as '# syntax=<image>:<tag>@sha256:<digest>' on line 1 (docs/dev-environment.md)."
  exit 1
fi

printf 'OK: %d Dockerfiles pin the frontend %s\n' "$checked" "$first_ref"
exit 0
