# Development environment

`make` commands start this checkout's Docker Compose project and publish its
HTTP edge on `127.0.0.1` without manual port configuration.

> **Current stage:** the stack is a development fixture
> (`compose.fixture.yaml`): a minimal BusyBox HTTP server (`edge`) and an
> unpublished helper with a named volume (`state`). It exists to exercise the
> port allocator and the lifecycle commands. The Symfony backend, the React
> frontend and PostgreSQL are not part of it yet, and a healthy fixture says
> nothing about their readiness.

## Prerequisites

| Tool | Notes |
|---|---|
| Docker Engine or Docker Desktop | daemon must be running |
| Docker Compose v2 | the `docker compose` plugin |
| GNU Make ≥ 3.81 | the macOS default works |
| bash ≥ 3.2 | `bin/devenv` runs under bash (macOS `/bin/bash` works) |
| `mktemp`, `hostname`, `ps`, `find`, `od`, `sha256sum` or `shasum` | present on macOS and common Linux distributions |
| `lsof` | optional, improves `make ports` |

PHP, Composer, Node.js and Python are **not** needed on the host. Python 3 and
`curl` are used only by the test suite.

Run `make doctor` to check all of this. It changes nothing.

## First start

```console
$ make up
FlowCRM development fixture: http://127.0.0.1:8080
$ make url
http://127.0.0.1:8080
```

`make up` validates the configuration and prerequisites, starts the internal
services, binds the edge, checks the actual Docker mapping and `GET /health`,
saves the verified port and prints the URL.

## Commands

| Command | Behaviour |
|---|---|
| `make up` | Start or reconcile the stack; print the URL. Running it again on a healthy stack changes nothing. |
| `make down` | Stop and remove this checkout's containers and network. **Volumes and the saved port are kept.** |
| `make restart` | `down`, then `up`; the saved port is tried first. |
| `make status` | Show the project name, saved port, each service's state and health and the actual mapping. Exit 1 unless the edge is running, healthy and matches the saved port. |
| `make url` | Print the verified URL. Fails when the edge is not running, does not answer `/health` or its mapping differs from the saved port. |
| `make ports` | Read-only: the candidate ports in order, whether something accepts connections on them, and the container or process using them (best effort). |
| `make logs` | Recent logs of this project only. `SERVICE=edge\|state`, `TAIL=200`, `FOLLOW=1`. |
| `make doctor` | Read-only prerequisite and configuration check. |
| `make help` | List the targets. |
| `make test-devenv` | Run the allocator tests (see below). |

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
reports a port conflict (`port is already allocated`, `address already in
use`, `Ports are not available`), the next candidate is tried. **Every**
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
  Docker mapping and `/health` were checked. A failed start never replaces it.
- It is read as data with a fixed set of keys; it is never executed. A
  corrupt, unknown-schema, symlinked or oversized file is ignored and
  replaced on the next successful start.
- If the saved port is taken by something else, the next candidate is used
  and the file is updated.
- If the running edge uses a different port than the saved one (for example
  the file was edited), `make url` and `make status` report the mismatch and
  `make up` reconciles the file with the actual mapping.
- The file contains no secrets.

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

The lock records host, boot id, PID, the PID's start time and a random
token. It is removed automatically only when it provably belongs to a dead
process on this host (or to a previous boot); a reused PID is detected
through its start time. A lock from another host is never removed
automatically. Ctrl-C or `SIGTERM` releases the lock; after `SIGKILL` the
next command removes the stale lock. The saved state is never left half
written.

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
| `… other than a port conflict` (exit 2) | the edge started but failed; see `make logs`, fix, run `make up` again |
| `internal services failed to start` (exit 2) | the unpublished services failed; no port was involved |
| `Docker daemon is not reachable` (exit 5) | start Docker Desktop or the Docker service |
| `waiting for another devenv command` | another command runs in this checkout; it is waited for |
| `holds .runtime/lock … gave up` (exit 4) | a command is still running, or a lock from another host; remove `.runtime/lock` only if no command runs |
| refused with exit 6 | resources of another checkout; see the message |

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
$ make test-devenv                               # unit + integration
$ tests/devenv/unit.sh                           # no Docker needed
$ DEVENV_TEST_PORT_BASE=18080 tests/devenv/integration.sh
```

- `tests/devenv/unit.sh` covers configuration validation, candidate order,
  state parsing and writing, failure classification, project naming and
  the lock (including stale, reused-PID, foreign-host and reap-guard cases).
- `tests/devenv/integration.sh` runs scenarios PA-01 to PA-20 and the
  Makefile targets against real Docker in temporary checkout copies. It uses
  the 20-port block starting at `DEVENV_TEST_PORT_BASE` (default 8080) and
  skips with exit 77 if any of those ports is in use, so it never competes
  with running stacks. It removes only the containers, volumes and networks
  it created (checked by label) and verifies that pre-existing containers,
  volumes and networks are unchanged.

Both suites run locally on macOS (Docker Desktop, bash 3.2) and in GitHub
Actions on Ubuntu (Docker Engine, bash 5) in the `Dev environment` job.
