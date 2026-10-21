# Development lifecycle contract

This document defines the interface between the development lifecycle
(`Makefile`, `bin/devenv`) and the Docker Compose stack it starts. Today the
stack is a development fixture (`compose.fixture.yaml`: a BusyBox HTTP server
and a helper with a named volume). It is **not** a CRM application. The
contract states what the application stack approved in the FCRM-003
architecture must provide when FND-004 implements it, so that it can replace
the fixture without changing the developer commands or weakening the
allocator's guarantees.

Day-to-day usage is described in [dev-environment.md](../dev-environment.md).

## Approved application stack (FCRM-003)

These decisions are fixed; FND-004 implements them and does not revisit
them:

| Service | Role |
|---|---|
| `edge` | Caddy 2, the same-origin HTTP entry point and the only service with a published host port (on `127.0.0.1`). Serves the SPA, sends `/api` to the `api` service with `php_fastcgi`, and in development sends `/` to the Vite dev server `web:5173`. |
| `web` | Vite development server for the React + TypeScript SPA; exists only under the Compose `dev` profile. |
| `api` | Symfony modular monolith under PHP-FPM, running as a non-root user. |
| `db` | PostgreSQL with the named volume `db-data`, on the internal network only. |

- Networks: `edge` and `web` on `front`; `api` and `db` on `back`, which is
  `internal: true`.
- Production-like images serve the built SPA from the `edge` image; PHP
  requests still go to PHP-FPM.
- Health endpoints: `/health/live` (process only; for the edge and the API)
  and `/health/ready` (`SELECT 1` and migrations current). Neither returns
  details in its body. They are used by the Compose health checks and by the
  `make up` verification.
- Redis and RabbitMQ are not adopted (ADR-007).
- Project isolation follows ADR-009 (section 4).

Exact versions and image digests are pinned in FND-004.

## 1. Stable developer interface

These commands and their exit codes are the public interface and stay
backward compatible:

| Command | Contract |
|---|---|
| `make up` | start or reconcile; prints `…: http://127.0.0.1:<port>` and saves the verified port |
| `make down` | remove this checkout's containers and network; keep volumes and the saved port |
| `make restart` | `down` + `up`, saved port first |
| `make status` | exit 0 only if the edge runs, is healthy and matches the saved port |
| `make url` | print the verified URL; exit 1 when not running or mismatched |
| `make ports` | read-only port diagnostics |
| `make logs` | logs of this project (`SERVICE`, `TAIL`, `FOLLOW`) |
| `make doctor` | read-only prerequisite check |
| `make help` | list the targets |
| `make test-devenv` | allocator unit and real-Docker integration suites |

Exit codes of `bin/devenv`: 0 success, 1 not running, 2 Docker error other
than a port conflict, 3 no usable port, 4 lock not available, 5 missing
prerequisite, 6 safety refusal, 64 invalid configuration. `make` reports its
own status 2 for any failure. The configuration variables
`FLOWCRM_PORT_DEFAULT`, `FLOWCRM_PORT_RANGE`, `FLOWCRM_HTTP_PORT`,
`FLOWCRM_UP_TIMEOUT`, `FLOWCRM_WAIT_TIMEOUT` and `FLOWCRM_LOCK_WAIT` keep their
names, defaults and validation. The unit suite (U-14) pins the Makefile
targets and the commands they run.

## 2. Compose file

`bin/devenv` uses exactly one Compose file, `$ROOT/compose.fixture.yaml`,
passed with `--file`, and always sets `--project-name` and
`--project-directory`. FND-004 points this setting at the application's
Compose file; the file name is one of the constants in section 10. The
fixture file stays in the repository for the allocator tests (section 9).

Requirements for the application's Compose file:

- no fixed `container_name`, network `name` or volume `name` (they would
  collide between checkouts);
- no `ports:` on any service except the edge;
- every service has a `healthcheck`, because services are started with
  `docker compose up --wait`;
