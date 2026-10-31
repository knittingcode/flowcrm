#!/usr/bin/env bash
# FCRM-SEC-025 controlled AppArmor spike, revision 4 (frozen package; run only
# under an explicit owner authorization). GitHub-hosted ubuntu-24.04 runner only.
#
# Question: does an AppArmor profile without attach_disconnected, applied with
# aa-exec to an unprivileged process in new mount/pid/net/ipc namespaces,
# refuse (EACCES) every connect to a pathname Unix socket bound by a host
# process, while sockets bound inside stay usable?
#
# Revision 4 changes only evidence collection: confined processes write to
# pipes and read /dev/null opened inside their namespace; a netlink audit
# multicast reader (root only to bind, then this user) is the primary audit
# source; the cases are collected first and evaluated by evaluate.py after the
# reader has stopped; every step is bounded by a time budget.
#
# Safety: no container engine command and no socket but this script's own
# listeners; every path under $RUNNER_TEMP/fcrm-spike-<run>-<attempt>;
# profiles named fcrm-spike-<16 random hex>-<suffix>, added (-a, never
# replaced), removed only when no task carries them (S14b removes its own on
# purpose); listeners and the reader signalled only after their identity
# matches; one bind mount, inside the base directory, unmounted in cleanup.
#
# Output: PRE/CASE/OBS lines "<kind> <id> <PASS|FAIL|INCONCLUSIVE|NOT-RUN|value>
# <detail>", CLEANUP lines, and last SPIKE-DECISION GO | NO-GO | INCONCLUSIVE.
set -u
export LC_ALL=C
unset NET DECIDED AUD AUD_PID
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  printf '%s\n' "SPIKE-DECISION INCONCLUSIVE (setup: bash 5 required)"
  exit 2
fi

here=$(cd -P "$(dirname "$0")" && pwd -P)
S=$here/sock.py
E=$here/evaluate.py
PY=/usr/bin/python3
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
LEDGER=()     # "PRE|CASE <id> <class>", written only by pre() and verdict()
SPEC=()       # deferred cases for evaluate.py
CLEANED=no
MODE=main
READER=none   # none | started | stopped
AUD_CLOSED=yes
aud_pid=
aud_st=
rd_pid=
rd_st=
EF=

# Time budget (seconds since start): an item may start only if
# now + its bound + TAIL <= LIMIT; the step allows 480 s.
TAIL=150
LIMIT=450
BOUND_LOAD=20
BOUND_ATTACH=25
BOUND_NEG=95
BOUND_NEG_MOUNT=100
BOUND_LATE=90
BOUND_S2C=30
BOUND_S3=25
BOUND_S6A=80
BOUND_S11E=25
BOUND_ESC=50
BOUND_S12=25
BOUND_S15=60
BOUND_S6B=25
BOUND_S8=30
BOUND_S9=25
BOUND_S11U=50
BOUND_S11B=25
BOUND_S14B=40
BOUND_S17=30
BOUND_S13=70

