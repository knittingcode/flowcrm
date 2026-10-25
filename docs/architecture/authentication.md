# Authentication and tenant authorization

How users log in, how sessions are protected and how access to an
organization is decided (FCRM-FND-010B), and how an organization's ADMIN
administers its memberships (FCRM-FND-010C). The decisions and their reasons
are in [ADR-019](adr/ADR-019-authentication-and-tenant-authorization.md)
(amended by the FCRM-FND-010V security gate) and, for membership
administration, [ADR-020](adr/ADR-020-membership-administration.md)
(proposed); sessions and their storage in
[sessions and cache](sessions-and-cache.md).

## Endpoints

All under the edge's single origin; the contract is
[`backend/openapi.yaml`](../../backend/openapi.yaml).

| Method and path | Who | Answer |
|---|---|---|
| `GET /api/v1/auth/session` | anyone | 200 `{"authenticated": false}`, or the user, active memberships with their permissions, the CSRF token and `expiresAt` |
| `POST /api/v1/auth/login` | anyone | 200 the session as above; 401 `invalid-credentials`; 429; 403/415 (request forgery); 500 when its audit event cannot be written (no session) |
| `POST /api/v1/auth/logout` | anyone | 204 (also without a session); 500 when its audit event cannot be written (the session has ended anyway) |
| `GET /api/v1/me` | logged in | profile, memberships, CSRF token |
| `POST /api/v1/me/password` | logged in | 204; 422 with `errors[]`; 429; 500 when its audit event cannot be written (nothing changed) |
| `GET /api/v1/organizations/{organizationId}` | member, `organization.view` | the organization and the own membership |
| `GET /api/v1/organizations/{organizationId}/members` | member, `membership.list` | active members, paginated (`page`, `pageSize` up to 100) |
| `GET /api/v1/organizations/{organizationId}/members/{membershipId}` | member, `membership.list` | one member |
| `POST /api/v1/organizations/{organizationId}/members` | member, `membership.add` | body `{"email", "role"}`: 201 the new member and `Location`; 422 `UNKNOWN_USER` (`/email`), `INVALID_ROLE` (`/role`); 409 `MEMBERSHIP_EXISTS` (also for a removed membership) |
| `PATCH /api/v1/organizations/{organizationId}/members/{membershipId}` | member, `membership.change_role` | body `{"role"}`: 200 the member (the same role again: no change, no audit event); 404 unknown, foreign or removed; 422 `INVALID_ROLE`; 409 `LAST_ADMIN` |
| `DELETE /api/v1/organizations/{organizationId}/members/{membershipId}` | member, `membership.remove` | 204, the membership becomes `REMOVED`; 404 unknown, foreign or already removed; 409 `LAST_ADMIN` |

`GET /api/v1/system/status` and `/health/{live,ready}` stay public and never
read a session (`/health` is outside the firewall).

### Answers

| Status | Problem type | When |
|---|---|---|
| 400 | `bad-request` | the body is not a JSON object; a login member is missing |
| 401 | `unauthenticated` | no valid session; `WWW-Authenticate: Session realm="flowcrm"`; no data; it starts and stores no session, and expires a cookie the request brought |
| 401 | `invalid-credentials` | every failed login, whatever the reason |
| 403 | `csrf-invalid` | origin policy or CSRF token failed |
| 403 | `forbidden` | a member without the permission |
| 404 | `not-found` | unknown route, unknown or foreign organization, removed membership, a resource of another organization: all the same |
| 415 | `unsupported-media-type` | an unsafe request with a body that is not JSON |
| 409 | `conflict` | a membership change conflicts with the organization's memberships: `errors: [{"code": "MEMBERSHIP_EXISTS"}]` or `[{"code": "LAST_ADMIN"}]`; nothing was changed |
| 422 | `validation-error` | `errors[]` with `pointer` (body) or `parameter` (query) and a stable `code`, such as `UNKNOWN_FIELD`, `UNKNOWN_PARAMETER`, `PASSWORD_TOO_SHORT`, `INVALID_CURRENT_PASSWORD`, `INVALID_ROLE`, `UNKNOWN_USER` |
| 429 | `too-many-requests` | a login limit or the per-user API limit is reached; `Retry-After` in seconds |

The order: unsafe-request checks (415, 403 `csrf-invalid`), then the
firewall (401), then the per-user API limit (429), then the organization
(404), then the permission (403); for membership changes then the target
membership (404), the body (422) and conflicts (409).
Every API response has `Cache-Control: no-store` and `Vary: Cookie`.

