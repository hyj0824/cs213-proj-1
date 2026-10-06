#!/usr/bin/env bash
# Build bench_titles_active at SCALE x the base dataset -- incrementally.
#
#   SCALE=1 scripts/34_amplify.sh     # 12.8M titles
#   SCALE=2 scripts/34_amplify.sh     # appends 12.8M more rows
#   SCALE=4 ... then SCALE=8          # each step only inserts what is missing
#
# Why incremental matters: the sweep 1 -> 2 -> 4 -> 8 rebuilds from scratch
# costs 1+2+4+8 = 15 base-loads of INSERT; appending the missing blocks costs
# 1+1+2+4 = 8. On a 12.8M-row base that is the difference between roughly one
# hour and roughly half an hour of pure INSERT per engine, before the primary
# key build and the file export.
#
# The blocks are laid out so this is safe:
#     block g  ->  ids in [g*1e9, g*1e9 + base)   and   titles suffixed " #g"
# which keeps every id distinct, keeps the appended ids at the right-hand edge
# of the B-tree (sequential inserts, not random ones), and makes the expected
# hit count for any keyword scale exactly linearly with SCALE -- so "is the
# answer still correct at 8x" is a checkable question, not a hopeful one.
source "$(dirname "$0")/lib.sh"
S="${SCALE:-1}"
BLOCK_OFFSET=1000000000

