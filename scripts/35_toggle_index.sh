#!/usr/bin/env bash
# Toggle the primary key on bench_titles_active.
#
#   up    : B-tree exists -> a point lookup touches ~4 pages
#   down  : no index        -> a point lookup is a full table scan
#
# Same query, same data, same engine; only the physical design changes. This is
# the cheapest possible demonstration that a DBMS's speed advantage is not
# "the DBMS is magic" but "the DBMS maintains an access structure for you".
source "$(dirname "$0")/lib.sh"
ACTION="${1:-status}"

for pair in "$PG_CTR:postgres" "$OG_CTR:opengauss"; do
  ctr="${pair%%:*}"; eng="${pair##*:}"
  ctr_running "$ctr" || { warn "$eng not running, skipped"; continue; }
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi

  case "$ACTION" in
    down)
      log "$eng: dropping the primary key"
      sql -c 'ALTER TABLE bench_titles_active DROP CONSTRAINT IF EXISTS bench_titles_active_pkey' >/dev/null 2>&1 \
        || sql -c 'DROP INDEX IF EXISTS bench_titles_active_pkey' >/dev/null 2>&1 || true
      ;;
    up)
      log "$eng: rebuilding the primary key (this sorts the whole table)"
      sql -c 'ALTER TABLE bench_titles_active ADD PRIMARY KEY (id)' >/dev/null 2>&1 \
        || warn "$eng: could not add the primary key (does it already exist?)"
      sql -c 'ANALYZE bench_titles_active' >/dev/null 2>&1 || true
      ;;
    status) ;;
    *) die "usage: $0 up|down|status" ;;
  esac

  log "$eng: $(sql -tAc "select pg_size_pretty(pg_relation_size('bench_titles_active'))" 2>/dev/null) heap, $(sql -tAc "select pg_size_pretty(pg_indexes_size('bench_titles_active'))" 2>/dev/null) indexes"
done
