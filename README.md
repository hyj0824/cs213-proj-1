# DBMS Performance Evaluation: PostgreSQL vs openGauss vs plain files

Experimental benchmark for *Project 1: DBMS Performance Evaluation*.

It answers two questions with measurements:

1. **What does a DBMS give you that file operations do not?**
2. **PostgreSQL or openGauss: better at what, and how do we measure it?**

---

## Engine versions in use

| engine | version | image |
|---|---|---|
| PostgreSQL | **18.6** | `postgres:18` (official) |
| openGauss | **openGauss-lite 7.0.0-RC3** (2026-03-25) | `opengauss/opengauss:7.0.0-RC3.B025-amd64-openEuler22.03` + `docker/Dockerfile.opengauss` |

Both are the newest generally available builds, both run the same workload on the
same host, with heaps of the same size (792 MB vs 793 MB for 12,841,585 titles)
and an identical parameter set (`out/guc_compare.md`). Settings that do not
map one-to-one are recorded there as engine differences:
PostgreSQL 18's parallel query and asynchronous I/O (`io_method`, `io_workers`),
and openGauss's thread pool, USTORE, and Oracle-compatibility mode. The official
`opengauss/opengauss` Docker image is built from the Lite package
(`openGauss-Lite-7.0.0-RC3-...bin`), so that is the edition measured. A
single-node kernel comparison does not need CM/OM or cluster features. The
published matrix lists SMP as unsupported in lite, but the 7.0.0-RC3 lite
binary accepts `query_dop` and produces a `LOCAL GATHER dop: 1/4` plan; the
benchmark sets `query_dop=4` for the parallel series.

## How the comparison is designed

The naive version of this project is a stopwatch race: run `SELECT ... LIKE '%x%'`,
run the equivalent Java loop, print two numbers. That produces two numbers but no
finding: both sides read every row, and the interesting part is why the numbers
differ.

This benchmark gives the file side a fair chance: one Java client, the same four
operations, and a TSV file exported by PostgreSQL. The report is organised as
design, implementation, and evaluation. The design section explains the controls
and the four experiment groups; the implementation section describes the data,
code, and measurement procedure; the evaluation section reports scans, point
lookups, concurrency, updates and rules, and the engine scorecard.

### The two comparisons

```
                 ┌──────────────┐
   canonical     │  PostgreSQL  │  bench_titles_active (heap, PK on/off)
   semantics  ──▶│  openGauss   │  bench_people_active (heap / ASTORE / USTORE)
   (Semantics.   └──────────────┘
    java)        ┌──────────────┐
                 │  plain file  │  titles_active.tsv  (+ sorted + byte index)
                 └──────────────┘
```

Every backend implements the same operations, defined once in
`benchmark/src/bench/Semantics.java`:

* retrieval: `title LIKE '%kw%'` ≡ `title.contains(kw)`, case-sensitive
* update: `replace(x,'T','Ttt')` ≡ `String.replace`, so every ASCII `T` becomes `Ttt`

The TSV file the file backend reads is exported by PostgreSQL
(`scripts/33_export_files.sh`), so all three backends work on the same rows.

---

## Quick start

```bash
# 0. environment: pin the CPU governor, check the machine
sudo sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
bash scripts/00_check_env.sh

# 1. toolchain (this box had a JRE but no javac, and sudo wants a password)
bash scripts/05_install_jdk.sh
bash benchmark/build.sh

# 2. the openGauss image -- see "Images and tooling" below for why this is needed
docker build -f docker/Dockerfile.opengauss -t dbbench/opengauss:7.0.0-RC3 .

# 3. containers: host bind mounts, identical cpusets, no overlayfs in the I/O path
bash scripts/10_up.sh
bash scripts/20_align_guc.sh          # applies identical settings, prints the diff

# 4. small dataset first (filmdb, 9,204 titles -- a fast full loop)
bash scripts/25_bootstrap.sh
bash scripts/30_load_filmdb.sh
bash scripts/33_export_files.sh
REPS=3 SCALE=1 scripts/40_run_all.sh
python3 analysis/analyze.py

# 5. then the real dataset (see docs/FULL_RUN.md for measured timings)
bash scripts/31_fetch_imdb.sh         # 420 MB -> 12,841,585 titles + 15.7M names
bash scripts/32_load_imdb.sh          # 2 m 21 s for BOTH engines, counts verified
SCALE=1 bash scripts/34_amplify.sh    # 64 s incl. the whole file export
python3 analysis/analyze.py
```

