#!/usr/bin/env python3
"""Mutation check: does each testbench detect the planted bugs listed in scripts/mutants.txt?

The source tree is never modified. For each mutant the script copies the named file into
sim/mutants/<id>/, applies the edit there, writes a source list that points at the copy,
and compiles and runs the listed testbenches (in order, until one fails).

Mutant file format (scripts/mutants.txt):
    [ID] path/to/file.sv tb_a[,tb_b...] [equivalent]
    - exact original text (must occur exactly once; "\\n" stands for a line break)
    + replacement text
    # what the bug is (optional, any number of lines)

Classification
    killed                  a testbench failed with a diagnostic (ERROR/FAIL/FATAL line; the
                            first one is reported for review)
    killed (bench timeout)  the testbench itself detected a deadlock or its cycle limit
                            (TIMEOUT, "deadlock", "timeout:" diagnostics): a legitimate
                            detection by the bench
    inconclusive            the simulator hit the external wall-clock limit without any
                            diagnostic, also when rechecked (see below). Not a detection:
                            excluded from the confirmed totals, and the run fails
    survived                every listed testbench passed: a verification gap, unless the
                            mutant is declared equivalent
    equivalent              declared equivalent and every testbench passed (the claim is not
                            proven by this script; the justification is in the mutant's comment)
    invalid                 the mutated source does not compile (not counted as killed)
    unapplied               the original text is missing or not unique, or the edit changed
                            nothing
A declared-equivalent mutant that is killed is reported as "killed (not equivalent)".

Wall-clock limits: every testbench named by the selected mutants first runs unmutated
(baseline); it must pass, and its time is reported. A mutant that reaches the wall-clock
limit is classified from the diagnostics it printed before it was stopped; with none, it
is rechecked: the unmutated baseline runs again under the same limit (if that also times
out, the machine is overloaded: inconclusive), then the mutant runs again with four times
the limit. Only a diagnostic counts as a detection. Benches get +stop_on_fail so a
detected mutant ends the simulation at its first failing run.

Usage: python scripts/mutate.py [ID ...]     (default: all mutants)
Exit status 1 if any mutant is survived, invalid, unapplied or inconclusive; 2 if a
baseline fails.
"""

import hashlib
import os
import time
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IVERILOG = "C:/iverilog/bin/iverilog"
VVP = "C:/iverilog/bin/vvp"


def parse(path):
    muts, cur = [], None
    for raw in path.read_text().splitlines():
        line = raw.rstrip("\n")
        m = re.match(r"^\[(\S+)\]\s+(\S+)\s+(\S+)(\s+equivalent)?\s*$", line)
        if m:
            cur = {"id": m.group(1), "file": m.group(2), "tests": m.group(3).split(","),
                   "equiv": bool(m.group(4)), "old": None, "new": None, "note": []}
            muts.append(cur)
        elif cur and line.startswith("- "):
            cur["old"] = line[2:].replace("\\n", "\n")
        elif cur and line.startswith("+ "):
            cur["new"] = line[2:].replace("\\n", "\n")
        elif cur and line.startswith("+") and line.strip() == "+":
            cur["new"] = ""
        elif cur and line.startswith("# "):
            cur["note"].append(line[2:])
    ids = [m["id"] for m in muts]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        sys.exit(f"duplicate mutant IDs in {path}: {', '.join(dup)}")
    return muts


def flist(tb):
    for d in ("tb/unit", "tb/core", "tb/soc"):
        p = ROOT / d / f"{tb}.f"
        if p.exists():
            return p
    raise SystemExit(f"no source list for {tb}")


def timeout_of(fl):
    m = re.search(r"^# timeout_seconds: *(\d+)", fl.read_text(), re.M)
    return int(m.group(1)) if m else 60


BENCH_TIMEOUT = re.compile(r"TIMEOUT|deadlock|timeout:|cycle limit", re.I)
DIAG = re.compile(r"^(ERROR|FAIL|FATAL|TIMEOUT)")


def text_of(x):
    if x is None:
        return ""
    return x.decode(errors="replace") if isinstance(x, bytes) else x


def classify_output(out):
    """(status, diagnostics) for a finished or stopped simulation."""
    diag = [ln for ln in out.splitlines() if DIAG.match(ln)]
    if not diag:
        return None, []
    if all(BENCH_TIMEOUT.search(d) for d in diag[:1]):
        return "killed (bench timeout)", diag[:1]
    return "killed", diag[:1]


def compile_tb(tb, mutated_rel, mutated_abs, work):
    fl = flist(tb)
    lines = []
    for ln in fl.read_text().splitlines():
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        if mutated_rel is not None and s == mutated_rel:
            s = str(mutated_abs).replace("\\", "/")
        lines.append(s)
    mf = work / f"{tb}.f"
    mf.write_bytes(("\n".join(lines) + "\n").encode())
    vvp = work / f"{tb}.vvp"
    c = subprocess.run([IVERILOG, "-g2012", "-o", str(vvp), "-s", tb, "-c", str(mf)],
                       cwd=ROOT, capture_output=True, text=True)
    if c.returncode != 0:
        return None, (c.stdout + c.stderr).strip().splitlines()[:1]
    return vvp, []


