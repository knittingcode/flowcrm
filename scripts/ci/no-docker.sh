#!/usr/bin/env bash
#
# Run a command where no container engine can be reached and where it cannot
# change what runs or is read outside it later, so a test suite, and any
# modified or mutated copy of the code it runs, cannot touch the Docker
# daemon of the machine (its images, containers, volumes, networks or build
# cache) or the user's environment. docs/dev-environment.md, "Isolation from
# Docker", lists every property, how it is verified and what is left.
#
# Usage: no-docker.sh [--work DIR] COMMAND [ARG...]
#                                  run COMMAND isolated; its status
#        no-docker.sh --check      exit 0 only if this process is already
#                                  isolated
#
# --work DIR: use DIR, a fresh, empty directory of the caller (mode 0700, not
# a symbolic link and without one in its path), as the only writable
# directory of the command instead of a temporary one, and keep it
# afterwards. On macOS DIR must be under $TMPDIR or /private/var/tmp, on
# Linux under /var/tmp. Whatever the command leaves there is untrusted data:
# a later reader must not follow symbolic links, must accept regular files
# only, must limit their size and must not run them.
#
# Supported: macOS developer machines (sandbox-exec) and Linux on
# GitHub-hosted Actions runners (sudo unshare). Everything else, including
# Linux elsewhere and uid 0, is refused.
#   macOS  sandbox-exec: no connect to a Unix socket, no TCP beyond
#          loopback, to loopback ports 22, 2375 and 2376 or to a loopback
#          port that was listening before the command started; file writes
#          only in the run's own directory (the command's $TMPDIR is in it)
#          and the /dev nodes a shell needs, nothing in /tmp (so no bash 3.2
#          here-document inside); no signal to and no debugging of a
#          process outside the sandbox; no preference write, TIOCSTI, open,
#          osascript, launchctl, ssh, launchd job, Launch Services, Apple
#          Events, login item or background task registration and no lookup
#          of Docker's own services. When the command ends, or no-docker.sh
#          gets SIGINT, SIGTERM, SIGHUP or SIGQUIT, the processes left in
#          the sandbox (found by a marker of the run) are killed; the run
#          is reported done only when it is shown that none of them runs
#          any more, otherwise it fails (125). A run that ended so, or
#          without its supervisor (SIGKILL), keeps new runs from starting
#          until that is shown. $TMPDIR must be the per-user directory
#          under /private/var/folders.
#   Linux  sudo unshare and AppArmor: new network (loopback only), mount, pid
#          and IPC namespaces; empty tmpfs over /run, /var/run, /tmp,
#          /var/tmp, /dev/shm and /sys/fs/cgroup, a fresh /dev/mqueue, every
#          other mount read-only; the command runs as the calling user without
#          supplementary groups, capabilities or the means to regain them
#          (no_new_privs), in a session of its own, with an allowlisted
#          environment, under a root pid 1 that waits for it, confined by an
#          AppArmor profile loaded for this launch alone
#          (scripts/ci/no-docker/apparmor.profile, no attach_disconnected):
#          the kernel refuses every Unix socket bound outside the namespace
#          (EACCES), whatever its path. Before the command starts it is shown
#          on two sockets of this launch bound outside (the fence) that the
#          refusal is in effect. stdin is /dev/null; stdout and stderr reach
#          the caller through pipes of this script, and the caller's must
#          not be a socket or a terminal. When the command ends, when
#          no-docker.sh itself gets SIGINT, SIGTERM or SIGHUP (such as Ctrl-C,
#          or a caller forwarding the signal) or when unshare dies, every
#          process left inside is killed; the profile is removed only when
#          the kernel shows no process can carry it any more, otherwise it
#          stays loaded, the run fails (125) and says so. A cancelled or
#          timed-out GitHub step does not signal no-docker.sh: its namespace
#          keeps running, confined, read-only and without network, and the
#          profile stays loaded, until the VM is discarded (an accepted
#          residual). docs/dev-environment.md, "Linux", has the details.
# In both, the variables that select an engine are removed and DOCKER_CONFIG
# is an empty directory. Before COMMAND runs, no-docker-probe.py proves from
# inside that each mechanism is in effect and that no engine answers on any
# endpoint it can find. If isolation cannot be applied or proven, COMMAND
# does not run and the exit status is 125; so is the status if the
# isolation tool returns without the command having started inside it, and
# on macOS if the processes the command left could not all be ended.

set -u

here=$(cd -P "$(dirname "$0")" && pwd -P)
probe="$here/no-docker-probe.py"
aa="$here/no-docker-aa.py"
EX_REFUSED=125

refuse() {
  printf 'no-docker: refused: %s; the command was not run\n' "$1" >&2
  exit "$EX_REFUSED"
}

if [ "${1-}" = --check ]; then
  exec python3 -I "$probe"
fi

if [ "${1-}" = --inner ]; then
  # Inside the macOS sandbox: prove it, then run the command. (On Linux
  # no-docker-probe.py --gate-exec does this.)
  [ "$(uname -s)" = Darwin ] || refuse "--inner is used on macOS only"
  shift
  python3 -I "$probe" >&2 || refuse "the isolation could not be proven"
  : >"$NO_DOCKER_STARTED" || refuse "cannot record the start"
  unset NO_DOCKER_STARTED
  exec "$@"
fi

