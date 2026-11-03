#!/usr/bin/env bash
#
# Fail unless every exception of the container vulnerability gate
# (security/trivyignore.yaml, used by tests/app/scan.sh) follows the policy
# in docs/security/container-vulnerabilities.md:
#   - one specific vulnerability per entry: id is CVE-<year>-<number> or a
#     GHSA id, and no id appears twice. Trivy matches only the id it
#     reports (the CVE when one exists), so an id that the Exceptions table
#     of the docs lists as an alias in parentheses, as in
#     "| CVE-2026-0001 (GHSA-xxxx-xxxx-xxxx) |", is rejected: one
#     vulnerability cannot be spread over a second entry under its alias;
#   - the affected package is named exactly: "purls" with at least one
#     entry, each pkg:<type>/<namespace>/<name>@<version> with an exact
#     version and no qualifiers, subpath or percent-encoding (a purl
#     without a version matches every version), and all purls of an entry
#     name the same package (type, namespace and name), so one entry cannot
#     cover a second package such as another major version of a Go module;
#   - one entry per package: no two entries name the same package (purl
#     without its version), whatever their ids. Packages are compared
#     without regard to case, as Trivy matches a Go module path whatever its
#     case;
#   - the affected path is named exactly: "paths" with at least one entry;
#     neither list has a wildcard (Trivy matches paths as doublestar
#     patterns, so * ? [ ] { } are all rejected);
#   - the evidence for the risk decision is given: a non-empty "statement";
#   - no key appears twice in one entry (YAML parsers differ in which value
#     of a repeated key they keep);
#   - the file is read the same way by this check and by YAML: printable
#     ASCII only (YAML also breaks lines at CR, NEL and U+2028/U+2029, which
#     could hide lines inside a comment or a value; bash drops or cuts at a
#     NUL byte, so it is searched separately), and no backslash or
#     inner double quote in a quoted value (an escape could add a wildcard
#     or continue the value over the next lines);
#   - the decision is reviewed again: "expired_at" is a valid date after
#     today and no more than 90 days after it. An entry on or past its
#     expired_at fails, so it is renewed after a new review or removed
#     instead of lingering (Trivy stops applying it at 00:00 UTC of that
#     day, and the gate fails on the finding again);
#   - the entry is listed in docs/security/container-vulnerabilities.md:
#     its id starts a row of the table under "## Exceptions" (a mention
#     elsewhere in the document does not count). The alias check knows only
#     the aliases that table lists, so editing its first column can bypass
#     it; such an edit is visible in review and must be checked there.
# Only the documented form is accepted (see the example in the file):
# "vulnerabilities: []", or "vulnerabilities:" followed by entries of
# "  - id: ..." and "    <key>: <value>" lines, with full-line comments.
# Anything else, including other top-level sections, is rejected, so a
# broad or unreviewed rule cannot pass unnoticed.
#
# Usage: guard-trivyignore.sh [repository-path]
# GUARD_TODAY=YYYY-MM-DD replaces today's date (UTC), for the tests.
# Exit codes: 0 policy met, 1 policy violated or unsupported format,
#             2 inspection error.
#
# Values are printed with %q on single, indented lines, so crafted content
# cannot inject CI log commands.

set -u
LC_ALL=C
export LC_ALL

repo=${1:-.}
max_days=90

if ! top=$(git -C "$repo" rev-parse --show-toplevel) || [ -z "$top" ]; then
  echo "ERROR: '$repo' is not inside a Git work tree." >&2
  exit 2