**The full sweep is one resumable command** -- read `docs/FULL_RUN.md` first:

```bash
nohup bash scripts/50_full_run.sh > out/full_run.log 2>&1 &
```

Full pipeline order:

```
00_check_env → 05_install_jdk → benchmark/build.sh → 10_up → 12_wait_ready → 20_align_guc
   → 25_bootstrap → {30_load_filmdb | 31_fetch_imdb → 32_load_imdb}
   → 34_amplify (scale N) → 01_guardrails → 33_export_files
   → 40_run_all → analyze.py → plot.py
   → 36_storage_ab, 37_constraint_demo   (the mechanism experiments)
```

`01_guardrails.sql` is not optional. It asserts that no value contains a tab or a
newline, which is what makes the one-line-per-record TSV reader valid. If it
prints anything other than 0, the file backend and the SQL backend are not
answering the same question and no result is meaningful.

---

## What each script does

| script | purpose |
|---|---|
| `00_check_env.sh` | writes `out/env.txt`: CPU topology, governor, RAM, disk, versions, and a pass/fail checklist. Goes straight into the report's environment section |
| `05_install_jdk.sh` | self-contained JDK under `.tools/` (no root needed) |
| `10_up.sh` / `11_down.sh` | both engines as containers, bind-mounted to the host NVMe, pinned to `SERVER_CPUS` |
| `12_wait_ready.sh` | probes openGauss's several entry points instead of assuming one |
| `20_align_guc.sh` / `21_dump_guc.sh` | applies identical absolute settings and emits `out/guc_compare.md`, flagging every parameter that differs |
| `25_bootstrap.sh` | creates/resets the benchmark tables |
| `30_load_filmdb.sh` | loads `filmdb.sql` into schema `film` on both engines, then points the benchmark tables at it |
| `31_fetch_imdb.sh` | IMDb non-commercial datasets (free for non-commercial use) |
| `32_load_imdb.sh` | streams gzip straight into `\copy`; nothing is materialised in the container |
| `34_amplify.sh` | derives `bench_titles_active` at SCALE × the base, then re-exports the file side |
| `33_export_files.sh` | the fairness measure: exports TSV from the DB, plus the sorted variant and its byte-offset index, plus `MANIFEST.txt` with row counts and sha256 |
| `35_toggle_index.sh` | `up`/`down` for the primary key — same query, two physical designs |
| `36_storage_ab.sh` | write amplification and bloat: PG heap vs openGauss ASTORE vs openGauss USTORE, with VACUUM timed separately |
| `37_constraint_demo.sh` | "the DBMS refuses, the file program complies" |
| `40_run_all.sh` | the whole matrix, one command; one engine at a time, with the scan measured both pinned to one core and as shipped |
| `50_full_run.sh` | **the full-scale benchmark**: every phase, resumable via markers in `out/phases/`, one engine exclusively resident at a time |
| `90_drop_caches.sh` | cold-cache control: `drop_caches` when root is available, otherwise a scratch-file eviction. Records which method was used; refuses to pretend |
| `65_coldfix.sh` | re-measures the whole cold series with one method, one drop per repetition, no warm-up |
| `66_cold_evidence.sh` | captures `EXPLAIN (ANALYZE, BUFFERS)` in a genuinely cold state and again warm, for the mechanism |
| `91_restore_people.sh` | restores the people table between destructive repetitions |

