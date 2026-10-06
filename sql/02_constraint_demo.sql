-- "The DBMS refuses; the file program silently complies."
--
-- The same T -> Ttt rewrite applied to a table that declares the integrity
-- rules a real schema would declare.  With IMDb-scale real names, plenty of
-- rows break `varchar(30)`, so the statement fails and is rolled back.
--
-- This is the experiment that answers question 1 with something other than a
-- stopwatch: a file program has no mechanism to even notice the violation.
--
-- Run whichever branch matches the engine (the file is included twice because
-- openGauss rejects some PG-only syntax; pick with \i).

\echo '--- strict table, PostgreSQL / openGauss -------------------------------'

DROP TABLE IF EXISTS bench_people_strict;
CREATE TABLE bench_people_strict (
    pid        BIGINT PRIMARY KEY,
    first_name VARCHAR(30),
    surname    VARCHAR(30),
    CONSTRAINT strict_name_len CHECK (
        length(coalesce(first_name,'')) <= 30 AND length(coalesce(surname,'')) <= 30
    )
);

-- Deliberately take the first 2,000,000 rows only: the point is the constraint
-- violation, not the row count.  Change the LIMIT if you want a bigger table.
INSERT INTO bench_people_strict
SELECT pid, first_name, surname
  FROM bench_people_active
 ORDER BY pid
 LIMIT 2000000;

\echo 'rows that the rewrite would push past the declared length:'
SELECT count(*) AS would_violate
  FROM bench_people_strict
 WHERE length(replace(coalesce(first_name,''),'T','Ttt')) > 30
    OR length(replace(coalesce(surname,''),'T','Ttt'))    > 30;

\echo 'now run the rewrite and watch it fail:'
UPDATE bench_people_strict
   SET first_name = replace(first_name,'T','Ttt'),
       surname    = replace(surname,'T','Ttt')
 WHERE coalesce(first_name,'') LIKE '%T%' OR coalesce(surname,'') LIKE '%T%';

\echo 'nothing was changed, because the statement rolled back:'
SELECT count(*) AS rows_already_updated
  FROM bench_people_strict
 WHERE first_name LIKE '%Ttt%' OR surname LIKE '%Ttt%';
