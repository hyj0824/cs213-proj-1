// ============================================================================
//  Project 1: DBMS Performance Evaluation
//  Build:  typst compile --root . report/report.typ report/report.pdf
// ============================================================================

#set page(
  paper: "a4",
  margin: (x: 2cm, y: 1.7cm),
  numbering: "1",
  header: {
    [DBMS Performance Evaluation #h(1fr) CS213 · Linpu Yu · 12510430]
    line(length: 100%)
  },
)
#set text(font: ("New Computer Modern", "DejaVu Sans"), size: 10.5pt, lang: "en")
#set par(justify: true, leading: 0.72em, spacing: 0.95em)
#set heading(numbering: "1.1")
#show heading.where(level: 1): set block(above: 1.5em, below: 0.8em)
#show heading.where(level: 1): set text(size: 14pt)
#show heading.where(level: 2): set block(above: 1.1em, below: 0.6em)
#show heading.where(level: 2): set text(size: 11.5pt)
#set figure(gap: 0.55em)
#show figure.caption: set text(size: 9pt)
#show table.cell: set text(size: 9.0pt)
#show table.cell: set par(justify: false)
#show raw.where(block: true): it => block(fill: luma(247), inset: 7pt, radius: 2pt, width: 100%, it)
#show raw.where(block: true): set text(size: 8.6pt)
#set table(stroke: none, inset: (x: 5pt, y: 3.2pt))
#show link: set text(fill: rgb("#1a5fb4"))

#import "tables.typ": *

// --- small drawing helpers for the two diagrams ----------------------------

#let panel(title, body, h: 15mm) = block(
  width: 100%,
  height: h,
  inset: (x: 5pt, y: 4pt),
  radius: 2.5pt,
  stroke: 0.6pt + luma(125),
  fill: luma(249),
  align(center + horizon)[
    #text(weight: "bold", size: 9pt)[#title]
    #linebreak()
    #text(size: 8.2pt)[#body]
  ],
)

#let flowstep(title, body) = block(
  width: 100%,
  height: 17mm,
  inset: (x: 4pt, y: 3pt),
  radius: 2.5pt,
  stroke: 0.6pt + luma(125),
  fill: luma(249),
  align(center + horizon)[
    #text(weight: "bold", size: 8.6pt)[#title]
    #linebreak()
    #text(size: 7.8pt)[#body]
  ],
)

#align(center)[
  #title(text(size: 20pt)[Project 1: DBMS Performance Evaluation])

  #link("https://github.com/hyj0824/cs213-proj-1")[https://github.com/hyj0824/cs213-proj-1]
]

// ===========================================================================
#heading("Summary", level: 1, numbering: none)

*Q1. What are the unique advantages of a DBMS compared with data operations in files?*

The advantage is correctness and guarantees under concurrency, not raw speed.
In single-threaded mode, the project's file "database" scans the full data in
5.7 s against 6.8 s for PostgreSQL and 11.7 s for openGauss, and it answers
2,000 indexed lookups in 25 ms against 50 and 82 ms.

Once the work is parallel, the databases win: they keep the result correct under
concurrent writers, and they supply rollback, constraints, durable commits,
and maintained indexes.

*Q2. Which DBMS is better? PostgreSQL or openGauss, and by which standard?*

PostgreSQL, on almost every standard the project tests: 1.7x on one core, 1.5x
at four workers, 1.6x on indexed lookups.

openGauss's USTORE keeps the smallest relation after a growing update, but it
has higher update latency and stores undo outside the relation size. That is a
space trade-off.


#heading("Environment")

The project has one Java client that tests all three backends through a single
interface. The data sits on a host bind mount shared by the containers, which
reduces the latency of Docker's `overlay2fs`.

#figure(
  table(
    columns: (auto, 1fr),
    align: (left, left),
    stroke: none,
    table.hline(stroke: 0.6pt),
    table.header([*Item*], [*Value*]),
    table.hline(stroke: 0.3pt),
    [CPU], [Intel i5-12400F, 6 cores / 12 threads; 4 server cores, 2 client cores],
    [Memory], [16 GiB host; 4 GB `shared_buffers` per engine],
    [Storage], [NVMe, ext4; data on a host bind mount],
    [OS], [Ubuntu 22.04.5, kernel 6.8.0-138],
    [JVM], [OpenJDK 17.0.20.1],
    [Engines], [PostgreSQL 18.6; openGauss 7.0.0, both in Docker],
    [Drivers], [pgJDBC 42.7.4; openGauss JDBC 5.0.0],
    table.hline(stroke: 0.6pt),
  ),
  caption: [
    Hardware and software. The full configuration is in Appendix B.
  ],
) <t_env>

