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
devenv: generated the local secret .runtime/secrets/db_owner_password
devenv: generated the local secret .runtime/secrets/db_app_password
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
5. start the internal services with `up --wait`: `db` first; on the
   application stack its database roles are then checked and corrected
   (`flowcrm-db-roles ensure`; a database created before the role separation
   or with inconsistent roles stops here with exit 6, see
   [ADR-018](architecture/adr/ADR-018-database-roles.md)), then `api` and
   `web`; they publish no port, so a failure here is never retried on another
   port;
6. recreate a running `db` or `api` whose mounted secret files differ from
   the files in `.runtime/secrets` (a file replaced on the host is not seen
   by a running container; application stack only), and check that each new
   container is healthy and mounts the current files (Compose's own wait can
   report success too early, ADR-018), then apply pending
   database migrations (when role corrections or migrations are needed, a
   running edge is stopped and the security gate recorded first, see
   ADR-018) in a one-off `migrate` container
   (`docker compose run --rm`) that connects as the schema owner
   `flowcrm_owner` (`doctrine:migrations:migrate --all-or-nothing`;
   application stack only);
7. verify the runtime role and privileges in the `api` container
   (`app:database:verify-privileges --runtime`; exit 6 on any difference from
   `backend/config/database/runtime-privileges.yaml`; application stack only).
   When this check or the role check of phase 5 fails, a running edge is
   stopped, so the stack is not served; the database and the saved port are
   kept, `make status` reports `blocked` and `make url` fails until a
   `make up` passes. The gate is the file `.runtime/gate/security-gate`; an
   edge started by `bin/devenv` mounts that directory (`FLOWCRM_GATE_DIR`)
   and, while the file exists, answers everything but `/health/live` and
   `/health/ready` with 503, so a stack that has not passed its checks
   serves nothing even if such an edge is running. An edge started directly
   with `docker compose up` mounts the empty `docker/edge/no-gate` instead
   and does not enforce the gate; use `make` (ADR-018);