---

## Non-negotiable methodology

These are the things that separate a measurement from a number.

1. **Warm-up is discarded.** Every non-destructive case runs `--warmup` times
   first; JIT and buffer pools make run #1 unrepresentative (see the 109 ms first
   `join` in a 7 ms case).
2. **Report the median of n ≥ 5 runs plus the IQR**, never a single run.
   `analyze.py` prints the coefficient of variation so noisy cases are visible
   instead of hidden.
3. **Client and server on different physical cores.** `SERVER_CPUS=0,2,4,6`,
   `CLIENT_CPUS=8,10`. The i5-12400F is 6C/12T with SMT pairs (0,1)(2,3)(4,5)
   (6,7)(8,9)(10,11), so pinning "0-7" would give the server two physical cores
   with sibling contention and put the client on top of it.
4. **Identical absolute configuration** on both engines, printed as a table
   (`out/guc_compare.md`). Divergences are reported, not hidden. Note that
   PostgreSQL's JIT is switched **off**: it is on by default since PG 12, costs
   ~1 ms per query, and openGauss has no JIT at all, so leaving it on would
   compare "PG + LLVM" with "openGauss".
5. **Cold and warm are separate experiments.** On a 16 GiB host a 1.5 GiB table
   lives entirely in the page cache, so an uncontrolled comparison measures the
   cache, not the engines. A cold phase drops the cache before **every**
   repetition and runs no warm-up (`40_run_all.sh` aborts the phase if the drop is
   unavailable, rather than mislabelling warm data) — the measured cold penalties
   are +30 % for the file, +12 % for openGauss and +2 % for PostgreSQL's
   single-core scan.
6. **Correctness is asserted before performance is reported.** Every backend
   returns a `result` for every case; `analyze.py` refuses to present a case
   where two backends disagree. A fast wrong answer is not a finding.
7. **The destructive update is restored between repetitions**, otherwise
   repetition #2 measures an empty diff.
8. **Autovacuum is off during measurement** and reclamation is timed explicitly,
   so no background process can be credited or blamed.

---

## Where the score comes from

The brief says the score depends on source and report quality, that the report
must be easy to understand, that highlights matter, that a reader should find it
interesting and useful, and that verbose filler is penalised. Concretely:

**Four results that are worth a section each**

1. **The file program is not slow, it is wrong.** `counter`: 8 clients × 200
   increments. PostgreSQL: 1600/1600. File: ~50/1600, and the counter file itself
   becomes unparseable because two writers both extended it (recorded as
   `unparseable_reads` in the raw log). No amount of optimisation fixes this —
   only a lock manager or a transaction manager does.
2. **The file program's speed advantage is the fsync it never performed.** Same
   run at 1 client: file 0.010 s vs PG 0.183 s (18×). Add `--file-fsync` and it
   becomes 0.225 s — *slower than the DBMS*, because now it is paying the same
   durability cost without any of the ergonomics. This single flag is the clearest
   possible statement of the cost model.
3. **Where the DBMS's index win actually comes from.** `35_toggle_index.sh down`
   turns a 500-lookup batch from 19 ms into 104 ms on 9,204 rows, and it gets
   worse linearly with size. Conversely, the file backend's own byte-offset index
   (rebuilt by hand in `FileBackend.pointLookupsIndexed`) is *slower* than its own
   full scan at this size — a concrete, measured answer to "when is an index not
   worth it".
4. **openGauss USTORE vs append-only heaps** (`36_storage_ab.sh`). The update
   grows every touched row, which is the worst case for PG's heap and openGauss's
   ASTORE: dead tuples, table growth, and VACUUM FULL needing a second copy of the
   table on disk. USTORE keeps the live version in place and moves the old version
   to undo space. This is a real architectural difference between the two
   engines, it is documented, and it is the only experiment here that can actually
   answer question 2.

