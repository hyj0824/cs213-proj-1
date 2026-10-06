-- What the report's cost accounting is actually made of.
--
-- Byte-level numbers matter more than milliseconds here: they are stable
-- across runs, they explain WHY one side is slower, and they are the only way
-- to make the "what does the DBMS's guarantee cost?" argument quantitative.
--
-- Run with:  psql -f sql/04_size_accounting.sql   (values come from shell vars)

\echo '=== logical rows ==='
SELECT 'titles' AS t, count(*) AS rows FROM bench_titles_active
UNION ALL SELECT 'people', count(*) FROM bench_people_active;

\echo '=== physical bytes: heap vs index (PG: pg_relation_size / pg_indexes_size) ==='
SELECT pg_size_pretty(pg_relation_size('bench_titles_active')) AS titles_heap,
       pg_size_pretty(pg_indexes_size('bench_titles_active'))  AS titles_index,
       pg_size_pretty(pg_relation_size('bench_people_active')) AS people_heap,
       pg_size_pretty(pg_indexes_size('bench_people_active'))  AS people_index;

\echo '=== bytes per row, the number that goes in the cost table ==='
SELECT round(pg_relation_size('bench_titles_active')::numeric / greatest(count(*),1), 2) AS heap_bytes_per_title_row,
       round(pg_relation_size('bench_people_active')::numeric / greatest((SELECT count(*) FROM bench_people_active),1), 2) AS heap_bytes_per_person_row
  FROM bench_titles_active;

\echo '=== database total (WAL not included) ==='
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;

\echo '=== WAL generated so far (PG >= 10) ==='
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')) AS wal_written;
