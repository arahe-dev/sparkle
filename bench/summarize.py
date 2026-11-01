"""Turn bench/results/raw/*.jsonl into bench/results/summary.md and charts.

Every number in docs/results.md comes from this file's output; nothing is typed in by hand.
Usage: python bench/summarize.py
"""
import json
import os
import statistics
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
# SPARKLE_RAW_DIR picks another result set (e.g. bench/results-python/raw); output goes beside it.
RAW = Path(os.environ.get("SPARKLE_RAW_DIR", ROOT / "results" / "raw")).resolve()
RES = RAW.parent
OUT = RES / "summary.md"
VARIANTS = ["plain", "tuned", "sparkle"]
TITLES = {
    "s10": "S10 Fixtures: build, import, size at rest, equivalence",
    "s11": "S11 Startup (ms until a command runs)",
    "s12": "S12 Tool speed on the image (ms)",
    "s13": "S13 colcon build of a 5-package ROS 2 workspace",
    "s14": "S14 Install and remove a package set (local .debs)",
    "s15": "S15 Disk growth over repeated use",
    "s16": "S16 Failure modes",
    "s17": "S17 Compatibility",
    "s20": "S20 Export and restore",

    "s18": "S18 Reclaimable upper layer",
}


def load():
    rows = []
    for f in sorted(RAW.glob("*.jsonl")):
        for line in f.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
    return rows


def fmt(v, unit):
    if isinstance(v, str):
        return v
    if unit == "B":
        return f"{v / 1e6:,.1f} MB"
    if unit == "ms" and v >= 10000:
        return f"{v / 1000:,.1f} s"
    if unit == "ms":
        return f"{v:,.0f} ms"
    return f"{v:,.0f}" if float(v).is_integer() else f"{v:,.2f}"


def cell(vals, unit):
    if not vals:
        return "—"
    if any(isinstance(v, str) for v in vals):
        return ", ".join(f"`{v}`" for v in dict.fromkeys(vals))
    if len(vals) == 1:
        return fmt(vals[0], unit)
    med = statistics.median(vals)
    return f"**{fmt(med, unit)}** <sub>{fmt(min(vals), unit)}–{fmt(max(vals), unit)}, n={len(vals)}</sub>"


def table(rows, test):
    groups = defaultdict(lambda: defaultdict(list))
    units, notes, order = {}, defaultdict(list), []
    for r in rows:
        if r["test"] != test:
            continue
        m = r["metric"]
        if m not in units:
            order.append(m)
        # The metric name is the source of truth for units (some early rows mislabelled counts).
        units[m] = "B" if m.endswith("_bytes") else "ms" if m.endswith("_ms") else (
            "count" if r["unit"] == "B" else r["unit"])
        groups[m][r["variant"]].append(r["value"])
        if r.get("note") and not r["note"].startswith("rc=0"):
            notes[m].append(f'{r["variant"]}: {r["note"]}')
    cols = [v for v in VARIANTS + ["old", "up", "all"] if any(v in groups[m] for m in order)]
    out = ["| metric | " + " | ".join(cols) + " |", "|---|" + "---|" * len(cols)]
    for m in order:
        if test == "s17":
            out.append(f"| {m} | " + " | ".join(
                ("✅" if all(x == 1 for x in groups[m][c]) else "❌") if groups[m][c] else "—" for c in cols) + " |")
            continue
        out.append(f"| {m} | " + " | ".join(cell(groups[m][c], units[m]) for c in cols) + " |")
    return "\n".join(out), notes


STAGES = [  # (label, test, metric, run) - one bar per variant per stage
    ("fresh import", "s10", "footprint_bytes", None),
    ("after the S11-S15 workload", "s15", "footprint_bytes", 5),
    ("after wsl --manage --compact", "s15", "footprint_after_compact_bytes", None),
]