given_work=""
if [ "${1-}" = --work ]; then
  [ $# -ge 2 ] || refuse "--work needs a directory"
  given_work=$2
  shift 2
fi
[ $# -gt 0 ] || refuse "no command given"
if [ -n "${NO_DOCKER_ACTIVE-}" ]; then
  # Already isolated (a suite re-executing itself): never nest.
  python3 -I "$probe" >&2 || refuse "inside no-docker.sh, but the isolation check fails"
  [ -z "$given_work" ] || refuse "--work cannot be used inside the isolation"
  exec "$@"
fi

# uid 0 keeps every capability through the isolation; refused first.
if [ "$(id -u)" = 0 ] || [ "$(id -ru)" = 0 ] || [ "${EUID-}" = 0 ] || [ "${UID-}" = 0 ]; then
  refuse "running as root (uid 0); run it as an unprivileged user"
fi

os=$(uname -s)
uid=$(id -u)

# plain PATH: true if PATH has only characters that are safe in a sandbox
# profile and in the shell of the namespace.
plain() {
  case $1 in "" | *[!A-Za-z0-9/._-]*) return 1 ;; esac
  return 0
}

# owner_mode PATH: "<uid> <octal mode>" of PATH.
owner_mode() {
  if [ "$os" = Darwin ]; then stat -f '%u %Lp' "$1"; else stat -c '%u %a' "$1"; fi
}

# use_work DIR PARENT...: check the caller's --work DIR and use it as $work.
use_work() {
  local d=$1 canon real p inside=no
  shift
  case $d in /*) ;; *) refuse "--work $d is not an absolute path" ;; esac
  plain "$d" || refuse "unexpected character in --work $d"
  case $d in */ | *//* | */./* | */../* | */. | */..) refuse "--work $d is not a canonical path" ;; esac
  [ -d "$d" ] && [ ! -L "$d" ] || refuse "--work $d is not a directory or is a symbolic link"
  canon=$d
  if [ "$os" = Darwin ]; then
    case $d in /var/* | /tmp/*) canon=/private$d ;; esac
  fi
  real=$(cd -P "$d" && pwd -P) || refuse "cannot resolve --work $d"
  [ "$real" = "$canon" ] || refuse "--work $d has a symbolic link in its path ($real)"
  for p in "$@"; do
    case $real in "$p"/?*) inside=yes ;; esac
  done
  [ "$inside" = yes ] || refuse "--work $d is not under $*"
  case $real/ in "$home"/*) refuse "--work $d is under \$HOME" ;; esac
  case $home/ in "$real"/*) refuse "--work $d contains \$HOME" ;; esac
  [ "$(owner_mode "$real")" = "$uid 700" ] || refuse "--work $d is not owned by you with mode 0700"
  [ -z "$(ls -A "$real")" ] || refuse "--work $d is not empty"
  work=$real
}

home=$(cd -P "$HOME" && pwd -P) || refuse "cannot resolve \$HOME"
plain "$home" || refuse "unexpected character in \$HOME ($home)"

case $os in
  Darwin)
    command -v sandbox-exec >/dev/null || refuse "sandbox-exec not found"
    # $TMPDIR must be the per-user temporary directory macOS creates,
    # /private/var/folders/<xx>/<id>/T, owned by the user with mode 0700:
    # any other directory may hold files that run or are read outside the
    # sandbox. The command gets a directory of its own inside it.
    t=${TMPDIR-}
    [ -n "$t" ] || t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || refuse "TMPDIR is unset and getconf DARWIN_USER_TEMP_DIR fails"
    tmp=$(cd -P "$t" 2>/dev/null && pwd -P) || refuse "cannot resolve the temporary directory $t"
    plain "$tmp" || refuse "unexpected character in the temporary directory $tmp"
    case $tmp in
      /private/var/folders/[!/][!/]/?*/T) ;;
      *) refuse "the temporary directory $tmp is not the per-user directory /private/var/folders/<xx>/<id>/T; unset TMPDIR or set it to that directory" ;;
    esac
    rest=${tmp#/private/var/folders/??/}
    case ${rest%/T} in "" | */*) refuse "the temporary directory $tmp is not the per-user directory /private/var/folders/<xx>/<id>/T" ;; esac
    [ "$(owner_mode "$tmp")" = "$uid 700" ] || refuse "the temporary directory $tmp is not owned by you with mode 0700"
    if [ -n "$given_work" ]; then
      use_work "$given_work" "$tmp" /private/var/tmp
    else
      work=$(mktemp -d "$tmp/no-docker.XXXXXX") || refuse "no temporary directory"
      work=$(cd -P "$work" && pwd -P) || refuse "cannot resolve the temporary directory"
      trap 'rm -rf "$work"' EXIT
    fi
    # The sandbox carries a marker of this run (a denied read of a file in
    # its marker directory, which is in $tmp, outside everything the
    # sandbox may write), by which no-docker-probe.py finds its processes
    # from outside: a process cannot leave its sandbox, and every process it
    # starts inherits it. The directory records this process as the run's
    # owner (the supervisor it becomes). An earlier run that ended without
    # its supervisor and may have processes left is ruled out before
    # anything is written into the run's directory.
    markdir=$(python3 -I "$probe" --markers "$tmp" "$$") || refuse "cannot make the marker of the run"
    case $markdir in "$tmp"/no-docker-mark.?*) ;; *) refuse "unexpected marker directory $markdir" ;; esac
    plain "$markdir" || refuse "unexpected character in the marker directory $markdir"
    if [ -n "$given_work" ]; then
      remove=-
      trap 'rm -rf "$markdir"' EXIT
    else
      remove=$work
      trap 'rm -rf "$work" "$markdir"' EXIT
    fi
    python3 -I "$probe" --orphans "$tmp" || refuse "cannot rule out a process left by an earlier isolated run"
    ;;
  Linux)
    # --- Linux: the launch's processes, state and cleanup -------------------------
    # A pid alone may name another process once the one recorded has ended and
    # been reaped (bash reaps its children itself), so every process this script
    # acts on is identified by its pid and its start time (field 22 of
    # /proc/<pid>/stat), read when it was started.

    # proc_stat PID: set ps_comm, ps_state, ps_ppid and ps_start from
    # /proc/PID/stat; false if it cannot be read (the process is gone).
    proc_stat() {
      local line rest
      { IFS= read -r line <"/proc/$1/stat"; } 2>/dev/null || return 1
      ps_comm=${line#*(}
      ps_comm=${ps_comm%)*}
      rest=${line##*) }
      # shellcheck disable=SC2086 # the fields, split on purpose
      set -- $rest
      [ $# -ge 20 ] || return 1
      ps_state=$1 ps_ppid=$2 ps_start=${20}
    }

    # alive PID START: true while the process PID started at START runs (not a
    # zombie).
    alive() {
      [ -n "$1" ] && [ -n "$2" ] && proc_stat "$1" && [ "$ps_state" != Z ] && [ "$ps_start" = "$2" ]
    }

    # wait_gone PID START SECONDS: true once the process no longer runs; false
    # if it still does after SECONDS. A start time not recorded yet is read now.
    wait_gone() {
      local pid=$1 start=$2 end
      [ -n "$pid" ] || return 0
      if [ -z "$start" ]; then
        proc_stat "$pid" || return 0
        start=$ps_start
      fi
      end=$((${EPOCHREALTIME/./} + $3 * 1000000))
      while alive "$pid" "$start"; do
        [ "${EPOCHREALTIME/./}" -lt "$end" ] || return 1
        sleep 0.05
      done
      return 0
    }

    # wait_all SECONDS PID:START...: true once none of the processes runs;
    # false if one still does after SECONDS (all share the one deadline).
    wait_all() {
      local end x p s busy
      end=$((${EPOCHREALTIME/./} + $1 * 1000000))
      shift
      while :; do
        busy=""
        for x in "$@"; do
          p=${x%%:*} s=${x#*:}
          if [ -n "$p" ] && [ -z "$s" ]; then
            proc_stat "$p" || continue
            s=$ps_start
          fi
          if alive "$p" "$s"; then busy=yes; fi
        done
        [ -n "$busy" ] || return 0
        [ "${EPOCHREALTIME/./}" -lt "$end" ] || return 1
        sleep 0.05
      done
    }

    # wait_file PATH: true once PATH exists (within 5 s).
    wait_file() {
      local i=0
      while [ ! -e "$1" ]; do
        [ "$i" -lt 100 ] || return 1
        sleep 0.05
        i=$((i + 1))
      done
    }

    # put_state VALUE: record the launch's state in CTLDIR/state: a new file
    # written, synced and renamed over the old one, then read back. The value
    # is taken as the state before the write, so a signal during it errs on
    # the side of a later state.
    put_state() {
      local got
      state=$1
      printf '%s\n' "$1" >"$ctldir/.state" && sync "$ctldir/.state" && mv -f "$ctldir/.state" "$ctldir/state" &&
        { IFS= read -r got <"$ctldir/state"; } 2>/dev/null && [ "$got" = "$1" ]
    }

    # resolve_pending: a start interrupted between its "&" and the recording of
    # its pid is resolved from $!: changed since the marker was set, the fork
    # happened and $! is the new process; unchanged, it did not.
    resolve_pending() {
      if [ -n "$pending" ] && [ "$!" != "$kept" ]; then
        case $pending in
          stream) fspid=$! ;;
          dgram) fdpid=$! ;;
          load) lpid=$! ;;
          relay-o) opid=$! ;;
          relay-e) epid=$! ;;
          init) spid=$! ;;
        esac
      fi
      pending=""
    }

    # relay_ok PID: true if PID is a child of this shell running cat (the exec
    # may take a moment: up to 1 s); sets ps_start.
    relay_ok() {
      local i=0
      while [ "$i" -lt 50 ]; do
        proc_stat "$1" || return 1
        [ "$ps_ppid" = $$ ] || return 1
        [ "$ps_comm" = cat ] && return 0
        sleep 0.02
        i=$((i + 1))
      done
      return 1
    }

    # own_fds: list this shell's descriptors into CTLDIR/fds (by a child, so the
    # listing's own descriptor is not among them) and set fd_dup to the other
    # descriptors of a relay's pipe and fd_bad to every other unexpected one.
    own_fds() {
      local line fd target ot et
      ls -l "/proc/$$/fd/" >"$ctldir/fds" 2>&1 || return 1
      ot=$(readlink "/proc/$$/fd/$o") && et=$(readlink "/proc/$$/fd/$e") || return 1
      fd_dup="" fd_bad=""
      while IFS= read -r line; do
        case $line in *" -> "*) ;; *) continue ;; esac
        target=${line#* -> }
        fd=${line% -> *}
        fd=${fd##* }
        case $fd in 0 | 1 | 2 | 255 | "$o" | "$e") continue ;; esac
        if [ "$target" = "$ot" ] || [ "$target" = "$et" ]; then
          fd_dup="$fd_dup $fd"
        else
          fd_bad="$fd_bad $fd:$target"
        fi
      done <"$ctldir/fds"
    }

    # sudo_may_run: true unless the sudo that starts the namespaces is known to
    # have ended (reaped by the wait of L9, or no longer running).
    sudo_may_run() {
      [ -z "$sudo_reaped" ] || return 1
      if [ -z "$sstart" ]; then
        proc_stat "$spid" || return 1
        sstart=$ps_start
      fi
      alive "$spid" "$sstart"
    }

    # secs MICROSECONDS: as seconds with two decimals.
    secs() {
      printf '%d.%02d' $(($1 / 1000000)) $(($1 % 1000000 / 10000))
    }

    # cleanup (the EXIT trap, once): end what this launch started, each step
    # only for what was recorded as started and bounded in time, keep the
    # profile loaded unless no-docker-aa.py shows that no process can carry it,
    # and exit with the launch's status.
    # shellcheck disable=SC2317,SC2329 # run as the EXIT trap
    cleanup() {
      local left="" fail="" started=no status t
      [ -z "$cleaning" ] || return
      cleaning=yes
      trap '' INT TERM HUP
      t=${EPOCHREALTIME/./}
      if [ -n "$o" ]; then exec {o}>&-; fi
      if [ -n "$e" ]; then exec {e}>&-; fi
      o="" e=""
      resolve_pending
      # C1: pid 1 of the namespace, killed by no-docker-aa.py, only while sudo
      # may still run; a fork that did not happen is recorded as such.
      case $state in
        entering | entered*)
          if [ -z "$spid" ]; then
            put_state not-forked || fail="$fail; the state not-forked could not be recorded"
          elif sudo_may_run; then
            sudo -n timeout 10 /usr/bin/python3 -I "$aa" kill-init "$$" "$ctldir" || fail="$fail; kill-init failed"
            wait_gone "$spid" "$sstart" 10 || left="the namespace did not end within 10s"
          fi
          ;;
      esac
      # C2: the relays end once every writer is gone; only then may workflow
      # commands resume.
      if wait_all 30 "$opid:$ostart" "$epid:$estart"; then
        if [ "$stopped" = yes ]; then printf '::%s::\n' "$token"; fi
      else
        fail="$fail; a relay of the command's output did not end (workflow commands stay stopped)"
      fi
      # C3: the fence listeners, by identity only.
      for x in "$fspid:$fsstart" "$fdpid:$fdstart"; do
        if alive "${x%%:*}" "${x#*:}"; then kill -TERM "${x%%:*}" 2>/dev/null; fi
      done
      if ! wait_all 2 "$fspid:$fsstart" "$fdpid:$fdstart"; then
        for x in "$fspid:$fsstart" "$fdpid:$fdstart"; do
          if alive "${x%%:*}" "${x#*:}"; then kill -KILL "${x%%:*}" 2>/dev/null; fi
        done
      fi
      [ -z "$fencedir" ] || rm -rf "$fencedir"
      # C4: a load still in flight.
      if [ -n "$lpid" ] && [ -z "$load_done" ]; then
        wait_gone "$lpid" "$lstart" 20 || left="${left:-the profile load did not end within 20s}"
      fi
      # C5: the release, only of a profile whose load was started.
      if [ -n "$lpid" ] && [ -z "$left" ]; then
        local tr=${EPOCHREALTIME/./}
        sudo -n timeout 30 /usr/bin/python3 -I "$aa" release "$profile" "$ctldir" ||
          left="no-docker-aa.py release refused or failed"
        t_release=$((${EPOCHREALTIME/./} - tr))
      fi
      [ -z "$work" ] || [ ! -e "$work/started" ] || started=yes
      # C6
      if [ -n "$left$fail" ]; then
        if [ -n "$left" ]; then
          sudo -n timeout 10 /usr/bin/python3 -I "$aa" diag "$profile"
          printf 'no-docker: refused: profile %s still loaded (%s); cleanup failed; its control directory %s is kept\n' \
            "$profile" "$left" "$ctldir" >&2
          printf '::error title=no-docker::profile %s still loaded (%s); control directory %s\n' "$profile" "$left" "$ctldir"
        fi
        [ -z "$fail" ] || printf 'no-docker: refused: cleanup failed (%s)\n' "${fail#; }" >&2
        [ -z "$ctldir" ] || printf 'no-docker: the control directory %s is kept\n' "$ctldir" >&2
      else
        [ -z "$ctldir" ] || rm -rf "$ctldir"
      fi
      [ "$work_made" != yes ] || rm -rf "$work"
      # C7: the status. A cleanup failure is 125 even after the command
      # succeeded; then a signal; then a refusal; then a command that did not
      # start; then the command's own.
      if [ -n "$left$fail" ]; then
        status=$EX_REFUSED
      elif [ -n "$signalled" ]; then
        status=$signalled
      elif [ "$normal" != yes ]; then
        status=$EX_REFUSED
      elif [ "$started" != yes ]; then
        printf 'no-docker: refused: the isolation tool returned %s without starting the command\n' "$rc" >&2
        status=$EX_REFUSED
      else
        status=$rc
      fi
      if [ -n "$lpid" ]; then
        printf '::notice title=no-docker::launch %ss: preflight %ss, fence %ss, profile load %ss, relays %ss, namespace, gate and command %ss, release %ss, cleanup %ss\n' \
          "$(secs $((${EPOCHREALTIME/./} - t_launch)))" "$(secs "$t_preflight")" "$(secs "$t_fence")" "$(secs "$t_load")" \
          "$(secs "$t_relays")" "$(secs "$t_run")" "$(secs "$t_release")" "$(secs $((${EPOCHREALTIME/./} - t)))"
      fi
      exit "$status"
    }

    # L0: the state of the launch, all empty, and the traps, before any
    # resource exists. Every way out (the normal end, a refusal, INT, TERM,
    # HUP) goes through cleanup, once, which touches only what was recorded
    # as started. "$!" has a value from here on (": &"), so the starts below
    # can be told apart from it under set -u.
    ctldir="" fencedir="" profile="" state="" lpid="" lstart="" load_done="" spid="" sstart="" sudo_reaped=""
    o="" e="" opid="" ostart="" epid="" estart="" fspid="" fsstart="" fdpid="" fdstart=""
    pending="" kept="" token="" stopped="" signalled="" normal="" cleaning="" work="" work_made="" rc=""
    t_launch=${EPOCHREALTIME/./} t_preflight=0 t_load=0 t_fence=0 t_relays=0 t_run=0 t_release=0
    trap '' PIPE
    : &
    kept=$!
    trap cleanup EXIT
    trap 'signalled=130; exit 130' INT
    trap 'signalled=143; exit 143' TERM
    trap 'signalled=129; exit 129' HUP
    # Only GitHub-hosted runners: the VM is discarded after the job, sudo
    # needs no password and no rootless engine or user session exists. The
    # checks below guard against using this elsewhere by accident; they are
    # not a boundary against the caller.
    [ "${GITHUB_ACTIONS-}" = true ] && [ "${RUNNER_ENVIRONMENT-}" = github-hosted ] ||
      refuse "Linux is supported on GitHub-hosted CI runners only (GITHUB_ACTIONS and RUNNER_ENVIRONMENT)"
    found=no
    pid=$PPID
    n=0
    while [ "$pid" -gt 1 ] && [ "$n" -lt 64 ]; do
      comm=$(cat "/proc/$pid/comm" 2>/dev/null) || break
      if [ "$comm" = Runner.Worker ]; then
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || break
        [ "${exe##*/}" = Runner.Worker ] && found=yes
        break
      fi
      st=$(cat "/proc/$pid/stat" 2>/dev/null) || break
      rest=${st##*) }
      rest=${rest#* }
      pid=${rest%% *}
      case $pid in "" | *[!0-9]*) break ;; esac
      n=$((n + 1))
    done
    [ "$found" = yes ] || refuse "Linux is supported on GitHub-hosted CI runners only (no Runner.Worker ancestor)"
    # The new pid namespace is shown to be below the caller's by the
    # caller's being the initial one (no-docker-probe.py).
    [ "$(readlink /proc/self/ns/pid)" = "pid:[4026531836]" ] ||
      refuse "Linux is supported on GitHub-hosted CI runners only (not in the initial pid namespace)"
    protected=$home
    for v in GITHUB_WORKSPACE RUNNER_TEMP; do
      d=$(cd -P "${!v:-/nonexistent}" 2>/dev/null && pwd -P) || refuse "Linux is supported on GitHub-hosted CI runners only ($v is not a directory)"
      plain "$d" || refuse "unexpected character in $v ($d)"
      case $d in "$home"/?*) ;; *) refuse "Linux is supported on GitHub-hosted CI runners only ($v is not under \$HOME)" ;; esac
      protected="$protected:$d"
      runner_temp=$d
    done
    # L1: the caller's stdout and stderr receive what the relays copy from
    # the command; one that is a socket or a terminal would be a channel out
    # of the isolation. stdin is not used: the command gets /dev/null.
    for fd in 1 2; do
      [ -e "/proc/$$/fd/$fd" ] || refuse "the caller's fd $fd is closed"
      if [ -S "/proc/$$/fd/$fd" ] || [ -t "$fd" ]; then
        refuse "the caller's fd $fd is a socket or a terminal; give the command a pipe or a file"
      fi
    done
    for tool in sudo timeout unshare setpriv setsid ip mount find stat python3 od sync; do
      command -v "$tool" >/dev/null || refuse "$tool not found"
    done
    for tool in /usr/bin/python3 /usr/bin/setpriv /usr/bin/aa-exec /usr/bin/setsid /usr/bin/env; do
      [ -x "$tool" ] || refuse "$tool not found"
    done
    sudo -n true 2>/dev/null || refuse "creating the namespaces needs passwordless sudo"
    t=${EPOCHREALTIME/./}
    sudo -n timeout 10 /usr/bin/python3 -I "$aa" preflight || refuse "AppArmor cannot confine the launch (no-docker-aa.py preflight)"
    t_preflight=$((${EPOCHREALTIME/./} - t))
    if [ -n "$given_work" ]; then
      use_work "$given_work" /var/tmp
    else
      work=$(mktemp -d /tmp/no-docker.XXXXXX) || refuse "no temporary directory"
      work_made=yes
      work=$(cd -P "$work" && pwd -P) || refuse "cannot resolve the temporary directory"
    fi
    cwd=$(pwd -P) || refuse "cannot resolve the working directory"
    # What the probe compares inside: the namespaces and the devices of the
    # directories that must be private.
    host_ns=""
    for ns in net mnt pid ipc; do
      v=$(readlink "/proc/self/ns/$ns") || refuse "cannot read the $ns namespace"
      host_ns="$host_ns $ns=$v"
    done
    host_devs=""
    for d in /tmp /var/tmp /dev/shm /run /dev/mqueue; do
      v=$(stat -c %d "$d") || refuse "cannot stat $d"
      host_devs="$host_devs $d=$v"
    done
    # The command keeps the caller's primary group (the probe refuses a
    # system group); for the log, next to the group of the engine socket.
    gid=$(id -g)
    printf 'no-docker: info primary group %s (%s); /var/run/docker.sock group %s\n' "$gid" \
      "$(id -gn 2>/dev/null || echo '?')" "$(stat -Lc '%g (%G)' /var/run/docker.sock 2>/dev/null || echo none)" >&2
    ;;
  *)
    refuse "no isolation mechanism for $os"
    ;;
