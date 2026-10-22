# Development environment

`make` commands start this checkout's Docker Compose project and publish its
HTTP edge on `127.0.0.1` without manual port configuration.

## Stacks

`FLOWCRM_STACK` selects the Compose stack that the commands manage:

| `FLOWCRM_STACK` | Compose file | Services | Readiness path |
|---|---|---|---|
| `app` (default) | `compose.yaml` | `edge` (Caddy 2), `web` (Vite, profile `dev`), `api` (Symfony on PHP-FPM), `db` (PostgreSQL 18) | `/health/ready` |
| `fixture` | `compose.fixture.yaml` | `edge` (BusyBox HTTP server), `state` (helper with a named volume) | `/health` |

The application stack is the normal development environment (see the
[README](../README.md) and the
[lifecycle contract](architecture/development-lifecycle-contract.md)). The
fixture exists only for the allocator's regression tests
(`tests/devenv/integration.sh` sets `FLOWCRM_STACK=fixture`); it is not a CRM
application, and a healthy fixture says nothing about the application.
Both stacks use the same allocator, lock and runtime state, and the same
Compose project name. One checkout runs one stack at a time: every command
checks the Compose file recorded on the project's containers (label
`com.docker.compose.project.config_files`) and refuses with exit 6 if they
belong to the other stack, naming the command that stops them
(`FLOWCRM_STACK=<stack> make down`). Readiness also requires the stack's own
response body (`{"status":"ready"}` or `ok`), so another stack's page never
counts as ready.

## Prerequisites

| Tool | Notes |
|---|---|
| Docker Engine or Docker Desktop | daemon must be running |
| Docker Compose v2 | the `docker compose` plugin |
| GNU Make ≥ 3.81 | the macOS default works |
| bash ≥ 3.2 | `bin/devenv` runs under bash (macOS `/bin/bash` works) |
| `mktemp`, `hostname`, `ps`, `find`, `od`, `tr`, `sha256sum` or `shasum` | present on macOS and common Linux distributions |
| `lsof` | optional, improves `make ports` |

PHP, Composer, Node.js, PostgreSQL and Python are **not** needed on the host.
Python 3, `curl`, `git` and `tar` are used only by the test suites.

Run `make doctor` to check all of this. It changes nothing.

## First start

```console
$ make up
devenv: generated the local secret .runtime/secrets/db_password
devenv: generated the local secret .runtime/secrets/app_secret
devenv: building images (the first build can take several minutes)
FlowCRM: http://127.0.0.1:8080
$ make url
http://127.0.0.1:8080
```

`make up` runs these phases; any failure stops it with a non-zero exit code
and leaves `.runtime/dev.env` unchanged:

1. validate the configuration, the prerequisites (Docker, Compose v2) and
   the Compose file (`docker compose config`);
2. take the per-checkout lock;
3. create missing secrets in `.runtime/secrets` (never replacing one; see
   below);
4. build this project's images (`docker compose build`; source code is
   mounted, so editing it does not rebuild anything);
5. start the internal services with `up --wait`: `db`, then `api` and `web`;
   they publish no port, so a failure here is never retried on another port;
6. apply pending database migrations in the running `api` container
   (`doctrine:migrations:migrate --all-or-nothing`; application stack only);
