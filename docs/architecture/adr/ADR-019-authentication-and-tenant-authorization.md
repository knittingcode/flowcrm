# ADR-019: Browser session authentication and tenant authorization

- **Status:** accepted for FCRM-FND-010B, amended by the FCRM-FND-010V security gate (the role matrix is provisional, see below)
- **Related:** FCRM-002 (REQ-001 to REQ-006, NFR-001, NFR-002, NFR-005 to NFR-007, NFR-012, TI-01 to TI-13, BR-32, BR-33, section H), FCRM-003 sections G, H and I, C-05 and C-07, ADR-004 (tenant enforcement), ADR-005 (authentication and sessions), ADR-006 (REST conventions), ADR-007 (no Redis), ADR-017 (edge routing), ADR-018 (database roles)
- **Design:** FCRM-FND-010A; details in [authentication](../authentication.md)

## Context

FlowCRM is a same-origin SPA behind one Caddy edge, without CORS. Sessions
are already stored in PostgreSQL (FND-008), the API runs as the
least-privileged role `flowcrm_app` (ADR-018), and the tenant tables carry
`organization_id` with composite foreign keys (FND-007). FCRM-003 decided
cookie sessions, a CSRF token with an Origin check, `login_throttling`, and
an organization taken from the path and checked against an active
membership on every request.

## Decision

1. **Session authentication with Symfony Security**, firewall `api`
   (`^/api`, lazy, stateful): `json_login` on `POST /api/v1/auth/login`, a
   session cookie that JavaScript cannot read, no JWT and no token in
   browser storage. Requests that do not need the user never read the
   session.
