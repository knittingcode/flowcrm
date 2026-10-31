#!/usr/bin/env bash
# FCRM-SEC-023 controlled AppArmor spike (frozen package; run only under an
# explicit owner authorization). GitHub-hosted ubuntu-24.04 runner only.
#
# Question: does an AppArmor profile without attach_disconnected, applied with
# aa-exec to an unprivileged process in new mount/pid/net/ipc namespaces,
# refuse (EACCES) every connect to a pathname Unix socket bound by a host
# process, while sockets bound inside stay usable?
#
# Safety: no container engine command and no socket but this script's own
# listeners; every path under $RUNNER_TEMP/fcrm-spike-<run>-<attempt>;
# profiles named fcrm-spike-<16 random hex>-<suffix>, added (-a, never
# replaced), removed only when no task carries them; listeners signalled only
# after their pid, start time and command line match; one bind mount, inside
# the base directory, unmounted in cleanup.
#
# Output: PRE/CASE/OBS lines "<kind> <id> <PASS|FAIL|INCONCLUSIVE|NOT-RUN|value>
# <detail>", CLEANUP lines, and last SPIKE-DECISION GO | NO-GO | INCONCLUSIVE.
set -u
export LC_ALL=C
unset NET DECIDED

here=$(cd -P "$(dirname "$0")" && pwd -P)
S=$here/sock.py
U=$(id -u)
G=$(id -g)
PIDS=()       # "pid starttime address" of this shell's listeners
BGJOBS=()     # background namespace runs (sudo, bounded by timeout)
LOADED=()
MOUNTS=()
SETUP_FAILS=()
REQ_FAIL=()
REQ_INC=()
PRE_FAIL=()
PRE_INC=()
CLEAN_FAILS=()
CLEANED=no
MODE=main

say() { printf '%s\n' "$*"; }
setup_fail() { SETUP_FAILS+=("$1"); say "SETUP FAILED $1"; }

# --- base directory, validated (no symlink anywhere in it)
if [ "${1-}" = --abort-selftest ]; then
  MODE=abort
  B=$2
  P=$3
