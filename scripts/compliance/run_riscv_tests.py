#!/usr/bin/env python3
"""Run the riscv-tests p-variant ISA tests on PX32 (step 1.8, riscv-tests part).

Suite: riscv-software-src/riscv-tests at the pinned commit, with its env submodule
(riscv/riscv-test-env) at the commit the suite pins. Tests are built exactly as the upstream
isa/Makefile builds them for RV32 (flags below), with the upstream env/p/riscv_test.h and
isa/macros/scalar/test_macros.h unmodified; only the linker script is PX32's
(sw/compliance/riscv-tests/link.ld: the upstream layout rebased to 0x1000_0000). Each ELF
runs on tb/compliance/tb_compliance.sv (px_core RTL, Icarus): PASS means the test stored 1
to tohost.

Fail closed:
  - the suite or env checkout is not at the pinned commit
  - a group's Makefrag list and its .S files disagree, or a group has no tests
  - a test does not build, has no tohost symbol, or its image does not fit
  - the bench reports anything but its PASS line, exits nonzero, or exceeds the
    wall-clock limit
  - an expected-unsupported test (sw/compliance/riscv-tests/exclusions.txt) passes: the
    exclusion is then stale
Required groups: rv32ui, rv32um, rv32uc (IMPLEMENTATION_GUIDE.md step 1.8). rv32mi
(machine-mode tests) runs as an informational group: its results are reported separately and
never change the exit status.

Outputs: sim/compliance/riscv-tests/ (builds, images, logs, traces, results.json,
summary.txt); nothing is written outside sim/.

Usage: python scripts/compliance/run_riscv_tests.py [--suite DIR] [--stress SEED]
                                                     [--only TEST] [--selftest]
Exit status 0 only if every required, non-excluded test passes.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUITE_DEFAULT = Path("C:/px32-tools/src/riscv-tests")
SUITE_COMMIT = "bcffa2b3188b040c611f90dc0b6e422f54775a09"
ENV_COMMIT = "6de71edb142be36319e380ce782c3d1830c65d68"
BIN = Path("C:/xpack/xpack-riscv-none-elf-gcc-15.2.0-1/bin")
GCC = BIN / "riscv-none-elf-gcc.exe"
IVERILOG = "C:/iverilog/bin/iverilog"
VVP = "C:/iverilog/bin/vvp"
# upstream isa/Makefile: compile_template for rv32ui/rv32uc/rv32um/rv32mi
MARCH = ["-march=rv32g", "-mabi=ilp32"]
GCC_OPTS = ["-static", "-mcmodel=medany", "-fvisibility=hidden", "-nostdlib", "-nostartfiles"]
REQUIRED = ["rv32ui", "rv32um", "rv32uc"]
INFORMATIONAL = ["rv32mi"]
WALL_LIMIT = 300          # seconds per test run
OUT = ROOT / "sim/compliance/riscv-tests"
LINK = ROOT / "sw/compliance/riscv-tests/link.ld"
EXCL = ROOT / "sw/compliance/riscv-tests/exclusions.txt"


def git_head(path):
    r = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def makefrag_tests(group_dir, group):
    """The <group>_sc_tests list of the group's Makefrag."""
    text = (group_dir / "Makefrag").read_text()
    m = re.search(rf"^{group}_sc_tests\s*=(.*?)(?:\n\s*\n|\Z)", text, re.S | re.M)
    if not m:
        return None
    return m.group(1).replace("\\", " ").split()


def load_exclusions():
    out = {}
    if EXCL.exists():
        for ln in EXCL.read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                parts = ln.split(None, 2)
                out[(parts[0], parts[1])] = parts[2] if len(parts) > 2 else ""
    return out


