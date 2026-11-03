# FCRM-SEC-030 WI-9 R2 expected evidence

Derived by `derive_expected.py` from source commit `5bcdd1bf6b03a18aeefe854f0cbad1a07f6ce33c` (its
`scripts/ci/tests/no-docker.test.sh` and the checkers of T-19, T-36, T-38
and T-39, run on that tree). `run.sh` compares the raw outputs of a run
with it: every block between its markers is read literally.

## Result lines of a successful Linux run (176: 97 L lines, 79 T lines)

Exactly these lines, each once, and no other `PASS`, `FAIL` or `SKIP` line.

<!-- pass begin -->
```text
PASS  T-00 the read-only lint rejects a payload with a non-read-only command (9 variants)
PASS  T-01 --check fails outside the isolation
PASS  T-02 claimed but unproven isolation (NO_DOCKER_ACTIVE outside it): refused by the mechanism check, command not run
PASS  T-07 a loopback port listening before the isolation is unreachable, one opened inside it is reachable
PASS  T-16 inside the isolation: private pids, confined, host sockets refused, read-only $HOME/workspace/RUNNER_TEMP, private /tmp, read-only mounts, masked cgroups, private IPC
PASS  T-17 a daemonised process does not outlive the isolated command
PASS  T-17 TERM delivered to no-docker.sh itself kills every process inside the isolation (143)
PASS  T-18 uid 0 (sudo): refused
PASS  T-18 RUNNER_ENVIRONMENT unset: refused
PASS  T-18 RUNNER_ENVIRONMENT=self-hosted: refused
PASS  T-18 GITHUB_ACTIONS unset: refused
PASS  T-18 GITHUB_WORKSPACE outside $HOME: refused
PASS  T-18 --negative-control off a GitHub-hosted runner: refused
PASS  T-18 --negative-control in a nested run: refused
PASS  T-18 no Runner.Worker ancestor: refused
PASS  L-01 inside: stream to a socket of the host is refused with EACCES
PASS  L-01 inside: dgram-connect to a socket of the host is refused with EACCES
PASS  L-01 inside: dgram-send to a socket of the host is refused with EACCES
PASS  L-01 inside: abstract to a socket of the host is refused with ECONNREFUSED
PASS  L-01 inside: the command is confined by exactly its profile in enforce mode
PASS  L-01 control before: stream outside reaches the same socket
PASS  L-01 control before: dgram-connect outside reaches the same socket
PASS  L-01 control before: dgram-send outside reaches the same socket
PASS  L-01 control before: abstract outside reaches the same socket
PASS  L-01 control after: stream outside reaches the same socket
PASS  L-01 control after: dgram-connect outside reaches the same socket
PASS  L-01 control after: dgram-send outside reaches the same socket
PASS  L-01 control after: abstract outside reaches the same socket
PASS  L-02 control: outside, the socket is reachable through the alias
PASS  L-02 inside: a connect through the alias is refused with EACCES
PASS  L-02 the run proceeds (the command ran)
PASS  L-03 N1 control: outside, the socket in the unlistable directory is reachable
PASS  L-03 N2 control: outside, the socket in the unlistable directory is reachable
PASS  L-03 N1 inside: the run proceeds and the connect is refused with EACCES
PASS  L-03 N2 inside: the run proceeds and the connect is refused with EACCES
PASS  L-03 N0: a socket file without a listener is ECONNREFUSED inside and outside
PASS  L-04 control: outside, the late socket is reachable
PASS  L-04 inside: a socket bound after the start is refused with EACCES
PASS  L-04 the order: the command started, then the socket was bound, then the connect
PASS  L-05 the gate's twin socket inside connected
PASS  L-05 a stream socket pair of the command in /tmp connects
PASS  L-05 a datagram socket pair of the command in /tmp exchanges a message
PASS  L-06 a grandchild of the command carries exactly the profile
PASS  L-06 the command runs in the gate's own process
PASS  L-06 inside: change_profile to unconfined is denied
PASS  L-06 inside: aa-exec -p unconfined is denied
PASS  L-06 inside: unshare -U is denied
PASS  L-06 the command ignores no signal (SigIgn)
PASS  L-06 the command blocks no signal (SigBlk)
PASS  L-06 inside: an AF_VSOCK socket is refused with EACCES
PASS  L-06 control: outside, unshare -U true succeeds
PASS  L-06 control: outside, aa-exec -p unconfined true succeeds
PASS  L-06 control: outside, an AF_VSOCK socket is not refused with EACCES
PASS  L-18 the command's 1 MiB of stdout arrives complete through a pipe
PASS  L-18 the command's 64 KiB of stderr arrives complete
PASS  L-18 the resume token is the last stdout line
PASS  L-17 the command's last workflow command comes before the resume token (ignored)
PASS  L-11 the preflight recorded the parser and the kernel's network features
PASS  L-11 the preflight recorded the AppArmor sysctl values and core_pattern
PASS  L-11 the preflight recorded sudo's env_reset and closefrom
PASS  L-11 while the command runs its profile is listed as exactly "NAME (enforce)"
PASS  L-11 the gate passed
PASS  L-11 root's view of the command's exec label is recorded (information)
PASS  L-14 the command ran and its profile was removed
PASS  L-14 no control or fence directory is left
PASS  L-14 no fence listener is left
PASS  L-14 the launcher's descriptors and the relays' pids, fds and parent are logged
PASS  L-14 the relays ended within 1 s of the command
PASS  L-14 no cleanup message and no kill-init in the log of a normal end
PASS  L-07 the caller's stdout a socketpair: refused (125) before anything was made
PASS  L-07 the caller's stdout a pty: refused (125) before anything was made
PASS  L-07 control: the caller's stdout a pipe runs (L-18)
PASS  L-07 control: the caller's stdout a regular file runs (L-14)
PASS  L-08 the gate run with a stray descriptor refuses (125); the command did not run
PASS  L-08 the gate's report names fd 5 and the socket on fd 1
PASS  L-08 the gate's report names the missing confinement
PASS  L-08 control: clean descriptors give no descriptor finding
PASS  L-09 --root-exec closed the inherited fds 5 and 6 and made stdin /dev/null
PASS  L-09 then setpriv failed without privileges; the command did not run
PASS  L-09 control: without them nothing is closed
PASS  L-10 inside: the connect to the descriptor-passing socket is refused with EACCES
PASS  L-10 no descriptor reached the command (outside, a client receives one)
PASS  L-10 the command's descriptors are 0, 1 and 2
PASS  L-12 the negative control exits 125
PASS  L-12 the gate reports the fence reachable (stream and datagram); L-14's normal launch found it refused
PASS  L-12 only /usr/bin/true could have run (the given command did not)
PASS  L-12 the negative-control profile was released
PASS  L-13 release is refused while a process outside carries the profile
PASS  L-13 the profile is still loaded after the refusal
PASS  L-13 once the carrier ended the release removes it
PASS  L-13b with a carrier outside the launch ends 125 and says the profile is still loaded
PASS  L-13b its control directory is kept
PASS  L-13b without the carrier the profile is released with that control directory
PASS  L-13c two concurrent launches both run
PASS  L-13c each released its own profile, once
PASS  L-13c no profile, control directory or run directory of theirs is left
PASS  L-15 TERM: no-docker.sh exits 143 within 150 s
PASS  L-15 pid 1 of the namespace was killed (kill-init)
PASS  L-15 the profile was released after P0 and P1
PASS  L-15 no process of the launch is left
PASS  L-15b unshare killed: released after P1, or left loaded (125) and released afterwards
PASS  L-15b never released as if no namespace had been made
PASS  L-15b the host socket never accepted a connection from inside
PASS  L-15c TERM at 0 ms: an allowed outcome
PASS  L-15c TERM at 20 ms: an allowed outcome
PASS  L-15c TERM at 50 ms: an allowed outcome
PASS  L-15c TERM at 100 ms: an allowed outcome
PASS  L-15c TERM at 200 ms: an allowed outcome
PASS  L-15c TERM at 300 ms: an allowed outcome; no profile of these launches is left
PASS  T-20 code run inside the isolation has no here-document or here-string
PASS  T-23 the helpers run outside any isolation are pinned to reviewed sha256 values, not hashed after writing
PASS  T-36 C01: 2 of 2 assertions pass
PASS  T-36 C02: 13 of 13 assertions pass
PASS  T-36 C03: 12 of 12 assertions pass
PASS  T-36 C04: 14 of 14 assertions pass
PASS  T-36 C05: 9 of 9 assertions pass
PASS  T-36 C06: 15 of 15 assertions pass
PASS  T-36 C07: 7 of 7 assertions pass
PASS  T-36 C10: 8 of 8 assertions pass
PASS  T-36 C11: 7 of 7 assertions pass
PASS  T-36 C12: 9 of 9 assertions pass
PASS  T-36 C13: 9 of 9 assertions pass
PASS  T-36 C14: 4 of 4 assertions pass
PASS  T-36 W: 12 of 12 assertions pass
PASS  T-36 M: 14 of 14 assertions pass
PASS  T-39 S-02: 2 of 2 checks pass
PASS  T-39 S-02b: 2 of 2 checks pass
PASS  T-39 S-03: 2 of 2 checks pass
PASS  T-39 S-03b: 2 of 2 checks pass
PASS  T-39 S-04: 2 of 2 checks pass
PASS  T-39 S-05: 4 of 4 checks pass
PASS  T-39 S-06: 2 of 2 checks pass
PASS  T-39 S-07: 2 of 2 checks pass
PASS  T-39 S-08: 2 of 2 checks pass
PASS  T-39 S-09: 2 of 2 checks pass
PASS  T-40 cleanup against stubs: a failed removal of the fence, control or run directory ends 125 naming it and keeps what the design keeps; otherwise status 0, nothing left
PASS  T-40 mutants of the propagation are caught (fence removal unchecked, failure cleared, status not raised, another directory named)
PASS  T-41 L-16's projection is compared with 540 s exactly: 540 s passes, 540.004 s and 540.04 s fail, 539.95 s passes
PASS  T-42 the opt-in copy of the case outputs keeps regular files with sha256, skips links, FIFOs and unsafe names, refuses an unsuitable destination
PASS  T-42 a directory replaced by a link to outside between its listing and the descent, and a link to a directory, are not followed: no byte from outside is kept
PASS  T-42 a directory replaced by a link to outside after it was opened: its file is read through the directory opened, no byte from outside is kept
PASS  T-42 a destination with a symbolic link among its ancestors is refused (2) and nothing is written
PASS  T-42 a file with a second hard link is not copied (skipped and recorded)
PASS  T-42 a source given by a symbolic link to outside is refused (2) and nothing is copied
PASS  T-42 a source with a symbolic link to outside among its ancestors is refused (2) and nothing is copied
PASS  T-43 keep_stream keeps exactly the stream of each mode and returns the command's own status
PASS  T-43 a raw output that cannot be written ends the suite with 2 (harness error), even when the command ends 125 as a case expects
PASS  T-43 the launches of T-02, T-07, T-16, T-17 and T-18 keep their streams through keep_stream; no other tee pipeline
PASS  T-38 P-01: 8 of 8 assertions pass
PASS  T-38 P-02: 7 of 7 assertions pass
PASS  T-38 P-03: 13 of 13 assertions pass
PASS  T-38 P-04: 7 of 7 assertions pass
PASS  T-38 P-05: 10 of 10 assertions pass
PASS  T-38 P-06: 15 of 15 assertions pass
PASS  T-38 P-07: 6 of 6 assertions pass
PASS  T-38 P-08: 4 of 4 assertions pass
PASS  T-38 P-09: 6 of 6 assertions pass
PASS  T-38 P-10: 4 of 4 assertions pass
PASS  T-38 P-11: 6 of 6 assertions pass
PASS  T-38 W: 9 of 9 assertions pass
PASS  T-38 M: 19 of 19 assertions pass
PASS  T-19 isolated steps are the last steps of their CI jobs; required jobs exist; no if: conditions
PASS  T-03 mutant as DEVENV: no request reached an engine
PASS  T-04 mutant edited into bin/devenv: no request reached an engine
PASS  T-03 mutant as DEVENV: the harness was started
PASS  T-04 mutant edited into bin/devenv: the harness was started
PASS  T-03 mutant as DEVENV: the harness refused before the mutant ran (an engine is reachable)
PASS  T-04 mutant edited into bin/devenv: the harness refused before the mutant ran (an engine is reachable)
PASS  T-03 mutant as DEVENV: the real Docker socket paths were not reached
PASS  T-04 mutant edited into bin/devenv: the real Docker socket paths were not reached
PASS  T-03 mutant as DEVENV: nothing written under $HOME
PASS  T-04 mutant edited into bin/devenv: nothing written under $HOME
PASS  T-05 control: without the containment the mutant's commands reach the canary engine
PASS  L-16 10 launches ran and timed themselves
PASS  L-16 the projected guard job is at most 540 s
PASS  L-16 no profile is left
```
<!-- pass end -->