- the edge's port mapping is exactly
  `"${FLOWCRM_HTTP_BIND:-127.0.0.1}:${FLOWCRM_HTTP_PORT:?…}:<container port>"`;
  the `:?` form makes a plain `docker compose up` fail instead of creating an
  unmanaged project.

## 3. Internal services and the HTTP edge

Services are split into two groups:

- **Internal services** (fixture: `state`; application: `db` and `api`, plus
  `web` under the `dev` profile) publish no host port. They are started
  first with
  `docker compose up --detach --wait --wait-timeout $FLOWCRM_WAIT_TIMEOUT <services>`.
  Any failure here is never a port conflict: `up` stops with exit 2 and no
  port is retried.
- **The edge** (fixture: BusyBox `edge`; application: the Caddy 2 `edge`) is
  the only service with a published port, always on `127.0.0.1`. It is
  started with `--no-deps`, so trying another port recreates only the
  stateless edge and never `db`, `api` or `web`.

The edge owns the published HTTP port and serves the whole application on
one container port (8080 in FCRM-003), with the routing listed in the
approved stack above:

| Mode | `/api` | Other requests (`/`) |
|---|---|---|
| Development | `php_fastcgi` to `api` (PHP-FPM) | Vite dev server `web:5173` |
| Production-like | `php_fastcgi` to `api` (PHP-FPM) | built SPA assets served by the `edge` image |

FND-004 implements this Caddy configuration; it does not choose another edge
server or routing scheme. Using the `dev` profile for `web` in development is
part of the allocator configuration FND-004 adds (section 10).

## 4. Project names and isolation

The Compose project name is `flowcrm-` plus the first six hex digits of the
SHA-256 of the checkout's physical path. Each checkout or worktree therefore
has its own containers, network and volumes. Commands refuse (exit 6) when
`.runtime/dev.env` names another project or a container with this project
name belongs to another directory. Two checkouts started at the same time
end up on different ports because Docker's bind decides (PA-04).

## 5. Port selection and the runtime port

Candidates: the saved port, `FLOWCRM_PORT_DEFAULT`, then the rest of
`FLOWCRM_PORT_RANGE`; `FLOWCRM_HTTP_PORT` replaces the list with exactly one
port and never falls back. The chosen port reaches Compose only through the
environment variables `FLOWCRM_HTTP_PORT` and `FLOWCRM_HTTP_BIND` of the
`docker compose` process. A candidate is accepted only after Docker bound it,
`docker compose port` reports `127.0.0.1:<port>` and `GET /health` answers
200; only then is `.runtime/dev.env` written (atomically). A failed attempt
never replaces the saved, previously verified port. Only messages containing
`port is already allocated` or `address already in use` count as port
conflicts.

## 6. Readiness

Readiness has two levels:

1. Docker health: `up --wait` returns only when every started service is
   healthy.
2. HTTP: a `GET` of the readiness path on `127.0.0.1:<port>` through the
   published edge must answer `HTTP/1.x 200` (20 attempts, 0.5 s apart).

The two stacks use different paths:

- **Fixture (today):** `/health`, a static file served by the BusyBox edge.
  It only shows that the fixture's HTTP server answers; it does not
  implement the application health contract.
- **Application (FND-004):** the approved `/health/ready` (database reachable
  with `SELECT 1`, migrations current), requested through the Caddy edge,
  is the readiness path of the `make up` verification. `/health/live`
  (process only) serves the Compose health checks of the edge and the API.

The readiness path is one of the constants in section 10. FCRM-003 also
states that only `/api/*` reaches PHP at the edge; FND-004 has to make the
Caddy routing of `/health/*` consistent with that rule without changing the
approved endpoints (see section 11).

## 7. Persistent data

- No command removes volumes: there is no `down -v`, `volume rm` or prune in
  `bin/devenv` (statically checked by U-09). `make down` keeps volumes.
- Edge retries never touch internal services (`--no-deps`), so PostgreSQL
  data and connections survive port changes.
