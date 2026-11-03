#!/usr/bin/env bash
#
# FCRM-SEC-030 WI-9 route R2: one job of the Linux isolation preview, run
# by .github/workflows/fcrm-sec030-wi9-r2-preview.yml on a GitHub-hosted
# ubuntu-24.04 runner, from the repository root, only after that workflow
# has checked every file of this tree against .github/wi9-r2/MANIFEST.md.
#
#   run.sh guard          the four guard suites and the isolation suite
#                         (as the job "Repository guard" of ci.yml)
#   run.sh devenv         tests/devenv/unit.sh (as "Dev environment")
#   run.sh check-guard DIR | check-devenv DIR
#                         only the evidence checks, on the raw outputs in DIR
#   run.sh capture DIR NAME COMMAND...
#                         run COMMAND, its output to the log and DIR/NAME.log;
#                         fails if the command or the copy fails
#
# Every suite runs even if an earlier one failed, so that one authorized
# run gives all the evidence. Its stdout and stderr go to the job log and,
# unchanged, to a directory under /tmp, which the isolation hides from the
# code under test (a file the command could read would give away the token
# that stops workflow commands). The isolation suite also keeps its case
# outputs there (NO_DOCKER_TEST_EVIDENCE). Then:
#   - every suite passed (its command and the copy of its output), and the
#     raw outputs hold the complete evidence of .github/wi9-r2/EXPECTED.md
#     (derived from the source): exactly its result lines, the full
#     checker outputs of T-19, T-36, T-38 and T-39 byte for byte, every
#     raw case output it requires and none it rules out; and, for each
#     first-level launch, every line of the preflight and of gate steps G1
#     to G8, exactly once;
#   - nothing of a launch is left (.github/wi9-r2/residual.py, as root);
#   - the sha256 of every raw output is printed, and all of it is exported
#     into the job log as one framed, hash-checked payload
#     (.github/wi9-r2/payload.py), unless a secret may be in it.
# Any failure, missing or repeated line, unknown or anything left makes the
# job fail.

set -u
LC_ALL=C
export LC_ALL
tools=$(cd -P "$(dirname "$0")" && pwd -P)

failures=0
note() { printf 'wi9-r2: %s\n' "$*"; }
bad() {
  printf 'wi9-r2: FAIL %s\n' "$*"
  failures=$((failures + 1))
}
good() { printf 'wi9-r2: ok   %s\n' "$*"; }

# expect N WANT GOOD BAD: GOOD if the number N equals WANT, else BAD.
expect() {
  if [ "$1" -eq "$2" ]; then good "$3"; else bad "$4"; fi
}

# starting LOG TEXT: the number of lines of LOG that start with TEXT.
starting() {
  awk -v t="$2" 'index($0, t) == 1 { n++ } END { print n + 0 }' "$1"
}

# exactly LOG N TEXT...: each TEXT starts exactly N lines of LOG.
exactly() {
  local log=$1 n=$2 t c
  shift 2
  for t in "$@"; do
    c=$(starting "$log" "$t")
    expect "$c" "$n" "${log##*/}: $n line(s) starting with: $t" "${log##*/}: $c lines, not $n, starting with: $t"
  done
}

# total LOG [N]: the suite's last line is "TOTAL n passed=n failed=0", n > 0
# (and n = N when given).
total() {
  local last
  last=$(grep '^TOTAL ' "$1" | tail -n 1)
  if printf '%s\n' "$last" | grep -qE '^TOTAL ([1-9][0-9]*) passed=\1 failed=0$' &&
    { [ -z "${2-}" ] || [ "$last" = "TOTAL $2 passed=$2 failed=0" ]; }; then
    good "${1##*/}: $last"
  else
    bad "${1##*/}: the suite did not pass${2:+ with $2 cases} (${last:-no TOTAL line})"
  fi
}