## Login and sessions

- **Firewall** `api` (`backend/config/packages/security.yaml`): pattern
  `^/api`, lazy (an anonymous request reads no session), `json_login` with
  `email` and `password`, `App\Identity\Infrastructure\Security\UserProvider`
  (case-insensitive e-mail lookup with the `lower()` of the unique index).
- **Passwords:** Argon2id (libsodium, `m=19456,t=3,p=1`, see
  [password hashing](#password-hashing)). Hashes with other parameters are
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
  (`FLOWCRM_SESSION_ABSOLUTE_LIFETIME`, seconds); at once when the operator
  disables the user (`flowcrm:user:disable` deletes every session row of
  the user in the same transaction, and `flowcrm:user:enable` deletes them
  again, so a session stored by a login that was in flight during the
  disable is not revived either); on the next request after the user was disabled or removed or the
  password changed elsewhere. The firewall then drops the token and
  `SessionEndListener` invalidates the whole session.
- **Password change** (`POST /api/v1/me/password`): needs the current
  password; this session gets a new ID and stays logged in, every other
  session of the user ends. Wrong current passwords: 5 per user per 15
  minutes.
- **Cookie:** `flowcrm_sid` in development (plain HTTP on 127.0.0.1, so not
  `Secure`), `__Host-flowcrm_sid` with `Secure` elsewhere; `HttpOnly`,
  `SameSite=Lax`, `Path=/`, no `Domain` (see
  [sessions and cache](sessions-and-cache.md#cookie)). Verified in Chromium
  over HTTPS (see [HTTPS](#https-and-proxies)).
- **Anonymous requests store nothing:** before answering 401, Symfony's
  firewall writes the requested URL into the session (the target of a
  login redirect), which would store a session and set a cookie for every
  anonymous request. `ProblemEntryPoint` removes it again: an empty session
  is not stored, and a cookie of an unknown or ended session is expired.

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

The account part of a key folds case at least as far as the user lookup
(PostgreSQL `lower()`, simple one-to-one Unicode mapping), so every spelling
that loads an account shares its windows; with the full mapping, a spelling
with `İ` (U+0130) would have got windows of its own. This was checked for
every code point under the database locale (libc, `en_US.utf8`): no two
spellings that `lower()` folds together get different keys. For 124 code
points (circled letters such as `Ⓐ`, for example) the key folds and `lower()`
does not; those spellings share an account's windows without loading it,
which only makes the limit stricter. The check must be repeated if the
locale, the collation provider, the C library or PHP's Unicode tables change.

A NUL byte never reaches PostgreSQL: the driver (`pdo_pgsql`) passes bound
strings as C strings and cuts them at the first NUL, so
`ada@example.test\u0000anything` would load Ada's account while the limits
key the whole string, a fresh set of windows for every suffix. An address
with a NUL byte, or one that is not UTF-8, therefore matches no account
before any query (`User::canHoldEmail`, used by every e-mail lookup and by
user creation): the login is the ordinary 401 `invalid-credentials` of an
unknown account (same hashing cost), and operator commands treat it as an
unknown user.

A successful login clears only the account-and-IP window. The state is in
`cache_items` (pool `cache.rate_limits`) under HMAC keys; PostgreSQL
advisory locks on the cache connection make concurrent failures all count.

**Client IP:** PHP-FPM is reachable only from the edge (network `back`).
Over FastCGI the edge passes the client's own address as `REMOTE_ADDR` and
`HTTPS=on` for TLS requests, so the API trusts no proxy (`compose.yaml` sets
no `TRUSTED_PROXIES`) and never reads a forwarding header: neither a
client's `X-Forwarded-*` headers nor an edge that passes them on can change
the client IP or the scheme (BE-17 checks that no proxy is trusted). A
deployment with another proxy in front of Caddy must configure Caddy's
`trusted_proxies` for it; Caddy then passes the real client as
`REMOTE_ADDR`. Only the PHP-FPM test harness, which plays the edge, trusts
its own address (`compose.test.yaml`).

## HTTPS and proxies

Verified with the production build and the production edge configuration,
TLS terminated by the edge itself (`tests/app/prodlike.sh` PL-17 to PL-22,
test sites in `tests/app/https`, a throwaway certificate per run that
Chromium trusts by its key only):

- In Chromium the session cookie is `__Host-flowcrm_sid`, `Secure`,
  `HttpOnly`, `SameSite=Lax`, `Path=/`, host-only (no `Domain`), a browser
  session cookie, and not readable by scripts; login, API calls and logout
  work through the SPA.
- The browser never sends it over plain HTTP to the same host, and a login
  over plain HTTP leaves no cookie (the browser refuses a `Secure` cookie
  from an insecure origin).
- A page of another site cannot forge requests: a cross-site `fetch` and
  form posts are refused (403 `csrf-invalid`, 415 for a text body), and the
  session stays.
- The API takes the scheme and the client address only from the edge: a
  client's `X-Forwarded-Proto`, `X-Forwarded-For`, `X-Forwarded-Host` or
  `X-Forwarded-Port` changes neither the origin check nor the client IP of
  the login limits and the security log. There is no CORS: no
  `Access-Control-*` header on a preflight or a cross-origin read.
- **Deployment requirement:** TLS must end at the edge, or the edge must
  trust the proxy that ends it (Caddy `trusted_proxies`). Behind a TLS proxy
  the edge does not trust, the API sees plain HTTP and refuses every unsafe
  request (403, PL-20): it fails closed. The TLS site must also send HSTS
  (FCRM-002 NFR-010); there is no deployment configuration yet.

## Per-user API limit

FCRM-002 NFR-007: a logged-in user may make 600 requests per minute (sliding
window) to the routes that require a login; the next one is a 429 with
`Retry-After` (`App\Identity\Http\Security\UserRateLimitListener`, limit in
`backend/config/services.yaml`, state in the same pool and with the same
locks as login throttling).

- Counted after the firewall and keyed by the user ID: anonymous requests,
  unsafe requests the request-origin guard refused and other users never
  count against a user.
- Not counted: the public routes (`/auth/session`, `/auth/login`,
  `/auth/logout`, `/system/status`). Login has its own limits, and a limited
  user can always log out.
- The limit is per user, not per session: all sessions of a user share it.
- Cost: one rate-limit update in PostgreSQL per counted request (an
  advisory lock, a read and a write on the cache connection), about 6 ms
  in a measurement on development hardware (`/me` 22.8 ms against 16.5 ms
  for the uncounted `/auth/session`, over TLS, api limited to 2 CPUs).

## Password hashing

Argon2id with libsodium, `m=19456` KiB, `t=3`, `p=1`
(`backend/config/packages/security.yaml`): above both OWASP baselines
(19 MiB with 2 passes, 12 MiB with 3); Symfony's libsodium hasher needs at
least 3 passes. The memory is allocated outside PHP's `memory_limit`.

**Evidence (FND-010V).** `bin/benchmark-password-hashing` verifies with
Symfony's hasher in parallel worker processes, as many as PHP-FPM runs at
once (`pm.max_children = 8`, `docker/api/php-fpm.conf`), in the api image
with Docker CPU and memory limits (Apple M4 Pro):

| Parameters | 1 CPU, 512 MB, 8 parallel | 2 CPUs, 1 GB, 8 parallel | no limit, 1 at a time | memory per worker |
|---|---|---|---|---|
| 19 MiB, t=3 (chosen) | p50 309 ms, p95 490 ms, 21/s | p50 107 ms, p95 187 ms, 59/s | 23 ms | 41 MiB |
| 19 MiB, t=4 | p50 481 ms, p95 608 ms, 15/s | p50 187 ms, p95 200 ms, 43/s | 24 ms | 41 MiB |
| 46 MiB, t=3 | p50 905 ms, p95 1105 ms, 8/s | p50 313 ms, p95 402 ms, 21/s | 49 ms | 68 MiB |
| 64 MiB, t=3 | killed (out of memory) | p50 496 ms, p95 527 ms, 15/s | 79 ms | 86 MiB |

Through the real edge and PHP-FPM (production images, successful logins:
hash, audit event and session write), the api container limited with
`docker update`:

| api container | 1 client | 8 parallel | 16 parallel (twice `pm.max_children`) |
|---|---|---|---|
| 1 CPU, 512 MB | p50 46 ms, p95 63 ms | p50 317 ms, p95 408 ms | p50 894 ms, p95 1105 ms |
| 2 CPUs, 1 GB | p50 50 ms, p95 62 ms | p50 181 ms, p95 203 ms | p50 380 ms, p95 403 ms |

Every login succeeded; requests beyond `pm.max_children` wait in PHP-FPM's
queue. A login's cost is one verification. Under full concurrency the latency is
set by the CPUs, not by the parameters alone: on a small instance, more
memory per hash makes every login slower for everyone during a burst, and
8 workers x 86 MiB does not fit 512 MB. 19 MiB with 3 passes keeps a login
under half a second at the 95th percentile on one CPU with 8 parallel
logins, which the login limits bound per client and account.

**Tuning a deployment:** run the benchmark in the api container on the
target hardware, with its limits and its `pm.max_children`:

```console
$ docker exec "$api" php bin/benchmark-password-hashing 19456 3 8 20
```

Raise `memory_cost` (then `time_cost`) in `security.yaml` while the 95th
percentile stays within the login budget and `pm.max_children` x (memory
per worker) fits the container's memory with room for PHP-FPM itself;
`SecurityConfigurationTest` pins the production values, so change it with
them. Existing hashes are upgraded at each user's next login, and the other
sessions of that user end then (the credentials fingerprint changes).

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
| `membership.add` | yes | no | no |
| `membership.change_role` | yes | no | no |
| `membership.remove` | yes | no | no |

Everything else is denied. The API returns each role's permissions with the
memberships for showing controls; it decides every request itself.

### Membership administration

FCRM-FND-010C, [ADR-020](adr/ADR-020-membership-administration.md)
(proposed): `App\Organizations\Application\ManageMemberships` runs every
add, role change and removal in one database transaction that

1. locks the organization row (`SELECT id FROM organizations WHERE id = ?
   FOR NO KEY UPDATE`, `DbalOrganizationLock`), so the membership changes of
   one organization, including the operator's `flowcrm:membership:add`, run
   one after the other; inserts that only reference the organization do not
   wait;
2. reads the actor's own membership again under the lock: none any more is
   a 404, a role that no longer grants the permission a 403 (the check of
   `TenantGuard` before the lock is not trusted for the write);
3. reads the target membership by organization and ID (`REMOVED` counts as
   not found);
4. for a demotion or removal of an active ADMIN counts the active ADMINs
   under the lock: fewer than two is a 409 `LAST_ADMIN`
   (`App\Organizations\Domain\LastAdminRule`, FCRM-002 BR-03); this also
   applies to an ADMIN demoting or removing themselves;
5. writes the change and its audit event, which commit together.

Members are added by the e-mail address of an existing user
(case-insensitive); there is no invitation and no reactivation of a removed
membership (409 `MEMBERSHIP_EXISTS`). A removed or demoted user's next
request sees the change (TI-04).

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
OQ-10); it ends every session of the user. Disabling a user deletes every
session of the user at once; enabling the user deletes them again (none
can be valid, but a login in flight during the disable may have stored
one), so enabling restores no session.

## Audit events and security log

| Audit action | Actor | Entity |
|---|---|---|
| `auth.login_succeeded`, `auth.logout`, `auth.password_changed` | the user | the user (no organization) |
| `user.created`, `user.password_reset`, `user.disabled`, `user.enabled` | `platform_operator` | the user |
| `organization.created`, `membership.added` (`changes: {"role": …}`) | `platform_operator` | organization, membership |
| `membership.added` (`{"role": …}`), `membership.role_changed` (`{"roleFrom": …, "roleTo": …}`), `membership.removed` (`{"role": …}`) | the user, actor role `ADMIN` | the membership, with the organization |

Audit events carry the request ID and never an IP address, password, hash,
token, session ID or e-mail address. **No sensitive change without its
event:** a login whose event cannot be written fails (500) and leaves no
session; a password change, an operator change, a membership change and
their events are one database transaction, so nothing changes without the
event; a logout ends
the session before it writes its event, and answers 500 if the event cannot
be written (the session has ended either way). **Failures are not audited** (failed
logins, CSRF rejections, 403 and 404): anonymous traffic must not be able
to fill the append-only table. They are written to the `security` log
channel instead:

| `event` | Fields |
|---|---|
| `login_failed` | `reason` (`invalid_credentials` or `disabled`), `account_ref`, `client_ref` |
| `login_succeeded`, `logout`, `session_ended`, `password_changed`, `password_change_failed` | `user_id` |
| `request_rejected` | `reason` (`content_type`, `fetch_site`, `origin_missing`, `origin_mismatch`, `token_missing`, `token_invalid`), `method`, `route` |
| `tenant_not_found`, `authorization_denied` | `user_id`, `route`, and for denials `permission`, `role`, `organization_id` (also when the re-check of a membership change under the organization lock refuses) |
| `membership_change_refused` | `reason` (`membership_not_found`, `unknown_user`, `membership_exists`, `last_admin`), `user_id`, `organization_id`, `route`; never the e-mail address |
| `api_rate_limited` | `user_id` |

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
  only with `membership.view_email`), `/o/:organizationId/members?page=`
  (member administration).
- Member administration: the form to add a member, the role select with its
  "Change role" button and "Remove" (with an inline confirmation) are shown
  only when the user's own membership in that organization
  (`GET /organizations/{id}`) has `membership.add`, `membership.change_role`
  or `membership.remove`. Nothing in the page changes before the server has
  answered: after every change, and after a 403, 404 or 409, the
  organization and the member list are read again, and so they are when it
  is unknown whether a change was saved (no answer, an unreadable success
  answer, or any 5xx); the rows are not actionable
  until the new list has arrived. After a 403 or 404 the session is read
  again as well, as the user's own access may have changed, and so it is
  when it is unknown whether a change of the user's own membership was
  saved. A 409 `LAST_ADMIN` says
  that an organization needs at least one admin, `MEMBERSHIP_EXISTS` that
  the user has a membership already; 422 errors are shown at their inputs.
  Removing oneself reads the session again and leads to `/`.

## Tests

| Where | What |
|---|---|
| `backend/tests/Integration/Security/AuthenticationTest` | login answer and cookie, fixation (existing and planted IDs), identical failures, case-insensitive e-mail, anonymous introspection and 401s without a stored session or cookie (also with an unknown session ID), logout and replay (AC-27), logout CSRF, absolute and idle expiry, invalidation by disable (rows deleted at once, none restored by enabling again, also not one stored after the disable, other users' sessions kept), operator reset and own password change, no credentials or tenant in the session, hash upgrade, token rotation |
| `RequestForgeryTest` | eight foreign-origin variants refused before authentication and with a valid token (with the request ID), Referer fallback, token missing, empty, forged or of another session, safe methods, form and text bodies (415), anonymous unsafe requests (401), malformed JSON |
| `ApiRateLimitTest` | the 601st request in a minute is a 429 with `Retry-After`; per user; the session probe and logout stay available; login, public routes, anonymous and refused requests are not counted |
| `LoginThrottlingTest` | the three limits, unknown accounts alike, case-insensitive accounts (including Unicode spellings that the lookup folds together), an address with a NUL byte matches no account (even the right password is a 401), reset of the account-and-IP window only, keyed by the forwarded client IP, throttle before the password check |
| `TenantAuthorizationTest` | anonymous 401, foreign organization identical to an unknown one, no memberships, the role in the answer, e-mail by permission, a user in two organizations, IDOR with guessed and malformed IDs, client-supplied organization IDs, removal and demotion on the next request, pagination |
| `MembershipAdministrationTest` | an ADMIN adds an existing user (201, `Location`, audit event with the request ID, AC-09); `MEMBERSHIP_EXISTS` also for a removed membership; `UNKNOWN_USER`, `INVALID_ROLE`, unknown members; MANAGER and REP get 403 on all three routes; foreign organization and foreign membership IDs 404 with nothing changed; the last ADMIN can neither demote nor remove themselves (409, no audit event); a disabled ADMIN still counts for that rule (current behaviour, open decision); with two ADMINs either is possible, also for oneself, and applies on the next request; repeated DELETE 404; the same role without an audit event; a failing audit write changes nothing (500), and so does a failing read of the member for the answer (500); CSRF and origin on the new routes; two ADMINs demoting or removing each other concurrently leave one ADMIN; the last two ADMINs stepping down at once leave one (409 `LAST_ADMIN`); two concurrent adds of one user give 201 and 409 `MEMBERSHIP_EXISTS`; two concurrent removals of one member give 204 and 404 with one event; two concurrent role changes of one member apply one after the other (one chain of events); memberships in another organization count neither for the actor nor as a duplicate; a promotion applies on the next request; anonymous (401) and rate-limited (429) changes change nothing; an address with a NUL is `UNKNOWN_USER`; `MembershipRefusalLoggingTest`: refused lookups are logged without the address; an ADMIN demoted (403) or removed (404) while their request waits for the lock is refused; another organization does not wait for the lock |
| `RouteSecurityTest` | every tenant route has the UUID requirement and exactly one permission; every API route outside the public list needs a login; `/health` is outside the firewall; the specification matches the routes |
| `AuditTrailTest`, `SecurityLoggingTest`, `ProvisioningCommandTest`, `SecurityConfigurationTest` | audit events without secrets or IP, none for failures; with the audit table failing (a test trigger): no login, no password or operator change, but the logout still ends the session; security log with pseudonyms and the request ID of the answer; console input rules (an address with a NUL byte or invalid UTF-8 names no user); production hasher, lifetime, limits and trusted headers |
| Unit tests | `SecurityUser`, `PasswordPolicy`, `UserProvider` (one hash for unknown e-mails), `LoginRateLimiter`, `RolePolicy` (the matrix as data), `TenantPermissionVoter`, `TenantGuard`, `RequestOriginGuard`, `JsonBody`, `Pagination`, problem documents, `ManageMemberships` (lock first; the checks, the audit event and the read of the member for the answer inside the transaction), `Membership::changeRole` and `LastAdminRule` |
| `tests/app/backend.sh` BE-18 | 64 negative controls (`backend/tests/Mutation/controls.php`): each removes one protection in a copy of the backend and must make its tests fail |
| `tests/app/stack.sh` ST-69 to ST-73, ST-16 | through the real edge: cookie attributes, logout with token and replay, cross-origin and form logins, spoofed `X-Forwarded-For` cannot evade the limit, no secrets in any log; Playwright journeys (login, logout, back button, roles, two organizations, foreign organization, CSRF) |
| `tests/app/prodlike.sh` PL-16, PL-11 | the production cookie (`__Host-`, `Secure`) with curl; the login page under the production CSP |
| `tests/app/prodlike.sh` PL-17 to PL-22, `frontend/e2e/https.spec.ts` | over HTTPS (see [HTTPS](#https-and-proxies)): the TLS site, spoofed forwarding headers, no CORS, an untrusted TLS proxy fails closed, the cookie and the logged-in journeys in Chromium, cross-site forgeries, the client IP behind the edge |
| `frontend/src/**/*.test.ts(x)` | `safeReturnTo`, the API client (CSRF header, problems, single retry, 401 handling), the membership requests and the routes, including the member administration (controls by permission, field errors and focus, conflicts, 403/404 with reload, self-removal, confirmation focus, page in the address) |
| `frontend/e2e/members.spec.ts` | through the real edge (dev and HTTPS): an ADMIN's controls with refused changes (existing membership, unknown user, last admin by demotion and by self-removal), add, role change and removal of a spare user, a MANAGER and a REP without controls and their forged changes answered 403, another organization's members page and memberships (also through the own organization's address) answered 404, a change after the session ended on the server leading to the login, sign-out, no sideways scrolling at 320 px, and with the keyboard only: an ADMIN demoted while the page is open (403, the controls go), a removal whose answer is lost (unknown outcome, the list shows the server's state) and a removed ADMIN's next change (the "Not found" page and a start page without the organization); the seeded memberships are left unchanged |

The API tests run against the real PHP-FPM, PdoSessionHandler and PostgreSQL
(`App\Tests\Support\Http\ApiClient`), and every `/api/v1` response they get
is checked against `backend/openapi.yaml`.

## Known limitations

- The role matrix is provisional. Membership administration (ADMIN only)
  is the only tenant mutation; ADR-020 is proposed and lists its
  [open decisions](adr/ADR-020-membership-administration.md#open-decisions):
  reactivation of removed members, whether disabled ADMINs count, account
  discovery and consent when adding by e-mail (including a dedicated
  limit), the code name `LAST_ADMIN`, and a bound on the lock wait.
- A removed member cannot be added again (409 `MEMBERSHIP_EXISTS`): there is
  no reactivation yet.
- No self-service password reset (no e-mail delivery exists); recovery is
  the operator's `flowcrm:user:reset-password`.
- No list of a user's sessions: the `sessions` table has no user column.
- HTTPS is verified with TLS terminated by the edge and a test
  certificate in Chromium only; a deployment's own TLS configuration
  (certificates, HSTS, any proxy in front) does not exist yet.
- The hashing parameters were measured on development hardware under
  Docker CPU and memory limits; measure again on the target hardware.
- An anonymous request to a route that requires a login still opens and
  discards a session in PostgreSQL before its 401 (nothing is stored).
