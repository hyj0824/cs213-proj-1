# Database configuration actually in effect

Captured 2026-10-18T10:40:27+00:00. Container memory limit: `10g`, server cpuset `0,2,4,6`.

Values are raw `pg_settings.setting` units (blocks, kB, ms) so that aligned
means byte-for-byte identical, not looks similar.

| parameter | PostgreSQL | openGauss | note |
|---|---|---|---|
| `shared_buffers` | `524288` | `524288` | aligned |
| `work_mem` | `65536` | `65536` | aligned |
| `maintenance_work_mem` | `1048576` | `1048576` | aligned |
| `max_connections` | `200` | `200` | aligned |
| `wal_level` | `replica` | `hot_standby` | equivalent, different spelling |
| `synchronous_commit` | `on` | `on` | aligned |
| `fsync` | `on` | `on` | aligned |
| `full_page_writes` | `on` | `on` | aligned |
| `checkpoint_timeout` | `900` | `900` | aligned |
| `max_wal_size` | `8192` | `-` | engine-specific (not applicable on the other side) |
| `random_page_cost` | `1.1` | `1.1` | aligned |
| `track_io_timing` | `on` | `on` | aligned |
| `autovacuum` | `off` | `off` | aligned |
| `jit` | `off` | `-` | engine-specific (not applicable on the other side) |
| `max_parallel_workers_per_gather` | `4` | `-` | engine-specific (not applicable on the other side) |
| `max_worker_processes` | `8` | `-` | engine-specific (not applicable on the other side) |
| `effective_cache_size` | `1310720` | `1310720` | aligned |
| `block_size` | `8192` | `8192` | aligned |
| `wal_block_size` | `8192` | `8192` | aligned |
| `enable_thread_pool` | `-` | `off` | engine-specific (not applicable on the other side) |
| `enable_incremental_checkpoint` | `-` | `off` | engine-specific (not applicable on the other side) |
| `io_method` | `worker` | `-` | engine-specific (not applicable on the other side) |
| `io_workers` | `3` | `-` | engine-specific (not applicable on the other side) |
| `enable_ustore` | `-` | `off` | engine-specific (not applicable on the other side) |
| `sql_compatibility` | `-` | `PG` | engine-specific (not applicable on the other side) |

Engine versions:

```
PostgreSQL : PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2) on x86_64-pc-linux-gnu, compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit  (postgres:18)
openGauss  : (openGauss-lite 7.0.0-RC3 build 01b7e318) compiled at 2026-03-25 18:41:08 commit 848 last mr 9114 release on x86_64-pc-linux-gnu, compiled by g++ (GCC) 10.3.0, 64-bit  (dbbench/opengauss:7.0.0-RC3)
```