# gate LOG: one first-level launch ran in LOG; its preflight and every check
# of gate steps G1 to G8 passed, each line exactly once; its profile was
# loaded and released; no check failed and nothing was refused.
gate() {
  local log=$1 n
  exactly "$log" 1 \
    "no-docker-aa: ok   AppArmor is enabled (Y)" \
    "no-docker-aa: ok   the global mode is enforce (enforce)" \
    "no-docker-aa: ok   the kernel mediates af_unix (" \
    "no-docker-aa: ok   /usr/sbin/apparmor_parser is present (True)" \
    "no-docker-aa: ok   /usr/bin/aa-exec is present (True)" \
    "no-docker-aa: loaded flowcrm-nd-" \
    "no-docker: closed: " \
    "no-docker: ok   not root (uids " \
    "no-docker: ok   no capabilities (" \
    "no-docker: ok   no_new_privs is set (1)" \
    "no-docker: ok   no supplementary groups (" \
    "no-docker: ok   the primary group is not a system group (" \
    "no-docker: ok   private net namespace (" \
    "no-docker: ok   private mnt namespace (" \
    "no-docker: ok   private pid namespace (" \
    "no-docker: ok   private ipc namespace (" \
    "no-docker: ok   the caller is in the initial pid namespace (" \
    "no-docker: ok   in a pid namespace below the caller's (" \
    "no-docker: ok   /proc shows this process in its own pid namespace only (" \
    "no-docker: ok   /proc belongs to this pid namespace" \
    "no-docker: ok   only our processes and the root pid 1 of the isolation are visible (" \
    "no-docker: ok   a session of our own (" \
    "no-docker: ok   no controlling terminal (" \
    "no-docker: ok   the standard descriptors are pipes or /dev/null (" \
    "no-docker: ok   network namespace has only loopback (lo)" \
    "no-docker: ok   the run's directory is known (" \
    "no-docker: ok   /proc shows every process of the namespace (" \
    "no-docker: ok   /tmp is a private tmpfs (" \
    "no-docker: ok   /var/tmp is a private tmpfs (" \
    "no-docker: ok   /dev/shm is a private tmpfs (" \
    "no-docker: ok   /run is a private tmpfs (" \
    "no-docker: ok   /dev/mqueue is a private mqueue (" \
    "no-docker: ok   no other proc or nsfs mount is reachable" \
    "no-docker: ok   /sys/fs/cgroup is masked by a read-only tmpfs" \
    "no-docker: ok   every other mount is read-only (" \
    "no-docker: ok   the working directory is reachable by its path (" \
    "no-docker: ok   the namespace record names this pid namespace (" \
    "no-docker: ok   the control directory is read-only inside (" \
    "no-docker: ok   the fence directory is read-only inside (" \
    "no-docker: ok   the profile name is known (flowcrm-nd-" \
    "no-docker: ok   this process is confined by exactly flowcrm-nd-" \
    "no-docker: ok   every other process but the root pid 1 is confined by exactly flowcrm-nd-" \
    "no-docker: ok   the stream fence is a socket of ours (True" \
    "no-docker: ok   file permissions allow the stream fence (True)" \
    "no-docker: ok   connect to the stream fence is refused with EACCES (EACCES)" \
    "no-docker: ok   the dgram fence is a socket of ours (True" \
    "no-docker: ok   file permissions allow the dgram fence (True)" \
    "no-docker: ok   sendto to the dgram fence is refused with EACCES (EACCES)" \
    "no-docker: ok   a socket bound inside the isolation connects (ok)" \
    "no-docker: ok   the protected directories are known (NO_DOCKER_PROTECTED)" \
    "no-docker: ok   no cgroup file is writable (" \
    "no-docker: ok   no socket in the private directories (" \
    "no-docker: ok   no container engine answers on " \
    "no-docker: ok   the descriptors listed are this process's (" \
    "no-docker: ok   fd 0 is /dev/null and fds 1 and 2 are pipes (" \
    "no-docker: ok   no other descriptor is open" \
    "no-docker: info the gate passed in " \
    "no-docker-aa: released flowcrm-nd-"
  # G7: $HOME, the workspace and $RUNNER_TEMP.
  exactly "$log" 3 "no-docker: ok   writes to "
  n=$(starting "$log" "no-docker: ok   ")
  expect "$n" 52 "${log##*/}: 52 gate checks passed (G1 to G8)" "${log##*/}: $n gate checks passed, not 52"
  n=$(starting "$log" "no-docker-aa: ok   ")
  expect "$n" 5 "${log##*/}: 5 preflight checks passed" "${log##*/}: $n preflight checks passed, not 5"
  if grep -q '; remaining: 0 1 2; stdin char 1:3$' "$log"; then
    good "${log##*/}: --root-exec left only fds 0 to 2, stdin /dev/null"
  else
    bad "${log##*/}: no --root-exec line ending '; remaining: 0 1 2; stdin char 1:3'"
  fi
  n=$(grep -cE '^(no-docker|no-docker-aa): (FAIL|refused)' "$log")
  expect "$n" 0 "${log##*/}: no failed check and no refusal" "${log##*/}: $n failed checks or refusals"
}

