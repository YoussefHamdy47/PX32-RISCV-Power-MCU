#!/usr/bin/env bash
# Run every SymbiYosys job in tb/formal/*.sby (all tasks). Work directories and logs go to
# sim/formal/. Exit status: 0 if every task passes, 1 otherwise.
#
# Scope: bounded model checking (bmc), k-induction (prove) and reachability (cover) of the
# properties written in each harness. A pass covers exactly those properties, under the
# harness's environment assumptions; it is not a proof of the whole core.

set -u
[ "${1:-}" = prove ] && FORMAL_TASKS=prove
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OSS="${OSS_CAD_SUITE:-/c/oss-cad-suite}"
export PATH="$OSS/bin:$OSS/lib:$PATH"
mkdir -p sim/formal
fail=0
for job in tb/formal/*.sby; do
  name="$(basename "$job" .sby)"
  # Default tasks: the job's "# formal-default-tasks:" line (bmc and cover if it has none).
  # Slow tasks are run on request, e.g. the fetch stage's unbounded "prove" (abc pdr; it
  # did not converge within 25 minutes in the audit): scripts/formal.sh prove.
  defaults="$(sed -n 's/^# formal-default-tasks: *//p' "$job" | head -1)"
  if sby -f --prefix "sim/formal/$name" "$job" ${FORMAL_TASKS:-${defaults:-bmc cover}} > "sim/formal/$name.log" 2>&1; then
    echo "  $name PASS"
  else
    echo "  $name FAIL (see sim/formal/$name.log)"
    fail=1
  fi
  grep -E "DONE \((PASS|FAIL|ERROR|UNKNOWN)" "sim/formal/$name.log" | sed 's/^/    /'
done
exit "$fail"