else
  [ "${GITHUB_ACTIONS-}" = true ] && [ "${RUNNER_ENVIRONMENT-}" = github-hosted ] ||
    { say "SPIKE-DECISION INCONCLUSIVE (refused: GitHub-hosted runner only)"; exit 2; }
  case ${GITHUB_RUN_ID-}${GITHUB_RUN_ATTEMPT-} in "" | *[!0-9]*) say "SPIKE-DECISION INCONCLUSIVE (setup: run id)"; exit 2 ;; esac
  rt=${RUNNER_TEMP-}
  case $rt in /*) ;; *) say "SPIKE-DECISION INCONCLUSIVE (setup: RUNNER_TEMP)"; exit 2 ;; esac
  [ -d "$rt" ] && [ ! -L "$rt" ] && [ "$(realpath -e "$rt")" = "$rt" ] ||
    { say "SPIKE-DECISION INCONCLUSIVE (setup: RUNNER_TEMP is not a canonical directory)"; exit 2; }
  B=$rt/fcrm-spike-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT
  N=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  P=fcrm-spike-$N
fi
case $P in fcrm-spike-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) say "SPIKE-DECISION INCONCLUSIVE (setup: profile prefix $P)"; exit 2 ;; esac
if [ "$MODE" = main ]; then
  mkdir -m 0700 "$B" || { say "SPIKE-DECISION INCONCLUSIVE (setup: cannot create $B)"; exit 2; }
fi
if ! { [ -d "$B" ] && [ ! -L "$B" ] && [ "$(realpath -e "$B")" = "$B" ] && [ "$(stat -c %u "$B")" = "$U" ]; }; then
  [ "$MODE" = abort ] || rmdir -- "$B" 2>/dev/null
  say "SPIKE-DECISION INCONCLUSIVE (setup: base directory $B not ours or not canonical)"
  exit 2
fi

starttime() { # pid -> field 22 of /proc/<pid>/stat, empty if gone
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  s=${s##*) }
  # shellcheck disable=SC2086 # split the fields on purpose
  set -- $s
  printf '%s' "${20-}"
}
is_ours() { # pid starttime address: the same listener process of this run
  [ -n "$2" ] && [ "$(starttime "$1")" = "$2" ] &&
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qF -- "$S listen $3 "
}
listen() { # address stream|dgram -> background listener of this user
  local f p st i
  f=$B/ready.$RANDOM$RANDOM
  python3 -I "$S" listen "$1" "$2" 270 >"$f" 2>&1 &
  p=$!
  st=$(starttime "$p")
  PIDS+=("$p $st $1")
  for i in $(seq 50); do
    grep -qx READY "$f" 2>/dev/null && return 0
    sleep 0.1
  done
  setup_fail "listener:$1"
  return 1
}
# Counts print "unknown" when the list cannot be read, which never equals 0.
profiles_with() { # regex of a name -> loaded profiles matching it
  local l
  l=$(sudo -n timeout 10 cat /sys/kernel/security/apparmor/profiles 2>/dev/null) || { printf unknown; return; }
  printf '%s\n' "$l" | grep -c "^$1 " || true
}
tasks_with() { # profile name -> tasks (threads included) carrying it, alone or stacked
  local l
  l=$(sudo -n timeout 10 sh -c 'cat /proc/[0-9]*/task/[0-9]*/attr/apparmor/current 2>/dev/null; true') || { printf unknown; return; }
  printf '%s\n' "$l" | grep -cE "(^|//&)$1( |//)" || true
}
profile_text() { # name flags capability-rule
  printf 'abi <abi/4.0>,\nprofile %s flags=(%s) {\n  file,\n  unix,\n  network,\n  deny network vsock,\n  signal,\n  ptrace (read, readby, trace, tracedby) peer=%s,\n  %s\n  deny mount,\n  deny umount,\n  deny pivot_root,\n}\n' \
    "$1" "$2" "$1" "${3:-deny capability,}"
}
load() { # name flags [capability-rule]
  local t
  case $1 in "$P"-[a-z0-9]*) ;; *) setup_fail "name:$1"; return 1 ;; esac
  if [ "$(profiles_with "$1")" != 0 ]; then setup_fail "exists:$1"; return 1; fi
  t=$(profile_text "$@")
  printf '%s\n' "$t" | sed "s/^/INFO profile $1: /"
  if printf '%s\n' "$t" | sudo -n timeout 30 apparmor_parser -a -K -q; then
    LOADED+=("$1")
    return 0
  fi
  setup_fail "load:$1"
  return 1
}
# ns OUT PROFILE|none CMD...: CMD in new mount/pid/ipc (and net unless NET=0)
# namespaces as this user, without groups or capabilities, no_new_privs, a
# private /tmp; under PROFILE through aa-exec. All output to OUT.
ns() {
  local o=$1 p=$2 net=--net wrap=()
  shift 2
  [ "${NET-1}" = 1 ] || net=
  [ "$p" = none ] || wrap=(aa-exec -p "$p" --)
  # shellcheck disable=SC2086,SC2024 # $net is one flag or nothing; this user, not root, writes OUT
  sudo -n timeout -s KILL 20 unshare $net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
    /bin/sh -c 'mount -t tmpfs -o mode=1777,nosuid,nodev spike /tmp || exit 99; exec "$@"' spike-init \
    setpriv --reuid "$U" --regid "$G" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
    "${wrap[@]}" "$@" >"$o" 2>&1
}
lbl() { sed -n 's/^LABEL //p' "$1" 2>/dev/null | tail -n 1; }
res() { local r; r=$(sed -n 's/^RESULT //p' "$1" 2>/dev/null | tail -n 1); printf '%s' "${r:-missing}"; }
audit_has() { # socket file name: an AppArmor DENIED line of profile -a for it, disconnected path
  { sudo -n timeout 10 dmesg 2>/dev/null; sudo -n timeout 10 journalctl -k --no-pager -o cat 2>/dev/null
    sudo -n timeout 10 cat /var/log/audit/audit.log 2>/dev/null; } |
    grep 'apparmor="DENIED"' | grep -F "profile=\"$P-a\"" | grep -F "$1" | grep -q 'disconnected path'
}
pre() { # id PASS|FAIL|INCONCLUSIVE detail. FAIL: the mechanism is absent
  # (NO-GO); INCONCLUSIVE: it could not be determined or attached
  say "PRE $1 $2 $3"
  case $2 in FAIL) PRE_FAIL+=("$1") ;; INCONCLUSIVE) PRE_INC+=("$1") ;; esac
}
verdict() { # id class detail (required cases)
  say "CASE $1 $2 $3"
  case $2 in FAIL) REQ_FAIL+=("$1") ;; INCONCLUSIVE | NOT-RUN) REQ_INC+=("$1") ;; esac
}
obs() { say "OBS $1 $2"; }