8. start the edge on the first usable port (`up --no-deps --wait edge`);
9. verify Docker's actual mapping and `GET` of the stack's readiness path
   (`/health/ready`, which must answer 200 with the stack's own body) through
   the published edge;
10. save the verified port and print the URL.

When the stack already runs, `make up` reports what it changed: `already
running; nothing to change`, or `running; recreated: api (image or
configuration changed)` and/or `applied pending database migrations`. A
running edge that does not mount `.runtime/gate` (created before the gate
mount existed, or by a plain `docker compose up`) would not enforce the
security gate; `make up` recreates it on its port instead of reporting it
as running.

**Upgrade note (security gate mount, FND-009E):** in a checkout whose
stack was started before this change, the first `make up` afterwards
recreates the running edge once and says so (`recreating the edge on port
…: it does not mount .runtime/gate`). Only the stateless edge container is
replaced: the database, its volume, `.runtime/secrets` and the api and web
containers are handled exactly as by any `make up`. The edge comes back on
the same port (if another program took the port in the meantime, the next
free one is used and the printed URL shows it). The edge image is rebuilt
first, while the old edge still serves; the UI and API are unavailable
only while the container is replaced (about one second, 0.5 to 1.2 s in
tests of this upgrade, with no answer on the port in between). Later runs
report `already running`.

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
| `make db-upgrade-roles` | Application stack only, explicit: convert a database created before the role separation. Creates the two role secrets, stops `api`, `web` and `edge`, takes a backup verified by a restore into a scratch database (`.runtime/backups/`), moves the schema to `flowcrm_owner` in one transaction, migrates and verifies. On a converted database it only re-checks. |
| `make db-rotate-password ROLE=app\|owner` | Application stack only, development use: a new password for `flowcrm_app` or `flowcrm_owner`. The pending password (`.runtime/secrets/.db_<role>_password.pending`, `0600`) is set in the database, a SCRAM login is checked, then it replaces the current file, the containers that mount it are recreated and the role's own client logs in. The edge serves again only when it answers readiness; otherwise the command exits 2 and the stack stays blocked until `make up` succeeds. After an interruption or failure, running it again finishes the rotation (ADR-018, Rotation). |
| `make db-rotate-password-abort ROLE=app\|owner` | Undo an unfinished rotation: the database gets the current password back (SCRAM login checked) and the pending file is removed. |
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
| 6 | safety refusal (resources of another checkout, missing or malformed secrets, database roles not upgraded or inconsistent, runtime privileges that differ from the manifest) |
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
  - The application stack has four: `db_password` (the PostgreSQL
    superuser, used only inside the `db` container), `db_owner_password`
    (`flowcrm_owner`, given to the `migrate` job), `db_app_password`
    (`flowcrm_app`, given to the `api`) and `app_secret`. The two role
    passwords must be 48 lowercase hex characters; anything else is refused
    with exit 6.
  - A secret is generated once and never replaced by `make up`.
  - If a database secret is missing while the volume `<project>_db-data`
    exists, `make up` refuses with exit 6 and generates nothing: the database
    was initialised with the old password. Restore the file from a backup, or
    reset the database deliberately (README, "Data persistence and reset").
    For a volume created before the role separation, `make db-upgrade-roles`
    is the only command that creates the role secrets; for a converted one,
    `make db-rotate-password ROLE=…` sets a new password.
  - Compose mounts secret files as bind mounts: a container keeps seeing the
    file it was started with. `make db-rotate-password` therefore recreates
    the containers that read a rotated secret; do not replace secret files
    by hand.

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
| `applying the database migrations failed` (exit 2) | a migration failed; nothing was saved; the output of the `migrate` job is shown; the stack stays blocked (`make status`) until a `make up` succeeds |
| `… was created before role separation` / `.runtime/secrets/db_owner_password is missing, but the volume … exists` (exit 6) | the volume predates the role separation: `make db-upgrade-roles` |
| `… is malformed (expected 48 lowercase hex characters)` (exit 6) | restore the role secret, or `make db-rotate-password ROLE=…` |
| `the database roles of … are inconsistent` (exit 6) | nothing was changed; see the recovery table in [ADR-018](architecture/adr/ADR-018-database-roles.md#recovery) |
| `the api's database role or privileges do not match …` (exit 6, edge stopped, `make status` shows `blocked:`) | the violations are listed; grant the privileges in the migration and list the object in `backend/config/database/runtime-privileges.yaml`; a failed login means a stale `db_app_password` (`make db-rotate-password ROLE=app`) |
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

### Isolation from Docker

`tests/devenv/unit.sh` and the guard regression suites in
`scripts/ci/tests/` run code under test, including a modified or mutated
copy of it (`DEVENV=`, `GUARD=`, `ADAPTED=` or an edited file). That code
runs with the caller's user ID and may be any shell, Python or program on
the machine: it may fork, daemonise, write files, open sockets and send
signals. Each suite therefore re-executes itself under
`scripts/ci/no-docker.sh`. The isolation must keep the code away from:

- the container engines and their objects (images, containers, volumes,
  networks, build cache), including those of other projects;
- the user's environment: files in `$HOME` and in the checkout, shell and
  tool configuration, user-session IPC and the user's other processes;
- later steps of the same CI job.

The person or job that starts a suite is trusted. The checks of the
environment described below prevent accidental use where the isolation is
not supported; they are not a boundary against the caller. Kernel and
sandbox vulnerabilities and CPU or memory exhaustion are out of scope.

Supported platforms:

| Platform | Support | Mechanism |
|---|---|---|
| macOS developer machine | supported | `sandbox-exec` profile |
| Linux on a GitHub-hosted Actions runner | supported | `sudo -n unshare` namespaces |
| Linux anywhere else (developer machines, self-hosted runners, containers) | refused (exit 125): "Linux is supported on GitHub-hosted CI runners only" | — |
| other systems | refused (exit 125) | — |
| any platform as uid 0 | refused (exit 125) | — |

Each property below is enforced by the sandbox profile or the kernel. Before
the command starts, `scripts/ci/no-docker-probe.py` checks from inside the
ones each platform's section lists as checked; on macOS the others rest on
`sandbox-exec` accepting the profile and on the regression tests. If any
check fails, a tool is missing, a mount fails, the profile is rejected or
the command was not started inside the isolation, the command does not run
and the exit status is 125.

On both platforms the variables that select an engine (`DOCKER_*`,
`CONTAINER_HOST`, `PODMAN_*`, `COMPOSE_*` and similar) are removed,
`DOCKER_CONFIG` is an empty directory and `$TMPDIR` is a directory of the
run. The probe then asks every endpoint it can find whether a container
engine answers there: the usual socket paths, the Docker contexts,
`DOCKER_HOST`, sockets under `/run`, `/var/run`, `/tmp`, `$TMPDIR` and
`~/.docker`, ports 2375 and 2376 and every listening TCP port. The walk
of those directories stops at 20,000 entries. On Linux that refuses the
run. On macOS, where every Unix socket connect is denied anyway, the probe
prints an INFO line instead.

#### macOS

`$TMPDIR` must be the per-user temporary directory that macOS creates,
`/private/var/folders/<xx>/<id>/T`, owned by the user with mode 0700. If
`TMPDIR` is unset, `getconf DARWIN_USER_TEMP_DIR` is used. Any other
directory, such as `/tmp`, `/private/var/tmp`, `/`, Homebrew's prefix or a
directory of the user's own, is refused. Each run gets a fresh directory
there, mode 0700. The command's `$TMPDIR` is inside it.

The `sandbox-exec` profile denies:

- connecting to any Unix socket. The probe checks this with a socket of its
  own: EPERM;
- TCP beyond loopback, and to loopback ports 22, 2375 and 2376. The probe
  checks 2375 and a non-loopback address;
- TCP to every port that was listening when the run started, on any address
  (a development server, an IDE, a published container port or a socket
  proxy). The list comes from `netstat`; if `netstat` fails, prints no
  column header or prints a LISTEN row that cannot be parsed, the run is
  refused. The probe connects to each held port;
- file writes anywhere except in the run's directory, `/dev/null`,
  `/dev/zero`, `/dev/tty`, `/dev/dtracehelper` and `/dev/fd/*`. Nothing in
  `/tmp` or `/private/var/tmp` is writable, so no file another process
  keeps there can be changed, replaced or created from inside. The probe
  checks that `$HOME`, the user's temporary directory, `/tmp`,
  `/private/var/tmp` and an `sh-thd-*` file in `/tmp` are not writable and
  that `$TMPDIR` is. This `/dev` list was measured with bash 3.2, python3,
  `mktemp`, `/usr/bin/git`, `tests/devenv/unit.sh` and the guard suites.
  Writing to `/dev/random`, `/dev/urandom` and other terminals' `/dev/ttys*`
  is denied. `/usr/bin/git` reports that it cannot write the `xcrun_db`
  cache in the user's temporary directory and still works. That cache is
  read by `xcrun` outside the sandbox, so it stays write-denied;
- signals to any process outside the sandbox. Processes of the run can
  signal each other, including process groups. The probe sends signal 0 to
  `no-docker.sh` outside: EPERM;
- debugging any process (`system-debug`): `ptrace(PT_ATTACHEXC)` fails with
  EPERM, even against a process of the user that allows debuggers
  (`get-task-allow`). Measured: without this rule the attach succeeds, and
  a debugger could then stop, signal or end that process;
- the task ports of processes outside the sandbox (control, inspect, read
  and name ports), which debuggers and readers such as `vmmap` and `sample`
  use. Measured: without the rule they read the memory map of such a
  process from inside; with it they are refused, while they still work on
  the command's own processes and `ps` still lists every process;
- reading the devices of other terminals (`/dev/ttys*`), which would let
  the command read what is typed in them. The command keeps its own
  terminal through `/dev/tty` and the descriptors it inherits;
- preference writes through `cfprefsd` and `TIOCSTI` on the terminal;
- `open`, `osascript`, `launchctl` and `ssh`, job submission to launchd,
  Launch Services and Apple Events. Measured with a re-signed copy of
  `launchctl` inside: `submit` and `bootstrap` of a job and `setenv` in the
  user's launchd domain all fail, and no job or variable appears;
- lookups of the services that register login items and background tasks
  (`com.apple.xpc.smd`, `com.apple.backgroundtaskmanagement*`,
  `com.apple.coreservices.sharedfilelistd*`) and of Docker Desktop's own
  services (`com.docker.*`, `com.electron.dockerdesktop.*`).

bash 3.2, which is also `/bin/sh`, keeps each here-document and
here-string in a temporary file, ignoring `$TMPDIR`: in `/private/var/tmp`,
or in `/tmp` where `/var/tmp` is not writable, as inside a sandbox. Neither
is writable inside, so a here-document fails there ("cannot create temp
file for here document"). Measured: bash then falls back to the working
directory, so one works only while the working directory is in the run's
directory. The code that runs inside (`bin/devenv`, `tests/devenv/unit.sh`,
the guard suites and the scripts they run) therefore uses none; T-20
checks this statically.

When the command ends, the processes it left in the sandbox are ended: a
plain background job, a daemon after `setsid` and a double fork, a
`posix_spawn` child in a session of its own, a process group of its own.
`no-docker.sh` hands its process to a supervisor in
`scripts/ci/no-docker-probe.py`, which starts `sandbox-exec`, waits for it
and then ends what is left. It finds those processes by a marker: the
profile denies reading file `a` of the run's marker directory, in `$TMPDIR`
outside the run's directory, and leaves file `b` next to it alone. From
outside, `sandbox_check()` asks how a process's sandbox would decide; a
process is in the run's sandbox exactly when it is sandboxed, denied `a` and
allowed `b`. Measured: an unsandboxed process is allowed both, and the
files must exist, or every process is "denied". A process cannot leave its
sandbox, and every process it starts inherits it, however it detaches.

The run is reported done only when it is shown that none of its processes
runs any more. The supervisor takes one copy of the kernel's process list
at a time (the kernel copies it under one lock, so it has every process of
that instant, zombies included) and checks each process in it, by its
unique id before and after the check: one of the run's is sent SIGKILL at
once. A copy shows the run has ended when every process in it is shown not
to be one of the run's, or was already dead before that copy was taken.
Every process started later descends from one in the copy (the kernel lists
a child before it can run, and its parent until it is reaped), so none of
them can be one of the run's either. A process that ends before it can be
checked leaves that copy open, as it may have started one of the run's
first; the supervisor then takes the next copy. Measured: a run without
leftovers is shown done in about 0.07 seconds, a run whose daemon must be
ended in about 0.4 seconds.

If that cannot be shown within 10 seconds, the run fails with status 125;
it is never reported done. Measured: a process that forks a new one and
ends, over and over (thousands of times per second), makes every copy
open: the run fails, although that process is not found and keeps running,
still in the sandbox with every limit above. The run's marker directory is
then kept, and no new run starts until it is shown that none of its
processes runs any more (then that directory is removed). The supervisor
needs no new process for any of this, so a command that uses up the
processes it may start cannot stop it. SIGINT, SIGTERM, SIGHUP or SIGQUIT
delivered to `no-docker.sh` end the command and everything it left in the
same way, and the status is 128 plus the signal number; a signal the
caller ignores stays ignored. The probe checks from inside that the
sandbox carries the run's marker.

SIGKILL of `no-docker.sh` (or a crash of the supervisor) cannot be handled:
what the command left keeps running, still inside the sandbox with every
limit above. The marker directory records the run's owner (the process
that becomes its supervisor). Before each run, `no-docker.sh` looks at the
marker directories whose owner is gone; it removes one once it is shown
that none of its processes runs, and otherwise refuses to start, naming
them. It never ends anything there. Runs in progress elsewhere (their
owner lives) are left alone.

Setuid programs cannot run in the sandbox, so `ps` is an ad-hoc signed copy
and `sudo` is unavailable. The U-16 check that another local user cannot
read a secret therefore prints INFO and is not counted; the U-16 mode checks
still run. macOS applies a sandbox inside another only if the profiles are
identical, so the suites cannot run inside a different sandbox: they are
refused.

#### Linux (GitHub-hosted runners)

`no-docker.sh` refuses unless:

- the caller is not uid 0 (real or effective). This is checked before
  anything else;
- `GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT=github-hosted`;
- a `Runner.Worker` process (by `comm` and executable name) is an ancestor
  of the caller. An unreadable ancestor counts as a refusal;
- `$GITHUB_WORKSPACE` and `$RUNNER_TEMP` are directories under `$HOME`;
- `sudo -n` works and `unshare`, `setpriv`, `setsid`, `ip`, `mount`, `find`,
  `stat` and `python3` exist.

Before entering, the caller's side lists every Unix socket file on the
local file systems (`find -xdev -type s` per mount) and every bound
pathname socket of the host's network namespace (`/proc/net/unix`, which is
what `ss -xl` shows). The list has a 180-second budget; when it runs out,
the run is refused instead of using a partial list. The time it took is
printed with each run, on stderr and as a `::notice::` in the CI log.
Inside, the list is a read-only file.

The command then runs under
`sudo -n unshare --net --mount --pid --fork --kill-child --mount-proc --ipc`
with private mount propagation. The namespace's pid 1 is a root shell that
does not exec:

1. It brings up loopback in the new network namespace.
2. It mounts an empty tmpfs over `/run` (and `/var/run` when that is not a
   symbolic link), `/tmp`, `/var/tmp` and `/dev/shm`, a fresh mqueue on
   `/dev/mqueue` and a read-only tmpfs over `/sys/fs/cgroup`. The run's
   directory, which is under `/tmp` (or under `/var/tmp` with `--work`), is
   bind-mounted aside first and moved back into the new tmpfs, so the
   original `/tmp` is not visible.
3. It remounts every other mount reachable by path read-only. A bind
   remount changes only the namespace's copy and keeps the other per-mount
   flags. This covers `$HOME` with the workspace, `$RUNNER_TEMP`,
   `$GITHUB_ENV`, `$GITHUB_PATH` and `~/.docker`, as well as
   `/opt/hostedtoolcache` and every other mount.
4. It runs the command as a child: `setpriv` with the caller's uid and gid,
   no supplementary groups, `no_new_privs`, and empty inheritable and
   bounding capability sets; then `setsid --wait`, then `env -i` with an
   allowlist of variables (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`,
   `LANG`, `LANGUAGE`, `LC_*`, `TERM`, `TZ`, `CI`, `DEVENV*`, `GUARD*`,
   `ADAPTED`, `HARNESS` and `FLOWCRM_*`). No session bus, display, agent,
   runner file-command or token variable reaches the command.
5. It waits for the command, reaping orphans meanwhile, and exits with the
   command's status. When pid 1 exits, the kernel kills every process left
   in the namespace, including daemonised ones. If `unshare` itself dies,
   `--kill-child` kills pid 1. pid 1 makes no credential change, so that
   signal stays armed.

Interruption: `unshare` runs as root, and with `--fork` it blocks SIGINT
and SIGTERM; pid 1 ignores signals from outside its namespace. So when
SIGINT, SIGTERM or SIGHUP is delivered to `no-docker.sh` itself (Ctrl-C in
a terminal, or a caller that forwards the signal), it sends SIGKILL,
through `sudo`, to the `unshare` it started: the process named `unshare`
whose ancestors include the `sudo` of this run. Through `--kill-child`,
that kills pid 1 and every process inside.

A cancelled or timed-out GitHub step does not reach this. The runner
signals only the step's shell, and later sends SIGKILL to the process
tree, so `no-docker.sh` gets no signal it can handle. The namespace then
keeps running, with read-only mounts and no network, until the runner's
VM is discarded (see the residual risks).

The probe checks from inside:

- no uid is 0; every capability set is empty; `NoNewPrivs` is 1; there are
  no supplementary groups;
- the network, mount, pid and IPC namespaces differ from the caller's;
- the process is in a pid namespace below the caller's (`NSpid`), and
  `/proc` belongs to it;
- pid 1 is the root shell of the isolation and every other visible process
  has the caller's uid. None is a runner, init or engine process, so
  `/proc/<pid>/root` and `nsenter` have no target outside;
- the process is in a session of its own without a controlling terminal,
  so `TIOCSTI` has no target;
- loopback is the only interface;
- `/tmp`, `/var/tmp`, `/dev/shm` and `/run` are tmpfs, and `/dev/mqueue` an
  mqueue, on devices other than the caller's. `/sys/fs/cgroup` is a
  read-only tmpfs, and no cgroup file is writable;
- every mount reachable by path is read-only, except the private file
  systems above, the run's directory, `/proc` and `/dev`. This is read from
  `/proc/self/mountinfo` and the mount ID of each path. Creating a file in
  `$HOME`, `$GITHUB_WORKSPACE` and `$RUNNER_TEMP` must fail as well;
- the working directory is reachable by its path;
- no other `proc` file system and no `nsfs` mount is reachable by path;
- there is no socket in the private directories, and none of the listed
  Unix sockets accepts a stream, seqpacket or datagram connection (a
  listener with a full backlog counts as accepting). Pathname sockets on a
  read-only mount would still accept one, which is why every one of them
  is tried.

The probe also prints the uids and gids of the command. The command keeps
the caller's primary group; on a runner that may be the group of the
Docker socket, which is kept away by the hidden path and the connect test
above. This Linux path has not yet run in CI in this version: the first
run on a GitHub-hosted runner is its first evidence.

The output between the start and the end of the isolated command is framed
with `::stop-commands::<random token>`, so the command cannot issue
workflow commands. The start line is printed on both stdout and stderr; the
token is never passed inside.

#### Run directory (`--work DIR`)

`no-docker.sh --work DIR COMMAND` uses `DIR` as the run's directory
instead of a temporary one, and keeps it afterwards. It is the command's
only writable directory and holds its `$TMPDIR`.

`DIR` must:

- be given as an absolute, canonical path with no symbolic link in it;
- be a directory of the caller with mode 0700;
- be empty;
- not be or contain `$HOME`;
- be under `$TMPDIR` or `/private/var/tmp` on macOS, and under `/var/tmp`
  on Linux.

Otherwise the run is refused. `tests/devenv/unit.sh` passes
`NO_DOCKER_WORK=<dir>` on as `--work`. Whatever the command leaves in
`DIR` is untrusted data: a later reader must not follow symbolic links,
must accept regular files only, must limit their size and must not execute
them.

#### Accepted residual risks

- **SIGKILL of `no-docker.sh` (macOS), or an ending that cannot be shown.**
  The command and what it left keep running in the sandbox, with every
  limit above, until someone ends them (`no-docker-probe.py --end <marker
  directory>`, or by pid); meanwhile no new isolated run starts. A process
  that keeps forking and ending is not found at all; it runs until it stops
  by itself, the user ends it or logs out. Until then the channels the
  sandbox leaves open (loopback ports, the pasteboard, reading the user's
  files and process information) stay available to it, without a time
  limit. Processes left by versions without the owner record are not
  recognised; end them by pid after updating.
- **Process identity (macOS).** A process is signalled only after its
  unique id and membership were read again, microseconds before. A pid
  reused within that window by a process outside could still be ended:
  an availability risk, not a way out. Reusing a pid needs the kernel's
  counter to wrap (pids up to 99999).
- **Late listeners.** A loopback port that starts listening after the run
  started (on macOS) is reachable, as are the ports the command opens
  itself. This includes a VM's port forward that starts later. The probe
  asks each listening port whether it is an engine only at the start. The
  other way round, a loopback port the command opens during the run can be
  reached by programs outside, which may take its answers for those of a
  local service (for example a readiness check of `bin/devenv` run at the
  same time).
- **Login items and launchd (macOS).** The services that register login
  items and background tasks are denied, and launchd jobs and `setenv`
  through a re-signed `launchctl` fail (measured). Services that launchd
  starts on the command's behalf run outside the sandbox; they are limited
  by the lookups and Apple Events denied above, not by the supervisor.
- **Terminals and the pasteboard (macOS).** Reading and writing other
  terminals' devices are denied. A process of the command can still make
  itself the foreground process group of its own terminal while it runs.
  The pasteboard (`pbcopy`) is not denied; using it needs a person to
  paste.
- **Reading other processes (macOS).** The environment and arguments of the
  user's other processes are readable (`ps eww`), as are the user's files.
- **Writes through other processes (macOS).** The file-write limit covers
  the command's own writes. Writes made for it by system services are
  limited by the launchd, Launch Services, Apple Events, preference and
  login-item denies above, not by the file rule. Keychain items are data,
  not code.
- **Sockets created after the list (Linux).** A pathname socket that
  appears on a read-only mount after the list was made, from a process
  outside the namespace, is not tried. On a GitHub-hosted runner no such
  service runs during the isolated steps.
- **Shared keyring and readable files (Linux).** The per-user kernel
  keyring is shared. Files such as `~/.docker/config.json` stay readable,
  but there is no network to use them on.
- **Orphan cleanup after a kill (Linux).** `env -i` drops
  `RUNNER_TRACKING_ID`, so the runner's end-of-job cleanup cannot find
  processes of the namespace. They are killed with pid 1 instead, on a
  normal end and when SIGINT, SIGTERM or SIGHUP is delivered to
  `no-docker.sh` itself (see above).
- **Cancelled or timed-out CI steps (Linux).** GitHub signals only the
  step's shell and later sends SIGKILL to the process tree. Neither
  reaches the trap in `no-docker.sh`, so the namespace and anything left
  in it keep running until the runner's VM is discarded. They still have
  read-only mounts, no network, no capabilities and no view of other
  processes. Only the checkout's post-job step follows.
- **CI coverage when a scan fails.** Isolated steps run last in their job
  (see below). When the container scan fails, the Dev environment job stops
  before `tests/devenv/unit.sh`, so the allocator unit tests do not run in
  that CI run.

#### CI

The isolated steps are the last steps of each required job:

- **Repository guard:** the trusted guard scripts, ShellCheck and
  actionlint run first; then the guard regression suites and
  `scripts/ci/tests/no-docker.test.sh`.
- **Dev environment:** `tests/devenv/unit.sh` runs after the container
  scan.

After them, only the checkout action's post-job step runs. During the
isolated steps on Linux it reads nothing that the code under test could
have written: the workspace and `$HOME` are read-only, and `/tmp` is
private.

`scripts/ci/tests/ci-isolation-order.py` checks the order statically:

- after the first isolated step of a job, every following step is
  isolated. A step is isolated when every command it runs (directly or
  through a `make` target) is `no-docker.sh`, its test harness
  `no-docker.test.sh`, or a script with the re-exec stanza. A step that
  mixes such commands with others fails;
- the required jobs exist;
- no job or step has an `if:` condition or a `continue-on-error:` key;
- every other file that mentions `no-docker.sh` has the recognised re-exec
  stanza.

#### Regression tests

`scripts/ci/tests/no-docker.test.sh` runs a mutated `bin/devenv` whose
commands reach Docker in more than 20 ways, both as `DEVENV` and edited
into the file. The mutant only reads (`docker version`, `GET /version`);
its text is pinned by sha256 and checked before each use. Its target is a
canary engine of the test, which answers like Docker and records every
request.

- **T-03 and T-04:** on macOS, `unit.sh` runs on the host as a developer
  would run it. The mutant must run to its end without a request reaching
  the canary. On Linux, `unit.sh` runs inside the isolation, where the
  canary is a reachable engine, so it must refuse.
- **T-05 (control):** a copy of `unit.sh` without the re-execution, behind
  an outer guard. The mutant must reach the canary. On macOS, that guard
  (also used for every case with `HARNESS=`) has the same write policy and
  denies as `no-docker.sh`. Only the case's own directories are writable,
  and only the canary's socket is reachable.
- Files that code under test could write are read only when they are
  regular files, so a planted FIFO or link cannot hang or redirect the
  test.
- **T-14 and T-23:** the helpers that the test runs outside any isolation
  (`canary.py`, `drive.sh`) and the mutant's text are tracked files in
  `scripts/ci/tests/no-docker/`. Their sha256 values are constants in the
  test, set when they were reviewed, and every copy is checked against
  them immediately before each run outside, so a copy changed at any time
  is never run. The copies are kept outside every directory that code
  under test can write. T-14 checks that a changed copy is detected and not
  run, and T-23 that the values are constants.

The other cases run plain commands that only print, connect, write markers
in the test's directories or send signal 0 or TERM to the test's own
`sleep`:

- **T-00:** the read-only lint of the mutant.
- **T-01 and T-02:** `--check`, and a claimed but unproven isolation.
- **T-07:** loopback ports that were already listening are unreachable,
  while ports opened inside are reachable.
- **T-06, T-08 to T-15, T-21, T-22 and T-24 to T-34, macOS only:**
  - **T-06 and T-11:** the write limits, including that a bash 3.2
    here-document fails;
  - **T-08:** the complete port list;
  - **T-09 and T-12:** the `TMPDIR` allowlist;
  - **T-10:** preferences and `TIOCSTI`;
  - **T-13:** a canary outside cannot be signalled (EPERM) and survives,
    while the command's own child and process group can be signalled;
  - **T-14:** integrity of the helpers;
  - **T-15:** `--work`, accepted and refused cases;
  - **T-21:** canary files named like bash 3.2 here-document files in
    `/tmp` and `/private/var/tmp` (random names, created exclusively, read
    and removed only while they are the files created) cannot be opened for
    writing, truncated, removed, renamed, replaced or chmodded, and none can
    be created;
  - **T-22:** a file outside the run's directory cannot be changed through
    a hard link, a symbolic link, a rename over it or an exchange;
  - **T-24:** four processes the command leaves (a background child, a
    `setsid` daemon after a double fork, a `posix_spawn` child in a session
    of its own, a process group of its own) are all ended, after a normal
    end, a failed command and a command killed by SIGKILL;
  - **T-25:** SIGINT, SIGTERM and SIGHUP to `no-docker.sh` end the command
    and those four processes at once (status 128 plus the signal);
  - **T-26:** after SIGKILL of `no-docker.sh`, its leftovers keep a new run
    from starting (125) until they are ended through the run's marker
    directory, whose owner is gone;
  - **T-27:** when the probe cannot make the markers, look for leftovers or
    supervise, the command is not run;
  - **T-28:** a debugger attach from inside to a test canary outside that
    allows debuggers fails, while it works from outside;
  - **T-30:** a process that keeps forking and ending is never reported as
    ended; new runs refuse while it runs and start after it ended;
  - **T-31:** two runs at the same time each end their own processes and
    do not refuse each other;
  - **T-32:** processes that start and end outside meanwhile do not make
    the ending fail;
  - **T-33:** an ending that cannot be shown fails the run (125), ends the
    supervisor's own child and keeps the marker directory;
  - **T-34:** SIGTERM at several moments while the command starts processes:
    every run ends in time and none of its processes survives;
  - **T-29:** another terminal's device cannot be read from inside, while
    it can from outside.
- **T-16 to T-18, Linux only:**
  - **T-16:** a canary inside sees only the namespace's processes, cannot
    read `/proc/1/root` and cannot connect to any engine, session or host
    socket. It gets EROFS in `$HOME`, the workspace, `$RUNNER_TEMP` and the
    tool cache, and sees a private `/tmp` and `/dev/shm`, read-only mounts,
    masked cgroups, private IPC and loopback only;
  - **T-17:** a `setsid` daemon, checked to be running before the command
    returns, does not outlive the command, neither when the command ends
    nor when SIGTERM is delivered to `no-docker.sh` itself. A cancelled
    GitHub step does not signal `no-docker.sh`, so that case is not
    covered;
  - **T-18:** uid 0 (a real `sudo` run), missing or other runner variables,
    a workspace outside `$HOME` and a caller without a `Runner.Worker`
    ancestor are refused.
- **T-19:** the static CI order check, on both platforms.
- **T-20:** a static check that the code run inside the isolation has no
  here-document or here-string, on both platforms.

The macOS cases run only on a developer's Mac: there is no macOS CI job.

#### Mutation testing

- Run a mutated copy of `bin/devenv` or of a guard only through these
  suites, on a macOS developer machine or in CI. On Linux outside CI the
  suites refuse to run.
- Until a CI run on the GitHub-hosted runner has shown the Linux cases
  T-16 to T-18 passing, use only payloads that read or print, on both
  platforms.
- Never use a destructive Docker command (prune, forced removal, `down -v`,
  `--rmi`), not even in isolation.
- `tests/devenv/integration.sh` and the `tests/app/` suites use the real
  Docker daemon on purpose, so never run them on a mutated copy.
  `integration.sh` refuses a `DEVENV` that differs from `bin/devenv`, but no
  suite can tell an edited checkout from a mutated one.
- BE-18 mutates a copy of the backend inside the api test container, which
  has no Docker socket.

Application suites (`tests/app/`), each in its own Compose projects:

- `scan.sh` (SC-xx): Trivy scans of the runtime images (production-like api
  and edge, db), which fail on any HIGH or CRITICAL finding, and of the
  development images, which are reported; each scan must inventory the
  expected package sources (Alpine packages, Composer, the Caddy binary,
  Node packages), and control scans prove the gate fails on a vulnerable
  image and on an image without inventoried packages; it also adapts the
  edge configurations (prod, dev, HTTPS test edge) with the built Caddy
  binary and rejects admin, config persistence, PKI, issuers, ACME and the
  `acme_server` handler, with a control image that must fail (see
  [security/container-vulnerabilities.md](security/container-vulnerabilities.md),
  "Edge configuration guard"; the static half is
  `scripts/ci/guard-edge-config.sh` in `Repository guard`).
- `backend.sh` (BE-01 to BE-18): PHP 8.5 runtime, `composer validate` and
  `composer audit`, PHP-CS-Fixer, PHPStan (level max), migrations from an
  empty database, `doctrine:schema:validate`, a full down/up migration round
  trip, PHPUnit unit and integration suites against a real PostgreSQL
  (project `<project>-test`, database on tmpfs, no published ports), and the
  architecture rules: Deptrac with `deptrac.modules.yaml` and
  `deptrac.layers.yaml`, and the architecture test suite (see
  [architecture/backend-modules.md](architecture/backend-modules.md)). The
  integration suite also runs sessions through a real PHP-FPM; BE-14 checks
  the session and cache configuration of dev and prod, BE-15 the PHP-FPM
  request time limit (see
  [architecture/sessions-and-cache.md](architecture/sessions-and-cache.md)).
  The suites connect as the runtime role `flowcrm_app`; migrations (BE-06 to
  BE-08) run as `flowcrm_owner`. BE-16 verifies the privilege manifest as the
  runtime role, BE-17 which secrets each service of the dev and prod Compose
  configuration receives (see
  [architecture/adr/ADR-018-database-roles.md](architecture/adr/ADR-018-database-roles.md)).
  The integration suite includes the API security tests (login, sessions,
  request forgery, throttling, tenant isolation) through a real PHP-FPM,
  each response checked against `backend/openapi.yaml`; BE-18 runs the
  security negative controls: 53 mutations of a copy of the backend, each
  of which must make its tests fail (see
  [architecture/authentication.md](architecture/authentication.md#tests)).
- `frontend.sh` (FE-01 to FE-05): `npm audit`, strict type check, ESLint
  without warnings, Vitest component tests and the production build.
- `stack.sh` (ST-01 to ST-73): the real stack through `bin/devenv` in fresh
  copies of the checkout on the 20 ports from `DEVENV_TEST_PORT_BASE`
  (default 18300): exposure, networks, non-root and read-only containers,
  routing through Caddy, API and health responses, readiness with a pending
  migration and with a stopped database, persistence across down/up and
  restart, a port conflict, checkout isolation, a Playwright browser
  journey including the HMR connection, the raw-path routing boundary,
  per-service hardening with negative controls, lost secrets, source edits
  and migrations added while running, both stacks in one checkout, and the
  structured logs (request ID in the api and edge logs, complete JSON
  records, no tokens in any log), lazy sessions (no cookie and no stored
  session for stateless requests) and the session and cache migration
  through `make up` with an incompatible and a compatible existing table,
  and the database roles: the api's role and secrets, privilege drift on a
  running stack stopping the edge, missing or malformed role secrets failing
  closed, rotations interrupted at each step and while waiting on a lock
  (finished or aborted, for both roles, with a failed api recreation), a
  volume created as before the role separation being refused, upgrades
  interrupted after the backup and while waiting on a lock, backups that do
  not restore, differ or are damaged, the upgrade itself (rows, triggers and
  migration history kept) and a second upgrade without changes, an
  unreadable credential answering 503 through the edge, and cancellations
  that cannot be confirmed (db container paused, old script not ending, a
  foreign holder of the advisory lock) keeping the stack blocked until the
  old operation has ended, and SIGKILL of `bin/devenv` during a rotation,
  an ownership conversion and after a committed but unverified change, with
  the edge already stopped before the change began; the security gate
  enforced by the running edge (only `/health/live` and `/health/ready`
  answered while it is recorded), kept through SIGKILL, SIGINT and SIGTERM
  while the edge comes back after a rotation and through a `make up`
  killed before its checks finished, and an edge without the gate mount
  being recreated by `make up`; and the upgrade of a
  volume from FND-004 (before the audit log existed) and of one whose audit
  triggers were disabled or dropped (refused); and authentication through
  the edge with users created by the operator console: the session cookie's
  attributes, logout with the CSRF token and a replayed cookie, logins from
  another origin and with a form body, spoofed `X-Forwarded-For` that cannot
  evade the login limit, no secrets in any log, and the logged-in browser
  journeys (roles, two organizations, a foreign organization, CSRF).
- `prodlike.sh` (PL-01 to PL-23): the production images (`<project>-prod`,
  no published ports): built SPA, CSP, cache headers, SPA fallback, API
  errors, health, the raw-path routing boundary, a Playwright journey
  under the CSP, lazy sessions in production mode, the `migrate` job
  completing as the owner before the api starts, and the production session
  cookie (`__Host-`, `Secure`) of a login. Then the edge is recreated with
  the HTTPS test sites of `tests/app/https` (a throwaway certificate made
  with `openssl` per run): the production cookie, the logged-in journeys and
  cross-site forgeries in Chromium over TLS, spoofed forwarding headers, no
  CORS, and a TLS proxy the edge does not trust failing closed.

Each application suite uses Compose project and image names unique to the
run, so several runs from one checkout do not interfere.

- `tests/devenv/unit.sh` covers configuration validation, candidate order,
  state parsing and writing, failure classification, project naming and
  the lock (stale, reused-PID, foreign-host, reap-guard, legacy and
  malformed records; real lock holders in other locales and time zones; a
  recorded child that survives `SIGKILL` of its owner; a recorded leader
  whose descendant outlives it; signal forwarding), the check of a
  recreated container after a secret change (with fake Compose and Docker:
  a container still starting, unhealthy, without a health check, not
  replaced or mounting an old secret is refused, also when Compose reported
  success), the edge's return after a rotation (it must answer readiness;
  otherwise it is stopped, the gate is recorded again and the command
  fails), a security gate that cannot be recorded (reported on stderr,
  never a success), the Makefile interface
  (targets and the commands they run), the test runners' image removal
  (by name only, see "Removing test images") and checks that the result tally
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

### Removing test images

The suites remove their images with `remove_images` in `tests/app/lib.sh`:
by name, never by image ID and never with `--force`. An image ID can carry
several names (`scan.sh` re-tags the pinned PostgreSQL base image as its
control image, and `docker tag` can give any name to an existing ID), and
`docker image rm -f <ID>` deletes every one of them. Removing a name
deletes the image only when it was the last name. `remove_images PREFIX`:

- removes only the names that start with the run's prefix (`<project>-` of
  the run's Compose project, or the run's `repository:tag`);
- when the image also has another name, removes only the run's name and
  reports the other names;
- keeps, and reports, an image used by any container;
- refuses an empty prefix, characters outside image names and any prefix
  that could match this checkout's development stack (`<project>-<service>`)
  other than a run project (`<project>-test-<run>-`, `<project>-prod-<run>-`);
- prints one line per call with the number of names removed and kept.

A rebuild within a run (`stack.sh` rebuilds a checkout after editing it)
moves the name to the new image. With Docker's classic image store the
previous image stays untagged (`<none>`), which a removal by name cannot
reach. With the containerd image store (Docker Desktop) a rebuild with
BuildKit or Compose drops the previous image, even while a container still
uses it; there an untagged image is left only when `docker tag` moves a name
to another image. The runners with a Compose
project of their own (`backend.sh`, `prodlike.sh` and, for each temporary
checkout, `stack.sh`) therefore also call `remove_untagged_images PROJECT`
after `remove_images`. It:

- selects only images that are untagged and carry the run's project label:
  `docker image ls -q --no-trunc --filter dangling=true --filter
  label=com.docker.compose.project=PROJECT`;
- removes each by ID without `--force`: an untagged image has no name that
  could belong to someone else, and Docker refuses to remove an image that a
  container uses or that has child images;
- skips, and reports, an image that got a name after it was listed or that a
  container uses, and reports every image Docker refused;
- refuses an empty project name, one that is not a Compose project name
  (lowercase letters, digits, `_` and `-`, starting with a letter or digit),
  and any name the prefix check above refuses as `PROJECT-`, which includes
  this checkout's development stack;
- prints one line per call with the number of images removed and kept.

`frontend.sh`, `scan.sh` and the browser test image (`flowcrm-e2e:<run>`)
build with `docker build` and no Compose project label. Each of their tags
is built once per run, so they leave no untagged image of their own; any
untagged image without the label is left alone. BuildKit's build cache is
not touched.

`tests/devenv/unit.sh` (U-26) checks both helpers with a fake Docker that
removes every name of an image removed by ID or with force, and checks that
`backend.sh`, `prodlike.sh` and `stack.sh` call `remove_untagged_images` with
their own project. It checks that each runner calls `remove_images` only
with its run's prefix (`$project-`, `$(project_of "$d")-` for the temporary
checkouts of `stack.sh`, `$e2e_image`, `$image`, `$tag:`), and that each of
these variables is assigned once, from a hash of the run's temporary
directory (`flowcrm-scan-<run>`, `flowcrm-web-check:<run>`,
`flowcrm-e2e:<run>`, `<project>-test-<run>`, `<project>-prod-<run>`). It also checks every `tests/app/*.sh` and
`tests/devenv/*.sh` file (excluding its own grep pattern lines and those of
U-09) and fails if:

- `docker image rm`, `docker image remove` or `docker rmi` appears outside
  `tests/app/lib.sh`;
- one of these commands has `-f`, a short option group containing `f`, or
  `--force` anywhere in the same command (up to `|`, `;` or a `&` that is
  not part of a redirection such as `2>&1` or `&>`);
- `--rmi` appears (Compose `down --rmi`);
- any `docker ... prune` appears (`image`, `system`, `builder`, `buildx`
  or any other prune).

A line that ends in a backslash continues on the next line: the check joins
such lines first, so a command split over several lines is checked as one
line. A fixture checks that removals and prunes split this way, and a force
option after a redirection, are found.
These are text checks: a removal written so that it does not match them
(for example through a variable holding the command) is not detected.

To remove leftover test images by hand (for example after a runner was
killed with `SIGKILL`), list the candidates of one run project, check that
every name of each image belongs to it and remove them by name:

```console
$ docker image ls --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep '^flowcrm-<hash>-test-<run>-'
$ docker image inspect --format '{{.RepoTags}}' flowcrm-<hash>-test-<run>-api:latest
$ docker image rm flowcrm-<hash>-test-<run>-api:latest
```

Then remove that project's untagged images by ID, without `-f`:

```console
$ docker image ls -q --no-trunc --filter dangling=true --filter label=com.docker.compose.project=flowcrm-<hash>-test-<run>
$ docker image rm <ID>
```

Do not remove a named image by ID, and do not remove images with `-f`,
with `docker image prune -a` or `docker system prune -a`, or through bulk
removal of "unused" images in Docker Desktop: these also delete other projects' images, including the
development stack's. A running container does not keep its image's name:
with the containerd image store (Docker Desktop), a `make up` that rebuilds
an unchanged image gives it a new image ID (BuildKit's attestation index
changes) while the platform image stays the same, so Compose keeps the
running container. The container then refers to the previous ID, and the
name points to an image that no container uses. A bulk removal of unused
images deletes such names of the development stack; its containers keep
running, and the next `make up` rebuilds the images.

The interface the future application stack has to provide is described in
[architecture/development-lifecycle-contract.md](architecture/development-lifecycle-contract.md).
