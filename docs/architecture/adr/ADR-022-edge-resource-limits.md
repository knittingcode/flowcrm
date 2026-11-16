# ADR-022: CPU, memory and PID limits for the edge container

- **Status:** proposed, **not implemented and not activated**. No Compose
  file sets these limits. Activation needs an owner decision and a separate
  reviewed change (see "Activation").
- **Related:** ADR-021 (go-jose v3 exception, residual availability risk),
  [container vulnerabilities](../../security/container-vulnerabilities.md)
  (deferred hardening items), [authentication](../authentication.md)
  (FND-010V benchmark with container limits)

This ADR does not change ADR-021. The exception in
`security/trivyignore.yaml`, its scope, its expiry (2026-11-30) and its
conditions stay as accepted on 2026-10-28. The limits below are defence in
depth for the availability risk that ADR-021 accepts; they are not a
compensating control of the exception and not a reason to renew or extend
it.

## Context

ADR-021 accepts a residual availability risk: if a configuration enabled an
ACME server or a mutable admin API, a remote client could exhaust the
edge's CPU, and "the edge has no CPU or memory limits, so the API and
database on the same host could suffer too". With `acme_server` enabled,
one unauthenticated request with the advisory's crafted key cost about
2.2 s of CPU (ADR-021, runtime check).

Current state on `main` (`1badf76`):

- No Compose file (`compose.yaml`, `compose.prodlike.yaml`,
  `compose.test.yaml`, `compose.fixture.yaml`,
  `tests/app/https/compose.https.yaml`) sets `cpus`, `mem_limit`,
  `pids_limit`, `deploy.resources` or `ulimits` for any service, and
  `bin/devenv` adds no such flags. The edge can use every CPU and all memory
  of the Docker host or VM.
- The edge already runs with `init`, `cap_drop: [ALL]`,
  `no-new-privileges`, a read-only root filesystem, a `/tmp` tmpfs and log
  rotation (3 x 10 MB).
- Neither Caddyfile sets server timeouts or a request body limit; the
  Caddy 2.11.7 defaults apply. The edge configuration guard allows only
  `admin off`, `auto_https off`, `persist_config off` and `log` in the
  global block, so a global `servers` option is out of scope here.
- If the Docker VM runs out of memory, the kernel OOM killer may pick the
  `db` or `api` container instead of the edge.

Caddy 2.11.7 adapts to container limits by itself. `cmd/main.go` calls
`maxprocs.Set` (automaxprocs 1.6.0: `GOMAXPROCS` from the cgroup CPU quota)
and `memlimit.Set` with the cgroup as provider (automemlimit 1.0.0: a soft
`GOMEMLIMIT` of 0.9 x the cgroup memory limit). With a limit, the Go
runtime schedules and collects garbage within it, so a kernel OOM kill is
less likely at normal load.

### What is measured, and what is not

| Data | Source | Used for |
|---|---|---|
| about 2.2 s CPU per unauthenticated request with `acme_server` enabled; about 0 s (404) with FlowCRM's configuration | ADR-021, runtime check | the CPU limit bounds this worst case to one core |
| api benchmark with Docker limits: 1 CPU / 512 MB and 2 CPUs / 1 GB, all logins through the real production edge succeeded | [authentication](../authentication.md), FND-010V | precedent for a "small instance" budget; the edge itself was not limited in that run |
| edge CPU, RSS and thread count under the stack and prod-like tests | **not measured** anywhere in the repository | the values below are therefore conservative ceilings, not tuned numbers |

## Proposal

Add three service-level keys to the `edge` service in `compose.yaml`, and
nowhere else. `compose.prodlike.yaml`, `compose.test.yaml` and
`tests/app/https/compose.https.yaml` are overrides of `compose.yaml`, so the
same limits apply to the development, test, prod-like and HTTPS test edges.

```yaml
  edge:
    # ... existing keys unchanged ...
    logging: *request-logs
    # Bounds what a request flood or a CPU-heavy request on the edge can take
    # from the api and db on the same host (ADR-021 residual risk, ADR-022).
    cpus: "1.0"
    mem_limit: 256m
    pids_limit: 256
```

This snippet is the proposed change. It is not in `compose.yaml`.

| Key | Proposed value | Rationale |
|---|---|---|
| `cpus` | `"1.0"` | The edge is a reverse proxy for one developer or one test harness. One CPU caps the ADR-021 worst case (about 2.2 s CPU per request) at one core and leaves the rest to api and db. Caddy then runs with `GOMAXPROCS=1`. It matches the 1-CPU small-instance budget of the FND-010V api benchmark. |
| `mem_limit` | `256m` | Half of the api's tested 512 MB small-instance budget, and an upper bound for an idle-to-moderately-loaded Caddy. Caddy sets `GOMEMLIMIT` to about 230 MiB. To be confirmed by the measurement below: the limit must be at least 4 x the observed peak. |
| `pids_limit` | `256` | Caddy does not fork. The limit stops runaway growth of OS threads (Go threads blocked in system calls) and is far above the expected count. To be confirmed by the measurement below. |