# negative ID ADDRESS-FILE-NAME CONNECT-ARGS...: a host-bound socket, with
# no-profile controls before and after, refused under -a with EACCES and
# an audit line naming it.
negative() {
  local id=$1 sock=$2 cb ca n
  shift 2
  ns "$B/out/$id.cb" none python3 -I "$S" "$@"
  sleep 1
  ns "$B/out/$id.neg" "$P-a" python3 -I "$S" "$@"
  ns "$B/out/$id.ca" none python3 -I "$S" "$@"
  cb=$(res "$B/out/$id.cb")
  ca=$(res "$B/out/$id.ca")
  n=$(res "$B/out/$id.neg")
  if [ "$cb" != OK ] || [ "$ca" != OK ] || [ "$(lbl "$B/out/$id.cb")" != unconfined ] || [ "$(lbl "$B/out/$id.ca")" != unconfined ]; then
    verdict "$id" INCONCLUSIVE "control before=$cb after=$ca labels=$(lbl "$B/out/$id.cb")/$(lbl "$B/out/$id.ca")"
  elif [ "$(lbl "$B/out/$id.neg")" != "$P-a (enforce)" ]; then
    verdict "$id" INCONCLUSIVE "confined label=$(lbl "$B/out/$id.neg") result=$n"
  elif [ "$n" = OK ]; then
    verdict "$id" FAIL "a host-bound socket was reached under $P-a (enforce)"
  elif [ "$n" != EACCES ]; then
    verdict "$id" INCONCLUSIVE "errno=$n (control OK)"
  elif audit_has "$sock"; then
    verdict "$id" PASS "EACCES; audit: disconnected path, $sock; controls OK"
  else
    verdict "$id" INCONCLUSIVE "EACCES without an audit line for $sock"
  fi
}
# positive ID PROFILE OUT: label PROFILE (enforce) and OK required
positive() {
  local r
  r=$(res "$3")
  if [ "$(lbl "$3")" != "$2 (enforce)" ]; then
    verdict "$1" INCONCLUSIVE "label=$(lbl "$3") result=$r (the profile did not attach as expected)"
  elif [ "$r" = OK ]; then
    verdict "$1" PASS "OK under $2 (enforce)"
  elif [ "$r" = EACCES ]; then
    verdict "$1" FAIL "EACCES under $2 (enforce)"
  else
    verdict "$1" INCONCLUSIVE "result=$r"
  fi
}

