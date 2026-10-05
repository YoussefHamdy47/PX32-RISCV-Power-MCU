#!/usr/bin/env python3
"""Run riscv-formal on px_core (DECISIONS.md D-029, D-030).

Steps (no make: Git Bash has none, and WSL has no Yosys/SBY):
  1. check the pinned riscv-formal checkout (commit and a clean tree)
  2. build a work tree in sim/riscv_formal/: the pinned checks/ and insns/, the project's
     Zicond models, the joined ISA list, and cores/px32/ with checks.cfg, wrapper.sv and a
     copy of the RTL (tb/formal/riscv_formal/, rtl/)
  3. run the upstream genchecks.py in cores/px32/ (it writes one .sby per check)
  4. run sby for every check in parallel and read each check's status file ("expect
     pass,fail" makes sby's exit code 0 either way)
Writes sim/riscv_formal/summary.txt and results.json. Exit status 1 if any check fails or
errors (or none ran).

Usage: python scripts/riscv_formal.py [--only REGEX] [--jobs N] [--list] [--timeout S]
       [--mutant ID]   apply mutant ID of scripts/mutants.txt to the work copy of the RTL
                       (sensitivity check: the run is expected to fail)
"""

import argparse
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RF = Path(os.environ.get("PX_RISCV_FORMAL", "C:/px32-tools/src/riscv-formal"))
RF_COMMIT = "c992aa61fdfe0846c5ed90324c596202a1c69b76"     # D-030
OSS = Path(os.environ.get("OSS_CAD_SUITE", "C:/oss-cad-suite"))
WORK = ROOT / "sim" / "riscv_formal"
CORE = WORK / "cores" / "px32"
SRC = ROOT / "tb" / "formal" / "riscv_formal"
ISA = "rv32imc_Zba_Zbb_Zbs_Zicond"
ISA_PARTS = ["rv32imc", "rv32iZba", "rv32iZbb", "rv32iZbs"]
EXTRA_INSNS = ["czero_eqz", "czero_nez"]                    # project models (Zicond)
RTL = ["rtl/pkg/px_pkg.sv", "rtl/core/px_alu.sv", "rtl/core/px_regfile.sv",
       "rtl/core/px_decoder.sv", "rtl/core/px_decompressor.sv", "rtl/core/px_if_stage.sv",
       "rtl/core/px_csr_m.sv", "rtl/core/px_csr.sv",
       "rtl/core/px_mul.sv", "rtl/core/px_div.sv", "rtl/core/px_core.sv"]


def git(*args):
    return subprocess.run(["git", "-C", str(RF), *args], capture_output=True, text=True).stdout.strip()


def env():
    e = dict(os.environ)
    e["PATH"] = os.pathsep.join([str(OSS / "bin"), str(OSS / "lib"), e.get("PATH", "")])
    return e


def build_tree(mutant=None):
    head = git("rev-parse", "HEAD")
    if head != RF_COMMIT:
        sys.exit(f"FAIL riscv-formal checkout {RF} is at {head or 'unknown'}, expected {RF_COMMIT}")
    if git("status", "--porcelain", "--untracked-files=no"):
        sys.exit(f"FAIL riscv-formal checkout {RF} has local modifications")
    shutil.rmtree(WORK, ignore_errors=True)
    shutil.copytree(RF / "checks", WORK / "checks")
    shutil.copytree(RF / "insns", WORK / "insns")
    for insn in EXTRA_INSNS:
        shutil.copy2(SRC / f"insn_{insn}.v", WORK / "insns" / f"insn_{insn}.v")
    insns = set(EXTRA_INSNS)
    for part in ISA_PARTS:
        insns |= set((RF / "insns" / f"isa_{part}.txt").read_text().split())
    (WORK / "insns" / f"isa_{ISA}.txt").write_text("".join(f"{i}\n" for i in sorted(insns)), newline="\n")
    (CORE / "rtl").mkdir(parents=True)
    shutil.copy2(SRC / "checks.cfg", CORE / "checks.cfg")
    shutil.copy2(SRC / "wrapper.sv", CORE / "wrapper.sv")
    for f in RTL:
        shutil.copy2(ROOT / f, CORE / "rtl" / Path(f).name)
    if mutant:
        sys.path.insert(0, str(ROOT / "scripts"))
        import mutate
        m = [x for x in mutate.parse(ROOT / "scripts" / "mutants.txt") if x["id"] == mutant]
        if not m:
            sys.exit(f"FAIL no mutant {mutant}")
        m = m[0]
        target = CORE / "rtl" / Path(m["file"]).name
        text = target.read_text(encoding="utf-8")
        if text.count(m["old"]) != 1:
            sys.exit(f"FAIL mutant {mutant}: original text not found exactly once")
        target.write_bytes(text.replace(m["old"], m["new"]).encode("utf-8"))
        print(f"mutant {mutant} applied to {target.name}: {' '.join(m['note'])}")
    return sorted(insns)