7. start the edge on the first usable port (`up --no-deps --wait edge`);
8. verify Docker's actual mapping and `GET` of the stack's readiness path
   (`/health/ready`, which must answer 200 with the stack's own body) through
   the published edge;
9. save the verified port and print the URL.

When the stack already runs, `make up` reports what it changed: `already
running; nothing to change`, or `running; recreated: api (image or
configuration changed)` and/or `applied pending database migrations`.

## Commands

| Command | Behaviour |
|---|---|
| `make up` | Start or reconcile the stack; print the URL. Running it again on a healthy stack changes nothing. |
| `make down` | Stop and remove this checkout's containers and network. **Volumes and the saved port are kept.** |
| `make restart` | `down`, then `up`; the saved port is tried first. |
| `make status` | Show the project name, saved port, each service's state and health and the actual mapping. Exit 1 unless the edge is running, healthy and matches the saved port. |
| `make url` | Print the verified URL. Fails when the edge is not running, the readiness path does not answer 200 or the mapping differs from the saved port. |
| `make ports` | Read-only: the candidate ports in order, whether something accepts connections on them, and the container or process using them (best effort). |
| `make logs` | Recent logs of this project only. `SERVICE` is one of the stack's services (`edge`, `web`, `api`, `db`; fixture: `edge`, `state`), `TAIL=200`, `FOLLOW=1`. |
| `make doctor` | Read-only prerequisite and configuration check. |
| `make help` | List the targets. |
| `make test-devenv` | Run the allocator tests on the fixture (see below). |
| `make test-app` | Run the backend, frontend and application-stack tests (see below). |

When `bin/devenv` fails, `make` reports its own exit code 2; run
`bin/devenv <command>` directly to see the codes below.

| Exit code | Meaning |
|---|---|
| 0 | success |
| 1 | not running (`status`, `url`) |
| 2 | Docker error that is not a port conflict |
| 3 | no usable port |
| 4 | lock timeout |
| 5 | missing prerequisite (for example the Docker daemon is not reachable) |
| 6 | safety refusal (resources of another checkout) |
| 64 | invalid configuration or usage |

## Port selection

Candidates, in order, without duplicates:

1. the saved port from `.runtime/dev.env`, if it lies inside the range;
2. `FLOWCRM_PORT_DEFAULT` (default `8080`);
3. every other port of `FLOWCRM_PORT_RANGE` (default `8080-8099`), ascending.

For each candidate, a TCP connect to `127.0.0.1` and `::1` skips ports on
which something already accepts connections. That probe is only a hint:
the candidate is accepted only when Docker actually binds it. If Docker
reports a port conflict (`port is already allocated` or `address already in
use`), the next candidate is tried; `Ports are not available` without one of
these (Docker Desktop also uses it for permission errors) is not a conflict.
A `docker compose` call that was terminated by a signal is never a conflict. **Every**
candidate of the range is considered; the only other limit is the overall
time budget `FLOWCRM_UP_TIMEOUT`. Any other Docker failure (for example the
edge exits or never becomes healthy) stops immediately with exit 2 and no
other port is tried; the containers are left in place for `make status` and
`make logs`.

A port outside the range is never chosen automatically, including a saved
port that lies outside it.

### Explicit port

```console
$ FLOWCRM_HTTP_PORT=8123 make up
```

Exactly this port is tried. If it is in use, `make up` fails with exit 3 and
does **not** fall back to another port. An explicit port may lie outside the
range. A later `make up` without `FLOWCRM_HTTP_PORT` moves the edge back into
the range. If an explicit port cannot be bound after the edge had to be
recreated for it, the previous edge is restored on its previous port.

### Configuration

| Variable | Default | Rules |
|---|---|---|
| `FLOWCRM_PORT_DEFAULT` | `8080` | port inside the range |
| `FLOWCRM_PORT_RANGE` | `8080-8099` | `low-high`, ports 1024–65535, no leading zeros, at most 1000 ports |
| `FLOWCRM_HTTP_PORT` | unset | one port 1024–65535; disables fallback |
| `FLOWCRM_UP_TIMEOUT` | `600` | seconds for the whole port search, 1–3600 |
| `FLOWCRM_WAIT_TIMEOUT` | `60` | seconds `docker compose up --wait` may take per attempt, 1–600 |
| `FLOWCRM_LOCK_WAIT` | `120` | seconds to wait for another command in this checkout, 1–3600 |

Invalid values are rejected with exit 64 before Docker is touched. Values are
only compared and passed as single arguments; they are never evaluated.

## Saved assignment

After a verified start, `.runtime/dev.env` (git-ignored) records:

```ini
RUNTIME_SCHEMA=1
COMPOSE_PROJECT_NAME=flowcrm-1a2b3c
FLOWCRM_HTTP_BIND=127.0.0.1
FLOWCRM_HTTP_PORT=8080
```

- It is written atomically (temporary file, then rename) and only after the
  Docker mapping and the readiness path were checked. A failed start never
  replaces it.
- It is read as data with a fixed set of keys; it is never executed. A
  corrupt, unknown-schema, symlinked or oversized file is ignored and
  replaced on the next successful start.
- If the saved port is taken by something else, the next candidate is used
  and the file is updated.
- If the running edge uses a different port than the saved one (for example
  the file was edited), `make url` and `make status` report the mismatch and
  `make up` reconciles the file with the actual mapping.
- The file contains no secrets. The application's secrets are separate
  files in `.runtime/secrets/`:
  - The directory must be owned by you; `make up` sets it to `0700` and the
    files to `0444` (readable by the unprivileged container users, not by
    other local users). Symlinks and other file types are refused.
  - A secret is generated once and never replaced.
  - If `db_password` is missing while the volume `<project>_db-data` exists,
    `make up` refuses with exit 6 and generates nothing: the database was
    initialised with the old password. Restore the file from a backup, or
    reset the database deliberately (README, "Data persistence and reset").

## Several checkouts and projects

The Compose project name is `flowcrm-` plus the first six hex digits of the
SHA-256 of the checkout's physical path, so every checkout (and every
worktree) has its own containers, network and volume. Nothing uses fixed
container, network or volume names, and only `edge` publishes a port, on
`127.0.0.1`. Two checkouts started at the same time end up on different
ports; another portfolio application on 8080 simply makes FlowCRM use the
next free port.