esac
plain "$work" || refuse "unexpected character in the working directory $work"
mkdir "$work/docker-config" "$work/bin" "$work/tmp" || refuse "cannot prepare $work"

# The environment of the command.
envargs=()
while IFS= read -r -d '' kv; do
  name=${kv%%=*}
  if [ "$os" = Linux ]; then
    # An allowlist: no session bus, display, agent, runner file-command or
    # token variables.
    case $name in
      PATH | HOME | USER | LOGNAME | SHELL | LANG | LANGUAGE | LC_* | TERM | TZ | CI | DEVENV | DEVENV_* | GUARD | GUARD_* | ADAPTED | HARNESS | FLOWCRM_*) envargs+=("$kv") ;;
    esac
  else
    case $name in
      DOCKER_* | CONTAINER_HOST | CONTAINER_CONNECTION | CONTAINERD_* | BUILDKIT_HOST | COMPOSE_* | PODMAN_* | NO_DOCKER_* | TMPDIR) ;;
      *) envargs+=("$kv") ;;
    esac
  fi
done < <(env -0)
envargs+=("DOCKER_CONFIG=$work/docker-config" "TMPDIR=$work/tmp" "NO_DOCKER_ACTIVE=1"
  "NO_DOCKER_ORIGINAL_HOST=${DOCKER_HOST-}" "NO_DOCKER_STARTED=$work/started" "NO_DOCKER_RUN_DIR=$work")

