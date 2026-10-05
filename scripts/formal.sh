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
  # Reference copies for equivalence jobs: "# formal-ref: <commit> <path> <module> <new
  # module>" writes <path> at <commit> to sim/formal/ref/<new module>.sv with the module
  # renamed (px_csr_equiv: the Phase 1 px_csr, D-032).
  refbad=0
  while read -r rcommit rpath rmod rnew; do
    [ -z "$rcommit" ] && continue
    mkdir -p sim/formal/ref
    if ! git show "$rcommit:$rpath" | sed -E "s/^module ${rmod}([^A-Za-z0-9_])/module ${rnew}\1/" \
         > "sim/formal/ref/$rnew.sv" || [ "$(grep -c "^module ${rnew}[^A-Za-z0-9_]" "sim/formal/ref/$rnew.sv")" != 1 ]; then
      echo "  $name: cannot write the reference $rnew from $rcommit:$rpath"
      refbad=1
    fi
  done < <(sed -n 's/^# formal-ref: *//p' "$job")
  if [ "$refbad" != 0 ]; then
    echo "  $name FAIL (reference)"
    fail=1
    continue
  fi
  if sby -f --prefix "sim/formal/$name" "$job" ${FORMAL_TASKS:-${defaults:-bmc cover}} > "sim/formal/$name.log" 2>&1; then
    echo "  $name PASS"
  else
    echo "  $name FAIL (see sim/formal/$name.log)"
    fail=1
  fi
  grep -E "DONE \((PASS|FAIL|ERROR|UNKNOWN)" "sim/formal/$name.log" | sed 's/^/    /'
done
exit "$fail"
