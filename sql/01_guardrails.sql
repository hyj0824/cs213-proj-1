-- Guard rails for the canonical semantics of the experiments.
--
-- Run after loading and before measuring. Every query here must return 0.
-- A non-zero answer means the file-side reader (line oriented, one record per
-- line) would NOT be equivalent to the SQL side, so the comparison would be
-- invalid. Failing loudly here is much cheaper than discovering it in the report.
--
--   docker exec -i -e PGPASSWORD=bench dbbench-pg psql -U bench -d bench -X -q -f - < sql/01_guardrails.sql

\echo '1. titles containing a tab (would shift fields in the TSV export):'
SELECT count(*) FROM bench_titles_active WHERE title LIKE '%' || chr(9) || '%';

\echo '2. titles containing CR/LF (would break one-record-per-line reading):'
SELECT count(*) FROM bench_titles_active
 WHERE title LIKE '%' || chr(13) || '%' OR title LIKE '%' || chr(10) || '%';

-- Not a guard but a property test, and the reason the two predicates may be
-- interchanged: LIKE and a plain substring search must agree even on the titles
-- that contain LIKE's own metacharacters (there are ~5000 % and _ in the IMDb
-- titles). Keywords themselves are restricted to [A-Za-z0-9 ] by the harness,
-- so the only risk is in the data, and this is where it is checked.
\echo '3. disagreements between LIKE and strpos on metacharacter-heavy titles:'
SELECT count(*) AS disagreements FROM (
  SELECT title FROM bench_titles_active
   WHERE title LIKE '%\%%' OR title LIKE '%\_%'
   ORDER BY id
   LIMIT 200000
) s
WHERE (title LIKE '%the%') <> (position('the' in title) > 0);

\echo '4. names containing CR/LF:'
SELECT count(*) FROM bench_people_active
 WHERE coalesce(first_name,'') LIKE '%' || chr(10) || '%'
    OR coalesce(surname,'')    LIKE '%' || chr(10) || '%';

\echo '5. rows the update predicate matches (this is the expected row count):'
SELECT count(*) FROM bench_people_active
 WHERE coalesce(first_name,'') LIKE '%T%' OR coalesce(surname,'') LIKE '%T%';
