# ADR-018: Database roles and runtime privileges

- **Status:** accepted (FCRM-FND-009)
- **Related:** FCRM-003 section F ("owner and app database roles"), FND-007
  (audit log), FND-008 (sessions and cache), ADR-005, ADR-007

## Context

Until FND-009 the API, the migrations, the sessions and the cache all
connected as `flowcrm`, the superuser the PostgreSQL image creates. A
superuser bypasses every safeguard: as that user, `SET
session_replication_role = replica` disables the append-only trigger of
`audit_events`, and `COPY … FROM PROGRAM` runs operating-system commands in
the database container. One SQL injection in the API would have been enough
for both.

## Decision

### Three roles

| Role | Attributes | Owns / may | Used by |
|---|---|---|---|
| `flowcrm` | superuser (the image's `POSTGRES_USER`) | everything | only inside the db container, over the local socket: initialisation, `flowcrm-db-roles` |
| `flowcrm_owner` | LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, NOBYPASSRLS | owns schema `public` and every object in it | the one-off `migrate` job (Doctrine migrations, schema tooling) |
| `flowcrm_app` | LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, NOBYPASSRLS, **NOINHERIT**, no memberships | `CONNECT` on the database, `USAGE` on schema `public`, and the table privileges of the manifest | the API: Doctrine, sessions, cache |

Nobody gets privileges through PUBLIC: the database, schema `public`, its
objects and functions grant PUBLIC nothing. The maintenance databases
`postgres` and `template1` keep their contents but grant PUBLIC no CONNECT
or TEMPORARY, so the two application roles can log in to `flowcrm` only
(`template0` accepts no connections at all).

### Explicit privileges, default-deny

`backend/config/database/runtime-privileges.yaml` lists every table, view
and sequence of schema `public` with exactly the privileges `flowcrm_app`
holds on it:

| Object | flowcrm_app |
|---|---|
| `users`, `organizations`, `memberships`, `pipelines`, `pipeline_stages` | SELECT, INSERT, UPDATE, DELETE |
| `sessions` (row locking needs UPDATE), `cache_items` | SELECT, INSERT, UPDATE, DELETE |
| `audit_events` | **SELECT, INSERT** |
| `doctrine_migration_versions` | SELECT (readiness) |
| `schema_baseline` | none |

Never granted: TRUNCATE, REFERENCES, TRIGGER, MAINTAIN, grant options,
column privileges, EXECUTE on functions. The default privileges of
`flowcrm_owner` grant new tables, sequences and functions to nobody, so a
new object is invisible to the runtime until a migration grants it.

The migration that creates an object grants its privileges
(`Version20261023000000` for the tables of FND-007 and FND-008), and the
manifest lists it. `bin/console app:database:verify-privileges --runtime`
compares the live catalog with the manifest (owners, role attributes,
memberships, database and schema privileges, every object's privileges,
default privileges) and fails on any difference, including an object the
manifest does not list. Beyond schema `public` it also fails when
`flowcrm_app` could connect to another database, use or create in another
non-system schema, reach an object there, own anything, or hold parameter,
tablespace or foreign-server privileges, and when any role's default
privileges give it or PUBLIC anything. The system schemas (`pg_*`,
`information_schema`) keep PostgreSQL's built-in defaults and are not
inspected.

`make up` runs the check after the migrations. If it, or the role check
before it, fails, the stack is not served: an edge that was already running
is stopped (the database, its volume, the other containers and the saved
port are kept), `make status` reports `blocked` with the reason and `make
url` fails, until a `make up` passes every check.

### Bootstrap

`docker/db/flowcrm-db-roles` runs in the db container as the superuser over
the local socket (`pg_hba` trust inside the container only; every network
login needs SCRAM). Passwords come from the secret files
`/run/secrets/db_owner_password` and `db_app_password` (48 lowercase hex
characters, checked), reach psql through its environment (`\getenv`), never
a command line, and the session sets `log_statement = none` and
`log_min_error_statement = panic` and echoes no failing statement. Each
command runs in one transaction.

**Operation lifetime.** Ending `docker compose exec` on the host does not
end the process inside the container, so every changing command runs as a
named operation: `bin/devenv` passes an operation ID, the script records
its process and names its sessions `flowcrm-db-roles:<id>`
(`application_name`), and every transaction first takes one PostgreSQL
advisory lock, so changes never interleave; no lock is waited for longer
than 120 s (`lock_timeout`: the transaction then fails and rolls back). On
SIGINT or SIGTERM, `bin/devenv` cancels its operation (`flowcrm-db-roles
cancel <id>`: the script is ended, its sessions are terminated, an open
transaction rolls back) and waits, at most 30 s (the call at most 45 s),
until both are gone, before it releases the checkout lock. Every changing
command first ends the leftovers of earlier operations the same way and
refuses to change anything (exit 14) while one cannot be ended within
30 s; it holds the checkout lock, so they belong to an interrupted command,
for example one ended with SIGKILL. It also removes an interrupted backup's
dump and scratch database. No other session is touched.

**Protection before every change.** Before `bin/devenv` changes roles,
passwords, ownership or grants (role corrections, migrations, the upgrade,
a rotation or its abort), it records the security gate in
`.runtime/gate/security-gate` (atomic rename, readable by the edge), stops
a running edge and checks that it stopped; only then does the change start. A command that dies from
then on, even by SIGKILL, which runs no handler, leaves the stack blocked:
no edge serves, `make status` and `make url` report `blocked`, and a change
that commits later is still not served. The gate is removed only by a
command that finished with every check passed (credentials, roles,
migrations, runtime privileges); a rotation or abort then starts the edge
it had stopped, `make up` does so itself.

**The edge enforces the gate (FND-009E).** The gate directory is mounted
read-only into the edge (`/run/flowcrm-gate`). While the gate file exists,
the edge answers every request with 503 ("blocked by its security gate"),
except exactly `/health/live` and `/health/ready` (raw request URI, as in
ADR-017), so its own health check and the readiness check through it still
work and the gate never deadlocks a recovery. The gate is therefore a
runtime barrier, not only a record: an edge that mounts `.runtime/gate`
serves nothing else while the gate is recorded, whatever happened to the
command that recorded it. Only `bin/devenv` mounts it: every Compose call
it makes sets `FLOWCRM_GATE_DIR` to `.runtime/gate`. Without that variable
the edge mounts the empty `docker/edge/no-gate` (the production-like and
test stacks, which `bin/devenv` does not run), so an edge of the
development stack started directly with `docker compose up`, outside
`bin/devenv`, does not see the gate and does not enforce it. The
development stack is therefore started and recovered only through `make`
(`bin/devenv`); `make up` recreates a running edge that does not mount
`.runtime/gate` (for example one created before this mount existed)
instead of reporting it as running. The directory is 0755 and
the record 0644: an edge that could not read the gate would serve, so
`bin/devenv` checks, before it relies on the barrier, that the edge
answers `/` with the gate's 503. `make up` changes nothing
needlessly: it first checks, read-only, whether the role attributes and
privileges need corrections (the corrections run in a transaction that is
always rolled back, and catalog fingerprints are compared), and protects
the stack only if they do or a migration is pending. A failing migration
therefore leaves a running stack blocked until a `make up` succeeds.

When the cancellation cannot be confirmed (the db container cannot be
reached, or the old script does not end in time), the old operation may
still commit later. The command then fails closed: it records the
unresolved state for `make status` and `make url` (`blocked`) and stops a
running edge. Only a `make up` that has ended the old operation, or found
it finished (committed or rolled back), and passed the role and privilege
checks serves the stack again. A rotation whose password change committed
late is finished with `make db-rotate-password` (the pending file is
still there); a late-committed upgrade is completed by `make up` (pending
migrations, privilege check).

- **New volume:** the image's initdb hook (`10-flowcrm-roles.sh`) runs
  `flowcrm-db-roles init`: the two roles with their passwords, schema
  `public` owned by `flowcrm_owner`, the privileges above. The migrate job
  then creates the tables as the owner.
- **Every `make up`:** `flowcrm-db-roles ensure` corrects role attributes,
  memberships, database, schema and default privileges. It never changes a
  password or an owner, and it fails closed unless the roles are complete.

### Existing volumes: explicit upgrade

A volume created before FND-009 (one superuser account, every object owned
by it) is never converted silently. `make up` refuses it (exit 6) before
starting the API, and, because its role secrets do not exist yet, before
starting any container. The owner upgrades it explicitly:

```console
$ make db-upgrade-roles
```

1. Creates the two role secrets (only this command may do so for an
   existing volume) and stops a running api, web and edge.
2. Dumps the database (`pg_dump -Fc`), restores the dump into a scratch
   database and compares, original against copy: the schema (relations,
   columns, defaults, constraints, indexes, triggers with their enabled
   state, functions, ACLs), the contents of every table (row count and a
   hash over all rows), the migration history and the audit log. Any
   difference, or a comparison that cannot be computed, fails. The audit
   log must be intact in both: `audit_events` with both triggers enabled
   whenever its migration (`Version20261022000000`, FND-007) or a later
   one is recorded. A database from before that migration (for example
   one created at FND-004) legitimately has no audit log; the upgrade then
   runs that migration and the later ones as `flowcrm_owner`. A disabled or
   missing trigger, or a missing table despite the recorded migration,
   stops the upgrade with nothing changed. The scratch
   database is dropped. The verified dump is copied to
   `.runtime/backups/roles_upgrade_<UTC time>_<pid>.dump` (directory `0700`,
   file `0600`) and its SHA-256 checked against the verified one. Any
   failure stops here with nothing changed; an unverified dump is removed
   (from the container's tmpfs and, for a failed or damaged copy, from the
   host), a verified backup never.
3. `flowcrm-db-roles upgrade`, one transaction: creates the roles, moves
   schema `public` and its tables, views, sequences, functions and types to
   `flowcrm_owner` (explicitly per object type, never `REASSIGN OWNED`),
   applies the privileges, and checks that nothing in `public` is left with
   another owner. Indexes and triggers belong to their tables.
4. Runs the migrations as the owner (`Version20261023000000` grants the
   runtime privileges) and verifies the manifest.

Rows, the audit triggers, sessions, cache items and the migration history
are not touched. Running it again is safe: on a converted database it only
re-checks. An interruption leaves either the unchanged legacy database
(the conversion is one transaction) or a converted one whose pending
migration the next `make up` applies. The API can never fall back to the
superuser: its container has neither that password nor any setting that
names it.

States reported by `flowcrm-db-roles state`: `legacy` (no roles, everything
owned by the superuser), `complete` (both roles, everything in `public`
owned by `flowcrm_owner`), `inconsistent` (anything else). Only `complete`
is accepted by `make up`; `inconsistent` always needs an operator.

### Secrets

`.runtime/secrets/` (directory `0700`, files `0444`) holds `db_password`
(superuser), `db_owner_password`, `db_app_password` and `app_secret`. Each
container gets only what it needs: db the three database passwords (to
create or change the roles), the api `db_app_password` and `app_secret`, the
migrate job `db_owner_password` and `app_secret`. For a new volume all are
generated; for an existing one a missing or malformed role secret stops
`make up` and is never regenerated by it. The superuser password is not
rotated by this decision.

### Secret files and running containers

Compose secrets are bind mounts of the host files. A container keeps the
file it was started with: when a file is replaced on the host (rotation,
restore from a backup), a running container sees it as **missing** on
Docker Desktop (observed on macOS, 29.x) and keeps the **old** file on
Linux (the bind mount pins the replaced inode; stack test ST-50 prints the
observed behaviour of each run). `make up`, the upgrade and the rotation
therefore compare the SHA-256 of every secret the running `db` and `api`
mount with the host file and recreate a container whose mount differs (no
value is printed). Restoring a secret from a backup is followed by `make up`.

A recreation counts only when it is checked: `docker compose up --wait`
alone is not proof. Compose 2.38 on Linux was seen to exit 0 when its wait
timeout expired while the new container was still starting (FND-009S, about
one in five recreations of an api that never got healthy). After Compose
returns, devenv therefore requires a new container (another ID) that is
`healthy` and mounts the current secret files; otherwise the command fails
with exit 2 and the security gate stays, so the edge does not serve.

### Rotation (development only)

```console
$ make db-rotate-password ROLE=app           # or ROLE=owner; run again to finish an interrupted one
$ make db-rotate-password-abort ROLE=app     # undo an unfinished rotation
```

A state machine whose state is the files in `.runtime/secrets`:

| State | Files | Database |
|---|---|---|
| start | current `db_<role>_password` | current password |
| 1 pending | plus `.db_<role>_password.pending` (`0600`, never mounted) | either password |
| 2 database | pending | the pending password (set by the superuser from standard input) |
| 3 login | pending | a SCRAM login with it succeeded (over TCP; a wrong password is refused first) |
| 4 promoted | pending replaced the current file (atomic `mv`, `0444`) | pending = current |
| 5 refreshed | `db` and `api` recreated because they mount the replaced file; each new container checked: healthy and mounting the current file | |
| 6 verified | the api's own connection (app) or the migrate job (owner) logged in; privileges match | |
| 7 served | an edge that was serving before is started while the gate is still recorded: first a one-off container of the edge service (no published port) must show that its image has the gate rule and can read the gate; the started edge must answer `/` with the gate's 503 and `/health/ready` with this stack's 200; only then is the gate cleared | |

- Interrupted (SIGINT, SIGTERM) or failed in states 1-3: the pending file
  is kept. `make db-rotate-password ROLE=…` finishes the rotation with it;
  `make db-rotate-password-abort ROLE=…` sets the database back to the
  current password, checks the login and removes the pending file. Both
  work whatever the database has at that moment, because the superuser sets
  the password; neither needs the old one, and nothing is left read-only.
  While the database has the pending password and the files the current
  one, the api cannot log in (readiness 503) until one of the two runs.
- Interrupted or failed after state 4 (for example the api does not get
  healthy again, whatever Compose's exit status says): the command exits 2,
  the stack stays blocked and the edge does not serve; the password and the
  file agree; `make up` recreates the containers that still mount the old
  file, after the cause is fixed.
- Interrupted in state 7, by any signal including SIGKILL: the gate is
  still recorded. Before the edge started, nothing listens; after it
  started, it serves only its health paths, because the pre-start check
  proved that its image enforces the gate and can read it (a rotation does
  not build images: an edge image from before the rule is refused, and
  `make up` rebuilds it). `make status` and `make url` report `blocked`.
  `make up` runs every check again, clears the gate once they passed, then
  keeps or starts the edge and requires it to answer readiness (exit 2
  otherwise). Running it again is safe at any point.
- Verified, but the edge does not serve again (state 7; for example the api
  is not ready): the command exits 2, the edge it started is stopped (not
  removed), and the security gate is recorded again with the reason, so
  nothing is served and `make status` reports the stack as blocked. The
  password change itself is complete and verified; `make up` serves once the
  cause is fixed. If the started edge cannot be stopped either, the command
  still fails with the original reason and says so; it says that the edge
  is blocked only when it saw the edge answer with the gate's 503, and
  otherwise asks to stop the stack with `make down` (which removes the
  containers and keeps the volumes).
- A password change waiting inside PostgreSQL when the command is
  interrupted is cancelled and rolled back (operation lifetime, above).
- Passwords are never printed or passed on a command line; nothing falls
  back to another role; the superuser password is not rotated.

Clients fail while the database and the api are recreated: there is no
zero-downtime rotation.

## Recovery

| Situation | `make up` | What to do |
|---|---|---|
| legacy volume | exit 6, nothing started | `make db-upgrade-roles` |
| role secret missing or malformed | exit 6, nothing generated | restore the file from a backup and run `make up` (it recreates containers that mount the replaced file), or `make db-rotate-password ROLE=…` (needs a complete database) |
| runtime password does not match (stale file, or the role changed its own password) | exit 6 after the migrations (login fails in the privilege check), edge stopped | `make db-rotate-password ROLE=app` |
| privileges differ from the manifest | exit 6, violations listed, edge stopped, `make status` reports `blocked` | fix the migration or the manifest; correct grants as `flowcrm_owner`; `make up` |
| rotation interrupted or failed | depends on the state (see Rotation) | `make db-rotate-password ROLE=…` again, or `make db-rotate-password-abort ROLE=…`; after the file was replaced: `make up` |
| interrupted database operation could not be confirmed as ended | warning, edge stopped, `make status` reports `blocked` | `make up` once the db container is reachable: it ends the old operation (or finds it finished) before changing anything, and checks every gate; after a late password change, `make db-rotate-password ROLE=…` finishes the rotation |
| `inconsistent` roles (for example an object in `public` owned by another role) | exit 6, nothing changed | inspect with `docker compose exec db flowcrm-db-roles state` and `psql`; move the object to `flowcrm_owner` or out of `public` by hand |
| failed or interrupted upgrade | legacy: exit 6; converted: migrates | run `make db-upgrade-roles` again (an interrupted conversion was rolled back before the command exited); the backup in `.runtime/backups/` restores the previous state (`pg_restore` into a new database) |

**Rollback** without data loss: restore the pre-upgrade backup into a new
volume, or, on the converted database, give the objects back to `flowcrm`
by hand. There is no switch back to a superuser API.

Persistent volumes: no command of this decision deletes or recreates a
volume or drops data. Keep `.runtime/secrets/` and `.runtime/backups/` with
the volume.

## Audit-event protection and its limits

| Actor | UPDATE, DELETE, TRUNCATE `audit_events` | Disable the triggers |
|---|---|---|
| `flowcrm_app` | refused by privilege, and by the trigger | refused (not the owner; `session_replication_role` needs a superuser) |
| `flowcrm_owner` | refused by the trigger | **possible** (`ALTER TABLE … DISABLE TRIGGER`, as owner) |
| `flowcrm`, Docker administrators | anything | anything |

The separation protects the audit log against the application: a bug or an
injection in the API cannot change history. The superuser, the schema owner
and anyone with Docker access to the host remain trusted actors; against
them this is not a tamper-proof audit system (that would need, for
example, hash-chained or off-host records).

## Consequences

- The application runs with least privilege; a compromised API cannot
  change the schema, the audit history or its own privileges, run programs
  or read files of the database server.
- Each migration that creates an object must grant its runtime privileges
  and list it in the manifest; otherwise `make up` and the tests fail.
- One more container type (the one-off `migrate` job, never long-running)
  and two more secret files.
- Existing development volumes need one explicit `make db-upgrade-roles`.
- At most three connections per PHP-FPM worker (default, sessions, cache)
  as `flowcrm_app` (connection limit 64); `flowcrm_owner` is limited to 10.

## Verification

- `backend/tests/Integration/Database/RuntimePrivilegesTest.php`: as
  `flowcrm_app` over SCRAM, the allowed operations work and 25 privileged
  operations are refused with PostgreSQL's own message (audit UPDATE,
  DELETE, TRUNCATE, LOCK, trigger disabling, `session_replication_role`,
  DDL, temporary tables, schemas, extensions, `SET ROLE`, role changes,
  `COPY PROGRAM`, server files, the trigger function, `schema_baseline`,
  the migration history); GRANT has no effect; its password opens no other
  role.
- `OwnerRoleTest.php`: DDL works, new objects give the runtime nothing, no
  superuser powers, and the documented trigger limit.
- `RuntimePrivilegesTest.php` also: no login to `postgres` or `template1`.
- `RuntimePrivilegesVerifierTest.php`: 31 weakenings (extra, missing,
  PUBLIC, grant-option and column privileges, unclassified objects, default
  privileges of any role, schema and database privileges, foreign owners,
  role attributes, memberships including predefined roles, grants in other
  schemas, objects owned by the runtime role, maintenance databases,
  parameter privileges) are each reported.
- `HttpEndpointsTest.php`: an unreadable database credential makes
  `/health/ready` answer 503, not 500.
- `CoreSchemaTest.php`: the runtime role is refused audit changes by
  privilege, the owner by the trigger.
- `tests/app/backend.sh` BE-06 to BE-08 (migrations as the owner), BE-16
  (manifest as the runtime role), BE-17 (who gets which secret).
- `tests/app/stack.sh` ST-47 to ST-58: the api's role and secrets;
  privilege drift on a running stack stops the edge; missing and malformed
  secrets fail closed, also with the former environment switch set;
  rotation interrupted (SIGTERM) after each state and while its transaction
  waits on a lock, then finished or aborted, for both roles, a failed api
  recreation, repeated rotations; a volume created exactly as before
  FND-009 is refused; an upgrade interrupted after the backup and while an
  `ALTER TABLE` waits on a real lock (SIGTERM, SIGINT, a cut connection)
  leaves it unchanged (no later commit); a cancellation that cannot be
  confirmed (db container paused, old script not ending) blocks the stack;
  SIGKILL of `bin/devenv` while `ALTER ROLE … PASSWORD` or `ALTER TABLE …
  OWNER` waits, and after a committed but unverified change, finds the edge
  already stopped and the stack blocked, and the next command ends the old
  operation first (no delayed commit) or completes the verification,
  and the next command ends the old operation first or refuses; a foreign
  holder of the advisory lock cannot make `make up` wait forever;
  a backup that does not restore, differs in its contents or is damaged on
  the host stops the upgrade without leaving a dump; the upgrade keeps every
  row, the triggers and the history; an unreadable credential gives 503
  through the edge.
- `tests/app/prodlike.sh` PL-15: migrations as the owner before the api.
