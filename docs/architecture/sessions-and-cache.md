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
only when a session starts, gives up connecting after 5 seconds
(`connect_timeout`), waits at most 5 seconds for a lock (`lock_timeout`,
set on this connection only) and shows up as `flowcrm_sessions` in
`pg_stat_activity`. Its lock transaction (below) therefore never mixes with
Doctrine's transactions.

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

Both sides of the wait are bounded:

- **The waiting request** gives up after 5 seconds (`lock_timeout` of the
  session connection). It gets a 500 problem document without details,
  with its request ID. The session is kept: when the read fails while PHP
  validates the ID, Symfony's `AbstractSessionHandler::validateId()` keeps
  the ID (rather than reporting it invalid, which would make PHP issue a new
  ID) and lets the failure surface from `read()`. PHP may send the session
  cookie again, but only with the same ID and the same attributes, and other
  cookies are unaffected. The connection closes with the request, which
  rolls its transaction back. The next request of the session works
  normally. PHP's own time limit does not help here: it counts CPU time,
  not time spent waiting for PostgreSQL.
- **The lock holder:** PHP-FPM kills a worker that is still busy after 60
  seconds (`request_terminate_timeout` in `docker/api/php-fpm.conf`). Its
  connections close, PostgreSQL rolls back its transaction and the lock is
  released; the killed request's session changes are not saved.

Neither bound lets an update be lost: a request that cannot get the lock
fails instead of writing.

### Database outages

Requests that do not use the session are unaffected. An `/api` request that
uses the session fails with a 500 problem document without details; the
connection attempt is abandoned after 5 seconds.

### Connections

A PHP-FPM worker opens at most three connections, each only when needed:
Doctrine's default connection, the session connection and the cache
connection. With `pm.max_children = 8`, the API uses at most 24 of
PostgreSQL's default 100 connections (plus console commands).

### Logs

The log redactor masks values under the keys `session`, `sid`, `sess_id`,
`sess_data`, `cookie` and `set-cookie`, keys containing `session`, `cookie`
or `sessid` (such as `PHPSESSID`), and keys ending in `_sid` or `-sid`, such
as the cookie names `flowcrm_sid` and `__Host-flowcrm_sid`, in any letter
case and at any depth. The edge masks `Cookie` request headers (ST-43). The
PHP-FPM tests check that no session ID appears in PHP-FPM or PHP error
output. Values written into free text (messages, exception texts) are not
covered by key-based redaction; code must not put session IDs there.

## Cache

### Adapter choice

FCRM-003 section F names `cache_items`, managed by Symfony's Doctrine DBAL
cache adapter, and ADR-007 rules out Redis. `cache.app` and every pool based
on it therefore use `DoctrineDbalAdapter`. `cache.system` (compiled
container, routing and validation metadata) stays on the local filesystem
of the container: it is rebuilt from the code and must not depend on the
database.

The adapter runs on its own DBAL connection, `cache` in
`config/packages/doctrine.yaml`: the same database and credentials as the
default connection, `application_name` `flowcrm_cache`, opened only when the
cache is used. Two reasons:

- **Transactions:** a cache query that fails (for example on a missing
  table) would abort an open transaction of the connection it runs on, and
  every later query of that business transaction would fail with SQLSTATE
  25P02. On its own connection, a cache failure is a logged miss and the
  business transaction goes on.
- **Schema ownership:** the adapter creates `cache_items` itself when the
  table is missing. The `RejectSchemaChanges` middleware, registered for
  the `cache` connection only, rejects `CREATE`, `ALTER`, `DROP` and
  `TRUNCATE` there, so the attempt fails (a logged miss) and the table
  exists only once its migration has run. The guard is intentionally narrow:
  it matches statements that start with those keywords, which covers the
  adapter's own `CREATE TABLE`. Other forms (leading comments, several
  statements in one string, `SELECT ... INTO`, `DO` blocks) pass; it is not
  a defence against hostile SQL, which would need database privileges.

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
- Cache writes are not part of Doctrine transactions: they are committed
  on the cache connection at once, even if the business transaction rolls
  back later.

### Keys and cached data