say() { printf '%s\n' "$*"; }
clean() { LC_ALL=C tr -d '\n' | LC_ALL=C tr -c '[:print:]' '?' | cut -c1-300; }
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
case $B in /* ) ;; *) say "SPIKE-DECISION INCONCLUSIVE (setup: base directory $B)"; exit 2 ;; esac
case $B in *[!A-Za-z0-9_./-]*) say "SPIKE-DECISION INCONCLUSIVE (setup: unexpected character in $B)"; exit 2 ;; esac
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
SECONDS=0
if [ "$MODE" = main ]; then
  EF=$(mktemp "$rt/fcrm-spike-eval-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.XXXXXX") &&
    [ -f "$EF" ] && [ ! -L "$EF" ] && [ "$(stat -c %u "$EF")" = "$U" ] ||
    { rmdir -- "$B" 2>/dev/null; say "SPIKE-DECISION INCONCLUSIVE (setup: evaluator error file)"; exit 2; }
fi

pstat() { # pid -> "state starttime" from /proc/<pid>/stat, empty if gone
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
  s=${s##*) }
  # shellcheck disable=SC2086 # split the fields on purpose
  set -- $s
  printf '%s %s' "${1-}" "${20-}"
}
starttime() { local s; s=$(pstat "$1"); printf '%s' "${s#* }"; }
is_live() { # pid starttime: the same process, not a zombie
  local s
  [ -n "$1" ] && [ -n "$2" ] || return 1
  s=$(pstat "$1")
  [ -n "$s" ] && [ "${s#* }" = "$2" ] && [ "${s%% *}" != Z ]
}
is_ours() { # pid starttime address: the same listener process of this run
  is_live "$1" "$2" &&
    tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -qF -- "$S listen $3 "
}
listen() { # address stream|dgram -> background listener of this user
  local f p st i
  f=$B/ready.$RANDOM$RANDOM
  "$PY" -I "$S" listen "$1" "$2" 270 >"$f" 2>&1 &
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
  l=$(sudo -n timeout 5 cat /sys/kernel/security/apparmor/profiles 2>/dev/null) || { printf unknown; return; }
  printf '%s\n' "$l" | grep -c "^$1 " || true
}
profile_text() { # name flags capability-rule
  printf 'abi <abi/4.0>,\nprofile %s flags=(%s) {\n  file,\n  unix,\n  network,\n  deny network vsock,\n  signal,\n  ptrace (read, readby, trace, tracedby) peer=%s,\n  %s\n  deny mount,\n  deny umount,\n  deny pivot_root,\n}\n' \
    "$1" "$2" "$1" "${3:-deny capability,}"
}
load() { # name flags [capability-rule]
  local t
  case $1 in "$P"-[a-z0-9]*) ;; *) setup_fail "name:$1"; return 1 ;; esac
  if [ "$MODE" = main ] && ! fits "$SECONDS" "$BOUND_LOAD" "$TAIL" "$LIMIT"; then setup_fail "deadline:load:$1"; return 1; fi
  if [ "$(profiles_with "$1")" != 0 ]; then setup_fail "exists:$1"; return 1; fi
  t=$(profile_text "$@")
  printf '%s\n' "$t" | sed "s/^/INFO profile $1: /"
  if printf '%s\n' "$t" | sudo -n timeout 15 apparmor_parser -a -K -q; then
    LOADED+=("$1")
    return 0
  fi
  setup_fail "load:$1"
  return 1
}
# ns OUT PROFILE|none CMD...: CMD in new mount/pid/ipc (and net unless NET=0)
# namespaces as this user, without groups or capabilities, no_new_privs, a
# private /tmp, stdin /dev/null opened inside the namespace; under PROFILE
# through aa-exec. stdout and stderr go through a pipe to OUT (64 KiB, 25 s).
ns() {
  local o=$1 p=$2 net=--net wrap=()
  shift 2
  [ "${NET-1}" = 1 ] || net=
  [ "$p" = none ] || wrap=(aa-exec -p "$p" --)
  # shellcheck disable=SC2086 # $net is one flag or nothing
  sudo -n timeout -s KILL 20 unshare $net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
    /bin/sh -c 'mount -t tmpfs -o mode=1777,nosuid,nodev spike /tmp || exit 99; exec </dev/null || exit 97; exec "$@"' spike-init \
    setpriv --reuid "$U" --regid "$G" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
    "${wrap[@]}" "$@" 2>&1 | timeout -s KILL 25 head -c 65536 >"$o"
}
lbl() { sed -n 's/^LABEL //p' "$1" 2>/dev/null | tail -n 1; }
res() { local r; r=$(sed -n 's/^RESULT //p' "$1" 2>/dev/null | tail -n 1); printf '%s' "${r:-missing}"; }
pre() { # id PASS|FAIL|INCONCLUSIVE detail. FAIL: the mechanism is absent
  # (NO-GO); INCONCLUSIVE: it could not be determined or attached
  say "PRE $1 $2 $3"
  LEDGER+=("PRE $1 $2")
  case $2 in FAIL) PRE_FAIL+=("$1") ;; INCONCLUSIVE) PRE_INC+=("$1") ;; esac
}
verdict() { # id class detail (gating cases)
  say "CASE $1 $2 $3"
  LEDGER+=("CASE $1 $2")
  case $2 in FAIL) REQ_FAIL+=("$1") ;; INCONCLUSIVE | NOT-RUN) REQ_INC+=("$1") ;; esac
}
obs() { say "OBS $1 $2"; }

# >>> fits
fits() { # NOW BOUND TAIL LIMIT: may an item of BOUND seconds start at NOW?
  [ "$(($1 + $2 + $3))" -le "$4" ]
}
# <<< fits
due() { # id bound: a gating case may start, else NOT-RUN deadline
  fits "$SECONDS" "$2" "$TAIL" "$LIMIT" && return 0
  verdict "$1" NOT-RUN "deadline"
  return 1
}
due_obs() { # id bound: an observation may start
  fits "$SECONDS" "$2" "$TAIL" "$LIMIT" && return 0
  obs "$1" "not-run deadline"
  return 1
}

# >>> accept
accept() { # RC OUT ERRFILE ALLOWED...: OUT if it is one well-formed line
  local rc=$1 out=$2 ef=$3 c a nl='
'
  shift 3
  if [ "$rc" != 0 ]; then printf '%s\n' "INCONCLUSIVE evaluator failed (rc=$rc)"; return 0; fi
  if [ -s "$ef" ]; then printf '%s\n' "INCONCLUSIVE evaluator failed (stderr)"; return 0; fi
  case $out in "" | *"$nl"*) printf '%s\n' "INCONCLUSIVE evaluator failed (lines)"; return 0 ;; esac
  c=${out%% *}
  for a in "$@"; do
    if [ "$c" = "$a" ]; then printf '%s\n' "$out"; return 0; fi
  done
  printf '%s\n' "INCONCLUSIVE evaluator failed (class)"
}
accept_batch() { # RC ERRFILE IDS OUT: one "<id> <class> <detail>" per id in IDS
  local rc=$1 ef=$2 ids=$3 out=$4 why="" got=() line id i=0 c rest
  if [ "$rc" != 0 ]; then why="rc=$rc"; elif [ -s "$ef" ]; then why=stderr; fi
  if [ -z "$why" ]; then
    while IFS= read -r line; do got+=("$line"); done <<<"$out"
    for id in $ids; do
      line=${got[$i]-}
      c=${line#"$id "}
      rest=${c#* }
      c=${c%% *}
      if [ "${line%% *}" != "$id" ] || [ "$rest" = "$c" ]; then why="line $i"; break; fi
      case $c in PASS | FAIL | INCONCLUSIVE) ;; *) why="class $i"; break ;; esac
      i=$((i + 1))
    done
    [ -n "$why" ] || [ "${#got[@]}" = "$i" ] || why="count ${#got[@]}"
  fi
  for id in $ids; do
    if [ -n "$why" ]; then printf '%s\n' "$id INCONCLUSIVE evaluator failed ($why)"; fi
  done
  if [ -z "$why" ]; then printf '%s\n' "$out"; fi
}
# <<< accept

# --- the audit reader (main mode only)
reader_ident_ok() { # the reader process, dropped to this user, exact argv
  local l uid gid cap want
  is_live "$rd_pid" "$rd_st" || return 1
  uid=$(sed -n 's/^Uid:[[:space:]]*//p' "/proc/$rd_pid/status" 2>/dev/null)
  gid=$(sed -n 's/^Gid:[[:space:]]*//p' "/proc/$rd_pid/status" 2>/dev/null)
  cap=$(sed -n 's/^CapEff:[[:space:]]*//p' "/proc/$rd_pid/status" 2>/dev/null)
  [ "$(printf '%s' "$uid" | tr -s '[:space:]' ' ')" = "$U $U $U $U" ] || return 1
  [ "$(printf '%s' "$gid" | tr -s '[:space:]' ' ')" = "$G $G $G $G" ] || return 1
  [ "$cap" = 0000000000000000 ] || return 1
  l=$(tr '\0' '\n' <"/proc/$rd_pid/cmdline" 2>/dev/null)
  want=$(printf '%s\n' "$PY" -I "$S" auditread 540 "$U" "$G")
  [ "$l" = "$want" ]
}
reader_alive() { is_live "$aud_pid" "$aud_st" || is_live "$rd_pid" "$rd_st"; }
reader_stop() { # idempotent: EOF, bounded wait, one identity-checked TERM
  local w i
  [ "$READER" = started ] || return 0
  READER=stopped
  if [ "$AUD_CLOSED" = no ]; then
    AUD_CLOSED=yes
    w=${AUD[1]-}
    case $w in "" | *[!0-9]*) ;; *) exec {w}>&- ;; esac
  fi
  for i in $(seq 50); do reader_alive || break; sleep 0.1; done
  if reader_alive && reader_ident_ok; then
    kill -TERM "$rd_pid" 2>/dev/null
    for i in $(seq 20); do reader_alive || break; sleep 0.1; done
  fi
  if [ -n "$aud_pid" ] && ! reader_alive; then wait "$aud_pid" 2>/dev/null; fi
  pgrep -f -- "$S auditread " >/dev/null
  [ "$?" = 1 ] || CLEAN_FAILS+=("auditreader")
}
children_scan() { # sets CHILD_N and CHILD_LIST: live children of this shell
  local f l rest st pp
  CHILD_N=0
  CHILD_LIST=
  for f in /proc/[0-9]*/stat; do
    { read -r l <"$f"; } 2>/dev/null || continue
    rest=${l##*) }
    st=${rest%% *}
    rest=${rest#* }
    pp=${rest%% *}
    if [ "$pp" = "$$" ] && [ "$st" != Z ]; then
      CHILD_N=$((CHILD_N + 1))
      f=${f#/proc/}
      CHILD_LIST="$CHILD_LIST ${f%/stat}"
    fi
  done
}

cleanup() {
  [ "$CLEANED" = no ] || return 0
  CLEANED=yes
  local e p st a i name n left labels list gone=() alive=()
  for e in "${PIDS[@]}"; do
    read -r p st a <<<"$e"
    if is_ours "$p" "$st" "$a"; then kill -TERM "$p" 2>/dev/null; fi
  done
  for e in "${BGJOBS[@]}"; do wait "$e" 2>/dev/null; done
  sleep 1
  for e in "${PIDS[@]}"; do
    read -r p st a <<<"$e"
    if is_ours "$p" "$st" "$a"; then kill -KILL "$p" 2>/dev/null; fi
  done
  # signals need the full identity (is_ours); a listener still counts as
  # running while its pid and start time live (is_live), and only a gone one
  # is reaped
  for i in $(seq 20); do
    alive=()
    for e in "${PIDS[@]}"; do
      read -r p st a <<<"$e"
      ! is_live "$p" "$st" || alive+=("$p")
    done
    [ "${#alive[@]}" = 0 ] && break
    sleep 0.1
  done
  for e in "${PIDS[@]}"; do
    read -r p st a <<<"$e"
    if ! is_live "$p" "$st"; then gone+=("$p"); wait "$p" 2>/dev/null; fi
  done
  left=${#alive[@]}
  for p in "${alive[@]}"; do CLEAN_FAILS+=("listener:$p"); done
  say "CLEANUP listeners started: ${#PIDS[@]}; still running: $left"
  reader_stop
  for i in "${MOUNTS[@]}"; do
    if findmnt -rn --mountpoint "$i" >/dev/null 2>&1; then
      sudo -n timeout 5 umount "$i" 2>/dev/null || CLEAN_FAILS+=("umount:$i")
    fi
  done
  n=$(findmnt -rn -o TARGET 2>/dev/null | grep -c "^$B" || true)
  [ "$n" = 0 ] || CLEAN_FAILS+=("mounts:$n")
  say "CLEANUP mounts under the base directory: $n"
  labels=$(sudo -n timeout 5 sh -c 'cat /proc/[0-9]*/task/[0-9]*/attr/apparmor/current 2>/dev/null; true') || labels=unknown
  for name in "${LOADED[@]}"; do
    if [ "$labels" = unknown ]; then n=unknown
    else n=$(printf '%s\n' "$labels" | grep -cE "(^|//&)$name( |//)" || true); fi
    if [ "$n" = 0 ]; then
      printf '%s' "$name" | sudo -n timeout 5 tee /sys/kernel/security/apparmor/.remove >/dev/null 2>&1
    else
      say "CLEANUP profile $name not removed (tasks carrying it: $n)"
    fi
  done
  list=$(sudo -n timeout 5 cat /sys/kernel/security/apparmor/profiles 2>/dev/null) || list=unknown
  if [ "$list" = unknown ]; then n=unknown
  else n=$(printf '%s\n' "$list" | grep -c "^$P-[^ ]* " || true); fi
  [ "$n" = 0 ] || CLEAN_FAILS+=("profiles-with-prefix:$n")
  say "CLEANUP profiles loaded: ${#LOADED[@]}; still loaded with this run's prefix: $n"
  children_scan
  [ "$CHILD_N" = 0 ] || { CLEAN_FAILS+=("children:$CHILD_N"); say "CLEANUP children still running:$CHILD_LIST"; }
  chmod -R u+rwx "$B" 2>/dev/null
  if rm -rf -- "$B" && [ ! -e "$B" ]; then say "CLEANUP $B removed"; else CLEAN_FAILS+=("dir:$B"); say "CLEANUP FAILED to remove $B"; fi
  if [ "${#CLEAN_FAILS[@]}" -eq 0 ]; then say "CLEANUP OK"; else say "CLEANUP FAILED ${CLEAN_FAILS[*]}"; fi
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
  local rc=$?
  cleanup
  [ -z "$EF" ] || rm -f -- "$EF"
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

mkdir -m 0700 "$B/host" "$B/alias" "$B/late" "$B/odd" "$B/odd/x1" "$B/out" "$B/abort" "$B/src" || { setup_fail dirs; exit 2; }

# --- preconditions and environment: what cannot be established statically is measured here
say "INFO kernel $(uname -r)"
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release | sed 's/^/INFO os /'
say "INFO parser $(timeout 5 apparmor_parser --version 2>&1 | head -n 1)"
say "INFO python $("$PY" -I -c 'import sys; print(sys.version.split()[0])' 2>&1)"
timeout 5 dpkg-query -W apparmor apparmor-utils 2>&1 | sed 's/^/INFO package /'
for s in kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined kernel.printk_ratelimit kernel.printk_ratelimit_burst; do
  say "INFO $s=$(timeout 5 sysctl -n "$s" 2>&1)"
done
say "INFO cmdline $(grep -oE '(^| )(audit|audit_backlog_limit|apparmor|lsm)=[^ ]*' /proc/cmdline | tr -d '\n' | clean)"
say "INFO journald-audit.socket $(timeout 5 systemctl is-active systemd-journald-audit.socket 2>&1 | clean)"
sudo -n timeout 5 dmesg 2>/dev/null | grep -E 'audit: (initializing|state=)|type=2000' | head -n 5 | clean | sed 's/^/INFO audit env /'
sudo -n timeout 5 find /sys/kernel/security/apparmor/features -maxdepth 3 -path '*network*' 2>/dev/null | sort | sed 's/^/INFO feature /'
say "INFO own label $(cat /proc/self/attr/apparmor/current 2>&1)"
e=$(timeout 5 aa-enabled 2>&1)
case $e in
  Yes) pre PRE-enabled PASS "aa-enabled Yes" ;;
  No*) pre PRE-enabled FAIL "aa-enabled $e" ;;
  *) pre PRE-enabled INCONCLUSIVE "aa-enabled ${e:-no output}" ;;
esac
if m=$(sudo -n timeout 5 cat /sys/module/apparmor/parameters/mode 2>&1); then
  if [ "$m" = enforce ]; then pre PRE-mode PASS "global mode enforce"; else pre PRE-mode FAIL "global mode $m"; fi
else
  pre PRE-mode INCONCLUSIVE "global mode unreadable: $m"
fi
if command -v aa-exec >/dev/null; then pre PRE-aa-exec PASS "$(command -v aa-exec)"; else pre PRE-aa-exec INCONCLUSIVE missing; fi
f=/sys/kernel/security/apparmor/features
if ! sudo -n timeout 5 test -d "$f"; then
  pre PRE-unix-feature INCONCLUSIVE "the feature tree is unreadable"
elif sudo -n timeout 5 test -e "$f/network/af_unix"; then
  pre PRE-unix-feature PASS "network/af_unix (Ubuntu v7/v8 class, which the noble parser targets)"
elif sudo -n timeout 5 test -e "$f/network_v9/af_unix"; then
  pre PRE-unix-feature FAIL "only network_v9/af_unix: the noble parser cannot emit v9 rules"
else
  pre PRE-unix-feature FAIL "no af_unix mediation feature"
fi
say "INFO parser abi/4.0 sha256 $(sha256sum /etc/apparmor.d/abi/4.0 2>&1 | cut -c1-64)"
sed -n '/network/,/}/p' /etc/apparmor.d/abi/4.0 2>/dev/null | head -n 20 | sed 's/^/INFO abi\/4.0: /'

# --- the audit reader: started before the first profile load
coproc AUD { sudo -n timeout -s KILL 560 "$PY" -I "$S" auditread 540 "$U" "$G" 2>&1 | timeout -s KILL 570 head -c 8388608 >"$B/audit.nl"; }
aud_pid=${AUD_PID-}
aud_st=$(starttime "$aud_pid")
READER=started
AUD_CLOSED=no
r=${AUD[0]-}
case $r in "" | *[!0-9]*) ;; *) exec {r}<&- ;; esac
w=${AUD[1]-}
case $w in "" | *[!0-9]*) say "INFO coproc write fd missing" ;;
  *) say "INFO coproc write fd flags $(sed -n 's/^flags:[[:space:]]*//p' "/proc/$$/fdinfo/$w" 2>&1 | clean)" ;; esac
