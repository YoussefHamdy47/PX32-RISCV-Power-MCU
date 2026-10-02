#!/usr/bin/env python3
"""Step 1.9: compare PX32 retirement traces with the Spike reference (DECISIONS.md D-026).

For every program of the selected suites:
  1. run it on tb/compliance/tb_compliance.sv (px_core RTL) in ideal memory and with random
     bus stalls (--stress SEED), each writing a trace (pc, insn, rd, value, CSR write; traps)
  2. run it on Spike (scripts/compliance/run_spike_wsl.sh, the pinned build and the D-026
     configuration) inside WSL, bounded by the PX32 event count plus a margin
  3. compare each PX32 trace with Spike's log (scripts/compliance/trace_compare.py)
Suites:
  riscv-tests  pinned riscv-tests (D-024): rv32ui, rv32um, rv32uc required; rv32mi informational.
               Built as scripts/compliance/run_riscv_tests.py builds them.
  act4         riscv-arch-test 4.1.0 ELFs (--elf-dir, MANIFEST.txt checked as run_act4.py does):
               I, M, Zca, Zicsr, Zifencei required; every other built ELF informational.
  random       the long random programs (tb/core/programs/list_random_long.txt), on the tb_core
               map (tb_compliance +core_map, Spike map "core"); required. Their ELFs come from
               scripts/build_core_tests.sh (sim/prog/), and their loadable contents must equal
               the committed images that regression runs.
  probe        sw/compliance/spike/csr_probe.S, once per section: the D-022-vs-Spike
               classification evidence; informational.
Result per program: MATCH, or a difference. A required program must match in both memory
modes unless it is listed in KNOWN (an exclusion by design). An informational program that
differs must be listed in KNOWN, and its first mismatch must contain the listed signature;
a listed program that matches, or differs in another way, fails the run (stale or
unexplained). Fail closed: a missing ELF, image or trace, a bench failure, a Spike run that
produced no log, and every trace_compare failure count as differences.

Outputs: sim/compliance/trace/ (per program: PX32 traces, Spike log (gzip), compare reports;
summary.txt, results.json).

Usage: python scripts/compliance/run_trace_compare.py [--suites riscv-tests,act4,random,probe]
           [--elf-dir C:/px32-tools/act4-elfs] [--stress 4660] [--only NAME] [--jobs 8]
"""

import argparse
import concurrent.futures as cf
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/compliance"))
import run_riscv_tests as rt          # noqa: E402
import run_act4 as ra                 # noqa: E402
import trace_compare as tc            # noqa: E402

OUT = ROOT / "sim/compliance/trace"
WSL = ["wsl.exe", "-d", "Ubuntu-24.04", "--"]
MARGIN = 2000                         # Spike events beyond the PX32 event count
PROGS = ROOT / "tb/core/programs"
PROBE = ROOT / "sw/compliance/spike/csr_probe.S"
PROBE_SECTIONS = range(1, 18)
CORE_TOHOST = 0x2000FFF0

# Known differences: name -> (D-026 class, explanation, signature of the first mismatch).
# Every entry must still differ, with this signature (otherwise the run fails as stale).
KNOWN = {
    # D-022 choices Spike cannot be configured to follow (probe sections, one difference each)
    "csr_probe_s02": ("C1 marchid", "Spike's marchid is 5 (its registered architecture ID, a constant); "
                      "PX32 reads 0 (D-022)", "x8 value: px32 00000000, spike 00000005"),
    "csr_probe_s04": ("C2 misa", "Spike's misa is writable (M and C can be cleared); PX32 ignores writes (D-022)",
                      "CSR 301 value: px32 40001104, spike 40000100"),
    "csr_probe_s05": ("C3 mie", "Spike implements MSIE/MTIE/MEIE as writable; PX32 has no interrupt source "
                      "before the CLIC, so mie is read-only 0 (D-022)", "CSR 304 value: px32 00000000, spike 00000888"),
    "csr_probe_s06": ("C4 mtvec MODE", "Spike keeps MODE = Vectored; PX32 is Direct only (D-022)",
                      "CSR 305 value: px32 10000040, spike 10000041"),
    "csr_probe_s10": ("C6 trigger CSRs", "Spike implements tselect (and tdata1-3/tinfo as zero) even with "
                      "--triggers=0; PX32 has no trigger module before Phase 7 (illegal, D-022)",
                      "px32 has a trap, spike a retirement"),
    "csr_probe_s15": ("C7 PMP CSRs", "with zero PMP entries Spike does not implement the PMP CSRs (illegal); "
                      "PX32 implements them as read-only 0 (D-022). Comparison rule R1 covers the riscv-tests "
                      "reset code; the probe's handler skips the access instead, so R1 cannot resynchronise",
                      "R1: px32 does not reach the Spike trap target"),
    # riscv-tests rv32mi (informational): the same classes in the suite's own tests
    "rv32mi-p-breakpoint": ("C6 trigger CSRs", "csrw tselect: illegal on PX32, implemented in Spike",
                            "px32 has a trap, spike a retirement"),
    "rv32mi-p-mcsr": ("C1 marchid", "the test reads marchid", "x10 value: px32 00000000, spike 00000005"),
    "rv32mi-p-ma_fetch": ("C2 misa", "the test clears misa.C to check IALIGN; PX32 ignores misa writes",
                          "CSR 301 value: px32 40001104, spike 40001100"),
    "rv32mi-p-pmpaddr": ("C7 PMP CSRs", "the test programs PMP entries (it assumes PMP exists); Spike with zero "
                         "entries traps on pmpcfg0 where PX32 reads 0, and the test then branches",
                         "R1: px32 does something other than straight-line code"),
    # riscv-arch-test 4.1.0 informational groups
    "Sm_mcsr_access-00": ("C3 mie", "the test writes all mie bits", "CSR 304 value: px32 00000000, spike 00000888"),
    "Sm_mcsr_walk-01": ("C3 mie", "walking ones through mie", "CSR 304 value: px32 00000000, spike 00000008"),
    "Sm_misa-00": ("C2 misa", "the test writes misa", "CSR 301 value: px32 40001104, spike 40000100"),
    "csr_probe_s17": ("C8 mcause WLRL", "an illegal mcause value: PX32 keeps bit 31 and the code bits [4:0], "
                      "Spike keeps all bits (WLRL: either is legal)", "CSR 342 value: px32 0000001f, spike 7fffffff"),
}