- Keys with the reserved characters `{}()/\@:` are rejected, so a key built
  from request input cannot reach into another namespace.
- Rules for cache users: never build keys from raw request input without
  validation, and never cache tenant data across requests where FCRM-003
  forbids it (the tenant resolver looks up memberships on every request).
- `cache_items` is not mapped by the ORM, and clearing or pruning a pool
  never touches another table.

### Database outages

Because the cache connection has a configured `server_version`, the adapter
does not need the database to detect the platform. When PostgreSQL is
unreachable, every read is a miss and every write is skipped, with a warning
on the `cache` log channel; no stale value is returned. The rest of the
application needs the database anyway.

### Locks

FCRM-003 lists locks next to the rate limiter for `cache_items`. Symfony's
Lock component does not store locks there: its `DoctrineDbalStore` uses its
own table and its `PostgreSqlStore` uses advisory locks without a table.
Neither the Lock component nor the rate limiter is installed yet; the
choice is made with the feature that needs them (the login throttling of
the authentication work stores its counters in a cache pool).

## Migration

`Version20261022100000` creates `sessions` (with `sess_lifetime_idx`) and
`cache_items`; `down()` drops them. No other table, constraint or row is
changed, and no credential changes. `make up` applies it to existing
development databases (in development after the containers start, as every
migration; in the production-like stack before PHP-FPM starts). Because the
cache cannot create its table (see above), the order does not matter: a
cache write before the migration is a logged miss.

### Existing tables

The migration only creates tables; it never adopts one. If a relation
named `sessions`, `cache_items` or `sess_lifetime_idx` already exists in
the schema (a table of any definition, a view, an index), it aborts before
any change with:

```text
Not migrating: cache_items already exist(s) in schema "public"; this migration only creates new tables. ...
```

Migrations run all-or-nothing in one transaction, so nothing is created,
dropped or altered, the version is not recorded, `make up` fails with exit
2 and keeps its saved state, and `/health/ready` stays 503 (pending
migration).

Such a table can only come from outside this project's code: created by
hand, or by the cache adapter of a build before the cache connection
refused schema changes. Comparing it with the expected definition reliably
would mean checking columns, collations, constraints, indexes, triggers,
ownership and persistence, so there is no automatic adoption.

Nothing in the project (migrations, `make up`, container start) adopts,
deletes or rewrites such a relation, and a failed migration leaves its data
as it was. Recovery is a manual operator task:

1. **Identify the database.** Run every command against the database of
   the environment that failed, and confirm it first. For a development
   checkout, `make status` prints the Compose project (for example
   `flowcrm-1d1ca1`); then, from the checkout directory:

   ```console
   $ docker compose -p flowcrm-1d1ca1 exec db psql -U flowcrm -d flowcrm -c 'SELECT current_database(), current_schema()'
   ```

2. **Inspect** the relation (`\d+ cache_items`, row count) and decide whether
   its rows matter. Cache rows are disposable; session rows only keep users
   signed in.
3. **Back it up and prove the backup restores**, before any change:

   ```console
   $ docker compose -p flowcrm-1d1ca1 exec -T db pg_dump -U flowcrm -d flowcrm -Fc -t cache_items >cache_items.dump
   $ docker compose -p flowcrm-1d1ca1 exec -T db createdb -U flowcrm flowcrm_restore_check
   $ docker compose -p flowcrm-1d1ca1 exec -T db pg_restore -U flowcrm -d flowcrm_restore_check <cache_items.dump
   $ docker compose -p flowcrm-1d1ca1 exec db psql -U flowcrm -d flowcrm_restore_check -c 'SELECT count(*) FROM cache_items'
   ```

   The count must match the original. Keep the dump outside the database
   volume; `flowcrm_restore_check` is a separate scratch database that
   holds only the restored copy.
4. **Rename, never drop**, the relation and its indexes, so the migration
   can create fresh tables and the existing rows stay in place:

   ```sql
   ALTER TABLE cache_items RENAME TO cache_items_preexisting;
   ALTER INDEX cache_items_pkey RENAME TO cache_items_preexisting_pkey;
   ```

   (for `sessions`: `sessions_pkey` and `sess_lifetime_idx`).
