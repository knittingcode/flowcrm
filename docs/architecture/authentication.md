# Authentication and tenant authorization

How users log in, how sessions are protected and how access to an
organization is decided (FCRM-FND-010B). The decisions and their reasons are
in [ADR-019](adr/ADR-019-authentication-and-tenant-authorization.md);
sessions and their storage in [sessions and cache](sessions-and-cache.md).

## Endpoints

All under the edge's single origin; the contract is
[`backend/openapi.yaml`](../../backend/openapi.yaml).

| Method and path | Who | Answer |
|---|---|---|
| `GET /api/v1/auth/session` | anyone | 200 `{"authenticated": false}`, or the user, active memberships with their permissions, the CSRF token and `expiresAt` |
| `POST /api/v1/auth/login` | anyone | 200 the session as above; 401 `invalid-credentials`; 429; 403/415 (request forgery) |
| `POST /api/v1/auth/logout` | anyone | 204 (also without a session) |
| `GET /api/v1/me` | logged in | profile, memberships, CSRF token |
| `POST /api/v1/me/password` | logged in | 204; 422 with `errors[]`; 429 |
| `GET /api/v1/organizations/{organizationId}` | member, `organization.view` | the organization and the own membership |
| `GET /api/v1/organizations/{organizationId}/members` | member, `membership.list` | active members, paginated (`page`, `pageSize` up to 100) |
| `GET /api/v1/organizations/{organizationId}/members/{membershipId}` | member, `membership.list` | one member |

`GET /api/v1/system/status` and `/health/{live,ready}` stay public and never
read a session (`/health` is outside the firewall).

### Answers

| Status | Problem type | When |
|---|---|---|
| 400 | `bad-request` | the body is not a JSON object; a login member is missing |
| 401 | `unauthenticated` | no valid session; `WWW-Authenticate: Session realm="flowcrm"`; no data |
| 401 | `invalid-credentials` | every failed login, whatever the reason |
| 403 | `csrf-invalid` | origin policy or CSRF token failed |
| 403 | `forbidden` | a member without the permission |
| 404 | `not-found` | unknown route, unknown or foreign organization, removed membership, a resource of another organization: all the same |
| 415 | `unsupported-media-type` | an unsafe request with a body that is not JSON |
| 422 | `validation-error` | `errors[]` with `pointer` (body) or `parameter` (query) and a stable `code`, such as `UNKNOWN_FIELD`, `UNKNOWN_PARAMETER`, `PASSWORD_TOO_SHORT`, `INVALID_CURRENT_PASSWORD` |
| 429 | `too-many-requests` | a limit is reached; `Retry-After` in seconds |

The order: unsafe-request checks (415, 403 `csrf-invalid`), then the
firewall (401), then the organization (404), then the permission (403).
Every API response has `Cache-Control: no-store` and `Vary: Cookie`.

## Login and sessions

- **Firewall** `api` (`backend/config/packages/security.yaml`): pattern
  `^/api`, lazy (an anonymous request reads no session), `json_login` with
  `email` and `password`, `App\Identity\Infrastructure\Security\UserProvider`
  (case-insensitive e-mail lookup with the `lower()` of the unique index).
- **Passwords:** Argon2id (libsodium, `m=19456,t=3,p=1`; about 20 ms per
  hash on the development hardware). Hashes with other parameters are
  replaced at the next successful login. Policy: 12 to 128 characters
  (code points), no composition rules.
- **Generic failures:** an unknown address costs one hash like a known one;
  a disabled account is refused after the password check; every failure is
  the same 401.
- **Session fixation:** every login gets a new session ID and deletes the
  previous row; an attacker-chosen ID is never adopted (strict mode).
- **What the session holds:** the security token with
  `App\Identity\Infrastructure\Security\SecurityUser` (user ID, crc32c
  fingerprint of the password hash and the time of the last password
  change, login time) and the CSRF token. No password hash, no e-mail
  address, no organization or role.
