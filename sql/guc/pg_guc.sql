-- ============================================================================
-- Parameters set on PostgreSQL.  sql/guc/og_guc.sql sets the SAME absolute
-- values on openGauss; anything that exists on only one engine is marked
-- PG-ONLY / OG-ONLY and must be reported as an architectural difference.
--
-- Applied with ON_ERROR_STOP=0, so a failure here is logged, not fatal.
-- ============================================================================

ALTER SYSTEM SET shared_buffers           = '4GB';
ALTER SYSTEM SET work_mem                 = '64MB';
ALTER SYSTEM SET maintenance_work_mem     = '1GB';
ALTER SYSTEM SET effective_cache_size     = '10GB';
ALTER SYSTEM SET max_connections          = 200;

-- durability: identical on both engines ------------------------------------
ALTER SYSTEM SET wal_level                = 'replica';
ALTER SYSTEM SET synchronous_commit       = 'on';
ALTER SYSTEM SET fsync                    = 'on';
ALTER SYSTEM SET full_page_writes         = 'on';
ALTER SYSTEM SET checkpoint_timeout       = '15min';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET max_wal_size             = '8GB';
ALTER SYSTEM SET min_wal_size             = '1GB';

-- planner / costing ----------------------------------------------------------
ALTER SYSTEM SET random_page_cost         = 1.1;
ALTER SYSTEM SET seq_page_cost            = 1.0;
ALTER SYSTEM SET cpu_tuple_cost           = 0.01;

-- determinism ---------------------------------------------------------------
-- JIT ON is the default since PG12 and adds a per-query compile cost that
-- completely dominates micro-benchmarks of the form used here.  openGauss has
-- no JIT at all, so leaving it on would compare "PG + LLVM" with "openGauss".
-- We turn it off and discuss its absence in "Threats to validity".
ALTER SYSTEM SET jit                      = off;
ALTER SYSTEM SET huge_pages               = off;
ALTER SYSTEM SET track_io_timing          = on;
ALTER SYSTEM SET track_counts             = on;

-- Autovacuum is disabled during measurement so that no background process can
-- perturb a run.  Reclamation is then performed explicitly and measured as its
-- own step (scripts/36_storage_ab.sh) -- which is more informative anyway.
ALTER SYSTEM SET autovacuum               = off;

-- PG-ONLY: parallel query.  openGauss has no equivalent; the harness switches
-- this per session (--parallel 0|4) so both "as-shipped" and "single-core fair"
-- comparisons can be reported.
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;
ALTER SYSTEM SET max_worker_processes     = 8;
ALTER SYSTEM SET max_parallel_workers     = 8;

-- PG-ONLY: NVMe advice.  No openGauss equivalent.
ALTER SYSTEM SET effective_io_concurrency = 200;

-- PG18-ONLY: asynchronous I/O.  PostgreSQL 18 can hand storage I/O to a pool of
-- auxiliary processes (io_method = worker, the default) or issue it synchronously
-- (sync).  openGauss has neither concept, so this is an architectural difference
-- to report rather than a knob to align.  io_workers=3 is the PG18 default; set
-- explicitly so the value cannot drift between runs.
ALTER SYSTEM SET io_method  = 'worker';
ALTER SYSTEM SET io_workers = 3;

SELECT pg_reload_conf();
