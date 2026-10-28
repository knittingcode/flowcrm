#!/usr/bin/env bash
#
# Fail unless every Caddy configuration the repository can run keeps the
# edge out of the code that parses untrusted JWS/JWK (go-jose,
# CVE-2026-116587, docs/security/container-vulnerabilities.md) and keeps
# its configuration immutable at run time:
#   - no ACME server (acme_server), no PKI app (pki), no internal issuer
#     (tls internal, issuer internal, local_certs) and no certificate
#     issuance or ACME client (acme, zerossl, issuer, cert_issuer, acme_ca,
#     acme_ca_root, acme_dns, acme_eab, on_demand, on_demand_tls,
#     skip_install_trust, get_certificate) in any tracked Caddy file and in
#     any file copied or mounted into /etc/caddy, whatever its name;
#   - tls only as "tls <cert-file> <key-file>" (no block, no internal);
#   - every configuration Caddy starts with has exactly one global options
#     block, first, with exactly "admin off", "auto_https off" and
#     "persist_config off" and no option outside the allow-list (log);
#   - in the same files: no environment placeholder ({$VAR}, substituted into the raw text
#     before parsing, so it could inject any configuration; {env.VAR}),
#     no snippet arguments or blocks ({args...}, {block}, {blocks...}), no
#     heredoc and no named route (&(name), invoke);
#   - every import resolves to a tracked file in the container (or to a
#     snippet defined before it), globs included; an unresolved import fails;
#   - every caddy command line (Dockerfiles, Compose files, scripts, the
#     Makefile, workflows) uses only run, adapt, validate, version,
#     list-modules or build-info; run, adapt and validate need
#     "--config <known path> --adapter caddyfile" and reject --resume,
#     --watch, --envfile and any unknown flag or argument; CADDY_ADMIN is
#     rejected everywhere;
#   - Caddy files reach the container only by a COPY of one tracked file
#     to a full /etc/caddy path or a read-only Compose bind mount of one;
#     no edge stage sets CMD or ENTRYPOINT (the pinned caddy base image's
#     "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile" is
#     used; tests/app/scan.sh checks it in the built images);
#   - edge services in Compose (build docker/edge/Dockerfile, a caddy
#     image, or an override of such a service) have no entrypoint or
#     extends, and a command only in the exact form
#     ["caddy", "run", "--config", "/etc/caddy/<path>", "--adapter", "caddyfile"];
#     Compose files contain no backslash (YAML escapes), no quoted key, no
#     flow mapping but {}, no path with //, /./ or .., and no short or
#     long-syntax (target:) mount over /, /etc, /usr or a bin directory;
#     anchors only on top-level x-* keys, aliases only as "<<: *name" and
#     "logging: *name", tags only !reset/!override, ${VAR} only in ports, a
#     short volume source and a top-level secret file, and no configs,
#     content, dockerfile_inline or secrets from the environment;
#   - edge runtime stages of a Dockerfile only RUN "apk add --no-cache
#     <packages>", copy the binary only to /usr/bin/caddy, put nothing else
#     in a bin directory, use only absolute literal COPY/ADD destinations,
#     no WORKDIR, ONBUILD or ADD, copy only to /etc/caddy/<file>,
#     /usr/bin/caddy or below /srv, and do not change PATH or SHELL; no
#     Dockerfile has a parser directive other than syntax=; command lines
#     contain no glob that matches the binary's name;
#   - no tracked Caddy file is unused by these start points, and no
#     tracked JSON file looks like a Caddy JSON configuration.
# Caddyfiles are tokenized like Caddy 2.11's lexer (comments, quotes,
# backticks, escaped newlines, CR) and parsed like its parser (snippets,
# imports, logical lines), so comments and quotes neither hide a
# directive nor invent one. Caddyfile constructs the guard does not model
# fail. Shell and YAML are only read line by line: the guard catches
# ordinary and accidental changes and the obfuscations above, but not a
# command or path assembled at run time (shell variables, eval, env_file,
# docker cp) or a Caddy plugin in docker/edge/caddy/main.go. It stops
# accidental and casual unsafe changes and makes deliberate ones visible in
# review; a committer can change this guard too, so review stays required.
#
# Usage: guard-edge-config.sh [repository-path]
# Exit codes: 0 configuration safe, 1 unsafe or unsupported construct,
#             2 inspection error (including no Caddy configuration found).
#
# Paths and values are printed with %q on single, indented lines, so
# crafted content cannot inject CI log commands. bash 3.2 compatible.

set -u
LC_ALL=C
export LC_ALL

repo=${1:-.}
self=scripts/ci/guard-edge-config.sh
self_test=scripts/ci/tests/guard-edge-config.test.sh
# Global options the edge may set besides admin, auto_https and
# persist_config. Extend only after reviewing the option (it must not
# enable the pki app, an issuer, ACME or the admin API).
allowed_globals=' log '
max_tokens=20000
max_import_depth=16

if ! top=$(git -C "$repo" rev-parse --show-toplevel) || [ -z "$top" ]; then
  echo "ERROR: '$repo' is not inside a Git work tree." >&2
  exit 2
fi
tracked=$(mktemp "${TMPDIR:-/tmp}/guard-edge-config.XXXXXX") || {
  echo "ERROR: could not create a temporary file." >&2
  exit 2
}
trap 'rm -f "$tracked"' EXIT
if ! git -C "$top" ls-files -z >"$tracked"; then
  echo "ERROR: could not list tracked files in '$top'." >&2
  exit 2
fi

errors=0
# report <where> <message> [value]
report() {
  if [ "$errors" -eq 0 ]; then
    echo "ERROR: the edge configuration could enable the ACME server, the PKI app, an issuer or mutable admin config:"
  fi
  if [ $# -ge 3 ]; then
    printf '  %q: %s: %q\n' "$1" "$2" "$3"
  else
    printf '  %q: %s\n' "$1" "$2"
  fi
  errors=$((errors + 1))
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# canonical_abs <path>: an absolute literal path without $, //, /./, /../,
# a trailing /. or /..; the guard compares paths only in this form.
canonical_abs() {
  case $1 in
    /*) ;;
    *) return 1 ;;
  esac
  case $1 in
    *'$'* | *'//'* | *'/./'* | *'/../'* | */. | */.. | *"\\"*) return 1 ;;
  esac
  return 0
}

# --- Discovery ---------------------------------------------------------------

CONFIGS=() JSONS=() DOCKERFILES=() COMPOSES=() RUNNERS=() TRACKED=' '
df_re='(^|/)([Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee](\.[^/]+)?|[^/]+\.[Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee]|[Cc][Oo][Nn][Tt][Aa][Ii][Nn][Ee][Rr][Ff][Ii][Ll][Ee])$'
while IFS= read -r -d '' path; do
  TRACKED="$TRACKED$path "
  base=${path##*/}
  shopt -s nocasematch
  case $base in
    caddyfile* | *.caddyfile | *.caddy) CONFIGS+=("$path") ;;
    *.json | *.json5 | *.jsonc) JSONS+=("$path") ;;
  esac
  if [ "$path" = "$self" ] || [ "$path" = "$self_test" ]; then
    shopt -u nocasematch
    continue
  fi
  if [[ $path =~ $df_re ]]; then
    DOCKERFILES+=("$path") RUNNERS+=("$path")
  else
    case $base in
      compose*.yaml | compose*.yml | docker-compose*.yaml | docker-compose*.yml | *.compose.yaml | *.compose.yml)
        COMPOSES+=("$path") RUNNERS+=("$path") ;;
      *.sh | *.bash | makefile | *.mk) RUNNERS+=("$path") ;;
      *)
        case $path in
          bin/* | .github/workflows/*.yml | .github/workflows/*.yaml) RUNNERS+=("$path") ;;
        esac
        ;;
    esac
  fi
  shopt -u nocasematch
done <"$tracked"

is_tracked() { case $TRACKED in *" $1 "*) return 0 ;; esac; return 1; }

if [ "${#CONFIGS[@]}" -eq 0 ]; then
  echo "ERROR: no tracked Caddy configuration found in '$top'." >&2
  exit 2
fi

for f in ${JSONS[@]+"${JSONS[@]}"}; do
  shopt -s nocasematch
  case ${f##*/} in
    *caddy*) report "$f" "Caddy JSON configuration (only Caddyfiles are supported by this guard)" ;;
    *) grep -qE '"(apps|admin)"[[:space:]]*:' "$top/$f" &&
      report "$f" "looks like a Caddy JSON configuration (key \"apps\" or \"admin\"); only Caddyfiles are supported" ;;
  esac
  shopt -u nocasematch
done

# --- Container paths: Dockerfile COPY and Compose bind mounts ----------------

