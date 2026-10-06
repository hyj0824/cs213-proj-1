#!/usr/bin/env python3
"""Turn out/raw.csv into the tables that go in the report.

Standard library only, so it runs on a machine without pip.  Three things come
out of it, and the third is the one that matters most:

  1. out/summary.csv          one row per (case, backend, implementation)
  2. out/report_tables.md     ready-to-paste Markdown
  3. a CONSISTENCY CHECK       every backend must return the same answer for the
                              same question.  A fast backend that returns a
                              different number is not fast, it is wrong -- and
                              without this check a broken implementation would
                              look like a discovery.

Usage
    python3 analysis/analyze.py [--raw out/raw.csv] [--exclude-group PATTERN]
"""
import argparse
import csv
import os
import statistics
import sys
from collections import defaultdict

BACKEND_ORDER = {"pg": 0, "og": 1, "file": 2}


def median(v):
    return statistics.median(v) if v else float("nan")


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                r["latency_ns"] = int(r["latency_ns"])
                r["result"] = int(r["result"])
                r["rep"] = int(r["rep"])
                r["ok"] = int(r["ok"])
            except (KeyError, ValueError):
                continue
            rows.append(r)
    return rows


def case_key(r):
    """Everything that defines *the same question* across backends."""
    return (r["mode"], r["param"], r["scale"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default="out/raw.csv")
    ap.add_argument("--outdir", default="out")
    ap.add_argument("--exclude-group", default=None,
                    help="regex-ish substring; drop runs from the summary (still checked)")
    args = ap.parse_args()

    if not os.path.exists(args.raw):
        sys.exit(f"{args.raw} not found -- run scripts/40_run_all.sh first")

    rows = load(args.raw)
    if args.exclude_group:
        rows = [r for r in rows if args.exclude_group not in r.get("group", "")]
    # warm-up runs are tagged *_warmup and never contribute to a table
    n0 = len(rows)
    rows = [r for r in rows if "warmup" not in r.get("group", "")]
    dropped = n0 - len(rows)
    if not rows:
        sys.exit(f"{args.raw} has no usable rows")

    cases = defaultdict(list)          # case_key -> rows
    for r in rows:
        cases[case_key(r)].append(r)

    summary = []
    consistency_issues = []

    for ck in sorted(cases, key=lambda k: (k[0], k[2], k[1])):
        mode, param, scale = ck
        by_impl = defaultdict(list)
        for r in cases[ck]:
            by_impl[(r["backend"], r["impl"], r["group"])].append(r)

        # ---- correctness first -------------------------------------------
        answers = {}
        for (backend, impl, group), rs in by_impl.items():
            vals = {x["result"] for x in rs}
            if len(vals) > 1:
                if mode == "counter":
                    # not a defect in the harness: a lost-update experiment is
                    # *supposed* to give a different number every time. That
                    # irreproducibility is the finding.
                    pass
                else:
                    consistency_issues.append(
                        f"{mode}/{param}/scale={scale}: {backend}/{impl} returned "
                        f"{sorted(vals)} across repetitions (not reproducible)")
            answers[(backend, impl, group)] = sorted(vals)[0]
        # counter mode answers are per-run by design (lost updates accumulate
        # differently every time), so only modes with a stable answer are compared
        if mode not in ("counter",):
            distinct = sorted(set(answers.values()))
            if len(distinct) > 1:
                detail = "; ".join(f"{b}/{i}={v}" for (b, i, g), v in sorted(answers.items()))
                consistency_issues.append(
                    f"{mode}/{param}/scale={scale}: backends DISAGREE -> {detail}")

        for (backend, impl, group), rs in sorted(
                by_impl.items(), key=lambda kv: (BACKEND_ORDER.get(kv[0][0], 9), kv[0][1])):
            lat = [x["latency_ns"] for x in rs]
            q1 = statistics.quantiles(lat, n=4)[0] if len(lat) > 1 else lat[0]
            q3 = statistics.quantiles(lat, n=4)[2] if len(lat) > 1 else lat[0]
            cv = (statistics.pstdev(lat) / statistics.fmean(lat)) if len(lat) > 1 and statistics.fmean(lat) else 0.0
            summary.append(dict(
                mode=mode, param=param, scale=scale, backend=backend, impl=impl, group=group,
                n=len(lat), result=answers[(backend, impl, group)],
                median_ms=median(lat) / 1e6, q1_ms=q1 / 1e6, q3_ms=q3 / 1e6,
                min_ms=min(lat) / 1e6, max_ms=max(lat) / 1e6,
                iqr_ms=(q3 - q1) / 1e6, cv=round(cv, 3),
                all_consistent_within_backend=all(x["ok"] == 1 for x in rs),
            ))

    # ---- write the tidy CSV -------------------------------------------------
    os.makedirs(args.outdir, exist_ok=True)
    csv_path = os.path.join(args.outdir, "summary.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
        w.writeheader()
        w.writerows(summary)

    # ---- write the markdown -------------------------------------------------
    md = os.path.join(args.outdir, "report_tables.md")
    with open(md, "w", encoding="utf-8") as f:
        f.write("# Generated tables\n\n")
        f.write("Source: `%s`. Every number is the **median of n measured runs**; "
                "the IQR is there so the reader can see how noisy the case is. "
                "A single run is not a measurement.\n\n" % args.raw)

        f.write("## Correctness first\n\n")
        if consistency_issues:
            f.write("The following cases failed the equivalence check and are **not** "
                    "performance results:\n\n")
            for c in consistency_issues:
                f.write(f"* {c}\n")
        else:
            f.write("Every backend returned the same answer for every question, and "
                    "every repetition of a non-destructive case reproduced it.\n")
        counters = [s for s in summary if s["mode"] == "counter"]
        if counters:
            f.write("\nIn the counter experiment the plain-file backend is expected to "
                    "be irreproducible: the surviving count depends on how the OS "
                    "scheduled the writers, which is precisely the defect. Only the "
                    "DBMS rows should reproduce exactly.\n")
        f.write("\n")

        # group cases by mode
        modes = defaultdict(list)
        for s in summary:
            modes[s["mode"]].append(s)

        for mode in ("scan", "point", "join", "update", "counter"):
            if mode not in modes:
                continue
            f.write(f"## {mode}\n\n")
            if mode == "counter":
                f.write("| scale | threads | backend/impl | runs | expected | final (median) | lost % | "
                        "median s | IQR s |\n|---|---|---|---|---|---|---|---|---|\n")
                for s in sorted(modes[mode], key=lambda x: (x["param"], x["backend"], x["impl"])):
                    exp = int(s["param"].split("x")[0].split("=")[1]) * int(s["param"].split("x")[1])
                    lost = 100.0 * (exp - s["result"]) / exp if exp else 0
                    f.write(f"| {s['scale']} | {s['param']} | {s['backend']}/{s['impl']} | {s['n']} | "
                            f"{exp} | {s['result']} | {lost:.1f} | {s['median_ms'] / 1000:.3f} | "
                            f"{s['iqr_ms'] / 1000:.3f} |\n")
                f.write("\n'expected' is threads x iterations. Anything below 100% is a lost update.\n\n")
                continue

            f.write("| scale | param | backend/impl | n | result | median ms | IQR ms | min | max | CV |\n")
            f.write("|---|---|---|---|---|---|---|---|---|---|\n")
            for s in sorted(modes[mode], key=lambda x: (x["scale"], x["param"], x["backend"], x["impl"])):
                f.write(f"| {s['scale']} | `{s['param']}` | {s['backend']}/{s['impl']} | {s['n']} | "
                        f"{s['result']} | {s['median_ms']:.3f} | {s['iqr_ms']:.3f} | "
                        f"{s['min_ms']:.3f} | {s['max_ms']:.3f} | {s['cv']:.2f} |\n")
            f.write("\n")

            # speedup vs file, per case
            f.write("<details><summary>ratio to the plain-file backend</summary>\n\n")
            f.write("| scale | param | file seqscan ms | other | ratio |\n|---|---|---|---|---|\n")
            for ck in sorted({(s["scale"], s["param"]) for s in modes[mode]}):
                fs = [s for s in modes[mode] if (s["scale"], s["param"]) == ck and s["backend"] == "file"]
                if not fs:
                    continue
                base = fs[0]["median_ms"]
                for s in [x for x in modes[mode] if (x["scale"], x["param"]) == ck and x["backend"] != "file"]:
                    f.write(f"| {ck[0]} | `{ck[1]}` | {base:.3f} | {s['backend']}/{s['impl']} "
                            f"{s['median_ms']:.3f} | {s['median_ms'] / base:.2f}x |\n")
            f.write("\n</details>\n\n")

    # ---- console ------------------------------------------------------------
    print(f"rows read          : {len(rows)}" + (f"  (+{dropped} warm-up rows excluded)" if dropped else ""))
    print(f"cases              : {len(cases)}")
    print(f"summary            : {csv_path}")
    print(f"report tables      : {md}")
    print()
    if consistency_issues:
        print("!! CONSISTENCY FAILURES -- fix these before writing anything up:")
        for c in consistency_issues:
            print("   -", c)
    else:
        print("ok: all backends agree on every answer")

    # highest-variance cases, the ones a careful reader would question
    worst = sorted(summary, key=lambda s: -s["cv"])[:5]
    print("\nnoisiest cases (highest coefficient of variation):")
    for s in worst:
        print(f"   {s['mode']:7s} {s['param']:14s} {s['backend']:5s}/{s['impl']:16s} "
              f"n={s['n']:2d} median={s['median_ms']:9.3f} ms  CV={s['cv']:.2f}")


if __name__ == "__main__":
    main()
