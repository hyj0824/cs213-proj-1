# Full-scale run book

Everything below has been executed at least once on this machine, so the timings
are measured, not estimated. The benchmark is **prepared but not yet run**: the
pipeline has been validated end to end at `SCALE=1` (12,841,585 titles), and the
phase markers for the completed stages are already in place, so the full run
resumes from the measurement phase.

Hardware: i5-12400F (6C/12T), 16 GiB RAM, ZHITAI TiPlus5000 1 TB NVMe.
Server cpuset `0,2,4,6`, client cpuset `8,10`.

---

## 1. What is already done

| phase | state | evidence |
|---|---|---|
| toolchain (self-contained JDK 17, both JDBC drivers) | done | `.tools/`, `benchmark/lib/` |
| both engines running the latest builds | done | `out/env.txt` |
| identical configuration, divergences enumerated | done | `out/guc_compare.md` |
| IMDb datasets downloaded (228 MB + 311 MB gzip) | done | `data/raw/` |
| base loaded into both engines, **counts verified** | done | 12,841,585 titles + 2,000,000 people on each |
| `SCALE=1` derived tables + file export | done | `data/MANIFEST.txt` |
| guardrails | **all 0** | `sql/01_guardrails.sql` |
| pipeline rehearsal, three backends, results agree | done | `out/pilot_raw.csv` |

Phase markers for `fetch`, `load`, `amplify_1`, `guardrails_1` exist in
`out/phases/`, so `50_full_run.sh` picks up at `measure_1`.

## 2. Pilot results (12.84M titles) — what the full run will extend

Medians of n=3, engine under test exclusively resident (the other container
stopped), so these are clean single-machine numbers.

| case | PostgreSQL 18.6 | openGauss-lite 7.0.0-RC3 | plain file |
|---|---|---|---|
| scan `the` — **1 core** | 860 ms | 1413 ms | **656 ms** |
| scan `the` — as shipped | **251 ms** (4 workers) | 1413 ms | 656 ms |
| scan `man` — 1 core | 800 ms | 1242 ms | **602 ms** |
| scan `man` — as shipped | **222 ms** | 1242 ms | 602 ms |
| 2000 indexed point lookups | 56 ms | 94 ms | 543 ms (one pass) / **22 ms** (byte-offset index) |
| 20 **unindexed** point lookups | 2215 ms | 14345 ms | — |

Every backend returned the same row counts in every case.

Four things fall out of this table, and they are the backbone of the report:

1. **On one core the file program wins the full scan** (656 ms vs 860 ms and
   1413 ms). It reads 418 MB of TSV where PostgreSQL reads a 792 MB heap —
   1.9x fewer bytes for the same logical rows — and it has no MVCC visibility
   check to perform.
2. **PostgreSQL's win at the default setting is parallelism, not scan
   efficiency.** 860 ms → 251 ms with four workers. openGauss gets no speedup at
   all (1413 ms → 1413 ms) because `query_dop` defaults to 1 (serial). At
   `query_dop=4` openGauss does use SMP; the parallel series sets it. Reporting only the
   default numbers would compare four cores against one and call it an engine
   difference.
3. **openGauss's sequential scan is 1.6x slower than PostgreSQL's single-core
   scan on byte-identical heaps** (793 MB vs 792 MB). That is a genuine engine
   difference, not an artefact of size or configuration.
4. **The file's hand-built byte-offset index beats PostgreSQL's B-tree by 2.6x
   on a batch of point lookups** (22 ms vs 56 ms for 2000 lookups), because the
   DBMS pays a round trip, parse, plan and execute for each one. An index is not
   the same thing as a query interface.

## 3. Sizing: how far the scale sweep actually needs to go

| SCALE | titles | heap per engine | TSV | sorted TSV | index | disk needed |
|---|---|---|---|---|---|---|
| 1 | 12.8 M | 0.8 GB | 0.4 GB | 0.4 GB | 0.1 GB | ~4 GB |
| 2 | 25.7 M | 1.6 GB | 0.8 GB | 0.8 GB | 0.2 GB | ~6 GB |
| 4 | 51.4 M | 3.2 GB | 1.7 GB | 1.7 GB | 0.4 GB | ~12 GB |
| 8 | 102.7 M | 6.3 GB | 3.3 GB | 3.3 GB | 0.8 GB | ~22 GB |
| 16 | 205.4 M | 12.7 GB | 6.7 GB | 6.7 GB | 1.6 GB | ~42 GB |