# MAP_* : stage ("<dockerfile>#<stage>", or "*" for Compose mounts, which
# the guard applies to every stage), container path, tracked source.
MAP_STAGE=() MAP_DEST=() MAP_SRC=()
ST_ID=() ST_PARENT=()

stage_index() { # id -> index, or 1
  local k
  for ((k = 0; k < ${#ST_ID[@]}; k++)); do
    [ "${ST_ID[$k]}" = "$1" ] && { printf '%s' "$k"; return 0; }
  done
  return 1
}

# logical_lines <file> [caddy]: joins lines ending in a backslash; prints
# "<first line number><TAB><text>" per logical line (with "caddy": only
# lines that mention caddy in any case and are not full-line comments).
logical_lines() {
  awk -v only="${2-}" '
    function out(t) { if (only == "" || (t !~ /^[[:space:]]*#/ && (tolower(t) ~ /caddy/ || t ~ /[*?[]/))) print start "\t" t }
    { sub(/\r$/, "") }
    { if (acc == "") start = NR; else acc = acc " "
      if ($0 ~ /\\$/) { acc = acc substr($0, 1, length($0) - 1); next }
      acc = acc $0; out(acc); acc = "" }
    END { if (acc != "") out(acc) }' "$1"
}

# normalize <text>: quotes, brackets and commas become spaces; shell
# separators become " ; " (so a command line can be split into words).
# words <text>: WORDS is the normalized text split on whitespace (no globbing).
normalize() {
  local t=$1
  t=${t//\"/ } t=${t//\'/ } t=${t//\`/ } t=${t//[/ } t=${t//]/ } t=${t//,/ }
  t=${t//;/ ; } t=${t//|/ ; } t=${t//&/ ; } t=${t//(/ ; } t=${t//)/ ; }
  NORM=$t
}
words() {
  normalize "$1"
  set -f
  # shellcheck disable=SC2206 # split on purpose; globbing is off
  WORDS=($NORM)
  set +f
}

ST_FROM=() DL_STAGE=() DL_WHERE=() DL_INSTR=() DL_TEXT=()
for df in ${DOCKERFILES[@]+"${DOCKERFILES[@]}"}; do
  # Parser directives (# key=value before the first instruction) change how
  # BuildKit reads the file (escape= changes line continuation): only
  # syntax= is accepted, so the guard reads the file as BuildKit does.
  awk '{ sub(/\r$/, ""); if (NR == 1) sub(/^\xef\xbb\xbf/, "") }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ {
      t = $0; sub(/^[[:space:]]*#[[:space:]]*/, "", t)
      if (t ~ /^[A-Za-z][A-Za-z0-9_-]*[[:space:]]*=/) {
        k = t; sub(/[[:space:]]*=.*/, "", k)
        if (tolower(k) != "syntax") print NR "\t" $0
      }
      next }
    { exit }' "$top/$df" >"$tracked.dir"
  while IFS=$'\t' read -r ln text; do
    report "$df:$ln" "Dockerfile parser directive other than syntax= (escape= or check= change how the file is read)" "$text"
  done <"$tracked.dir"
  rm -f "$tracked.dir"
  stage='' has_caddy_copy=no cmd_lines=''
  while IFS=$'\t' read -r ln text; do
    [[ $text =~ ^[[:space:]]*(#|$) ]] && continue
    text=${text#"${text%%[![:space:]]*}"}
    instr=${text%%[[:space:]]*} rest=${text#"$instr"}
    shopt -s nocasematch
    case $instr in
      from | copy | add | cmd | entrypoint | run | env | shell | workdir | onbuild) instr=$(lower "$instr") ;;
      *) instr=other ;;
    esac
    shopt -u nocasematch
    case $instr in
      from)
        words "$rest"
        w=(${WORDS[@]+"${WORDS[@]}"})
        img=$(lower "${w[0]-}") name="stage-${#ST_ID[@]}" parent=''
        if [ "${#w[@]}" -ge 3 ] && [ "$(lower "${w[1]}")" = as ]; then name=$(lower "${w[2]}"); fi
        stage_index "$df#$img" >/dev/null && parent="$df#$img"
        stage="$df#$name"
        ST_ID+=("$stage") ST_PARENT+=("$parent") ST_FROM+=("${w[0]-}")
        ;;
      copy | add)
        DL_STAGE+=("$stage") DL_WHERE+=("$df:$ln") DL_INSTR+=("$instr") DL_TEXT+=("$text")
        words "$rest"
        w=(${WORDS[@]+"${WORDS[@]}"})
        dest=${w[${#w[@]}-1]-}
        case $dest in /etc/caddy | /etc/caddy/*) ;; *) continue ;; esac
        has_caddy_copy=yes
        srcs=() from=''
        for x in "${w[@]}"; do
          case $x in --from=*) from=$x ;; --*) ;; *) srcs+=("$x") ;; esac
        done
        unset 'srcs[${#srcs[@]}-1]'
        if [ "$instr" = add ]; then
          report "$df:$ln" "ADD into /etc/caddy is not supported (use COPY of one tracked file)" "$text"
        elif [ -n "$from" ]; then
          report "$df:$ln" "COPY --from into /etc/caddy is not supported (the file must be a tracked one the guard can check)" "$text"
        elif [ "${#srcs[@]}" -ne 1 ]; then
          report "$df:$ln" "COPY into /etc/caddy must copy exactly one file" "$text"
        elif ! is_tracked "${srcs[0]}"; then
          report "$df:$ln" "COPY into /etc/caddy of a source that is not a tracked file" "${srcs[0]}"
        else
          case $dest in */) dest=$dest${srcs[0]##*/} ;; /etc/caddy)
            report "$df:$ln" "COPY into /etc/caddy must name the full destination path" "$text"
            continue
            ;;
          esac
          MAP_STAGE+=("$stage") MAP_DEST+=("$dest") MAP_SRC+=("${srcs[0]}")
        fi
        ;;
      cmd | entrypoint) cmd_lines="$cmd_lines $ln" ;;
      *)
        case $instr in run | env | shell | workdir | onbuild)
          DL_STAGE+=("$stage") DL_WHERE+=("$df:$ln") DL_INSTR+=("$instr") DL_TEXT+=("$text") ;;
        esac
        case $text in *"/etc/caddy"*)
          report "$df:$ln" "only COPY may write to /etc/caddy (the guard checks the copied file)" "$text"
          ;;
        esac
        ;;
    esac
  done < <(logical_lines "$top/$df")
  if [ "$has_caddy_copy" = yes ] && [ -n "$cmd_lines" ]; then
    report "$df" "CMD or ENTRYPOINT in an edge Dockerfile (lines$cmd_lines): the edge runs the caddy base image's command, checked by tests/app/scan.sh"
  fi
done

# Edge runtime stages: a stage FROM a caddy image, a stage that copies into
# /etc/caddy, and every stage built on one. Their RUN may only install
# Alpine packages, the binary may only be copied to /usr/bin/caddy, and
# nothing else may be placed in a bin directory or change PATH or SHELL: a
# renamed or linked copy of the binary would escape the command checks.
is_runtime_stage() { # stage id
  local st=$1 idx k seen=' '
  while [ -n "$st" ]; do
    case $seen in *" $st "*) return 1 ;; esac
    seen="$seen$st "
    for ((k = 0; k < ${#MAP_STAGE[@]}; k++)); do [ "${MAP_STAGE[$k]}" = "$st" ] && return 0; done
    idx=$(stage_index "$st") || return 1
    shopt -s nocasematch
    case ${ST_FROM[$idx]} in *caddy*) [ -z "${ST_PARENT[$idx]}" ] && { shopt -u nocasematch; return 0; } ;; esac
    shopt -u nocasematch
    st=${ST_PARENT[$idx]}
  done
  return 1
}
# Descendants count too: a stage is runtime if it or an ancestor is.
bin_dir_re='^(/usr/local|/usr)?/s?bin(/|$)'
for ((k = 0; k < ${#DL_STAGE[@]}; k++)); do
  is_runtime_stage "${DL_STAGE[$k]}" || continue
  where=${DL_WHERE[$k]} text=${DL_TEXT[$k]}
  case ${DL_INSTR[$k]} in
    run)
      body=${text#*[[:space:]]}
      body=${body#"${body%%[![:space:]]*}"}
      case $body in
        'apk add --no-cache '*)
          set -f
          # shellcheck disable=SC2086 # split on purpose; globbing is off
          set -- $body
          set +f
          for x in "$@"; do
            [[ $x =~ ^(apk|add|--[a-z-]+|[A-Za-z0-9._+=~-]+|\'[A-Za-z0-9._+=~\<\>-]+\')$ ]] && continue
            report "$where" "RUN in an edge runtime stage may only be a plain 'apk add --no-cache <packages>' (no shell operators)" "$text"
            break
          done
          ;;
        *) report "$where" "RUN in an edge runtime stage may only be 'apk add --no-cache <packages>' (a link, copy or rename of the binary would escape the command checks)" "$text" ;;
      esac
      ;;
    env)
      case $text in *PATH* | *path* | *SHELL*) report "$where" "ENV changing PATH or SHELL in an edge runtime stage" "$text" ;; esac
      ;;
    shell) report "$where" "SHELL in an edge runtime stage" "$text" ;;
    workdir) report "$where" "WORKDIR in an edge runtime stage (a relative COPY destination would land in it)" "$text" ;;
    onbuild) report "$where" "ONBUILD in an edge runtime stage" "$text" ;;
    copy | add)
      words "${text#*[[:space:]]}"
      w=(${WORDS[@]+"${WORDS[@]}"})
      dest=${w[${#w[@]}-1]-} src=''
      for x in "${w[@]}"; do case $x in --*) ;; *) [ -n "$src" ] || src=$x ;; esac; done
      if ! canonical_abs "$dest"; then
        report "$where" "COPY or ADD in an edge runtime stage needs an absolute literal destination (no relative path, variable, //, . or ..)" "$text"
        continue
      fi
      if [ "${DL_INSTR[$k]}" = add ]; then
        report "$where" "ADD in an edge runtime stage (it extracts archives and fetches URLs; use COPY)" "$text"
        continue
      fi
      if [[ $dest =~ $bin_dir_re ]] || [ "${src##*/}" = caddy ]; then
        case $text in
          [Cc][Oo][Pp][Yy]' --from='*' '*/caddy' /usr/bin/caddy') [ "${src##*/}" = caddy ] && [ "${#w[@]}" -eq 3 ] || report "$where" "only the Caddy binary may be copied into a bin directory, to /usr/bin/caddy" "$text" ;;
          *) report "$where" "only 'COPY --from=<stage> <path>/caddy /usr/bin/caddy' may place the binary or anything in a bin directory of an edge runtime stage" "$text" ;;
        esac
      fi
      # Only these destinations: a file in /etc/caddy (checked above as a
      # Caddy file), the binary at /usr/bin/caddy, and the site below /srv.
      case ${dest%/} in
        /etc/caddy/?* | /usr/bin/caddy | /srv/?*) ;;
        *)
          report "$where" "COPY destination in an edge runtime stage outside /etc/caddy/<file>, /usr/bin/caddy and /srv/<path> (an ancestor such as / or /etc would replace /etc/caddy or a bin directory)" "$text"
          ;;
      esac
      ;;
  esac
done

# compose_line_rules <file> <line number> <line>: YAML features that would
# let a value reach a service without the line checks seeing it. Allowed
# are exactly the forms the repository uses:
#   - anchors only on top-level x-* keys ("x-name: &name");
#   - aliases only as "<<: *name" (one alias, no list) and "logging: *name";
#   - tags only !reset and !override;
#   - ${VAR} interpolation only in ports, in the source of a short volume
#     mount with a literal target ("- ${VAR...}:/path[:mode]"), and in the
#     file of a top-level secret;
#   - no configs, no content (inline configs or secrets), no
#     dockerfile_inline, and top-level secrets only from a file.
CTX_IND=() CTX_KEY=()
compose_line_rules() {
  local f=$1 n=$2 l=$3 ind body key path k item=no v
  body=${l#"${l%%[! ]*}"}
  [ -n "$body" ] || return 0
  ind=$((${#l} - ${#body}))
  case $body in '---'* | '...'*) report "$f:$n" "YAML document marker in a Compose file (one document only)" "$l"; return ;; esac
  if [[ $body =~ ^-([[:space:]]+|$) ]]; then
    item=yes
    body=${body#-}
    v=${body#"${body%%[! ]*}"}
    ind=$((ind + 1 + ${#body} - ${#v}))
    body=$v
  fi
  key=''
  if [[ $body =~ ^([A-Za-z0-9_.<-]+):([[:space:]]|$) ]]; then key=${BASH_REMATCH[1]}; fi
  # Pop to the parent of this line, then push its key.
  while [ "${#CTX_IND[@]}" -gt 0 ] && [ "${CTX_IND[${#CTX_IND[@]} - 1]}" -ge "$ind" ]; do
    unset 'CTX_IND[${#CTX_IND[@]}-1]' 'CTX_KEY[${#CTX_KEY[@]}-1]'
  done
  path=''
  for ((k = 0; k < ${#CTX_KEY[@]}; k++)); do path="$path${CTX_KEY[$k]}."; done
  if [ -n "$key" ]; then CTX_IND+=("$ind") CTX_KEY+=("$key"); fi
  case $key in
    configs | content | dockerfile_inline | environment)
      case $key in environment) [ "${path%%.*}" = secrets ] || key='' ;; esac
      [ -n "$key" ] && report "$f:$n" "Compose $key is not supported (an inline or external config could replace /etc/caddy or the binary)" "$l"
      ;;
  esac
  if [[ $body =~ (^|[[:space:]:,\[])\&[A-Za-z0-9_.-]+ ]]; then
    [ "$ind" -eq 0 ] && [[ $body =~ ^x-[A-Za-z0-9_.-]+:[[:space:]]+\&[A-Za-z0-9_.-]+[[:space:]]*$ ]] ||
      report "$f:$n" "YAML anchor in a Compose file (only on a top-level x-* key)" "$l"
  fi
  if [[ $body =~ (^|[[:space:]:,\[])\*[A-Za-z0-9_.-]+ ]]; then
    [[ $body =~ ^(\<\<|logging):[[:space:]]+\*[A-Za-z0-9_.-]+[[:space:]]*$ ]] && [ "$item" = no ] ||
      report "$f:$n" "YAML alias in a Compose file (only '<<: *name' and 'logging: *name')" "$l"
  fi
  if [[ $body =~ (^|[[:space:]:,\[])\!+([A-Za-z0-9_.-]*) ]]; then
    case ${BASH_REMATCH[2]} in reset | override) ;; *) report "$f:$n" "YAML tag in a Compose file (only !reset and !override)" "$l" ;; esac
  fi
  case $body in
    *'$'*)
      v=no
      case $path in *ports.) [ "$item" = yes ] && v=yes ;; esac
      case $path in
        *volumes.)
          [ "$item" = yes ] && [[ $body =~ ^\"?\$\{[A-Za-z_][A-Za-z0-9_]*(:?[-?][^}\$]*)?\}[^:\$\"]*:/[^:\$\"]+(:[a-z,]+)?\"?[[:space:]]*$ ]] && v=yes ;;
      esac
      [ "$path" = "secrets.${path#secrets.}" ] && [ "$key" = file ] && [ "${path//[!.]/}" = .. ] && v=yes
      [ "$v" = yes ] || report "$f:$n" "interpolation in a Compose file outside ports, a volume source and a secret file (it could change an image, command, mount or build)" "$l"
      ;;
  esac
}

for cf in ${COMPOSES[@]+"${COMPOSES[@]}"}; do
  ln=0
  CTX_IND=() CTX_KEY=()
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*# ]] && continue
    case $line in *$'\t'*) report "$cf:$ln" "tab in a Compose file" "$line" ;; esac
    compose_line_rules "$cf" "$ln" "$line"
    # YAML escapes (\u0063addy, \x2F) would hide a command or a path from
    # these line checks; Compose decodes them.
    case $line in *"\\"*) report "$cf:$ln" "backslash in a Compose file (YAML escapes are not supported)" "$line" ;; esac
    # The service model below reads block-style YAML with plain keys only.
    if [[ $line =~ ^[[:space:]]*(-[[:space:]]+)?[\"\'][^\"\']*[\"\'][[:space:]]*: ]]; then
      report "$cf:$ln" "quoted key in a Compose file (not supported: it would hide a key from the checks)" "$line"
    fi
    if [[ $line =~ (^|[^\$])\{[[:space:]]*[^}[:space:]] ]]; then
      report "$cf:$ln" "flow mapping in a Compose file (only {} is supported)" "$line"
    fi
    # Long-syntax mounts and other path keys.
    if [[ $line =~ ^[[:space:]]*(-[[:space:]]+)?(target|destination|dst|source|src|file|dockerfile):[[:space:]]*[\"\']?([^\"\'[:space:]]*) ]]; then
      t=${BASH_REMATCH[3]}
      case $t in
        */* | .*)
          case $t in *'//'* | *'/./'* | *'..'* | */.)
            report "$cf:$ln" "path with //, /./ or .. in a Compose file (write it in canonical form)" "$line" ;;
          esac
          ;;
      esac
      case ${BASH_REMATCH[2]} in
        target | destination | dst)
          t=${t%/}
          case $t in
            '' | /etc | /etc/caddy | /etc/caddy/* | /usr | /usr/local | /bin | /sbin | /usr/bin | /usr/sbin | /usr/local/bin | /usr/local/sbin | /usr/bin/* | /usr/local/bin/* | /bin/*)
              case $t in '' | /*) report "$cf:$ln" "long-syntax mount over /etc/caddy, the Caddy binary or a directory that holds them" "$line" ;; esac ;;
          esac
          ;;
      esac
    fi
    # A mount over /, /etc, /usr or a bin directory replaces /etc/caddy or
    # the binary without naming them.
    if [[ $line =~ ^[[:space:]]*-[[:space:]]*[\"\']?[^:\"\'[:space:]]+:(/[^:\"\'[:space:]]*)(:[a-z,]+)?[\"\']?[[:space:]]*$ ]]; then
      t=${BASH_REMATCH[1]}
      canonical_abs "$t" || [ "$t" = / ] || report "$cf:$ln" "mount target must be a canonical absolute path (no //, . or ..)" "$line"
      t=${t%/}
      case $t in
        '' | /etc | /usr | /usr/local | /bin | /sbin | /usr/bin | /usr/sbin | /usr/local/bin | /usr/local/sbin | /usr/bin/* | /usr/local/bin/* | /bin/*)
          report "$cf:$ln" "mount over a directory that holds /etc/caddy or the Caddy binary" "$line" ;;
      esac
    fi
    case $line in *"/etc/caddy"*) ;; *) continue ;; esac
    if [[ $line =~ ^[[:space:]]*-[[:space:]]*\"?\./([^:\"[:space:]]+):(/etc/caddy/[^:\"[:space:]]+)(:([a-z,]+))?\"?[[:space:]]*$ ]]; then
      src=${BASH_REMATCH[1]} dest=${BASH_REMATCH[2]} mode=${BASH_REMATCH[4]}
      if ! is_tracked "$src"; then
        report "$cf:$ln" "bind mount into /etc/caddy of a source that is not a tracked file" "$src"
      elif [ "$mode" != ro ]; then
        report "$cf:$ln" "bind mount into /etc/caddy must be read-only (:ro)" "$line"
      else
        MAP_STAGE+=("*") MAP_DEST+=("$dest") MAP_SRC+=("$src")
      fi
    elif [[ $line =~ ^[[:space:]]*(command|entrypoint): ]]; then
      : # checked as a caddy command line below
    else
      report "$cf:$ln" "unsupported reference to /etc/caddy (only '- ./<tracked file>:/etc/caddy/<path>:ro' mounts are accepted)" "$line"
    fi
  done <"$top/$cf"
done

# Edge services in Compose files: a service that builds docker/edge/Dockerfile
# or runs a caddy image (directly or through a "<<: *anchor" merge), or an
# override (no image and no dockerfile of its own) of a service that is an
# edge service in another file. An edge service has no entrypoint and no extends, and its
# command, if set, is exactly
#   command: ["caddy", "run", "--config", "/etc/caddy/<path>", "--adapter", "caddyfile"]
# compose_keys <file>: "<line>\t<service or &anchor>\t<key>\t<value>" for the
# keys image, dockerfile, build, command, entrypoint, extends and <<.
compose_keys() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    { match($0, /^ */); ind = RLENGTH; t = substr($0, ind + 1) }
    ind == 0 { top = t; sub(/:.*/, "", top); owner = ""; svc_ind = -1; key_ind = -1
      if (top ~ /^x-/ && match(t, /&[A-Za-z0-9_.-]+/)) owner = substr(t, RSTART, RLENGTH)
      next }
    top == "services" && (svc_ind < 0 || ind <= svc_ind) && t ~ /^[A-Za-z0-9_.-]+:/ {
      svc_ind = ind; key_ind = -1; owner = t; sub(/:.*/, "", owner); next }
    owner != "" {
      if (key_ind < 0) key_ind = ind
      k = t; sub(/:.*/, "", k); v = t; sub(/^[^:]*:[[:space:]]*/, "", v)
      if (ind == key_ind && (k == "image" || k == "build" || k == "command" || k == "entrypoint" || k == "extends" || k == "<<"))
        print NR "\t" owner "\t" k "\t" v
      else if (k == "dockerfile") print NR "\t" owner "\tdockerfile\t" v
    }' "$1"
}
CK_FILE=() CK_LINE=() CK_OWNER=() CK_KEY=() CK_VAL=()
for cf in ${COMPOSES[@]+"${COMPOSES[@]}"}; do
  while IFS=$'\t' read -r ln owner key val; do
    CK_FILE+=("$cf") CK_LINE+=("$ln") CK_OWNER+=("$owner") CK_KEY+=("$key") CK_VAL+=("$val")
  done < <(compose_keys "$top/$cf")
done
# svc_has <file> <owner> <key> [value-pattern]: the key, directly or through
# a merged anchor of the same file; sets SVC_VAL, SVC_LINE.
svc_has() {
  local f=$1 o=$2 key=$3 pat=${4-*} k m anchors=''
  for ((k = 0; k < ${#CK_KEY[@]}; k++)); do
    [ "${CK_FILE[$k]}" = "$f" ] && [ "${CK_OWNER[$k]}" = "$o" ] && [ "${CK_KEY[$k]}" = '<<' ] &&
      # "*name" -> "&name" without & in a replacement (bash >= 5.2 expands it).
      anchors="$anchors &${CK_VAL[$k]#\*}"
  done
  for ((k = 0; k < ${#CK_KEY[@]}; k++)); do
    [ "${CK_FILE[$k]}" = "$f" ] && [ "${CK_KEY[$k]}" = "$key" ] || continue
    m=no
    [ "${CK_OWNER[$k]}" = "$o" ] && m=yes
    case " $anchors " in *" ${CK_OWNER[$k]} "*) m=yes ;; esac
    [ "$m" = yes ] || continue
    shopt -s nocasematch
    # shellcheck disable=SC2053 # $pat is a pattern
    if [[ ${CK_VAL[$k]} == $pat ]]; then
      shopt -u nocasematch
      SVC_VAL=${CK_VAL[$k]} SVC_LINE=${CK_LINE[$k]}
      return 0
    fi
    shopt -u nocasematch
  done
  return 1
}
# Dockerfiles with an edge runtime stage; a Compose service that builds one
# (or a Dockerfile the guard does not know) is an edge service.
EDGE_DOCKERFILES=' '
for ((k = 0; k < ${#ST_ID[@]}; k++)); do
  is_runtime_stage "${ST_ID[$k]}" && EDGE_DOCKERFILES="$EDGE_DOCKERFILES${ST_ID[$k]%#*} "
done
edge_dockerfile() { # dockerfile value from Compose
  local v=${1#./}
  v=${v#\"} v=${v%\"} v=${v#\'} v=${v%\'}
  v=${v#./}
  case $EDGE_DOCKERFILES in *" $v "*) return 0 ;; esac
  is_tracked "$v" || return 0
  return 1
}
EDGE_NAMES=' '
for ((k = 0; k < ${#CK_KEY[@]}; k++)); do
  case ${CK_OWNER[$k]} in '&'*) continue ;; esac
  if { svc_has "${CK_FILE[$k]}" "${CK_OWNER[$k]}" dockerfile && edge_dockerfile "$SVC_VAL"; } ||
    svc_has "${CK_FILE[$k]}" "${CK_OWNER[$k]}" image '*caddy*'; then
    case $EDGE_NAMES in *" ${CK_OWNER[$k]} "*) ;; *) EDGE_NAMES="$EDGE_NAMES${CK_OWNER[$k]} " ;; esac
  fi
done
edge_cmd_re='^\[ *"caddy" *, *"run" *, *"--config" *, *"/etc/caddy/[A-Za-z0-9._/-]+" *, *"--adapter" *, *"caddyfile" *\]$'
for ((k = 0; k < ${#CK_KEY[@]}; k++)); do
  f=${CK_FILE[$k]} o=${CK_OWNER[$k]}
  case $o in '&'*) continue ;; esac
  case " ${CHECKED_SVC-} " in *" $f:$o "*) continue ;; esac
  CHECKED_SVC="${CHECKED_SVC-} $f:$o"
  edge=no
  if { svc_has "$f" "$o" dockerfile && edge_dockerfile "$SVC_VAL"; } || svc_has "$f" "$o" image '*caddy*'; then
    edge=yes
  elif ! svc_has "$f" "$o" image && ! svc_has "$f" "$o" dockerfile; then
    case $EDGE_NAMES in *" $o "*) edge=yes ;; esac
  fi
  [ "$edge" = yes ] || continue
  svc_has "$f" "$o" entrypoint && report "$f:$SVC_LINE" "entrypoint of the edge service $o (only the image's command, or the exact caddy run form, is accepted)" "$SVC_VAL"
  svc_has "$f" "$o" extends && report "$f:$SVC_LINE" "extends in the edge service $o is not supported" "$SVC_VAL"
  if svc_has "$f" "$o" command && ! [[ $SVC_VAL =~ $edge_cmd_re ]]; then
    report "$f:$SVC_LINE" "command of the edge service $o must be exactly [\"caddy\", \"run\", \"--config\", \"/etc/caddy/<path>\", \"--adapter\", \"caddyfile\"]" "$SVC_VAL"
  fi
done

# --- caddy command lines -------------------------------------------------------

CFG_PATHS=' '
# check_cli <where> <words...>: the words after a caddy command word.
check_cli() {
  local where=$1 sub=${2-} config='' adapter='' w v
  shift
  case $sub in
    '' | ';') report "$where" "caddy without a subcommand on the same line (unsupported form)"; return ;;
    version | list-modules | build-info) return ;;
    run | adapt | validate) shift ;;
    *) report "$where" "caddy subcommand not allowed (only run, adapt, validate, version, list-modules, build-info)" "$sub"; return ;;
  esac
  while [ $# -gt 0 ]; do
    w=$1
    shift
    case $w in
      ';' | '>'* | '<'* | [0-9]'>'*) break ;;
      --config=* | -c=*) config=${w#*=} ;;
      --config | -c) config=${1-}; shift ;;
      --adapter=* | -a=*) adapter=${w#*=} ;;
      --adapter | -a) adapter=${1-}; shift ;;
      --resume | -r | --resume=*) report "$where" "caddy $sub --resume would run the last autosaved (possibly admin-loaded) config" "$w" ;;
      --watch | -w | --watch=*) report "$where" "caddy $sub --watch reloads the config at run time" "$w" ;;
      --envfile | --envfile=*) report "$where" "caddy $sub --envfile could set CADDY_ADMIN or {\$VAR} values" "$w" ;;
      --pidfile | --pingback) [ "$sub" = run ] || report "$where" "unknown flag for caddy $sub" "$w"; shift ;;
      --pidfile=* | --pingback=* | --environ | -e) [ "$sub" = run ] || report "$where" "unknown flag for caddy $sub" "$w" ;;
      --pretty | -p | --validate) [ "$sub" = adapt ] || report "$where" "unknown flag for caddy $sub" "$w" ;;
      -*) report "$where" "unknown flag for caddy $sub (fails closed)" "$w" ;;
      *) report "$where" "unexpected argument for caddy $sub" "$w" ;;
    esac
  done
  if [ -z "$config" ]; then
    report "$where" "caddy $sub without --config (it would look for ./Caddyfile or the autosave)"
  else
    case $config in
      /etc/caddy/*) case $config in *'$'* | *'*'* | *'?'* | *..*) v=bad ;; *) v=ok ;; esac ;;
      *) v=bad ;;
    esac
    if [ "$v" = ok ]; then
      case $CFG_PATHS in *" $config "*) ;; *) CFG_PATHS="$CFG_PATHS$config " ;; esac
    else
      report "$where" "caddy $sub --config must be a literal path below /etc/caddy" "$config"
    fi
  fi
  [ "$adapter" = caddyfile ] || report "$where" "caddy $sub needs --adapter caddyfile" "$adapter"
}

# scan_runner <file>: caddy command lines, CADDY_ADMIN and /etc/caddy mounts.
scan_runner() {
  local f=$1 kind=other ln text words i w n nextind ind instr
  case " ${COMPOSES[*]-} " in *" $f "*) kind=compose ;; esac
  case " ${DOCKERFILES[*]-} " in *" $f "*) kind=dockerfile ;; esac
  while IFS=$'\t' read -r ln text; do
    case $text in *CADDY_ADMIN*)
      report "$f:$ln" "CADDY_ADMIN would set the admin API address" "$text" ;;
    esac
    if [ "$kind" = dockerfile ]; then
      instr=${text#"${text%%[![:space:]]*}"} instr=${instr%%[[:space:]]*}
      shopt -s nocasematch
      case $instr in run | cmd | entrypoint | healthcheck | shell | onbuild) instr=ok ;; esac
      shopt -u nocasematch
      [ "$instr" = ok ] || continue
    fi
    words "$text"
    words=(${WORDS[@]+"${WORDS[@]}"})
    n=${#words[@]}
    for ((i = 0; i < n; i++)); do
      w=${words[$i]}
      case $w in
        *:/etc/caddy*)
          v=${w%%:/etc/caddy*} dest=/etc/caddy${w#*:/etc/caddy} dest=${dest%%:*}
          v=${v#\$APP_REPO/} v=${v#\$\{APP_REPO\}/} v=${v#\$PWD/} v=${v#./}
          mapped=no
          for ((k = 0; k < ${#MAP_DEST[@]}; k++)); do
            [ "${MAP_STAGE[$k]}" = '*' ] && [ "${MAP_DEST[$k]}" = "$dest" ] && [ "${MAP_SRC[$k]}" = "$v" ] && mapped=yes
          done
          [ "$mapped" = yes ] || report "$f:$ln" "mount into /etc/caddy that is not a Compose-mounted tracked file at the same path" "$w"
          ;;
        *target=/etc/caddy* | *dst=/etc/caddy* | *destination=/etc/caddy*)
          report "$f:$ln" "--mount into /etc/caddy is not supported" "$w" ;;
      esac
      # A glob that matches the binary's name (cadd?, /usr/bin/c*dy) could
      # run, link or copy it under another name.
      case $w in
        *[*?[]*)
          b=${w##*/}
          if [ "${#b}" -gt 0 ] && [[ ${b//[^A-Za-z0-9]/} =~ [A-Za-z0-9]{2} ]]; then
            shopt -s nocasematch
            # shellcheck disable=SC2053 # $b is the pattern
            [[ caddy == $b ]] && report "$f:$ln" "glob that matches the Caddy binary's name" "$w"
            shopt -u nocasematch
          fi
          ;;
      esac
      case $w in
        caddy | /*/caddy) ;;
        *) continue ;;
      esac
      # An output path (go build -o /out/caddy) is not a command.
      if [ "$i" -gt 0 ]; then
        case ${words[$((i - 1))]} in -o | --output) continue ;; esac
      fi
      if [ "$kind" = compose ]; then
        if ! [[ $text =~ ^[[:space:]]*(command|entrypoint):[[:space:]]*(\[.*\]|[^][|>[:space:]].*)[[:space:]]*$ ]]; then
          report "$f:$ln" "caddy command in an unsupported YAML form (use command: [\"caddy\", ...] on one line)" "$text"
          break
        fi
        ind=${text%%[![:space:]]*}
        nextind=$(sed -n "$((ln + 1)),\$p" "$top/$f" | awk 'NF && $1 !~ /^#/ { match($0, /^[ \t]*/); print RLENGTH; exit }')
        if [ -n "$nextind" ] && [ "$nextind" -gt "${#ind}" ]; then
          report "$f:$ln" "caddy command continues on the next line (unsupported YAML form)" "$text"
          break
        fi
      fi
      check_cli "$f:$ln" "${words[@]:$((i + 1))}"
      break
    done
  done < <(logical_lines "$top/$f" caddy)
}

for f in ${RUNNERS[@]+"${RUNNERS[@]}"}; do scan_runner "$f"; done

# --- Caddyfile lexer (Caddy 2.11 caddyconfig/caddyfile/lexer.go) ------------

# lex <tracked file>: LX_TEXT, LX_Q (0, '"' or '`'), LX_LINE; 1 if unsupported.
lex() {
  local s n i ch val='' q=0 bt=0 hesc=0 esc=0 comment=0 line=1 skipped=0 tline=1 more=yes
  LX_TEXT=() LX_Q=() LX_LINE=() LX_ERR=''
  emit() {
    LX_TEXT+=("$val") LX_Q+=("$1") LX_LINE+=("$tline")
    val='' q=0 bt=0 hesc=0 esc=0 comment=0
  }
  [ -r "$top/$1" ] || { LX_ERR="cannot read"; return 1; }
  # One physical line at a time (with its LF), so that the substring
  # expansions work on short strings.
  exec 3<"$top/$1"
  while [ "$more" = yes ]; do
    if IFS= read -r s <&3; then s=$s$'\n'; else more=no; fi
    n=${#s} i=0
  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}
    i=$((i + 1))
    if [ "$q" = 0 ] && [ "$bt" = 0 ] && [ "$hesc" = 0 ] && [ "${#val}" -gt 1 ] && [ "${val:0:2}" = '<<' ]; then
      if [ "$ch" = ' ' ]; then emit 0; continue; fi
      LX_ERR="line $tline: heredoc (<<) is not supported"
      exec 3<&-
      return 1
    fi
    if [ "$esc" = 0 ] && [ "$bt" = 0 ] && [ "$ch" = "\\" ]; then esc=1; continue; fi
    if [ "$q" = 1 ] || [ "$bt" = 1 ]; then
      if [ "$q" = 1 ] && [ "$esc" = 1 ]; then
        [ "$ch" = '"' ] || val="$val\\"
        esc=0
      elif { [ "$q" = 1 ] && [ "$ch" = '"' ]; } || { [ "$bt" = 1 ] && [ "$ch" = '`' ]; }; then
        emit "$ch"
        continue
      fi
      if [ "$ch" = $'\n' ]; then line=$((line + 1 + skipped)) skipped=0; fi
      val="$val$ch"
      continue
    fi
    case $ch in
      ' ' | $'\t' | $'\n' | $'\r' | $'\v' | $'\f')
        [ "$ch" = $'\r' ] && continue
        if [ "$ch" = $'\n' ]; then
          if [ "$esc" = 1 ]; then skipped=$((skipped + 1)) esc=0; else line=$((line + 1 + skipped)) skipped=0; fi
          comment=0
        fi
        [ "${#val}" -gt 0 ] && emit 0
        continue
        ;;
    esac
    [ "$ch" = '#' ] && [ "${#val}" -eq 0 ] && comment=1
    [ "$comment" = 1 ] && continue
    if [ "${#val}" -eq 0 ]; then
      tline=$line
      if [ "$ch" = '"' ]; then q=1; continue; fi
      if [ "$ch" = '`' ]; then bt=1; continue; fi
    fi
    if [ "$esc" = 1 ]; then
      if [ "$ch" = '<' ]; then hesc=1; else val="$val\\"; fi
      esc=0
    fi
    val="$val$ch"
  done
  done
  exec 3<&-
  [ "${#val}" -gt 0 ] && emit 0
  return 0
}

# lex_cached <tracked file>: lex once per file (LX_* as lex sets them).
LC_PATH=() LC_START=() LC_LEN=() LC_ERR=() LA_TEXT=() LA_Q=() LA_LINE=()
lex_cached() {
  local k st len
  for ((k = 0; k < ${#LC_PATH[@]}; k++)); do
    [ "${LC_PATH[$k]}" = "$1" ] || continue
    LX_ERR=${LC_ERR[$k]} st=${LC_START[$k]} len=${LC_LEN[$k]}
    LX_TEXT=() LX_Q=() LX_LINE=()
    if [ "$len" -gt 0 ]; then
      LX_TEXT=("${LA_TEXT[@]:$st:$len}") LX_Q=("${LA_Q[@]:$st:$len}") LX_LINE=("${LA_LINE[@]:$st:$len}")
    fi
    [ -z "$LX_ERR" ]
    return
  done
  lex "$1"
  LC_PATH+=("$1") LC_START+=("${#LA_TEXT[@]}") LC_LEN+=("${#LX_TEXT[@]}") LC_ERR+=("$LX_ERR")
  if [ "${#LX_TEXT[@]}" -gt 0 ]; then
    LA_TEXT+=("${LX_TEXT[@]}") LA_Q+=("${LX_Q[@]}") LA_LINE+=("${LX_LINE[@]}")
  fi
  [ -z "$LX_ERR" ]
}

# deny <token text>: sets DENY to why the token is rejected ('' if allowed).
deny() {
  local r=''
  shopt -s nocasematch
  case $1 in
    *acme_server*) r="ACME server (acme_server parses unauthenticated JWS with go-jose, CVE-2026-116587)" ;;
    pki) r="PKI app (pki: local certificate authority)" ;;
    internal) r="internal issuer (tls internal or issuer internal)" ;;
    local_certs) r="local_certs (internal issuer for every site)" ;;
    acme | zerossl | issuer | issuers | cert_issuer | acme_ca | acme_ca_root | acme_dns | acme_eab | on_demand | on_demand_tls | skip_install_trust | get_certificate)
      r="certificate issuance or ACME client ($1)" ;;
  esac
  shopt -u nocasematch
  case $1 in
    *'{args'* | *'{block}'* | *'{blocks.'*) r="snippet arguments or blocks are not supported" ;;
    '&('*) r="named routes (&(name)) are not supported" ;;
  esac
  DENY=$r
}

# Raw checks and forbidden tokens: every tracked Caddy file, used or not,
# and every file copied or mounted into /etc/caddy, whatever its name (any
# of them can be imported by a glob or a path).
CHECK_FILES=("${CONFIGS[@]}")
for ((k = 0; k < ${#MAP_SRC[@]}; k++)); do
  case " ${CHECK_FILES[*]} " in *" ${MAP_SRC[$k]} "*) ;; *) CHECK_FILES+=("${MAP_SRC[$k]}") ;; esac
done
for f in "${CHECK_FILES[@]}"; do
  if [ -n "$(tr -d '\t\n\r -~' <"$top/$f" | head -c 1 | od -An -c)" ]; then
    report "$f" "only printable ASCII, tab, CR and LF are accepted (Caddy splits tokens at Unicode spaces)"
    continue
  fi
  ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case $line in *'{$'*) report "$f:$ln" "environment placeholder {\$...} (substituted into the raw text before parsing, also in comments)" "$line" ;; esac
    case $line in *'{env.'*) report "$f:$ln" "environment placeholder {env.*} is not on the allow-list (none is)" "$line" ;; esac
  done <"$top/$f"
  if ! lex_cached "$f"; then
    report "$f" "$LX_ERR"
    continue
  fi
  for ((k = 0; k < ${#LX_TEXT[@]}; k++)); do
    deny "${LX_TEXT[$k]}"
    [ -z "$DENY" ] || report "$f:${LX_LINE[$k]}" "$DENY" "${LX_TEXT[$k]}"
  done
  used=no
  for ((k = 0; k < ${#MAP_SRC[@]}; k++)); do [ "${MAP_SRC[$k]}" = "$f" ] && used=yes; done
  [ "$used" = yes ] || report "$f" "Caddy file not copied or mounted into an edge container by any known start point (unknown configurations fail)"
done

# --- Parser (Caddy 2.11 caddyconfig/caddyfile/parse.go) per entry -------------

# Visible files of the current stage: compose mounts first (they shadow the
# image), then the stage and its ancestors, nearest first, last COPY first.
VIS_DEST=() VIS_SRC=()
set_stage() {
  local st=$1 k idx chain=''
  VIS_DEST=() VIS_SRC=()
  for ((k = ${#MAP_DEST[@]} - 1; k >= 0; k--)); do
    [ "${MAP_STAGE[$k]}" = '*' ] && VIS_DEST+=("${MAP_DEST[$k]}") VIS_SRC+=("${MAP_SRC[$k]}")
  done
  while [ -n "$st" ]; do
    for ((k = ${#MAP_DEST[@]} - 1; k >= 0; k--)); do
      [ "${MAP_STAGE[$k]}" = "$st" ] && VIS_DEST+=("${MAP_DEST[$k]}") VIS_SRC+=("${MAP_SRC[$k]}")
    done
    case " $chain " in *" $st "*) break ;; esac
    chain="$chain $st"
    idx=$(stage_index "$st") || break
    st=${ST_PARENT[$idx]}
  done
}
resolve() { # container path -> RESOLVED (tracked source); 1 if none
  local k
  for ((k = 0; k < ${#VIS_DEST[@]}; k++)); do
    [ "${VIS_DEST[$k]}" = "$1" ] && { RESOLVED=${VIS_SRC[$k]}; return 0; }
  done
  return 1
}
# visible_paths: unique visible container paths, one per line.
visible_paths() { printf '%s\n' ${VIS_DEST[@]+"${VIS_DEST[@]}"} | awk '!seen[$0]++'; }

clean_path() { # absolute path -> CLEAN, with . and .. segments removed
  local p=$1/ out='' seg
  while [ -n "$p" ]; do
    seg=${p%%/*} p=${p#*/}
    case $seg in '' | .) ;; ..) out=${out%/*} ;; *) out="$out/$seg" ;; esac
  done
  CLEAN=${out:-/}
}

# Working token stream of the entry being parsed.
W_TEXT=() W_Q=() W_LINE=() W_FILE=() W_CHAIN=() W_SRC=()
# Snippets: name, and their tokens in the S_* arena (start, length).
SN_NAME=() SN_START=() SN_LEN=()
S_TEXT=() S_Q=() S_LINE=() S_FILE=() S_CHAIN=() S_SRC=()

newline_between() { # i j: is W[j] on a new logical line after W[i]?
  [ "${W_FILE[$1]}" != "${W_FILE[$2]}" ] && return 0
  [ "${W_CHAIN[$1]}" != "${W_CHAIN[$2]}" ] && return 0
  local t=${W_TEXT[$1]} nl
  nl=${t//[!$'\n']/}
  [ $((W_LINE[$1] + ${#nl})) -lt "${W_LINE[$2]}" ]
}

# splice <at> <end>: replaces W[at..end) with the N_* tokens.
N_TEXT=() N_Q=() N_LINE=() N_FILE=() N_CHAIN=() N_SRC=()
splice() {
  local a=$1 e=$2
  W_TEXT=(${W_TEXT[@]+"${W_TEXT[@]:0:$a}"} ${N_TEXT[@]+"${N_TEXT[@]}"} ${W_TEXT[@]+"${W_TEXT[@]:$e}"})
  W_Q=(${W_Q[@]+"${W_Q[@]:0:$a}"} ${N_Q[@]+"${N_Q[@]}"} ${W_Q[@]+"${W_Q[@]:$e}"})
  W_LINE=(${W_LINE[@]+"${W_LINE[@]:0:$a}"} ${N_LINE[@]+"${N_LINE[@]}"} ${W_LINE[@]+"${W_LINE[@]:$e}"})
  W_FILE=(${W_FILE[@]+"${W_FILE[@]:0:$a}"} ${N_FILE[@]+"${N_FILE[@]}"} ${W_FILE[@]+"${W_FILE[@]:$e}"})
  W_CHAIN=(${W_CHAIN[@]+"${W_CHAIN[@]:0:$a}"} ${N_CHAIN[@]+"${N_CHAIN[@]}"} ${W_CHAIN[@]+"${W_CHAIN[@]:$e}"})
  W_SRC=(${W_SRC[@]+"${W_SRC[@]:0:$a}"} ${N_SRC[@]+"${N_SRC[@]}"} ${W_SRC[@]+"${W_SRC[@]:$e}"})
}

# load_file <container path> <chain> -> N_* (appends); 1 on error
load_file() {
  local cpath=$1 chain=$2 src k
  resolve "$cpath" || return 1
  src=$RESOLVED
  if ! lex_cached "$src"; then
    report "$src" "$LX_ERR"
    return 1
  fi
  for ((k = 0; k < ${#LX_TEXT[@]}; k++)); do
    N_TEXT+=("${LX_TEXT[$k]}") N_Q+=("${LX_Q[$k]}") N_LINE+=("${LX_LINE[$k]}")
    N_FILE+=("$cpath") N_CHAIN+=("$chain") N_SRC+=("$src")
  done
}

# Results of parse_entry: final tokens with block number, depth and
# whether they start a logical line.
F_TEXT=() F_Q=() F_LINE=() F_SRC=() F_BLOCK=() F_DEPTH=() F_START=()
B_KEYS=()

# parse_entry <container path> <context>: 1 if the entry could not be parsed.
parse_entry() {
  local entry=$1 ctx=$2 i j k pat depth=0 block=-1 sn found base dir glob p m stars q_marks nest start where chain depth_of_chain matches
  W_TEXT=() W_Q=() W_LINE=() W_FILE=() W_CHAIN=() W_SRC=()
  SN_NAME=() SN_START=() SN_LEN=()
  S_TEXT=() S_Q=() S_LINE=() S_FILE=() S_CHAIN=() S_SRC=()
  F_TEXT=() F_Q=() F_LINE=() F_SRC=() F_BLOCK=() F_DEPTH=() F_START=() B_KEYS=()
  N_TEXT=() N_Q=() N_LINE=() N_FILE=() N_CHAIN=() N_SRC=()
  load_file "$entry" "" || { report "$ctx" "configuration not found in the container" "$entry"; return 1; }
  splice 0 0
  i=0
  while [ "$i" -lt "${#W_TEXT[@]}" ]; do
    if [ "${#W_TEXT[@]}" -gt "$max_tokens" ]; then
      report "$ctx" "more than $max_tokens tokens after imports (import cycle?)"
      return 1
    fi
    start=no
    { [ "$i" -eq 0 ] || newline_between $((i - 1)) "$i"; } && start=yes
    where="${W_SRC[$i]}:${W_LINE[$i]}"
    # import <pattern>, at the start of a line, at any depth
    if [ "$start" = yes ] && [ "${W_TEXT[$i]}" = import ]; then
      j=$((i + 1))
      while [ "$j" -lt "${#W_TEXT[@]}" ] && ! newline_between $((j - 1)) "$j"; do j=$((j + 1)); done
      if [ $((j - i)) -ne 2 ]; then
        report "$where" "import must have exactly one argument (import arguments and blocks are not supported) ($ctx)" "${W_TEXT[*]:$i:$((j - i))}"
        return 1
      fi
      pat=${W_TEXT[$((i + 1))]}
      chain="${W_CHAIN[$i]}>${W_FILE[$i]}:${W_LINE[$i]}"
      depth_of_chain=${chain//[!>]/}
      if [ "${#depth_of_chain}" -gt "$max_import_depth" ]; then
        report "$where" "imports nested deeper than $max_import_depth (import cycle?) ($ctx)" "$pat"
        return 1
      fi
      N_TEXT=() N_Q=() N_LINE=() N_FILE=() N_CHAIN=() N_SRC=()
      found=no
      for ((k = 0; k < ${#SN_NAME[@]}; k++)); do
        if [ "${SN_NAME[$k]}" = "$pat" ]; then
          found=yes
          for ((m = SN_START[k]; m < SN_START[k] + SN_LEN[k]; m++)); do
            N_TEXT+=("${S_TEXT[$m]}") N_Q+=("${S_Q[$m]}") N_LINE+=("${S_LINE[$m]}")
            N_FILE+=("${S_FILE[$m]}") N_CHAIN+=("${S_CHAIN[$m]}$chain") N_SRC+=("${S_SRC[$m]}")
          done
        fi
      done
      if [ "$found" = no ]; then
        dir=${W_FILE[$i]%/*}
        case $pat in /*) glob=$pat ;; *) glob=$dir/$pat ;; esac
        clean_path "$glob"
        glob=$CLEAN
        case $glob in *'['* | *']'* | *'{'* | *'}'* | *"\\"*)
          report "$where" "import pattern with [, ], {, } or backslash is not supported ($ctx)" "$pat"
          return 1
          ;;
        esac
        stars=${glob//[!*]/} q_marks=${glob//[!?]/}
        if [ "${#stars}" -gt 1 ] || [ "${#q_marks}" -gt 1 ]; then
          report "$where" "import glob with more than one wildcard (Caddy rejects it) ($ctx)" "$pat"
          return 1
        fi
        matches=()
        if [ "${#stars}" -eq 0 ] && [ "${#q_marks}" -eq 0 ]; then
          resolve "$glob" && matches=("$glob")
        else
          base=${glob##*/}
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            # shellcheck disable=SC2053 # $glob is the pattern
            [[ $p == $glob ]] || continue
            [ "${p//[!\/]/}" = "${glob//[!\/]/}" ] || continue
            case $base in '*'*) case ${p##*/} in .*) continue ;; esac ;; esac
            matches+=("$p")
          done < <(visible_paths | sort)
        fi
        if [ "${#matches[@]}" -eq 0 ]; then
          if [ "$SOFT" = soft ] && [ "${#stars}" -eq 0 ] && [ "${#q_marks}" -eq 0 ]; then
            # Caddy refuses to start on this import: not runnable here.
            return 3
          fi
          report "$where" "import does not resolve to a snippet defined before it or to a tracked file in the container ($ctx)" "$pat"
          return 1
        fi
        for p in "${matches[@]}"; do load_file "$p" "$chain" || return 1; done
      fi
      splice "$i" "$j"
      continue
    fi
    if [ "$depth" -eq 0 ]; then
      if [ "$start" = no ]; then
        report "$where" "unexpected token after a block on the same line ($ctx)" "${W_TEXT[$i]}"
        return 1
      fi
      j=$((i + 1))
      while [ "$j" -lt "${#W_TEXT[@]}" ] && ! newline_between $((j - 1)) "$j"; do j=$((j + 1)); done
      k=$((j - 1))
      if [ "${W_TEXT[$k]}" != '{' ] || [ "${W_Q[$k]}" != 0 ]; then
        report "$where" "top-level line must be '<addresses> {' or '{' (blocks without braces, multi-line addresses and stray tokens are not supported) ($ctx)" "${W_TEXT[*]:$i:$((j - i))}"
        return 1
      fi
      if [ $((j - i)) -eq 2 ] && [[ ${W_TEXT[$i]} =~ ^\(.+\)$ ]]; then
        # Snippet definition: store its raw tokens (imports expand on use).
        sn=${W_TEXT[$i]:1:$((${#W_TEXT[$i]} - 2))}
        for ((m = 0; m < ${#SN_NAME[@]}; m++)); do
          if [ "${SN_NAME[$m]}" = "$sn" ]; then
            report "$where" "redeclaration of snippet ($ctx)" "$sn"
            return 1
          fi
        done
        m=$j nest=1
        while [ "$m" -lt "${#W_TEXT[@]}" ]; do
          if [ "${W_Q[$m]}" = 0 ]; then
            [ "${W_TEXT[$m]}" = '{' ] && nest=$((nest + 1))
            [ "${W_TEXT[$m]}" = '}' ] && nest=$((nest - 1))
          fi
          [ "$nest" -eq 0 ] && break
          m=$((m + 1))
        done
        if [ "$nest" -ne 0 ]; then
          report "$where" "snippet without its closing brace ($ctx)" "$sn"
          return 1
        fi
        SN_NAME+=("$sn") SN_START+=("${#S_TEXT[@]}") SN_LEN+=($((m - j)))
        for ((p = j; p < m; p++)); do
          S_TEXT+=("${W_TEXT[$p]}") S_Q+=("${W_Q[$p]}") S_LINE+=("${W_LINE[$p]}")
          S_FILE+=("${W_FILE[$p]}") S_CHAIN+=("${W_CHAIN[$p]}") S_SRC+=("${W_SRC[$p]}")
        done
        i=$((m + 1))
        continue
      fi
      block=$((block + 1))
      B_KEYS+=("$((j - i - 1))")
      for ((m = i; m < j; m++)); do
        F_TEXT+=("${W_TEXT[$m]}") F_Q+=("${W_Q[$m]}") F_LINE+=("${W_LINE[$m]}") F_SRC+=("${W_SRC[$m]}")
        if [ "$m" -eq "$i" ]; then F_START+=(yes); else F_START+=(no); fi
        F_BLOCK+=("$block") F_DEPTH+=(0)
      done
      depth=1
      i=$j
      continue
    fi
    F_TEXT+=("${W_TEXT[$i]}") F_Q+=("${W_Q[$i]}") F_LINE+=("${W_LINE[$i]}") F_SRC+=("${W_SRC[$i]}")
    F_BLOCK+=("$block") F_DEPTH+=("$depth") F_START+=("$start")
    if [ "${W_Q[$i]}" = 0 ]; then
      if [ "${W_TEXT[$i]}" = '{' ]; then
        depth=$((depth + 1))
      elif [ "${W_TEXT[$i]}" = '}' ]; then
        depth=$((depth - 1))
        F_DEPTH[${#F_DEPTH[@]} - 1]=$depth
      fi
    fi
    i=$((i + 1))
  done
  if [ "$depth" -ne 0 ]; then
    report "$ctx" "unbalanced braces after imports"
    return 1
  fi
  return 0
}

# line_end <index>: LINE_END is the index after the logical line at <index>.
line_end() {
  LINE_END=$(($1 + 1))
  while [ "$LINE_END" -lt "${#F_TEXT[@]}" ] && [ "${F_START[$LINE_END]}" = no ]; do LINE_END=$((LINE_END + 1)); done
}

# check_entry <stage> <entry> [soft]: with soft, an entry whose plain
# (non-glob) import does not resolve in this stage is skipped (status 3):
# Caddy would refuse to start it there.
check_entry() {
  local stage=$1 entry=$2 ctx k e name args globals=0 first_global=-1 seen=' ' b rc
  ctx="$entry in stage ${stage##*#} of ${stage%#*}"
  set_stage "$stage"
  SOFT=${3:-no}
  parse_entry "$entry" "$ctx"
  rc=$?
  SOFT=no
  [ "$rc" -eq 0 ] || return "$rc"
  for ((b = 0; b < ${#B_KEYS[@]}; b++)); do
    if [ "${B_KEYS[$b]}" -eq 0 ]; then
      globals=$((globals + 1))
      [ "$first_global" -ge 0 ] || first_global=$b
    fi
  done
  if [ "$globals" -eq 0 ]; then
    report "$ctx" "no global options block (admin off, auto_https off and persist_config off are required)"
  elif [ "$globals" -gt 1 ]; then
    report "$ctx" "more than one global options block ($globals)"
  elif [ "$first_global" -ne 0 ]; then
    report "$ctx" "the global options block is not the first block"
  fi
  for ((k = 0; k < ${#F_TEXT[@]}; k++)); do
    [ "${F_START[$k]}" = yes ] || continue
    line_end "$k"
    e=$LINE_END
    name=${F_TEXT[$k]}
    args=$((e - k - 1))
    b=${F_BLOCK[$k]}
    where="${F_SRC[$k]}:${F_LINE[$k]}"
    if [ "${B_KEYS[$b]}" -eq 0 ] && [ "${F_DEPTH[$k]}" -eq 1 ]; then
      case $name in
        admin | auto_https | persist_config)
          case $seen in *" $name "*) report "$where" "global option $name appears twice ($ctx)" ;; esac
          seen="$seen$name "
          if [ "$args" -ne 1 ] || [ "${F_TEXT[$((k + 1))]}" != off ]; then
            report "$where" "global option must be exactly '$name off' ($ctx)" "${F_TEXT[*]:$k:$((e - k))}"
          fi
          ;;
        '}') ;;
        *)
          case $allowed_globals in
            *" $name "*) ;;
            *) report "$where" "global option is not on the edge allow-list (admin, auto_https, persist_config,$allowed_globals) ($ctx)" "$name" ;;
          esac
          ;;
      esac
    fi
    shopt -s nocasematch
    case $name in
      tls)
        if [ "$args" -ne 2 ] || [ "${F_TEXT[$((e - 1))]}" = '{' ] || [[ ${F_TEXT[$((k + 1))]} == internal ]]; then
          report "$where" "tls must be exactly 'tls <cert-file> <key-file>' (no block, no internal issuer, no ACME e-mail) ($ctx)" "${F_TEXT[*]:$k:$((e - k))}"
        fi
        ;;
      invoke) report "$where" "named routes (invoke) are not supported ($ctx)" ;;
    esac
    shopt -u nocasematch
  done
  if [ "$globals" -eq 1 ]; then
    for name in admin auto_https persist_config; do
      case $seen in *" $name "*) ;; *) report "$ctx" "global option '$name off' is missing" ;; esac
    done
  fi
  CHECKED="$CHECKED
  $ctx"
}

# Entries: every leaf stage with files in /etc/caddy runs /etc/caddy/Caddyfile
# (the base image's command) and every --config path that resolves in it.
CHECKED=''
RUNNABLE=' '
SOFT=no
entries=0
for ((s = 0; s < ${#ST_ID[@]}; s++)); do
  st=${ST_ID[$s]} leaf=yes
  for ((k = 0; k < ${#ST_ID[@]}; k++)); do [ "${ST_PARENT[$k]}" = "$st" ] && leaf=no; done
  [ "$leaf" = yes ] || continue
  set_stage "$st"
  own=no
  for ((k = 0; k < ${#MAP_DEST[@]}; k++)); do
    [ "${MAP_STAGE[$k]}" = '*' ] && continue
    for x in ${VIS_SRC[@]+"${VIS_SRC[@]}"}; do [ "$x" = "${MAP_SRC[$k]}" ] && own=yes; done
  done
  [ "$own" = yes ] || continue
  if ! resolve /etc/caddy/Caddyfile; then
    report "${st%#*}" "stage ${st##*#} has Caddy files but no tracked /etc/caddy/Caddyfile (it would run the base image's default config)"
    continue
  fi
  check_entry "$st" /etc/caddy/Caddyfile
  entries=$((entries + 1))
  for p in $CFG_PATHS; do
    [ "$p" = /etc/caddy/Caddyfile ] && continue
    set_stage "$st"
    resolve "$p" || continue
    check_entry "$st" "$p" soft
    case $? in 3) continue ;; esac
    entries=$((entries + 1))
    RUNNABLE="$RUNNABLE$p "
  done
done
for p in $CFG_PATHS; do
  [ "$p" = /etc/caddy/Caddyfile ] && continue
  case $RUNNABLE in *" $p "*) continue ;; esac
  report "$p" "caddy --config names a configuration that no edge stage provides with all its imports (no Dockerfile COPY or Compose mount, or an import that resolves nowhere)"
done

if [ "$entries" -eq 0 ] && [ "$errors" -eq 0 ]; then
  echo "ERROR: no edge start point found (no Dockerfile stage copies a Caddyfile to /etc/caddy)." >&2
  exit 2
fi

if [ "$errors" -gt 0 ]; then
  echo "See the edge configuration guard in docs/security/container-vulnerabilities.md."
  exit 1
fi
printf 'OK: %d Caddy files, %d entry configurations checked:%s\n' "${#CONFIGS[@]}" "$entries" "$CHECKED"
exit 0
