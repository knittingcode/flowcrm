#!/usr/bin/env bash
#
# Regression tests for scripts/ci/guard-edge-config.sh and
# scripts/ci/edge-adapted-config.jq. Every guard case runs in its own
# temporary Git repository holding copies of the repository's edge files
# (Dockerfile, Caddyfiles, Compose files, scan.sh) with one unsafe change;
# the repository under test is only read. The adapted-config cases run the
# jq check on JSON fixtures (tests/app/scan.sh runs it on the built images).
#
# Usage: guard-edge-config.test.sh
# GUARD=<path> or ADAPTED=<path> runs the suite against another
# implementation (used for mutation tests).

set -u

here=$(cd "$(dirname "$0")" && pwd)
# The suite runs the guard, or a modified or mutated copy of it (GUARD=),
# so it runs only where no container engine can be reached.
"$here/../no-docker.sh" --check >/dev/null 2>&1 ||
  exec "$here/../no-docker.sh" "$BASH" "$here/guard-edge-config.test.sh" "$@"
guard=${GUARD:-"$here/../guard-edge-config.sh"}
adapted=${ADAPTED:-"$here/../edge-adapted-config.jq"}
real=$(git -C "$here" rev-parse --show-toplevel) || exit 2
work=$(mktemp -d "${TMPDIR:-/tmp}/guard-edge-config-tests.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT
# Never let Git discover a repository above the fixtures.
export GIT_CEILING_DIRECTORIES=$work

NL=$'\n'
TAB=$'\t'
CR=$'\r'
REAL=(docker/edge/Dockerfile docker/edge/Caddyfile.dev docker/edge/Caddyfile.prod docker/edge/common.caddy
  tests/app/https/Caddyfile tests/app/https/compose.https.yaml compose.yaml compose.prodlike.yaml compose.test.yaml
  compose.fixture.yaml tests/app/scan.sh docker/api/Dockerfile docker/db/Dockerfile docker/web/Dockerfile)
P=docker/edge/Caddyfile.prod
D=docker/edge/Caddyfile.dev
C=docker/edge/common.caddy
H=tests/app/https/Caddyfile
HC=tests/app/https/compose.https.yaml
DF=docker/edge/Dockerfile
pass=0
fail=0
case_no=0

new_repo() {
  case_no=$((case_no + 1))
  repo="$work/repo-$case_no"
  git init -q "$repo" || exit 2
}

# base: a new repository with copies of the real edge files.
base() {
  local f
  new_repo
  for f in "${REAL[@]}"; do
    mkdir -p "$repo/$(dirname "$f")"
    cp "$real/$f" "$repo/$f" || exit 2
  done
  git -C "$repo" add -f -- "${REAL[@]}" || exit 2
}

# put <path> <content>: write the file and add it to the index.
put() {
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s' "$2" >"$repo/$1"
  git -C "$repo" add -f -- "$1" || exit 2
}

# subst <path> <from> <to>: replace every literal <from> (one line) by <to>.
# Both are passed to awk through files, so backslashes stay literal.
subst() {
  printf '%s' "$2" >"$work/from"
  printf '%s' "$3" >"$work/to"
  awk -v ff="$work/from" -v tf="$work/to" '
    BEGIN { getline f < ff; n = 0; t = ""
      while ((getline l < tf) > 0) { t = t (n++ ? "\n" : "") l } }
    { out = ""; s = $0
      while ((i = index(s, f)) > 0) { out = out substr(s, 1, i - 1) t; s = substr(s, i + length(f)) }
      print out s }' "$repo/$1" >"$work/subst" || exit 2
  if cmp -s "$work/subst" "$repo/$1"; then
    echo "HARNESS ERROR: '$2' not found in $1" >&2
    exit 2
  fi
  cat "$work/subst" >"$repo/$1"
}

# expect <name> <expected-exit> [message]: the guard's exit status, and
# the message (a fixed string) must appear in its output.
expect() {
  local name=$1 want=$2 msg=${3-} got
  "$guard" "$repo" >"$work/out" 2>&1
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$msg" ] || grep -qF -- "$msg" "$work/out"; }; then
    pass=$((pass + 1))
    printf 'PASS  %-74s exit=%s\n' "$name" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-74s exit=%s want=%s%s\n' "$name" "$got" "$want" "${msg:+ message=$msg}"
    sed 's/^/      | /' "$work/out"
  fi
}

# bad <name> <message> <path> <from> <to>: one substitution, must fail.
bad() {
  base
  subst "$3" "$4" "$5"
  expect "$1" 1 "$2"
}

SITE=':8080 {'
GLOBAL='	persist_config off'

# --- Accepted ------------------------------------------------------------------
repo=$real
expect "actual repository" 0 "3 entry configurations checked"
"$guard" "$real" >"$work/out" 2>&1
for e in "/etc/caddy/Caddyfile in stage dev" "/etc/caddy/Caddyfile in stage prod" "/etc/caddy/https/Caddyfile in stage prod"; do
  if grep -qF "$e" "$work/out"; then
    pass=$((pass + 1))
    printf 'PASS  %-74s\n' "actual repository checks $e"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-74s\n' "actual repository checks $e"
    sed 's/^/      | /' "$work/out"
  fi
done
base
expect "copy of the actual edge files" 0
base
subst "$P" "$SITE" "# acme_server, pki and tls internal in a comment are ignored${NL}$SITE"
expect "acme_server, pki, tls internal in a comment are ignored" 0
base
subst "$P" "	admin off" "	\"admin\" \"off\""
expect "quoted admin off (same tokens for Caddy)" 0
base
subst "$P" "	admin off" "	admin off${CR}"
subst "$P" "	auto_https off" "	auto_https off${CR}"
expect "CRLF line endings" 0

# --- acme_server, pki, issuers, anywhere -------------------------------------
bad "acme_server in the production site" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	acme_server"
bad "acme_server in a handle block of the dev site" "ACME server (acme_server" "$D" "		reverse_proxy web:5173" "		acme_server"
bad "acme_server in an imported snippet (common.caddy baseline)" "ACME server (acme_server" "$C" "(baseline) {" "(baseline) {${NL}	acme_server"
bad "acme_server in a snippet nobody imports" "ACME server (acme_server" "$C" "(php) {" "(unused) {${NL}	acme_server${NL}}${NL}${NL}(php) {"
bad "acme_server in the HTTPS test edge" "ACME server (acme_server" "$H" "	import app" "	import app${NL}	acme_server"
bad "upper-case ACME_SERVER" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	ACME_SERVER"
bad "quoted \"acme_server\" directive" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	\"acme_server\""
bad "backtick-quoted acme_server directive" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	\`acme_server\`"
bad "acme_server split by a CR (Caddy drops CR)" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	acme_${CR}server"
bad "acme_server inside a route matcher block" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	route /acme/* {${NL}		acme_server${NL}	}"
bad "acme_server as part of a token (a#acme_server)" "ACME server (acme_server" "$P" "$SITE" "$SITE${NL}	respond a#acme_server"
bad "pki global option" "PKI app (pki" "$P" "$GLOBAL" "$GLOBAL${NL}	pki {${NL}		ca local${NL}	}"
bad "local_certs global option" "local_certs (internal issuer" "$P" "$GLOBAL" "$GLOBAL${NL}	local_certs"
bad "acme_ca global option" "certificate issuance or ACME client (acme_ca)" "$P" "$GLOBAL" "$GLOBAL${NL}	acme_ca https://ca.example/dir"
bad "acme_dns global option" "certificate issuance or ACME client (acme_dns)" "$P" "$GLOBAL" "$GLOBAL${NL}	acme_dns cloudflare x"
bad "cert_issuer global option" "certificate issuance or ACME client (cert_issuer)" "$P" "$GLOBAL" "$GLOBAL${NL}	cert_issuer zerossl x"
bad "on_demand_tls global option" "certificate issuance or ACME client (on_demand_tls)" "$P" "$GLOBAL" "$GLOBAL${NL}	on_demand_tls {${NL}		ask http://x${NL}	}"
bad "email global option (not on the allow-list)" "global option is not on the edge allow-list" "$P" "$GLOBAL" "$GLOBAL${NL}	email ops@example.test"
bad "servers global option (not on the allow-list)" "global option is not on the edge allow-list" "$P" "$GLOBAL" "$GLOBAL${NL}	servers {${NL}		protocols h1${NL}	}"
bad "tls internal" "tls must be exactly" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls internal"
bad "tls internal: internal is rejected too" "internal issuer (tls internal" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls internal"
bad "tls with an ACME e-mail" "tls must be exactly" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls ops@example.test"
bad "tls block with issuer acme" "certificate issuance or ACME client (issuer)" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls {${NL}		issuer acme${NL}	}"
bad "tls files plus a block" "tls must be exactly" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls /a.crt /a.key {${NL}		protocols tls1.3${NL}	}"
bad "tls arguments continued over an escaped newline" "tls must be exactly" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls \\${NL}		/a.crt /a.key extra"
bad "tls on_demand" "certificate issuance or ACME client (on_demand)" "$H" "	tls /run/flowcrm-https/edge.crt /run/flowcrm-https/edge.key" "	tls {${NL}		on_demand${NL}	}"
bad "zerossl issuer in a reverse_proxy block" "certificate issuance or ACME client (zerossl)" "$P" "$SITE" "$SITE${NL}	reverse_proxy x {${NL}		transport http {${NL}			tls_client_auth zerossl${NL}		}${NL}	}"

# --- Global options --------------------------------------------------------------
bad "admin with an address" "global option must be exactly 'admin off'" "$P" "	admin off" "	admin localhost:2019"
bad "admin off with a block" "global option must be exactly 'admin off'" "$P" "	admin off" "	admin off {${NL}		origins x${NL}	}"
bad "upper-case admin OFF (Caddy reads it as an address)" "global option must be exactly 'admin off'" "$D" "	admin off" "	admin OFF"
bad "admin missing" "global option 'admin off' is missing" "$P" "	admin off" ""
bad "auto_https missing" "global option 'auto_https off' is missing" "$D" "	auto_https off" ""
bad "persist_config missing" "global option 'persist_config off' is missing" "$P" "	persist_config off" ""
bad "auto_https disable_redirects" "global option must be exactly 'auto_https off'" "$P" "	auto_https off" "	auto_https disable_redirects"
bad "admin twice (admin off, then an address)" "global option admin appears twice" "$P" "	admin off" "	admin off${NL}	admin :2019"
bad "comment ending in a backslash joins the next line" "global option must be exactly 'admin off'" "$P" "	admin off" "	admin off # note \\"
bad "second global options block" "more than one global options block" "$P" "$SITE" "{${NL}	admin localhost:2019${NL}}${NL}$SITE"
bad "second global options block in the HTTPS test edge" "more than one global options block" "$H" "https://flowcrm.test:8443 {" "{${NL}	admin :2019${NL}}${NL}https://flowcrm.test:8443 {"
base
subst "$D" "	admin off" "	admin localhost:2019"
expect "unsafe dev global block (dev image)" 1 "/etc/caddy/Caddyfile in stage dev"
base
subst "$P" "	admin off" "	admin localhost:2019"
expect "unsafe production global block also fails the HTTPS test edge" 1 "(/etc/caddy/https/Caddyfile in stage prod"
base
put "$P" "import /etc/caddy/common.caddy${NL}${NL}(app) {${NL}	import baseline${NL}}${NL}${NL}:8080 {${NL}	import app${NL}}${NL}${NL}{${NL}	admin off${NL}	auto_https off${NL}	persist_config off${NL}}${NL}"
expect "global options block after a site block" 1 "the global options block is not the first block"
base
put "$P" "import /etc/caddy/common.caddy${NL}${NL}(app) {${NL}	import baseline${NL}}${NL}${NL}:8080 {${NL}	import app${NL}}${NL}"
expect "no global options block" 1 "no global options block"
bad "global options block in common.caddy, before the real one" "more than one global options block" "$C" "(php) {" "{${NL}	admin :2019${NL}}${NL}${NL}(php) {"

# --- Placeholders, snippets, imports, unsupported syntax -------------------------
bad "{\$VAR} environment placeholder" "environment placeholder {\$...}" "$P" "	admin off" "	admin {\$CADDY_ADMIN_OFF:off}"
bad "{\$VAR} as a directive" "environment placeholder {\$...}" "$P" "$SITE" "$SITE${NL}	{\$EXTRA}"
bad "{\$VAR} hidden in a comment" "environment placeholder {\$...}" "$C" "(php) {" "# {\$EVIL}${NL}(php) {"
bad "{env.VAR} placeholder" "environment placeholder {env.*}" "$P" "$SITE" "$SITE${NL}	respond {env.SECRET}"
bad "snippet argument placeholder" "snippet arguments or blocks are not supported" "$C" "(php) {" "(php) {${NL}	{args[0]}"
bad "snippet {block} placeholder" "snippet arguments or blocks are not supported" "$C" "(php) {" "(php) {${NL}	{block}"
bad "import with arguments" "import must have exactly one argument" "$P" "	import baseline" "	import baseline acme_srv"
bad "import with a block" "import must have exactly one argument" "$P" "	import baseline" "	import baseline {${NL}		x y${NL}	}"
bad "unresolved import (missing file)" "import does not resolve" "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/common.caddy${NL}import /etc/caddy/missing.caddy"
bad "unresolved import (undefined snippet)" "import does not resolve" "$P" "	import baseline" "	import nosuchsnippet"
bad "import glob that matches nothing" "import does not resolve" "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/common.caddy${NL}import /etc/caddy/conf.d/*.caddy"
bad "import glob with two wildcards" "more than one wildcard" "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/*/*.caddy"
bad "import of a host path outside the container files" "import does not resolve" "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/common.caddy${NL}import ../../srv/x.caddy"
bad "re-import of common.caddy redeclares its snippets" "redeclaration of snippet" "$C" "(php) {" "import /etc/caddy/common.caddy${NL}(php) {"
base
put docker/edge/loop.caddy "import /etc/caddy/loop.caddy${NL}"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/loop.caddy /etc/caddy/loop.caddy"
subst "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/common.caddy${NL}import /etc/caddy/loop.caddy"
expect "import cycle (a file that imports itself)" 1 "import cycle?"
bad "heredoc" "heredoc (<<) is not supported" "$P" "$SITE" "$SITE${NL}	respond <<EOF${NL}	x${NL}	EOF"
bad "named route" "named routes (&(name)) are not supported" "$P" "$SITE" "&(r) {${NL}	respond x${NL}}${NL}$SITE"
bad "invoke of a named route" "named routes (invoke) are not supported" "$P" "$SITE" "$SITE${NL}	invoke r"
bad "site address without a brace" "top-level line must be" "$P" "$SITE" ":8080"
bad "non-breaking space before acme_server (Caddy splits there)" "only printable ASCII" "$P" "$SITE" "$SITE${NL}	"$'\xc2\xa0'"acme_server"

base
put docker/edge/extra.caddy "(extra) {${NL}	acme_server${NL}}${NL}"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/extra.caddy /etc/caddy/extra.caddy"
subst "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/*.caddy"
subst "$P" "	import baseline" "	import baseline${NL}	import extra"
expect "unsafe snippet reached through an import glob" 1 "ACME server (acme_server"
base
put docker/edge/extra.caddy "{${NL}	admin localhost:2019${NL}}${NL}"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/extra.caddy /etc/caddy/extra.caddy"
subst "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/*.caddy"
expect "global block injected through an import glob" 1 "more than one global options block"
base
put docker/edge/.hidden.caddy "{${NL}	admin localhost:2019${NL}}${NL}"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/.hidden.caddy /etc/caddy/.hidden.caddy"
subst "$P" "import /etc/caddy/common.caddy" "import /etc/caddy/*.caddy"
expect "import glob *.caddy skips dot files, as Caddy does" 0

# --- Discovery of configurations ----------------------------------------------------
base
put docker/edge/Caddyfile.staging "{${NL}	admin off${NL}	auto_https off${NL}	persist_config off${NL}}${NL}:8080 {${NL}	respond ok${NL}}${NL}"
expect "tracked Caddyfile that no start point uses" 1 "Caddy file not copied or mounted"
base
put docker/edge/caddy.json '{"admin":{"disabled":true}}'
expect "Caddy JSON configuration file" 1 "Caddy JSON configuration"
base
put config/edge.json '{"apps":{"http":{}}}'
expect "JSON file with an apps key" 1 "looks like a Caddy JSON configuration"
base
put frontend/tsconfig.json '{"compilerOptions":{"strict":true}}'
expect "unrelated JSON files are accepted" 0
new_repo
put README.md "text${NL}"
expect "no tracked Caddy configuration (inspection error)" 2
mkdir -p "$work/not-a-repo"
repo=$work/not-a-repo
expect "not a Git repository (inspection error)" 2

# --- Start points: Dockerfile ---------------------------------------------------------
bad "Dockerfile CMD override in the edge" "CMD or ENTRYPOINT in an edge Dockerfile" "$DF" "COPY docker/edge/Caddyfile.dev /etc/caddy/Caddyfile" "COPY docker/edge/Caddyfile.dev /etc/caddy/Caddyfile${NL}CMD [\"caddy\", \"run\", \"--config\", \"/etc/caddy/Caddyfile\", \"--adapter\", \"caddyfile\"]"
bad "Dockerfile ENTRYPOINT with --resume" "caddy run --resume" "$DF" "COPY docker/edge/Caddyfile.dev /etc/caddy/Caddyfile" "COPY docker/edge/Caddyfile.dev /etc/caddy/Caddyfile${NL}ENTRYPOINT [\"caddy\", \"run\", \"--resume\"]"
bad "Dockerfile ENV CADDY_ADMIN" "CADDY_ADMIN would set the admin API address" "$DF" "USER 65534:65534" "ENV CADDY_ADMIN=0.0.0.0:2019${NL}USER 65534:65534"
bad "Dockerfile RUN writes /etc/caddy" "only COPY may write to /etc/caddy" "$DF" "USER 65534:65534" "RUN echo '{\$X}' >> /etc/caddy/Caddyfile${NL}USER 65534:65534"
bad "Dockerfile ADD into /etc/caddy" "ADD into /etc/caddy is not supported" "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "ADD docker/edge/common.caddy /etc/caddy/common.caddy"
bad "Dockerfile COPY --from into /etc/caddy" "COPY --from into /etc/caddy is not supported" "$DF" "COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile" "COPY --from=spa-build /app/Caddyfile /etc/caddy/Caddyfile"
bad "Dockerfile COPY of a directory into /etc/caddy" "not a tracked file" "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/ /etc/caddy/"
bad "Dockerfile COPY of two files into /etc/caddy" "must copy exactly one file" "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy docker/edge/Caddyfile.dev /etc/caddy/"
bad "Dockerfile RUN over a line continuation writes /etc/caddy" "only COPY may write" "$DF" "USER 65534:65534" "RUN true \\${NL}  && cp /tmp/x /etc/caddy/Caddyfile${NL}USER 65534:65534"
bad "edge stage without a Caddyfile (base image default config)" "has Caddy files but no tracked /etc/caddy/Caddyfile" "$DF" "FROM caddy-base AS dev" "FROM caddy-base AS bare${NL}${NL}FROM caddy-base AS dev"
bad "Dockerfile RUN caddy reload" "caddy subcommand not allowed" "$DF" "USER 65534:65534" "RUN caddy reload --config /etc/caddy/Caddyfile${NL}USER 65534:65534"

# --- Start points: Compose, scripts, Makefile, workflows --------------------------------
base
subst compose.yaml "    networks: [front, back]" "    environment:${NL}      CADDY_ADMIN: 0.0.0.0:2019${NL}    networks: [front, back]"
expect "CADDY_ADMIN in the edge's Compose environment" 1 "CADDY_ADMIN would set the admin API address"
bad "--resume in a Compose command" "caddy run --resume" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\", \"caddyfile\", \"--resume\"]"
bad "-r (short --resume) in a Compose command" "caddy run --resume" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\", \"caddyfile\", \"-r\"]"
bad "--watch in a Compose command" "caddy run --watch" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\", \"caddyfile\", \"--watch\"]"
bad "--envfile in a Compose command" "caddy run --envfile" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\", \"caddyfile\", \"--envfile\", \"/run/x\"]"
bad "--config outside /etc/caddy" "--config must be a literal path below /etc/caddy" "$HC" "\"/etc/caddy/https/Caddyfile\"" "\"/srv/Caddyfile\""
bad "--config=/etc/caddy/... no image or mount provides" "no edge stage provides" "$HC" "\"--config\", \"/etc/caddy/https/Caddyfile\"" "\"--config=/etc/caddy/other/Caddyfile\""
bad "--config with a variable" "--config must be a literal path" "$HC" "\"/etc/caddy/https/Caddyfile\"" "\"\$CONFIG\""
bad "--adapter json" "needs --adapter caddyfile" "$HC" "\"--adapter\", \"caddyfile\"" "\"--adapter\", \"json\""
bad "no --adapter (a non-Caddyfile name would be read as JSON)" "needs --adapter caddyfile" "$HC" ", \"--adapter\", \"caddyfile\"" ""
bad "no --config (./Caddyfile or the autosave)" "without --config" "$HC" "\"--config\", \"/etc/caddy/https/Caddyfile\", " ""
bad "unknown caddy run flag" "unknown flag for caddy run" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\", \"caddyfile\", \"--resume-from\"]"
bad "caddy start in a Compose command" "caddy subcommand not allowed" "$HC" "[\"caddy\", \"run\"" "[\"caddy\", \"start\""
bad "Compose command as a block sequence" "unsupported YAML form" "$HC" "    command: [\"caddy\", \"run\", \"--config\", \"/etc/caddy/https/Caddyfile\", \"--adapter\", \"caddyfile\"]" "    command:${NL}      - caddy${NL}      - run${NL}      - --resume"
bad "Compose command flow sequence continued on the next line" "unsupported YAML form" "$HC" "\"--adapter\", \"caddyfile\"]" "\"--adapter\",${NL}      \"caddyfile\", \"--resume\"]"
bad "Compose command plain scalar continued on the next line" "continues on the next line" "$HC" "    command: [\"caddy\", \"run\", \"--config\", \"/etc/caddy/https/Caddyfile\", \"--adapter\", \"caddyfile\"]" "    command: caddy run --config /etc/caddy/https/Caddyfile --adapter caddyfile${NL}      --resume"
bad "Compose mount into /etc/caddy without :ro" "must be read-only" "$HC" "Caddyfile:/etc/caddy/https/Caddyfile:ro" "Caddyfile:/etc/caddy/https/Caddyfile"
bad "Compose mount of an untracked file into /etc/caddy" "not a tracked file" "$HC" "./tests/app/https/Caddyfile:/etc/caddy/https/Caddyfile:ro" "./tests/app/https/evil:/etc/caddy/https/Caddyfile:ro"
bad "Compose long-syntax mount into /etc/caddy" "unsupported reference to /etc/caddy" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - type: bind${NL}        source: ./x${NL}        target: /etc/caddy/Caddyfile"
base
put tests/app/extra.sh "#!/bin/sh${NL}docker exec edge caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile${NL}"
expect "caddy reload in a script" 1 "caddy subcommand not allowed"
base
put tests/app/extra.sh "#!/bin/sh${NL}docker run --rm \\${NL}  img caddy run --config /etc/caddy/Caddyfile \\${NL}  --adapter caddyfile --resume${NL}"
expect "--resume after a shell line continuation" 1 "caddy run --resume"
base
put tests/app/extra.sh "#!/bin/sh${NL}docker run --rm -v \"\$PWD/evil:/etc/caddy/Caddyfile:ro\" img caddy run --config /etc/caddy/Caddyfile --adapter caddyfile${NL}"
expect "docker run mounting another file over /etc/caddy/Caddyfile" 1 "mount into /etc/caddy that is not a Compose-mounted"
base
put tests/app/extra.sh "#!/bin/sh${NL}docker run --rm --mount type=bind,src=./x,target=/etc/caddy/Caddyfile img${NL}"
expect "docker run --mount into /etc/caddy" 1 "--mount into /etc/caddy is not supported"
base
put tests/app/extra.sh "#!/bin/sh${NL}docker compose run --entrypoint caddy edge reload${NL}"
expect "--entrypoint caddy with another subcommand" 1 "caddy subcommand not allowed"
base
put tests/app/extra.sh "#!/bin/sh${NL}/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile -w${NL}"
expect "absolute /usr/bin/caddy with -w" 1 "caddy run --watch"
base
put tests/app/extra.sh "#!/bin/sh${NL}sh -c 'caddy run --config=/etc/caddy/Caddyfile --adapter=caddyfile --resume'${NL}"
expect "caddy run --resume inside sh -c '...'" 1 "caddy run --resume"
base
put tests/app/extra.sh "#!/bin/sh${NL}export CADDY_ADMIN=localhost:2019${NL}"
expect "export CADDY_ADMIN in a script" 1 "CADDY_ADMIN would set"
base
put Makefile "serve:${NL}${TAB}caddy file-server --listen :8080${NL}"
expect "caddy file-server in the Makefile" 1 "caddy subcommand not allowed"
base
put .github/workflows/edge.yml "jobs:${NL}  x:${NL}    steps:${NL}      - run: caddy run --config /etc/caddy/Caddyfile --adapter caddyfile --resume${NL}"
expect "caddy run --resume in a workflow" 1 "caddy run --resume"
base
put bin/edge "#!/bin/sh${NL}exec caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile --pretty${NL}"
expect "caddy adapt with allowed flags in bin/ is accepted" 0
base
put tests/app/extra.sh "#!/bin/sh${NL}echo 'the caddy edge'${NL}"
expect "prose with the word caddy fails closed (unknown subcommand)" 1 "caddy subcommand not allowed"
base
put tests/app/extra.sh "#!/bin/sh${NL}# caddy run --resume is never used here${NL}"
expect "caddy command in a full-line comment is ignored" 0


# --- Audit reproducers (FCRM-SEC-042 E, MEDIUM-1 and LOW-1) ---------------------------
# shellcheck disable=SC2016 # the Compose text itself, not an expansion
EDGE_VOL='      - ${FLOWCRM_GATE_DIR:-./docker/edge/no-gate}:/run/flowcrm-gate:ro'
UNSAFE="{${NL}	admin off${NL}}${NL}:8080 {${NL}	acme_server${NL}}${NL}"
base
put docker/edge/acme.conf "acme_server${NL}"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - ./docker/edge/acme.conf:/etc/caddy/acme.conf:ro"
subst "$D" "	import baseline" "	import baseline${NL}	import /etc/caddy/*.conf"
expect "E conf-compose-glob: acme_server in a Compose-mounted .conf reached by a glob" 1 "docker/edge/acme.conf:1: ACME server (acme_server"
base
put docker/edge/acme.conf "acme_server${NL}"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/acme.conf /etc/caddy/acme.conf"
subst "$P" "	import baseline" "	import baseline${NL}	import acme.conf"
expect "E conf-dockerfile-copy: acme_server in a copied .conf imported by path" 1 "docker/edge/acme.conf:1: ACME server (acme_server"
base
put docker/edge/extra.conf "{\$EDGE_EXTRA}${NL}respond {env.X}${NL}"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - ./docker/edge/extra.conf:/etc/caddy/extra.conf:ro"
subst "$D" "	import baseline" "	import baseline${NL}	import /etc/caddy/*.conf"
expect "E conf-envvar: {\$VAR} in an imported .conf" 1 "docker/edge/extra.conf:1: environment placeholder {\$...}"
base
put docker/edge/extra.conf "{\$EDGE_EXTRA}${NL}respond {env.X}${NL}"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - ./docker/edge/extra.conf:/etc/caddy/extra.conf:ro"
subst "$D" "	import baseline" "	import baseline${NL}	import /etc/caddy/*.conf"
expect "E conf-envvar: {env.*} in an imported .conf" 1 "docker/edge/extra.conf:2: environment placeholder {env.*}"
base
put docker/edge/plain.conf "respond "$'\xc2\xa0'"x${NL}"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - ./docker/edge/plain.conf:/etc/caddy/plain.conf:ro"
expect "non-ASCII in a mounted file with any name" 1 "only printable ASCII"
base
put docker/edge/e.conf "$UNSAFE"
subst "$HC" '    command: ["caddy", "run", "--config", "/etc/caddy/https/Caddyfile", "--adapter", "caddyfile"]' '    command: ["\u0063addy", "run", "--config", "/srv/e.conf", "--adapter", "caddyfile"]'
subst "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/srv/attacker:ro${NL}      - ./docker/edge/e.conf:/srv/e.conf:ro"
expect "E yaml-escape-cmd: \\u0063addy in a Compose command" 1 "backslash in a Compose file"
base
put docker/edge/e.conf "$UNSAFE"
subst "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/srv/attacker:ro${NL}"'      - "./docker/edge/e.conf:/etc/\u0063addy/Caddyfile:ro"'
expect "E yaml-escape-mount: \\u0063addy in a Compose mount target" 1 "backslash in a Compose file"
base
put docker/edge/e.conf "$UNSAFE"
subst "$DF" "USER 65534:65534" "RUN ln -s /usr/bin/cadd? /usr/local/bin/edge${NL}USER 65534:65534"
subst "$HC" '    command: ["caddy", "run", "--config", "/etc/caddy/https/Caddyfile", "--adapter", "caddyfile"]' '    command: ["edge", "run", "--config", "/srv/e.conf", "--adapter", "caddyfile"]'
subst "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/srv/attacker:ro${NL}      - ./docker/edge/e.conf:/srv/e.conf:ro"
expect "E alias-binary: RUN ln of the binary in an edge stage" 1 "RUN in an edge runtime stage may only be"
base
put docker/edge/e.conf "$UNSAFE"
subst "$HC" '    command: ["caddy", "run", "--config", "/etc/caddy/https/Caddyfile", "--adapter", "caddyfile"]' '    command: ["edge", "run", "--config", "/srv/e.conf", "--adapter", "caddyfile"]'
expect "E alias-binary: another executable in the edge service command" 1 "command of the edge service edge must be exactly"
bad "E caddyfile-name-elsewhere: sh -c 'exec caddy run ... --resume' as the edge command" "command of the edge service edge must be exactly" "$HC" '    command: ["caddy", "run", "--config", "/etc/caddy/https/Caddyfile", "--adapter", "caddyfile"]' '    command: ["sh", "-c", "exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile --resume"]'
bad "E json-config-noadapter: caddy run --config /srv/edge.cfg" "command of the edge service edge must be exactly" "$HC" '    command: ["caddy", "run", "--config", "/etc/caddy/https/Caddyfile", "--adapter", "caddyfile"]' '    command: ["caddy", "run", "--config", "/srv/edge.cfg"]'

# --- Edge services in Compose -----------------------------------------------------------
base
subst compose.yaml "      target: dev" "      target: dev${NL}    entrypoint: [\"/usr/bin/caddy\"]"
expect "entrypoint in the edge service (compose.yaml)" 1 "entrypoint of the edge service edge"
base
subst compose.prodlike.yaml "    ports: !reset []" "    ports: !reset []${NL}    command: [\"edge\", \"run\"]"
expect "command in a build-target override of the edge (compose.prodlike.yaml)" 1 "command of the edge service edge must be exactly"
base
subst compose.test.yaml "    ports: !reset []" "    ports: !reset []${NL}    entrypoint: [\"sh\", \"-c\"]"
expect "entrypoint in a plain override of the edge (compose.test.yaml)" 1 "entrypoint of the edge service edge"
base
subst compose.yaml "x-hardening: &hardening" "x-hardening: &hardening${NL}  command: [\"edge\", \"run\"]"
expect "command merged into the edge from an x- anchor" 1 "command of the edge service edge must be exactly"
base
subst compose.yaml "      target: dev" "      target: dev${NL}    extends:${NL}      file: other.yaml"
expect "extends in the edge service" 1 "extends in the edge service edge is not supported"
base
put compose.extra.yaml "services:${NL}  proxy:${NL}    image: caddy:2.11.7-alpine${NL}    command: [\"caddy\", \"run\", \"--resume\"]${NL}"
expect "another service running a caddy image" 1 "command of the edge service proxy must be exactly"
base
put compose.extra.yaml "services:${NL}  edge2:${NL}    build:${NL}      context: .${NL}      dockerfile: docker/edge/Dockerfile${NL}    entrypoint: [\"sh\"]${NL}"
expect "another service building the edge Dockerfile" 1 "entrypoint of the edge service edge2"
bad "Compose mount over /etc" "mount over a directory that holds /etc/caddy or the Caddy binary" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/etc:ro"
bad "Compose mount over /usr/bin/caddy" "mount over a directory that holds /etc/caddy or the Caddy binary" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/usr/bin/caddy:ro"
bad "Compose mount over / (quoted)" "mount over a directory that holds /etc/caddy or the Caddy binary" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - \"./tests/app/https/attacker:/:ro\""
bad "backslash anywhere in a Compose file" "backslash in a Compose file" compose.yaml "    read_only: true" "    read_only: \"tr\\x75e\""

# --- Edge runtime stages of the Dockerfile ----------------------------------------------
bad "RUN cp of the binary in an edge stage" "RUN in an edge runtime stage may only be" "$DF" "USER 65534:65534" "RUN cp /usr/bin/caddy /usr/local/bin/edge${NL}USER 65534:65534"
bad "RUN in a stage built on caddy-base (prod)" "RUN in an edge runtime stage may only be" "$DF" "COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile" "COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile${NL}RUN mv /usr/bin/caddy /usr/bin/edge"
base
printf 'FROM prod AS extra\nRUN ln -s /usr/bin/caddy /usr/local/bin/edge\n' >>"$repo/$DF"
expect "RUN in a stage built on prod without files of its own" 1 "RUN in an edge runtime stage may only be"
bad "apk add with a shell operator" "no shell operators" "$DF" "'libcurl>=8.23.0-r0'" "'libcurl>=8.23.0-r0' && ln -s /usr/bin/caddy /bin/e"
bad "COPY of the binary under another name" "may place the binary or anything in a bin directory" "$DF" "COPY --from=caddy-build /out/caddy /usr/bin/caddy" "COPY --from=caddy-build /out/caddy /usr/local/bin/edge"
bad "COPY of the binary outside a bin directory" "only 'COPY --from=<stage> <path>/caddy /usr/bin/caddy'" "$DF" "COPY --from=caddy-build /out/caddy /usr/bin/caddy" "COPY --from=caddy-build /out/caddy /usr/bin/caddy${NL}COPY --from=caddy-build /out/caddy /srv/edge"
bad "COPY of another file into a bin directory" "may place the binary or anything in a bin directory" "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}COPY docker/edge/no-gate/README.md /usr/local/bin/caddy-wrapper"
bad "ENV PATH in an edge stage" "ENV changing PATH or SHELL" "$DF" "USER 65534:65534" "ENV PATH=/srv/bin:/usr/bin${NL}USER 65534:65534"
bad "SHELL in an edge stage" "SHELL in an edge runtime stage" "$DF" "USER 65534:65534" "SHELL [\"/bin/sh\", \"-c\"]${NL}USER 65534:65534"
base
subst "$DF" "RUN npm run build" "RUN npm run build && cp /app/dist/index.html /tmp/x"
expect "RUN in a non-edge stage (spa-build) is not restricted" 0

# --- Re-audit (FCRM-SEC-042 E, HIGH-R1 and LOW-R1) ----------------------------------------
base
put docker/edge/launcher "#!/bin/sh${NL}exec /usr/bin/caddy run --config /srv/e.conf --adapter caddyfile${NL}"
subst "$DF" "USER 65534:65534" "WORKDIR /usr/local/bin${NL}COPY --chmod=755 docker/edge/launcher ./caddy${NL}WORKDIR /${NL}USER 65534:65534"
expect "E workdir-dest: WORKDIR in an edge stage" 1 "WORKDIR in an edge runtime stage"
base
put docker/edge/launcher "#!/bin/sh${NL}exec /usr/bin/caddy run --config /srv/e.conf --adapter caddyfile${NL}"
subst "$DF" "USER 65534:65534" "COPY --chmod=755 docker/edge/launcher ./caddy${NL}USER 65534:65534"
expect "relative COPY destination in an edge stage" 1 "needs an absolute literal destination"
base
put docker/edge/launcher "#!/bin/sh${NL}exec /usr/bin/caddy run --config /srv/e.conf --adapter caddyfile${NL}"
subst "$DF" "USER 65534:65534" "ARG D=/usr/local/bin${NL}COPY --chmod=755 docker/edge/launcher \${D}/caddy${NL}USER 65534:65534"
expect "E arg-dest: ARG-built COPY destination" 1 "needs an absolute literal destination"
bad "COPY to /etc//caddy/Caddyfile (non-canonical)" "needs an absolute literal destination" "$DF" "COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile" "COPY docker/edge/Caddyfile.prod /etc/caddy/Caddyfile${NL}COPY docker/edge/no-gate/README.md /etc//caddy/Caddyfile"
bad "ONBUILD in an edge stage" "ONBUILD in an edge runtime stage" "$DF" "USER 65534:65534" "ONBUILD RUN true${NL}USER 65534:65534"
bad "E long-mount-bin: long-syntax mount over /usr/local/bin" "long-syntax mount over" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - type: bind${NL}        source: ./tests/app/https/attacker${NL}        target: /usr/local/bin"
bad "long-syntax mount over /etc" "long-syntax mount over" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - type: bind${NL}        source: ./tests/app/https/attacker${NL}        target: /etc"
bad "short mount target /usr//bin (non-canonical)" "canonical absolute path" "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - ./tests/app/https/attacker:/usr//bin:ro"
bad "E quoted-key-launcher: quoted \"entrypoint\" key" "quoted key in a Compose file" "$HC" "    command: [" "    \"entrypoint\": [\"/srv/l/launch\"]${NL}    command: ["
bad "quoted key in single quotes" "quoted key in a Compose file" "$HC" "    command: [" "    'entrypoint': ['/bin/sh']${NL}    command: ["
base
put compose.override.yaml "services:${NL}  edge: {entrypoint: [\"/bin/sh\", \"-c\", \"exec /usr/bin/caddy run --resume\"]}${NL}"
expect "E flow-service: edge service as a flow mapping" 1 "flow mapping in a Compose file"
base
put compose.extra.yaml "services:${NL}  edge2:${NL}    build:${NL}      context: .${NL}      dockerfile: docker//edge/Dockerfile${NL}    entrypoint: [\"sh\"]${NL}"
expect "E dslash-dockerfile: docker//edge/Dockerfile (block style)" 1 "path with //, /./ or .. in a Compose file"
base
put compose.extra.yaml "services:${NL}  edge2:${NL}    build: {context: ., dockerfile: docker/edge/Dockerfile}${NL}"
expect "build as a flow mapping" 1 "flow mapping in a Compose file"
base
mkdir -p "$repo/docker/edge2"
printf '%s\n' "# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e" "FROM caddy:2.11.7-alpine" "USER 65534:65534" >"$repo/docker/edge2/Dockerfile"
git -C "$repo" add -f docker/edge2/Dockerfile || exit 2
put compose.extra.yaml "services:${NL}  proxy:${NL}    build:${NL}      context: .${NL}      dockerfile: docker/edge2/Dockerfile${NL}    command: [\"edge\", \"run\"]${NL}"
expect "service building another Dockerfile with a caddy stage" 1 "command of the edge service proxy must be exactly"
base
put compose.extra.yaml "services:${NL}  proxy:${NL}    build:${NL}      context: docker/edge${NL}      dockerfile: Dockerfile${NL}    command: [\"edge\", \"run\"]${NL}"
expect "service building an untracked or context-relative Dockerfile is treated as edge" 1 "command of the edge service proxy must be exactly"
base
subst compose.yaml "    networks: [front, back]" "    networks: [front, back]${NL}    entrypoint: [\"sh\"]"
expect "HIGH-R1: <<: anchor merge resolves (edge with merged hardening)" 1 "entrypoint of the edge service edge"

# --- SEC-042M final audit (M-1, M-2, L-1) ----------------------------------------------
base
put docker/edge/evil "x${NL}"
subst compose.yaml "x-hardening: &hardening" "x-etc: &etcmount \"./docker/edge/evil:/etc:ro\"${NL}${NL}x-hardening: &hardening"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - *etcmount"
expect "M B1: YAML alias mount over /etc" 1 "YAML anchor in a Compose file"
base
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - *etcmount"
expect "YAML alias as a list item" 1 "YAML alias in a Compose file"
base
put docker/edge/evil "x${NL}"
subst compose.yaml "$EDGE_VOL" "$EDGE_VOL${NL}      - ./docker/edge/evil:\${EDGE_ETC:-/etc}:ro"
expect "M B2: interpolated short mount target \${X:-/etc}" 1 "interpolation in a Compose file"
base
subst "$HC" "      - ./tests/app/https/attacker:/srv/attacker:ro" "      - type: bind${NL}        source: ./tests/app/https/attacker${NL}        target: \${B:-/usr/bin}"
expect "M B3: long-syntax target \${B:-/usr/bin}" 1 "interpolation in a Compose file"
base
subst compose.yaml "x-hardening: &hardening" "x-ep: &ep${NL}  entrypoint: [\"sh\", \"-c\", \"exec cadd\${Y:-y} run --resume\"]${NL}${NL}x-hardening: &hardening"
subst compose.yaml "    <<: *hardening" "    <<: [*hardening, *ep]"
expect "M B15: <<: with a list of aliases" 1 "YAML alias in a Compose file"
base
subst compose.yaml "x-hardening: &hardening" "x-ep: &ep${NL}  entrypoint: [\"sh\", \"-c\", \"exec cadd\${Y:-y} run --resume\"]${NL}${NL}x-hardening: &hardening"
expect "M B15: interpolation in an x- anchor's entrypoint" 1 "interpolation in a Compose file"
base
put compose.extra.yaml "x-img: &edgeimg docker.io/library/cadd\${Y:-y}:2.11.7-alpine${NL}services:${NL}  side:${NL}    image: *edgeimg${NL}    configs:${NL}      - source: sidecfg${NL}        target: \${C:-/etc}/cadd\${Y:-y}/Caddyfile${NL}configs:${NL}  sidecfg:${NL}    content: |${NL}      {${NL}        admin 0.0.0.0:2019${NL}      }${NL}      :2015 {${NL}        acme_server${NL}      }${NL}"
expect "M B9: aliased and interpolated caddy image with inline configs" 1 "Compose configs is not supported"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: *edgeimg${NL}"
expect "alias as an image value" 1 "YAML alias in a Compose file"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: docker.io/library/cadd\${Y:-y}:2.11.7-alpine${NL}"
expect "interpolated image" 1 "interpolation in a Compose file"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: busybox${NL}    command: [\"sh\", \"-c\", \"\$CMD\"]${NL}"
expect "interpolation without braces in a command" 1 "interpolation in a Compose file"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: busybox${NL}    secrets: [s]${NL}secrets:${NL}  s:${NL}    content: \"acme_server\"${NL}"
expect "inline secret content" 1 "Compose content is not supported"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: busybox${NL}secrets:${NL}  s:${NL}    environment: EVIL${NL}"
expect "secret from an environment variable" 1 "Compose environment is not supported"
base
put compose.extra.yaml "services:${NL}  side:${NL}    image: busybox${NL}secrets:${NL}  s:${NL}    file: \${D:-/x}/s${NL}"
expect "secret file with interpolation (the form the repository uses) is accepted" 0
base
put docker/edge/side.txt "acme_server${NL}"
put compose.extra.yaml "services:${NL}  side2:${NL}    build:${NL}      context: .${NL}      dockerfile_inline: |${NL}        FROM docker.io/library/cadd\${Y:-y}:2.11.7-alpine${NL}        WORKDIR /etc${NL}        COPY docker/edge/side.txt cadd\${Y:-y}/Caddyfile${NL}"
expect "M B10: build.dockerfile_inline" 1 "Compose dockerfile_inline is not supported"
bad "YAML tag other than !reset and !override" "YAML tag in a Compose file" compose.prodlike.yaml "    ports: !reset []" "    ports: !!seq []"
bad "tab in a Compose file" "tab in a Compose file" compose.prodlike.yaml "    ports: !reset []" "    ports:${TAB}!reset []"
bad "YAML document marker" "YAML document marker" compose.prodlike.yaml "services:" "---${NL}services:"
bad "anchor on a service key" "YAML anchor in a Compose file" compose.yaml "  edge:" "  edge: &edge"
base
put docker/edge/e.conf "$UNSAFE"
subst "$DF" "# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e" "# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e${NL}# escape=\`"
subst "$DF" "COPY --from=caddy-build /out/caddy /usr/bin/caddy" "COPY --from=caddy-build /out/caddy /usr/bin/caddy${NL}ENV HIDE=1\\${NL}RUN ln -s /usr/bin/caddy /usr/local/bin/edge && cd /etc && printf acme_server > caddy/x"
expect "M B6: # escape=\` parser directive hides a RUN" 1 "Dockerfile parser directive other than syntax="
bad "# check= parser directive" "Dockerfile parser directive other than syntax=" "$DF" "# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e" "# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e${NL}#  ESCAPE = \`"
base
put docker/edge/conf.tar "x"
subst "$DF" "COPY docker/edge/common.caddy /etc/caddy/common.caddy" "COPY docker/edge/common.caddy /etc/caddy/common.caddy${NL}ADD docker/edge/conf.tar /etc/"
expect "M L-1 B4: ADD of an archive to /etc/ in an edge stage" 1 "ADD in an edge runtime stage"
bad "M L-1 B5: COPY --from to /etc/ in an edge stage" "outside /etc/caddy/<file>, /usr/bin/caddy and /srv/<path>" "$DF" "COPY --from=spa-build /app/dist /srv/www" "COPY --from=spa-build /app/dist /srv/www${NL}COPY --from=spa-build /gen/ /etc/"
bad "COPY to / in an edge stage" "outside /etc/caddy/<file>, /usr/bin/caddy and /srv/<path>" "$DF" "COPY --from=spa-build /app/dist /srv/www" "COPY --from=spa-build /app/dist /"
bad "COPY to /usr/local/lib in an edge stage" "outside /etc/caddy/<file>, /usr/bin/caddy and /srv/<path>" "$DF" "COPY --from=spa-build /app/dist /srv/www" "COPY --from=spa-build /app/dist /usr/local/lib/x"
base
subst "$DF" "COPY --from=spa-build /app/dist /srv/www" "COPY --from=spa-build /app/dist /srv/www${NL}COPY --from=spa-build /app/dist/index.html /srv/extra/index.html"
expect "COPY below /srv in an edge stage is accepted" 0

# --- Globs that match the binary's name ---------------------------------------------------
base
put tests/app/extra.sh "#!/bin/sh${NL}docker run --rm img sh -c 'cp /usr/bin/cadd? /tmp/e && /tmp/e run --resume'${NL}"
expect "cp /usr/bin/cadd? in a script" 1 "glob that matches the Caddy binary's name"
base
put tests/app/extra.sh "#!/bin/sh${NL}ls /usr/bin/c*dy${NL}"
expect "c*dy glob in a script" 1 "glob that matches the Caddy binary's name"
base
put tests/app/extra.sh "#!/bin/sh${NL}rm -f /tmp/build/*.log${NL}case \$x in *\" \$y \"*) ;; esac${NL}"
expect "ordinary globs are accepted" 0
# --- Adapted JSON (scripts/ci/edge-adapted-config.jq) ---------------------------------------
SAFE='{"admin":{"disabled":true,"config":{"persist":false}},"logging":{"logs":{"default":{}}},"apps":{"http":{"servers":{"srv0":{"listen":[":8080"],"routes":[{"handle":[{"handler":"file_server"}]}],"automatic_https":{"disable":true}}}}}}'
# adapted_case <name> <expect-violation-substring or ''> <jq expression applied to SAFE>
adapted_case() {
  local name=$1 want=$2 out rc
  printf '%s' "$SAFE" | jq "$3" >"$work/adapted.json" || exit 2
  out=$(jq -r -f "$adapted" "$work/adapted.json" 2>&1)
  rc=$?
  if { [ -z "$want" ] && [ "$rc" -eq 0 ] && [ -z "$out" ]; } ||
    { [ -n "$want" ] && [ -n "$out" ] && printf '%s\n' "$out" | grep -qF -- "$want"; }; then
    pass=$((pass + 1))
    printf 'PASS  %-74s\n' "adapted: $name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-74s want=%s\n' "adapted: $name" "${want:-no violation}"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
}
if ! command -v jq >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "FAIL  jq is required for the adapted-config cases"
else
  adapted_case "safe configuration" "" '.'
  adapted_case "safe HTTPS test edge (certificates from files)" "" '.apps.tls = {"certificates":{"load_files":[{"certificate":"/c","key":"/k"}]}}'
  adapted_case "admin enabled" "admin.disabled is not true" 'del(.admin.disabled)'
  adapted_case "admin with a listen address" "admin has other settings: listen" '.admin.listen = "localhost:2019"'
  adapted_case "admin config load" "admin.config has other settings" '.admin.config.load = {"module":"http"}'
  adapted_case "persist_config on" "admin.config.persist is not false" '.admin.config.persist = true'
  adapted_case "persist_config missing" "admin.config.persist is not false" 'del(.admin.config)'
  adapted_case "pki app" "apps.pki is configured" '.apps.pki = {"certificate_authorities":{"local":{}}}'
  adapted_case "other app" "apps other than http and tls: layer4" '.apps.layer4 = {}'
  adapted_case "tls automation with an internal issuer" "apps.tls.automation is configured (issuer modules: internal)" '.apps.tls = {"automation":{"policies":[{"issuers":[{"module":"internal"}]}]}}'
  adapted_case "tls automation with acme and zerossl issuers" "issuer modules found: acme, zerossl" '.apps.tls = {"automation":{"policies":[{"issuers":[{"module":"acme"},{"module":"zerossl"}]}]}}'
  adapted_case "tls other than certificates" "apps.tls has settings other than certificates" '.apps.tls = {"session_tickets":{}}'
  adapted_case "certificates other than load_files" "apps.tls.certificates other than load_files" '.apps.tls = {"certificates":{"automate":["x"]}}'
  adapted_case "acme_server handler, nested in a subroute" "acme_server handler found (1x)" '.apps.http.servers.srv0.routes[0].handle = [{"handler":"subroute","routes":[{"handle":[{"handler":"acme_server"}]}]}]'
  adapted_case "issuer key anywhere" "certificate issuance settings found: issuers" '.apps.http.servers.srv0.x = {"issuers":[]}'
  adapted_case "on_demand anywhere" "certificate issuance settings found: on_demand" '.apps.http.servers.srv0.tls_connection_policies = [{"on_demand":true}]'
  adapted_case "automatic HTTPS on" "automatic_https.disable is not true" 'del(.apps.http.servers.srv0.automatic_https)'
  adapted_case "second server with automatic HTTPS" "servers.srv1.automatic_https.disable is not true" '.apps.http.servers.srv1 = {"listen":[":8443"]}'
  adapted_case "no servers" "no apps.http.servers" '.apps.http.servers = {}'
  adapted_case "storage setting" "top-level settings other than admin, apps and logging: storage" '.storage = {"module":"file_system"}'
  adapted_case "not an object" "not a JSON object" '[.]'
fi

# Output safety: crafted names and values stay on escaped, indented lines.
base
put "docker/edge/a${NL}::error::x.caddy" "::warning::x${NL}"
"$guard" "$repo" >"$work/out" 2>&1
if grep -q '^::' "$work/out"; then
  fail=$((fail + 1))
  printf 'FAIL  %-74s\n' "crafted path and value printed on escaped lines"
  sed 's/^/      | /' "$work/out"
else
  pass=$((pass + 1))
  printf 'PASS  %-74s\n' "crafted path and value printed on escaped lines"
fi

echo
echo "TOTAL $((pass + fail)) passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