def run_check(name, timeout):
    t0 = time.time()
    try:
        p = subprocess.run([str(OSS / "bin" / "sby.exe"), "-f", f"{name}.sby"], cwd=CORE / "checks",
                           capture_output=True, text=True, env=env(), timeout=timeout)
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return name, "TIMEOUT", time.time() - t0, ""
    status_file = CORE / "checks" / name / "status"
    status = status_file.read_text().split()[0] if status_file.exists() else "ERROR"
    trace = ""
    m = re.search(r"Writing trace to VCD file: (\S+)", out)
    if m:
        trace = m.group(1)
    if status not in ("PASS", "FAIL"):
        (CORE / "checks" / f"{name}.error.log").write_text(out)
    return name, status, time.time() - t0, trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="regular expression on check names")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    ap.add_argument("--timeout", type=int, default=3600, help="seconds per check")
    ap.add_argument("--list", action="store_true", help="generate and list the checks only")
    ap.add_argument("--mutant", help="apply this scripts/mutants.txt mutant to the work RTL")
    a = ap.parse_args()

    insns = build_tree(a.mutant)
    g = subprocess.run([sys.executable, str(WORK / "checks" / "genchecks.py")], cwd=CORE,
                       capture_output=True, text=True, env=env())
    (WORK / "genchecks.log").write_text(g.stdout + g.stderr)
    if g.returncode != 0:
        print(g.stdout + g.stderr)
        sys.exit("FAIL genchecks.py")
    checks = sorted(p.stem for p in (CORE / "checks").glob("*.sby"))
    if a.only:
        checks = [c for c in checks if re.search(a.only, c)]
    print(f"riscv-formal {RF_COMMIT[:8]}, ISA {ISA} ({len(insns)} instruction models), "
          f"{len(checks)} checks, {a.jobs} jobs")
    if a.list:
        print("\n".join(checks))
        return 0
    if not checks:
        sys.exit("FAIL no checks selected")

    results = []
    t0 = time.time()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for name, status, dt, trace in ex.map(lambda c: run_check(c, a.timeout), checks):
            results.append({"check": name, "status": status, "seconds": round(dt, 1), "trace": trace})
            print(f"  {name:<40} {status:<7} {dt:7.1f} s {trace}", flush=True)
    bad = [r for r in results if r["status"] != "PASS"]
    lines = [f"riscv-formal {RF_COMMIT}, ISA {ISA}, {len(results)} checks, "
             f"{len(results) - len(bad)} PASS, {len(bad)} not PASS, {time.time() - t0:.0f} s"]
    lines += [f"  {r['status']:<7} {r['check']} {r['trace']}" for r in bad]
    lines.append("PASS riscv-formal" if not bad else "FAIL riscv-formal")
    (WORK / "summary.txt").write_text("\n".join(lines) + "\n")
    (WORK / "results.json").write_text(json.dumps(results, indent=1))
    print("\n".join(lines))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
