# Sessions and cache

Server-side sessions and the application cache, both in the existing
PostgreSQL service (FCRM-003 section F, ADR-005, ADR-007): no Redis and no
other new service. This is infrastructure only. Login, logout, CSRF tokens,
authorization and the `/me` endpoint are not implemented, and no production
route uses a session yet.

Configuration: `backend/config/packages/session.yaml` and
`backend/config/packages/cache.yaml`. Migration:
`backend/migrations/Version20261022100000.php`.

## Sessions

### Storage

Symfony's `PdoSessionHandler` stores sessions in the `sessions` table:

| Column | Type | Meaning |
|---|---|---|
| `sess_id` | `VARCHAR(128)`, primary key | session ID |
| `sess_data` | `BYTEA` | serialized session data |
| `sess_lifetime` | `INT`, index `sess_lifetime_idx` | expiry time (Unix seconds) |
| `sess_time` | `INT` | last write (Unix seconds) |

The table is exactly what the handler defines: DoctrineBundle's schema
listener adds it to the expected schema, so `doctrine:schema:validate`
(BE-07) fails if the migration and the handler differ.

The handler uses its own connection, built from the same `DATABASE_*`
settings and password file as Doctrine (no new credential). It is opened
only when a session starts, gives up after 5 seconds (`connect_timeout`) and
shows up as `flowcrm_sessions` in `pg_stat_activity`. Its lock transaction
(below) therefore never mixes with Doctrine's transactions.

### Lazy sessions

Nothing starts a session until code reads or writes it. Requests that do not
use the session (health checks, `/api/v1/system/status`, errors) get no
`Set-Cookie` header and store nothing, even when the request carries a
session cookie. A started session that stays empty is not stored either.

### Cookie

| Attribute | dev and test | prod |
|---|---|---|
| Name | `flowcrm_sid` | `__Host-flowcrm_sid` |
| `HttpOnly` | yes | yes |
| `SameSite` | `Lax` | `Lax` |
| `Path` | `/` | `/` |
| `Domain` | none | none |
| `Secure` | when the request is HTTPS (`auto`) | always |
| Expiry | browser session (`cookie_lifetime: 0`) | browser session |

The development stack runs over plain HTTP on 127.0.0.1, so `Secure` and the
`__Host-` prefix apply outside development only (FCRM-003 C-07). Browsers
accept a `__Host-` cookie only with `Secure`, `Path=/` and no `Domain`.

### Session IDs

- PHP 8.5 generates IDs of 32 characters at 4 bits each, 128 bits from its
  CSPRNG. The ID is never part of a response body or a log.
- Strict mode (`session.use_strict_mode`, set by Symfony's
  `NativeSessionStorage`): an ID the server does not know, such as an
  attacker-chosen, expired or malformed one, is never adopted; the session
  gets a new ID. This prevents session fixation with planted IDs.
- `migrate(true)` gives the session a new ID, keeps its data and deletes the
  old row, so the old ID cannot be replayed. `invalidate()` deletes the row
  and expires the cookie. The later login and logout use these two.
- **Both are silent no-ops on a session that has not started.** Symfony's
  firewall starts the session before authentication when a session cookie
  is present; code that migrates or invalidates on its own must call
  `start()` first.

### Lifetime and garbage collection