for i in $(seq 50); do
  grep -qE '^AUDITREAD (READY|BINDFAIL|DROPFAIL)' "$B/audit.nl" 2>/dev/null && break
  sleep 0.1
done
rl=$(grep -m 1 -E '^AUDITREAD (READY|BINDFAIL|DROPFAIL)' "$B/audit.nl" 2>/dev/null | clean)
case $rl in
  "AUDITREAD READY pid="*)
    rd_pid=${rl#AUDITREAD READY pid=}
    rd_pid=${rd_pid%% *}
    case $rd_pid in "" | *[!0-9]*) rd_pid= ;; *) rd_st=$(starttime "$rd_pid") ;; esac ;;
esac
say "INFO audit reader: ${rl:-not ready}"

if load "$P-a" enforce; then pre PRE-load-a PASS "$P-a added"; else pre PRE-load-a INCONCLUSIVE "$P-a not loaded"; fi
if [ "${#PRE_FAIL[@]}" -eq 0 ] && [ "${#PRE_INC[@]}" -eq 0 ]; then
  if fits "$SECONDS" "$BOUND_ATTACH" "$TAIL" "$LIMIT"; then
    ns "$B/out/PRE-attach" "$P-a" "$PY" -I "$S" label
    a=$(lbl "$B/out/PRE-attach")
    case $a in
      "$P-a (enforce)") pre PRE-attach PASS "label $a" ;;
      *"$P-a"*"//&"* | *"//&"*"$P-a"*) pre PRE-attach INCONCLUSIVE "stacked label $(printf '%s' "$a" | clean) (kernel.apparmor_restrict_unprivileged_unconfined?)" ;;
      *) pre PRE-attach INCONCLUSIVE "label $(printf '%s' "${a:-missing}" | clean)" ;;
    esac
  else
    pre PRE-attach INCONCLUSIVE "deadline"
  fi