// ===========================================================================
#heading("Design")

The report answers two questions: what a DBMS adds beyond file I/O, and which
of the two engines is better. The same four operations are implemented three
times, separately for PostgreSQL, openGauss, and a Java file backend.

#heading("Data and equivalence", level: 2)

The data is the IMDb non-commercial dump with 12,841,585 titles and 2,000,000
person names. The large table is eight copies of the title base with disjoint id
ranges, which turns 12.8M rows into 102.7M without changing the title
distribution. The sizes tested are 12.8M, 25.7M, 51.4M, and 102.7M rows.

PostgreSQL exports the TSV that the file backend reads, so all three backends
see the same rows. A timing is reported only after the backends agree on the
result.

#heading("The four functions", level: 2)

#figure(
  table(
    columns: (auto, auto, 1.25fr, auto),
    align: (left, left, left, left),
    stroke: none,
    table.hline(stroke: 0.6pt),
    table.header([*Function*], [*SQL backend*], [*File backend*], [*Unit*]),
    table.hline(stroke: 0.3pt),
    [Scan],
    [`count(*) WHERE title LIKE '%kw%'`],
    [`title.contains(kw)`, one streaming pass],
    [1 pass],
    [Point],
    [`SELECT ... WHERE id = ?`, prepared],
    [binary search on a sorted file by offset index],
    [2,000 keys],
    [Update],
    [`replace(name,'T','Ttt')`],
    [`String.replace`, then rewrite the file],
    [2M rows],
    [Counter],
    [`UPDATE ... SET v = v + 1`],
    [read-modify-write `counter.txt` + optional `fsync`],
    [N × 500],
    table.hline(stroke: 0.6pt),
  ),
  caption: [
    One SQL statement per operation; the full SQL is in Appendix A.
  ],
) <t_ops>

The four functions cover the costs that separate a DBMS from a file: sequential
reading (scan), index lookup (point), extra writes and space reuse
(update), and concurrent correctness plus durability (counter).

Two design choices affect fairness. The SQL point batch issues 2,000 separate
single-row queries, which is what a client pays to read one row; a set-based
`id = ANY` query would avoid that cost and was not tested. The file index is a
sorted copy plus 8-byte offsets, built offline and not maintained during writes;
the B-tree is. Without its index, the file finds the same keys in one pass.

#heading("How the runs are grouped", level: 2)

#figure(
  table(
    columns: (auto, 1fr, 1.25fr),
    align: (left, left, left),
    stroke: none,
    table.hline(stroke: 0.6pt),
    table.header([*Group*], [*What changes*], [*What it tests*]),
    table.hline(stroke: 0.3pt),
    [Scan],
    [Table size (four scales) and keyword selectivity (four keywords)],
    [Whether selectivity changes a full scan; a leading wildcard cannot use the primary-key B-tree],
    [Point],
    [Index on or off; four table sizes; 2,000 indexed keys],
    [Index cost against the fixed cost of starting a query],
    [Update],
    [Storage engine (PostgreSQL heap, ASTORE, or USTORE); a declared length limit],
    [Space growth, space recovery, and rule enforcement],
    [Counter],
    [1, 4, 16, or 64 clients; file `fsync` on or off; both databases keep `fsync` on],
    [Lost updates and the price of durability],
    table.hline(stroke: 0.6pt),
  ),
  caption: [
    The four experiment groups.
  ],
) <t_matrix>

Comparisons run at matched parallelism: PostgreSQL uses no parallel workers in
its one-core series and four in the four-worker series, openGauss uses one
thread by default (`query_dop=1`) and four in the parallel test, and the file
backend is always single-threaded. Rows with four workers therefore compare the
two databases, not the database with the file.

// ===========================================================================
#heading("Implementation")

#heading("Architecture", level: 2)

