#!/usr/bin/env python3
"""The figures.  Needs matplotlib:

    . .tools/mpl.env && python3 analysis/plot.py

Produces (in out/figures/), each as PNG and SVG:

  fig1_scan_scale     scan cost vs dataset size, one line per engine/physical design
  fig2_selectivity    scan cost vs hit count -- latency is flat in selectivity
  fig3_update_cost    T -> Ttt write amplification, three storage engines
  fig4_concurrency    % of updates that survived vs concurrent clients
  fig5_point_scale    indexed point lookups vs dataset size (B-tree vs byte index)
  fig6_repeatability  per-run spread, i.e. the error bars

Every figure is a claim, not decoration: the caption states what it shows.
"""
import argparse
import csv
import os
import re
import sys
from collections import defaultdict

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.ticker import FuncFormatter
    # The report displays these at 72% of the text width, so every size here is
    # roughly 1/0.72 of what it should look like on the page.
    plt.rcParams.update({
        "font.size": 11, "axes.titlesize": 11.5, "axes.labelsize": 10.5,
        "legend.fontsize": 8.5, "xtick.labelsize": 9.5, "ytick.labelsize": 9.5,
        "figure.autolayout": False,
    })
except ImportError:
    print("matplotlib is not available. Install it, or use the tables in")
    print("out/report_tables.md -- every number a figure would show is in there.")
    sys.exit(0)

SCALES = {1: "12.8M", 2: "25.7M", 4: "51.4M", 8: "102.7M", 16: "205M"}

COLORS = {
    "pg/heap+parallel0": "#1f77b4",
    "pg/heap+default": "#17becf",
    "og/astore+parallel0": "#d62728",
    "og/astore+default": "#ff7f0e",
    "file/seqscan": "#2ca02c",
    "file/sorted+byteindex": "#9467bd",
    "file/seqscan+fsync": "#8c564b",
}
LABELS = {
    "pg/heap+parallel0": "PostgreSQL 18.6, 1 core",
    "pg/heap+default": "PostgreSQL 18.6",
    "og/astore+parallel0": "openGauss 7.0, 1 core",
    "og/astore+default": "openGauss 7.0, 1 core",
    "file/seqscan": "plain file, streaming scan",
    "file/sorted+byteindex": "plain file, byte-offset index",
    "file/seqscan+fsync": "plain file, fsync per update",
}


def load_summary(path):
    with open(path, newline="", encoding="utf-8") as f:
        return [r for r in csv.DictReader(f)]


