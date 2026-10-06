-- Bootstrap: every table the experiments use.  Idempotent.
--
--   bench_titles_base / bench_people_base : the raw loaded dataset (IMDb).
--        34_amplify.sh derives the *_active tables from these at scale 1/2/4/8.
--        For the small filmdb dataset there is no base table: 30_load_filmdb.sh
--        fills the *_active tables directly.
--   bench_titles_active : one row per title.  The PK on id is toggled by
--        scripts/35_toggle_index.sh to create the "same query, two physical
--        designs" comparison.
--   bench_people_active : one row per person.  Target of the T -> Ttt update.
--   bench_counter       : single row, the lost-update / durability experiment.

DROP TABLE IF EXISTS bench_titles_base;
CREATE TABLE bench_titles_base (
    id    BIGINT PRIMARY KEY,
    title TEXT   NOT NULL
);

DROP TABLE IF EXISTS bench_people_base;
CREATE TABLE bench_people_base (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
);

DROP TABLE IF EXISTS bench_titles_active;
CREATE TABLE bench_titles_active (
    id    BIGINT PRIMARY KEY,
    title TEXT   NOT NULL
);

DROP TABLE IF EXISTS bench_people_active;
CREATE TABLE bench_people_active (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
);

-- Provenance: bench_titles_active is *derived* from bench_titles_base, and a
-- stale derived table is invisible but invalidates everything. These timestamps
-- are what let 34_amplify.sh notice that the base was reloaded afterwards.
DROP TABLE IF EXISTS bench_meta;
CREATE TABLE bench_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

DROP TABLE IF EXISTS bench_counter;
CREATE TABLE bench_counter (
    id INT PRIMARY KEY,
    v  BIGINT NOT NULL
);
INSERT INTO bench_counter VALUES (0, 0);

ANALYZE bench_titles_active;
ANALYZE bench_people_active;
