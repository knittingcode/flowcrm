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
objects and functions grant PUBLIC nothing.

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
manifest does not list. `make up` runs it after the migrations and publishes
nothing if it fails.

### Bootstrap

`docker/db/flowcrm-db-roles` runs in the db container as the superuser over
the local socket (`pg_hba` trust inside the container only; every network
login needs SCRAM). Passwords come from the secret files
`/run/secrets/db_owner_password` and `db_app_password` (48 lowercase hex
characters, checked), reach psql through its environment (`\getenv`), never
a command line, and the session sets `log_statement = none` and
`log_min_error_statement = panic` and echoes no failing statement. Each
command runs in one transaction.

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
   database, compares every table's row count, the migration history and
   the triggers, and drops the scratch database. The dump is copied to
   `.runtime/backups/roles_upgrade_<UTC time>.dump` (directory `0700`, file
   `0600`) and its SHA-256 checked against the verified one. Any failure
   stops here with nothing changed.
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

### Rotation (development only)

```console
$ make db-rotate-password ROLE=app     # or ROLE=owner
```

Writes a new secret atomically (the previous one is kept until the new
password is set), recreates the db container so it reads the new file (a
Compose secret is a bind mount, which keeps showing the old file after an
atomic replace), sets the password, and recreates the api (`app`) or runs
the migrate job (`owner`) to prove the login. If setting the password
fails, the previous file is restored and nothing changed. If a later step
fails, the password has changed and `make up` completes the restart.
Clients fail for a few seconds while the database restarts: there is no
zero-downtime rotation.

## Recovery

| Situation | `make up` | What to do |
|---|---|---|
| legacy volume | exit 6, nothing started | `make db-upgrade-roles` |
| role secret missing or malformed | exit 6, nothing generated | restore the file from a backup, or `make db-rotate-password ROLE=…` (needs a complete database) |
| runtime password does not match (stale file, or the role changed its own password) | exit 6 after the migrations (login fails in the privilege check) | `make db-rotate-password ROLE=app` |
| privileges differ from the manifest | exit 6, violations listed | fix the migration or the manifest; correct grants as `flowcrm_owner` |
| `inconsistent` roles (for example an object in `public` owned by another role) | exit 6, nothing changed | inspect with `docker compose exec db flowcrm-db-roles state` and `psql`; move the object to `flowcrm_owner` or out of `public` by hand |
| failed or interrupted upgrade | legacy: exit 6; converted: migrates | run `make db-upgrade-roles` again; the backup in `.runtime/backups/` restores the previous state (`pg_restore` into a new database) |

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
- `RuntimePrivilegesVerifierTest.php`: 21 weakenings (extra, missing,
  PUBLIC, grant-option and column privileges, unclassified objects, default
  privileges, schema and database privileges, foreign owners, role
  attributes, memberships) are each reported.
- `CoreSchemaTest.php`: the runtime role is refused audit changes by
  privilege, the owner by the trigger.
- `tests/app/backend.sh` BE-06 to BE-08 (migrations as the owner), BE-16
  (manifest as the runtime role), BE-17 (who gets which secret).
- `tests/app/stack.sh` ST-47 to ST-53: the api's role and secrets; privilege
  drift, missing and malformed secrets fail closed; rotation of both
  passwords; a volume created exactly as before FND-009 is refused, upgraded
  with a verified backup and keeps every row, triggers and its history.
- `tests/app/prodlike.sh` PL-15: migrations as the owner before the api.