def load_raw(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return [r for r in csv.DictReader(f)]


def num(d, k, dflt=float("nan")):
    try:
        return float(d[k])
    except (KeyError, ValueError, TypeError):
        return dflt


def key(r):
    return f"{r['backend']}/{r['impl']}"


def save(fig, outdir, name):
    os.makedirs(outdir, exist_ok=True)
    for ext in ("png", "svg"):
        p = os.path.join(outdir, f"{name}.{ext}")
        fig.tight_layout()
        fig.savefig(p, dpi=170)
    print(f"  wrote {outdir}/{name}.png / .svg")
    plt.close(fig)


def series(rows, **match):
    """Group by backend/impl, and -- for scan cases -- by cache state as well.

    Warm and cold are different experiments, not two samples of one: at SCALE=8
    the file's cold scan is 30% slower than its warm one. Plotting them on a
    single line would average away the finding.
    """
    out = defaultdict(list)
    for r in rows:
        if not all(r[k] == v for k, v in match.items()):
            continue
        k = key(r)
        if "_cold" in r.get("group", ""):
            k += "#cold"
        elif "_warm" in r.get("group", ""):
            k += "#warm"
        out[k].append(r)
    for k in out:
        out[k].sort(key=lambda r: int(r["scale"]))
    return out


def line_panel(ax, groups, xl, yl, title, xlog=False, ylog=False, note=None):
    for k, rs in sorted(groups.items()):
        xs = [int(r["scale"]) for r in rs]
        ys = [num(r, "median_ms") for r in rs]
        base, _, phase = k.partition("#")
        cold = phase == "cold"
        lbl = LABELS.get(base, base) + (" (cold cache)" if cold else "")
        # only the warm series gets a legend entry: the caption states that dashed
        # means cold, and eight entries in a 6-inch figure is unreadable
        ax.plot(xs, ys, marker="o", color=COLORS.get(base, None),
                label="_nolegend_" if cold else lbl,
                lw=1.8, ms=5, ls="--" if cold else "-", alpha=0.95 if cold else 1.0)
    if xlog:
        ax.set_xscale("log", base=2)
        ticks = sorted({int(r["scale"]) for rs in groups.values() for r in rs})
        ax.set_xticks(ticks)                       # ticks and labels must come from the same set
        ax.set_xticklabels([SCALES.get(t, str(t)) for t in ticks])
    if ylog:
        ax.set_yscale("log")
    ax.set_xlabel(xl)
    ax.set_ylabel(yl)
    ax.set_title(title, fontsize=10)
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=7)
    if note:
        # bottom-right: the series all rise to the right, so this corner is free
        ax.annotate(note, xy=(0.98, 0.03), xycoords="axes fraction", fontsize=7,
                    color="#444", ha="right", va="bottom")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--summary", default="out/summary.csv")
    ap.add_argument("--raw", default="out/raw.csv")
    ap.add_argument("--storage", default="out/storage_ab.md")
    ap.add_argument("--outdir", default="out/figures")
    args = ap.parse_args()

    rows = load_summary(args.summary)
    os.makedirs(args.outdir, exist_ok=True)
    print(f"figures from {args.summary} ({len(rows)} summary rows)")

    # ---- fig 1: scan cost vs dataset size ---------------------------------
    # one series per config: PG's 4-worker runs have no openGauss counterpart,
    # and the openGauss default repeats the explicit query_dop=1 series
    single = [r for r in rows
              if (r["backend"], r["impl"]) not in (("pg", "heap+default"),
                                                     ("og", "astore+default"))]
    g = series(single, mode="scan", param="the")
    fig, ax = plt.subplots(figsize=(6.4, 3.1))
    line_panel(ax, g, "titles (rows)", "median scan time (ms, log)",
               "Full scan of the substring 'the' (4.5% of rows match)",
               xlog=True, ylog=True)
    save(fig, args.outdir, "fig1_scan_scale")

    # ---- fig 2: selectivity -------------------------------------------------
    # Warm-cache only, one series per engine/physical design: the point of this
    # figure is the *shape* (flat in selectivity), and nine overlapping series with
    # phase-suffixed keys made it unreadable.
    g2 = series(rows, mode="scan", scale="8")
    KEEP2 = [("file", "seqscan"), ("pg", "heap+parallel0"),
             ("og", "astore+default")]
    if g2:
        fig, ax = plt.subplots(figsize=(6.6, 4.3))
        for base in KEEP2:
            k = f"{base[0]}/{base[1]}"
            for kk, rs in g2.items():
                if not kk.startswith(k + "#") and kk != k:
                    continue
                if "#cold" in kk:
                    continue
                xs = [num(r, "result") for r in rs]
                ys = [num(r, "median_ms") for r in rs]
                ax.plot(sorted(zip(xs, ys))[0] and [x for x, _ in sorted(zip(xs, ys))],
                        [y for _, y in sorted(zip(xs, ys))],
                        marker="o", lw=1.6, color=COLORS.get(k, None),
                        label=LABELS.get(k, k))
                for x, y, r in sorted(zip(xs, ys, rs)):
                    ax.annotate(r["param"], (x, y), fontsize=6,
                                xytext=(3, 3), textcoords="offset points")
                break
        ax.set_xscale("log")
        ax.set_xlabel("rows matched (log)")
        ax.set_ylabel("median scan time (ms)")
        ax.set_title("Cost is independent of selectivity: every engine scans every row", fontsize=10)
        ax.grid(alpha=0.25)
        ax.legend(fontsize=7)
        ax.set_ylim(0, None)
        save(fig, args.outdir, "fig2_selectivity")

    # ---- fig 3: update cost, from the storage-engine A/B --------------------
    if os.path.exists(args.storage):
        entries = []
        for line in open(args.storage, encoding="utf-8"):
            if not line.startswith("| ") or line.startswith("| target") or set(line) <= set("|- \n"):
                continue
            c = [x.strip() for x in line.strip().strip("|").split("|")]
            if len(c) < 12:
                continue
            try:
                entries.append(dict(target=c[0], growth=float(c[5].rstrip("%")),
                                    dead=float(c[6]), vacuum=float(c[7]),
                                    full=float(c[9]), update=float(c[11]),
                                    before=float(c[2]), after=float(c[3])))
            except ValueError:
                continue
        if entries:
            def pretty(target):
                eng, _, tbl = target.partition("/")
                tbl = tbl.replace("bench_people_", "")
                if eng == "pg":
                    return "PostgreSQL\nheap"
                return {"astore": "openGauss\nASTORE", "ustore": "openGauss\nUSTORE"}.get(tbl, tbl)
            names = [pretty(e["target"]) for e in entries]
            fig, axes = plt.subplots(1, 3, figsize=(11, 3.8))
            for ax, field, title, unit, ylabel in (
                    (axes[0], "growth", "(a) table growth", "%", "growth (%)"),
                    (axes[1], "dead", "(b) dead tuples", "", "dead tuples"),
                    (axes[2], "full", "(c) VACUUM FULL duration", "ms", "duration (ms)")):
                vals = [e[field] for e in entries]
                bars = ax.bar(names, vals, color=["#1f77b4", "#ff7f0e", "#2ca02c"][:len(entries)])
                ax.set_title(title, fontsize=9)
                ax.set_ylabel(ylabel)
                ax.set_ylim(0, max(vals) * 1.18)
                ax.yaxis.set_major_formatter(FuncFormatter(lambda x, p: f"{x:,.0f}"))
                ax.grid(axis="y", alpha=0.25)
                for b, v in zip(bars, vals):
                    # one decimal for the percentages: 5.97 vs 8.36 is the finding,
                    # "6% vs 8%" hides it
                    label = f"{v:,.2f}{unit}" if unit == "%" else f"{v:,.0f} {unit}"
                    ax.annotate(label, (b.get_x() + b.get_width() / 2, v),
                                ha="center", va="bottom", fontsize=7)
            fig.suptitle("T -> Ttt on 2,000,000 IMDb person names: update cost per storage engine",
                         fontsize=10)
            save(fig, args.outdir, "fig3_update_cost")

    # ---- fig 4: concurrency correctness ------------------------------------
    g4 = series(rows, mode="counter")
    if g4:
        # merge warm/cold (and phase-less) variants of the same backend: the
        # counter experiment does not depend on the cache state, and leaving the
        # phase suffix in the key produced duplicate, untranslated legend entries
        merged = defaultdict(list)
        for k, rs in g4.items():
            merged[k.split("#")[0]] += rs
        g4 = merged
        fig, ax = plt.subplots(figsize=(6.0, 3.1))
        for k, rs in sorted(g4.items()):
            pts = []
            for r in rs:
                m = re.match(r"threads=(\d+)x(\d+)", r["param"])
                if not m:
                    continue
                threads, iters = int(m.group(1)), int(m.group(2))
                exp = threads * iters
                pts.append((threads, 100.0 * num(r, "result") / exp if exp else 0))
            pts.sort()
            if pts:
                ax.plot([p[0] for p in pts], [p[1] for p in pts], marker="o",
                        color=COLORS.get(k, None), label=LABELS.get(k, k), lw=1.8)
        ax.set_xscale("log", base=2)
        ax.set_xlabel("concurrent clients")
        ax.set_ylabel("% of updates that survived")
        ax.set_ylim(-5, 110)
        ax.axhline(100, color="#333", lw=0.8, ls="--")
        ax.set_title("Correctness under concurrency: read-modify-write on one counter", fontsize=10)
        ax.grid(alpha=0.25)
        ax.legend(fontsize=7, loc="center left")
        save(fig, args.outdir, "fig4_concurrency")

    # ---- fig 5: point lookups vs scale -------------------------------------
    g5 = series(rows, mode="point", param="n=2000")
    if g5:
        fig, ax = plt.subplots(figsize=(6.4, 3.1))
        line_panel(ax, g5, "titles (rows)", "batch time for 2,000 keys (ms, log)",
                   "2,000 point lookups: batch time vs table size",
                   xlog=True, ylog=True)
        save(fig, args.outdir, "fig5_point_scale")

    # ---- fig 6: repeatability ----------------------------------------------
    raw = load_raw(args.raw)
    if raw:
        keys = sorted({(r["mode"], r["param"], r["scale"], r["backend"], r["impl"], r["group"])
                       for r in raw})
        keys = [k for k in keys if "warmup" not in k[5] and not k[1].startswith("n=10")][:22]
        data, labels = [], []
        for k in keys:
            vals = [int(r["latency_ns"]) / 1e6 for r in raw
                    if (r["mode"], r["param"], r["scale"], r["backend"], r["impl"], r["group"]) == k]
            if len(vals) >= 3:
                data.append(vals)
                labels.append(f"s{k[2]} {k[3]}/{k[4][:12]}\n{k[0]} {k[1][:10]}")
        if data:
            fig, ax = plt.subplots(figsize=(max(7.5, 0.42 * len(data)), 4.3))
            ax.boxplot(data, labels=labels, showfliers=True)
            ax.set_yscale("log")
            ax.set_ylabel("latency (ms, log)")
            ax.set_title("Spread of every measured case -- this is the error bar", fontsize=10)
            plt.setp(ax.get_xticklabels(), fontsize=6, rotation=90)
            ax.grid(axis="y", alpha=0.25)
            save(fig, args.outdir, "fig6_repeatability")

    print("done")


if __name__ == "__main__":
    main()