**Five figures** (`analysis/plot.py`)

1. scale curve, log-log: file scan / DB seq scan / DB index scan vs dataset size
2. latency vs selectivity (flat, because both sides scan)
3. update cost: latency + bytes written + bloat, three storage engines
4. concurrency: % of updates that survived vs client count
5. per-case spread (the error bars a careful reader will ask for)

**Report skeleton**

```
p1   Summary: the two answers, each with numbers
1    Design: questions, architecture, controls, experiment groups
2    Implementation: data, code, measurement
3    Evaluation: scans, point lookups, concurrency, updates and rules,
     PostgreSQL vs openGauss, what the numbers mean, limits
```

---

## Threats to validity (write these down, do not hide them)

* **The two engines are not the same code base.** openGauss is a heavily modified
  fork of PostgreSQL 9.2; this compares two *products*, not two algorithms.
  PostgreSQL's process-based parallel query and openGauss's thread-pool model
  are architectural differences, not tuning differences, and are reported as
  such. openGauss's SMP is off by default (`query_dop=1`); the lite binary used
  here accepts `query_dop=4` despite the published matrix.
* **Containers.** Both engines run in containers with an identical
  `--cpuset-cpus` and memory cap and data on a host bind mount. A control run
  without the bind mount (`docker run` without `-v`) is worth 30 minutes in an
  appendix: the container's overlayfs layer adds copy-on-write write amplification
  that has nothing to do with the engine.
* **Page cache.** Only the host's own cache is dropped; `shared_buffers` is not.
  A true cold start needs `docker restart`. The cold series was **re-measured**
  after the first attempt turned out not to be cold at all (it began with a
  warm-up scan and dropped the cache once per phase instead of once per
  repetition, giving a PostgreSQL "cold" number 1.000x its warm one). All four
  scales now use `drop_caches` before **every** repetition with no warm-up;
  `out/cold_method.txt` summarises it and `out/cold_invocations.log` records every
  drop. The measured penalty is consistent: **file +30 %, openGauss +12 %,
  PostgreSQL single-core +2 %**. Do **not** compare the `I/O Timings` column
  across the engines — PostgreSQL 18 reports 12.6 ms for 6.3 GB of reads because
  `io_method=worker` moves them to auxiliary processes.
* **Single machine, one run each.** No confidence intervals beyond the IQR; the
  absolute numbers will not transfer to other hardware, the ratios should.
* **The file backend is Java.** A hand-written C reader with `mmap` would be
  faster on the scan cases. The implementation here already avoids per-line
  String allocation and offers a zero-copy line reader, so the remaining gap is
  JVM/IO-setup overhead, not a naive parser — state that explicitly.

---

## Layout

```
report/report.pdf           THE REPORT (compiled with Typst)
report/report.typ           report source
report/tables.typ           generated tables imported by the report
report/gen_tables.py        regenerates every table from out/summary.csv
submit/DBBench.java         the benchmark as a single submission file (generated)
docs/FULL_RUN.md            run book: measured timings, sizing math, what to check
docker/Dockerfile.opengauss the two-line fix that makes the official openGauss image start
filmdb.sql                  the course fixture (SQLite dump; the PRAGMA line is stripped on load)
benchmark/src/bench/        the benchmark (Semantics, Backend, SqlBackend, FileBackend, Main, Tsv, Stats, RawCsv)
benchmark/lib/              JDBC drivers (gitignored; see lib/README.md for the openGauss fallback)
sql/                        bootstrap, guardrails, constraint demo, storage engines, size accounting
sql/guc/                    the identical settings applied to both engines
scripts/                    the pipeline, numbered in execution order
tools/tsv_util.py           export helpers + byte-offset index builder
analysis/analyze.py         median/IQR tables + the cross-backend consistency check
analysis/plot.py            the five figures (needs matplotlib)
data/                       canonical TSV exports + MANIFEST (gitignored, regenerable)
out/                        raw.csv, summary.csv, report_tables.md, explain dumps, figures
```

