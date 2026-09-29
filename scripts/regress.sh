#!/usr/bin/env bash
# D-019: run all unit/core/SoC source lists and print a summary.
# Exit status: 0 = all pass, 1 = any failure or invalid suite.

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
  if scripts/run_unit.sh "$tb" "$f" > /dev/null 2>&1; then
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
