canary_py=$1 data=$2 canary=$3
shift 3
mkdir -p "$data" || exit 2
: >"$data/canary.log" || exit 2
rm -f "$canary"
python3 -I "$canary_py" "$canary" "$data/canary.log" &
cpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -S "$canary" ] && break; sleep 0.2; done
[ -S "$canary" ] || { echo "HARNESS ERROR: the canary engine did not start"; kill "$cpid"; exit 2; }
: >"$data/drive-started"
DOCKER_HOST=unix://$canary "$@"
rc=$?
sleep 0.5 # let the canary finish writing
kill "$cpid" 2>/dev/null
wait "$cpid" 2>/dev/null
exit "$rc"