case $os in
  Darwin)
    # A copy of ps loses its setuid bit; it needs a signature of its own.
    { cp /bin/ps "$work/bin/ps" && codesign -f -s - "$work/bin/ps" 2>/dev/null; } ||
      refuse "cannot prepare an unprivileged ps"
    for i in "${!envargs[@]}"; do
      case ${envargs[$i]} in PATH=*) envargs[i]="PATH=$work/bin:${envargs[$i]#PATH=}" ;; esac
    done
    # Local services that were listening before the command started (a
    # development server, an IDE, a published container port or a socket
    # proxy) are not the command's: it may connect only to loopback ports it
    # opens itself. Every listening port number is held, whatever address
    # it listens on.
    listening=$(python3 -I "$probe" --listening) || refuse "cannot list the listening TCP ports"
    held=""
    for port in $listening; do
      case $port in *[!0-9]* | "") refuse "unexpected port $port" ;; esac
      held="$held (remote ip \"localhost:$port\")"
    done
    envargs+=("NO_DOCKER_HELD_PORTS=$(printf '%s' "$listening" | tr '\n' ' ')" "NO_DOCKER_OUTER_PID=$$"
      "NO_DOCKER_USER_TMP=$tmp")
    envargs+=("NO_DOCKER_MARK=$markdir")
    # File writes: the run's directory; of /dev only what shells and
    # interpreters open for writing (measured, docs/dev-environment.md).
    # Nothing in /tmp: bash 3.2 keeps here-documents there when it cannot
    # use /var/tmp, whatever $TMPDIR is, so code run inside must not use
    # here-documents or here-strings, and no bash in another sandbox can
    # have its here-documents changed from inside. Signals, task ports
    # (debuggers, vmmap, sample) and process names only within this
    # sandbox; no ptrace of any process; no reading other terminals. An
    # SBPL error makes sandbox-exec fail, so the command never starts (125).
    profile="(version 1)