`Main` parses the options and runs the repetitions, `Semantics` holds the single
definition of each operation, and `Backend` is implemented by `SqlBackend` and
`FileBackend`. Sharing one definition keeps the three sides comparable: a
change cannot silently apply to one backend only.

#figure(
  {
    grid(
      columns: (1fr, 1fr, 1fr),
      column-gutter: 6pt,
      row-gutter: 3pt,
      panel([`Main` / `DBBench`], [parses args, runs repetitions], h: 12mm),
      panel([`Semantics`], [defines each operation once], h: 12mm),
      panel([`Stats` / `RawCsv`], [latency, result, CSV], h: 12mm),
      grid.cell(colspan: 3, block(
        width: 100%,
        inset: (x: 5pt, y: 3pt),
        radius: 2.5pt,
        stroke: 0.6pt + luma(125),
        fill: luma(243),
        align(center)[
          #text(weight: "bold", size: 10pt)[Backend interface]
        ],
      )),
      grid.cell(colspan: 2, panel(
        [`SqlBackend` (JDBC)],
        [prepared statements → PostgreSQL / openGauss],
        h: 14mm,
      )),
      panel([`FileBackend` (TSV)], [streaming reader, offset index], h: 14mm),
      panel([PostgreSQL 18.6], [server · 4 cores], h: 13mm),
      panel([openGauss 7.0.0], [server · 4 cores], h: 13mm),
      panel([File backend], [TSV · client side], h: 13mm),
    )
  },
  kind: "image",
  supplement: [Figure],
  caption: [
    The benchmark components.
  ],
) <fig_arch>

#heading("SQL backends", level: 2)

`SqlBackend` uses JDBC prepared statements and no ORM. A scan is a `count(*)`
with a `LIKE` parameter, point lookups reuse one prepared single-row `SELECT`,
the update is one statement with `replace`, and the counter is a single
`UPDATE`. Connection setup is outside the timed region; statement execution and
row transfer are inside it. Each repetition starts from a restored table state,
so a case measures one operation, not the leftover space from the run before.

#heading("File backend", level: 2)

`FileBackend` has three physical layouts: a sequential scan, a sorted copy plus
a fixed-width offset index for point lookups, and a rewrite of the whole file for
updates. Updates and counter writes can call `FileChannel.force` to pay the same
durability cost as a commit. The backend is single-threaded.

#heading("Measurement steps", level: 2)

#figure(
  {
    grid(
      columns: (1fr, auto, 1fr, auto, 1fr, auto, 1fr),
      column-gutter: 3pt,
      flowstep([Prepare], [load rows, check counts, #linebreak() restore state]),
      align(center + horizon)[#text(size: 12pt)[→]],
      flowstep([Warm up], [one run, discarded]),
      align(center + horizon)[#text(size: 12pt)[→]],
      flowstep([Time 7 runs], [warm: no cache drop; #linebreak() cold: drop before each]),
      align(center + horizon)[#text(size: 12pt)[→]],
      flowstep([Check and record], [results agree; median #linebreak() and IQR to `summary.csv`]),
    )
  },
  kind: "image",
  supplement: [Figure],
  caption: [
    One measured case.
  ],
) <fig_flow>

Cold cases drop the OS page cache before every repetition and leave
`shared_buffers` intact, so the cold number is not a true cold start. Reported
values are medians of seven runs; the IQRs are in the data files.

// ===========================================================================
#heading("Results and Evaluation")

#heading("Full scan: bytes and row checks", level: 2)

#figure(t_scan_main, caption: [
  Warm full scan for `the`, median of 7.
]) <t_scan_main>

On one core the file wins at every size. At 102.7M rows it needs 5.69 s against
6.78 s for PostgreSQL and 11.69 s for openGauss. Two things explain the gap:
the file reads 3.58 GB of TSV where the heap is 6.64 GB, and it performs no
visibility check on each row.

Selectivity changes the numbers, not the ranking. Across keywords matching 0.05%
to 50% of rows, database times move by 10 to 13%, and every engine still reads
every row because a leading wildcard cannot use a B-tree (@t_sel). Cold runs are
closer: with the OS page cache dropped, PostgreSQL is 6% faster than the file at
102.7M (6.93 s against 7.39 s), because `shared_buffers` still holds part of the
heap. @fig1 shows both series; the lines are parallel, so the gap stays about
the same.

#figure(kind: "image", supplement: [Figure], image("../out/figures/fig1_scan_scale.png", width: 68%), caption: [
  Scan time against size; solid is warm, dashed is cold.
]) <fig1>

#heading("Point lookups: a fixed cost per query", level: 2)

#figure(t_point_main, caption: [
  Warm point lookups by key, median of 7.
]) <t_point_main>

The file's offset index answers 2,000 keys in 25.4 ms, PostgreSQL in 50.4 ms,
and openGauss in 81.6 ms. All three take about the same time at every table
size, for different reasons. The file performs one binary search per key over a
compact offset array. The databases pay a fixed cost for protocol, parsing,
planning, and execution on every query; at this scale that cost is the whole
cost.

The file index is smaller (8.0 bytes/row against 28.2 for the PostgreSQL B-tree)
because it stores offsets into a sorted copy rather than keys and heap pointers.
Remove the index and the result reverses: 10 unindexed lookups cost PostgreSQL
10.4 s and openGauss 66.9 s (@t_point). A set-based `id = ANY` query would
reduce the per-query overhead and was not tested, so the file's advantage
applies only to single-row queries from the client.

#heading("Growing update: space and latency", level: 2)

#figure(t_storage_main, caption: [
  `T → Ttt` on 2M names; sizes include the index.
]) <t_storage_main>