## Full output of the checker of T-19 (55 lines; `work/T-19.out` must equal it)

<!-- T-19 begin -->
```text
ci-isolation-order: ok   required job 'Repository guard' exists
ci-isolation-order: ok   required job 'Dev environment' exists
ci-isolation-order: ok   no job or step has an if: condition
ci-isolation-order: ok   no job or step has continue-on-error
ci-isolation-order: ok   Repository guard / Check out repository: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Check out repository: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Reject tracked local-only files: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Reject tracked local-only files: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Require a digest-pinned Dockerfile frontend: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Require a digest-pinned Dockerfile frontend: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Check the container scan exceptions against their policy: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Check the container scan exceptions against their policy: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Keep the edge configuration free of ACME server, PKI, issuers and mutable admin: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Keep the edge configuration free of ACME server, PKI, issuers and mutable admin: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / ShellCheck: the scripts it runs exist
ci-isolation-order: ok   Repository guard / ShellCheck: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / actionlint: the scripts it runs exist
ci-isolation-order: ok   Repository guard / actionlint: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Run guard regression tests: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Run guard regression tests: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Run Dockerfile frontend guard regression tests: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Run Dockerfile frontend guard regression tests: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Run container scan exception guard regression tests: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Run container scan exception guard regression tests: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Run edge configuration guard regression tests: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Run edge configuration guard regression tests: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard / Run test isolation regression tests: the scripts it runs exist
ci-isolation-order: ok   Repository guard / Run test isolation regression tests: does not mix isolated and other commands
ci-isolation-order: ok   Repository guard: no step that is not isolated after the first isolated one
ci-isolation-order: ok   Repository guard: has isolated steps (first: Run guard regression tests)
ci-isolation-order: ok   Dev environment / Check out repository: the scripts it runs exist
ci-isolation-order: ok   Dev environment / Check out repository: does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / ShellCheck: the scripts it runs exist
ci-isolation-order: ok   Dev environment / ShellCheck: does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Validate Compose configuration: the scripts it runs exist
ci-isolation-order: ok   Dev environment / Validate Compose configuration: does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / make help and make doctor: the scripts it runs exist
ci-isolation-order: ok   Dev environment / make help and make doctor: does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Allocator integration tests (real Docker): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Allocator integration tests (real Docker): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Backend checks (Composer, PHP-CS-Fixer, PHPStan, migrations, PHPUnit): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Backend checks (Composer, PHP-CS-Fixer, PHPStan, migrations, PHPUnit): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Frontend checks (npm audit, type check, ESLint, Vitest, build): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Frontend checks (npm audit, type check, ESLint, Vitest, build): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Application stack (real Docker, bin/devenv, browser): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Application stack (real Docker, bin/devenv, browser): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Production-like stack (built SPA, browser): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Production-like stack (built SPA, browser): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Container vulnerability scan (Trivy): the scripts it runs exist
ci-isolation-order: ok   Dev environment / Container vulnerability scan (Trivy): does not mix isolated and other commands
ci-isolation-order: ok   Dev environment / Allocator unit tests: the scripts it runs exist
ci-isolation-order: ok   Dev environment / Allocator unit tests: does not mix isolated and other commands
ci-isolation-order: ok   Dev environment: no step that is not isolated after the first isolated one
ci-isolation-order: ok   Dev environment: has isolated steps (first: Allocator unit tests)
ci-isolation-order: ok   every other file that mentions no-docker.sh has the recognised re-exec stanza
```
<!-- T-19 end -->