fi
load "$P-c" enforce,attach_disconnected
load "$P-m" complain
load "$P-x" enforce "capability setuid, capability setgid, capability setpcap,"
load "$P-r" enforce

# negative_collect ID CONNECT-ARGS...: no-profile control, 7 s, the confined
# attempt (its time window in ID.t), the control after; evaluated later.
negative_collect() {
  local id=$1
  shift
  ns "$B/out/$id.cb" none "$PY" -I "$S" "$@"
  sleep 1
  sleep 6
  date +%s.%N >"$B/out/$id.t"
  ns "$B/out/$id.neg" "$P-a" "$PY" -I "$S" "$@"
  date +%s.%N >>"$B/out/$id.t"
  ns "$B/out/$id.ca" none "$PY" -I "$S" "$@"
}

if [ "${#PRE_FAIL[@]}" -eq 0 ] && [ "${#PRE_INC[@]}" -eq 0 ]; then
  # === COLLECT: gating cases first (one listener per case, so each record names it)
  if due S2-host-stream "$BOUND_NEG"; then
    if listen "$B/host/s2.sock" stream; then
      negative_collect S2-host-stream connect "$B/host/s2.sock" stream
      SPEC+=("negative S2-host-stream stream connect $B/host/s2.sock $B/out/S2-host-stream")
    else verdict S2-host-stream NOT-RUN setup; fi
  fi
  if due S4-unlistable-dir "$BOUND_NEG"; then
    if listen "$B/odd/x1/s4.sock" stream && chmod 0311 "$B/odd/x1"; then
      negative_collect S4-unlistable-dir connect "$B/odd/x1/s4.sock" stream
      SPEC+=("negative S4-unlistable-dir stream connect $B/odd/x1/s4.sock $B/out/S4-unlistable-dir")
    else verdict S4-unlistable-dir NOT-RUN setup; fi
  fi
  if due S5-bind-alias "$BOUND_NEG_MOUNT"; then
    if listen "$B/host/s5.sock" stream && [ "$(realpath -e "$B/host")" = "$B/host" ] && [ "$(realpath -e "$B/alias")" = "$B/alias" ] &&
      sudo -n timeout 5 mount --bind "$B/host" "$B/alias"; then
      MOUNTS+=("$B/alias")
      # the record names the bound path host/s5.sock (unix_sk(peer)->path)
      negative_collect S5-bind-alias connect "$B/alias/s5.sock" stream
      SPEC+=("negative S5-bind-alias stream connect $B/host/s5.sock $B/out/S5-bind-alias")
    else verdict S5-bind-alias NOT-RUN setup; fi
  fi
  if due S10-dgram-connect "$BOUND_NEG"; then
    if listen "$B/host/s10.sock" dgram; then
      negative_collect S10-dgram-connect connect "$B/host/s10.sock" dgram
      SPEC+=("negative S10-dgram-connect dgram connect $B/host/s10.sock $B/out/S10-dgram-connect")
    else verdict S10-dgram-connect NOT-RUN setup; fi
  fi
  if due S10u-dgram-sendto "$BOUND_NEG"; then
    if listen "$B/host/s10u.sock" dgram; then
      negative_collect S10u-dgram-sendto sendto "$B/host/s10u.sock"
      SPEC+=("negative S10u-dgram-sendto dgram sendto $B/host/s10u.sock $B/out/S10u-dgram-sendto")
    else verdict S10u-dgram-sendto NOT-RUN setup; fi
  fi

  # --- mechanism identification: the same profile with attach_disconnected allows it
  if due S2c-attach-disconnected "$BOUND_S2C"; then
    if listen "$B/host/s2c.sock" stream; then
      ns "$B/out/S2c" "$P-c" "$PY" -I "$S" connect "$B/host/s2c.sock" stream
      SPEC+=("positive S2c-attach-disconnected $P-c $B/out/S2c")
    else verdict S2c-attach-disconnected NOT-RUN setup; fi
  fi

  # --- a socket bound inside the namespace stays usable (T-05's shape)
  if due S3-inside-socket "$BOUND_S3"; then
    ns "$B/out/S3" "$P-a" sh -c '"$1" -I "$0" listen /tmp/p.sock stream 20 >/dev/null & i=0
      while [ ! -S /tmp/p.sock ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
      "$1" -I "$0" connect /tmp/p.sock stream' "$S" "$PY"
    SPEC+=("positive S3-inside-socket $P-a $B/out/S3")
  fi

  # --- abstract: unreachable from a private network namespace (control: same netns)
  ABS=no
  if due S6a-abstract "$BOUND_S6A"; then
    if listen "@$P-abs" stream; then
      ABS=yes
      NET=0 ns "$B/out/S6.c" none "$PY" -I "$S" connect "@$P-abs" stream
      ns "$B/out/S6.n" none "$PY" -I "$S" connect "@$P-abs" stream
      NET=0 ns "$B/out/S6.ca" none "$PY" -I "$S" connect "@$P-abs" stream
      SPEC+=("abstract S6a-abstract $B/out/S6")
    else verdict S6a-abstract NOT-RUN setup; fi
  fi

  # --- late: bound by the host after the confined process started
  late() { # out-prefix profile -> $1 (output), $1.order ("after" when the
    # socket was bound only once the confined process had started), $1.t
    rm -f "$B/late/s7.sock" "$B/late.flag" "$B/late.started"
    date +%s.%N >"$1.t"
    ns "$1" "$2" sh -c ': >"$3"; i=0; while [ ! -e "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      "$4" -I "$0" connect "$2" stream' "$S" "$B/late.flag" "$B/late/s7.sock" "$B/late.started" "$PY" &
    local w=$! i=0
    BGJOBS+=("$w")
    while [ ! -e "$B/late.started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    if [ -e "$B/late.started" ] && [ ! -e "$B/late/s7.sock" ]; then echo after >"$1.order"; else echo unknown >"$1.order"; fi
    listen "$B/late/s7.sock" stream && : >"$B/late.flag"
    wait "$w"
    date +%s.%N >>"$1.t"
  }
  if due S7-late-socket "$BOUND_LATE"; then
    late "$B/out/S7.c" none
    sleep 1
    sleep 6
    late "$B/out/S7.n" "$P-a"
    SPEC+=("late S7-late-socket $B/late/s7.sock $B/out/S7")
  fi

  # --- exec inheritance and escapes (each with its no-profile control)
  if due S11-exec-inherits "$BOUND_S11E"; then
    ns "$B/out/S11e" "$P-a" sh -c 'exec sh -c "exec \"\$1\" -I \"\$0\" label" "$0" "$1"' "$S" "$PY"
    case $(lbl "$B/out/S11e") in
      "$P-a (enforce)") verdict S11-exec-inherits PASS "grandchild label $P-a (enforce)" ;;
      unconfined) verdict S11-exec-inherits FAIL "the grandchild lost the profile" ;;
      *) verdict S11-exec-inherits INCONCLUSIVE "grandchild label $(lbl "$B/out/S11e" | clean)" ;;
    esac
  fi
  esc() { # id shell-command printing RESULT CHANGED|DENIED
    due "$1" "$BOUND_ESC" || return 0
    ns "$B/out/$1.c" none sh -c "\"\$1\" -I \"\$0\" label; $2" "$S" "$PY"
    ns "$B/out/$1.n" "$P-a" sh -c "\"\$1\" -I \"\$0\" label; $2" "$S" "$PY"
    if [ "$(res "$B/out/$1.c")" != CHANGED ] || [ "$(lbl "$B/out/$1.n")" != "$P-a (enforce)" ]; then
      verdict "$1" INCONCLUSIVE "control $(res "$B/out/$1.c" | clean), label $(lbl "$B/out/$1.n" | clean)"
    elif [ "$(res "$B/out/$1.n")" = DENIED ]; then verdict "$1" PASS "denied under the profile (or by no_new_privs, as in production); control changed"
    elif [ "$(res "$B/out/$1.n")" = CHANGED ]; then verdict "$1" FAIL "changed under the profile"
    else verdict "$1" INCONCLUSIVE "result $(res "$B/out/$1.n" | clean)"; fi
  }
  esc S11-changeprofile 'printf "changeprofile unconfined" >/proc/self/attr/apparmor/current 2>/dev/null && echo "RESULT CHANGED" || echo "RESULT DENIED"'
  esc S11-aa-exec-unconfined 'aa-exec -p unconfined -- true 2>/dev/null && echo "RESULT CHANGED" || echo "RESULT DENIED"'

  # --- refusal when the profile is unavailable; complain mode is visible
  if due S12-missing-profile "$BOUND_S12"; then
    ns "$B/out/S12" none sh -c 'aa-exec -p "$1" -- "$2" -I "$0" label; echo "RC $?"' "$S" "$P-missing" "$PY"
    if ! grep -q '^LABEL ' "$B/out/S12" && grep -q '^RC [1-9]' "$B/out/S12"; then
      verdict S12-missing-profile PASS "aa-exec refused; the command did not start"
    elif grep -q '^LABEL ' "$B/out/S12"; then verdict S12-missing-profile FAIL "the command started"
    else verdict S12-missing-profile INCONCLUSIVE "$(clean <"$B/out/S12")"; fi
  fi
  if due S12-complain-visible "$BOUND_S12"; then
    ns "$B/out/S12m" "$P-m" "$PY" -I "$S" label
    case $(lbl "$B/out/S12m") in
      "$P-m (complain)") verdict S12-complain-visible PASS "label shows (complain)" ;;
      "$P-m ("*) verdict S12-complain-visible FAIL "label $(lbl "$B/out/S12m" | clean) hides complain mode" ;;
      *) verdict S12-complain-visible INCONCLUSIVE "label $(lbl "$B/out/S12m" | clean) (profile not attached)" ;;
    esac
  fi

  # --- cleanup after an abnormal end: a child run is terminated after setup
  if due S15-cleanup-after-term "$BOUND_S15"; then
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
        verdict S15-cleanup-after-term FAIL "left: dir $([ -e "$B/abort" ] && echo yes || echo no), listener rc $zl, profile $zp; $(grep '^CLEANUP' "$B/out/S15" | clean)"
      else
        verdict S15-cleanup-after-term INCONCLUSIVE "profile count $zp, pgrep rc $zl; $(grep '^CLEANUP' "$B/out/S15" | clean)"
      fi
    else
      kill -TERM "$w" 2>/dev/null
      wait "$w"
      verdict S15-cleanup-after-term INCONCLUSIVE "self-test setup: $(clean <"$B/out/S15")"
    fi
  fi

  # === COLLECT: observations (not gating)
  if due_obs S6b-abstract-same-netns-profile "$BOUND_S6B"; then
    if [ "$ABS" = yes ]; then
      NET=0 ns "$B/out/S6b" "$P-a" "$PY" -I "$S" connect "@$P-abs" stream
      obs S6b-abstract-same-netns-profile "$(res "$B/out/S6b" | clean) (not guaranteed by the policy: unix, allows abstract peers)"
    else obs S6b-abstract-same-netns-profile "not-run (no abstract listener)"; fi
  fi
  # inherited and passed sockets: not guaranteed by the policy (delegation);
  # production relies on closing descriptors
  if due_obs S8-inherited-connected "$BOUND_S8"; then
    listen "$B/host/s8.sock" stream || true
    ns "$B/out/S8" none "$PY" -I "$S" holdexec "$B/host/s8.sock" -- aa-exec -p "$P-a" -- "$PY" -I "$S" usefd 5
    obs S8-inherited-connected "label $(lbl "$B/out/S8" | clean); result $(res "$B/out/S8" | clean)"
  fi
  if due_obs S9-scm-rights "$BOUND_S9"; then
    ns "$B/out/S9" none "$PY" -I "$S" scm "$B/host/s8.sock" -- aa-exec -p "$P-a" -- "$PY" -I "$S" recvfd 6
    obs S9-scm-rights "label $(lbl "$B/out/S9" | clean); result $(res "$B/out/S9" | clean)"
  fi
  if due_obs S11-userns "$BOUND_S11U"; then
    ns "$B/out/S11u.c" none sh -c 'unshare -U true 2>/dev/null && echo "RESULT CREATED" || echo "RESULT DENIED"'
    ns "$B/out/S11u.n" "$P-a" sh -c 'unshare -U true 2>/dev/null && echo "RESULT CREATED" || echo "RESULT DENIED"'
    obs S11-userns "no profile $(res "$B/out/S11u.c" | clean); profile $(res "$B/out/S11u.n" | clean) (a new namespace only makes host sockets more disconnected)"
  fi
  if due_obs S11b-order-B "$BOUND_S11B"; then
    sudo -n timeout -s KILL 20 unshare --net --mount --pid --fork --kill-child --mount-proc --ipc --propagation private -- \
      /bin/sh -c 'exec </dev/null || exit 97; printf "exec %s" "$1" >/proc/self/attr/apparmor/exec || exit 98; shift; exec "$@"' spike-init "$P-x" \
      setpriv --reuid "$U" --regid "$G" --clear-groups --no-new-privs --inh-caps=-all --bounding-set=-all -- \
      "$PY" -I "$S" connect "$B/host/s2.sock" stream 2>&1 | timeout -s KILL 25 head -c 65536 >"$B/out/S11b"
    obs S11b-order-B "label $(lbl "$B/out/S11b" | clean); result $(res "$B/out/S11b" | clean) (used only if order A fails)"
  fi
  # the hazard of removing a profile a task still carries (test-owned task only)
  if due_obs S14b-removal-unconfines "$BOUND_S14B"; then
    listen "$B/host/s14.sock" stream || true
    rm -f "$B/rm.flag"
    ns "$B/out/S14b" "$P-r" sh -c '"$3" -I "$0" label; i=0; while [ ! -e "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
      "$3" -I "$0" connect "$2" stream' "$S" "$B/rm.flag" "$B/host/s14.sock" "$PY" &
    w=$!
    BGJOBS+=("$w")
    sleep 2
    case " ${LOADED[*]} " in *" $P-r "*) printf '%s' "$P-r" | sudo -n timeout 5 tee /sys/kernel/security/apparmor/.remove >/dev/null 2>&1 ;; esac
    : >"$B/rm.flag"
    wait "$w"
    obs S14b-removal-unconfines "labels: $(sed -n 's/^LABEL //p' "$B/out/S14b" | tr '\n' '|' | clean); result $(res "$B/out/S14b" | clean)"
  fi
  # descriptor hygiene: what a confined process holds, and that no listener holds the reader's stdin
  if due_obs S17-fd-hygiene "$BOUND_S17"; then
    ns "$B/out/S17" "$P-a" "$PY" -I "$S" fds
    held=unknown
    w=${AUD[1]-}
    case $w in "" | *[!0-9]*) ;; *)
      pi=$(readlink "/proc/$$/fd/$w" 2>/dev/null)
      held=no
      for e in "${PIDS[@]}"; do
        read -r p st a <<<"$e"
        is_ours "$p" "$st" "$a" || continue
        for l in /proc/"$p"/fd/*; do [ "$(readlink "$l" 2>/dev/null)" = "$pi" ] && held=yes; done
      done ;;
    esac
    obs S17-fd-hygiene "label $(lbl "$B/out/S17" | clean); fds $(sed -n 's/^FDS //p' "$B/out/S17" | clean); a listener holds the reader stdin: $held"
  fi
  # cost (recorded, not gating)
  if due_obs S13-cost "$BOUND_S13"; then
    t0=$(date +%s%N)
    load "$P-t" enforce
    obs S13-profile-load "$((($(date +%s%N) - t0) / 1000000)) ms"
    t0=$(date +%s%N); ns "$B/out/S13n" none "$PY" -I "$S" label; t1=$(date +%s%N)
    ns "$B/out/S13a" "$P-a" "$PY" -I "$S" label; t2=$(date +%s%N)
    obs S13-start "no profile $(((t1 - t0) / 1000000)) ms; profile $(((t2 - t1) / 1000000)) ms"
  fi
else
  say "INFO preconditions not met (${PRE_FAIL[*]-} ${PRE_INC[*]-}): cases NOT-RUN"
fi

# === STOP the reader, then read the fallback sources once
for e in "${BGJOBS[@]}"; do wait "$e" 2>/dev/null; done
sleep 2
reader_stop
obs S16-audit-reader "$(grep -E '^AUDITREAD (READY|BINDFAIL|DROPFAIL|END|ERROR)' "$B/audit.nl" 2>/dev/null | tr '\n' ' ' | clean); enobufs lines $(grep -c '^AUDITREAD LOST' "$B/audit.nl" 2>/dev/null); size $(stat -c %s "$B/audit.nl" 2>/dev/null)"
sudo -n timeout 5 dmesg 2>/dev/null | head -c 8388608 >"$B/src/dmesg"
sudo -n timeout 5 journalctl -k --no-pager -o short-unix 2>/dev/null | head -c 8388608 >"$B/src/journal"
sudo -n timeout 5 cat /var/log/audit/audit.log 2>/dev/null | head -c 8388608 >"$B/src/auditlog"
SRCS=(--src "netlink=$B/audit.nl" --src "dmesg=$B/src/dmesg" --src "journal=$B/src/journal" --src "auditlog=$B/src/auditlog")

# === EVALUATE the deferred cases (one bounded call), then bash re-checks every PASS
recheck() { # spec line -> 0 when bash's own simple conditions agree with a PASS
  local k id x1 x2 x3 x4
  read -r k id x1 x2 x3 x4 <<<"$1"
  case $k in
    negative)
      [ "$(res "$x4.cb")" = OK ] && [ "$(res "$x4.ca")" = OK ] && [ "$(lbl "$x4.cb")" = unconfined ] &&
        [ "$(lbl "$x4.ca")" = unconfined ] && [ "$(lbl "$x4.neg")" = "$P-a (enforce)" ] && [ "$(res "$x4.neg")" = EACCES ] ;;
    late)
      [ "$(res "$x2.c")" = OK ] && [ "$(lbl "$x2.c")" = unconfined ] && [ "$(lbl "$x2.n")" = "$P-a (enforce)" ] &&
        [ "$(cat "$x2.n.order" 2>/dev/null)" = after ] && [ "$(res "$x2.n")" = EACCES ] ;;
    positive) [ "$(lbl "$x2")" = "$x1 (enforce)" ] && [ "$(res "$x2")" = OK ] ;;
    abstract)
      [ "$(res "$x1.c")" = OK ] && [ "$(res "$x1.ca")" = OK ] && [ "$(lbl "$x1.c")" = unconfined ] &&
        [ "$(lbl "$x1.ca")" = unconfined ] && [ "$(res "$x1.n")" = ECONNREFUSED ] ;;
    *) return 1 ;;
  esac
}
if [ "${#SPEC[@]}" -gt 0 ]; then
  ids=
  for e in "${SPEC[@]}"; do read -r k id rest <<<"$e"; ids="$ids $id"; done
  : >"$EF"
  out=$(printf '%s\n' "${SPEC[@]}" | timeout 15 "$PY" -I "$E" cases --profile "$P" "${SRCS[@]}" 2>"$EF")
  rc=$?
  batch=$(accept_batch "$rc" "$EF" "$ids" "$out")
  i=0
  while IFS= read -r line; do
    id=${line%% *}
    rest=${line#* }
    c=${rest%% *}
    d=${rest#* }
    if [ "$c" = PASS ] && ! recheck "${SPEC[$i]}"; then c=INCONCLUSIVE; d="evaluator/bash disagree ($d)"; fi
    verdict "$id" "$c" "$d"
    i=$((i + 1))
  done <<<"$batch"
fi
socks=()
for e in "${SPEC[@]}"; do read -r k id x1 x2 x3 rest <<<"$e"; [ "$k" = negative ] && socks+=(--sock "$x3"); [ "$k" = late ] && socks+=(--sock "$x1"); done
: >"$EF"
nz=$(timeout 5 "$PY" -I "$E" noise --profile "$P" "${socks[@]}" "${SRCS[@]}" 2>"$EF")
rc=$?
obs S16-audit-noise "$(accept "$rc" "$nz" "$EF" INFO | cut -d' ' -f2- | clean)"
grep -F "$P" "$B/audit.nl" 2>/dev/null | grep '^REC 1400 ' | head -n 120 | LC_ALL=C tr -c '[:print:]\n' '?' | cut -c1-600 | sed 's/^/INFO audit-nl /'
grep -F "$P" "$B/src/dmesg" 2>/dev/null | head -n 60 | LC_ALL=C tr -c '[:print:]\n' '?' | cut -c1-600 | sed 's/^/INFO audit-dmesg /'

# === CLEANUP, then DECIDE (bash prints the only decision line)
trap - EXIT
cleanup
DECIDED=yes
if [ "${#CLEAN_FAILS[@]}" -eq 0 ]; then cs=OK; else cs=FAILED; fi
: >"$EF"
dout=$(printf '%s\n' "${LEDGER[@]}" "CLEANUP $cs" "SETUP ${#SETUP_FAILS[@]}" | timeout 10 "$PY" -I "$E" decide 2>"$EF")
rc=$?
d=$(accept "$rc" "$dout" "$EF" GO NO-GO INCONCLUSIVE)
rm -f -- "$EF"
bash_go=yes
[ "${#PRE_FAIL[@]}" -eq 0 ] && [ "${#PRE_INC[@]}" -eq 0 ] && [ "${#REQ_FAIL[@]}" -eq 0 ] && [ "${#REQ_INC[@]}" -eq 0 ] &&
  [ "${#SETUP_FAILS[@]}" -eq 0 ] && [ "${#CLEAN_FAILS[@]}" -eq 0 ] || bash_go=no
for id in PRE-enabled PRE-mode PRE-aa-exec PRE-unix-feature PRE-load-a PRE-attach S2-host-stream S4-unlistable-dir \
  S5-bind-alias S10-dgram-connect S10u-dgram-sendto S7-late-socket S2c-attach-disconnected S3-inside-socket S6a-abstract \
  S11-exec-inherits S11-changeprofile S11-aa-exec-unconfined S12-missing-profile S12-complain-visible S15-cleanup-after-term; do
  n=0
  for e in "${LEDGER[@]}"; do
    read -r k x c <<<"$e"
    [ "$x" = "$id" ] || continue
    n=$((n + 1))
    [ "$c" = PASS ] || bash_go=no
  done
  [ "$n" = 1 ] || bash_go=no
done
case $d in
  "GO "*)
    if [ "$bash_go" = yes ]; then say "SPIKE-DECISION GO"; exit 0; fi
    say "SPIKE-DECISION INCONCLUSIVE (evaluator/bash disagree: evaluator GO, bash not)"
    exit 1 ;;
  "NO-GO "*) say "SPIKE-DECISION NO-GO (${d#NO-GO })"; exit 1 ;;
  *) say "SPIKE-DECISION INCONCLUSIVE (${d#INCONCLUSIVE })"; exit 1 ;;
esac