def simulate(vvp, limit):
    """('pass'|'fail'|'wallclock', output, seconds)."""
    t0 = time.monotonic()
    try:
        r = subprocess.run([VVP, "-n", str(vvp), "+stop_on_fail"], cwd=ROOT,
                           capture_output=True, text=True, timeout=limit)
    except subprocess.TimeoutExpired as e:
        return "wallclock", text_of(e.stdout) + text_of(e.stderr), time.monotonic() - t0
    out = r.stdout + r.stderr
    passed = (r.returncode == 0 and re.search(r"^PASS", out, re.M)
              and not re.search(r"^(FAIL|ERROR|FATAL|TIMEOUT)([ :]|$)", out, re.M))
    return ("pass" if passed else "fail"), out, time.monotonic() - t0


BASELINE = {}      # tb -> (vvp, seconds)


def baseline(tb):
    if tb not in BASELINE:
        work = ROOT / "sim/mutants" / f"_baseline_{tb}"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        vvp, err = compile_tb(tb, None, None, work)
        if vvp is None:
            raise SystemExit(f"baseline {tb} does not compile: {err}")
        st, out, sec = simulate(vvp, timeout_of(flist(tb)))
        if st != "pass":
            print(f"ERROR: unmutated baseline {tb} did not pass ({st}):", flush=True)
            print("\n".join(out.splitlines()[-5:]), flush=True)
            sys.exit(2)
        print(f"baseline {tb}: PASS in {sec:.0f} s (limit {timeout_of(flist(tb))} s)", flush=True)
        BASELINE[tb] = (vvp, sec)
    return BASELINE[tb]


def run_tb(tb, mutated_rel, mutated_abs, work):
    fl = flist(tb)
    limit = timeout_of(fl)
    # Harness self-test hook: force a short first limit for mutant runs only.
    if os.environ.get("PX_MUTATE_TEST_LIMIT"):
        limit = int(os.environ["PX_MUTATE_TEST_LIMIT"])
    vvp, err = compile_tb(tb, mutated_rel, mutated_abs, work)
    if vvp is None:
        return "invalid", err
    st, out, sec = simulate(vvp, limit)
    if st == "pass":
        return "pass", []
    if st == "fail":
        status, diag = classify_output(out)
        return (status or "killed"), (diag or ["nonzero exit / no PASS"])
    # external wall-clock limit
    status, diag = classify_output(out)
    if status:
        return status, [diag[0] + "  (printed before the wall-clock limit)"]
    base_vvp, _ = baseline(tb)
    bst, _, bsec = simulate(base_vvp, limit)
    if bst != "pass":
        return "inconclusive", [f"wall-clock limit {limit} s; the unmutated baseline also "
                                f"failed to finish ({bst}, {bsec:.0f} s): machine load"]
    st, out, sec = simulate(vvp, 4 * limit)
    if st == "pass":
        return "pass", [f"passed on recheck with a {4 * limit} s limit"]
    status, diag = classify_output(out)
    if status:
        return status, [diag[0] + f"  (recheck with a {4 * limit} s limit; baseline {bsec:.0f} s)"]
    return "inconclusive", [f"no diagnostic within {limit} s or {4 * limit} s "
                            f"(baseline {bsec:.0f} s)"]


def digest(files):
    return {f: hashlib.sha256((ROOT / f).read_bytes()).hexdigest() for f in files}


def main():
    muts = parse(ROOT / "scripts/mutants.txt")
    if len(sys.argv) > 1:
        muts = [m for m in muts if m["id"] in sys.argv[1:]]
    before = digest(sorted({m["file"] for m in muts}))
    for tb in sorted({tb for m in muts for tb in m["tests"]}):
        baseline(tb)
    counts = {}
    bad = False
    report = []
    for m in muts:
        src = (ROOT / m["file"]).read_text()
        work = ROOT / "sim/mutants" / m["id"]
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(parents=True)
        detail = []
        if m["old"] is None or m["new"] is None or src.count(m["old"]) != 1:
            status = "unapplied"
            detail = [f"original text found {src.count(m['old']) if m['old'] else 0} times"]
        else:
            mutated = src.replace(m["old"], m["new"])
            if mutated == src:
                status, detail = "unapplied", ["edit changes nothing"]
            else:
                mpath = work / Path(m["file"]).name
                mpath.write_bytes(mutated.encode())
                status = "pass"
                for tb in m["tests"]:
                    status, detail = run_tb(tb, m["file"], mpath, work)
                    if status != "pass":
                        detail = [f"{tb}: {d}" for d in detail]
                        break
                if status == "pass":
                    status = "equivalent" if m["equiv"] else "survived"
                elif status == "killed" and m["equiv"]:
                    status = "killed (not equivalent)"
        counts[status] = counts.get(status, 0) + 1
        if status in ("survived", "invalid", "unapplied", "inconclusive"):
            bad = True
        line = f"{m['id']:<6} {status:<24} {m['file']}  {' / '.join(m['note'][:1])}"
        report.append(line)
        print(line, flush=True)
        for d in detail:
            print(f"         {d[:160]}", flush=True)
    after = digest(sorted(before))
    if before != after:
        print("ERROR: a source file changed during the mutation run")
        bad = True
    print("summary: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    confirmed = sum(v for k, v in counts.items() if k.startswith("killed"))
    print(f"confirmed detections: {confirmed} (diagnostic {counts.get('killed', 0)}, "
          f"bench timeout {counts.get('killed (bench timeout)', 0)}, "
          f"declared equivalent but killed {counts.get('killed (not equivalent)', 0)}); "
          f"inconclusive {counts.get('inconclusive', 0)}")
    return 1 if bad else 0


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main())
