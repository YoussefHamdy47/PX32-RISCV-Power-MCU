#!/usr/bin/env bash
# D-019: run all unit/core/SoC source lists and print a summary.
# Exit status: 0 = all pass, 1 = any failure or invalid suite.
# REGRESS_JOBS (default 4) benches run at a time (step 2.2d, DECISIONS.md D-035): every bench
# writes only its own files (sim/<tb>.vvp, sim/logs/<tb>*), so they are independent; the
# summary lists them in the usual order.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
failed=()
json_rows=()

json_row() {  # name status detail -> one JSON object (escapes backslash and quote)
  local d="${3//\\/\\\\}"
  d="${d//\"/\\\"}"
  printf '{"name": "%s", "status": "%s", "detail": "%s"}' "$1" "$2" "$d"
}

shopt -s nullglob
tests=(tb/unit/*.f tb/core/*.f tb/soc/*.f)
if [ "${#tests[@]}" -eq 0 ]; then
  echo "FAIL: no test source lists found"
  exit 1
fi
declare -A seen
for f in "${tests[@]}"; do
  tb="$(basename "$f" .f)"
  if [ -n "${seen[$tb]:-}" ]; then
    echo "FAIL: duplicate testbench name: $tb"
    exit 1
  fi
  seen[$tb]=1
done

# run: the longest benches (core, SoC) first, at most REGRESS_JOBS at a time; each writes
# its exit status to sim/logs/<tb>.rc
JOBS="${REGRESS_JOBS:-4}"
mkdir -p sim/logs
order=()
for f in "${tests[@]}"; do case "$f" in tb/unit/*) ;; *) order+=("$f") ;; esac; done
for f in "${tests[@]}"; do case "$f" in tb/unit/*) order+=("$f") ;; esac; done
running=0
for f in "${order[@]}"; do
  tb="$(basename "$f" .f)"
  rm -f "sim/logs/${tb}.rc"
  ( scripts/run_unit.sh "$tb" "$f" > /dev/null 2>&1; echo $? > "sim/logs/${tb}.rc" ) &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n
    running=$((running - 1))
  fi
done
wait

for f in "${tests[@]}"; do
  tb="$(basename "$f" .f)"
  if [ "$(cat "sim/logs/${tb}.rc" 2>/dev/null)" = 0 ]; then
    detail="$(grep -m1 '^PASS' "sim/logs/${tb}.log" | sed 's/^PASS [^ ]* //')"
    printf '  %-28s PASS  %s\n' "$tb" "$detail"
    pass=$((pass + 1))
    json_rows+=("$(json_row "$tb" PASS "$detail")")
  else
    printf '  %-28s FAIL  (see sim/logs/%s.log)\n' "$tb" "$tb"
    fail=$((fail + 1))
    failed+=("$tb")
    json_rows+=("$(json_row "$tb" FAIL "see sim/logs/${tb}.log")")
  fi
done

echo "----------------------------------------"
echo "  $pass passed, $fail failed"

# Status dashboard: record results and regenerate sim/dashboard/index.html.
# Informational only; it never changes the regression exit status.
{
  printf '{"timestamp": "%s", "results": [' "$(date '+%Y-%m-%d %H:%M:%S')"
  (IFS=,; printf '%s' "${json_rows[*]}")
  printf ']}\n'
} > sim/regress.json
PY="${LOCALAPPDATA:-}/Programs/Python/Python312/python.exe"
[ -x "$PY" ] || PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ] && "$PY" scripts/gen_dashboard.py > /dev/null 2>&1; then
  echo "  dashboard: sim/dashboard/index.html"
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
