# Container vulnerabilities

How the images of the development stack are scanned, the policy for HIGH
and CRITICAL findings, and the triage of the findings of the FCRM-FND-004V
audit (F-03).

## Scanning

`tests/app/scan.sh` runs in the required `Dev environment` job. It builds
the images from the checkout, exports them with `docker save` and scans the
archives with Trivy 0.67.2
(`aquasec/trivy:0.67.2@sha256:e2b22eac59c02003d8749f5b8d9bd073b62e30fefaef5b7c8371204e0a4b0c08`).
Trivy gets no access to the Docker socket; its vulnerability database is
downloaded on every run.

| Image | Role | Policy |
|---|---|---|
| `docker/api/Dockerfile`, target `prod` | runtime (production-like) | **fails** on any HIGH or CRITICAL finding, fixed or not |
| `docker/edge/Dockerfile`, target `prod` | runtime (production-like) | **fails** on any HIGH or CRITICAL finding, fixed or not |
| `docker/db/Dockerfile` | runtime | **fails** on any HIGH or CRITICAL finding, fixed or not |
| `docker/api/Dockerfile`, target `dev` | development | reported |
| `docker/edge/Dockerfile`, target `dev` | development | reported |
| `docker/web/Dockerfile`, target `dev` | development and test tooling | reported |