cleanup() {
  [ "$CLEANED" = no ] || return 0
  CLEANED=yes
  local e p st a i name n left
  for e in "${PIDS[@]}"; do
    read -r p st a <<<"$e"
    if is_ours "$p" "$st" "$a"; then
      kill -TERM "$p" 2>/dev/null
    fi
  done
  for e in "${BGJOBS[@]}"; do wait "$e" 2>/dev/null; done
  sleep 1
  left=0
  for e in "${PIDS[@]}"; do
    read -r p st a <<<"$e"
    if is_ours "$p" "$st" "$a"; then
      kill -KILL "$p" 2>/dev/null
      sleep 0.2
      ! is_ours "$p" "$st" "$a" || { left=$((left + 1)); CLEAN_FAILS+=("listener:$p"); }
    fi
  done
  say "CLEANUP listeners started: ${#PIDS[@]}; still running: $left"
  for i in "${MOUNTS[@]}"; do
    if findmnt -rn --mountpoint "$i" >/dev/null 2>&1; then
      sudo -n timeout 10 umount "$i" 2>/dev/null || CLEAN_FAILS+=("umount:$i")
    fi
  done
  n=$(findmnt -rn -o TARGET 2>/dev/null | grep -c "^$B" || true)
  [ "$n" = 0 ] || CLEAN_FAILS+=("mounts:$n")
  say "CLEANUP mounts under the base directory: $n"
  for name in "${LOADED[@]}"; do
    n=$(tasks_with "$name")
    if [ "$n" = 0 ]; then
      printf '%s' "$name" | sudo -n timeout 10 tee /sys/kernel/security/apparmor/.remove >/dev/null 2>&1
    fi
    if [ "$n" = unknown ] || [ "$(profiles_with "$name")" != 0 ]; then
      CLEAN_FAILS+=("profile:$name")
      say "CLEANUP profile $name still loaded (tasks carrying it: $n)"
    fi
  done
  n=$(profiles_with "$P-[^ ]*")
  [ "$n" = 0 ] || CLEAN_FAILS+=("profiles-with-prefix:$n")
  say "CLEANUP profiles loaded: ${#LOADED[@]}; still loaded with this run's prefix: $n"
  chmod -R u+rwx "$B" 2>/dev/null
  if rm -rf -- "$B" && [ ! -e "$B" ]; then say "CLEANUP $B removed"; else CLEAN_FAILS+=("dir:$B"); say "CLEANUP FAILED to remove $B"; fi
  if [ "${#CLEAN_FAILS[@]}" -eq 0 ]; then say "CLEANUP OK"; else say "CLEANUP FAILED ${CLEAN_FAILS[*]}"; fi
}
on_exit() {
  local rc=$?
  cleanup
  if [ "$MODE" = main ] && [ "${DECIDED-no}" = no ]; then
    say "SPIKE-DECISION INCONCLUSIVE (ended early, status $rc)"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# --- abort self-test mode: set up, then wait to be terminated
if [ "$MODE" = abort ]; then
  load "$P-z" enforce && listen "$B/z.sock" stream && say "SELFTEST READY" >"$B/ready"
  i=0
  while [ "$i" -lt 120 ]; do sleep 1; i=$((i + 1)); done
  exit 0
fi

mkdir -m 0700 "$B/host" "$B/alias" "$B/late" "$B/odd" "$B/odd/x1" "$B/out" "$B/abort" || { setup_fail dirs; exit 2; }

# --- preconditions: what cannot be established statically is measured here
say "INFO kernel $(uname -r)"
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release | sed 's/^/INFO os /'
say "INFO parser $(apparmor_parser --version 2>&1 | head -n 1)"
dpkg-query -W apparmor apparmor-utils 2>&1 | sed 's/^/INFO package /'
for s in kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined; do
  say "INFO $s=$(sysctl -n "$s" 2>&1)"
done
sudo -n timeout 10 find /sys/kernel/security/apparmor/features -maxdepth 3 -path '*network*' 2>/dev/null | sort | sed 's/^/INFO feature /'
say "INFO own label $(cat /proc/self/attr/apparmor/current 2>&1)"
e=$(aa-enabled 2>&1)
case $e in
  Yes) pre PRE-enabled PASS "aa-enabled Yes" ;;
  No*) pre PRE-enabled FAIL "aa-enabled $e" ;;
  *) pre PRE-enabled INCONCLUSIVE "aa-enabled ${e:-no output}" ;;
esac
if m=$(sudo -n timeout 10 cat /sys/module/apparmor/parameters/mode 2>&1); then
  if [ "$m" = enforce ]; then pre PRE-mode PASS "global mode enforce"; else pre PRE-mode FAIL "global mode $m"; fi
else
  pre PRE-mode INCONCLUSIVE "global mode unreadable: $m"
fi
if command -v aa-exec >/dev/null; then pre PRE-aa-exec PASS "$(command -v aa-exec)"; else pre PRE-aa-exec INCONCLUSIVE missing; fi
f=/sys/kernel/security/apparmor/features
if ! sudo -n timeout 10 test -d "$f"; then
  pre PRE-unix-feature INCONCLUSIVE "the feature tree is unreadable"
elif sudo -n timeout 10 test -e "$f/network/af_unix"; then
  pre PRE-unix-feature PASS "network/af_unix (Ubuntu v7/v8 class, which the noble parser targets)"
elif sudo -n timeout 10 test -e "$f/network_v9/af_unix"; then
  pre PRE-unix-feature FAIL "only network_v9/af_unix: the noble parser cannot emit v9 rules"
