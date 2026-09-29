#!/usr/bin/env python3
"""Generate the PX32 project status dashboard: sim/dashboard/index.html.

Everything shown is read from the repository, so the page cannot drift from the
real state:
  PROGRESS.md              current phase, block status, next action, issues, log
  DECISIONS.md             decision list with tier/status (Proposed = needs owner)
  IMPLEMENTATION_GUIDE.md  phase names
  sim/regress.json         last regression run (written by scripts/regress.sh)
  sim/synth/summary.json   synthesis results (written by scripts/synth.sh)
  rtl/, tb/                source inventory

Standard library only. Run directly or let scripts/regress.sh call it:
    python scripts/gen_dashboard.py
"""

import datetime
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sim" / "dashboard" / "index.html"
LINK_PREFIX = "../../"  # from sim/dashboard/ back to the repo root


# ---------------------------------------------------------------------------
# Minimal Markdown renderer (headings, paragraphs, lists, tables, code, quotes)
# ---------------------------------------------------------------------------
LIST_RE = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)")


def inline(text: str) -> str:
    codes = []

    def stash(m):
        codes.append(m.group(1) if m.group(1) is not None else m.group(2))
        return f"\x00{len(codes) - 1}\x00"

    t = re.sub(r"``\s*(.+?)\s*``|`([^`]+)`", stash, text)
    t = html.escape(t, quote=False)

    def link(m):
        label, href = m.group(1), m.group(2)
        if not re.match(r"^(https?:|#|mailto:)", href):
            href = LINK_PREFIX + href
        return f'<a href="{html.escape(href)}">{label}</a>'

    t = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])", r"<em>\1</em>", t)
    t = re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{html.escape(codes[int(m.group(1))])}</code>", t)
    return t


def render_table(rows):
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    sep = re.compile(r"^:?-{3,}:?$")
    head = cells[0]
    body = [r for r in cells[1:] if not all(sep.match(c.replace(" ", "")) for c in r if c)]
    out = ['<div class="tbl"><table><thead><tr>']
    out += [f"<th>{inline(c)}</th>" for c in head]
    out.append("</tr></thead><tbody>")
    for r in body:
        out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def render_list(block):
    out, stack = [], []
    for raw in block:
        if not raw.strip():
            continue
        m = LIST_RE.match(raw)
        if m:
            ind = len(m.group(1))
            tag = "ol" if m.group(2)[0].isdigit() else "ul"
            while stack and stack[-1][0] > ind:
                out.append(f"</li></{stack.pop()[1]}>")
            if stack and stack[-1][0] == ind:
                out.append("</li>")
            else:
                out.append(f"<{tag}>")
                stack.append((ind, tag))
            out.append("<li>" + inline(m.group(3)))
        else:
            out.append("<p>" + inline(raw.strip()) + "</p>")
    while stack:
        out.append(f"</li></{stack.pop()[1]}>")
    return "".join(out)