5. **Run `make up` again.** The migration creates the new tables.
6. **Leave the renamed table until an operator decides.** Removing it, or
   the scratch restore database, is a separate, explicitly authorized step
   once its data is confirmed to be no longer needed and the backup is
   verified. Until then `doctrine:schema:validate` reports it as a table
   the mapping does not know: renaming does not make schema validation
   pass, and neither does moving it to another schema of the same
   database, because Doctrine inspects every schema.

If any step cannot be done safely (the database is not certain, the backup
does not restore, the data may matter), stop and ask the operator; never
run `DROP TABLE` against persistent development or production data as
part of a recovery script.

An interrupted migration (process killed, connection lost) is rolled back
by PostgreSQL and can simply be run again.

Tests:

- from an empty database (BE-06), in sync with the schema (BE-07), and a
  full down/up round trip (BE-08);
- `SessionCacheMigrationTest`, each case in a throwaway database: core rows,
  including an audit event and the audit triggers, unchanged by up, down and
  up; a second run changes nothing; a cache write before the migration
  creates no table (and, as a control, does without the middleware); twelve
  existing relations (tables identical to the expected ones, and tables with
  an extra CHECK, foreign key, user trigger, UNIQUE constraint or index, a
  case-insensitive collation, UNLOGGED, another owner; a view; an index of
  that name elsewhere), each stopping the migration with its own message
  and leaving the whole catalog and the stored rows unchanged; the rename
  recovery; a migration killed while waiting inside its transaction leaves
  nothing and runs again;
- ST-45 and ST-46: an existing table and the rename recovery through
  `make up` on the running stack.

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
| `backend/tests/Integration/Session/FpmSessionTest.php` | through a real PHP-FPM and the real database: stateless routes, with and without a session cookie, answer at once while the sessions table is exclusively locked, set no cookie and store nothing; the session ID has 128 bits and never appears in a body; cookie attributes over HTTP and HTTPS; idle expiry stored; data survives a PHP-FPM restart; unknown, malformed and expired IDs are replaced, never adopted; `migrate` deletes the old row; `invalidate` deletes the row and expires the cookie; two concurrent requests of one session do not lose an update; a request waiting for a locked session fails after 5 s with a problem document and its request ID, keeps the session ID (any `Set-Cookie` repeats the same ID and attributes) and other cookies, closes its connection, and the session continues afterwards; a worker past `request_terminate_timeout` is killed and releases the lock; without the database only session routes fail, as problem documents without details; no session ID in PHP-FPM output |
| `backend/tests/Integration/Session/PdoSessionHandlerTest.php` | the configured handler: transactional lock mode on its own connection; `lock_timeout` 5 s on the session connection only; write, read and destroy, including binary data; unknown and expired IDs invalid; garbage collection deletes only expired rows; a second request waits for the lock; **negative control:** without the lock an update is lost |
| `backend/tests/Integration/Session/FpmServerTest.php` | the harness: a request without an answer fails at its deadline with diagnostics and its client process is killed; stopping ends the master and every worker; the master leads a process group of its own; the workers of a master killed from outside are still found and stopped |
| `backend/tests/Integration/Cache/DatabaseCacheTest.php` | `cache.app` is `DoctrineDbalAdapter`; items in `cache_items` with their TTL; hit, expiry, deletion; namespaces of two pools isolated; clearing touches no other table; prune removes only expired items; reserved key characters rejected; an unreachable database gives logged misses |
| `backend/tests/Integration/Cache/CacheConnectionTest.php` | the cache's own lazy connection; it refuses `CREATE`, `ALTER`, `DROP` and `TRUNCATE`, the default connection does not; a cache failure leaves a business transaction intact; **negative control:** on the default connection it aborts it (25P02) |
| `backend/tests/Integration/Configuration/SessionAndCacheConfigurationTest.php` | the session options of dev, test and prod |
| `backend/tests/Integration/Database/SessionCacheMigrationTest.php` | the migration keeps existing data, up and down |
| `tests/app/backend.sh` BE-14 | dev and prod use `PdoSessionHandler`, `DoctrineDbalAdapter` and the seed `flowcrm`; the test-only session routes exist in the test environment only |
| `tests/app/backend.sh` BE-15 | the PHP-FPM configuration of the image ends requests after 60 s |
| `tests/app/stack.sh` ST-44, `tests/app/prodlike.sh` PL-14 | through the edge, in development and production mode: stateless requests set no cookie and store no session; the tables exist after `make up` |
| `tests/app/stack.sh` ST-45, ST-46 | `make up` with an existing `cache_items` (identical to the expected one) fails, changes nothing and keeps its saved state; after renaming it by hand, `make up` migrates and the renamed table keeps its rows; the schema is valid once it is dropped |

