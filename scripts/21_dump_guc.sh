#!/usr/bin/env bash
# Dump the run-time values of the parameters that matter and write a Markdown
# table straight into the report.  Divergences are flagged with "!!" so the
# "Threats to validity" section can cite them instead of hand-waving.
source "$(dirname "$0")/lib.sh"

OUT="${1:-$OUT_DIR/guc_compare.md}"

# Parameters we deliberately set identically, plus the ones that differ by
# design and therefore must be reported as architectural differences.
PARAMS="shared_buffers work_mem maintenance_work_mem max_connections wal_level
synchronous_commit fsync full_page_writes checkpoint_timeout max_wal_size
random_page_cost track_io_timing autovacuum jit max_parallel_workers_per_gather
max_worker_processes effective_cache_size block_size wal_block_size
enable_thread_pool enable_incremental_checkpoint
io_method io_workers enable_ustore sql_compatibility"

# pg_settings rather than current_setting(): openGauss 5.0 is based on
# PostgreSQL 9.2, where current_setting() takes no second argument, so the
# portable form is to read the catalog view. A parameter that does not exist
# returns no row, which becomes "-".
get_pg() { local v; v="$(pg_sql -tAc "select setting from pg_settings where name='$1'" 2>/dev/null)"; echo "${v:--}"; }
get_og() { local v; v="$(og_sql -tAc "select setting from pg_settings where name='$1'" 2>/dev/null)"; echo "${v:--}"; }

{
  echo "# Database configuration actually in effect"
  echo
  echo "Captured $(date -Is). Container memory limit: \`$CTR_MEM\`, server cpuset \`$SERVER_CPUS\`."
  echo
  echo "Values are raw \`pg_settings.setting\` units (blocks, kB, ms) so that "aligned"
means byte-for-byte identical, not "looks similar".

| parameter | PostgreSQL | openGauss | note |"
  echo "|---|---|---|---|"
  # Values that are the same setting under different names. Reporting these as
  # misconfigurations would bury the real divergences in noise.
  equivalent() { # name a b -> 0 when known-equivalent
    case "$1:$2:$3" in
      wal_level:replica:hot_standby|wal_level:hot_standby:replica) return 0 ;;
      *) return 1 ;;
    esac
  }

  for p in $PARAMS; do
    a="$(get_pg "$p" | head -1 | tr -d '[:space:]')"; a="${a:--}"
    b="$(get_og "$p" | head -1 | tr -d '[:space:]')"; b="${b:--}"
    if [ "$a" = "-" ] && [ "$b" = "-" ]; then note="not reported by either engine"
    elif [ "$a" = "-" ] || [ "$b" = "-" ]; then note="engine-specific (not applicable on the other side)"
    elif [ "$a" = "$b" ]; then note="aligned"
    elif equivalent "$p" "$a" "$b"; then note="equivalent, different spelling"
    else note="**DIFFERS** -- must be discussed"; fi
    printf '| `%s` | `%s` | `%s` | %s |\n' "$p" "$a" "$b" "$note"
  done
  echo
  echo "Engine versions:"
  echo
  echo '```'
  echo "PostgreSQL : $(pg_sql -tAc 'select version()' 2>/dev/null | head -1)  ($(docker inspect -f '{{.Config.Image}}' "$PG_CTR" 2>/dev/null))"
  echo "openGauss  : $(og_sql -tAc 'select version()' 2>/dev/null | head -1)  ($(docker inspect -f '{{.Config.Image}}' "$OG_CTR" 2>/dev/null))"
  echo '```'
} > "$OUT"

log "wrote $OUT"
grep -E 'DIFFERS' "$OUT" | sed 's/^/    /' || log "no divergent parameters"