## Full output of the checker of T-36 (136 lines; `work/T-36.out` must equal it)

<!-- T-36 begin -->
```text
ok   C01 a private /proc with NSpid of one entry, this pid, passes ([])
ok   C01 the whole mechanism check passes on a valid observation ([])
ok   C02 rejected: NSpid of two entries (a /proc of an ancestor namespace) (1 failing)
ok   C02 rejected: NSpid of one entry that is not this pid (1 failing)
ok   C02 rejected: NSpid missing (1 failing)
ok   C02 rejected: NSpid malformed (1 failing)
ok   C02 rejected: own pid namespace is the caller's (1 failing)
ok   C02 rejected: caller not in the initial pid namespace (1 failing)
ok   C02 rejected: own namespace is the initial one, the caller claimed another (2 failing)
ok   C02 rejected: caller given twice (1 failing)
ok   C02 rejected: caller a near miss (1 failing)
ok   C02 rejected: caller missing (1 failing)
ok   C02 rejected: own namespace malformed (1 failing)
ok   C02 rejected: /proc/self is another pid (1 failing)
ok   C02 rejected by the whole check: a pid namespace shared with the caller
ok   C03 our processes and the root shell as pid 1 pass
ok   C03 a process that ended is skipped
ok   C03 a process that ended (ESRCH) is skipped
ok   C03 rejected: a process of another user
ok   C03 rejected: a host daemon under our uid
ok   C03 rejected: Runner.Worker visible
ok   C03 rejected: pid 1 is systemd
ok   C03 rejected: pid 1 is not root
ok   C03 rejected: pid 1 missing
ok   C03 rejected: pid 1 unreadable (hidepid)
ok   C03 rejected: a status unreadable (EACCES)
ok   C03 rejected: a process without uids
ok   C04 no capability, no_new_privs, not root passes
ok   C04 rejected: CapInh not zero
ok   C04 rejected: CapInh missing
ok   C04 rejected: CapPrm not zero
ok   C04 rejected: CapPrm missing
ok   C04 rejected: CapEff not zero
ok   C04 rejected: CapEff missing
ok   C04 rejected: CapBnd not zero
ok   C04 rejected: CapBnd missing
ok   C04 rejected: CapAmb not zero
ok   C04 rejected: CapAmb missing
ok   C04 rejected: an unparsable capability set
ok   C04 rejected: no_new_privs unset
ok   C04 rejected: a uid 0
ok   C05 primary gid 1000 passes
ok   C05 primary gid 1001 passes
ok   C05 rejected: primary gid 999 (the last system gid)
ok   C05 rejected: primary gid 118 (the docker group)
ok   C05 rejected: primary gid 6 (disk)
ok   C05 rejected: primary gid 0 (root)
ok   C05 rejected: gids that differ
ok   C05 rejected: gids missing
ok   C05 rejected: a supplementary group
ok   C06 private mounts, one procfs, masked cgroups pass
ok   C06 hidepid=0 passes
ok   C06 rejected: a second procfs
ok   C06 rejected: an nsfs file
ok   C06 rejected: /proc with hidepid=2
ok   C06 rejected: /proc with hidepid=invisible
ok   C06 rejected: /proc with hidepid=noaccess
ok   C06 rejected: /proc with hidepid=ptraceable
ok   C06 rejected: /proc with subset=pid
ok   C06 rejected: /proc not a procfs
ok   C06 rejected: /proc missing
ok   C06 rejected: /tmp not private
ok   C06 rejected: /sys/fs/cgroup writable
ok   C06 rejected: /tmp is the caller's device
ok   C06 rejected: a writable mount left
ok   C07 rejected: a standard descriptor is a Unix socket
ok   C07 rejected: a standard descriptor is a TCP socket
ok   C07 /dev/null and pipes pass
ok   C07 rejected: a terminal
ok   C07 rejected: a regular file
ok   C07 rejected: a descriptor that cannot be examined (EACCES)
ok   C07 rejected: fd 0 closed
ok   C10 with every finding passed the write and connect phase runs once
ok   C10 not entered when a finding failed
ok   C10 not entered when no findings
ok   C10 not entered when the evaluation raised ValueError
ok   C10 not entered when the evaluation raised KeyError
ok   C10 not entered when the observation raised OSError
ok   C10 not entered when the whole check on an observation with a writable mount
ok   C10 not entered when the whole check on a terminal
ok   C11 this process confined by exactly NAME in enforce mode passes
ok   C11 every other process confined by exactly NAME, pid 1 the root shell, passes
ok   C11 rejected: a stacked label
ok   C11 rejected: complain mode
ok   C11 rejected: another process unconfined
ok   C11 rejected: pid 1 unconfined but not the root shell
ok   C11 rejected: the label missing
ok   C12 fd 0 /dev/null, fds 1 and 2 pipes, nothing else passes
ok   C12 rejected: an extra fd 3 (a Unix socket)
ok   C12 rejected: an extra fd 7 (a file)
ok   C12 the listing's own descriptor (closed by now) is ignored
ok   C12 rejected: fd 1 a socket
ok   C12 rejected: fd 2 a regular file
ok   C12 rejected: an fd that cannot be examined
ok   C12 rejected: fd 0 not /dev/null (1:3)
ok   C12 rejected: the listing of another process
ok   C13 both fence sockets refused with EACCES, the twin connects: passes
ok   C13 rejected: both fence sockets reached
ok   C13 rejected: the stream connect refused (ECONNREFUSED)
ok   C13 rejected: the stream fence missing (ENOENT)
ok   C13 rejected: the stream connect denied with EPERM
ok   C13 rejected: the datagram timing out
ok   C13 rejected: file permissions not shown to allow the fence
ok   C13 rejected: the datagram refused but the stream reached
ok   C13 rejected: the twin not connecting
ok   C14 descriptors above 2 closed and none left: proceeds (closed [5, 6])
ok   C14 rejected: a descriptor above 2 survives the close
ok   C14 the listing's own descriptor (closed by now) is ignored
ok   C14 rejected: stdin not /dev/null
ok   W the gate evaluates the label (G3) and the descriptor table (G8): gate_exec uses eval_fds, evaluate_gate, observe_fds
ok   W the gate's evaluation goes through gated: gate_exec uses gated
ok   W the gate checks the fence (G4, G6): gate_exec uses eval_fence, fence_check
ok   W the gate checks the twin (G5): gate_exec uses twin_check
ok   W --root-exec closes and verifies the descriptors: root_exec uses closerange, dup2, eval_root_fds, execv, list_fds
ok   W the gate runs the kept after-gate checks and the engine check (endpoints): gate_exec uses after_gate_linux, engine_check
ok   W main runs gate_exec for --gate-exec
ok   W main runs root_exec for --root-exec
ok   W main runs seal for --seal
ok   W main runs check_mechanism_linux and then engine_check without arguments (--check)
ok   W a nested run gates on G1 (evaluate_linux), G3 (eval_label) and G7 (after_gate_linux, then engine_check with endpoints)
ok   W the gate checks the descriptors, then resets every signal and clears the mask, then execs ({'eval_fds': 1405, 'pthread_sigmask': 1414, 'execvp': 1425, 'signal': 1413})
ok   M1 the old NSpid rule (two entries or more): rejected by C01
ok   M4 the primary group rule removed: rejected by C05
ok   M6 the gate removed: rejected by C10
ok   M11 any unreadable process skipped: rejected by C03
ok   M12 the caller's pid namespace not checked: rejected by C02
ok   M13 NSpid containing the pid accepted: rejected by C02
ok   M14 any fence error accepted: rejected by C13
ok   M15 a stacked label accepted: rejected by C11
ok   M16 descriptors above 2 ignored: rejected by C12
ok   M17 the file permission proof skipped: rejected by C13
ok   M18 a socket on fd 1 accepted: rejected by C12
ok   M19 the twin ignored: rejected by C13
ok   M20 a descriptor that cannot be examined taken as closed: rejected by C12
ok   M21 the listing of another process accepted: rejected by C12
SUMMARY 135 ok, 0 failed
```
<!-- T-36 end -->

