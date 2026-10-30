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
#   Linux  sudo unshare: new network (loopback only), mount, pid, and IPC
#          namespaces; empty tmpfs over /run, /var/run, /tmp, /var/tmp,
#          /dev/shm and /sys/fs/cgroup, a fresh /dev/mqueue, every other mount
#          read-only; the command runs as the calling user without
#          supplementary groups, capabilities or the means to regain them
#          (no_new_privs), in a session of its own, with an allowlisted
#          environment, under a root pid 1 that waits for it; when it ends,
#          when no-docker.sh itself gets SIGINT, SIGTERM or SIGHUP (such as
#          Ctrl-C, or a caller forwarding the signal) or when unshare dies,
#          every process left inside is killed. A cancelled or timed-out
#          GitHub step does not signal no-docker.sh: its namespace keeps
#          running, read-only and without network, until the VM is
#          discarded (an accepted residual).
#          Unix sockets found outside before the start must not accept a
#          connection inside.
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
EX_REFUSED=125

refuse() {
  printf 'no-docker: refused: %s; the command was not run\n' "$1" >&2
  exit "$EX_REFUSED"
}

if [ "${1-}" = --check ]; then
  exec python3 -I "$probe"
fi

if [ "${1-}" = --inner ]; then
  # Inside the isolation: prove it, then run the command.
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
  python3 -I "$probe" >/dev/null || refuse "inside no-docker.sh, but the isolation check fails"
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

# kill_isolation (Linux): SIGKILL the unshare that this script started:
# a process named unshare whose ancestors include $spid, the sudo of this
# script. Called from the INT/TERM/HUP trap.
# shellcheck disable=SC2329
kill_isolation() {
  local d p q st n rest
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$(cat "$d/comm" 2>/dev/null)" = unshare ] || continue
    q=$p
    n=0
    while [ "$n" -lt 16 ]; do
      st=$(cat "/proc/$q/stat" 2>/dev/null) || break
      # Field 4, the parent: after the name, "STATE PPID ...".
      rest=${st##*) }
      rest=${rest#* }
      q=${rest%% *}
      case $q in "" | *[!0-9]*) break ;; esac
      [ "$q" -gt 1 ] || break
      if [ "$q" = "$spid" ]; then
        sudo -n kill -KILL "$p" 2>/dev/null
        break
      fi
      n=$((n + 1))
    done
  done
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
    protected=$home
    for v in GITHUB_WORKSPACE RUNNER_TEMP; do
      d=$(cd -P "${!v:-/nonexistent}" 2>/dev/null && pwd -P) || refuse "Linux is supported on GitHub-hosted CI runners only ($v is not a directory)"
      plain "$d" || refuse "unexpected character in $v ($d)"
      case $d in "$home"/?*) ;; *) refuse "Linux is supported on GitHub-hosted CI runners only ($v is not under \$HOME)" ;; esac
      protected="$protected:$d"
    done
    for tool in sudo unshare setpriv setsid ip mount find stat python3; do
      command -v "$tool" >/dev/null || refuse "$tool not found"
    done
    sudo -n true 2>/dev/null || refuse "creating the namespaces needs passwordless sudo"
    if [ -n "$given_work" ]; then
      use_work "$given_work" /var/tmp
    else
      work=$(mktemp -d /tmp/no-docker.XXXXXX) || refuse "no temporary directory"
      work=$(cd -P "$work" && pwd -P) || refuse "cannot resolve the temporary directory"
      trap 'rm -rf "$work"' EXIT
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
    # Every Unix socket on the local file systems and every bound one of
    # the host's network namespace; inside, none may accept a connection.
    # A time budget that runs out refuses rather than truncating the list.
    timing=$(python3 -I "$probe" --sockets 2>&1 >"$work/sockets.list") || refuse "cannot list the Unix sockets: $timing"
    # Its duration, in the log of every run (the budget is 180 s).
    printf '%s\n' "$timing" >&2
    printf '::notice title=no-docker::%s\n' "${timing#no-docker: }"
    envargs+=("NO_DOCKER_SOCKETS=/run/no-docker/sockets.list" "NO_DOCKER_HOST_NS=${host_ns# }"
      "NO_DOCKER_HOST_DEVS=${host_devs# }" "NO_DOCKER_PROTECTED=$protected")
    # pid 1 of the new pid namespace is this root shell. It does not exec:
    # it keeps the parent-death signal of --kill-child (a credential change
    # would clear it), reaps orphans while it waits, and its exit kills
    # everything left in the namespace.
    # shellcheck disable=SC2016 # expanded by the shell in the namespace
    init='
      set -u
      PATH=/usr/sbin:/usr/bin:/sbin:/bin
      export PATH
      die() { printf "no-docker: refused: %s; the command was not run\n" "$1" >&2; exit 125; }
      uid=$1 gid=$2 work=$3 probe=$4 cwd=$5
      shift 5
      cd / || die "cannot leave the working directory"
      ip link set lo up || die "cannot bring up loopback"
      mount -t tmpfs -o mode=0755,nosuid,nodev,noexec no-docker /run || die "cannot hide /run"
      mkdir /run/no-docker /run/no-docker/work || die "cannot prepare /run"
      mount --bind "$work" /run/no-docker/work || die "cannot keep $work"
      cp "$work/sockets.list" /run/no-docker/sockets.list && chmod 0444 /run/no-docker/sockets.list &&
        rm -f "$work/sockets.list" || die "cannot keep the socket list"
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
      # An asynchronous command gets /dev/null as stdin unless it is
      # given one explicitly: that of the caller, through fd 3.
      exec 3<&0
      setpriv --reuid "$uid" --regid "$gid" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
        setsid --wait /usr/bin/env -i "$@" <&3 3<&- &
      child=$!
      exec 3<&-
      wait "$child"
      exit $?
    '
    # Workflow commands in the command's output are ignored: the token is
    # random and never passed inside.
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#token}" -eq 32 ] || refuse "cannot make a random token"
    printf '::stop-commands::%s\n' "$token"
    printf '::stop-commands::%s\n' "$token" >&2
    # Interruption: unshare runs as root and, with --fork, blocks SIGINT and
    # SIGTERM; pid 1 ignores signals from outside its namespace. So SIGINT,
    # SIGTERM or SIGHUP delivered to this script itself (Ctrl-C, or a caller
    # forwarding the signal) is turned into SIGKILL of the unshare started
    # below, found as a descendant of its sudo; --kill-child then kills
    # pid 1, and with it every process inside. A cancelled or timed-out
    # GitHub step signals only the step's shell and later SIGKILLs the
    # process tree, so it does not reach this trap: the namespace keeps
    # running, read-only and without network, until the VM is discarded.
    exec 3<&0
    sudo -n unshare --net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
      /bin/sh -c "$init" no-docker-init "$uid" "$(id -g)" "$work" "$probe" "$cwd" \
      "${envargs[@]}" "$BASH" "$here/no-docker.sh" --inner "$@" <&3 3<&- &
    spid=$!
    exec 3<&-
    interrupted=""
    trap 'interrupted=yes; kill_isolation' INT TERM HUP
    while :; do
      wait "$spid"
      rc=$?
      [ -n "$interrupted" ] || break
      interrupted=""
    done
    trap - INT TERM HUP
    printf '::%s::\n' "$token"
    ;;
esac
[ -e "$work/started" ] || refuse "the isolation tool returned $rc without starting the command"
exit "$rc"