fi
file=$top/security/trivyignore.yaml
doc=$top/docs/security/container-vulnerabilities.md
for f in "$file" "$doc"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "ERROR: cannot read $(printf '%q' "${f#"$top"/}")." >&2
    exit 2
  fi
done

# Days since 1970-01-01 of a YYYY-MM-DD date; fails for an invalid date.
days_of() {
  local y m d leap
  [[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  leap=$(((y % 4 == 0 && y % 100 != 0) || y % 400 == 0))
  case $m in
    1 | 3 | 5 | 7 | 8 | 10 | 12) [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 1 ;;
    4 | 6 | 9 | 11) [ "$d" -ge 1 ] && [ "$d" -le 30 ] || return 1 ;;
    2) [ "$d" -ge 1 ] && [ "$d" -le $((28 + leap)) ] || return 1 ;;
    *) return 1 ;;
  esac
  # Howard Hinnant's days_from_civil.
  [ "$m" -gt 2 ] || y=$((y - 1))
  local era=$((y / 400)) yoe doy doe
  yoe=$((y - era * 400))
  doy=$(((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s' $((era * 146097 + doe - 719468))
}

today=${GUARD_TODAY:-$(date -u +%Y-%m-%d)}
if ! today_days=$(days_of "$today"); then
  echo "ERROR: invalid date for today: $(printf '%q' "$today")." >&2
  exit 2
fi

errors=0
report() { # line message [value]
  if [ "$errors" -eq 0 ]; then
    echo "ERROR: security/trivyignore.yaml does not follow the exception policy:"
  fi
  if [ $# -ge 3 ]; then
    printf '  line %s: %s: %q\n' "$1" "$2" "$3"
  else
    printf '  line %s: %s\n' "$1" "$2"
  fi
  errors=$((errors + 1))
}

# An exact purl: lowercase type, name segments without '@', '%', '?' or
# '#', and one '@' with a version of plain version characters.
purl_re='^pkg:[a-z][a-z0-9.+-]*/([A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+@[A-Za-z0-9][A-Za-z0-9.:_+~-]*$'
id_re='^(CVE-[0-9]{4}-[0-9]{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$'
# Quoted values with at least one character that is not blank, and without
# backslash (YAML escapes) or inner double quote.
item='"[^"\\]*[^"\\[:space:]][^"\\]*"'
list_re="^\\[[[:space:]]*$item([[:space:]]*,[[:space:]]*$item)*[[:space:]]*\\]$"
state=start entries=0 entry_line=0 id='' purls='' paths='' pkg='' statement='' expiry='' ids=' ' keys=' '
# Packages of the entries so far, as " <package>=<line> ".
packages=' '

# The Exceptions table of the docs: the id that starts each row, and the
# aliases listed after it in parentheses, as " <alias>=<id> ".
listed=' ' aliases=' ' in_table=''
while IFS= read -r dline || [ -n "$dline" ]; do
  case $dline in
    '## Exceptions') in_table=yes ;;
    '## '*) in_table='' ;;
  esac
  [ -n "$in_table" ] || continue
  [[ $dline =~ ^\|\ *([A-Za-z0-9-]+)(\ \(([A-Za-z0-9, -]*)\))?\ *\| ]] || continue
  primary=${BASH_REMATCH[1]} rest=${BASH_REMATCH[3]}
  [[ $primary =~ $id_re ]] || continue
  listed="$listed$primary "
  while [[ $rest =~ ([A-Za-z0-9-]+)(.*)$ ]]; do
    aliases="$aliases${BASH_REMATCH[1]}=$primary " rest=${BASH_REMATCH[2]}
  done
done <"$doc"

# Checks the entry collected so far (called at the next entry and at the end).
finish_entry() {
  [ "$entry_line" -gt 0 ] || return 0
  [ -n "$purls" ] || report "$entry_line" "no purls (the affected package with its exact version)" "$id"
  [ -n "$paths" ] || report "$entry_line" "no paths (the affected path)" "$id"
  if [ -n "$pkg" ]; then
    if [[ $packages == *" $pkg="* ]]; then
      local other=${packages#*" $pkg="}
      report "$entry_line" "package already excepted by the entry at line ${other%% *} (one entry per package)" "$pkg"
    fi
    packages="$packages$pkg=$entry_line "
  fi
  [ -n "$statement" ] || report "$entry_line" "no statement with the evidence for the decision" "$id"
  if [ -z "$expiry" ]; then
    report "$entry_line" "no expired_at date (the exception would be permanent)" "$id"
  elif ! e=$(days_of "$expiry"); then
    report "$entry_line" "expired_at is not a valid YYYY-MM-DD date" "$expiry"
  elif [ "$e" -le "$today_days" ]; then
    report "$entry_line" "expired_at is not after $today (expired: renew it after a new review, or remove it)" "$expiry"
  elif [ $((e - today_days)) -gt "$max_days" ]; then
    report "$entry_line" "expired_at is more than $max_days days after $today" "$expiry"
  fi
  if [ -n "$id" ] && [[ $aliases == *" $id="* ]]; then
    local primary=${aliases#*" $id="}
    report "$entry_line" "id is listed as an alias of ${primary%% *} in docs/security/container-vulnerabilities.md (Trivy matches the id it reports; use that id in one entry)" "$id"
  elif [ -n "$id" ] && [[ $listed != *" $id "* ]]; then
    report "$entry_line" "not listed in the Exceptions table of docs/security/container-vulnerabilities.md" "$id"
  fi
  entry_line=0 id='' purls='' paths='' pkg='' statement='' expiry='' keys=' '
}

# check_purls <line> <list>: every purl is exact and all name one package.
# Sets pkg to the package of the entry, in lower case (Trivy matches the
# namespace of a Go purl whatever its case, so case must not make two
# packages out of one).
check_purls() {
  local rest=$2 purl ok=yes name
  pkg=''
  while [[ $rest =~ ^[^\"]*\"([^\"]*)\"(.*)$ ]]; do
    purl=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
    if [[ ! $purl =~ $purl_re ]]; then
      report "$1" "purl is not pkg:<type>/<name>@<exact version> without qualifiers, subpath or encoding" "$purl"
      ok=''
    elif name=$(printf '%s' "${purl%@*}" | tr '[:upper:]' '[:lower:]') && [ -z "$pkg" ]; then
      pkg=$name
    elif [ "$name" != "$pkg" ]; then
      report "$1" "purls name more than one package (one package per entry)" "$2"
      ok=''
    fi
  done
  [ -n "$ok" ]
}

# bash's read drops a NUL byte (or ends the line at it), so the loop below
# cannot see one; report the line of the first NUL byte.
nul_line=$(od -An -v -tu1 "$file" | awk '{ for (i = 1; i <= NF; i++) { if ($i == 10) n++; else if ($i == 0) { print n + 1; exit } } }')
[ -z "$nul_line" ] || report "$nul_line" "only printable ASCII is accepted (NUL byte)"

line_no=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  line=${line%$'\r'}
  if [[ $line == *[![:print:]]* ]]; then
    report "$line_no" "only printable ASCII is accepted (YAML may read a control or non-ASCII character as a line break)" "$line"
    continue
  fi
  [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
  case $state in
    start)
      if [ "$line" = 'vulnerabilities: []' ]; then
        state=empty
      elif [ "$line" = 'vulnerabilities:' ]; then
        state=list
      else
        report "$line_no" "expected 'vulnerabilities: []' or 'vulnerabilities:'" "$line"
        state=bad
      fi
      ;;
    empty | bad)
      report "$line_no" "unexpected content (only the documented form is accepted)" "$line"
      ;;
    list)
      if [[ $line =~ ^\ \ -\ id:\ (.*)$ ]]; then
        finish_entry
        entries=$((entries + 1)) entry_line=$line_no id=${BASH_REMATCH[1]}
        if [[ ! $id =~ $id_re ]]; then
          report "$line_no" "id is not one CVE or GHSA identifier" "$id"
        elif [[ $ids == *" $id "* ]]; then
          report "$line_no" "duplicate id" "$id"
        fi
        ids="$ids$id "
      elif [ "$entry_line" -gt 0 ] && [[ $line =~ ^\ \ \ \ (paths|purls|statement|expired_at):\ (.*)$ ]]; then
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        if [[ $keys == *" $key "* ]]; then
          report "$line_no" "$key appears twice in this entry" "$id"
        fi
        keys="$keys$key "
        case $key in
          paths | purls)
            if [[ ! $value =~ $list_re ]]; then
              report "$line_no" "$key must be a list of quoted, non-blank values without backslash" "$value"
            elif inner=${value#\[} inner=${inner%\]} && [[ $inner == *[][*?{}]* ]]; then
              report "$line_no" "$key must not contain wildcards" "$value"
            elif [ "$key" = paths ]; then
              paths=yes
            elif check_purls "$line_no" "$value"; then
              purls=yes
            fi
            ;;
          statement)
            if [[ ! $value =~ ^$item$ ]]; then
              report "$line_no" "statement must be a non-empty quoted text without backslash or inner double quote" "$value"
            else
              statement=yes
            fi
            ;;
          expired_at) expiry=$value ;;
        esac
      else
        report "$line_no" "unexpected line (only id, paths, purls, statement and expired_at are accepted)" "$line"
      fi
      ;;
  esac
done <"$file"
finish_entry

if [ "$state" = start ]; then
  report "$line_no" "no 'vulnerabilities:' section"
elif [ "$state" = list ] && [ "$entries" -eq 0 ]; then
  report "$line_no" "'vulnerabilities:' without entries (write 'vulnerabilities: []')"
fi

if [ "$errors" -gt 0 ]; then
  echo "See the exception policy in docs/security/container-vulnerabilities.md."
  exit 1
fi
printf 'OK: %d exception(s) in security/trivyignore.yaml follow the policy (checked on %s)\n' "$entries" "$today"
exit 0
