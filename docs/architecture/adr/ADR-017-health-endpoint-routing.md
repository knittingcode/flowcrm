# ADR-017: Routing of the health endpoints at the edge

- **Status:** Accepted (FCRM-FND-004)
- **Amends:** FCRM-003 section G (edge control "Only `/api/*` reaches PHP")
- **Related:** FCRM-003 sections I and Q, ADR-006, ADR-009, ADR-010

## Context

The FCRM-003 architecture contains two statements that meet at the Caddy
edge:

1. Section G, enforcement chain, layer 1: *Only `/api/*` reaches PHP.*
2. Sections I and Q: the only global routes are `/auth/*`, `/me` and
   `/health/*`; the health endpoints are `/health/live` (process only) and
   `/health/ready` (`SELECT 1`, migrations current), used by the Compose
   health checks and by the `make up` verification (phase P5) **through the
   edge**.

If the edge forwarded only `/api/*`, `GET /health/ready` through the edge
would be answered by the SPA, and `make up` could never verify readiness.
Moving the endpoints under `/api` would change the approved paths.

## Decision

The edge forwards exactly these requests to Symfony (PHP-FPM):

| Path | Purpose |
|---|---|
| `/api` and `/api/*` | the application API (ADR-006) |
| `/health/live` | liveness: the PHP process answers; no dependency is touched |
| `/health/ready` | readiness: PostgreSQL answers `SELECT 1` and no migration is pending or unknown |

The decision is made on the **raw request URI** as the client sent it
(`{http.request.orig_uri}`), with two anchored, case-sensitive regular
expressions: `^/api(/[^?]*)?([?].*)?$` and `^/health/(live|ready)([?].*)?$`.
No other path reaches Symfony: `//api/…`, `/health//live`, `/health/live/`,
`/HEALTH/LIVE`, `/health%2Flive`, `/%61pi/…`, `/health/./live`, `/index.php`,
`/_error/*`, `/bundles/*` and every other path are answered by the frontend
(the Vite dev server in development, the built SPA in production-like
images). The rule is in `docker/edge/common.caddy` and applies to both edge
configurations.

Caddy's `path` and `path_regexp` matchers are **not** used for this rule:
they match a cleaned path (repeated slashes merged, dot segments resolved,
percent-encoding decoded), and `path` also ignores case. With them, the
variants above reached Symfony and received Symfony's error pages
(FCRM-FND-004V finding F-02). Raw paths that start with `/api/` stay inside
the API: Symfony answers them, unknown ones as an RFC 9457 problem document.

The health responses contain a single status word (`{"status":"live"}`,
`{"status":"ready"}` or `{"status":"not-ready"}`), are sent with
`Cache-Control: no-store`, and never include error messages, connection
details or versions. The reason for a failed readiness check is logged by the
API (stderr) only.

## Consequences

- `make up` verifies `GET /health/ready` through the published edge before it
  saves the port; a pending migration or an unreachable database makes it fail
  with exit 2 and keeps the previously verified state.
- The Compose health check of the API calls `/health/live` directly over
  FastCGI; the edge's health check calls `/health/live` through the edge.
- The exception is limited to two fixed, read-only, unauthenticated GET/HEAD
  endpoints without business data. Any further non-`/api` route needs its own
  decision.
- The boundary is tested with raw request paths (`curl --path-as-is`):
  `tests/app/stack.sh` (ST-09, ST-10) and `tests/app/prodlike.sh` (PL-08,
  PL-10, PL-12, PL-13) send every variant above and identify the serving layer
  by the `X-Request-Id` response header, which only Symfony sets.
- A non-GET request to a health path reaches Symfony and is answered with
  405 (an HTML error page; without details when `APP_DEBUG=0`). This is
  accepted: the method does not widen the set of reachable endpoints.

## Alternatives considered

- **Health endpoints under `/api`** (for example `/api/health/ready`): keeps
  the literal edge rule but changes the approved endpoint paths of sections I
  and Q.
- **A separate, unpublished health port on the edge**: the readiness check of
  `make up` must go through the same published port the developer uses, so it
  would no longer prove the actual route.