## Gotchas already handled (each one cost real time)

**Images and tooling**

* **`opengauss/opengauss:latest` (7.0.0-RC) cannot initdb on this host**:
  `gaussdb: error while loading shared libraries: libopenblas.so.0`. That is an
  image defect, not a configuration problem. `OG_IMAGE` therefore defaults to
  `enmotech/opengauss:5.0.0`, which works. If you want a newer openGauss, expect
  to rebuild the image or install openblas into it.
* **opengauss-jdbc is a pgjdbc fork.** It ships `org.postgresql.Driver` (there is
  no `org.opengauss.Driver`) and accepts only `jdbc:postgresql://` URLs —
  `jdbc:opengauss://` fails with "No suitable driver found". Worse, putting both
  jars on one classpath makes one silently shadow the other, and the symptom is a
  cryptic `Protocol error. Session setup failed.` against PostgreSQL. `run.sh`
  therefore builds a **per-backend classpath**, and the benchmark prints the
  driver's *code source jar* so the report can state which client stack ran.
* **openGauss's `gsql` is only on `omm`'s PATH**, does not read `PGPASSWORD`
  (passwords must go through `-W`), and does not accept `-f -` the way psql does
  ("The option '-f' need a parameter"). Scripts are piped to its stdin instead.
* **`ALTER SYSTEM SET` is not usable for most parameters in openGauss 5.0**:
  `postgresql.auto.conf` stays empty and the server answers "ALTER SYSTEM SET
  only support POSTMASTER-level, SIGHUP-level and BACKEND-level guc variable".
  `sql/guc/og_conf.conf` is appended to `postgresql.conf` instead, and
  `20_align_guc.sh` rolls the block back automatically if the server then fails
  to start. That the two engines cannot even be configured the same way is a
  reportable finding, not an inconvenience.
* **`max_wal_size` does not exist in openGauss 5.0** and aborts startup. It is
  removed from the openGauss block and recorded as an engine-specific difference.
* **USTORE is off by default in the 7.0 line**; `CREATE TABLE ... WITH
  (storage_type=USTORE)` fails until `enable_ustore=on` is set (a postmaster
  parameter). `20_align_guc.sh` takes `ENABLE_USTORE=off|on`, and leaving it *off*
  is the honest way to compare the engines' default storage behaviour.
* **The PostgreSQL 18 image moved its mount point** to `/var/lib/postgresql` with
  `PGDATA=/var/lib/postgresql/18/docker`. Mounting the 17 path on an 18 image
  makes initdb refuse to start. `PG_MOUNT` is derived from the image's own
  `PGDATA` env so this cannot silently drift.
* **openGauss SMP is off by default.** PostgreSQL 18 splits a sequential scan
  across workers, so the scan is measured twice -- once pinned to one core
  (`--parallel 0`) and once as shipped -- and `impl()` records which ran
  (`heap+parallel0` vs `heap+default`). openGauss uses `query_dop`, default 1;
  the lite binary used here accepts `query_dop=4` and produces a `LOCAL GATHER
  dop: 1/4` plan, despite the published matrix. The fair parallel probe sets it
  to 4.

**Data integrity -- the failures that do not announce themselves**

* **`awk '{ exit }'` in a load pipeline aborts the script.** Closing the pipe kills
  `zcat` with SIGPIPE and `set -o pipefail` turns that into a failure --
  non-deterministically, depending on whether `psql` had already finished. The
  loaders filter by row number instead of exiting.
* **COPY's text format unescapes backslashes.** Two IMDb titles contain a literal
  two-character `\t` / `\n`; those rows had been silently stored with a real tab
  and a real newline in them, which no line-oriented file reader can represent.
  Backslashes are now doubled on the way in, making the load byte-exact.
  `sql/01_guardrails.sql` is the check that caught it and it must print 0.