## Full output of the checker of T-38 (115 lines; `work/T-38.out` must equal it)

<!-- T-38 begin -->
```text
ok   P-01 a valid NAME is accepted by load and release
ok   P-01 a valid NEGNAME is accepted by load-negative-control, release and diag
ok   P-01 rejected: NEGNAME by load
ok   P-01 rejected: NAME by load-negative-control
ok   P-01 rejected: 31 hex digits
ok   P-01 rejected: 33 hex digits
ok   P-01 rejected: upper case
ok   P-01 rejected: path characters, a newline, a space, empty
ok   P-02 enforce: the name and its mode
ok   P-02 complain: the mode is complain
ok   P-02 a stacked label is not the profile itself
ok   P-02 unconfined has no mode
ok   P-02 an empty label is nothing
ok   P-02 a trailing newline is ignored
ok   P-02 a namespace-prefixed label is not the profile itself
ok   P-03 enabled, enforce, af_unix and both tools pass
ok   P-03 rejected: AppArmor disabled
ok   P-03 rejected: enabled unreadable
ok   P-03 rejected: global mode complain
ok   P-03 rejected: global mode unreadable
ok   P-03 rejected: no af_unix class
ok   P-03 rejected: af_unix unreadable
ok   P-03 rejected: apparmor_parser missing
ok   P-03 rejected: aa-exec missing
ok   P-03 rejected: a tool unreadable
ok   P-03 the sysctl values are recorded, not gating
ok   P-03 rejected: an empty observation
ok   P-03 af_unix: a file reading yes or a directory counts; anything else does not
ok   P-04 listed once in enforce mode
ok   P-04 listed twice: both seen
ok   P-04 listed in complain mode
ok   P-04 absent: loaded only then; a NAME listed already is never loaded again
ok   P-04 an unreadable list is an error, nothing is removed
ok   P-04 similar foreign names are not the profile
ok   P-04 the list is read to its end: NAME after its first 4096 bytes is found; a list over the limit is an error
ok   P-05 a task carrying the profile is counted
ok   P-05 a stacked label is counted
ok   P-05 a prefixed label is counted
ok   P-05 a longer name containing it is counted
ok   P-05 a task that ended (ENOENT, ESRCH) is skipped
ok   P-05 an unreadable label (EACCES) is unknown
ok   P-05 an unreadable label (EINVAL) is unknown
ok   P-05 two sweeps are required: a carrier in the second keeps it
ok   P-05 two clear sweeps pass
ok   P-05 a long stacked label read whole is counted; a read that fills its buffer (maybe cut) is unknown
ok   P-06 init alive: kept
ok   P-06 init a single-threaded zombie: released
ok   P-06 no task in the namespace: released
ok   P-06 state loading, no namespace recorded: no P1: released
ok   P-06 state entering, namespace record missing: kept
ok   P-06 namespace record not root-owned: kept
ok   P-06 namespace record unparsable: kept
ok   P-06 another task in the namespace: kept
ok   P-06 the task scan unreadable (EACCES): kept
ok   P-06 state missing or unknown: treated as entered: kept
ok   P-06 namespace record naming the host's namespace: kept
ok   P-06 state loading with a namespace recorded: treated as entered: kept
ok   P-06 state not-forked: released without P1 only when no namespace is recorded (released, kept)
ok   P-06 a record whose mount namespace is unknown (mnt:-): released
ok   P-06 malformed namespace records are refused (16 of 16 variants)
ok   P-07 rejected: template bytes that differ from the pinned sha256
ok   P-07 every @NAME@ is replaced (profile name and ptrace peer)
ok   P-07 the unix rule is accepted (not an exec mode)
ok   P-07 rejected: an exec transition
ok   P-07 rejected: attach_disconnected in the production template
ok   P-07 rejected: change_profile
ok   P-08 load-negative-control loads the negative template
ok   P-08 load never loads the negative template
ok   P-08 the negative template needs NEGNAME
ok   P-08 load adds the production profile under NAME
ok   P-09 the profile vanished: kept
ok   P-09 its mode changed (complain): kept
ok   P-09 its kernel hash changed: kept
ok   P-09 unchanged: released
ok   P-09 no hash exported, at load or now: released
ok   P-09 state loading and the name never loaded: success with nothing to remove (not removed)
ok   P-10 namespace record missing: held by a pidfd, start time checked around the namespace read, recorded, then killed (['pidfd_open 1003', 'start_time', 'ns_inodes', 'start_time', 'signal 0', 'signal 9'])
ok   P-10 namespace recorded: nothing written; killed only in the recorded namespace (killed, refused)
ok   P-10 pid 1 recorded its namespace first: the same one is accepted, another one stops the kill (killed, refused)
ok   P-10 an ambiguous lookup is retried until the deadline, then refused without a signal (refused, 8s)
ok   P-11 a valid CTLDIR is accepted
ok   P-11 CTLDIR refused: relative, not canonical, a link, missing, not a directory, mode, owner, place, name; SUDO_USER mismatch (15 of 15)
ok   P-11 LAUNCHERPID accepted: the parent of the sudo that started this helper (with and without sudo's monitor)
ok   P-11 LAUNCHERPID refused: another uid, not the sudo's parent, absent, too far up, a grandparent
ok   P-11 pid 1 is found below the launcher's sudo and unshare (with and without sudo's monitor; a process inside disguised as unshare is not taken)
ok   P-11 pid 1 is not taken: no child yet, another sudo argv, two sudos, two children, the host namespace, not pid 1, another recorded namespace, another launcher (['none', 'none', 'ambiguous', 'ambiguous', 'none', 'none', 'ambiguous', 'none'])
ok   W main uses diag, kill_init, launcher_findings, load, name_ok, preflight, release, validated_ctldir
ok   W release uses listed_modes, p0, p1, p2, parse_ns, parse_state, release_plan, sweeps_clear
ok   W load uses listed_modes, render, template_for
ok   W kill_init_once uses find_init, ns_record, p0, parse_ns
ok   W preflight uses preflight_findings
ok   W sweeps_clear uses sweep_result
ok   W profile_list uses read_all
ok   W label_sweep uses read_label
ok   W read_label uses label_from
ok   M1 a sweep counting exact labels only: rejected by P-05
ok   M2 an unreadable label counted as no carrier: rejected by P-05
ok   M3 a single sweep: rejected by P-05
ok   M4 P1 skipped: rejected by P-06
ok   M5 P2 skipped: rejected by P-09
ok   M6 the kernel hash not compared: rejected by P-09
ok   M7 a load that replaces a loaded profile: rejected by P-04
ok   M8 the negative template reachable through load: rejected by P-08
ok   M9 the name prefix not checked: rejected by P-01
ok   M10 an init that still runs accepted: rejected by P-06
ok   M11 a task that ended counted as unknown: rejected by P-05
ok   M12 a stacked label not counted: rejected by P-05
ok   M13 a missing state treated as loading: rejected by P-06
ok   M14 a namespace record naming the host accepted: rejected by P-06
ok   M15 state loading with a namespace recorded not escalated: rejected by P-06
ok   M16 state not-forked accepted with a namespace recorded: rejected by P-06
ok   M17 pid 1 signalled before its namespace is recorded: rejected by P-10
ok   M18 the profile list read once: rejected by P-04
ok   M19 a label read that filled its buffer accepted: rejected by P-05
SUMMARY 114 ok, 0 failed
```
<!-- T-38 end -->