The rewrite grows every touched row, the worst case for an append-only heap.
PostgreSQL's heap grows 6.79%, openGauss ASTORE 8.36%, and USTORE 5.97%. USTORE
achieves the smaller relation by keeping the live row in place and moving the
old version to undo space, which `pg_relation_size` does not count. It also has
the highest update latency: 1,395 ms against 610 ms for PostgreSQL and 796 ms for
ASTORE. The space saving is real, but it comes with that latency.

`VACUUM FULL` restores PostgreSQL and USTORE to within about 0.2% of their
starting size; ASTORE does not return to its starting size. The file backend
rewrites the 2M-row file in 151.7 ms without fsync, faster than any database, but
it rewrites everything, blocks writers, cannot roll back, and checks no
constraint. @t_storage and @fig3_update in Appendix C give the full storage table
and the VACUUM time.

#heading("Constraints: the database can refuse", level: 2)

The same rewrite on a table with `VARCHAR(30)` and a matching `CHECK` shows what
a constraint adds. At every limit tested, both databases refuse the statement
and roll back with zero rows changed. The file backend writes the
violating rows and reports nothing: at `n = 10` it creates 11,815 violations on
top of 193,444 already-invalid rows; at `n = 30` it still creates 21. A file
program can check a limit if it is written to, but the check is not part of the
data model and does not cover every writer. @t_constraint in Appendix C lists
every limit.

#heading("Concurrency and durability", level: 2)

#figure(t_conc_main, caption: [
  Counter with N clients, 500 increments each.
]) <t_conc_main>

The file backend is fastest at one client because it never asks the disk to
confirm the write. Add one fsync per update and it takes 0.52 s, the same as
PostgreSQL.

However, at 64 clients the file backend keeps only 1 of all 32,000 increments (7 with fsync), while both databases keep all 32,000. No amount of buffering or retrying fixes this and the correctness needs a lock or a transaction manager.

#figure(kind: "image", supplement: [Figure], image("../out/figures/fig4_concurrency.png", width: 68%), caption: [
  Share of updates that survived.
]) <fig4>

#heading("Which database is better", level: 2)

#figure(t_score_main, caption: [
  Comparison at 102.7M rows unless noted.
]) <t_score_main>

PostgreSQL wins every database-to-database row: 1.72x on one core, 1.52x at four
workers, 1.62x on indexed lookups, and about 2x on committed durability. Its
B-tree is also smaller (28.2 against 35.6 bytes per row). openGauss's only win is
the relation size after the growing update, and that comparison excludes USTORE's
undo. At equal parallelism PostgreSQL is the better default for this workload;
USTORE is worth considering only when space after a growing update is what
matters most. The full comparison is @t_score in Appendix C.

#heading("Limits", level: 2)

- Single machine and one dataset. Absolute times do not carry over to other
  machines; the ratios do.
- The 102.7M-row table is eight copies of the title base, so the title
  distribution repeats.
