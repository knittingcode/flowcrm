#!/usr/bin/env bash
#
# Run a command where no container engine can be reached, so a test suite,
# and any modified or mutated copy of the code it runs, cannot touch the
# Docker daemon of the machine (its images, containers, volumes, networks
# or build cache) by the routes below: docker found on PATH or by an
# absolute path, in a nested shell or a command substitution, with -H,
# --context or an inherited DOCKER_HOST, curl --unix-socket or a raw socket.
#
# Usage: no-docker.sh COMMAND [ARG...]   run COMMAND isolated; its status
#        no-docker.sh --check            exit 0 only if this process is
#                                        already isolated
#
# Isolation:
#   macOS  sandbox-exec: every connect to a Unix socket is denied, as is TCP
#          to anything but loopback and to loopback ports 22, 2375 and 2376
#          (ssh and the Docker API ports); nothing under $HOME can be
#          written (Docker Desktop keeps its disk image there); open,
#          osascript, launchctl and ssh cannot run and Launch Services and
#          Apple Events cannot be reached (the known ways to have a program
#          started outside the sandbox). The profile filters these routes;
#          it is not a complete jail. Setuid programs cannot run in the sandbox, so
#          ps is an unprivileged, ad-hoc signed copy. Loopback TCP to other
#          ports stays open for the tests; the probe asks every listening
#          port whether it is an engine (a socket proxy, for example).
#   Linux  sudo unshare: a network namespace with only loopback and a mount
#          namespace with an empty tmpfs over /run (and /var/run), then the
#          calling user without supplementary groups (no docker group) and
#          with no_new_privs, so sudo cannot regain root to undo it.
# In both, DOCKER_* and similar variables are removed and DOCKER_CONFIG is
# an empty directory. Before COMMAND runs, no-docker-probe.py proves from
# inside that the mechanism is in effect and that no engine answers on any
# endpoint it can find. If isolation cannot be applied or proven, COMMAND
# does not run and the exit status is 125; so is the status if the
# isolation tool returns without the command having started inside it.

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

[ $# -gt 0 ] || refuse "no command given"
if [ -n "${NO_DOCKER_ACTIVE-}" ]; then
  # Already isolated (a suite re-executing itself): never nest.
  python3 -I "$probe" >/dev/null || refuse "inside no-docker.sh, but the isolation check fails"
  exec "$@"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/no-docker.XXXXXX") || refuse "no temporary directory"
work=$(cd -P "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
mkdir "$work/docker-config" "$work/bin" || refuse "cannot prepare $work"

# The environment of the command: the caller's, without the variables that
# select a container engine or its configuration.
envargs=()
while IFS= read -r -d '' kv; do
  case ${kv%%=*} in
    DOCKER_* | CONTAINER_HOST | CONTAINER_CONNECTION | CONTAINERD_* | BUILDKIT_HOST | COMPOSE_* | PODMAN_* | NO_DOCKER_*) ;;
    *) envargs+=("$kv") ;;
  esac
done < <(env -0)
envargs+=("DOCKER_CONFIG=$work/docker-config" "NO_DOCKER_ACTIVE=1" "NO_DOCKER_ORIGINAL_HOST=${DOCKER_HOST-}"
  "NO_DOCKER_STARTED=$work/started")

case $(uname -s) in
  Darwin)
    command -v sandbox-exec >/dev/null || refuse "sandbox-exec not found"
    # A copy of ps loses its setuid bit; it needs a signature of its own.
    { cp /bin/ps "$work/bin/ps" && codesign -f -s - "$work/bin/ps" 2>/dev/null; } ||
      refuse "cannot prepare an unprivileged ps"
    for i in "${!envargs[@]}"; do
      case ${envargs[$i]} in PATH=*) envargs[i]="PATH=$work/bin:${envargs[$i]#PATH=}" ;; esac
    done
    home=$(cd -P "$HOME" && pwd -P)
    profile="(version 1)
(allow default)
(deny network-outbound (remote unix-socket))
(deny network-outbound (remote ip))
(allow network-outbound (remote ip \"localhost:*\"))
(deny network-outbound (remote ip \"localhost:22\") (remote ip \"localhost:2375\") (remote ip \"localhost:2376\"))
(deny file-write* (subpath \"$home\"))
(deny process-exec (literal \"/usr/bin/open\") (literal \"/usr/bin/osascript\") (literal \"/bin/launchctl\") (literal \"/usr/bin/ssh\"))
(deny mach-lookup (global-name \"com.apple.coreservices.launchservicesd\") (global-name \"com.apple.coreservices.appleevents\") (global-name-regex #\"^com\\.apple\\.lsd\\.\"))"
    sandbox-exec -p "$profile" /usr/bin/env -i "${envargs[@]}" "$BASH" "$here/no-docker.sh" --inner "$@"
    ;;
  Linux)
    for tool in unshare setpriv ip; do
      command -v "$tool" >/dev/null || refuse "$tool not found"
    done
    sudo -n true 2>/dev/null || refuse "creating the namespaces needs passwordless sudo"
    # shellcheck disable=SC2016 # expanded by the inner shell
    sudo -n unshare --net --mount --propagation private -- /bin/sh -c '
      ip link set lo up || exit 125
      mount -t tmpfs -o mode=0755,nosuid,nodev,noexec no-docker /run || exit 125
      if [ -d /var/run ] && [ ! -L /var/run ]; then
        mount -t tmpfs -o mode=0755,nosuid,nodev,noexec no-docker /var/run || exit 125
      fi
      uid=$1 gid=$2
      shift 2
      exec setpriv --reuid "$uid" --regid "$gid" --clear-groups --no-new-privs -- /usr/bin/env -i "$@"
    ' no-docker "$(id -u)" "$(id -g)" "${envargs[@]}" "$BASH" "$here/no-docker.sh" --inner "$@"
    ;;
  *)
    refuse "no isolation mechanism for $(uname -s)"
    ;;
esac
rc=$?
[ -e "$work/started" ] || refuse "the isolation tool returned $rc without starting the command"
exit "$rc"
