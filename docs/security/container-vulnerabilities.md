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
- A control scan of the unmodified PostgreSQL base image (with its `gosu`)
  must fail; it proves the gate is not passing vacuously.
- Development-image findings are reviewed with every dependency update; they
  never ship in a runtime image.

## Triage of the FCRM-FND-004V findings

Findings of Trivy 0.67.2 (HIGH and CRITICAL), before and after this
remediation.

### Edge: Caddy 2.11.4 binary (runtime)

Caddy 2.11.4 is the newest release. Its released binary was built with Go
1.26.3 and older modules; the official builder image ships Go 1.26.8. Several
findings are reachable over plain HTTP in this configuration (the production
edge serves files, so `Range` and URL path handling are exposed), so they
were **not** accepted on the grounds of the loopback binding.

**Remediation:** the edge image builds Caddy 2.11.4 from the upstream module
(`docker/edge/caddy/`, `go.mod` and `go.sum` committed) with
`golang:1.26.10-alpine3.24@sha256:9ce231b28998b32e116927c61aa5c406183061d4f3f2d61b292c88e7f6bdf7ca`
and these module versions; `caddy version` still reports `v2.11.4`. Result:
**0 HIGH/CRITICAL** (was 24).

| CVE | Package | Installed → built | Fixed in | Reachable here |
|---|---|---|---|---|
| CVE-2026-78667 | Go stdlib `net/http` (Range headers DoS) | 1.26.3 → 1.26.10 | 1.26.9 | yes: `file_server` in the production edge |
| CVE-2026-78669 | stdlib / `golang.org/x/net` http2 DoS | 1.26.3 / 0.55.0 → 1.26.10 / 0.60.0 | 1.26.9 / 0.60.0 | HTTP/2 only over TLS or h2c (both off) |
| CVE-2026-56860 | stdlib `net/url` path resolution DoS | 1.26.3 → 1.26.10 | 1.26.6 | yes: request URLs |
| CVE-2026-42504 | stdlib `mime` header DoS | 1.26.3 → 1.26.10 | 1.26.4 | possible: request parsing |
| CVE-2026-56853 | stdlib `net/http` unencrypted HTTP/2 DoS | 1.26.3 → 1.26.10 | 1.26.6 | h2c is off |
| CVE-2026-111943, CVE-2026-27145, CVE-2026-33818, CVE-2026-56862, CVE-2026-97031 | stdlib `crypto/x509`, `encoding/asn1`, `crypto/tls` | 1.26.3 → 1.26.10 | ≤ 1.26.10 | no TLS in this configuration |
| CVE-2026-39821, CVE-2026-39822, CVE-2026-46600, CVE-2026-56858, CVE-2026-56859 | stdlib `idna`, `os.Root`, `dnsmessage`, `html/template`, `encoding/xml` | 1.26.3 → 1.26.10 | ≤ 1.26.6 | not on the request path (fixed regardless) |
| CVE-2026-63209 | `github.com/klauspost/compress` | 1.18.6 → 1.18.7 | 1.18.7 | `encode` not configured (fixed regardless) |
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

### web: Node 24.20 (development and test only)

| CVE | Package | Status |
|---|---|---|
| CVE-2026-14456 | Alpine `libssl3`, `libcrypto3` 3.5.7 | fixed: upgraded to 3.5.8 with `apk upgrade` in the image (no newer Node image exists) |
| CVE-2026-102276, CVE-2026-102278, CVE-2026-14257, CVE-2026-69152 | `brace-expansion` 5.0.7 in npm's own bundled modules | open, reported; fixed in a later npm |
| CVE-2026-93748 | `http-cache-semantics` 4.2.0 (npm bundled) | open, no fix released |
| CVE-2026-69192 | `ip-address` 10.2.0 (npm bundled) | open, reported |
| CVE-2026-73566 | `tar` 7.5.19 (npm bundled) | open, reported |
| CVE-2026-19534 | `undici` 6.27.0 (npm bundled) | open, reported |

These packages belong to the npm CLI inside the Node base image
(`/usr/local/lib/node_modules/npm`), not to the project's dependencies
(`npm audit` of the project reports 0 vulnerabilities). They are used only
while installing dependencies during the image build and are not part of any
runtime image: the production edge contains only Caddy and the built SPA.
Owner decision pending: upgrade npm inside the image, or wait for a Node 24
release with a newer npm.

## Deferred hardening items

- `framework.trusted_hosts` is not configured: behind the edge, Symfony
  builds absolute URLs (for example the trailing-slash redirect of
  `/api/v1/system/status/`) from the request's `Host` header. Required before
  any deployment.
- Non-GET requests to `/health/live` and `/health/ready` receive Symfony's
  405 HTML error page (no details in production mode), not a JSON body.