2. **Passwords:** Argon2id with libsodium, 19 MiB and 3 passes (above both
   OWASP baselines; Symfony's libsodium hasher requires at least 3 passes),
   upgraded at the next login when the parameters change. Kept after
   measuring under PHP-FPM's concurrency (FND-010V, see
   [authentication](../authentication.md#password-hashing)): with 8
   parallel logins on 1 CPU and 512 MB, 64 MiB was killed for lack of
   memory and 46 MiB took over a second at the 95th percentile, while
   19 MiB stayed under 0.5 s. 12 to 128 characters, no composition rules
   (NFR-001). Passwords appear in no log, argument or response; the console
   reads them from standard input.
3. **One failure answer:** 401 `invalid-credentials` for an unknown e-mail,
   a wrong password and a disabled account (checked after the password).
   An unknown e-mail costs one hash, like a known one.
4. **Session lifecycle:** a new session ID at every login (the previous row
   is deleted) and a new CSRF token; logout deletes the row. The session
   stores the user ID, a credentials fingerprint (crc32c of the hash and the
   time of the last password change, Symfony's supported mechanism) and the
   login time: no password hash, no e-mail address, no organization. A
   session ends on its next request when the user is disabled or gone, the
   password was changed anywhere else, or 8 hours passed since the login;
   the idle timeout stays 30 minutes.
5. **Request forgery:** before the firewall, every unsafe `/api` request
   needs an `application/json` body (415 otherwise), an `Origin` equal to
   the request's own origin (or, without `Origin`, a `Referer` of that
   origin; neither is a 403) and no cross-site `Sec-Fetch-Site`; a logged-in
   session must also send its token in `X-CSRF-Token`. Only login is exempt
   from the token. Problem type `csrf-invalid` (FCRM-003 section I).
6. **Login throttling** before the password is hashed, counting failures
   only: 5 per account and client IP and 50 per client IP per 15 minutes,
   100 per account per day (FND-010A values). The client IP is the one the
   edge passes over FastCGI as `REMOTE_ADDR` (the client's own address), and
   the scheme its `HTTPS` parameter; no proxy is trusted, so no forwarding
   header is ever read (FND-010V: `TRUSTED_PROXIES=REMOTE_ADDR` trusted the
   client itself, because over FastCGI `REMOTE_ADDR` is not the edge).
   State in `cache_items` with HMAC keys, serialised by PostgreSQL advisory
   locks on the cache connection (no new service, table or privilege).
   **Per-user API limit** (NFR-007, added by FND-010V): 600 requests per
   minute per logged-in user to the routes that require a login, then 429
   with `Retry-After`; keyed by the user ID and counted after the firewall,
   so anonymous traffic, refused forgeries and other users cannot use it up,
   and the public routes (login, logout, session probe, status) are not
   counted.
7. **Tenant authorization:** on every route with `{organizationId}` the
   current user's `ACTIVE` membership is read from the database, never
   cached and never taken from the session, the query, the body or a
   header. No membership, a removed one and an unknown organization are
   the same 404 (C-05). A tenant route must declare exactly one
   `TenantPermission`; without one it fails closed (500) and the route
   registry test fails. A voter decides with the static `RolePolicy`;
   organization roles are never Symfony roles. Object queries always filter
   by the organization.
8. **Status codes:** 401 before anything about organizations is looked up,
   and a 401 never starts or stores a session (the firewall's login
   redirect target is removed again, FND-010V);
   404 for anything outside the user's view; 403 for a member without the
   permission; 415, 422 (with `errors[]`), 429 (with `Retry-After`).
9. **Audit and logs:** successful sensitive actions (login, logout,
   password change, the operator's provisioning) go to `audit_events`
   without an IP address; failures go only to the security log, with HMAC
   pseudonyms instead of e-mail and IP addresses, so anonymous traffic
   cannot fill the immutable log. No sensitive change without its event: a
   login whose event cannot be written fails without a session; a password
   change or an operator change and its event are one transaction; a
   logout ends the session first and then fails (500) if its event cannot
   be written.
10. **Provisioning:** operator console commands only; no public
    registration and no HTTP route that administers organizations.
11. **Contract:** a committed OpenAPI 3.0.3 file (`backend/openapi.yaml`);
    every API test response is validated against it, and a test fails when
    routes and specification differ.

### Provisional role matrix

Only these permissions exist; everything else is denied. No role inherits
another's permissions.

| Permission | ADMIN | MANAGER | REP | Source |
|---|---|---|---|---|
| `organization.view` | yes | yes | yes | FCRM-002 section H [TASK] |
| `membership.list` (name, role) | yes | yes | yes | FCRM-002 section H [PROP] |
| `membership.view_email` | yes | yes | no | not specified in FCRM-002; provisional |

Tenant mutations and membership management are not part of FND-010B.

## Deviations, with reasons

| From | Decision here | Why |
|---|---|---|
| FCRM-003 I: login answers 204 | 200 with the session (user, memberships, CSRF token, expiry) | FND-010A contract; the SPA needs the token at once |
| FCRM-003 G layer 3: CSRF token from `/me` | also from `/auth/session` and the login | FND-010A; anonymous visitors can ask `/auth/session` without a 401 |
| FCRM-002 NFR-001: 12 to 128 characters | as specified (FND-010A had proposed 256) | FCRM-002 is the source of truth |
| FCRM-002 NFR-007: 5 failures per account, 30 per IP | 5 per account and IP, 50 per IP, 100 per account per day | FND-010B: FND-010A values; a 5-per-account limit across IPs would let anyone lock out any user |
| FCRM-002 BR-32: IP stored for authentication events | no IP address in the audit log | FND-010B privacy constraint |
| FCRM-003 I: OpenAPI generated by NelmioApiDocBundle | hand-written specification, validated by the tests | FND-010A decision; no production dependency |
| FCRM-003 H: SPA remembers the last organization in localStorage | nothing in browser storage; the organization is in the address | FND-010B: no client storage of security state |
| FCRM-003 S, FND-008: `organization:create` with a default pipeline | organization and first ADMIN only | pipeline creation belongs to the pipeline feature |
| FCRM-002 AC-28: new session ID on organization switch | no switch in the session: the organization is in the path | sessions carry no tenant (FCRM-003 G) |
| FND-010A: `Clear-Site-Data` on logout | not sent | it clears every cookie of the origin, including other local projects on 127.0.0.1 |
| FND-010A: bundled common-password list | length rules only | no vetted list with a compatible license chosen yet |
| FND-010A: HMAC fingerprint in the session | crc32c (Symfony's mechanism) plus the password-change time | the framework's supported comparison; not secret either way |

## Consequences

- Unsafe requests need the CSRF token, and requests of one session run one
  after another (FND-008 lock).
- The per-account limit can delay the owner during an attack on the account
  (100 failures per day); the limits are configuration
  (`config/services.yaml`).
- The hashing cost (about 20 ms for one login on the development hardware)
  is a deployment decision: measure it with `bin/benchmark-password-hashing`
  on the target hardware with PHP-FPM's `pm.max_children` as the
  concurrency, and plan `pm.max_children` x 41 MiB of memory for hashing.
- **TLS:** the edge must terminate TLS itself, as verified (PL-17 to PL-22),
  or trust the proxy that does (Caddy `trusted_proxies`). Behind an
  untrusted TLS proxy the API sees plain HTTP and refuses every unsafe
  request with 403 (fails closed, PL-20). The TLS site must also send HSTS
  (NFR-010); no deployment configuration exists yet.
- Every request of a logged-in user to a route that requires a login costs
  one rate-limit update in PostgreSQL (lock, read, write).
- Changing hash parameters ends the other sessions of a user at their next
  login (the fingerprint changes); the session that logs in stays valid.
- Sessions cannot be listed per user (the `sessions` table has no user
  column); a password change or disabling the user ends them all.
- Machine clients would need a separate, token-based firewall.

## Verification

- `backend/tests/Integration/Security/*` over the real PHP-FPM,
  PdoSessionHandler and PostgreSQL; every response checked against the
  OpenAPI file.
- `tests/app/backend.sh` BE-18: 48 negative controls, each removing one
  protection, must make their tests fail.
- `tests/app/stack.sh` ST-16 and ST-69 to ST-73 through the real edge,
  including spoofed `X-Forwarded-For`; `tests/app/prodlike.sh` PL-16 for the
  production cookie with curl, and PL-17 to PL-22 over HTTPS: the
  production edge configuration with TLS and a throwaway certificate, the
  `__Host-` cookie, login, API calls, logout and cross-site forgeries in a
  real browser (Chromium), spoofed forwarding headers, no CORS, and the
  client IP behind the TLS edge.

## Alternatives rejected

- **JWT or other bearer tokens:** no revocation without server state, and
  the token is readable by scripts (XSS).
- **Tokens in localStorage:** readable by any script on the page.
- **The organization in the session:** hidden state that makes cross-tab
  and IDOR mistakes likely, and stale roles (TI-04).
- **403 for foreign organizations:** confirms that an organization ID exists
  (C-05).
- **Doctrine SQL filters as the main control:** bypassed by DBAL and easy to
  switch off; Row-Level Security remains a separate decision (ADR-004,
  FND-016).