def wsl_path(p):
    p = Path(p).resolve()
    return "/mnt/" + p.drive[0].lower() + p.as_posix()[2:]


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


# ---------------------------------------------------------------------------------------
# Case collection
# ---------------------------------------------------------------------------------------
def riscv_tests_cases(suite):
    head, env = rt.git_head(suite), rt.git_head(suite / "env")
    if head != rt.SUITE_COMMIT or env != rt.ENV_COMMIT:
        sys.exit(f"FAIL riscv-tests not at the pinned commits ({head}, env {env})")
    cases = []
    for g in rt.REQUIRED + rt.INFORMATIONAL:
        gdir = suite / "isa" / g
        listed = rt.makefrag_tests(gdir, g)
        if not listed:
            sys.exit(f"FAIL no test list for {g}")
        for t in listed:
            name = f"{g}-p-{t}"
            work = OUT / "riscv-tests" / g / t
            image, tohost, err = rt.build(gdir / f"{t}.S", suite, work)
            cases.append({"name": name, "suite": "riscv-tests", "group": g,
                          "required": g in rt.REQUIRED, "work": work, "elf": work / f"{t}.elf",
                          "image": image, "halt": int(tohost, 16) if tohost else None,
                          "map": "compliance", "error": err})
    return cases


def act4_cases(elf_dir, suite):
    head = rt.git_head(suite)
    if head != ra.SUITE_COMMIT:
        sys.exit(f"FAIL riscv-arch-test at {head}, expected {ra.SUITE_COMMIT}")
    stale = ra.manifest_problems(elf_dir)
    if stale:
        sys.exit("FAIL stale or unidentified ELF set:\n  " + "\n  ".join(stale))
    elfs = {p.stem: p for p in elf_dir.rglob("*.elf")}
    cases, used = [], set()
    for g in ra.REQUIRED:
        srcs = sorted(p.stem for p in (suite / "tests/rv32i" / g).glob("*.S"))
        if not srcs:
            sys.exit(f"FAIL no ACT4 sources for {g}")
        for t in srcs:
            used.add(t)
            cases.append(act4_case(t, g, True, elfs.get(t)))
    for t in sorted(set(elfs) - used):
        cases.append(act4_case(t, "other", False, elfs[t]))
    return cases


def act4_case(t, g, required, elf):
    work = OUT / "act4" / g / t
    work.mkdir(parents=True, exist_ok=True)
    c = {"name": t, "suite": "act4", "group": g, "required": required, "work": work, "elf": elf,
         "image": work / "image.hex", "halt": int(ra.HALT, 16), "map": "compliance", "error": None,
         "console": ra.CONSOLE}
    if elf is None:
        c["error"] = "no ELF built"
        return c
    r = sh([sys.executable, str(ROOT / "scripts/compliance/elf2mem.py"), str(elf), str(c["image"])])
    if r.returncode != 0:
        c["error"] = "image: " + (r.stdout + r.stderr).strip()
    return c