else
  pre PRE-unix-feature FAIL "no af_unix mediation feature"
fi
say "INFO parser abi/4.0 sha256 $(sha256sum /etc/apparmor.d/abi/4.0 2>&1 | cut -c1-64)"
sed -n '/network/,/}/p' /etc/apparmor.d/abi/4.0 2>/dev/null | head -n 20 | sed 's/^/INFO abi\/4.0: /'
if load "$P-a" enforce; then pre PRE-load-a PASS "$P-a added"; else pre PRE-load-a INCONCLUSIVE "$P-a not loaded"; fi
if [ "${#PRE_FAIL[@]}" -eq 0 ] && [ "${#PRE_INC[@]}" -eq 0 ]; then
  ns "$B/out/PRE-attach" "$P-a" python3 -I "$S" label
  a=$(lbl "$B/out/PRE-attach")
  case $a in
    "$P-a (enforce)") pre PRE-attach PASS "label $a" ;;
    *"$P-a"*"//&"* | *"//&"*"$P-a"*) pre PRE-attach INCONCLUSIVE "stacked label $a (kernel.apparmor_restrict_unprivileged_unconfined?)" ;;
    *) pre PRE-attach INCONCLUSIVE "label ${a:-missing}" ;;
  esac
fi
load "$P-c" enforce,attach_disconnected
load "$P-m" complain
load "$P-x" enforce "capability setuid, capability setgid, capability setpcap,"
load "$P-r" enforce