## Full output of the checker of T-39 (23 lines; `work/T-39.out` must equal it)

<!-- T-39 begin -->
```text
ok   S-02 repository: no AppArmor reload, replace, remove, mode change or configuration write
ok   S-02 mutant fixture is rejected (scripts/ci/no-docker.sh:905)
ok   S-02b repository: attach_disconnected only in the negative-control template
ok   S-02b mutant fixture is rejected (scripts/ci/no-docker/apparmor.profile:15)
ok   S-03b repository: no sudo -E or --preserve-env; sudo in no-docker.test.sh only as reviewed
ok   S-03b mutant fixture is rejected (scripts/ci/tests/no-docker.test.sh:3044, scripts/ci/tests/no-docker.test.sh:3044)
ok   S-03 repository: sudo in no-docker.sh runs only the seven reviewed commands
ok   S-03 mutant fixture is rejected (scripts/ci/no-docker.sh:905)
ok   S-04 repository: the AppArmor helper only in the Linux arms of no-docker.sh; the helper refuses other platforms
ok   S-04 mutant fixture is rejected (scripts/ci/no-docker.sh:181)
ok   S-05 repository: the templates are exactly the reviewed rule set
ok   S-05 mutant fixture is rejected (scripts/ci/no-docker/apparmor.profile: not the reviewed rule set (extra [], missing ['deny network vsock,']))
ok   S-06 repository: no host socket listing is left
ok   S-06 mutant fixture is rejected (scripts/ci/no-docker-probe.py:1693)
ok   S-07 repository: the negative control only in the files that implement and test it
ok   S-07 mutant fixture is rejected (.github/workflows/ci.yml:140)
ok   S-08 repository: the template hashes pinned in no-docker-aa.py are those of the files
ok   S-08 mutant fixture is rejected (scripts/ci/no-docker-aa.py pins 2375d20c5202891297e686ced0976899e36601d9824d475f6f34c204b28ea46e for scripts/ci/tests/no-docker/apparmor-negative.profile, which is 123b3e8ce3fcca1e6dbc094415dded280f675b6d08ef2c1e656db5052cfb0092)
ok   S-09 repository: a failed removal of the fence, control or run directory is a cleanup failure (125)
ok   S-09 mutant fixture is rejected (scripts/ci/no-docker.sh:448)
ok   S-05 template: scripts/ci/no-docker/apparmor.profile is the production rule set with flags=(enforce) (exact)
ok   S-05 template: scripts/ci/tests/no-docker/apparmor-negative.profile differs from the production template only by attach_disconnected (["not the reviewed rule set (extra ['profile @NAME@ flags=(enforce,attach_disconnected) {'], missing ['profile @NAME@ flags=(enforce) {'])", 'attach_disconnected'])
SUMMARY 22 ok, 0 failed
```
<!-- T-39 end -->

