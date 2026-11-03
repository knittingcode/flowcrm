# shellcheck shell=bash
#
# Result bookkeeping shared by the bin/devenv test suites (sourced).
#
# Every result is printed and appended to a tally file. tally_finish compares
# the PASS and FAIL records in that file with the counters of the main shell,
# so a result recorded in a subshell or pipeline (whose counter update is
# lost) fails the suite with exit 2 instead of disappearing from the totals.
# A suite without any result fails as well.

tally_init() { # file
  TALLY_FILE=$1
  : >"$TALLY_FILE"
  pass=0
  fail=0
}

pass_result() { # text
  pass=$((pass + 1))
  printf 'PASS  %s\n' "$1" | tee -a "$TALLY_FILE"
}

fail_result() { # text
  fail=$((fail + 1))
  printf 'FAIL  %s\n' "$1" | tee -a "$TALLY_FILE"
}

# Prints the totals; returns 0 all passed, 1 failures or no results,
# 2 printed records and counters disagree.
tally_finish() { # [summary suffix]
  local printed_pass printed_fail
  printed_pass=$(grep -c '^PASS  ' "$TALLY_FILE")
  printed_fail=$(grep -c '^FAIL  ' "$TALLY_FILE")
  echo
  echo "TOTAL $((pass + fail)) passed=$pass failed=$fail${1:+ $1}"
  if [ "$printed_pass" -ne "$pass" ] || [ "$printed_fail" -ne "$fail" ]; then
    echo "HARNESS ERROR: $printed_pass PASS and $printed_fail FAIL records printed, but $pass and $fail counted (a result was recorded in a subshell)"
    return 2
  fi
  [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
}