def random_cases():
    lst = PROGS / "list_random_long.txt"
    names = [n for n in lst.read_text().split() if n] if lst.exists() else []
    if not names:
        sys.exit(f"FAIL no long random programs listed in {lst}")
    cases = []
    for n in names:
        work = OUT / "random" / n
        work.mkdir(parents=True, exist_ok=True)
        elf = ROOT / "sim/prog" / f"{n}.elf"
        c = {"name": n, "suite": "random", "group": "random", "required": True, "work": work,
             "elf": elf, "image": PROGS / f"{n}.itcm.hex", "dtcm": PROGS / f"{n}.dtcm.hex",
             "halt": CORE_TOHOST, "map": "core", "error": None}
        if not elf.is_file():
            c["error"] = f"no ELF {elf}: run scripts/build_core_tests.sh"
        else:
            r = sh([sys.executable, str(ROOT / "scripts/elf2hex.py"), str(elf), str(work / n)])
            if r.returncode != 0:
                c["error"] = "elf2hex: " + (r.stdout + r.stderr).strip()
            else:
                for part in ("itcm", "dtcm"):
                    if (work / f"{n}.{part}.hex").read_bytes() != (PROGS / f"{n}.{part}.hex").read_bytes():
                        c["error"] = f"ELF {elf} differs from the committed {part} image: rebuild"
        cases.append(c)
    return cases


def probe_cases():
    cases = []
    for sec in PROBE_SECTIONS:
        name = f"csr_probe_s{sec:02d}"
        work = OUT / "probe" / name
        work.mkdir(parents=True, exist_ok=True)
        elf = work / f"{name}.elf"
        cmd = [str(rt.GCC), "-march=rv32imc_zicsr_zifencei", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
               f"-T{rt.LINK}", f"-DONLY={sec}", str(PROBE), "-o", str(elf)]
        r = sh(cmd)
        c = {"name": name, "suite": "probe", "group": "probe", "required": False, "work": work,
             "elf": elf, "image": work / "image.hex", "halt": None, "map": "compliance", "error": None}
        if r.returncode != 0:
            c["error"] = "build: " + (r.stdout + r.stderr).strip()
        else:
            r = sh([sys.executable, str(ROOT / "scripts/compliance/elf2mem.py"), str(elf), str(c["image"]), "tohost"])
            if r.returncode != 0:
                c["error"] = "image: " + (r.stdout + r.stderr).strip()
            else:
                c["halt"] = int(r.stdout.split()[1], 16)
        cases.append(c)
    return cases


# ---------------------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------------------
def run_dut(vvp, c, stress):
    tag = "ideal" if stress is None else f"stress{stress}"
    trace = c["work"] / f"px32_{tag}.trace"
    args = [rt.VVP, "-n", str(vvp), f"+image={c['image']}", f"+tohost={c['halt']:08x}",
            f"+name={c['name']}", f"+trace={trace}"]
    if c["map"] == "core":
        args += ["+core_map", f"+dtcm_image={c['dtcm']}"]
    if c.get("console"):
        args.append(f"+console={c['console']}")
    if stress is not None:
        args.append(f"+stress={stress}")
    if trace.exists():
        trace.unlink()
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=rt.WALL_LIMIT, cwd=ROOT)
        out = p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        out = f"wall-clock limit {rt.WALL_LIMIT} s"
    (c["work"] / f"px32_{tag}.log").write_text(out)
    res = [ln for ln in out.splitlines() if re.match(r"^(PASS|FAIL|TIMEOUT) tb_compliance ", ln)]
    # a test may legitimately fail on PX32 (e.g. an unsupported feature): the trace is still
    # compared; only a bench problem (no halt store, X, deadlock, timeout) is an error here
    halted = bool(res) and (res[0].startswith("PASS") or "tohost" in res[0])
    return trace, (res[0] if res else "no result line"), halted


def run_spike(cases):
    jobs = OUT / "spike_jobs.txt"
    lines = []
    for c in cases:
        if c.get("spike_n"):
            c["spike_log"] = c["work"] / "spike.log.gz"
            if c["spike_log"].exists():
                c["spike_log"].unlink()
            # at most three log lines per event (disassembly, commit or exception, tval)
            lines.append(f"{wsl_path(c['elf'])} {c['map']} {c['halt']:08x} {3 * c['spike_n']} "
                         f"{wsl_path(c['spike_log'])}")
    if not lines:
        return
    jobs.write_bytes(("\n".join(lines) + "\n").encode())
    r = sh(WSL + ["bash", wsl_path(ROOT / "scripts/compliance/run_spike_wsl.sh"), wsl_path(jobs)],
           env={**__import__("os").environ, "MSYS_NO_PATHCONV": "1"})
    if r.returncode != 0:
        sys.exit("FAIL Spike batch: " + (r.stdout + r.stderr).strip())