## Raw case outputs that must be kept (count, path pattern)

Paths in `no-docker-cases/MANIFEST.sha256` (POSIX extended regular expressions, whole path). `w.XXXXXX` and
`t40.XXXXXX` are `mktemp` names. Each row's file must be listed (and, by `sha256sum -c`, present and unchanged).

<!-- paths begin -->
```text
1 work/launch-count
1 work/l-listeners
1 work/l-release
1 work/l-carriers
1 work/payload-t00
1 work/t01\.out
1 work/t02\.out
1 work/t03\.out
1 work/t04\.out
1 work/t05\.out
1 work/t07\.py
1 work/t07\.port
1 work/t07\.out
1 work/t07\.err
1 work/t16\.out
1 work/t16-sockets
1 work/t16-classes
1 work/t16own\.ready\.count
1 work/t17\.out
1 work/t17\.err
1 work/t17c\.out
1 work/t18-1\.out
1 work/t18-1\.err
1 work/t18-2\.out
1 work/t18-2\.err
1 work/t18-3\.out
1 work/t18-3\.err
1 work/t18-4\.out
1 work/t18-4\.err
1 work/t18-5\.out
1 work/t18-5\.err
1 work/t18-6\.out
1 work/t18-6\.err
1 work/t18-7\.out
1 work/t18-7\.err
1 work/t18\.rc
1 work/t18\.rc\.err
1 work/t18\.rc\.out
1 work/l01\.before
1 work/l01\.in
1 work/l01\.err
1 work/l01\.after
1 work/l01s\.ready\.count
1 work/l01d\.ready\.count
1 work/l01a\.ready\.count
1 work/l02\.out
1 work/l02\.in
1 work/l02\.err
1 work/l02\.ready\.count
1 work/l03n1\.out
1 work/l03n1\.in
1 work/l03n1\.err
1 work/l03n2\.out
1 work/l03n2\.in
1 work/l03n2\.err
1 work/l03n0\.out
1 work/l03n0\.in
1 work/l03n0\.err
1 work/l03n1\.ready\.count
1 work/l03n2\.ready\.count
1 work/l04\.in
1 work/l04\.err
1 work/l04\.out
1 work/l05\.in
1 work/l05\.err
1 work/l06\.in
1 work/l06\.err
1 work/l06\.out
1 work/l07-socketpair\.err
1 work/l07-pty\.err
1 work/l08\.err
1 work/l08c\.err
1 work/l09\.err
1 work/l09b\.err
1 work/l10\.out
1 work/l10\.in
1 work/l10\.err
1 work/l12\.out
1 work/l12\.err
1 work/l13\.err
1 work/l13b\.out
1 work/l13b\.err
1 work/l13c-a\.out
1 work/l13c-a\.err
1 work/l13c-b\.out
1 work/l13c-b\.err
1 work/l14\.out
1 work/l14\.err
1 work/l15\.out
1 work/l15\.err
1 work/l15b\.out
1 work/l15b\.err
1 work/l16\.out
1 work/l16\.err
1 work/l18\.out
1 work/l18\.err
1 work/l10\.ready\.count
1 work/l15c-0\.out
1 work/l15c-0\.err
1 work/l15c-20\.out
1 work/l15c-20\.err
1 work/l15c-50\.out
1 work/l15c-50\.err
1 work/l15c-100\.out
1 work/l15c-100\.err
1 work/l15c-200\.out
1 work/l15c-200\.err
1 work/l15c-300\.out
1 work/l15c-300\.err
1 work/T-19\.out
1 work/T-36\.out
1 work/T-38\.out
1 work/T-39\.out
1 work/t40-cleanup\.sh
1 work/t40-m1\.sh
1 work/t40-m2\.sh
1 work/t40-m3\.sh
1 work/t40-m4\.sh
20 work/t40\.[A-Za-z0-9]{6}/out
20 work/t40\.[A-Za-z0-9]{6}/err
5 work/t40\.[A-Za-z0-9]{6}/run/started
1 work/t42/dest/MANIFEST\.sha256
1 work/t42/dest/SKIPPED\.txt
1 work/t42/dest/work/a\.log
1 work/t42/dest/work/sub/b\.log
1 work/t42/full/x
1 work/t42/out/extra\.log
1 work/t42/r1/dest/MANIFEST\.sha256
1 work/t42/r1/dest/SKIPPED\.txt
1 work/t42/r1/dest/work/a\.log
1 work/t42/r1/src/a\.log
1 work/t42/r1/src/d42\.moved/f42\.log
1 work/t42/r2/dest/MANIFEST\.sha256
1 work/t42/r2/dest/SKIPPED\.txt
1 work/t42/r2/dest/work/d42/f42\.log
1 work/t42/r2/src/d42\.moved/f42\.log
1 work/t42/r4/dest/MANIFEST\.sha256
1 work/t42/r4/dest/SKIPPED\.txt
1 work/t42/r4/dest/work/a\.log
1 work/t42/r4/src/a\.log
1 work/t42/r5/out/src/f42\.log
1 work/t42/src/a\.log
1 work/t42/src/sub/b\.log
1 work/t43/both\.out
1 work/t43/out\.out
1 work/t43/out\.err
1 work/t43/err\.err
1 work/t43/err\.out
1 work/t43/fail\.out
1 work/t43/fail\.err
8 vt/w\.[A-Za-z0-9]{6}/started
3 vt/w\.[A-Za-z0-9]{6}/d/canary\.log
3 vt/w\.[A-Za-z0-9]{6}/d/drive-started
1 vt/w\.[A-Za-z0-9]{6}/d/mutant\.log
2 vt/w\.[A-Za-z0-9]{6}/name
2 vt/w\.[A-Za-z0-9]{6}/go
```
<!-- paths end -->