- **Idle timeout: 30 minutes** (`gc_maxlifetime: 1800`). Every request that
  uses the session moves `sess_lifetime` to now + 1800 s, including requests
  that do not change its data (PHP's lazy write updates only the timestamp).
  An expired session reads as empty, its ID is not reused, and a new
  session starts.
- **Garbage collection:** PHP runs it with probability 1/100
  (`gc_probability`/`gc_divisor`) when a session starts. The handler then
  deletes all expired rows after the request (`DELETE ... WHERE
  sess_lifetime < now`, using the index).
- The **absolute timeout of 8 hours** from FCRM-003 counts from the login
  time stored in the session, so it comes with the authentication work.

### Concurrency

The handler locks transactionally: `SELECT ... FOR UPDATE` on the session
row when the session starts, until the session is saved at the end of the
request. A second request of the same session waits for the first, so
neither overwrites the other's changes. The cost: such requests run one
after another, so request handlers that use the session should stay short.
Requests of different sessions do not wait for each other.

### Database outages

Requests that do not use the session are unaffected. An `/api` request that
uses the session fails with a 500 problem document without details; the
connection attempt is abandoned after 5 seconds.

### Logs

The log redactor masks values under the keys `session`, `sid`, `sess_id`,
`sess_data`, `cookie` and `set-cookie` (and keys containing `session` or
`cookie`); the edge masks `Cookie` request headers (ST-43). The PHP-FPM tests
check that no session ID appears in PHP-FPM or PHP error output.

## Cache

### Adapter choice

FCRM-003 section F names `cache_items`, managed by Symfony's Doctrine DBAL
cache adapter, and ADR-007 rules out Redis. `cache.app` and every pool based
on it therefore use `DoctrineDbalAdapter` on Doctrine's default connection.
`cache.system` (compiled container, routing and validation metadata) stays
on the local filesystem of the container: it is rebuilt from the code and
must not depend on the database.

| Column | Type | Meaning |
|---|---|---|
| `item_id` | `VARCHAR(255)`, primary key | pool namespace + key |
| `item_data` | `BYTEA` | serialized value |
| `item_lifetime` | `INT`, nullable | TTL in seconds; `NULL` = no expiry |
| `item_time` | `INT` | time of the write (Unix seconds) |

As for sessions, DoctrineBundle's schema listener adds the table to the
expected schema, so BE-07 compares it with the migration.

### Namespaces

Each pool stores its items under its own prefix (`<namespace>:<key>`), a
hash of the pool name and the prefix seed. The seed is fixed (`flowcrm`), so
namespaces do not change with the installation path or between deploys.
Pools never see each other's items, and clearing a pool deletes only its
own prefix. Environments use separate databases. Pools today:

- `cache.app`. In prod, Doctrine's result cache pool is also based on
  `cache.app`; no query uses the result cache.
- In the test environment only: `test.cache.pool_a` and `test.cache.pool_b`,
  which prove the isolation.

### TTL, expiry and invalidation

- The TTL is set per item (`ItemInterface::expiresAfter()`); without it, an
  item does not expire.
- An expired item is a miss; reading it deletes its row.
- Invalidation: delete the key (`delete()`), or clear a whole pool
  (`bin/console cache:pool:clear <pool>`, which deletes only that pool's
  rows).
- `bin/console cache:pool:prune` deletes the expired items of every pool.
  Nothing runs it on a schedule yet, so items that expire without being
  read again stay in the table until it runs.
- The cache shares Doctrine's connection. A write inside an open Doctrine
  transaction is committed or rolled back with that transaction.

### Keys and cached data

- Keys with the reserved characters `{}()/\@:` are rejected, so a key built
  from request input cannot reach into another namespace.
- Rules for cache users: never build keys from raw request input without
  validation, and never cache tenant data across requests where FCRM-003
  forbids it (the tenant resolver looks up memberships on every request).
- `cache_items` is not mapped by the ORM, and clearing or pruning a pool
  never touches another table.

### Database outages

Because the connection has a configured `server_version`, the adapter does
not need the database to detect the platform. When PostgreSQL is
unreachable, every read is a miss and every write is skipped, with a warning
on the `cache` log channel. The rest of the application needs the database
anyway.

### Locks

FCRM-003 lists locks next to the rate limiter for `cache_items`. Symfony's
Lock component does not store locks there: its `DoctrineDbalStore` uses its
own table and its `PostgreSqlStore` uses advisory locks without a table.
Neither the Lock component nor the rate limiter is installed yet; the
choice is made with the feature that needs them (the login throttling of
the authentication work stores its counters in a cache pool).

## Migration

`Version20261022100000` only adds `sessions` (with its index) and
`cache_items`; `down()` drops them. No existing table, constraint or row is
changed, and no credential changes. `make up` applies it to existing
development databases. Tests:

- from an empty database (BE-06), in sync with the schema (BE-07), and a
  full down/up round trip (BE-08);
- `SessionCacheMigrationTest`: in a throwaway database, up to the core
  schema, core rows inserted, then this migration up, down and up again,
  with the core rows unchanged each time.

## Security boundaries

- A session is not authentication. It stores data for a browser; who the
  user is, and whether a session counts as logged in, comes with the
  authentication work (firewall, login, CSRF token and Origin check).
- Sessions carry no tenant: the organization is always taken from the URL
  path and checked against an active membership on every request (FCRM-003
  section G). Adding session storage does not isolate tenants.
- PostgreSQL stays on the internal network; no port is published and no
  CORS setting changes.

## Tests

| Test | Proves |
|---|---|
| `backend/tests/Integration/Session/FpmSessionTest.php` | through a real PHP-FPM and the real database: stateless routes set no cookie and store nothing; the session ID has 128 bits and never appears in a body; cookie attributes over HTTP and HTTPS; idle expiry stored; data survives a PHP-FPM restart; unknown, malformed and expired IDs are replaced, never adopted; `migrate` deletes the old row; `invalidate` deletes the row and expires the cookie; two concurrent requests of one session do not lose an update; without the database only session routes fail, as problem documents without details; no session ID in PHP-FPM output |
| `backend/tests/Integration/Session/PdoSessionHandlerTest.php` | the configured handler: transactional lock mode on its own connection; write, read and destroy, including binary data; unknown and expired IDs invalid; garbage collection deletes only expired rows; a second request waits for the lock; **negative control:** without the lock an update is lost |
| `backend/tests/Integration/Cache/DatabaseCacheTest.php` | `cache.app` is `DoctrineDbalAdapter`; items in `cache_items` with their TTL; hit, expiry, deletion; namespaces of two pools isolated; clearing touches no other table; prune removes only expired items; reserved key characters rejected; an unreachable database gives logged misses |
| `backend/tests/Integration/Configuration/SessionAndCacheConfigurationTest.php` | the session options of dev, test and prod |
| `backend/tests/Integration/Database/SessionCacheMigrationTest.php` | the migration keeps existing data, up and down |
| `tests/app/backend.sh` BE-14 | dev and prod use `PdoSessionHandler`, `DoctrineDbalAdapter` and the seed `flowcrm`; the test-only session routes exist in the test environment only |
| `tests/app/stack.sh` ST-44, `tests/app/prodlike.sh` PL-14 | through the edge, in development and production mode: stateless requests set no cookie and store no session; the tables exist after `make up` |

The session tests use `SessionProbeController`
(`backend/tests/Support/Session`), test-only routes under `/api/_test/session`
that are registered only in the test environment. `tests/` is not mounted in
the development stack and is removed from the production image.

These configuration changes each fail the tests named: lock mode
`LOCK_NONE`; `HttpOnly` off; `SameSite=None`; the native file handler
instead of PostgreSQL; a 24-hour idle timeout; the prod cookie without the
`__Host-` prefix; a filesystem `cache.app`; `Secure` never set; the
migration removed (BE-07 and the session and cache tests).

## Known limitations

- No scheduled `cache:pool:prune`: expired cache items that are never read
  again stay until it runs.
- Garbage collection of sessions is probabilistic. On a quiet system,
  expired rows stay longer, but they can never be used.
- The 8-hour absolute timeout, login, logout, CSRF and login throttling come
  with the authentication work.
- Sessions and cache use the application's database role. Separate roles
  are an open decision (see [data model](data-model.md#not-included-yet)).