def lifecycle(rows):
    """{stage label: {variant: bytes}} for the footprint chart."""
    out = {}
    for label, test, metric, run in STAGES:
        d = {}
        for r in rows:
            if r["test"] == test and r["metric"] == metric and (run is None or r["run"] == run):
                d[r["variant"]] = r["value"]
        out[label] = d
    return out


def svg_chart(stages, path, title):
    """Grouped bars: disk space on Windows per variant at each stage of a pack's life."""
    if not any(stages.values()):
        return
    w, h, pad, top = 680, 340, 60, 60
    colors = {"plain": "#d1495b", "tuned": "#edae49", "sparkle": "#00798c"}
    ymax = max(b for d in stages.values() for b in d.values()) * 1.15
    y = lambda b: h - pad - (h - pad - top) * b / ymax
    gw = (w - 2 * pad) / len(stages)
    bw = gw / (len(VARIANTS) + 1.2)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" font-family="sans-serif" font-size="12">',
             f'<rect width="{w}" height="{h}" fill="#fff"/>',
             f'<text x="{w/2}" y="22" text-anchor="middle" font-size="15">{title}</text>']
    for i in range(5):
        b = ymax * i / 4
        parts.append(f'<line x1="{pad}" x2="{w-pad}" y1="{y(b):.1f}" y2="{y(b):.1f}" stroke="#e5e5e5"/>')
        parts.append(f'<text x="{pad-6}" y="{y(b)+4:.1f}" text-anchor="end" fill="#555">{b/1e9:.1f} GB</text>')
    for g, (label, d) in enumerate(stages.items()):
        x0 = pad + g * gw + bw * 0.6
        for k, v in enumerate(VARIANTS):
            if v not in d:
                continue
            x = x0 + k * bw
            parts.append(f'<rect x="{x:.1f}" y="{y(d[v]):.1f}" width="{bw*0.9:.1f}" height="{y(0)-y(d[v]):.1f}" fill="{colors[v]}"/>')
            parts.append(f'<text x="{x+bw*0.45:.1f}" y="{y(d[v])-4:.1f}" text-anchor="middle" font-size="10">{d[v]/1e9:.2f}</text>')
        parts.append(f'<text x="{pad + g*gw + gw/2:.1f}" y="{h-pad+18}" text-anchor="middle">{label}</text>')
    for k, v in enumerate(VARIANTS):
        parts.append(f'<rect x="{pad + k*110}" y="34" width="12" height="12" fill="{colors[v]}"/>')
        parts.append(f'<text x="{pad + k*110 + 17}" y="44">{v}</text>')
    parts.append(f'<text x="{w/2}" y="{h-14}" text-anchor="middle" fill="#555" font-size="11">'
                 'Bytes on the Windows drive: the distro disk, plus the image file for sparkle. Same 599 packages at every stage.</text>')
    parts.append("</svg>")
    path.write_text("\n".join(parts), encoding="utf-8", newline="\n")


def main():
    rows = load()
    machine = (RES / "machine.txt")
    md = ["# Benchmark summary (generated)", "",
          f"Generated by `python bench/summarize.py` from `{RAW.relative_to(ROOT.parent).as_posix()}/*.jsonl`. "
          "Cells show **median** with min–max and run count. Do not edit by hand.", ""]
    if machine.exists():
        md += ["```", machine.read_text(encoding="utf-8").strip(), "```", ""]
    for test in sorted({r["test"] for r in rows}):
        t, notes = table(rows, test)
        md += [f"## {TITLES.get(test, test)}", "", t, ""]
        for m, ns in notes.items():
            uniq = sorted(set(ns))[:6]
            md.append(f"- `{m}`: " + "; ".join(f"`{n}`" for n in uniq))
        md.append("")
    OUT.write_text("\n".join(md), encoding="utf-8", newline="\n")
    svg_chart(lifecycle(rows), RES / "footprint.svg",
              "Disk space a ROS 2 pack takes on Windows" if RES == ROOT / "results" else "Disk space a pack takes on Windows")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