def compile_bench():
    OUT.mkdir(parents=True, exist_ok=True)
    fl = [ROOT / p for p in (ROOT / "tb/compliance/tb_compliance.f").read_text().split()
          if not p.startswith("#")]
    vvp = OUT / "tb_compliance.vvp"
    r = subprocess.run([IVERILOG, "-g2012", "-Wall", "-o", str(vvp), "-s", "tb_compliance",
                        *map(str, fl)], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or r.stdout.strip() or r.stderr.strip():
        sys.exit("tb_compliance does not compile cleanly:\n" + r.stdout + r.stderr)
    return vvp


def build(src, suite, work, extra_inc=()):
    work.mkdir(parents=True, exist_ok=True)
    elf = work / (src.stem + ".elf")
    inc = [f"-I{suite / 'env/p'}", f"-I{suite / 'isa/macros/scalar'}", *[f"-I{i}" for i in extra_inc]]
    cmd = [str(GCC), *MARCH, *GCC_OPTS, *inc, f"-T{LINK}", str(src), "-o", str(elf)]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=src.parent)
    (work / "build.log").write_text(" ".join(cmd) + "\n" + r.stdout + r.stderr)
    if r.returncode != 0:
        return None, None, "build failed"
    subprocess.run([str(BIN / "riscv-none-elf-objdump"), "-d", "-M", "no-aliases,numeric", str(elf)],
                   stdout=open(work / (src.stem + ".dis"), "w"))
    r = subprocess.run([sys.executable, str(ROOT / "scripts/compliance/elf2mem.py"), str(elf),
                        str(work / "image.hex"), "tohost"], capture_output=True, text=True)
    if r.returncode != 0:
        return None, None, "image/tohost: " + (r.stdout + r.stderr).strip()
    tohost = r.stdout.split()[1]
    return work / "image.hex", tohost, None


def run(vvp, image, tohost, name, work, stress=None):
    tag = "ideal" if stress is None else f"stress{stress}"
    log = work / f"run_{tag}.log"
    args = [VVP, "-n", str(vvp), f"+image={image}", f"+tohost={tohost}", f"+name={name}",
            f"+trace={work / f'trace_{tag}.txt'}"]
    if stress is not None:
        args.append(f"+stress={stress}")
    t0 = time.monotonic()
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=WALL_LIMIT, cwd=ROOT)
        out, rc = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        log.write_text("wall-clock limit exceeded\n")
        return "fail", f"wall-clock limit {WALL_LIMIT} s", log
    log.write_text(out)
    lines = [ln for ln in out.splitlines() if re.match(r"^(PASS|FAIL|TIMEOUT) tb_compliance ", ln)]
    ok = (rc == 0 and len(lines) == 1 and lines[0].startswith(f"PASS tb_compliance {name} ")
          and not re.search(r"^(ERROR|FATAL|FAIL|TIMEOUT)", out, re.M))
    detail = lines[0] if lines else (out.strip().splitlines() or ["no result line"])[-1]
    return ("pass" if ok else "fail"), f"{detail} [{time.monotonic() - t0:.1f} s]", log


def run_group(group, suite, vvp, excl, stress, only):
    gdir = suite / "isa" / group
    listed = makefrag_tests(gdir, group) if (gdir / "Makefrag").exists() else None
    files = sorted(p.stem for p in gdir.glob("*.S"))
    res = {"group": group, "makefrag": listed, "files": files, "tests": [], "problems": []}
    if not listed:
        res["problems"].append("no test list in Makefrag")
        return res
    if sorted(listed) != files:
        res["problems"].append(f"Makefrag list and .S files differ: only listed {sorted(set(listed) - set(files))}, "
                               f"only files {sorted(set(files) - set(listed))}")
    for t in listed:
        if only and t != only:
            continue
        name = f"{group}-p-{t}"
        work = OUT / group / t
        entry = {"test": name, "excluded": excl.get((group, t)), "runs": {}}
        src = gdir / f"{t}.S"
        if not src.exists():
            entry["result"], entry["detail"] = "fail", "source missing"
        else:
            image, tohost, err = build(src, suite, work)
            if err:
                entry["result"], entry["detail"] = "fail", err
            else:
                st, det, log = run(vvp, image, tohost, name, work)
                entry["runs"]["ideal"] = {"result": st, "detail": det, "log": str(log.relative_to(ROOT))}
                if stress is not None and st == "pass":
                    st2, det2, log2 = run(vvp, image, tohost, name, work, stress)
                    entry["runs"][f"stress{stress}"] = {"result": st2, "detail": det2,
                                                        "log": str(log2.relative_to(ROOT))}
                    if st2 != "pass":
                        st, det = st2, det2
                entry["result"], entry["detail"] = st, det
        tag = entry["result"].upper()
        if entry["excluded"] is not None:
            tag += " (expected unsupported)"
        print(f"  {name:<24} {tag:<32} {entry['detail']}", flush=True)
        res["tests"].append(entry)
    return res