- The file backend is single-threaded Java on the client cores. A parallel, C,
  or `mmap` version was not tested; it would likely narrow the scan gap.
- Cold runs retain `shared_buffers`. There is no crash-recovery test, so
  durability here means fsync on commit.
- The counter uses one row. No multi-row transactions, isolation levels, or
  read/write mixes were tested.
- Measurements are medians of seven runs; no formal significance test was run.

#heading("Conclusion")

On a warm full scan and on indexed point lookups, a plain file can beat both
databases in this setup: it reads fewer bytes, pays no visibility cost on each
row, and pays no per-query overhead. That advantage disappears once the work
needs concurrent increments, rollback, constraints, or recovery. PostgreSQL
is the stronger general-purpose engine at equal parallelism; openGauss's USTORE
is a space trade-off with higher write latency, not a throughput alternative.
The numbers read like a price list: the file is cheaper because it does not buy
the guarantees.

// ===========================================================================
#heading("References", level: 1, numbering: none)

1. PostgreSQL 18 documentation. #link("https://www.postgresql.org/docs/18/")[postgresql.org/docs/18].
2. openGauss documentation. #link("https://docs.opengauss.org/")[docs.opengauss.org].
3. IMDb datasets. #link("https://datasets.imdbws.com/")[datasets.imdbws.com].
4. PostgreSQL JDBC driver. #link("https://jdbc.postgresql.org/")[jdbc.postgresql.org].
5. openGauss JDBC driver. #link("https://gitee.com/opengauss/openGauss-connector-jdbc")[gitee.com/opengauss/openGauss-connector-jdbc].


#pagebreak()

// ===========================================================================
#heading("Appendix A: SQL used in the experiments", level: 1, numbering: none)

The full scripts, including the data-loading and cache-control helpers, are in
`sql/`.

#heading("A.1 Schema", level: 2, numbering: none)

```sql
CREATE TABLE bench_titles_active (
    id    BIGINT PRIMARY KEY,
    title TEXT   NOT NULL
);

CREATE TABLE bench_people_active (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
);

CREATE TABLE bench_counter (
    id INT PRIMARY KEY,
    v  BIGINT NOT NULL
);
INSERT INTO bench_counter VALUES (0, 0);
```

#heading("A.2 Retrieval", level: 2, numbering: none)

```sql
-- scan: one statement, keyword bound as a parameter
SELECT count(*) FROM bench_titles_active WHERE title LIKE '%the%';

-- point: one prepared statement, executed 2,000 times
SELECT id FROM bench_titles_active WHERE id = ?;
```

#heading("A.3 Update", level: 2, numbering: none)

```sql
UPDATE bench_people_active
   SET first_name = replace(first_name, 'T', 'Ttt'),
       surname    = replace(surname,    'T', 'Ttt')
 WHERE coalesce(first_name,'') LIKE '%T%'
    OR coalesce(surname,'')    LIKE '%T%';
```

#heading("A.4 Constraint check", level: 2, numbering: none)

```sql
CREATE TABLE bench_people_strict (
    pid        BIGINT PRIMARY KEY,
    first_name VARCHAR(30),
    surname    VARCHAR(30),
    CONSTRAINT strict_name_len CHECK (
        length(coalesce(first_name,'')) <= 30 AND
        length(coalesce(surname,''))    <= 30
    )
);

-- the UPDATE above is then refused and rolled back by both engines
```

#heading("A.5 Storage engines and sizes", level: 2, numbering: none)

```sql
CREATE TABLE bench_people_astore (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
) WITH (storage_type = ASTORE);

CREATE TABLE bench_people_ustore (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
) WITH (storage_type = USTORE);

SELECT pg_relation_size('bench_titles_active') AS heap,
       pg_indexes_size('bench_titles_active')  AS index;
```

#heading("A.6 Data checks", level: 2, numbering: none)

```sql
-- all of these must return 0
SELECT count(*) FROM bench_titles_active
 WHERE title LIKE '%' || chr(9) || '%';
SELECT count(*) FROM bench_titles_active
 WHERE title LIKE '%' || chr(13) || '%'
    OR title LIKE '%' || chr(10) || '%';

-- LIKE and substring must agree on the same 200,000 titles
SELECT count(*) FROM (
  SELECT title FROM bench_titles_active
   WHERE title LIKE '%\%%' OR title LIKE '%\_%'
   ORDER BY id
   LIMIT 200000
) s
WHERE (title LIKE '%the%') <> (position('the' in title) > 0);
```

