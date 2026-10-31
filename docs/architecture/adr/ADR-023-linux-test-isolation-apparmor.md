# ADR-023: Kernel-enforced isolation of code under test from the Docker API on Linux CI

- **Status:** proposed. It is not accepted until the owner decides, after
  the Linux regression cases have run on a GitHub-hosted runner.
- **Related:** [development environment](../../dev-environment.md),
  "Isolation from Docker" and "Linux"; `scripts/ci/no-docker.sh`,
  `scripts/ci/no-docker-aa.py`, `scripts/ci/no-docker-probe.py`,
  `scripts/ci/no-docker/apparmor.profile`.

## Context

`tests/devenv/unit.sh` and the guard suites run code under test, mutated
copies included, under `scripts/ci/no-docker.sh`. On Linux (GitHub-hosted
runners only) that code must not reach the host's Docker Engine API or
other Unix sockets of the host.

Until now the Linux isolation listed the host's Unix sockets before each
run and tried every one from inside. The listing had two problems:
- **It could not be shown complete.** A socket only in flight, held by the
  kernel or in some io_uring tables could be missed.
- **It was slow.** When the fast kernel listing could not prove itself
  complete, the walk of every local file system took about 140 to 150
  seconds per run (measured).

The AppArmor spike (runs 41200868832 and 41209833578, on `7.0.0-1017-azure`
with apparmor_parser 4.0.1) established a kernel mechanism instead. A
profile without `attach_disconnected`, on a process in a private mount
namespace, denies every connect or send to a pathname socket bound outside
that namespace, whatever the path. The denial is Ubuntu's AppArmor code
(`RULE_MEDIATES_UNIX`).

## Decision

Replace the enumeration with kernel enforcement, on GitHub-hosted Linux
runners only. macOS is unchanged.

1. **One profile per launch.** `no-docker-aa.py` (root, through sudo, in
   reviewed argv shapes) loads a profile named `flowcrm-nd-<random>`.
   - It is loaded only from the pinned template (sha256 constant), added and
     never replaced.
   - It attaches with `aa-exec` after `setpriv` has dropped privileges,
     inside the existing network, mount, pid and IPC namespaces.
2. **A functional proof per launch (the fence).** Before the command
   starts, the process that will become the command (`no-docker-probe.py
   --gate-exec`) must find two sockets of the launch, bound outside, refused
   with `EACCES` exactly.
   - File permissions are first shown to allow them (`faccessat`), so the
     refusal can only come from the profile.
   - Its label must be exactly `NAME (enforce)`.
   - A socket it binds inside must connect.
   - On a kernel, parser or image where the denial does not hold, every
     launch refuses (125).
3. **A descriptor boundary.** The command receives exactly:
   - `/dev/null` as stdin, opened inside;
   - pipes to relays of `no-docker.sh` as stdout and stderr.

   `--root-exec` closes every other descriptor and verifies it. The gate
   checks its own descriptor table last, then execs the command in its own
   process, after resetting the signal dispositions. A caller's stdout or
   stderr that is a socket or terminal is refused.
4. **A profile lifecycle that never unconfines a live process.** Removing
   a profile unconfines any task that still carries it. The profile is
   removed only after all of these hold:
   - **P0:** a root-owned record of the launch's pid namespace exists,
     written by its pid 1 before anything untrusted runs (or by `kill-init`
     from the verified pid 1);
   - **P1:** no task is in that namespace but its zombie init (the kernel
     kills every other task before init becomes a zombie,
     `zap_pid_ns_processes`);
   - **P2:** the profile is unchanged;
   - **sweeps:** two complete system-wide sweeps find no carrier.

   Any doubt keeps the profile loaded and the run fails (125, the control
   directory kept and named). The launch state is written before each
   transition and read back.
5. **Fail closed throughout.**
   - The preflight checks that AppArmor is enabled, in enforce mode, with
     the `af_unix` class, and that the tools exist.
   - Labels must match exactly.
   - One guarded cleanup acts only on what was recorded.
   - Exit precedence: a cleanup failure gives 125; the negative control
     gives 125; a signal gives 128 plus the signal; a refusal gives 125.
6. **No global AppArmor change.** No reload, replacement, mode change or
   configuration write. Static rules (T-39) check this on every run.

## Alternatives considered

- **Keep the enumeration and accept its residual, or always run the walk.**
  The enumeration is not provably complete, and the walk costs 140 to 150
  seconds per launch.
- **A seccomp filter denying `AF_UNIX`.** It breaks the code under test's
  own sockets.
- **Landlock.** Not available for this on the runners' kernel.
- **One profile per job, or never removing profiles.** Leftovers would mix
  launches, and removal could not be tied to one launch's namespace.
- **Attaching before `setpriv` (order B).** It would need capability rules
  in the profile.

## Kernel and runner prerequisites

- AppArmor enabled and in enforce mode, with `features/network/af_unix`
  (Ubuntu's v7/v8 class, which the noble parser targets).
- `kernel.apparmor_restrict_unprivileged_unconfined=0`; with 1 the label is
  stacked and every launch refuses.
- Passwordless `sudo`, `aa-exec`, `apparmor_parser`, `setpriv` and
  `unshare` (util-linux). sudo's default `closefrom` and `env_reset` are
  recorded, not relied on.

## Consequences

**Positive:**
- The kernel refuses every host-bound pathname socket, including late,
  aliased, unlistable and datagram ones; the enumeration's residuals are
  gone.
- The guard job's estimated time drops to about 317 to 382 seconds (an
  estimate from component bounds; the 600-second timeout is unchanged, and
  L-16 fails above a projected 540 seconds).

**Accepted residual risks** (docs/dev-environment.md):
- **RR-01:** a runner cancellation leaves confined processes running and the
  profile loaded until the VM is discarded.
- **RR-02 and RR-03:** kernel or image drift, or the sysctl, make every
  launch refuse.
- **RR-04:** io_uring, rename and hard-link paths rest on reading the
  kernel source.
- **RR-05:** a path that root makes into the namespace.
- **RR-06:** a late chain after a signal in the start window (its gate
  refuses, and the profile stays loaded).
- **RR-07:** a trusted actor attaching after the last sweep.
- **RR-08:** audit records may be lost.
- **RR-09:** the launch chain must stay as designed.
- **RR-10:** annotation ordering between stdout and stderr.
- **RR-11:** untrapped signals.
- **RR-12:** a reused namespace inode (a false 125 only).
- **RR-13:** no namespace record after an internal fault (the profile stays
  loaded, with no carrier).

## Validation plan

1. Local: the pure and static suites (T-36, T-38, T-39), T-19, ShellCheck
   and the macOS cases. These prove logic and structure, not enforcement.
2. A separately authorized run on a GitHub-hosted runner of the four guard
   suites, `no-docker.test.sh` (L-01 to L-18, T-16 to T-18, T-03 to T-05)
   and `tests/devenv/unit.sh`. That run is the first evidence that this
   implementation, and not only the spike, isolates.
3. Performance taken from that run (L-16 and the job times), not from the
   estimate.

## Rollback

Revert the commits that introduced this change on their branch. The Linux
path then refuses, or uses the previous mechanism of the reverted-to
commit. Profiles never outlive the runner's VM, so nothing persists
between jobs.