The session tests use `SessionProbeController`
(`backend/tests/Support/Session`), test-only routes under `/api/_test/session`
that are registered only in the test environment. `tests/` is not mounted in
the development stack and is removed from the production image.

Each of these changes fails the tests named (run on copies of the code):

| Change | Fails |
|---|---|
| lock mode `LOCK_NONE` | the concurrency and lock tests |
| `HttpOnly` off, `SameSite=None`, `Secure` never set | the cookie tests and the configuration test |
| the native file handler instead of PostgreSQL | the handler tests |
| a 24-hour idle timeout; the prod cookie without `__Host-` | the configuration test (and the lifetime test) |
| a filesystem `cache.app` | the cache tests |
| the migration removed | BE-07 and the session and cache tests |
| no `lock_timeout` on the session connection | the lock-wait test (fails at the harness deadline instead of hanging) and the lock-timeout scope test |
| a session handler that reports a failed read as an invalid ID (so PHP issues a new one) | the lock-wait test (the request then gets a new, empty session) |
| no `request_terminate_timeout` | BE-15 |
| the schema guard disabled | the guard and transaction-isolation tests |
| the guard without its connection scope | the test that the default connection is not restricted |
| the migration without its existence check, silently skipping existing tables, or adopting tables whose columns match (the earlier version) | the existing-relation tests |
| the harness finding workers by parent PID | the test for workers of a master killed from outside |
| `cache.app` on the default connection | the dedicated-connection test |
| no redaction of `*_sid` keys | the redaction tests for the cookie names |
| a listener that starts the session on every request | the stateless-route test |
| no deadline in the FastCGI harness | the harness deadline test |

## Prerequisites for the authentication work

Login, logout, CSRF and throttling are not part of this infrastructure. When
they are built:

- Start the session before migrating or invalidating it. `migrate()` and
  `invalidate()` silently do nothing on a session that has not started;
  Symfony's firewall starts it when a session cookie is present, code that
  migrates on its own must call `start()` first. Login must migrate (new ID,
  old row deleted); logout must invalidate.
- Store the login time in the session and enforce the absolute timeout of 8
  hours (FCRM-003); the idle timeout is already enforced.
- Keep request handlers that use the session short: requests of one session
  run one after another and wait at most 5 seconds for each other.
- Login throttling stores counters in a cache pool on the `cache`
  connection; the pool must be based on `cache.app` (or another
  `DoctrineDbalAdapter` on that connection).
- Never cache authorization or membership decisions across requests
  (FCRM-003: the tenant resolver checks the membership on every request).
- Verify `Secure` and the `__Host-` prefix in a real browser over HTTPS (see
  below); no environment here terminates TLS.

## Known limitations

- No scheduled `cache:pool:prune`: expired cache items that are never read
  again stay until it runs.
- Garbage collection of sessions is probabilistic. On a quiet system,
  expired rows stay longer, but they can never be used.
- The 8-hour absolute timeout, login, logout, CSRF and login throttling come
  with the authentication work.
- Sessions and cache use the application's database role. Separate roles
  are an open decision (see [data model](data-model.md#not-included-yet)).
- `sess_lifetime`, `sess_time`, `item_lifetime` and `item_time` are 32-bit
  `INT` columns, as Symfony's components define them; Unix times exceed them
  in January 2038. This follows the framework's schema and is tracked
  upstream.
- How browsers treat the `Secure` `__Host-flowcrm_sid` cookie over HTTPS is
  not verified end to end: the stacks here run over plain HTTP, and the
  production-like stack does not use sessions.
