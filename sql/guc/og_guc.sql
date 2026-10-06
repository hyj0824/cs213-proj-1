-- ============================================================================
-- Parameters set on openGauss.  Mirrors sql/guc/pg_guc.sql value for value.
--
-- Statements that reference a parameter openGauss does not have will fail;
-- gsql continues by default and scripts/20_align_guc.sh reports the failures.
-- Those failures are themselves a reportable finding (the two engines do not
-- even expose the same knob set).
-- ============================================================================

ALTER SYSTEM SET shared_buffers           = '4GB';
ALTER SYSTEM SET work_mem                 = '64MB';
ALTER SYSTEM SET maintenance_work_mem     = '1GB';
ALTER SYSTEM SET max_connections          = 200;

-- durability: identical on both engines ------------------------------------
-- openGauss spells PG's wal_level='replica' as 'hot_standby'.
ALTER SYSTEM SET wal_level                = 'hot_standby';
ALTER SYSTEM SET synchronous_commit       = 'on';
ALTER SYSTEM SET fsync                    = 'on';
ALTER SYSTEM SET full_page_writes         = 'on';
ALTER SYSTEM SET checkpoint_timeout       = '15min';

-- determinism ---------------------------------------------------------------
ALTER SYSTEM SET random_page_cost         = 1.1;
ALTER SYSTEM SET track_io_timing          = on;
ALTER SYSTEM SET autovacuum               = off;

-- OG-ONLY: thread-pool model.  This is the single biggest architectural
-- difference for the high-concurrency experiment; the harness must run the
-- sweep both with and without it rather than leaving it at whatever the image
-- shipped with.
ALTER SYSTEM SET enable_thread_pool       = off;

-- OG-ONLY: allow md5 authentication so that the stock PostgreSQL JDBC driver
-- still works if the opengauss-jdbc artifact cannot be fetched (fallback path
-- documented in benchmark/lib/README.md).
ALTER SYSTEM SET password_encryption_type = 0;

-- OG-ONLY: keep the WAL segment accounting comparable; openGauss exposes
-- max_wal_size in some builds only.
ALTER SYSTEM SET max_wal_size             = '8GB';