- **When a session ends:** logout (row deleted, cookie expired); 30 minutes
  without a request; 8 hours after the login
  (`FLOWCRM_SESSION_ABSOLUTE_LIFETIME`, seconds); on the next request after
  the user was disabled or removed or the password changed elsewhere. The
  firewall then drops the token and `SessionEndListener` invalidates the
  whole session.
- **Password change** (`POST /api/v1/me/password`): needs the current
  password; this session gets a new ID and stays logged in, every other
  session of the user ends. Wrong current passwords: 5 per user per 15
  minutes.
- **Cookie:** `flowcrm_sid` in development (plain HTTP on 127.0.0.1, so not
  `Secure`), `__Host-flowcrm_sid` with `Secure` elsewhere; `HttpOnly`,
  `SameSite=Lax`, `Path=/`, no `Domain` (see
  [sessions and cache](sessions-and-cache.md#cookie)).

## Cross-site request forgery

`App\Shared\Http\Security\RequestOriginGuard` runs for every unsafe `/api`
request before the firewall, so it also protects login and logout:

1. A body must be `application/json` (415): HTML forms and CORS-simple
   requests cannot send one, and a cross-origin JSON request needs a
   preflight, which fails (there is no CORS). A request without a body
   (logout) needs no media type: Caddy's FastCGI transport labels every
   POST without a `Content-Type` as a form. Form and multipart bodies count
   as bodies even though PHP parses them itself.
2. `Origin` must equal the request's own origin (scheme from the edge, host
   and port from the `Host` header). Without `Origin` the origin of the
   `Referer` must; without both the request is refused. A `Sec-Fetch-Site`
   other than `same-origin` is refused.
3. A logged-in session must send its CSRF token in `X-CSRF-Token`
   (Symfony's session-bound token; the answers carry a newly masked value).
   It is created at login and dropped with the session. Login is the only
   route without a token (it has no session yet).

The SPA keeps the token in memory only and retries a request refused with
`csrf-invalid` once, after reading the session again (such a request was
not processed). The edge's access log removes `X-CSRF-Token`.

## Login throttling

Checked before the password is hashed; only failures count; unknown
accounts count like known ones (`App\Identity\Infrastructure\Security\LoginRateLimiter`,
limits in `backend/config/services.yaml`):

| Limit | Window | Against |
|---|---|---|
| 5 per account and client IP | 15 minutes, sliding | guessing from one client |
| 50 per client IP | 15 minutes | password spraying over many accounts |
| 100 per account | 1 day | distributed guessing against one account |

A successful login clears only the account-and-IP window. The state is in
`cache_items` (pool `cache.rate_limits`) under HMAC keys; PostgreSQL
advisory locks on the cache connection make concurrent failures all count.

**Client IP:** PHP-FPM is reachable only from the edge (network `back`), and
Caddy replaces any `X-Forwarded-For` a client sends. The API trusts only its
direct peer (`TRUSTED_PROXIES=REMOTE_ADDR` in `compose.yaml`) and takes only
`X-Forwarded-For` and `X-Forwarded-Proto` from it. A deployment with
another proxy in front of Caddy must configure Caddy's `trusted_proxies`
for it; if PHP-FPM ever became reachable by anything but the edge,
`TRUSTED_PROXIES` would have to name the edge's address instead.

## Tenant authorization

- **Where the organization comes from:** only the route parameter
  `{organizationId}` (`Requirement::UUID`). It is never stored in the
  session and never read from the query, the body or a header; unknown
  query parameters and body members are a 422.
- **Every request:** `App\Organizations\Http\Tenant\TenantGuard` loads the
  current user's `ACTIVE` membership (`memberships_organization_user_key`).
  None, a removed one or an unknown organization: 404. Removal and role
  changes apply from the next request (TI-04).
- **Policy:** each tenant route declares exactly one `#[TenantPermission]`;
  otherwise it fails closed (500) and `RouteSecurityTest` fails.
  `TenantPermissionVoter` decides with `App\Organizations\Domain\RolePolicy`
  and only for the user's own membership. Every user has `ROLE_USER` only.
- **Queries:** every read is filtered by the organization in SQL
  (`DbalOrganizationReadModel`); a membership ID of another organization is
  a 404 like an unknown one.

### Provisional role matrix

| Permission | ADMIN | MANAGER | REP |
|---|---|---|---|
| `organization.view` | yes | yes | yes |
| `membership.list` (name, role) | yes | yes | yes |
| `membership.view_email` | yes | yes | no (provisional) |

Everything else is denied. The API returns each role's permissions with the
memberships for showing controls; it decides every request itself.

## Operator console

There is no public registration. The platform operator provisions users and
organizations with console commands in the api container; passwords are
read from standard input (or hidden at a terminal), never from an argument:

```console
$ api=$(docker compose -p "$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .runtime/dev.env)" ps -q api)
$ docker exec -it "$api" php bin/console flowcrm:user:create --email=ada@example.test --display-name='Ada Example'
$ docker exec -it "$api" php bin/console flowcrm:organization:create --name='Example Ltd' --currency=EUR --timezone=Europe/Warsaw --admin-email=ada@example.test
$ docker exec -it "$api" php bin/console flowcrm:membership:add --organization=<id> --email=grace@example.test --role=REP
$ docker exec -it "$api" php bin/console flowcrm:user:reset-password ada@example.test
$ docker exec -it "$api" php bin/console flowcrm:user:disable ada@example.test
$ docker exec -it "$api" php bin/console flowcrm:user:enable ada@example.test
```

Every change is audited with the actor `platform_operator`. A password
reset by the operator is the account recovery without e-mail (FCRM-002
OQ-10); it ends every session of the user.

## Audit events and security log

| Audit action | Actor | Entity |
|---|---|---|
| `auth.login_succeeded`, `auth.logout`, `auth.password_changed` | the user | the user (no organization) |
| `user.created`, `user.password_reset`, `user.disabled`, `user.enabled` | `platform_operator` | the user |
| `organization.created`, `membership.added` (`changes: {"role": …}`) | `platform_operator` | organization, membership |

Audit events carry the request ID and never an IP address, password, hash,
token, session ID or e-mail address. **Failures are not audited** (failed
logins, CSRF rejections, 403 and 404): anonymous traffic must not be able
to fill the append-only table. They are written to the `security` log
channel instead:

| `event` | Fields |
|---|---|
| `login_failed` | `reason` (`invalid_credentials` or `disabled`), `account_ref`, `client_ref` |
| `login_succeeded`, `logout`, `session_ended`, `password_changed`, `password_change_failed` | `user_id` |
| `request_rejected` | `reason` (`content_type`, `fetch_site`, `origin_missing`, `origin_mismatch`, `token_missing`, `token_invalid`), `method`, `route` |
| `tenant_not_found`, `authorization_denied` | `user_id`, `route`, and for denials `permission`, `role`, `organization_id` |

`account_ref` and `client_ref` are HMAC-SHA256 pseudonyms (application
secret, 64 bits) of the lower-case e-mail and of the client IP: equal values
can be correlated, the values themselves are not logged. The redactor also
masks `email`, `password`, token and session keys.

### Retention

Logs are short-lived diagnostics. Docker keeps the api and edge output in at
most 3 files of 10 MB per container (`compose.yaml`, `x-request-logs`) and
removes it with the container. The edge's access log contains the client
address, as every HTTP access log does; it is not copied anywhere. A
deployment must keep equivalent limits in its log pipeline (and decide a
time-based retention) before any real personal data is processed.

## React application

- `AuthProvider` reads `GET /api/v1/auth/session` on load and keeps the
  state (`loading`, `unavailable`, `anonymous`, `authenticated`) and the CSRF
  token in memory; nothing goes to browser storage.
- `RequireAuth` guards every page except `/login`; anonymous visitors go to
  `/login?returnTo=…`. `safeReturnTo()` accepts only a path of the
  application (no scheme, no `//`, no backslash, no control characters, not
  `/login`), so a crafted link cannot redirect elsewhere.
- Any 401 from the API ends the session in the SPA and shows the login with
  "Your session has ended". A 404 shows the same "Not found" page for a
  foreign organization and an unknown address; a 403 shows a message without
  data; a 429 says how long to wait.
- Routes: `/login`, `/` (straight to the only organization, or a choice),
  `/o/:organizationId` (profile and member directory; the e-mail column
  only with `membership.view_email`).

## Tests

| Where | What |
|---|---|
| `backend/tests/Integration/Security/AuthenticationTest` | login answer and cookie, fixation (existing and planted IDs), identical failures, case-insensitive e-mail, anonymous introspection without a session, logout and replay (AC-27), logout CSRF, absolute and idle expiry, invalidation by disable, operator reset and own password change, no credentials or tenant in the session, hash upgrade, token rotation |
| `RequestForgeryTest` | eight foreign-origin variants refused before authentication and with a valid token, Referer fallback, token missing, empty, forged or of another session, safe methods, form and text bodies (415), anonymous unsafe requests (401), malformed JSON |
| `LoginThrottlingTest` | the three limits, unknown accounts alike, case-insensitive accounts, reset of the account-and-IP window only, keyed by the forwarded client IP, throttle before the password check |
| `TenantAuthorizationTest` | anonymous 401, foreign organization identical to an unknown one, no memberships, the role in the answer, e-mail by permission, a user in two organizations, IDOR with guessed and malformed IDs, client-supplied organization IDs, removal and demotion on the next request, pagination |
| `RouteSecurityTest` | every tenant route has the UUID requirement and exactly one permission; every API route outside the public list needs a login; `/health` is outside the firewall; the specification matches the routes |
| `AuditTrailTest`, `SecurityLoggingTest`, `ProvisioningCommandTest`, `SecurityConfigurationTest` | audit events without secrets or IP, none for failures; security log with pseudonyms; console input rules; production hasher, lifetime, limits and trusted headers |
| Unit tests | `SecurityUser`, `PasswordPolicy`, `UserProvider` (one hash for unknown e-mails), `LoginRateLimiter`, `RolePolicy` (the matrix as data), `TenantPermissionVoter`, `TenantGuard`, `RequestOriginGuard`, `JsonBody`, `Pagination`, problem documents |
| `tests/app/backend.sh` BE-18 | 28 negative controls (`backend/tests/Mutation/controls.php`): each removes one protection in a copy of the backend and must make its tests fail |
| `tests/app/stack.sh` ST-69 to ST-73, ST-16 | through the real edge: cookie attributes, logout with token and replay, cross-origin and form logins, spoofed `X-Forwarded-For` cannot evade the limit, no secrets in any log; Playwright journeys (login, logout, back button, roles, two organizations, foreign organization, CSRF) |
| `tests/app/prodlike.sh` PL-16, PL-11 | the production cookie (`__Host-`, `Secure`); the login page under the production CSP |
| `frontend/src/**/*.test.ts(x)` | `safeReturnTo`, the API client (CSRF header, problems, single retry, 401 handling) and the routes |

The API tests run against the real PHP-FPM, PdoSessionHandler and PostgreSQL
(`App\Tests\Support\Http\ApiClient`), and every `/api/v1` response they get
is checked against `backend/openapi.yaml`.

## Known limitations

- The role matrix is provisional; tenant mutations and membership
  management through the API come later.
- No self-service password reset (no e-mail delivery exists); recovery is
  the operator's `flowcrm:user:reset-password`.
- The per-user API rate limit of FCRM-002 NFR-007 (600 per minute) is not
  implemented.
- No list of a user's sessions: the `sessions` table has no user column.
- The `Secure` `__Host-` cookie is checked with curl in the production-like
  stack; no environment here serves HTTPS, so its handling by a browser over
  TLS is not verified end to end.
- The hashing cost is tuned only for the development hardware.
