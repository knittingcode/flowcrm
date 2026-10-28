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
  decision, the affected path and an expiry no more than 90 days ahead, and
  it is listed in the table below. There are currently **no exceptions**.
  `scripts/ci/guard-trivyignore.sh` (job `Repository guard`) enforces these
  rules on the file: one CVE or GHSA id per entry, no duplicate id and no
  key twice in one entry, `paths` or `purls` with non-blank values and without
  wildcards (Trivy matches `paths` as glob patterns, so `*`, `?`, `[`, `]`,
  `{` and `}` are all rejected), a non-empty `statement`, a valid `expired_at`
  no more than 90 days after the day of the check, the id mentioned in this
  document, and only the documented form (any other section or key fails).
  So that the check reads the file exactly as Trivy's YAML parser does, it
  accepts printable ASCII only (YAML also breaks lines at CR, NEL and
  U+2028, which could hide an entry inside a comment; a NUL byte, which the
  shell would drop, is rejected too) and no backslash or
  inner double quote in a quoted value (an escape could add a wildcard or
  continue the statement over `expired_at`).
  Its regression suite is `scripts/ci/tests/guard-trivyignore.test.sh`.
- A control scan of the unmodified PostgreSQL base image (with its `gosu`)
  must fail; it proves the gate is not passing vacuously.
- Every scan must report the package sources expected for the image (Alpine
  packages; Composer for api; the Go binary `usr/bin/caddy` for edge; Node
  packages for web) with at least one package each. An image Trivy cannot
  read, or a scan that silently skips a layer of the application, fails
  instead of reporting "no findings".
- Development-image findings are reviewed with every dependency update; they
  never ship in a runtime image.

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
with the 2.11.4 release binary, 5 with the 2.11.7 release binary).

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

## Deferred hardening items

- `framework.trusted_hosts` is not configured: behind the edge, Symfony
  builds absolute URLs (for example the trailing-slash redirect of
  `/api/v1/system/status/`) from the request's `Host` header. Required before
  any deployment.
- Non-GET requests to `/health/live` and `/health/ready` receive Symfony's
  405 HTML error page (no details in production mode), not a JSON body.
