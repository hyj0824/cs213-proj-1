-- Storage-engine A/B for openGauss: ASTORE (append update) vs USTORE (in place
-- update).  PostgreSQL only has the append-update design, so the three-way
-- comparison is PG-heap vs OG-ASTORE vs OG-USTORE.
--
-- This is the openGauss-specific finding: the T -> Ttt update GROWS every
-- touched row, which is the worst case for an append-only heap (every updated
-- version is a new tuple, the old one becomes dead space that only VACUUM can
-- reclaim).  USTORE keeps the live version in place and puts the previous
-- version in undo space, so the table should not bloat.
--
-- openGauss >= 2.1 only.  If `storage_type=USTORE` errors out, the image is too
-- old -- record that in the report and carry on with ASTORE only.

DROP TABLE IF EXISTS bench_people_ustore;
CREATE TABLE bench_people_ustore (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
) WITH (storage_type = USTORE);

DROP TABLE IF EXISTS bench_people_astore;
CREATE TABLE bench_people_astore (
    pid        BIGINT PRIMARY KEY,
    first_name TEXT,
    surname    TEXT
) WITH (storage_type = ASTORE);

INSERT INTO bench_people_ustore SELECT pid, first_name, surname FROM bench_people_active;
INSERT INTO bench_people_astore SELECT pid, first_name, surname FROM bench_people_active;

ANALYZE bench_people_ustore;
ANALYZE bench_people_astore;