| Count | Path | From | Why |
|---|---|---|---|
| 1 | `work/launch-count` | `"$work/launch-count"` | bookkeeping of launches, listeners, loaded profiles and carriers |
| 1 | `work/l-listeners` | `"$work/l-listeners"` | bookkeeping of launches, listeners, loaded profiles and carriers |
| 1 | `work/l-release` | `"$work/l-release"` | bookkeeping of launches, listeners, loaded profiles and carriers |
| 1 | `work/l-carriers` | `"$work/l-carriers"` | bookkeeping of launches, listeners, loaded profiles and carriers |
| 1 | `work/payload-t00` | `>"$work/payload-t00"` | T-00 |
| 1 | `work/t01.out` | `"$nd" --check >"$work/t01.out" 2>&1` | T-01 |
| 1 | `work/t02.out` | `keep_stream both "$work/t02.out"` | T-02 |
| 1 | `work/t03.out` | `OUT=$work/$name.out` | T03 harness output |
| 1 | `work/t04.out` | `OUT=$work/$name.out` | T04 harness output |
| 1 | `work/t05.out` | `OUT=$work/$name.out` | T05 harness output |
| 1 | `work/t07.py` | `cat >"$work/t07.py"` | T-07 |
| 1 | `work/t07.port` | `"$work/t07.port" &` | T-07 |
| 1 | `work/t07.out` | `keep_stream out "$work/t07.out" "$work/t07.err"` | T-07 |
| 1 | `work/t07.err` | `keep_stream out "$work/t07.out" "$work/t07.err"` | T-07 |
| 1 | `work/t16.out` | `keep_stream both "$work/t16.out"` | T-16 launch stream |
| 1 | `work/t16-sockets` | `cp "$ro/t16-sockets" "$ro/t16-classes" "$work/"` | T-16 host sockets found outside |
| 1 | `work/t16-classes` | `cp "$ro/t16-sockets" "$ro/t16-classes" "$work/"` | T-16 their classes |
| 1 | `work/t16own.ready.count` | `lsock stream "$ro/t16own/s" "$work/t16own.ready"` | T-16's own socket, reached from outside |
| 1 | `work/t17.out` | `keep_stream out "$work/t17.out" "$work/t17.err"` | T-17 |
| 1 | `work/t17.err` | `keep_stream out "$work/t17.out" "$work/t17.err"` | T-17 |
| 1 | `work/t17c.out` | `>"$work/t17c.out" 2>&1 &` | T-17 |
| 1 | `work/t18-1.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-1.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-2.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-2.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-3.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-3.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-4.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-4.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-5.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-5.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-6.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-6.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18-7.out` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stdout |
| 1 | `work/t18-7.err` | `keep_stream err "$work/t18-$t18n.err" "$work/t18-$t18n.out"` | T-18 refusal stderr |
| 1 | `work/t18.rc` | `"$work/t18.rc"` | T-18 without a Runner.Worker ancestor |
| 1 | `work/t18.rc.err` | `"$work/t18.rc"` | T-18 without a Runner.Worker ancestor |
| 1 | `work/t18.rc.out` | `"$work/t18.rc"` | T-18 without a Runner.Worker ancestor |
| 1 | `work/l01.before` | `"$work/l01.before"` | L-01 |
| 1 | `work/l01.in` | `"$work/l01.in"` | L-01 |
| 1 | `work/l01.err` | `"$work/l01.err"` | L-01 |
| 1 | `work/l01.after` | `"$work/l01.after"` | L-01 |
| 1 | `work/l01s.ready.count` | `"$work/l01s.ready"` | L-01 listener reached from outside (before/after controls) |
| 1 | `work/l01d.ready.count` | `"$work/l01d.ready"` | L-01 listener reached from outside (before/after controls) |
| 1 | `work/l01a.ready.count` | `"$work/l01a.ready"` | L-01 listener reached from outside (before/after controls) |
| 1 | `work/l02.out` | `"$work/l02.out"` | L-02 |
| 1 | `work/l02.in` | `"$work/l02.in"` | L-02 |
| 1 | `work/l02.err` | `"$work/l02.err"` | L-02 |
| 1 | `work/l02.ready.count` | `"$work/l02.ready"` | L-02 listener reached through the alias outside |
| 1 | `work/l03n1.out` | `"$work/l03$n.out"` | L-03 |
| 1 | `work/l03n1.in` | `"$work/l03$n.in"` | L-03 |
| 1 | `work/l03n1.err` | `"$work/l03$n.err"` | L-03 |
| 1 | `work/l03n2.out` | `"$work/l03$n.out"` | L-03 |
| 1 | `work/l03n2.in` | `"$work/l03$n.in"` | L-03 |
| 1 | `work/l03n2.err` | `"$work/l03$n.err"` | L-03 |
| 1 | `work/l03n0.out` | `"$work/l03n0.out"` | L-03 |
| 1 | `work/l03n0.in` | `"$work/l03n0.in"` | L-03 |
| 1 | `work/l03n0.err` | `"$work/l03n0.err"` | L-03 |
| 1 | `work/l03n1.ready.count` | `"$work/l03$n.ready"` | L-03 listener reached by the outside control |
| 1 | `work/l03n2.ready.count` | `"$work/l03$n.ready"` | L-03 listener reached by the outside control |
| 1 | `work/l04.in` | `"$work/l04.in"` | L-04 |
| 1 | `work/l04.err` | `"$work/l04.err"` | L-04 |
| 1 | `work/l04.out` | `"$work/l04.out"` | L-04 |
| 1 | `work/l05.in` | `"$work/l05.in"` | L-05 |
| 1 | `work/l05.err` | `"$work/l05.err"` | L-05 |
| 1 | `work/l06.in` | `"$work/l06.in"` | L-06 |
| 1 | `work/l06.err` | `"$work/l06.err"` | L-06 |
| 1 | `work/l06.out` | `"$work/l06.out"` | L-06 |
| 1 | `work/l07-socketpair.err` | `2>"$work/l07-$kind.err"` | L-07 |
| 1 | `work/l07-pty.err` | `2>"$work/l07-$kind.err"` | L-07 |
| 1 | `work/l08.err` | `"$work/l08.err"` | L-case stream |
| 1 | `work/l08c.err` | `"$work/l08c.err"` | L-case stream |
| 1 | `work/l09.err` | `"$work/l09.err"` | L-case stream |
| 1 | `work/l09b.err` | `"$work/l09b.err"` | L-case stream |
| 1 | `work/l10.out` | `"$work/l10.out"` | L-case stream |
| 1 | `work/l10.in` | `"$work/l10.in"` | L-case stream |
| 1 | `work/l10.err` | `"$work/l10.err"` | L-case stream |
| 1 | `work/l12.out` | `"$work/l12.out"` | L-case stream |
| 1 | `work/l12.err` | `"$work/l12.err"` | L-case stream |
| 1 | `work/l13.err` | `"$work/l13.err"` | L-case stream |
| 1 | `work/l13b.out` | `"$work/l13b.out"` | L-case stream |
| 1 | `work/l13b.err` | `"$work/l13b.err"` | L-case stream |
| 1 | `work/l13c-a.out` | `"$work/l13c-a.out"` | L-case stream |
| 1 | `work/l13c-a.err` | `"$work/l13c-a.err"` | L-case stream |
| 1 | `work/l13c-b.out` | `"$work/l13c-b.out"` | L-case stream |
| 1 | `work/l13c-b.err` | `"$work/l13c-b.err"` | L-case stream |
| 1 | `work/l14.out` | `"$work/l14.out"` | L-case stream |
| 1 | `work/l14.err` | `"$work/l14.err"` | L-case stream |
| 1 | `work/l15.out` | `"$work/l15.out"` | L-case stream |
| 1 | `work/l15.err` | `"$work/l15.err"` | L-case stream |
| 1 | `work/l15b.out` | `"$work/l15b.out"` | L-case stream |
| 1 | `work/l15b.err` | `"$work/l15b.err"` | L-case stream |
| 1 | `work/l16.out` | `"$work/l16.out"` | L-case stream |
| 1 | `work/l16.err` | `"$work/l16.err"` | L-case stream |
| 1 | `work/l18.out` | `"$work/l18.out"` | L-case stream |
| 1 | `work/l18.err` | `"$work/l18.err"` | L-case stream |
| 1 | `work/l10.ready.count` | `"$work/l10.ready"` | L-10 listener reached by the outside client |
| 1 | `work/l15c-0.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-0.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/l15c-20.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-20.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/l15c-50.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-50.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/l15c-100.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-100.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/l15c-200.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-200.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/l15c-300.out` | `"$work/l15c-$ms.out"` | L-15c |
| 1 | `work/l15c-300.err` | `"$work/l15c-$ms.err"` | L-15c |
| 1 | `work/T-19.out` | `"$work/T-19.out"` | T-19 full checker output (content checked against the block below) |
| 1 | `work/T-36.out` | `"$work/T-36.out"` | T-36 full checker output (content checked against the block below) |
| 1 | `work/T-38.out` | `"$work/T-38.out"` | T-38 full checker output (content checked against the block below) |
| 1 | `work/T-39.out` | `"$work/T-39.out"` | T-39 full checker output (content checked against the block below) |
| 1 | `work/t40-cleanup.sh` | `t40_src=$work/t40-cleanup.sh` | T-40 |
| 1 | `work/t40-m1.sh` | `"$work/t40-m1.sh"` | T-40 mutant |
| 1 | `work/t40-m2.sh` | `"$work/t40-m2.sh"` | T-40 mutant |
| 1 | `work/t40-m3.sh` | `"$work/t40-m3.sh"` | T-40 mutant |
| 1 | `work/t40-m4.sh` | `"$work/t40-m4.sh"` | T-40 mutant |
| 20 | `work/t40.[A-Za-z0-9]{6}/out` | `d=$(mktemp -d "$work/t40.XXXXXX")` | T-40: 4 cases x (the cleanup and 4 mutants) |
| 20 | `work/t40.[A-Za-z0-9]{6}/err` | `d=$(mktemp -d "$work/t40.XXXXXX")` | T-40 |
| 5 | `work/t40.[A-Za-z0-9]{6}/run/started` | `: >"$d/run/started"` | T-40: the run directory kept in the run-failure case |
| 1 | `work/t42/dest/MANIFEST.sha256` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/dest/SKIPPED.txt` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/dest/work/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/dest/work/sub/b.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/full/x` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/out/extra.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r1/dest/MANIFEST.sha256` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r1/dest/SKIPPED.txt` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r1/dest/work/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r1/src/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r1/src/d42.moved/f42.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r2/dest/MANIFEST.sha256` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r2/dest/SKIPPED.txt` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r2/dest/work/d42/f42.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r2/src/d42.moved/f42.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r4/dest/MANIFEST.sha256` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r4/dest/SKIPPED.txt` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r4/dest/work/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r4/src/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/r5/out/src/f42.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/src/a.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t42/src/sub/b.log` | `t42=$work/t42` | T-42 fixture tree (pure; the same on both platforms) |
| 1 | `work/t43/both.out` | `keep_stream both "$t43/both.out"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/out.out` | `keep_stream out "$t43/out.out" "$t43/out.err"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/out.err` | `keep_stream out "$t43/out.out" "$t43/out.err"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/err.err` | `keep_stream err "$t43/err.err" "$t43/err.out"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/err.out` | `keep_stream err "$t43/err.err" "$t43/err.out"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/fail.out` | `>"$t43/fail.out" 2>"$t43/fail.err"` | T-43 (pure; the same on both platforms) |
| 1 | `work/t43/fail.err` | `>"$t43/fail.out" 2>"$t43/fail.err"` | T-43 (pure; the same on both platforms) |
| 8 | `vt/w.[A-Za-z0-9]{6}/started` | `new_work` | --work runs whose command started: L-04, L-14, L-13b, L-15, L-15b and the guard of T-03, T-04, T-05 (written by the gate) |
| 3 | `vt/w.[A-Za-z0-9]{6}/d/canary.log` | `data=$g/d` | T-03, T-04, T-05: the canary's record (drive.sh) |
| 3 | `vt/w.[A-Za-z0-9]{6}/d/drive-started` | `data=$g/d` | T-03, T-04, T-05: drive.sh started the harness |
| 1 | `vt/w.[A-Za-z0-9]{6}/d/mutant.log` | `LOG=$data/mutant.log` | T-05: the mutant ran (T-03 and T-04 refuse before it) |
| 2 | `vt/w.[A-Za-z0-9]{6}/name` | `echo "$NO_DOCKER_PROFILE" >"$1/name"` | L-14, L-13b: the profile name the command saw |
| 2 | `vt/w.[A-Za-z0-9]{6}/go` | `: >"$g/go"` | L-14, L-13b: written by the suite to end the command |

## Raw case outputs that must not be there after a successful run

<!-- absent begin -->
```text
work/t02
work/l08\.marker
work/l09\.marker
work/l12\.marker
work/l15b\.ready\.count
work/t16own\.ready
work/l01s\.ready
work/l01d\.ready
work/l01a\.ready
work/l02\.ready
work/l03n0\.ready
work/l03n1\.ready
work/l03n2\.ready
work/l10\.ready
work/l15b\.ready
work/l03n0\.ready\.count
```
<!-- absent end -->

| Path | From | Why |
|---|---|---|
| `work/t02` | `touch "$work/t02"` | T-02: the command must not run |
| `work/l08.marker` | `"$work/l08.marker"` | L-08: the command must not run |
| `work/l09.marker` | `"$work/l09.marker"` | L-09: the command must not run |
| `work/l12.marker` | `"$work/l12.marker"` | L-12: the given command must not run |
| `work/l15b.ready.count` | `"$work/l15b.ready.count"` | L-15b: the host socket never accepted a connection |
| `work/t16own.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l01s.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l01d.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l01a.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l02.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l03n0.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l03n1.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l03n2.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l10.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l15b.ready` | `lstop() {` | a listener's ready file, removed by lstop |
| `work/l03n0.ready.count` | `"$work/l03n0.ready"` | L-03 N0: the listener ended before any connect |

## Variable part (allowed, not required)

- Further files under `vt/` written by the commands under test (the T-05 mutant run, the L-cases' commands).
- Files of failure paths (a profile left loaded, refusals); a run with them fails on its result lines anyway.
- `SKIPPED.txt` entries: sockets (the canary `vt/w.XXXXXX/d/c`), links and FIFOs of the fixtures, the
  hard-linked T-42 files; never `FAILED`.
- Not kept by design: the suite's read-only material under `$RUNNER_TEMP` (helpers, payload, harness trees,
  listener sockets and L-04's ready file), and `/dev/null` streams that are part of a case's descriptor
  set-up (L-07's socket or pty, L-09's stdout).