- An exception for a runtime image is allowed only for one CVE that cannot be
  fixed yet, in `security/trivyignore.yaml`, with the evidence for the
  decision, the affected package at its exact version, the affected path and
  an expiry no more than 90 days ahead, and it is listed in
  [Exceptions](#exceptions). An exception does **not** fix the vulnerable
  code: it only stops the gate from failing on that one finding.
  `scripts/ci/guard-trivyignore.sh` (job `Repository guard`) enforces these
  rules on the file: one CVE or GHSA id per entry, no duplicate id and no
  key twice in one entry; the id is the one Trivy reports (the CVE when one
  exists: Trivy matches only that id, not its aliases), so an id listed as an
  alias in the first column of the [Exceptions](#exceptions) table, as in
  `CVE-2026-116587 (GHSA-mgcc-cww5-fp2q)`, is rejected; `purls` with at least one value, each of the form
  `pkg:<type>/<namespace>/<name>@<version>` with a lowercase type and an
  exact version (no purl without a version, which Trivy would apply to every
  version; no range, list or blank; no qualifiers, subpath or
  percent-encoding), and all purls of an entry naming the same package
  (type, namespace and name), so one entry cannot also cover another package
  such as a second major version of a Go module; no two entries naming the
  same package (purl without its version), whatever their ids, so one
  package is never excepted under a second id or alias; `paths` with at
  least one value (without `paths` Trivy would apply the entry at any path
  in every gated image); non-blank values without wildcards in both
  lists (Trivy matches `paths` as glob patterns, so `*`, `?`, `[`, `]`, `{`
  and `}` are all rejected); a non-empty `statement`; a valid `expired_at`
  after the day of the check and no more than 90 days after it; the id at
  the start of a row of the [Exceptions](#exceptions) table (a mention
  elsewhere in this document does not count); and only the documented form (any other
  section or key fails). Trivy stops applying an entry at 00:00 UTC of its
  `expired_at` day, and from that day on the guard fails too, so an expired
  exception breaks the `Repository guard` job until it is renewed after a
  new review or removed, instead of lingering in the file. Trivy applies an
  entry only to a finding that matches its id, one of its `paths` and one of
  its `purls`.
  So that the check reads the file exactly as Trivy's YAML parser does, it
  accepts printable ASCII only (YAML also breaks lines at CR, NEL and
  U+2028, which could hide an entry inside a comment; a NUL byte, which the
  shell would drop, is rejected too) and no backslash or
  inner double quote in a quoted value (an escape could add a wildcard or
  continue the statement over `expired_at`).
  Its regression suite is `scripts/ci/tests/guard-trivyignore.test.sh`.
- The gate scans (runtime images and the control scan) run with
  `--show-suppressed`, and the scan log lists every finding an exception
  suppressed as a `SUPPRESSED ignored <severity> <id> <package> <version>`
  line, so an excepted finding stays visible in CI. The option changes the
  output only, not the exit code. The development-image scans do not read
  the exception file and report the finding as usual.
- A control scan of the unmodified PostgreSQL base image (with its `gosu`)
  must fail; it proves the gate is not passing vacuously.
- Every scan must report the package sources expected for the image (Alpine
  packages; Composer for api; the Go binary `usr/bin/caddy` for edge; Node
  packages for web) with at least one package each. An image Trivy cannot
  read, or a scan that silently skips a layer of the application, fails
  instead of reporting "no findings".
- Development-image findings are reviewed with every dependency update; they
  never ship in a runtime image.

## Exceptions

Each entry of `security/trivyignore.yaml`. The finding is not fixed by the
exception; the vulnerable code is still in the image.

| Id | Package and path | Image | Fixed in | Reachable here | Expires | Decision |
|---|---|---|---|---|---|---|
| CVE-2026-116587 (GHSA-mgcc-cww5-fp2q) | `github.com/go-jose/go-jose/v3` v3.0.5 (`pkg:golang/github.com/go-jose/go-jose/v3@v3.0.5`) in `usr/bin/caddy` | edge (`prod`; `dev` is report-only) | none for v3 (v4 fixed in 4.1.6 and upgraded, not excepted) | no: no `acme_server`, `pki` app or `tls internal`, admin API off | 2026-11-30 (gate fails again from 00:00 UTC that day) | [ADR-021](../architecture/adr/ADR-021-edge-go-jose-v3-exception.md), **proposed, not accepted** ([details](#cve-2026-116587--ghsa-mgcc-cww5-fp2q-go-jose-edge)) |

## Triage of the FCRM-FND-004V findings

Findings of Trivy 0.67.2 (HIGH and CRITICAL), before and after this
remediation.

### Edge: Caddy binary (runtime)

The audit found the released Caddy 2.11.4 binary, built with Go 1.26.3 and
older modules. Several findings are reachable over plain HTTP in this
configuration (the production edge serves files, so `Range` and URL path
handling are exposed), so they were **not** accepted on the grounds of the
loopback binding.

The newest release is now Caddy 2.11.7 (2026-10-03; 2.11.6 added
security hardening such as idle timeouts and a 16 KiB request-header
limit). Its official image
(`caddy:2.11.7-alpine@sha256:d8542f48d34a9cf4e4c11a478865229840e87e4c96ea3f439101f31a5d35f75f`)
still ships a binary built with Go 1.26.8 and `golang.org/x/net` 0.59.0:
5 HIGH findings (CVE-2026-78667, CVE-2026-78669 in stdlib and x/net,
CVE-2026-97031, CVE-2026-111943).

**Remediation:** the edge image builds Caddy 2.11.7 from the upstream module
(`docker/edge/caddy/`, `go.mod` and `go.sum` committed, `go mod verify`
clean) with
`golang:1.26.10-alpine3.24@sha256:9ce231b28998b32e116927c61aa5c406183061d4f3f2d61b292c88e7f6bdf7ca`
and `golang.org/x/net` 0.60.0; the official 2.11.7 image provides the base
layer. `caddy version` reports `v2.11.7`. Result: **0 HIGH/CRITICAL** (was 24
with the 2.11.4 release binary, 5 with the 2.11.7 release binary). Since
2026-10-27 the binary has a `go-jose` finding again; see
[CVE-2026-116587](#cve-2026-116587--ghsa-mgcc-cww5-fp2q-go-jose-edge).

Triage of the 2.11.4 release binary:

| CVE | Package | Installed → built | Fixed in | Reachable here |
|---|---|---|---|---|
| CVE-2026-78667 | Go stdlib `net/http` (Range headers DoS) | 1.26.3 → 1.26.10 | 1.26.9 | yes: `file_server` in the production edge |
| CVE-2026-78669 | stdlib / `golang.org/x/net` http2 DoS | 1.26.3 / 0.55.0 → 1.26.10 / 0.60.0 | 1.26.9 / 0.60.0 | HTTP/2 only over TLS or h2c (both off) |
| CVE-2026-56860 | stdlib `net/url` path resolution DoS | 1.26.3 → 1.26.10 | 1.26.6 | yes: request URLs |
| CVE-2026-42504 | stdlib `mime` header DoS | 1.26.3 → 1.26.10 | 1.26.4 | possible: request parsing |
| CVE-2026-56853 | stdlib `net/http` unencrypted HTTP/2 DoS | 1.26.3 → 1.26.10 | 1.26.6 | h2c is off |
| CVE-2026-111943, CVE-2026-27145, CVE-2026-33818, CVE-2026-56862, CVE-2026-97031 | stdlib `crypto/x509`, `encoding/asn1`, `crypto/tls` | 1.26.3 → 1.26.10 | ≤ 1.26.10 | no TLS in this configuration |
| CVE-2026-39821, CVE-2026-39822, CVE-2026-46600, CVE-2026-56858, CVE-2026-56859 | stdlib `idna`, `os.Root`, `dnsmessage`, `html/template`, `encoding/xml` | 1.26.3 → 1.26.10 | ≤ 1.26.6 | not on the request path (fixed regardless) |
| CVE-2026-63209 | `github.com/klauspost/compress` | 1.18.6 → 1.20.1 | 1.18.7 | `encode` not configured (fixed regardless) |
| CVE-2026-56854 | `golang.org/x/crypto` (ssh) | 0.52.0 → 0.57.0 | 0.55.0 | not used (fixed regardless) |
| CVE-2026-46600 | `golang.org/x/net` (dnsmessage) | 0.55.0 → 0.60.0 | 0.56.0 | not on the request path |
| CVE-2026-56851, CVE-2026-56852 | `golang.org/x/text` | 0.37.0 → 0.42.0 | 0.41.0 / 0.39.0 | not on the request path |
| CVE-2026-84304, CVE-2026-84445, GHSA-hrxh-6v49-42gf | `google.golang.org/grpc` | 1.81.0 → 1.83.2 | 1.83.1 / 1.83.2 / 1.82.1 | gRPC not used (fixed regardless) |

### db: PostgreSQL 18.6 image (runtime)

All 26 findings (1 CRITICAL CVE-2025-68121, 25 HIGH including
CVE-2025-61726, CVE-2025-61729, CVE-2026-25679, CVE-2026-27145,
CVE-2026-32280, CVE-2026-32281, CVE-2026-32283, CVE-2026-33811,
CVE-2026-33814, CVE-2026-111943) are in `/usr/local/bin/gosu` (gosu 1.19,
Go 1.24.6). No PostgreSQL 18 image with a patched gosu exists (the newest,
`postgres:18.6-alpine3.24`, has the same binary).

`gosu` only drops from root to `postgres`; the container runs as `postgres`
from the start (`user: postgres`), and the entrypoint calls gosu only when it
runs as root. **Remediation:** `docker/db/Dockerfile` derives from
`postgres:18.6-alpine3.24@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873`
and removes the binary; tests ST-08 and ST-19 to ST-23 run against it.
Result: **0 HIGH/CRITICAL**.

### api: PHP 8.5.12 FPM (runtime and development)

**0 HIGH/CRITICAL** in Alpine packages and Composer dependencies, before and
after.

### web: Node 24.22.1 (development and test only)

Node 24.20.0 was replaced by the 24.22.1 security release
(`node:24.22.1-alpine3.24@sha256:6a1c190e17215d844926b0677f4bf87273ff7d5e54db06d3b5b5863ab0b09a3d`),
which also ships the fixed OpenSSL 3.5.8, so the `apk upgrade` of the
earlier remediation is no longer needed. The SPA build stage of the edge
image uses the same Node image; it is not part of the runtime image.

The HIGH findings were in the npm CLI bundled with Node
(`/usr/local/lib/node_modules/npm`), not in the project's dependencies
(`npm audit` of the project reports 0 vulnerabilities):

| CVE | Package (npm bundled) | Node 24.20.0 (npm 11.x) | Node 24.22.1 (npm 11.19.1) | npm 11.21.1 |
|---|---|---|---|---|
| CVE-2026-14456 | Alpine `libssl3`, `libcrypto3` | 3.5.7 | fixed (3.5.8) | fixed |
| CVE-2026-102276, CVE-2026-102278 | `brace-expansion` | 5.0.7 | 5.0.9, open | 5.0.12, fixed |
| CVE-2026-14257, CVE-2026-69152 | `brace-expansion` | 5.0.7 | fixed | fixed |
| CVE-2026-93748 | `http-cache-semantics` | 4.2.0, open | 4.2.0, open | 4.3.0, not reported |
| CVE-2026-69192 | `ip-address` | 10.2.0 | fixed | fixed |
| CVE-2026-73566 | `tar` | 7.5.19 | fixed | fixed |
| CVE-2026-19534 | `undici` | 6.27.0 | 6.28.0, open | 6.29.0, fixed |

**Remediation:** `docker/web/Dockerfile` replaces the bundled npm with npm
11.21.1, downloaded from the npm registry and verified against a pinned
SHA-256 (`dd77c48eb845f4856c2cdba347cfb52bd877a2655a1ea48ff0c4796e3df9dd7b`,
matching the registry's SHA-512 integrity); a wrong checksum fails the
build. The web image now has **0 HIGH/CRITICAL**; it stays report-only
because it is a development and test image.

## CVE-2026-111497: `brotli-libs` (runtime images)

Published after FND-010; found by the scan of PR #15 (run 40016420940), not
by a change of the project. The Alpine package `brotli-libs` 1.2.0 (HIGH)
was in all three runtime images through their pinned base images (PHP
8.5.12 FPM on Alpine 3.24, Caddy 2.11.7 on Alpine 3.23, PostgreSQL 18.6 on
Alpine 3.24); 1.2.1-r0 fixes it and is in the Alpine 3.23 and 3.24
repositories. No base image ships it yet, so `docker/api/Dockerfile`,
`docker/edge/Dockerfile` and `docker/db/Dockerfile` upgrade the package
(`apk add --upgrade 'brotli-libs>=1.2.1-r0'`; the build fails if that
version cannot be installed). Remove the upgrade when the pinned base
images include the fix. No exception was added.

## CVE-2026-92392: `curl` and `libcurl` (runtime images)

Published after the last green scan of `main` (run 40223497868,
2026-10-25); found by the scan of PR #38 (run 40383573386, 2026-10-26), not
by a change of the project. The Alpine packages `curl` and `libcurl`
8.22.0-r0 (HIGH) come from the pinned base images:

| Image | Base (Alpine) | Affected packages |
|---|---|---|
| api (`prod`, `dev`) | PHP 8.5.12 FPM (3.24.2) | `curl`, `libcurl` |
| edge (`prod`, `dev`) | Caddy 2.11.7 (3.23.6) | `curl`, `libcurl` |
| db | PostgreSQL 18.6 (3.24.2) | `libcurl` (no `curl` tool) |

8.23.0-r0 fixes it and is in the Alpine 3.23 and 3.24 `main` repositories
for x86_64 and aarch64 (built 2026-10-25). The current builds of the base
image tags were created on 2026-10-21, before the fix, so refreshing the
pinned digests would not help. `docker/api/Dockerfile` and
`docker/edge/Dockerfile` upgrade both packages
(`apk add --upgrade 'curl>=8.23.0-r0' 'libcurl>=8.23.0-r0'`),
`docker/db/Dockerfile` upgrades `libcurl` only, so no package is added to an
image; the build fails if the fixed version cannot be installed. The
project's own health checks do not use `curl` (they use `cgi-fcgi` and
`wget`), but the packages belong to the base images and are not removed.
Remove the upgrade when the pinned base images include the fix. No exception
was added.

## CVE-2026-116587 / GHSA-mgcc-cww5-fp2q: `go-jose` (edge)

Published by go-jose on 2026-10-14 and added to the GitHub advisory database
(HIGH) on 2026-10-27, after the last green scan of `main` (run 40407409241,
2026-10-26); found by the scan of PR #40 (run 40671261985, 2026-10-28), not
caused by a change of the project. Parsing a JWK with a crafted RSA key
costs excessive CPU (denial of service). The rebuilt Caddy binary
(`usr/bin/caddy`, edge `prod` and `dev`) contains both affected major
versions:

| Package | Installed | Fixed in | Status |
|---|---|---|---|
| `github.com/go-jose/go-jose/v4` | 4.1.5 | 4.1.6 | **fixed**: `docker/edge/caddy/go.mod` requires 4.1.6 |
| `github.com/go-jose/go-jose/v3` | 3.0.5 | none (no fixed v3 release) | **open** |

`go-jose/v3` comes from `modules/caddypki` → `github.com/smallstep/certificates/authority`
→ `go.step.sm/crypto/jose` (0.91.0; the newest, 0.91.1, still requires
v3). It cannot be removed by building Caddy without `modules/caddypki`:
`modules/caddytls` (internal issuer and CA pools) and
`caddyconfig/httpcaddyfile` import `caddypki` directly, and
`modules/caddyhttp` imports `caddytls`, so every Caddy build with the HTTP
app links it. A build from the `modules/standard` list without `caddypki`
and `caddypki/acmeserver` still contains `go-jose/v3` 3.0.5 (`go version -m`)
and only drops the `http.handlers.acme_server` module. Removing v3 needs
either a release of `go.step.sm/crypto` and `smallstep/certificates` on
go-jose v4, or a change to Caddy itself.

FlowCRM's configuration does not reach the vulnerable code: both
Caddyfiles disable automatic HTTPS (`auto_https off`), no configuration
defines a `pki` app, `tls internal` or `acme_server`, and the HTTPS test
edge (`tests/app/https`) loads its certificate from files
(`tls.certificates.load_files`). Only the `acme_server` handler passes
untrusted input (the JWS of an ACME request) to the vulnerable parser;
`tls internal` and the `pki` app parse only keys Caddy creates or loads
from its own configuration. With `admin off` the configuration cannot be
changed at run time.

**Exception (proposed, not accepted):** `security/trivyignore.yaml` excepts
this id for `go-jose/v3` v3.0.5 in `usr/bin/caddy` only, until 2026-11-30
(see [Exceptions](#exceptions); decision proposed in ADR-021). It does not
fix the vulnerable code: go-jose v3 3.0.5 stays in the edge binary, and the
exception only rests on the configuration above, which the edge
configuration guard is to enforce. Scope, verified with Trivy 0.67.2 and the
flags of `tests/app/scan.sh` (FCRM-SEC-042):

- The edge `prod` gate passes with the exception; the finding is listed as
  `SUPPRESSED ignored HIGH CVE-2026-116587 github.com/go-jose/go-jose/v3
  v3.0.5`, and the edge `dev` report scan still lists it as a HIGH finding.
- The same file does not cover go-jose v4: the edge `prod` image of `main`
  (v4 4.1.5) still fails the gate on the v4 finding.
- It does not cover another v3 version: a build with v3 3.0.4 fails the gate
  (CVE-2026-116587 and CVE-2026-34986 for 3.0.4).
- It suppresses nothing in the api, db and control scans; the control scan
  still fails.
- With an `expired_at` on or before the day of the scan, Trivy no longer
  applies the entry and the gate fails; the guard fails as well.

Review it again, at the latest at the expiry, on any of: a go-jose v3
release that fixes the CVE; `go.step.sm/crypto` or `smallstep/certificates`
moving to go-jose v4, or a Caddy release without v3; any change to
`docker/edge` or `tests/app/https`; a change of the advisory's severity or
a new advisory for go-jose v3; a deployment beyond the loopback binding; a
Trivy upgrade (the exception file format is experimental in Trivy).

### Edge configuration guard

The finding is acceptable only while no edge configuration runs the code
that parses untrusted JWS/JWK. Two checks enforce this. They catch
ordinary and accidental changes and the obfuscations listed below, not every
deliberate evasion (see "Known limits"):

- `scripts/ci/guard-edge-config.sh` (job `Repository guard`, regression
  suite `scripts/ci/tests/guard-edge-config.test.sh`) reads every tracked
  Caddy file (`Caddyfile*`, `*.caddyfile`, `*.caddy`) and every place that
  starts Caddy: the edge Dockerfile (its `COPY` into `/etc/caddy`; no `CMD`
  or `ENTRYPOINT`, so the pinned base image's
  `caddy run --config /etc/caddy/Caddyfile --adapter caddyfile` runs),
  Compose files (commands and read-only bind mounts into `/etc/caddy`, such
  as `tests/app/https/compose.https.yaml`), scripts, `bin/`, the Makefile
  and the workflows. It tokenizes and parses each configuration like Caddy
  2.11 does (comments, quotes, escaped newlines, snippets, imports and import
  globs, resolved against the files in the container) and rejects:
  - `acme_server`, `pki`, `internal`, `local_certs`, `acme`, `zerossl`,
    `issuer`, `cert_issuer`, `acme_ca`, `acme_ca_root`, `acme_dns`,
    `acme_eab`, `on_demand`, `on_demand_tls`, `skip_install_trust` and
    `get_certificate` (in any case, quoted or not) in every tracked Caddy
    file and in every file copied or mounted into `/etc/caddy`, whatever
    its name (an import glob can reach any of them), and `tls` in any form
    other than `tls <cert-file> <key-file>`;
  - a configuration Caddy starts with that does not have exactly one global
    options block, first, with exactly `admin off`, `auto_https off` and
    `persist_config off`; options other than these and `log`;
  - in the same files: `{$VAR}` (replaced in the raw text before parsing,
    even in a comment), `{env.*}` and non-ASCII text; snippet arguments and
    blocks, heredocs, named routes, and an import that does not resolve to
    a copied or mounted file or a snippet;
  - a `caddy` command other than `run`, `adapt`, `validate`, `version`,
    `list-modules` and `build-info`; `run`, `adapt` and `validate` without
    `--config <path the image or a mount provides> --adapter caddyfile`, or
    with `--resume`, `--watch`, `--envfile` or an unknown flag; `CADDY_ADMIN`
    anywhere; a glob in a command line that matches the binary's name
    (`cadd?`);
  - an edge service in Compose (it builds `docker/edge/Dockerfile`, runs a
    caddy image, directly or through a `<<: *anchor` merge, or overrides
    such a service) with an `entrypoint`, `extends`, or a `command` other
    than exactly
    `["caddy", "run", "--config", "/etc/caddy/<path>", "--adapter", "caddyfile"]`;
    a backslash anywhere in a Compose file (YAML escapes such as
    `\u0063addy` would hide a command or a path); a mount over `/`, `/etc`,
    `/usr` or a bin directory;
  - in the edge runtime stages of the Dockerfile (from the caddy image or a
    stage with files in `/etc/caddy`, and every stage built on them): a
    `RUN` other than a plain `apk add --no-cache <packages>`, a copy of the
    binary anywhere but `COPY --from=<stage> <path>/caddy /usr/bin/caddy`,
    anything else in a bin directory, and `ENV PATH` or `SHELL`, so the
    binary cannot be linked, copied or renamed;
  - a Caddy file that no start point uses, and a tracked JSON file that
    looks like a Caddy JSON configuration.
- `tests/app/scan.sh` (job `Dev environment`) runs `caddy adapt` with the
  built binary in the built edge `prod` and `dev` images and on the HTTPS
  test edge, checks the images' command and that they set no `CADDY_*`
  variable other than `CADDY_VERSION`, and checks the adapted JSON with
  `scripts/ci/edge-adapted-config.jq`: `admin.disabled` is true,
  `admin.config.persist` is false, there is no other admin setting, no
  `pki` app, no `tls.automation`, no issuer module (`acme`, `internal`,
  `zerossl`), no `acme_server` handler at any depth, and every HTTP server
  has `automatic_https.disable`. A control image with an unsafe
  configuration must be rejected.

Known limits. The guard reads Caddyfiles like Caddy does, but shell, YAML
and Dockerfile text only line by line, and some evasions remain open:
- commands and paths assembled at run time: shell variables, `eval`,
  `$(...)` in scripts, an `env_file:` that sets `CADDY_ADMIN` or a `{$VAR}`
  value, `docker cp` or `docker exec` with a variable command;
- `docker run --entrypoint <other>` in a script, outside Compose (only
  caddy command words and globs that match its name are checked there);
- Compose files are not merged as Compose merges them. Bind mounts count
  for every edge stage, and an override is recognised by its service name;
- a Caddy plugin added to `docker/edge/caddy/main.go`, or a package an
  `apk add` installs.

The adapted-config check in `tests/app/scan.sh` sees what the built images
contain and the one HTTPS test mount. It does not apply Compose mounts.
Changing a rule means reviewing the reason above.

## Deferred hardening items

- `framework.trusted_hosts` is not configured: behind the edge, Symfony
  builds absolute URLs (for example the trailing-slash redirect of
  `/api/v1/system/status/`) from the request's `Host` header. Required before
  any deployment.
- Non-GET requests to `/health/live` and `/health/ready` receive Symfony's
  405 HTML error page (no details in production mode), not a JSON body.