def selftest(suite, vvp):
    """The runner's own fail-closed checks: fixtures with known outcomes."""
    fx = ROOT / "sw/compliance/selftest"
    expect = {"st_pass": "pass", "st_fail": "fail", "st_hang": "fail", "st_notohost": "fail",
              "st_badbuild": "fail", "st_trapstorm": "fail"}
    ok = True
    for t, want in expect.items():
        work = OUT / "selftest" / t
        image, tohost, err = build(fx / f"{t}.S", suite, work, extra_inc=[fx])
        if err:
            got, det = "fail", err
        else:
            got, det, _ = run(vvp, image, tohost, t, work)
        good = got == want
        ok &= good
        print(f"  selftest {t:<14} expected {want:<5} got {got:<5} {'ok' if good else 'MISMATCH'}  {det}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", type=Path, default=SUITE_DEFAULT)
    ap.add_argument("--stress", type=int, default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    head, env = git_head(a.suite), git_head(a.suite / "env")
    if head != SUITE_COMMIT or env != ENV_COMMIT:
        sys.exit(f"FAIL suite not at the pinned commits: riscv-tests {head} (want {SUITE_COMMIT}), "
                 f"env {env} (want {ENV_COMMIT})")
    vvp = compile_bench()
    if a.selftest:
        ok = selftest(a.suite, vvp)
        print("PASS runner selftest" if ok else "FAIL runner selftest")
        return 0 if ok else 1
    excl = load_exclusions()
    results, ok = [], True
    for g in REQUIRED + INFORMATIONAL:
        print(f"{g}{' (informational)' if g in INFORMATIONAL else ''}:", flush=True)
        r = run_group(g, a.suite, vvp, excl, a.stress, a.only)
        r["informational"] = g in INFORMATIONAL
        results.append(r)
    lines = [f"riscv-tests {SUITE_COMMIT} (env {ENV_COMMIT}), flags {' '.join(MARCH + GCC_OPTS)}",
             f"{'group':<8} {'listed':>6} {'run':>5} {'pass':>5} {'fail':>5} {'unsup':>6}  status"]
    for r in results:
        t = r["tests"]
        req = [x for x in t if x["excluded"] is None]
        uns = [x for x in t if x["excluded"] is not None]
        npass = sum(x["result"] == "pass" for x in req)
        nfail = len(req) - npass
        stale = [x["test"] for x in uns if x["result"] == "pass"]
        good = not r["problems"] and len(req) > 0 and nfail == 0 and not stale and \
            (not a.only or len(t) > 0)
        if a.only:
            good = not r["problems"] and nfail == 0 and not stale
        if not r["informational"] and not good:
            ok = False
        status = ("ok" if good else "FAIL") + (" (informational)" if r["informational"] else "")
        extra = "; ".join(r["problems"] + [f"stale exclusion: {s}" for s in stale])
        lines.append(f"{r['group']:<8} {len(r['makefrag'] or []):>6} {len(t):>5} {npass:>5} {nfail:>5} "
                     f"{len(uns):>6}  {status} {extra}")
        for x in uns:
            lines.append(f"         unsupported {x['test']}: {x['excluded']} (ran: {x['result']})")
        for x in req:
            if x["result"] != "pass":
                lines.append(f"         failed {x['test']}: {x['detail']}")
    if a.only:
        matched = sum(len(r["tests"]) for r in results)
        ok = ok and matched > 0
        lines.append(("ONLY-RUN ok" if ok else "FAIL") + f" (--only {a.only}: {matched} test(s); not a suite result)")
    else:
        lines.append(("PASS" if ok else "FAIL") + " riscv-tests (required groups rv32ui, rv32um, rv32uc)")
    print("\n".join(lines))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "summary.txt").write_text("\n".join(lines) + "\n")
    (OUT / "results.json").write_text(json.dumps({"suite_commit": SUITE_COMMIT, "env_commit": ENV_COMMIT,
                                                  "flags": MARCH + GCC_OPTS, "groups": results}, indent=1))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