#pagebreak()

// ===========================================================================
#heading("Appendix B: Configuration", level: 1, numbering: none)

The server container is pinned to physical cores `0,2,4,6` and the client to
`8,10`, with no hyperthread sharing between them. The two engine containers
never run at the same time. Cold runs write `3` to
`/proc/sys/vm/drop_caches` before each repetition and leave `shared_buffers`
intact.

#figure(t_guc, caption: [
  Server parameters.
]) <t_guc>

PostgreSQL ran with JIT off and `max_parallel_workers_per_gather` at 0 or 4;
openGauss ran with `query_dop` at 1 or 4 and chose ASTORE or USTORE per table.
Both engines keep `fsync` and `synchronous_commit` on.


#pagebreak()
// ===========================================================================
#heading("Appendix C: Full measurement tables", level: 1, numbering: none)

#heading("C.1 Parallel scan", level: 2, numbering: none)

#figure(t_parallel, caption: [
  Warm full scan at 102.7M rows.
]) <t_parallel>

#heading("C.2 Cold cache", level: 2, numbering: none)

#figure(t_cold, caption: [
  Cold full scan; `shared_buffers` is not cleared.
]) <t_cold>

#heading("C.3 Selectivity", level: 2, numbering: none)

#figure(t_sel, caption: [
  Warm scan time by keyword at 102.7M rows, median of 7.
]) <t_sel>

#heading("C.4 Point lookups, including the unindexed case", level: 2, numbering: none)

#figure(t_point, caption: [
  Warm point lookups; SQL no-index columns use 10 keys.
]) <t_point>

#figure(kind: "image", supplement: [Figure], image("../out/figures/fig5_point_scale.png", width: 66%), caption: [
  Indexed point lookups against size.
]) <fig5>

#heading("C.5 Storage and engine details", level: 2, numbering: none)

#figure(t_bytes, caption: [
  Storage per row at 102.7M rows, index included.
]) <t_bytes>

#figure(t_storage, caption: [
  Growing update on 2M names; autovacuum is off.
]) <t_storage>

#figure(kind: "image", supplement: [Figure], image("../out/figures/fig3_update_cost.png", width: 78%), caption: [
  Update cost: growth, dead tuples, and `VACUUM FULL` time.
]) <fig3_update>

#heading("C.6 Constraint checks", level: 2, numbering: none)

#figure(t_constraint, caption: [
  Constraint test; the file keeps every row.
]) <t_constraint>

#heading("C.7 Full comparison", level: 2, numbering: none)

#figure(t_score, caption: [
  Comparison by dimension
]) <t_score>

USTORE saves space only in the relation: its undo is outside
`pg_relation_size`; its update latency is 1,395 ms against 610 ms.


#pagebreak()
// ===========================================================================
#heading("Appendix D: Source and reproducibility", level: 1, numbering: none)

#figure(
  table(
    columns: (auto, 1fr),
    align: (left, left),
    stroke: none,
    table.hline(stroke: 0.6pt),
    table.header([*Path*], [*Contents*]),
    table.hline(stroke: 0.3pt),
    [`DBBench.java`], [Single-file submission build of the benchmark],
    [`benchmark/src/bench/`], [Modular benchmark code: `Main`, `Semantics`, `SqlBackend`, `FileBackend`],
    [`sql/`], [Schema, data checks, constraint, storage-engine, and size scripts],
    [`scripts/`], [Load, duplicate, export, run, restore, and cache scripts],
    [`analysis/`, `report/gen_tables.py`], [Consistency checks, figures, and generated tables],
    [`out/raw.csv`, `out/summary.csv`], [Per-run measurements and the medians used here],
    table.hline(stroke: 0.6pt),
  ),
  caption: [Where the code and the measured data live.],
) <t_source>

```bash
# compile and run one case
javac -cp "lib/*" DBBench.java
java -cp ".:lib/*" DBBench --backend file --mode scan \
     --keyword the --data ./data

# regenerate the tables and the PDF
python3 report/gen_tables.py
typst compile --root . report/report.typ report/report.pdf
```