Every command acts only on this checkout's project. It refuses (exit 6) when:

- `.runtime/dev.env` names another project (for example it was copied with
  the directory; delete it), or
- a container carries this project name but belongs to a different
  directory.

No command removes volumes or runs global cleanup such as `docker system
prune`. To delete this checkout's data, remove the volume explicitly:
`docker volume rm flowcrm-<hash>_state-data` (the name is shown by
`make status`).

## Concurrency and interruption

Mutating commands (`up`, `down`, `restart`) take a per-checkout lock,
`.runtime/lock`, created atomically with `mkdir`. A second command waits up
to `FLOWCRM_LOCK_WAIT` seconds and then sees the result of the first (for
`up`: "already running").

The lock records host, PID, the PID's start identity and a random token.
The start identity does not depend on the caller's locale or time zone: on
Linux it is the kernel boot id plus the start time in clock ticks since boot
(`/proc/<pid>/stat`), elsewhere `ps -o lstart` rendered with `LC_ALL=C` and
`TZ=UTC0`. A reused PID, including one after a reboot, has a different
identity.

While a command holds the lock, each mutating `docker compose` call (`up`,
`down`, `rm`) runs as a recorded process group: `bin/devenv` starts it as
the leader of a new process group, writes its PID, start identity and
process group to `.runtime/lock/op` and then executes Docker in that same
process. The Docker CLI and the Compose plugin it starts (a child process)
share that group. `SIGKILL` of `bin/devenv` or of the Docker CLI does not
stop the plugin, so:

- after such a call returns, `bin/devenv` waits until every member of the
  group has ended before it continues or releases the lock (at most
  `FLOWCRM_LOCK_WAIT` seconds; then it fails with exit 4 and **keeps** the
  lock, "Docker Compose processes … are still running");
