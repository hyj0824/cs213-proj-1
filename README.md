# DBMS Performance Evaluation: PostgreSQL vs openGauss vs plain files

Benchmark for *Project 1: DBMS Performance Evaluation*. One Java client runs
four operations against PostgreSQL 18.6, openGauss 7.0.0, and a plain TSV
file backend on the IMDb title data, from 12.8M to 102.7M rows.

Report: `report/report.pdf`. Medians: `out/summary.csv`. Per-run data:
`out/raw.csv`. Full run log: `out/full_run.log`.

## Q1. What are the unique advantages of a DBMS compared with data operations in files?

The advantage is correctness and guarantees under concurrency, not raw speed. On
one core the file backend is faster: a full scan takes 5.7 s against 6.8 s for
PostgreSQL and 11.7 s for openGauss, and 2,000 indexed lookups take 25 ms
against 50 and 82 ms. The databases keep results correct under concurrent
writers, and they supply rollback, constraints, durable commits, and maintained
indexes. The file backend has none of this unless its program adds it.

## Q2. Which DBMS is better? PostgreSQL or openGauss, and by which standard?

PostgreSQL, on every speed measure: 1.7x on one core, 1.5x at four workers, and
1.6x on indexed lookups. openGauss's USTORE keeps the smallest relation after a
growing update, but its update latency is higher and its undo sits outside the
relation size, so the space win is a trade-off.

| measurement (102.7M rows unless noted) | result |
|---|---|
| full scan, one core | file 5.69 s, PostgreSQL 6.78 s, openGauss 11.69 s |
| full scan, four workers | PostgreSQL 2.06 s, openGauss 3.13 s (1.52x) |
| 2,000 indexed point lookups | file 25.4 ms, PostgreSQL 50.4 ms, openGauss 81.6 ms |
| 10 unindexed point lookups | PostgreSQL 10.4 s, openGauss 66.9 s |
| 500 increments, one client | file 0.015 s; file+fsync 0.52 s; PostgreSQL 0.52 s |
| 32,000 increments, 64 clients | file 1 survived (7 with fsync); both databases 32,000 |
| growing update on 2M names | growth: PostgreSQL 6.79%, ASTORE 8.36%, USTORE 5.97% |

## How the measurements were made

- Four operations: full scan, point lookup, growing update, and concurrent
  counter. All are defined once in `benchmark/src/bench/Semantics.java`.
- PostgreSQL exports the TSV that the file backend reads, so all three backends
  see the same rows. A timing is reported only after the backends agree on the
  result.
- Warm and cold cases run separately. Warm cases discard one warm-up and use the
  median of 7 runs; cold cases drop the OS page cache before every repetition.
  `shared_buffers` is not cleared, so cold is not a true cold start.
- Comparisons use matched parallelism: one core and four workers or threads. The
  file backend is single-threaded.
- Limits: one machine and one dataset; the 102.7M-row table is eight copies of
  the title base, so the title distribution repeats; the file backend is
  single-threaded Java, and no parallel or C version was tested.

## Quick start

```bash
bash scripts/05_install_jdk.sh
bash benchmark/build.sh
docker build -f docker/Dockerfile.opengauss -t dbbench/opengauss:7.0.0-RC3 .
bash scripts/10_up.sh
bash scripts/20_align_guc.sh
bash scripts/25_bootstrap.sh
bash scripts/30_load_filmdb.sh
bash scripts/33_export_files.sh
REPS=3 SCALE=1 bash scripts/40_run_all.sh
python3 analysis/analyze.py
```

The full IMDb run (`31_fetch_imdb.sh` through `50_full_run.sh`) and its measured
timings are in `docs/FULL_RUN.md`. JDBC drivers are not committed; `build.sh`
fetches them.

## Report

```bash
python3 report/gen_tables.py
typst compile --root . report/report.typ report/report.pdf
```

`report/gen_tables.py` builds every table from `out/summary.csv`. The report PDF
and its figures are committed; the TSV data and per-run logs are not.

## Layout

- `benchmark/src/bench/` — Java harness: semantics, backends, CSV output
- `sql/`, `scripts/` — schema, guardrails, and the measurement pipeline
- `analysis/` — median and IQR checks, plus the six figures
- `report/` — Typst source, generated tables, PDF
- `out/figures/`, `out/summary.csv`, `out/raw.csv` — figures and measurements
- `filmdb.sql` — small course fixture; the IMDb data is downloaded and gitignored
- `submit/DBBench.java` — single-file submission build

## Status

The full benchmark has been run at four scales. The figures and tables in the
report are generated from `out/summary.csv`; the PDF is the authoritative
write-up.