build() { # container engine
  local ctr="$1" eng="$2"
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi

  local base target current blocks
  base="$(sql -tAc 'select count(*) from bench_titles_base' 2>/dev/null | tr -dc 0-9 || true)"
  if [ "${base:-0}" -eq 0 ]; then
    warn "$eng: bench_titles_base is empty -- run scripts/32_load_imdb.sh (or the filmdb path)"
    return 0
  fi
  target=$((base * S))

  current="$(sql -tAc 'select count(*) from bench_titles_active' 2>/dev/null | tr -dc 0-9 || true)"
  current="${current:-0}"

  # Staleness check. The row count alone cannot tell whether the *contents* are
  # current: reloading the base with corrected values leaves the same count and
  # a table full of the old data (this actually happened here -- two IMDb titles
  # had been mangled on the way in, the base was reloaded, and the derived table
  # silently kept the mangled rows). So compare the load timestamps instead.
  base_at="$(sql -tAc "select value from bench_meta where key='base_loaded_at'" 2>/dev/null | tr -d ' \r\n' || true)"
  active_at="$(sql -tAc "select value from bench_meta where key='active_built_at'" 2>/dev/null | tr -d ' \r\n' || true)"
  if [ "${FORCE_REBUILD:-0}" = 1 ] || { [ -n "$base_at" ] && [ -n "$active_at" ] && [ "$base_at" \> "$active_at" ]; }; then
    warn "$eng: active table is stale (base loaded $base_at, active built $active_at) -- rebuilding"
    sql -c 'DROP TABLE IF EXISTS bench_titles_active' >/dev/null
    current=0
  fi

  if [ "$current" -eq "$target" ]; then
    log "$eng: already at ${S}x ($target rows), nothing to do"
  elif [ "$current" -gt "$target" ] || [ $((current % base)) -ne 0 ]; then
    log "$eng: active table is at $current rows, not a multiple of the base -- rebuilding"
    sql -c 'DROP TABLE IF EXISTS bench_titles_active' >/dev/null
    if ! sql -c 'CREATE UNLOGGED TABLE bench_titles_active (id BIGINT, title TEXT)' >/dev/null 2>&1; then
      log "$eng: UNLOGGED not supported, using a logged table"
      sql -c 'CREATE TABLE bench_titles_active (id BIGINT, title TEXT)' >/dev/null
    fi
    current=0
  fi

  if [ "$current" -eq 0 ]; then
    log "$eng: creating bench_titles_active"
    # UNLOGGED where available: this table is read-only for the scan experiments,
    # so paying WAL for it would slow the load without changing any measured number.
    sql -c 'DROP TABLE IF EXISTS bench_titles_active' >/dev/null
    if ! sql -c 'CREATE UNLOGGED TABLE bench_titles_active (id BIGINT, title TEXT)' >/dev/null 2>&1; then
      log "$eng: UNLOGGED not supported, using a logged table"
      sql -c 'CREATE TABLE bench_titles_active (id BIGINT, title TEXT)' >/dev/null
    fi
  fi

  blocks=$((current / base))
  if [ "$blocks" -lt "$S" ]; then
    log "$eng: appending blocks $blocks..$((S - 1)) (from $current to $target rows)"
    local t0 t1
    t0=$(date +%s)
    sql -c "INSERT INTO bench_titles_active
            SELECT id + (g::bigint * $BLOCK_OFFSET), title || ' #' || g
              FROM bench_titles_base, generate_series($blocks, $((S - 1))) AS g" >/dev/null
    t1=$(date +%s)
    log "$eng: inserted in $((t1 - t0))s"
  fi

  # The PK is what the point-lookup experiment measures; 35_toggle_index.sh drops
  # it for the no-index comparison and this restores it.
  local has_pk
  has_pk="$(sql -tAc "select count(*) from pg_indexes where tablename='bench_titles_active' and indexname like '%pkey%'" 2>/dev/null | tr -dc 0-9 || true)"
  if [ "${has_pk:-0}" -eq 0 ]; then
    log "$eng: building the primary key on id"
    local k0 k1
    k0=$(date +%s)
    sql -c 'ALTER TABLE bench_titles_active ADD PRIMARY KEY (id)' >/dev/null
    k1=$(date +%s)
    log "$eng: primary key built in $((k1 - k0))s"
  fi
  sql -c 'ANALYZE bench_titles_active' >/dev/null
  sql -c "DELETE FROM bench_meta WHERE key = 'active_built_at';
          INSERT INTO bench_meta VALUES ('active_built_at', to_char(now(),'YYYYMMDDHH24MISS'))" >/dev/null 2>&1 \
    || warn "$eng: could not stamp bench_meta"

  # people: no scale axis is needed. The update experiments need a table that can
  # be restored between repetitions, so it is a fresh copy of the base.
  local ppl
  ppl="$(sql -tAc 'select count(*) from bench_people_base' 2>/dev/null | tr -dc 0-9 || true)"
  if [ "${ppl:-0}" -gt 0 ]; then
    local pc
    pc="$(sql -tAc 'select count(*) from bench_people_active' 2>/dev/null | tr -dc 0-9 || true)"
    if [ "${pc:-0}" != "$ppl" ]; then
      log "$eng: refreshing bench_people_active from $ppl base rows"
      sql -c 'TRUNCATE bench_people_active;
              INSERT INTO bench_people_active SELECT pid, first_name, surname FROM bench_people_base;
              ANALYZE bench_people_active' >/dev/null
    fi
  fi

  log "$eng: $(sql -tAc 'select count(*) from bench_titles_active' 2>/dev/null) titles, $(sql -tAc 'select count(*) from bench_people_active' 2>/dev/null) people, \
heap $(sql -tAc "select pg_size_pretty(pg_relation_size('bench_titles_active'))" 2>/dev/null), \
indexes $(sql -tAc "select pg_size_pretty(pg_indexes_size('bench_titles_active'))" 2>/dev/null)"
}

for pair in "$PG_CTR:postgres" "$OG_CTR:opengauss"; do
  ctr="${pair%%:*}"; eng="${pair##*:}"
  ctr_running "$ctr" || { warn "$eng container not running, skipped"; continue; }
  build "$ctr" "$eng"
done

log "regenerating the file-side export at SCALE=$S"
SCALE="$S" "$(dirname "$0")/33_export_files.sh"

cat <<EOF

SCALE=$S is loaded on both engines and exported to $DATA_DIR.
Next:  SCALE=$S scripts/40_run_all.sh
EOF