**The cache boundary is between 8 and 16, not before it.** At `SCALE=8` the
table is 6.3 GB, which still fits in 16 GiB of page cache once the OS and one
server are resident; a sweep that stops at 8 therefore demonstrates the
*linear-growth* and *fixed-overhead* effects but does **not** exercise a genuine
memory miss. If you want the "working set no longer fits" point, add 16 to
`SCALES`; it costs roughly 40 GB more disk and 1.5-2 h more wall clock.

The default is deliberately `1 2 4 8`.

## 4. Measured cost of each phase

| phase | measured | note |
|---|---|---|
| `31_fetch_imdb.sh` | 3-4 min | 420 MB download, skips if present |
| `32_load_imdb.sh` | **2 m 21 s** for both engines | PG 22 s titles + 8 s people; OG 67 s + 13 s. Includes a row-count verification that aborts on any mismatch |
| `34_amplify.sh SCALE=1` | **64 s** total | both engines + full file export (12.8 M rows: COPY, 2-way sort, byte-offset index) |
| `34_amplify.sh SCALE=8` | ~25-35 min estimated | inserts 7 x 12.8 M rows per engine incrementally plus a 3.3 GB export; the 1→2→4→8 order only ever inserts what is missing |
| `measure` per scale | ~20-40 min | 4 keywords x 2 parallelism settings x 3 backends x 7 reps, plus the no-index point variant |
| `36_storage_ab.sh` | ~15 min | VACUUM FULL on a table of 2 M names |
| concurrency at 64 clients | ~40 min | 7 reps x 500 iterations x 4 thread counts x 4 backends |

Full sweep, all phases: **roughly 4-6 hours**, resumable.

## 5. Running it

```bash
cd cs213-proj-1
nohup bash scripts/50_full_run.sh > out/full_run.log 2>&1 &
tail -f out/full_run.log
```

Useful overrides:

```bash
SCALES="1 2 4 8 16"        # include the cache-boundary point
REPS=7 WARMUP=2            # repetitions (default 5 / 2 when run directly)
EXCLUSIVE=1                # stop the idle engine while measuring (default in 50_full_run.sh)
KEYWORDS="the a man love"  # hit rates of roughly 4.5%, 70%, 1%, 0.6% at SCALE=1
ENABLE_USTORE=on           # required for the ASTORE/USTORE experiment
```

Resume / redo a phase:

```bash
ls out/phases/                  # one marker per completed phase
rm out/phases/measure_4         # redo just that one
rm -rf out/phases               # redo everything
```

## 6. What to check when it finishes

1. `python3 analysis/analyze.py` prints `ok: all backends agree on every answer`.
   **If it prints a consistency failure instead, do not write any numbers up.**
2. `out/report_tables.md` — paste directly into the report.
3. `out/figures/` — needs `pip install matplotlib`; `analyze.py` works without it.
4. `grep -c DIFFERS out/guc_compare.md` — every divergence needs a sentence in
   the report's threats-to-validity section.
5. The CV column: any case with CV > 0.3 is noisy and needs more repetitions
   before it is quoted.

## 7. Traps that were already hit, so they are not hit again

* **`awk ... { exit }` in a load pipeline aborts the script.** Closing the pipe
  kills `zcat` with SIGPIPE, and `set -o pipefail` turns that into a script
  failure — non-deterministically, depending on whether `psql` had already
  finished. The loaders now filter by row number instead of exiting.
* **COPY's text format unescapes backslashes.** Two IMDb titles contain a literal
  `\t` / `\n` two-character sequence; those arrived in the database as a real tab
  and a real newline, silently, and no line-oriented file reader can represent
  the result. Backslashes are now doubled on the way in, which makes the load
  byte-exact. `sql/01_guardrails.sql` is what caught it.
* **A derived table can be stale while looking correct.** Reloading the base left
  `bench_titles_active` with the same row count and the old, mangled contents.
  `bench_meta` timestamps now force a rebuild; `FORCE_REBUILD=1` overrides.
* **`docker exec` without `-i` silently returns nothing** when a SQL script is
  piped into it. Every script that feeds SQL over stdin uses `-i`.
* **The two engines cannot both hold a 4 GB `shared_buffers` plus a multi-GB table
  on a 16 GiB host.** `EXCLUSIVE=1` stops the idle container, which also gives
  every backend the same cold buffer pool.