(allow default)
(deny network-outbound (remote unix-socket))
(deny network-outbound (remote ip))
(allow network-outbound (remote ip \"localhost:*\"))
(deny network-outbound (remote ip \"localhost:22\") (remote ip \"localhost:2375\") (remote ip \"localhost:2376\")$held)
(deny file-write*)
(allow file-write* (subpath \"$work\") (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/[0-9]+\$\"))
(deny file-read-data (literal \"$markdir/a\"))
(deny file-read* (regex #\"^/dev/ttys[0-9]+\$\"))
(deny user-preference-write)
(deny file-ioctl (ioctl-command #x80017472))
(deny process-exec (literal \"/usr/bin/open\") (literal \"/usr/bin/osascript\") (literal \"/bin/launchctl\") (literal \"/usr/bin/ssh\"))
(deny job-creation)
(deny lsopen)
(deny appleevent-send)
(deny mach-lookup (global-name \"com.apple.coreservices.launchservicesd\") (global-name \"com.apple.coreservices.appleevents\") (global-name-regex #\"^com\\.apple\\.lsd\\.\") (global-name \"com.apple.xpc.smd\") (global-name-regex #\"^com\\.apple\\.backgroundtaskmanagement\") (global-name-regex #\"^com\\.apple\\.coreservices\\.sharedfilelistd\") (global-name-regex #\"^com\\.docker\\.\") (global-name-regex #\"^com\\.electron\\.dockerdesktop\\.\"))
(deny system-debug)
(deny mach-task-name mach-task-read mach-task-inspect mach-priv-task-port)
(allow mach-task-name mach-task-read mach-task-inspect mach-priv-task-port (target same-sandbox))
(deny signal)
(allow signal (target same-sandbox))"
    # The supervisor takes over this process: a signal sent to it ends the
    # command and everything it left at once, and so does the command's
    # end. It removes the run's directory (unless given with --work) and
    # the marker directory.
    trap - EXIT
    shopt -s execfail
    exec python3 -I "$probe" --supervise "$markdir" "$work/started" "$remove" -- /usr/bin/sandbox-exec -p "$profile" \
      /usr/bin/env -i "${envargs[@]}" "$BASH" "$here/no-docker.sh" --inner "$@"
    rm -rf "$markdir"
    [ "$remove" = - ] || rm -rf "$work"
    refuse "cannot start the supervisor (python3)"
    ;;
  Linux)
    # L2: the control directory (the launch's state, the namespace record,
    # the profile's kernel hash), the fence directory and the profile name.
    # Both directories are read-only inside (the seal).
    ctldir=$(mktemp -d "$runner_temp/no-docker-ctl.XXXXXX") || refuse "no control directory"
    fencedir=$(mktemp -d "$runner_temp/no-docker-fence.XXXXXX") || refuse "no fence directory"
    plain "$ctldir" || refuse "unexpected character in $ctldir"
    plain "$fencedir" || refuse "unexpected character in $fencedir"
    hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    case $hex in *[!0-9a-f]*) refuse "cannot make a random profile name" ;; esac
    [ "${#hex}" -eq 32 ] || refuse "cannot make a random profile name"
    profile=flowcrm-nd-$hex
    put_state loading || refuse "cannot record the state of the launch"

    # L3: the fence, two sockets of this launch bound outside the namespace
    # (stream and datagram), which the command's gate must find refused with
    # EACCES. The listeners are this shell's own children; each dies with it
    # (PR_SET_PDEATHSIG) and exits unless its parent is this shell.
    t=${EPOCHREALTIME/./}
    # shellcheck disable=SC2016 # Python, not shell
    fence_py='
import ctypes, os, socket, sys
kind, path, launcher, ready = sys.argv[1:5]
if ctypes.CDLL(None, use_errno=True).prctl(1, 9, 0, 0, 0) != 0 or os.getppid() != int(launcher):
    sys.exit(3)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM if kind == "stream" else socket.SOCK_DGRAM)
s.bind(path)
if kind == "stream":
    s.listen(64)
with open(ready + ".tmp", "w") as f:
    f.write("ready\n")
os.rename(ready + ".tmp", ready)
while True:
    if kind == "stream":
        s.accept()[0].close()
    else:
        s.recv(65536)
'
    pending=stream kept=$!
    python3 -I -c "$fence_py" stream "$fencedir/stream" "$$" "$fencedir/stream.ready" </dev/null >"$fencedir/stream.log" 2>&1 &
    fspid=$! pending=
    proc_stat "$fspid" && fsstart=$ps_start
    pending=dgram kept=$!
    python3 -I -c "$fence_py" dgram "$fencedir/dgram" "$$" "$fencedir/dgram.ready" </dev/null >"$fencedir/dgram.log" 2>&1 &
    fdpid=$! pending=
    proc_stat "$fdpid" && fdstart=$ps_start
    [ -n "$fsstart" ] && [ -n "$fdstart" ] || refuse "the fence listeners did not start"
    wait_file "$fencedir/stream.ready" || refuse "the stream fence listener did not start"
    wait_file "$fencedir/dgram.ready" || refuse "the datagram fence listener did not start"
    # The positive control: outside, both sockets are reachable.
    python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sys.argv[1] + "/stream")
s.close()
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(b"no-docker fence", sys.argv[1] + "/dgram")
s.close()
' "$fencedir" </dev/null || refuse "the fence cannot be reached outside the isolation"
    t_fence=$((${EPOCHREALTIME/./} - t))

    # L4: the profile of this launch, from the pinned template (root, 20 s).
    # sudo runs as root: whether it still runs is read from /proc (pid and
    # start time), never with kill -0, which this user may not send it.
    t=${EPOCHREALTIME/./}
    pending=load kept=$!
    sudo -n timeout 20 /usr/bin/python3 -I "$aa" load "$profile" "$ctldir" &
    lpid=$! pending=
    proc_stat "$lpid" && lstart=$ps_start
    wait_gone "$lpid" "$lstart" 25 || refuse "loading the AppArmor profile did not end within 25s"
    wait "$lpid"
    lrc=$? load_done=yes
    [ "$lrc" -eq 0 ] || refuse "the AppArmor profile could not be loaded (status $lrc)"
    t_load=$((${EPOCHREALTIME/./} - t))

    # L5: workflow commands in the command's output are ignored: the token
    # is random and never passed inside. It is printed again only once the
    # relays have copied all of the command's output (cleanup).
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#token}" -eq 32 ] || refuse "cannot make a random token"
    printf '::stop-commands::%s\n' "$token" || refuse "cannot print the token that stops workflow commands"
    stopped=yes
    printf '::stop-commands::%s\n' "$token" >&2 || refuse "cannot print the token that stops workflow commands"
    # The relays: the command's stdout and stderr are pipes to these two
    # children of this shell, which copy to the caller's.
    t=${EPOCHREALTIME/./}
    pending=relay-o kept=$!
    exec {o}> >(exec cat) || refuse "cannot start the stdout relay"
    opid=$! pending=
    pending=relay-e kept=$!
    exec {e}> >(exec cat >&2 {o}>&-) || refuse "cannot start the stderr relay"
    epid=$! pending=
    relay_ok "$opid" || refuse "the stdout relay is not a cat of this shell"
    ostart=$ps_start
    relay_ok "$epid" || refuse "the stderr relay is not a cat of this shell"
    estart=$ps_start
    # No descriptor of this shell but 0 to 2, the relays' write ends and
    # the script may reach the namespace (sudo also closes those above 2).
    own_fds || refuse "cannot list the descriptors of no-docker.sh"
    if [ -n "$fd_dup" ]; then
      for x in $fd_dup; do exec {x}>&-; done
      own_fds || refuse "cannot list the descriptors of no-docker.sh"
    fi
    [ -z "$fd_dup$fd_bad" ] || refuse "an unexpected descriptor is open in no-docker.sh:$fd_dup$fd_bad"
    t_relays=$((${EPOCHREALTIME/./} - t))

    envargs+=("NO_DOCKER_HOST_NS=${host_ns# }" "NO_DOCKER_HOST_DEVS=${host_devs# }" "NO_DOCKER_PROTECTED=$protected"
      "NO_DOCKER_PROFILE=$profile" "NO_DOCKER_CTL=$ctldir" "NO_DOCKER_FENCE=$fencedir")
    # pid 1 of the new pid namespace is this root shell. It does not exec:
    # it keeps the parent-death signal of --kill-child (a credential change
    # would clear it), reaps orphans while it waits, and its exit kills
    # everything left in the namespace. Its first action records the
    # namespace (CTLDIR/ns), before anything untrusted exists.
    # shellcheck disable=SC2016 # expanded by the shell in the namespace
    init='
      set -u
      PATH=/usr/sbin:/usr/bin:/sbin:/bin
      export PATH
      die() { printf "no-docker: refused: %s; the command was not run\n" "$1" >&2; exit 125; }
      uid=$1 gid=$2 work=$3 probe=$4 cwd=$5 ctl=$6 name=$7
      shift 7
      p=$(readlink /proc/self/ns/pid) && m=$(readlink /proc/self/ns/mnt) || die "cannot read the namespaces"
      p=${p#pid:?} m=${m#mnt:?}
      p=${p%?} m=${m%?}
      case $p in "" | *[!0-9]*) die "unexpected pid namespace link" ;; esac
      case $m in "" | *[!0-9]*) die "unexpected mount namespace link" ;; esac
      umask 0222
      printf "pid:%s mnt:%s\n" "$p" "$m" >"$ctl/.ns.init" && sync "$ctl/.ns.init" &&
        mv -f "$ctl/.ns.init" "$ctl/ns" || die "cannot record the namespace"
      umask 0022
      cd / || die "cannot leave the working directory"
      ip link set lo up || die "cannot bring up loopback"
      mount -t tmpfs -o mode=0755,nosuid,nodev,noexec no-docker /run || die "cannot hide /run"
      mkdir /run/no-docker /run/no-docker/work || die "cannot prepare /run"
      mount --bind "$work" /run/no-docker/work || die "cannot keep $work"
      if [ -d /var/run ] && [ ! -L /var/run ]; then
        mount -t tmpfs -o mode=0755,nosuid,nodev,noexec no-docker /var/run || die "cannot hide /var/run"
      fi
      for d in /tmp /var/tmp /dev/shm; do
        mount -t tmpfs -o mode=1777,nosuid,nodev no-docker "$d" || die "cannot hide $d"
      done
      mount -t mqueue -o nosuid,nodev,noexec no-docker /dev/mqueue || die "cannot mount a private /dev/mqueue"
      mount -t tmpfs -o ro,mode=0555,nosuid,nodev,noexec no-docker /sys/fs/cgroup || die "cannot mask /sys/fs/cgroup"
      mkdir -p "$work" && mount --move /run/no-docker/work "$work" || die "cannot move $work into the private temporary directory"
      python3 -I "$probe" --seal "$work" || die "cannot make the other mounts read-only"
      cd "$cwd" || die "the working directory $cwd is not visible in the isolation"
      /usr/bin/python3 -I "$probe" --root-exec "$uid" "$gid" "$name" "$@" &
      child=$!
      wait "$child"
      exit $?
    '
    # The state is "entering" before the fork, read back; if it cannot be
    # recorded nothing is started. The marker and the last pid are taken in
    # one command, so cleanup can tell whether the fork happened ($! is set
    # in this shell right after fork(), and traps run between commands).
    put_state entering || refuse "cannot record the state of the launch"
    t=${EPOCHREALTIME/./}
    pending=init kept=$!
    sudo -n unshare --net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
      /bin/sh -c "$init" no-docker-init "$uid" "$gid" "$work" "$probe" "$cwd" "$ctldir" "$profile" \
      -- "${envargs[@]}" -- "$@" </dev/null >&"$o" 2>&"$e" {o}>&- {e}>&- &
    spid=$! pending=
    proc_stat "$spid" && sstart=$ps_start
    put_state "entered spid=$spid" || refuse "cannot record the state of the launch"
    exec {o}>&- {e}>&-
    o="" e=""
    # L9: the command's end (sudo's), then cleanup.
    wait "$spid"
    rc=$? sudo_reaped=yes
    t_run=$((${EPOCHREALTIME/./} - t))
    normal=yes
    exit "$rc"
    ;;
esac