if [ "${#PRE_FAIL[@]}" -eq 0 ] && [ "${#PRE_INC[@]}" -eq 0 ]; then
  # --- host-bound sockets (one listener per case, so each audit line names it)
  if listen "$B/host/s2.sock" stream; then negative S2-host-stream s2.sock connect "$B/host/s2.sock" stream
  else verdict S2-host-stream NOT-RUN setup; fi
  if listen "$B/odd/x1/s4.sock" stream && chmod 0311 "$B/odd/x1"; then
    negative S4-unlistable-dir s4.sock connect "$B/odd/x1/s4.sock" stream
  else verdict S4-unlistable-dir NOT-RUN setup; fi
  if listen "$B/host/s5.sock" stream && [ "$(realpath -e "$B/host")" = "$B/host" ] && [ "$(realpath -e "$B/alias")" = "$B/alias" ] &&
    sudo -n timeout 10 mount --bind "$B/host" "$B/alias"; then
    MOUNTS+=("$B/alias")
    negative S5-bind-alias s5.sock connect "$B/alias/s5.sock" stream
  else
    verdict S5-bind-alias NOT-RUN "setup"
  fi
  if listen "$B/host/s10.sock" dgram; then negative S10-dgram-connect s10.sock connect "$B/host/s10.sock" dgram
  else verdict S10-dgram-connect NOT-RUN setup; fi
  if listen "$B/host/s10u.sock" dgram; then negative S10u-dgram-sendto s10u.sock sendto "$B/host/s10u.sock"
  else verdict S10u-dgram-sendto NOT-RUN setup; fi

  # --- mechanism identification: the same profile with attach_disconnected allows it
  if listen "$B/host/s2c.sock" stream; then
    ns "$B/out/S2c" "$P-c" python3 -I "$S" connect "$B/host/s2c.sock" stream
    positive S2c-attach-disconnected "$P-c" "$B/out/S2c"
  else verdict S2c-attach-disconnected NOT-RUN setup; fi

  # --- a socket bound inside the namespace stays usable (T-05's shape)
  ns "$B/out/S3" "$P-a" sh -c 'python3 -I "$0" listen /tmp/p.sock stream 20 >/dev/null & i=0
    while [ ! -S /tmp/p.sock ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    python3 -I "$0" connect /tmp/p.sock stream' "$S"
  positive S3-inside-socket "$P-a" "$B/out/S3"

  # --- abstract: unreachable from a private network namespace (control: same netns)
  listen "@$P-abs" stream
  NET=0 ns "$B/out/S6.c" none python3 -I "$S" connect "@$P-abs" stream
  ns "$B/out/S6.n" none python3 -I "$S" connect "@$P-abs" stream
  NET=0 ns "$B/out/S6.ca" none python3 -I "$S" connect "@$P-abs" stream
  if [ "$(res "$B/out/S6.c")" != OK ] || [ "$(res "$B/out/S6.ca")" != OK ]; then
    verdict S6a-abstract INCONCLUSIVE "control before $(res "$B/out/S6.c") after $(res "$B/out/S6.ca")"
  elif [ "$(res "$B/out/S6.n")" = ECONNREFUSED ]; then verdict S6a-abstract PASS "ECONNREFUSED from a private netns; control OK"
  elif [ "$(res "$B/out/S6.n")" = OK ]; then verdict S6a-abstract FAIL "an abstract host socket was reached from a private netns"
  else verdict S6a-abstract INCONCLUSIVE "private netns result $(res "$B/out/S6.n")"; fi
  NET=0 ns "$B/out/S6b" "$P-a" python3 -I "$S" connect "@$P-abs" stream
  obs S6b-abstract-same-netns-profile "$(res "$B/out/S6b") (not guaranteed by the policy: unix, allows abstract peers)"

  # --- late: bound by the host after the confined process started
  late() { # id profile -> out file; $B/out/<id>.order is "after" when the
    # socket was bound only once the confined process had started
    rm -f "$B/late/s7.sock" "$B/late.flag" "$B/late.started"
    ns "$B/out/$1" "$2" sh -c ': >"$3"; i=0; while [ ! -e "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      python3 -I "$0" connect "$2" stream' "$S" "$B/late.flag" "$B/late/s7.sock" "$B/late.started" &
    local w=$! i=0
    BGJOBS+=("$w")
    while [ ! -e "$B/late.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    if [ -e "$B/late.started" ] && [ ! -e "$B/late/s7.sock" ]; then echo after >"$B/out/$1.order"; else echo unknown >"$B/out/$1.order"; fi
    listen "$B/late/s7.sock" stream && : >"$B/late.flag"
    wait "$w"
  }
  late S7.c none
  sleep 1
  late S7.n "$P-a"
  if [ "$(res "$B/out/S7.c")" != OK ] || [ "$(lbl "$B/out/S7.n")" != "$P-a (enforce)" ] || [ "$(cat "$B/out/S7.n.order")" != after ]; then
    verdict S7-late-socket INCONCLUSIVE "control $(res "$B/out/S7.c"), label $(lbl "$B/out/S7.n"), order $(cat "$B/out/S7.n.order")"
  elif [ "$(res "$B/out/S7.n")" = OK ]; then verdict S7-late-socket FAIL "reached under enforce"
  elif [ "$(res "$B/out/S7.n")" = EACCES ] && audit_has s7.sock; then verdict S7-late-socket PASS "EACCES; audited"
  else verdict S7-late-socket INCONCLUSIVE "result $(res "$B/out/S7.n") or no audit line"; fi

  # --- inherited and passed sockets: not guaranteed by the policy (delegation);
  # production relies on closing descriptors
  listen "$B/host/s8.sock" stream || true
  ns "$B/out/S8" none python3 -I "$S" holdexec "$B/host/s8.sock" -- aa-exec -p "$P-a" -- python3 -I "$S" usefd 5
  obs S8-inherited-connected "label $(lbl "$B/out/S8"); result $(res "$B/out/S8")"
  ns "$B/out/S9" none python3 -I "$S" scm "$B/host/s8.sock" -- aa-exec -p "$P-a" -- python3 -I "$S" recvfd 6
  obs S9-scm-rights "label $(lbl "$B/out/S9"); result $(res "$B/out/S9")"

  # --- exec inheritance and escapes (each with its no-profile control)
  ns "$B/out/S11e" "$P-a" sh -c 'exec sh -c "exec python3 -I \"\$0\" label" "$0"' "$S"
  case $(lbl "$B/out/S11e") in
    "$P-a (enforce)") verdict S11-exec-inherits PASS "grandchild label $P-a (enforce)" ;;
    unconfined) verdict S11-exec-inherits FAIL "the grandchild lost the profile" ;;
    *) verdict S11-exec-inherits INCONCLUSIVE "grandchild label $(lbl "$B/out/S11e")" ;;
  esac
  esc() { # id shell-command printing RESULT CHANGED|DENIED
    ns "$B/out/$1.c" none sh -c "python3 -I \"\$0\" label; $2" "$S"
    ns "$B/out/$1.n" "$P-a" sh -c "python3 -I \"\$0\" label; $2" "$S"
    if [ "$(res "$B/out/$1.c")" != CHANGED ] || [ "$(lbl "$B/out/$1.n")" != "$P-a (enforce)" ]; then
      verdict "$1" INCONCLUSIVE "control $(res "$B/out/$1.c"), label $(lbl "$B/out/$1.n")"
    elif [ "$(res "$B/out/$1.n")" = DENIED ]; then verdict "$1" PASS "denied under the profile (or by no_new_privs, as in production); control changed"
    elif [ "$(res "$B/out/$1.n")" = CHANGED ]; then verdict "$1" FAIL "changed under the profile"
    else verdict "$1" INCONCLUSIVE "result $(res "$B/out/$1.n")"; fi
  }
  esc S11-changeprofile 'printf "changeprofile unconfined" >/proc/self/attr/apparmor/current 2>/dev/null && echo "RESULT CHANGED" || echo "RESULT DENIED"'
  esc S11-aa-exec-unconfined 'aa-exec -p unconfined -- true 2>/dev/null && echo "RESULT CHANGED" || echo "RESULT DENIED"'
  ns "$B/out/S11u.c" none sh -c 'unshare -U true 2>/dev/null && echo "RESULT CREATED" || echo "RESULT DENIED"'
  ns "$B/out/S11u.n" "$P-a" sh -c 'unshare -U true 2>/dev/null && echo "RESULT CREATED" || echo "RESULT DENIED"'
  obs S11-userns "no profile $(res "$B/out/S11u.c"); profile $(res "$B/out/S11u.n") (a new namespace only makes host sockets more disconnected)"
  # shellcheck disable=SC2024 # this user, not root, writes the output file
  sudo -n timeout -s KILL 20 unshare --net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
    /bin/sh -c 'printf "exec %s" "$1" >/proc/self/attr/apparmor/exec || exit 98; shift; exec "$@"' spike-init "$P-x" \
    setpriv --reuid "$U" --regid "$G" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
    python3 -I "$S" connect "$B/host/s2.sock" stream >"$B/out/S11b" 2>&1
  obs S11b-order-B "label $(lbl "$B/out/S11b"); result $(res "$B/out/S11b") (used only if order A fails)"

  # --- refusal when the profile is unavailable; complain mode is visible
  ns "$B/out/S12" none sh -c 'aa-exec -p "$1" -- python3 -I "$0" label; echo "RC $?"' "$S" "$P-missing"
  if ! grep -q '^LABEL ' "$B/out/S12" && grep -q '^RC [1-9]' "$B/out/S12"; then
    verdict S12-missing-profile PASS "aa-exec refused; the command did not start"
  elif grep -q '^LABEL ' "$B/out/S12"; then verdict S12-missing-profile FAIL "the command started"
  else verdict S12-missing-profile INCONCLUSIVE "$(tr '\n' ' ' <"$B/out/S12")"; fi
  ns "$B/out/S12m" "$P-m" python3 -I "$S" label
  case $(lbl "$B/out/S12m") in
    "$P-m (complain)") verdict S12-complain-visible PASS "label shows (complain)" ;;
    "$P-m ("*) verdict S12-complain-visible FAIL "label $(lbl "$B/out/S12m") hides complain mode" ;;
    *) verdict S12-complain-visible INCONCLUSIVE "label $(lbl "$B/out/S12m") (profile not attached)" ;;
  esac

  # --- the hazard of removing a profile a task still carries (test-owned task only)
  listen "$B/host/s14.sock" stream || true
  rm -f "$B/rm.flag"
  ns "$B/out/S14b" "$P-r" sh -c 'python3 -I "$0" label; i=0; while [ ! -e "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    python3 -I "$0" connect "$2" stream' "$S" "$B/rm.flag" "$B/host/s14.sock" &
  w=$!
  BGJOBS+=("$w")
  sleep 2
  case " ${LOADED[*]} " in *" $P-r "*) printf '%s' "$P-r" | sudo -n timeout 10 tee /sys/kernel/security/apparmor/.remove >/dev/null 2>&1 ;; esac
  : >"$B/rm.flag"
  wait "$w"
  obs S14b-removal-unconfines "labels: $(sed -n 's/^LABEL //p' "$B/out/S14b" | tr '\n' '|'); result $(res "$B/out/S14b")"

  # --- cleanup after an abnormal end: a child run is terminated after setup
  bash "$0" --abort-selftest "$B/abort" "$P-q" >"$B/out/S15" 2>&1 &
  w=$!
  for i in $(seq 100); do [ -e "$B/abort/ready" ] && break; sleep 0.1; done
  if [ -e "$B/abort/ready" ]; then
    kill -TERM "$w"
    wait "$w"
    zp=$(profiles_with "$P-q-z")
    pgrep -f -- "$S listen $B/abort/z.sock " >/dev/null
    zl=$?
    if [ ! -e "$B/abort" ] && [ "$zp" = 0 ] && [ "$zl" = 1 ] && grep -q '^CLEANUP OK' "$B/out/S15"; then
      verdict S15-cleanup-after-term PASS "directory, listener and profile gone after SIGTERM"
    elif [ -e "$B/abort" ] || [ "$zl" = 0 ] || { [ "$zp" != 0 ] && [ "$zp" != unknown ]; }; then
      verdict S15-cleanup-after-term FAIL "left: dir $([ -e "$B/abort" ] && echo yes || echo no), listener rc $zl, profile $zp; $(grep '^CLEANUP' "$B/out/S15" | tr '\n' ' ')"
    else
      verdict S15-cleanup-after-term INCONCLUSIVE "profile count $zp, pgrep rc $zl; $(grep '^CLEANUP' "$B/out/S15" | tr '\n' ' ')"
    fi
  else
    kill -TERM "$w" 2>/dev/null
    wait "$w"
    verdict S15-cleanup-after-term INCONCLUSIVE "self-test setup: $(tr '\n' ' ' <"$B/out/S15" | cut -c1-300)"
  fi

  # --- cost (recorded, not gating)
  t0=$(date +%s%N)
  load "$P-t" enforce
  obs S13-profile-load "$((($(date +%s%N) - t0) / 1000000)) ms"
  t0=$(date +%s%N); ns "$B/out/S13n" none python3 -I "$S" label; t1=$(date +%s%N)
  ns "$B/out/S13a" "$P-a" python3 -I "$S" label; t2=$(date +%s%N)
  obs S13-start "no profile $(((t1 - t0) / 1000000)) ms; profile $(((t2 - t1) / 1000000)) ms"