# The expected evidence: block NAME of .github/wi9-r2/EXPECTED.md (derived
# from the source tree and pinned by the manifest), without its fence lines.
expected() {
  sed -n "/^<!-- $1 begin -->\$/,/^<!-- $1 end -->\$/p" "$tools/EXPECTED.md" | sed '1,2d;$d' | sed '$d'
}

check_guard() {
  local d=$1 s n w line ci cf ln lp c count re t
  for s in guard-tracked-files guard-dockerfile-frontend guard-trivyignore guard-edge-config; do
    total "$d/$s.log"
    gate "$d/$s.log"
  done
  t=$(mktemp -d "${TMPDIR:-/tmp}/wi9-r2-check.XXXXXX") || { bad "no temporary directory for the checks"; return; }
  # Exactly the result lines of EXPECTED.md, each once: no line missing,
  # replaced (a filler with the same case id, the macOS branch's text) or
  # added.
  s=$d/no-docker.log
  expected pass | LC_ALL=C sort >"$t/want"
  grep '^PASS  ' "$s" | LC_ALL=C sort >"$t/got"
  n=$(grep -c . "$t/want")
  if [ "$n" -gt 0 ] && cmp -s "$t/want" "$t/got"; then
    good "no-docker.log: exactly the $n result lines of EXPECTED.md passed, each once"
  else
    bad "no-docker.log: the result lines differ from EXPECTED.md ($(comm -23 "$t/want" "$t/got" | grep -c .) missing, $(comm -13 "$t/want" "$t/got" | grep -c .) not expected)"
    comm -3 "$t/want" "$t/got" | head -n 10 | sed 's/^/wi9-r2:      /'
  fi
  total "$s" "$n"
  n=$(grep -cE '^(FAIL|SKIP)  |^HARNESS ERROR' "$s")
  expect "$n" 0 "no-docker.log: no FAIL, SKIP or harness error line" "no-docker.log: $n FAIL, SKIP or harness error lines"
  # L-16's projection recomputed exactly, in milliseconds: 184 s + N * c,
  # c as printed (three decimals, rounded up by the suite), at most 540 s;
  # and the printed whole seconds (rounded up) at most 540.
  line=$(grep '^INFO  L-16 c = ' "$s" | tail -n 1)
  read -r ci cf ln lp <<<"$(printf '%s\n' "$line" |
    sed -n 's/^INFO  L-16 c = \([0-9]*\)\.\([0-9][0-9][0-9]\) s per launch, N = \([0-9]*\) launches, projected guard job \([0-9]*\) s$/\1 \2 \3 \4/p')"
  if [ -n "$lp" ] && [ $((184000 + ln * (10#$ci * 1000 + 10#$cf))) -le 540000 ] && [ "$lp" -le 540 ]; then
    good "no-docker.log: L-16 projection 184 + $ln * $ci.$cf = $((184000 + ln * (10#$ci * 1000 + 10#$cf))) ms (at most 540000), printed $lp s"
  else
    bad "no-docker.log: no L-16 projection of at most 540 s (${line:-no INFO L-16 line})"
  fi
  # The case outputs the suite kept. First the manifest itself: every line
  # "<sha256>  <path>", the path relative and of safe names (no "." or
  # ".." part), no path twice; then each file as hashed, none failed.
  w=$d/no-docker-cases
  if [ -s "$w/MANIFEST.sha256" ] &&
    ! grep -vqE '^[0-9a-f]{64}  [A-Za-z0-9._@+=,-]+(/[A-Za-z0-9._@+=,-]+)*$' "$w/MANIFEST.sha256" &&
    ! cut -c67- "$w/MANIFEST.sha256" | grep -qE '(^|/)[.][.]?(/|$)' &&
    [ -z "$(cut -c67- "$w/MANIFEST.sha256" | LC_ALL=C sort | uniq -d)" ]; then
    good "no-docker-cases: the manifest has $(wc -l <"$w/MANIFEST.sha256" | tr -d ' ') well-formed rows, each path once"
  else
    bad "no-docker-cases: the manifest is missing, malformed, names an unsafe path or lists a path twice"
  fi
  if [ -f "$w/MANIFEST.sha256" ] && [ -f "$w/SKIPPED.txt" ] && [ -s "$w/MANIFEST.sha256" ] &&
    (cd "$w" && sha256sum -c --strict --quiet MANIFEST.sha256) && ! grep -q '^FAILED' "$w/SKIPPED.txt"; then
    good "no-docker-cases: $(wc -l <"$w/MANIFEST.sha256" | tr -d ' ') case outputs kept, each with its sha256"
  else
    bad "no-docker-cases: the case outputs are missing, incomplete or differ from their sha256"
  fi
  # The full outputs of the checkers (the suite prints only their lines
  # that are not "ok"): exactly those of EXPECTED.md.
  for c in T-19 T-36 T-38 T-39; do
    expected "$c" >"$t/$c"
    if [ -s "$t/$c" ] && grep -qx "[0-9a-f]\{64\}  work/$c.out" "$w/MANIFEST.sha256" && cmp -s "$t/$c" "$w/work/$c.out"; then
      good "no-docker-cases: work/$c.out is exactly the checker output of EXPECTED.md ($(grep -c . "$t/$c") lines)"
    else
      bad "no-docker-cases: work/$c.out is missing or differs from the checker output of EXPECTED.md"
    fi
  done
  # Every raw case output a successful run leaves, by the rows of
  # EXPECTED.md (count, path pattern), in the manifest; none of those it
  # removes or never makes.
  cut -c67- "$w/MANIFEST.sha256" >"$t/paths" 2>/dev/null
  expected paths >"$t/rows"
  expected absent >"$t/absent"
  n=0
  while read -r count re; do
    c=$(grep -cE "^($re)\$" "$t/paths")
    if [ "$c" -ne "$count" ]; then
      bad "no-docker-cases: $c kept paths match $re, not $count"
      n=$((n + 1))
    fi
  done <"$t/rows"
  if [ "$n" -eq 0 ] && [ -s "$t/rows" ]; then
    good "no-docker-cases: all $(grep -c . "$t/rows") path rows of EXPECTED.md are kept ($(awk '{ s += $1 } END { print s }' "$t/rows") files)"
  else
    bad "no-docker-cases: $n of the path rows of EXPECTED.md are not met"
  fi
  n=$(grep -cxEf "$t/absent" "$t/paths")
  expect "$n" 0 "no-docker-cases: none of the $(grep -c . "$t/absent") paths a successful run removes or never makes is there" \
    "no-docker-cases: $n paths kept that a successful run removes or never makes"
  { sed 's/^[0-9]* //' "$t/rows"; cat "$t/absent"; } >"$t/patterns"
  n=$(grep -cvxEf "$t/patterns" "$t/paths")
  note "no-docker-cases: $n further kept paths (the variable part of EXPECTED.md)"
  grep -vxEf "$t/patterns" "$t/paths" | head -n 40 | sed 's/^/wi9-r2:      /'
  rm -rf "${t:?}"
}

check_devenv() {
  total "$1/unit.log"
  gate "$1/unit.log"
}

# capture DIR NAME COMMAND...: COMMAND's stdout and stderr to the job log
# and DIR/NAME.log; both the command and the copy must succeed.
capture() {
  local d=$1 name=$2 s st
  shift 2
  note "--- $name: $* ($(date -u +%H:%M:%S))"
  s=$(date +%s)
  "$@" 2>&1 | tee "$d/$name.log"
  st=("${PIPESTATUS[@]}")
  note "--- $name: status ${st[0]}, copy ${st[1]}, after $(($(date +%s) - s)) s"
  [ "${st[0]}" -eq 0 ] || bad "$name exited with status ${st[0]}"
  [ "${st[1]}" -eq 0 ] || bad "$name: its output could not be kept (tee status ${st[1]})"
  [ -f "$d/$name.log" ] && [ ! -L "$d/$name.log" ] || bad "$name: no raw output file"
}

record() {
  note "commit $GITHUB_SHA ref $GITHUB_REF run $GITHUB_RUN_ID attempt $GITHUB_RUN_ATTEMPT"
  note "image ${ImageOS-?} ${ImageVersion-?}; runner ${RUNNER_ENVIRONMENT-?} ${RUNNER_ARCH-?}"
  note "kernel $(uname -srvm)"
  # shellcheck source=/dev/null # the runner's own file
  note "os $(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
  note "$(bash --version | head -n 1); $(python3 --version 2>&1); $(sudo -V | head -n 1)"
  note "$(/usr/sbin/apparmor_parser --version 2>&1 | head -n 1)"
  note "features/network/af_unix: $(sudo -n cat /sys/kernel/security/apparmor/features/network/af_unix 2>&1 | head -n 1)"
  note "apparmor_restrict_unprivileged_unconfined $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined 2>&1)"
  note "apparmor_restrict_unprivileged_userns $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>&1)"
}

# residual WHEN: nothing of a launch is left (as root; unknown fails).
residual() {
  if sudo -n /usr/bin/python3 -I "$tools/residual.py" "$RUNNER_TEMP"; then
    good "$1: nothing of a launch is left"
  else
    bad "$1: something of a launch is left, or it cannot be shown that nothing is"
  fi
}

finish() {
  local job=$1 rc
  note "raw outputs (sha256, bytes, path):"
  python3 -I "$tools/payload.py" digest "$dir" | sed 's/^/wi9-r2: /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || bad "the raw outputs cannot all be read and hashed"
  python3 -I "$tools/payload.py" export "$dir" "$job"
  rc=$?
  case $rc in
    0) good "the raw outputs are exported above as payload $job (extract: .github/wi9-r2/payload.py extract)" ;;
    3) bad "the payload is withheld: a secret may be in the raw outputs" ;;
    *) bad "the payload could not be made (status $rc)" ;;
  esac
  if [ "$failures" -eq 0 ]; then
    note "PASS: every suite passed, the evidence is complete, nothing is left, the payload is exported"
    exit 0
  fi
  note "FAIL: $failures failed checks"
  exit 1
}