def classify(c, results):
    """Outcome of one program: 'match', 'known' (listed difference, signature seen) or 'fail'."""
    k = KNOWN.get(c["name"])
    bad = [r for r in results if not r["ok"]]
    if not bad:
        return ("fail", f"listed in KNOWN ({k[0]}) but matches: stale entry") if k else ("match", results[0]["msg"])
    if k:
        # every run (ideal and stress) must show the listed difference first
        other = [r for r in results if r["ok"] or k[2] not in r["msg"]]
        if not other:
            return "known", f"{k[0]}: {k[1]}"
        return "fail", f"listed as {k[0]}, but run {other[0]['run']}: {other[0]['msg']}"
    return "fail", f"run {bad[0]['run']}: {bad[0]['msg']}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suites", default="riscv-tests,act4,random,probe")
    ap.add_argument("--elf-dir", type=Path, default=Path("C:/px32-tools/act4-elfs"))
    ap.add_argument("--rt-suite", type=Path, default=rt.SUITE_DEFAULT)
    ap.add_argument("--act-suite", type=Path, default=Path("C:/px32-tools/src/riscv-arch-test"))
    ap.add_argument("--stress", type=int, default=4660)
    ap.add_argument("--only", default=None)
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    suites = a.suites.split(",")
    OUT.mkdir(parents=True, exist_ok=True)
    vvp = rt.compile_bench()
    cases = []
    if "riscv-tests" in suites:
        cases += riscv_tests_cases(a.rt_suite)
    if "act4" in suites:
        cases += act4_cases(a.elf_dir, a.act_suite)
    if "random" in suites:
        cases += random_cases()
    if "probe" in suites:
        cases += probe_cases()
    if a.only:
        cases = [c for c in cases if re.fullmatch(a.only, c["name"])]
    if not cases:
        sys.exit("FAIL no programs selected")
    print(f"{len(cases)} programs; PX32 runs (ideal, stress {a.stress}) ...", flush=True)

    def dut_both(c):
        if c["error"]:
            return
        c["runs"] = {}
        for s in (None, a.stress):
            c["runs"]["ideal" if s is None else f"stress{s}"] = run_dut(vvp, c, s)
        n = max((sum(1 for _ in open(t)) if t.exists() else 0) for t, _, _ in c["runs"].values())
        c["spike_n"] = n + MARGIN
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        list(ex.map(dut_both, cases))
    print("Spike runs ...", flush=True)
    run_spike(cases)

    ok = True
    rows = []
    for c in cases:
        if c["error"]:
            outcome, detail, results = "fail", c["error"], []
        else:
            results = []
            for tag, (trace, res, halted) in c["runs"].items():
                if not halted:
                    r = {"run": tag, "ok": False, "msg": f"FAIL px32 {tag}: {res}"}
                else:
                    good, msg, stats = tc.run(trace, c["spike_log"], c["halt"])
                    r = {"run": tag, "ok": good, "msg": msg, "stats": stats, "px32": res}
                (c["work"] / f"compare_{tag}.txt").write_text(r["msg"] + "\n")
                results.append(r)
            outcome, detail = classify(c, results)
        if outcome == "fail":
            ok = False
        rows.append({"name": c["name"], "suite": c["suite"], "group": c["group"], "required": c["required"],
                     "outcome": outcome, "detail": detail, "runs": results})
        print(f"  {c['suite']:<11} {c['group']:<8} {c['name']:<34} {outcome.upper():<6} {detail.splitlines()[0]}",
              flush=True)

    lines = [f"step 1.9 trace comparison against Spike (D-026); PX32 ideal memory and stress seed {a.stress}",
             f"{'suite':<12} {'group':<9} {'req':>3} {'programs':>8} {'match':>6} {'known':>6} {'fail':>5}"]
    groups = {}
    for r in rows:
        groups.setdefault((r["suite"], r["group"], r["required"]), []).append(r)
    for (s, g, req), rs in groups.items():
        lines.append(f"{s:<12} {g:<9} {'yes' if req else 'no':>3} {len(rs):>8} "
                     f"{sum(x['outcome'] == 'match' for x in rs):>6} {sum(x['outcome'] == 'known' for x in rs):>6} "
                     f"{sum(x['outcome'] == 'fail' for x in rs):>5}")
    for r in rows:
        if r["outcome"] != "match":
            lines.append(f"  {r['outcome']:<5} {r['name']}: {r['detail'].splitlines()[0]}")
    lines.append(("PASS" if ok else "FAIL") + " trace comparison" + (f" (--only {a.only})" if a.only else ""))
    print("\n".join(lines))
    tagname = "" if not a.only else "_only"
    (OUT / f"summary{tagname}.txt").write_text("\n".join(lines) + "\n")
    (OUT / f"results{tagname}.json").write_text(json.dumps(rows, indent=1, default=str))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