- PostgreSQL (`db`) is an internal service on the internal `back` network
  with the named volume `db-data`, published on no host port. Volume names
  are scoped by the project name, so checkouts never share a database.
- Deleting data is always an explicit developer action
  (`docker volume rm <project>_<volume>`).

## 8. Concurrency and process ownership

`up`, `down` and `restart` hold the per-checkout lock `.runtime/lock`. Each
mutating Compose call runs as the leader of its own process group, recorded
in `.runtime/lock/op` (PID, start identity, process group). The lock is
released only when the owner, the recorded leader and every member of its
process group (the Docker CLI and its Compose plugin) have ended; signals
are forwarded to that group. These guarantees do not depend on the stack and
apply unchanged to FND-004. Read-only commands (`status`, `url`, `ports`,
`logs`, `doctor`) take no lock.

## 9. Tests and CI

- The fixture and its tests (`tests/devenv/unit.sh`,
  `tests/devenv/integration.sh`, scenarios PA-01 to PA-23 and MK-01 to
  MK-12) stay in place and keep running in the `Dev environment` job until
  the application stack has equivalent coverage. They exercise the allocator
  independently of the application (each scenario copies the fixture into a
  temporary checkout).
- The integration suite selects the stack through the Compose file copied
  into its temporary checkouts; once the file name is configurable, the same
  scenarios can run against the application file without code changes.
- FCRM-003 plans a startup CI job for the application stack: fresh clone,
  `make up`, `/health/ready` returning 200 through the edge, URL printed,
  plus a health-check test. A new job only becomes a required check after
  the owner adds it to the `Portfolio Main Protection` ruleset. The names
  `Repository guard` and `Dev environment` must not change.
- Image references stay pinned by digest; actions stay pinned by commit.

## 10. Fixture-specific constants

These values in `bin/devenv` describe the fixture and must become explicit
configuration for FND-004:

| Constant | Fixture value | Application value (FCRM-003) | Use |
|---|---|---|---|
| `COMPOSE_FILE` | `$ROOT/compose.fixture.yaml` | the application Compose file | the Compose file |
| `EDGE` | `edge` | `edge` (Caddy 2) | service with the published port |
| `EDGE_CONTAINER_PORT` | `8080` | `8080` | container port of the edge |
| `INTERNAL_SERVICES` | `state` | `db api`, plus `web` under the `dev` profile | services started before the edge |
| readiness path | `/health` | `/health/ready` | HTTP readiness check |
| `PROJECT_RE` / prefix | `flowcrm-` | `flowcrm-` (ADR-009) | project naming |
| `logs` services | `edge`, `state` | `edge`, `web`, `api`, `db` | `SERVICE` allow-list |
| URL label | `FlowCRM development fixture` | the application name | `make up` output |

The proposed form is a small, documented block of constants at the top of
`bin/devenv` (no new file format and no new runtime dependency); values stay
validated before use. Changing the `flowcrm-` prefix or the `FLOWCRM_*`
variable names would change existing project names and saved state, and is
not planned.

## 11. Boundary between FND-003 and FND-004

FND-003 (this document) hardens the lifecycle and fixes the contract above,
using the fixture only. FND-004 implements the approved FCRM-003 stack; it
does not select an alternative edge, runtime or routing. FND-004:

1. adds the application's Compose file with the `edge` (Caddy 2), `web`
   (Vite, `dev` profile), `api` (Symfony on PHP-FPM) and `db` (PostgreSQL,
   `db-data`) services, following sections 2, 3, 6 and 7;
2. adds the Caddy configuration for the development and production-like
   routing of section 3 and the `/health/live` and `/health/ready`
   endpoints;
3. turns the constants of section 10 into configuration and sets the
   application values;
4. adds the planned startup CI job (section 9);
5. keeps the fixture tests green throughout.

Open points for FND-004, within the approved architecture: how the Caddy
routing of `/health/*` coexists with the rule that only `/api/*` reaches PHP
(section 6), and whether the owner makes the startup job a required check.