Values must be literals. The edge configuration guard rejects `${VAR}`
interpolation in a Compose file outside ports, a volume source and a secret
file, so `cpus: ${FLOWCRM_EDGE_CPUS:-1.0}` would fail the `Repository
guard` job. Making the values configurable would need a guard change and
its own review; it is not proposed.

### Alternatives

- **`deploy.resources.limits`** (`cpus`, `memory`, `pids`): equivalent in
  `docker compose`. The service-level keys are flatter and match the block
  style of `compose.yaml`. Either form is acceptable; the owner chooses.
- **`memswap_limit` equal to `mem_limit`**: without it, Docker allows swap
  up to the same amount again. Setting it makes the memory bound strict, at
  a higher risk of an OOM kill instead of slowdown. Open decision.
- **Limits on `api`, `db` and `web` too, Caddy timeouts, a
  `request_body` limit:** separate scope. A `request_body` limit is a
  Caddyfile change that the guard parses and that needs its own review.
- **No limits:** keeps the documented residual risk unchanged.

## Verification before activation

The change that activates the limits must show, in CI and in the pull
request:

1. **Measurement first.** Record the edge's peak CPU, memory and PIDs
   (`docker stats --no-stream` sampled during the run) during
   `tests/app/stack.sh` (browser tests through the edge, the ST-50
   interruption tests) and `tests/app/prodlike.sh` (production and HTTPS
   test edges). Set `mem_limit` to at least 4 x the observed memory peak
   and `pids_limit` well above the observed peak, or keep the values above
   if they already satisfy that.
2. **Static checks:** `scripts/ci/guard-edge-config.sh` and its regression
   suite stay green. CI's `Validate Compose configuration` step
   (`docker compose ... config --quiet` for all four file combinations)
   stays green.
3. **Runtime assertion:** extend `hardening_problems` in
   `tests/app/stack.sh` so the running edge must have
   `HostConfig.NanoCpus`, `HostConfig.Memory` and `HostConfig.PidsLimit`
   set to the expected values, with a negative control (a container
   without the limits is reported), so the limits cannot disappear
   silently. `tests/app/prodlike.sh` has no hardening check today; whether
   it gets one for the prod-like edge is part of the activation change.
4. **No regression:** the full CI is green, including `stack.sh` and
   `prodlike.sh`; no edge healthcheck (`timeout: 3s`,
   `start_period: 20s`) fails, and no step slows down or times out. Report
   the measured durations before and after.
5. **Recreate behaviour:** `make up` on an existing stack recreates the
   edge because its configuration changed. Confirm that the security gate
   (`/run/flowcrm-gate`) stays fail-closed across the recreate, as the
   existing interruption tests require.

## Risks

- **OOM kill of the edge.** A limit that is too low turns load into a kernel
  OOM kill and a restart of the edge, which is an outage of the whole stack
  for its user. `GOMEMLIMIT` is soft: under a sustained flood the Go runtime
  can exceed it and the kernel then kills the process. Mitigation: the
  4 x margin from the measurement, and the runtime check above.
- **Configuration reload.** In FlowCRM's configuration the edge cannot
  reload its configuration at run time: `admin off` disables the admin API,
  and the guard rejects `--watch` and `--resume`. A configuration change
  recreates the container, and Caddy loads one configuration at start.
  Should a later, separately reviewed change allow reloads, Caddy would
  hold the old and the new configuration at once during the switch, which
  needs more headroom; the memory limit must then be re-measured. Startup
  (loading the static TLS certificate of the HTTPS test edge, building the
  routes) must also fit in the limit, which step 1 covers.
- **Slower tests.** One CPU can lengthen parallel browser tests through the
  edge. Mitigation: step 4 compares durations; raise `cpus` if a step
  times out rather than lengthening timeouts.
- **Not a DoS fix.** The limits bound the damage to api and db; they do
  not stop a flood from making the edge itself unavailable. The ADR-021
  guards remain the control that keeps `acme_server` and the admin API
  off.
- **Platform differences.** Docker Desktop's VM and a Linux host enforce
  the same cgroup limits, but the VM's own memory is a further, shared
  bound. The measurement should state the platform.

## Activation

Not activated. Activation requires:

1. An owner decision to accept this proposal, including the values, the
   key form (service-level or `deploy.resources.limits`) and the
   `memswap_limit` question.
2. A separate pull request with the Compose change, the runtime assertion,
   the measured values and the green CI described above. A Compose change
   is a review trigger of ADR-021, so that pull request also gets the edge
   review that ADR-021 requires.
3. In the same pull request, the factual documentation updates: the
   ADR-021 consequence sentence "The edge has no CPU or memory limits"
   (a factual update, not a change of the exception's scope), the
   container vulnerabilities document, and this ADR's status.

Until then, the edge has no CPU, memory or PID limits, and the residual
risk stated in ADR-021 is unchanged.