case ${1-} in
  check-guard | check-devenv)
    [ -d "${2-}" ] || { echo "usage: $0 $1 DIR" >&2; exit 2; }
    if [ "$1" = check-guard ]; then check_guard "$2"; else check_devenv "$2"; fi
    [ "$failures" -eq 0 ] && exit 0
    exit 1
    ;;
  capture)
    [ $# -ge 4 ] || { echo "usage: $0 capture DIR NAME COMMAND..." >&2; exit 2; }
    shift
    capture "$@"
    [ "$failures" -eq 0 ] && exit 0
    exit 1
    ;;
  guard | devenv) ;;
  *)
    echo "usage: $0 guard|devenv|check-guard DIR|check-devenv DIR|capture DIR NAME COMMAND..." >&2
    exit 2
    ;;
esac
[ "${GITHUB_ACTIONS-}" = true ] && [ "${RUNNER_ENVIRONMENT-}" = github-hosted ] && [ -n "${RUNNER_TEMP-}" ] ||
  { echo "wi9-r2: for a GitHub-hosted runner only" >&2; exit 2; }
# By its physical path: the isolation suite refuses an evidence directory
# with a symbolic link among its ancestors.
dir=$(mktemp -d /tmp/wi9-r2-evidence.XXXXXX) && dir=$(cd -P "$dir" && pwd -P) && [ -n "$dir" ] || exit 2
note "raw outputs are kept in $dir"
record
residual before
if [ "$1" = guard ]; then
  capture "$dir" guard-tracked-files scripts/ci/tests/guard-tracked-files.test.sh
  capture "$dir" guard-dockerfile-frontend scripts/ci/tests/guard-dockerfile-frontend.test.sh
  capture "$dir" guard-trivyignore scripts/ci/tests/guard-trivyignore.test.sh
  capture "$dir" guard-edge-config scripts/ci/tests/guard-edge-config.test.sh
  mkdir -m 700 "$dir/no-docker-cases" || bad "cannot make the directory for the case outputs"
  capture "$dir" no-docker env NO_DOCKER_TEST_EVIDENCE="$dir/no-docker-cases" scripts/ci/tests/no-docker.test.sh
  check_guard "$dir"
else
  capture "$dir" unit tests/devenv/unit.sh
  check_devenv "$dir"
fi
residual after
finish "$1"