- another command treats the lock as active while the owner, the recorded
  leader or any member of its process group runs. A second `up`, `down` or
  `restart` waits up to `FLOWCRM_LOCK_WAIT` seconds ("Docker command pid … is
  still running" or "Docker Compose processes in process group … are still
  running") and then fails with exit 4; it never runs Compose alongside
  them.

A process group ID is not reused while the group has members, so a member of
the recorded group belongs to the recorded operation; no process names or
command lines are matched. Read-only commands (`status`, `url`, `ports`,
`logs`) take no lock and are not recorded.

A lock whose owner or command record is missing a field, malformed, or
cannot be compared on this platform is never removed automatically (exit 4
after the wait). A live owner recorded by an older `bin/devenv` (no
canonical start identity) is reported as such; once that process has ended
the lock is removed automatically. A lock directory without an owner record
is removed once it is older than a minute. A lock from another host is never
removed automatically. Ctrl-C, `SIGTERM` and `SIGHUP` are forwarded to the
running Docker Compose process group at once; the command exits (130, 143,
129) and releases the lock after that group has ended. After `SIGKILL` the
next command removes the lock once the orphaned Docker Compose processes have
finished. The saved state is never left
half written, and a Docker command that finished without its owner does not
change it: the next `up` verifies and saves the actual mapping.

## Diagnostics

```console
$ make ports
range 8080-8099, default 8080, override none, saved 8084
PORT   PROBE      PUBLISHED BY / LISTENER (best effort)
8084   in-use     flowcrm-1a2b3c-edge-1
8080   in-use     other-app-1
8081   free
...
```

`make status` shows container IDs, health and the mapping; `make logs`
shows this project's logs (`edge` logs each HTTP request).

## Failure scenarios

| Symptom | Meaning / action |
|---|---|
| `no free port in 8080-8099` (exit 3) | every candidate is in use; free one, or set `FLOWCRM_PORT_RANGE` or `FLOWCRM_HTTP_PORT`; see `make ports` |
| `FLOWCRM_HTTP_PORT=… cannot be bound` (exit 3) | the explicit port is in use; no fallback by design |
| `starting the edge on port … failed for a reason other than a port conflict (…)` (exit 2) | the edge failed or `docker compose` was terminated; see `make logs`, fix, run `make up` again |
| `starting the internal services (…) failed: …` (exit 2) | the unpublished services failed (for example an invalid Compose file or a failing health check) or `docker compose` was terminated; no port was involved |
| `stopping project … failed: …` (exit 2) | `docker compose down` failed or was terminated |
| `project … has containers of another stack` (exit 6) | the other `FLOWCRM_STACK` runs in this checkout; stop it with the command shown |
| `.runtime/secrets/db_password is missing, but the volume … was initialised with it` (exit 6) | restore the secret, or reset the database (README) |
| `applying the database migrations failed` (exit 2) | a migration failed; nothing was saved; see `make logs SERVICE=api` |
| `the Compose configuration (…) is invalid` (exit 2) | the Compose file does not parse or validate; nothing was started |
| `building the images failed: …` (exit 2) | a Dockerfile or dependency install failed; running containers were not changed |
| `does not answer /health/ready with 200` (exit 2) | the stack runs but is not ready (database unreachable or a migration pending); `make logs SERVICE=api` shows the logged reason |
| `could not create the secret …` / `… is not a regular file` (exit 6) | `.runtime/secrets` is not writable or contains a symlink; fix it, never edit an existing secret |
| `Docker daemon is not reachable` (exit 5) | start Docker Desktop or the Docker service |
| `waiting for another devenv command` | another command runs in this checkout; it is waited for |
| `holds .runtime/lock … gave up` (exit 4) | a command, or Docker Compose processes of a killed one, are still running, or the lock comes from another host, an older `bin/devenv` or is unreadable; remove `.runtime/lock` only if no devenv or `docker compose` command of this checkout runs |
| `… still running …; .runtime/lock is kept until they end` (exit 4) | Docker Compose processes outlived the Docker CLI for `FLOWCRM_LOCK_WAIT` seconds; the next command proceeds once they have ended |
| refused with exit 6 | resources of another checkout; see the message |

## Image pinning

Base images are pinned by tag and digest in `docker/*/Dockerfile` and
`compose.fixture.yaml`. The BuildKit Dockerfile frontend is pinned the same way: line
1 of every Dockerfile is

```dockerfile
# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
```

so the build no longer resolves the mutable `docker/dockerfile:1` tag on
every build (the digest is the multi-platform index; `linux/amd64` and
`linux/arm64` are among its platforms). Docker Engine and Docker Desktop with
BuildKit, as used by `docker compose build`, load the frontend from this
reference.

`scripts/ci/guard-dockerfile-frontend.sh` (job `Repository guard`) fails
unless every tracked Dockerfile (`Dockerfile`, `Dockerfile.<x>`,
`<x>.Dockerfile`, `Containerfile`) has such a directive on line 1, as
`<image>:<tag>@sha256:<64 hex>`, all Dockerfiles use the same reference and
no other `syntax` directive appears. To update the frontend, resolve the new
version's index digest (`docker buildx imagetools inspect
docker/dockerfile:<version>`) and change line 1 of all Dockerfiles together.
Its regression suite is `scripts/ci/tests/guard-dockerfile-frontend.test.sh`.

## macOS and Linux

- The commands use bash 3.2-compatible syntax and BSD/GNU-neutral tools.
- On macOS, Docker Desktop's backend publishes the ports; on Linux,
  Docker Engine does. Both report a conflicting bind, which the allocator
  detects by message text; that detection is covered by unit tests with the
  known messages of both and by the real-Docker tests.
- `127.0.0.1` is used in the URL rather than `localhost`, so a browser does
  not try `::1` and reach a different server.

## Tests

```console
$ make test-devenv                               # allocator: unit + integration (fixture)
$ tests/devenv/unit.sh                           # no Docker needed
$ DEVENV_TEST_PORT_BASE=18080 tests/devenv/integration.sh
$ make test-app                                  # application: the four suites below
```

Application suites (`tests/app/`), each in its own Compose projects:

- `scan.sh` (SC-xx): Trivy scans of the runtime images (production-like api
  and edge, db), which fail on any HIGH or CRITICAL finding, and of the
  development images, which are reported; each scan must inventory the
  expected package sources (Alpine packages, Composer, the Caddy binary,
  Node packages), and control scans prove the gate fails on a vulnerable
  image and on an image without inventoried packages (see
  [security/container-vulnerabilities.md](security/container-vulnerabilities.md)).
- `backend.sh` (BE-01 to BE-13): PHP 8.5 runtime, `composer validate` and
  `composer audit`, PHP-CS-Fixer, PHPStan (level max), migrations from an
  empty database, `doctrine:schema:validate`, a full down/up migration round
  trip, PHPUnit unit and integration suites against a real PostgreSQL
  (project `<project>-test`, database on tmpfs, no published ports), and the
  architecture rules: Deptrac with `deptrac.modules.yaml` and
  `deptrac.layers.yaml`, and the architecture test suite (see
  [architecture/backend-modules.md](architecture/backend-modules.md)).
- `frontend.sh` (FE-01 to FE-05): `npm audit`, strict type check, ESLint
  without warnings, Vitest component tests and the production build.
- `stack.sh` (ST-01 to ST-43): the real stack through `bin/devenv` in fresh
  copies of the checkout on the 20 ports from `DEVENV_TEST_PORT_BASE`
  (default 18300): exposure, networks, non-root and read-only containers,
  routing through Caddy, API and health responses, readiness with a pending
  migration and with a stopped database, persistence across down/up and
  restart, a port conflict, checkout isolation, a Playwright browser
  journey including the HMR connection, the raw-path routing boundary,
  per-service hardening with negative controls, lost secrets, source edits
  and migrations added while running, both stacks in one checkout, and the
  structured logs (request ID in the api and edge logs, complete JSON
  records, no tokens in any log).
- `prodlike.sh` (PL-01 to PL-13): the production images (`<project>-prod`,
  no published ports): built SPA, CSP, cache headers, SPA fallback, API
  errors, health, the raw-path routing boundary and a Playwright journey
  under the CSP.

Each application suite uses Compose project and image names unique to the
run, so several runs from one checkout do not interfere.

- `tests/devenv/unit.sh` covers configuration validation, candidate order,
  state parsing and writing, failure classification, project naming and
  the lock (stale, reused-PID, foreign-host, reap-guard, legacy and
  malformed records; real lock holders in other locales and time zones; a
  recorded child that survives `SIGKILL` of its owner; a recorded leader
  whose descendant outlives it; signal forwarding), the Makefile interface
  (targets and the commands they run) and checks that the result tally
  detects failed and lost results.
- `tests/devenv/integration.sh` runs scenarios PA-01 to PA-23 and the
  Makefile targets against real Docker in temporary checkout copies. It uses
  the 20-port block starting at `DEVENV_TEST_PORT_BASE` (default 8080) and
  skips with exit 77 if any of those ports is in use, so it never competes
  with running stacks. It removes only the containers, volumes and networks
  it created (checked by label) and verifies that pre-existing containers,
  volumes and networks are unchanged. PA-16 kills `up` with `SIGKILL` while
  its `docker compose up --wait` blocks on a gated health check and verifies
  that `up`, `down` and `restart` are refused until the orphan finished;
  PA-21 holds the lock under `pl_PL.UTF-8`/`TZ=JST-9` and checks it from
  other locales and time zones. PA-22 kills the recorded Docker CLI while
  real Docker Compose processes of its group keep running (through a
  test-only `docker` shim, since the real plugin exits within milliseconds)
  and verifies that the lock is held until they end. PA-23 checks that an
  invalid Compose file fails with exit 2, keeps the verified state and tries
  no other port.
- Both suites compare the printed PASS/FAIL records with their counters and
  exit 2 on a mismatch; a scenario without results or a failed setup step
  counts as a failure.

Both suites run locally on macOS (Docker Desktop, bash 3.2) and in GitHub
Actions on Ubuntu (Docker Engine, bash 5) in the `Dev environment` job.

The interface the future application stack has to provide is described in
[architecture/development-lifecycle-contract.md](architecture/development-lifecycle-contract.md).