def md(text: str) -> str:
    lines = text.splitlines()
    out, i = [], 0

    def next_nonblank(j):
        while j < len(lines) and not lines[j].strip():
            j += 1
        return lines[j] if j < len(lines) else ""

    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            j, buf = i + 1, []
            while j < len(lines) and not lines[j].startswith("```"):
                buf.append(lines[j])
                j += 1
            out.append("<pre><code>" + html.escape("\n".join(buf)) + "</code></pre>")
            i = j + 1
            continue
        m = re.match(r"^(#{1,6})\s+(.*)", line)
        if m:
            lvl = min(len(m.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
            i += 1
            continue
        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            out.append(render_table(rows))
            continue
        if LIST_RE.match(line):
            block = []
            while i < len(lines):
                cur = lines[i]
                nxt = next_nonblank(i + 1)
                if LIST_RE.match(cur) or (cur.startswith("  ") and cur.strip()):
                    block.append(cur)
                elif not cur.strip() and (LIST_RE.match(nxt) or nxt.startswith("  ")):
                    block.append(cur)
                else:
                    break
                i += 1
            out.append(render_list(block))
            continue
        if line.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].startswith(">"):
                buf.append(lines[i].lstrip(">").strip())
                i += 1
            out.append("<blockquote>" + inline(" ".join(buf)) + "</blockquote>")
            continue
        if not line.strip():
            i += 1
            continue
        buf = []
        while i < len(lines) and lines[i].strip() and not re.match(r"^(#|\||```|>)", lines[i]) \
                and not LIST_RE.match(lines[i]):
            buf.append(lines[i].strip())
            i += 1
        out.append("<p>" + inline(" ".join(buf)) + "</p>")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def sections(text: str, level: str = "## "):
    """Split Markdown into {heading: body} at the given heading level."""
    result, cur, buf = {}, None, []
    for line in text.splitlines():
        if line.startswith(level):
            if cur is not None:
                result[cur] = "\n".join(buf).strip()
            cur, buf = line[len(level):].strip(), []
        elif cur is not None:
            buf.append(line)
    if cur is not None:
        result[cur] = "\n".join(buf).strip()
    return result


def parse_status_table(body: str):
    rows = []
    for line in body.splitlines():
        if not line.startswith("|"):
            if rows:
                break
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells[0] in ("Block", "") or set(cells[0]) <= set("-: "):
            continue
        rows.append(cells)
    return rows


def parse_decisions(text: str):
    items = []
    for chunk in re.split(r"(?m)^(?=### D-)", text):
        m = re.match(r"### (D-\d+)\s*[\N{EM DASH}-]\s*(.+)", chunk)   # matches the em dash used in local headings
        if not m:
            continue
        fields = dict(re.findall(r"(?m)^\|\s*(Date|Author|Tier|Status|Affects)\s*\|\s*(.+?)\s*\|\s*$", chunk))
        body = chunk.split("\n", 1)[1] if "\n" in chunk else ""
        body = re.sub(r"(?m)^\|.*\|\s*$\n?", "", body)          # drop the field table
        body = re.sub(r'(?m)^<a id="[^"]+"></a>\s*$', "", body)
        items.append({"id": m.group(1), "title": m.group(2).strip(), "body": body.strip(), **fields})
    return items


def parse_phases(text: str):
    return re.findall(r"(?m)^### Phase (\d+) \N{EM DASH} (.+)$", text)


def inventory():
    rows = []
    for sub in ("rtl", "tb", "scripts", "sw"):
        for p in sorted((ROOT / sub).rglob("*")):
            if p.is_file() and p.suffix in (".sv", ".v", ".py", ".sh", ".S", ".c", ".h", ".ld"):
                n = sum(1 for _ in p.open(encoding="utf-8", errors="replace"))
                rows.append((p.relative_to(ROOT).as_posix(), n))
    return rows


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------
CSS = """
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2330;--muted:#5d6678;--line:#e3e6ec;--accent:#2f5bd3;
--ok:#1f7a4a;--ok-bg:#e3f4ea;--bad:#b3261e;--bad-bg:#fbe5e3;--warn:#8a5a00;--warn-bg:#fff1d0;
--idle:#5d6678;--idle-bg:#eceff3;--code:#f0f2f5}
@media (prefers-color-scheme:dark){:root{--bg:#12151b;--card:#1a1e26;--ink:#e6e9ef;--muted:#9aa3b2;
--line:#2a303b;--accent:#7ea2ff;--ok:#6fd39b;--ok-bg:#173325;--bad:#ff8a80;--bad-bg:#3a1c1a;
--warn:#f3c56b;--warn-bg:#3a2e12;--idle:#9aa3b2;--idle-bg:#252a33;--code:#232833}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--accent)}
header{padding:20px 16px 8px;max-width:1200px;margin:0 auto}
header h1{margin:0;font-size:22px}
header .sub{color:var(--muted);font-size:13px}
main{max-width:1200px;margin:0 auto;padding:8px 16px 40px;display:grid;gap:16px;
grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;min-width:0}
.card.wide{grid-column:1/-1}
.card h2{margin:0 0 10px;font-size:16px}
.card h3,.card h4,.card h5,.card h6{margin:14px 0 6px;font-size:14px}
.kpis{display:flex;gap:10px;flex-wrap:wrap}
.kpi{flex:1 1 120px;border:1px solid var(--line);border-radius:8px;padding:10px}
.kpi .v{font-size:22px;font-weight:600}
.kpi .l{font-size:12px;color:var(--muted)}
.chip{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.ok{color:var(--ok);background:var(--ok-bg)}.bad{color:var(--bad);background:var(--bad-bg)}
.warn{color:var(--warn);background:var(--warn-bg)}.idle{color:var(--idle);background:var(--idle-bg)}
.phases{display:flex;gap:6px;flex-wrap:wrap}
.phase{flex:1 1 130px;border:1px solid var(--line);border-radius:8px;padding:8px;font-size:13px}
.phase.cur{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.phase .n{font-size:12px;color:var(--muted)}
.bar{height:8px;background:var(--idle-bg);border-radius:4px;overflow:hidden;margin:6px 0 2px}
.bar>div{height:100%;background:var(--ok)}
.tbl{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600}
code{background:var(--code);padding:0 4px;border-radius:4px;font-size:12.5px}
pre{background:var(--code);padding:10px;border-radius:6px;overflow-x:auto}
pre code{background:none;padding:0}
blockquote{margin:8px 0;padding:6px 10px;border-left:3px solid var(--accent);color:var(--muted)}
details{border-top:1px solid var(--line);padding:6px 0}
details summary{cursor:pointer}
.muted{color:var(--muted);font-size:13px}
ul,ol{padding-left:20px;margin:6px 0}
"""


def chip(text: str) -> str:
    t = text.lower()
    cls = "idle"
    if any(k in t for k in ("done", "pass", "accepted", "baseline", "signed off")):
        cls = "ok"
    elif any(k in t for k in ("fail", "rejected", "error")):
        cls = "bad"
    elif any(k in t for k in ("progress", "proposed", "pending", "partial")):
        cls = "warn"
    return f'<span class="chip {cls}">{html.escape(re.sub(r"[*]", "", text))}</span>'


def build() -> str:
    progress = read(ROOT / "PROGRESS.md")
    psec = sections(progress)
    decisions = parse_decisions(read(ROOT / "DECISIONS.md"))
    phases = parse_phases(read(ROOT / "IMPLEMENTATION_GUIDE.md"))
    regress = load_json(ROOT / "sim" / "regress.json")
    synth = load_json(ROOT / "sim" / "synth" / "summary.json")

    cur_heading = next((h for h in psec if h.lower().startswith("current phase")), "")
    m = re.search(r"(\d+)", cur_heading)
    cur_phase = int(m.group(1)) if m else -1

    status_body = next((b for h, b in psec.items() if h.lower().startswith("status by block")), "")
    blocks = parse_status_table(status_body)
    done = sum(1 for r in blocks if len(r) > 1 and "done" in r[1].lower())

    proposed = [d for d in decisions if "proposed" in d.get("Status", "").lower()]
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    parts = [f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="30">
<title>PX32 Status</title><style>{CSS}</style></head><body>
<header><h1>PX32 project status</h1>
<div class="sub">Generated {now} from the repository · reloads every 30 s ·
source of truth: <a href="{LINK_PREFIX}PROGRESS.md">PROGRESS.md</a>, <a href="{LINK_PREFIX}DECISIONS.md">DECISIONS.md</a></div>
</header><main>"""]

    # KPIs
    if regress:
        res = regress.get("results", [])
        npass = sum(1 for r in res if r["status"] == "PASS")
        reg_v = f"{npass}/{len(res)}"
        reg_c = "ok" if res and npass == len(res) else "bad"
        reg_t = regress.get("timestamp", "")
    else:
        reg_v, reg_c, reg_t = "-", "idle", "not run yet"
    parts.append(f"""<section class="card wide"><h2>Overview</h2><div class="kpis">
<div class="kpi"><div class="v">Phase {cur_phase if cur_phase >= 0 else "?"}</div><div class="l">{html.escape(cur_heading.split("\N{EM DASH}", 1)[-1].strip())}</div></div>
<div class="kpi"><div class="v"><span class="chip {reg_c}" style="font-size:18px">{reg_v}</span></div><div class="l">regression · {html.escape(reg_t)}</div></div>
<div class="kpi"><div class="v">{done}/{len(blocks)}</div><div class="l">blocks done</div></div>
<div class="kpi"><div class="v">{len(decisions)}</div><div class="l">decisions logged</div></div>
<div class="kpi"><div class="v"><span class="chip {"warn" if proposed else "ok"}" style="font-size:18px">{len(proposed)}</span></div><div class="l">proposals waiting for you</div></div>
</div></section>""")

    # Now / next
    nxt = next((b for h, b in psec.items() if h.lower().startswith(("next action", "now working"))), "")
    if nxt:
        parts.append(f'<section class="card wide"><h2>Working on next</h2>{md(nxt)}</section>')

    # Phase roadmap
    if phases:
        cells = []
        for n, name in phases:
            n = int(n)
            state = "done" if n < cur_phase else ("in progress" if n == cur_phase else "not started")
            cells.append(f'<div class="phase{" cur" if n == cur_phase else ""}"><div class="n">Phase {n}</div>'
                         f'<div>{html.escape(name)}</div>{chip(state)}</div>')
        parts.append(f'<section class="card wide"><h2>Roadmap</h2><div class="phases">{"".join(cells)}</div></section>')

    # Block status
    if blocks:
        pct = int(100 * done / len(blocks)) if blocks else 0
        rows = "".join(
            f"<tr><td>{inline(r[0])}</td><td>{chip(r[1]) if len(r) > 1 else ''}</td>"
            f"<td>{inline(r[2]) if len(r) > 2 else ''}</td><td>{inline(r[3]) if len(r) > 3 else ''}</td></tr>"
            for r in blocks)
        parts.append(f"""<section class="card wide"><h2>Blocks · {done}/{len(blocks)} done</h2>
<div class="bar"><div style="width:{pct}%"></div></div>
<div class="tbl"><table><thead><tr><th>Block</th><th>Status</th><th>Tests</th><th>Notes</th></tr></thead>
<tbody>{rows}</tbody></table></div></section>""")

    # Regression
    if regress:
        rows = "".join(f"<tr><td><code>{html.escape(r['name'])}</code></td><td>{chip(r['status'])}</td>"
                       f"<td>{html.escape(r.get('detail', ''))}</td></tr>" for r in regress.get("results", []))
        parts.append(f"""<section class="card"><h2>Last regression</h2><div class="muted">{html.escape(reg_t)}</div>
<div class="tbl"><table><thead><tr><th>Testbench</th><th>Result</th><th>Detail</th></tr></thead>
<tbody>{rows}</tbody></table></div></section>""")
    else:
        parts.append('<section class="card"><h2>Last regression</h2><p class="muted">No run recorded yet. '
                     'Run <code>scripts/regress.sh</code>.</p></section>')

    # Synthesis
    if synth:
        rows = "".join(
            f"<tr><td><code>{html.escape(s['module'])}</code></td><td>{chip(s.get('status', ''))}</td>"
            f"<td>{s.get('cells', '')}</td><td>{s.get('latches', '')}</td><td>{s.get('depth', '')}</td></tr>"
            for s in synth.get("modules", []))
        parts.append(f"""<section class="card"><h2>Synthesis (Yosys, generic gates)</h2>
<div class="muted">{html.escape(synth.get('timestamp', ''))} · {html.escape(synth.get('note', ''))}</div>
<div class="tbl"><table><thead><tr><th>Module</th><th>Result</th><th>Cells</th><th>Latches</th><th>Logic depth</th></tr></thead>
<tbody>{rows}</tbody></table></div></section>""")

    # Decisions
    drows = []
    for d in reversed(decisions):
        drows.append(f"<details><summary><strong>{d['id']}</strong> {inline(d['title'])} "
                     f"{chip(d.get('Status', '?'))} <span class='chip idle'>Tier {html.escape(d.get('Tier', '?'))}</span>"
                     f"</summary><div class='muted'>{inline(d.get('Date', ''))} · {inline(d.get('Author', ''))} · "
                     f"affects {inline(d.get('Affects', ''))}</div>{md(d['body'])}</details>")
    parts.append(f'<section class="card wide"><h2>Decisions (newest first)</h2>{"".join(drows)}</section>')

    # Other PROGRESS sections
    for key in ("Measured vs target", "Open proposals waiting for the owner", "Known issues",
                "Current validation evidence", "Session log"):
        body = next((b for h, b in psec.items() if h.lower().startswith(key.lower())), None)
        if body:
            wide = " wide" if key in ("Known issues", "Session log", "Measured vs target") else ""
            parts.append(f'<section class="card{wide}"><h2>{html.escape(key)}</h2>{md(body)}</section>')

    # Block details (### subsections of Status by block)
    details = sections(status_body, "### ")
    for h, b in details.items():
        parts.append(f'<section class="card wide"><details><summary><strong>{inline(h)}</strong></summary>{md(b)}</details></section>')

    # Inventory
    inv = inventory()
    total = sum(n for _, n in inv)
    rows = "".join(f"<tr><td><code>{html.escape(p)}</code></td><td>{n}</td></tr>" for p, n in inv)
    parts.append(f"""<section class="card wide"><details><summary><strong>Source files</strong> · {len(inv)} files · {total} lines</summary>
<div class="tbl"><table><thead><tr><th>File</th><th>Lines</th></tr></thead><tbody>{rows}</tbody></table></div></details></section>""")

    parts.append("</main></body></html>")
    return "\n".join(parts)


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(build(), encoding="utf-8")
    print(f"dashboard: {OUT}")


if __name__ == "__main__":
    main()