* **A derived table can be stale while looking correct.** Reloading the base left
  `bench_titles_active` with the same row count and the old, mangled contents.
  `bench_meta` now stamps load times and forces a rebuild; `FORCE_REBUILD=1`
  overrides.
* **Every load is verified against the number of rows it should have produced.**
  A silently truncated load would make every subsequent comparison wrong while
  looking perfectly healthy.
* **openGauss defaults to Oracle SQL compatibility**, where the empty string *is*
  NULL: the filmdb dump dies on `null value in column surname` and the whole
  transaction aborts. `25_bootstrap.sh` creates the benchmark database with
  `DBCOMPATIBILITY 'PG'`. Comparing PostgreSQL against an Oracle-mode database
  would compare two dialects, not two engines.
* **`docker exec` without `-i` returns nothing** when a SQL script is piped in,
  with no error at all.

**Measurement correctness**

* **_T → Ttt is not idempotent._** `"Ttt"` still matches `LIKE '%T%'`, so a second
  run rewrites already-rewritten rows and inflates every count. Every destructive
  experiment restores its input first — `91_restore_people.sh` for the table and
  the file, `--restore-cmd` for the repetitions.
* **A ${var//%T%/$table} substitution silently rewrote the WHERE clause** into
  `LIKE 'bench_people_active'` and matched zero rows, which looked like a valid
  0-row update. `36_storage_ab.sh` uses a placeholder that cannot collide.
* **An append-only heap can absorb an update into space freed by the previous
  update**, so the relation does not grow and "write amplification" silently
  reads as 0. `36_storage_ab.sh` restores and `VACUUM FULL`s before measuring.
* **A CHECK constraint cannot be added to a table whose rows already violate it.**
  The strict table is created with the rule and then loaded with rows that
  satisfy it; the *update* is what breaks the rule.
* **Non-distinct random ids break the point comparison** (the file side answers a
  batch with one scan and a set membership test). `Main.randomIds` generates
  distinct ids.
* **`--file-impl idx` is not automatically faster.** At 9,204 rows the file's own
  binary search loses to its own full scan. Measure the crossover; do not assume
  it.
* **warm-up runs are tagged `*_warmup`** and excluded by `analyze.py`, so the
  first, always-slower run cannot inflate a median.
* **A `grep` in a pipeline returns 1 when it matches nothing**, which under
  `set -e -o pipefail` kills the driver script silently. The driver scripts end
  their filter pipelines with `|| true`.

---

## The report

`report/report.pdf` is built with Typst:

```bash
python3 report/gen_tables.py                 # tables from the measured data
typst compile --root . report/report.typ report/report.pdf
```

No number in the report was typed by hand: `report/gen_tables.py` reads
`out/summary.csv`, `out/storage_ab.md` and `out/constraint_demo.txt` and emits
`report/tables.typ`, which the report imports. Re-measure, re-run those two
commands, and the report updates.

## Results at full scale (12.8M -> 102.7M titles)

The complete findings, with every number traceable to `out/summary.csv`
(n=7 medians) are in **`report/report.pdf`**. The short version:

| question | measurement | answer |
|---|---|---|
| full scan, one core | 102.7M rows, 4.5% match | plain file **5693 ms** beats PostgreSQL **6778 ms** and openGauss **11685 ms** |
| full scan, four workers | same | PostgreSQL **2061 ms**, openGauss **3126 ms** (equal parallelism, 1.52x) |
| 2000 point lookups | indexed | file byte-index **25 ms**, PostgreSQL B-tree **47 ms**, openGauss **78 ms** |
| 2000 point lookups | no index | PostgreSQL 10.4 s, openGauss **66.9 s** per 10 lookups |
| 500 updates, 1 client | read-modify-write | file **0.02 s**, but file+fsync **0.52 s = PostgreSQL exactly** |
| 32,000 updates, 64 clients | read-modify-write | file **1/32000 survived**; PostgreSQL and openGauss 32000/32000 |
| `T -> Ttt`, 2M names | storage engines | growth: PostgreSQL heap +6.79%, ASTORE +8.36%, **USTORE +5.97%** |
| `VARCHAR(30)` + `CHECK` | 21 rows would break the rule | both engines refuse and roll back; the file creates them and reports nothing |
| bytes per row | same logical data | file **34.8**, PostgreSQL heap 64.7 (+ B-tree 92.9), openGauss 100.4 |

The four headline claims, and why they are worth reading:

1. **A plain file beats both DBMSs at a full scan on one core** — and the reason
   is byte count (1.77x more heap than TSV) plus MVCC visibility work. At equal
   parallelism, PostgreSQL is 1.7x faster than openGauss on one core and 1.5x
   with four threads.
2. **A hand-built file index beats both B-trees** (25 ms vs 47 ms vs 78 ms per
   2000 lookups) because the DBMS pays parse + plan + round trip *per query*.
3. **The file program's speed is the fsync it never performed.** At one client it
   is 26x faster than PostgreSQL; add `fsync` and it lands on PostgreSQL's number
   exactly (0.52 s both). From four clients up it silently loses 99.6-99.99% of
   updates.
4. **The DBMS can refuse.** 21 of 2,000,000 names break `VARCHAR(30)`; both
   engines roll the statement back with 0 rows changed, while the file program
   creates the violating rows and has no mechanism to report anything.

## Current status

**The full benchmark has been run.** 19 phases, 2 h 51 min (`out/full_run.log`),
plus two targeted re-runs to close gaps the first pass left (see below).

| what | state |
|---|---|
| PostgreSQL 18.6 (`postgres:18`) + openGauss-lite 7.0.0-RC3 | measured |
| identical configuration, every divergence enumerated | `out/guc_compare.md` |
| base load verified on both engines | 12,841,585 titles, 2,000,000 people |
| scale sweep 1x / 2x / 4x / 8x (up to 102,732,680 rows, 6.3 GB heap) | done |
| guardrails at every scale | all 0 |
| cross-backend equivalence check | `ok: all backends agree on every answer` |
| cold-cache series, re-measured with a uniform method | `out/cold_method.txt`, 803 drops logged |
| figures | `out/figures/`, 6 figures as PNG + SVG |
| report | `report/report.pdf` |

### Three gaps found after the first full run, and how they were closed

1. **No update rows.** The measure phases ran `MODES="scan point join"` and the
   storage-engine phase does its own, separate update measurement, so the
   benchmark-level `T -> Ttt` timing was never collected. `50_full_run.sh` now
   includes it; the data was collected by `scripts/61_gapfill.sh` (21 rows).
2. **An invalid storage comparison.** `36_storage_ab.sh` used to create the
   ASTORE/USTORE tables only if they did not exist, so it measured a 2,000,000-row
   PostgreSQL heap against a 16,489-row USTORE table left over from the filmdb
   phase. It now rebuilds whenever any target's row count differs, and the
   comparison was redone (`scripts/62_pointfix.sh`, `63_finalize.sh`).
3. **The file counter's fsync variant was pooled with the non-durable one**
   (n=14, shared median), which hid the project's single best comparison. The
   `impl()` label now carries `+fsync`, and the series was re-measured.

One further self-inflicted problem is worth recording because it shaped the
tooling: a mid-flight edit to `36_storage_ab.sh` corrupted the *running* instance,
because bash reads a script incrementally and an edit shifts the byte offsets.
Never edit a script another process is executing.

### Reproducing just the analysis

```bash
python3 analysis/analyze.py                       # medians, IQR, consistency check
. .tools/mpl.env && python3 analysis/plot.py      # the six figures
```

`out/raw.csv` is the consolidated dataset the report cites.