else
  say "INFO preconditions not met (${PRE_FAIL[*]-} ${PRE_INC[*]-}): cases NOT-RUN"
fi

{ sudo -n timeout 10 dmesg 2>/dev/null; } | grep -F "$P" | tail -n 60 | sed 's/^/INFO audit /'
trap - EXIT
cleanup
DECIDED=yes
if [ "${#PRE_FAIL[@]}" -gt 0 ]; then
  say "SPIKE-DECISION NO-GO (precondition: ${PRE_FAIL[*]}; undetermined: ${PRE_INC[*]-none})"
  exit 1
elif [ "${#PRE_INC[@]}" -gt 0 ]; then
  say "SPIKE-DECISION INCONCLUSIVE (precondition: ${PRE_INC[*]}; setup: ${SETUP_FAILS[*]-none})"
  exit 1
elif [ "${#REQ_FAIL[@]}" -gt 0 ]; then
  say "SPIKE-DECISION NO-GO (failed: ${REQ_FAIL[*]}; inconclusive: ${REQ_INC[*]-none})"
  exit 1
elif [ "${#REQ_INC[@]}" -gt 0 ] || [ "${#SETUP_FAILS[@]}" -gt 0 ] || [ "${#CLEAN_FAILS[@]}" -gt 0 ]; then
  say "SPIKE-DECISION INCONCLUSIVE (inconclusive: ${REQ_INC[*]-none}; setup: ${SETUP_FAILS[*]-none}; cleanup: ${CLEAN_FAILS[*]-none})"
  exit 1
fi
say "SPIKE-DECISION GO"
