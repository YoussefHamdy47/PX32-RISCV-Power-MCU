#!/usr/bin/env python3
"""Formal mutation check: does each formal harness fail on every planted bug in its RTL?

Harnesses (HARNESSES below): px_csr (tb/formal/px_csr.sby; rtl/core/px_csr.sv and
rtl/core/px_csr_m.sv, task bmc) and px_clic (tb/formal/px_clic.sby; rtl/irq/px_clic.sv,
task bmc_short, step 2.2c, D-034). For every mutant of scripts/mutants.txt whose file is one
of a harness's RTL files, the script copies that file into sim/fv_mut/<harness>/<id>/,
applies the edit there, writes a copy of the harness's .sby whose [files] section points at
the mutated copy, and runs the harness's task with SymbiYosys. The source tree is never
modified (checked by digest).

Classification
    detected    the BMC task ends with FAIL (an assertion is violated; the first failing
                assertion is reported so it can be compared with the mutant's description)
    survived    the BMC task passes: a gap in the harness
    error       SymbiYosys ends with ERROR or UNKNOWN, or no result line (not a detection)
    unapplied   the original text is missing or not unique, or the edit changes nothing
Each unmutated harness runs first and must PASS (otherwise exit 2).

Usage: python scripts/formal_mutants.py [ID ...] [--jobs N] [--task bmc|prove] [--harness NAME]
Default: every harness, every mutant of its files, its default task, 8 parallel jobs.
Results: sim/fv_mut/<harness>/summary.txt. Exit status 1 if any mutant is not detected.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import mutate  # noqa: E402  (shares the mutant file parser)

OSS = Path(os.environ.get("OSS_CAD_SUITE", "C:/oss-cad-suite"))
# name: (job file, RTL files the mutants may target, default task)
HARNESSES = {
    "px_csr": (ROOT / "tb" / "formal" / "px_csr.sby", ["rtl/core/px_csr.sv", "rtl/core/px_csr_m.sv"], "bmc"),
    "px_clic": (ROOT / "tb" / "formal" / "px_clic.sby", ["rtl/irq/px_clic.sv"], "bmc_short"),
}
RESULT = re.compile(r"DONE \((PASS|FAIL|ERROR|UNKNOWN)")
ASSERT = re.compile(r"Assert failed in \S+ (\S+)")


def env():
    e = dict(os.environ)
    e["PATH"] = os.pathsep.join([str(OSS / "bin"), str(OSS / "lib"), e.get("PATH", "")])
    return e


def job_text(sby, mutated_rel=None, mutated_abs=None):
    out = []
    for ln in sby.read_text().splitlines():
        if mutated_rel is not None and ln.strip() == mutated_rel:
            ln = str(mutated_abs).replace("\\", "/")
        out.append(ln)
    return "\n".join(out) + "\n"


def run_sby(work, text, task):
    job = work / "job.sby"
    job.write_bytes(text.encode())
    t0 = time.monotonic()
    r = subprocess.run([str(OSS / "bin" / "sby.exe"), "-f", "--prefix", str(work / "run"), str(job), task],
                       cwd=ROOT, capture_output=True, text=True, env=env())
    out = r.stdout + r.stderr
    (work / f"{task}.log").write_bytes(out.encode())
    m = RESULT.findall(out)
    res = m[-1] if m else "NONE"
    a = ASSERT.search(out)
    return res, (a.group(1) if a else ""), time.monotonic() - t0


def run_harness(name, ids, jobs, task_opt):
    sby, files, default_task = HARNESSES[name]
    task = task_opt or default_task
    work_root = ROOT / "sim" / "fv_mut" / name
    muts = [m for m in mutate.parse(ROOT / "scripts" / "mutants.txt") if m["file"] in files]
    if ids:
        muts = [m for m in muts if m["id"] in ids]
    before = {f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files}

    work_root.mkdir(parents=True, exist_ok=True)
    base = work_root / "_baseline"
    shutil.rmtree(base, ignore_errors=True)
    base.mkdir(parents=True)
    res, _, sec = run_sby(base, job_text(sby), task)
    print(f"baseline {name} {task}: {res} in {sec:.0f} s", flush=True)
    if res != "PASS":
        print(f"ERROR: the unmutated harness does not pass (see {base / (task + '.log')})")
        return 2

    def one(m):
        work = work_root / m["id"]
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        src = (ROOT / m["file"]).read_text()
        if m["old"] is None or m["new"] is None or src.count(m["old"]) != 1:
            return m, "unapplied", f"original text found {src.count(m['old']) if m['old'] else 0} times", 0
        mutated = src.replace(m["old"], m["new"])
        if mutated == src:
            return m, "unapplied", "edit changes nothing", 0
        mpath = work / Path(m["file"]).name
        mpath.write_bytes(mutated.encode())
        res, where, sec = run_sby(work, job_text(sby, m["file"], mpath), task)
        status = {"FAIL": "detected", "PASS": "survived"}.get(res, "error")
        return m, status, (f"assertion {where}" if where else f"sby {res}"), sec

    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        results = list(ex.map(one, muts))
    lines = [f"{name} formal harness ({task}) against the {name} mutants of scripts/mutants.txt "
             f"({time.strftime('%Y-%m-%d %H:%M')})"]
    width = max([22] + [len(f) for f in files])
    for m, status, detail, sec in results:
        lines.append(f"{m['id']:<5} {status:<10} {sec:5.0f} s  {m['file']:<{width}} {detail}  "
                     f"[{' / '.join(m['note'][:1])}]")
    ndet = sum(1 for _, st, _, _ in results if st == "detected")
    lines.append(f"{ndet}/{len(results)} detected, wall clock {time.monotonic() - t0:.0f} s")
    after = {f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files}
    if before != after:
        lines.append("ERROR: a source file changed during the run")
    text = "\n".join(lines) + "\n"
    print(text, end="")
    (work_root / "summary.txt").write_bytes(text.encode())
    return 0 if ndet == len(results) and before == after else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--task", default=None, choices=["bmc", "bmc_short", "prove"])
    ap.add_argument("--harness", default=None, choices=sorted(HARNESSES))
    a = ap.parse_args()

    names = [a.harness] if a.harness else list(HARNESSES)
    if a.ids:
        known = {m["id"]: m["file"] for m in mutate.parse(ROOT / "scripts" / "mutants.txt")}
        missing = sorted(i for i in a.ids if i not in known or
                         not any(known[i] in HARNESSES[n][1] for n in names))
        if missing:
            sys.exit(f"no formal-harness mutant {', '.join(missing)} in scripts/mutants.txt")
        names = [n for n in names if any(known[i] in HARNESSES[n][1] for i in a.ids)]
    rc = 0
    for n in names:
        r = run_harness(n, a.ids, a.jobs, a.task)
        if r == 2:
            return 2
        rc = max(rc, r)
    return rc


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
