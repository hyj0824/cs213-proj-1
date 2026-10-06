#!/usr/bin/env bash
# Load the course's filmdb.sql into a dedicated schema on BOTH engines.
#
# filmdb.sql is a SQLite dump: line 1 is `PRAGMA foreign_keys=OFF;`, which
# PostgreSQL/openGauss reject.  Everything else is portable SQL.  The dump's
# own BEGIN/COMMIT are kept -- one transaction for 76k INSERTs is much faster
# than 76k autocommits.
source "$(dirname "$0")/lib.sh"

SRC="$ROOT/filmdb.sql"
[ -f "$SRC" ] || die "filmdb.sql not found at $SRC"

CLEAN="$DATA_DIR/filmdb_pg.sql"
WRAPPED="$DATA_DIR/filmdb_load.sql"
tail -n +2 "$SRC" > "$CLEAN"
# Put the schema and the search_path *inside* the stream instead of relying on
# client flags: openGauss's gsql does not accept "-f -" and does not honour
# PGOPTIONS, and relying on two clients behaving identically is exactly the kind
# of assumption that produces silently empty tables.
{
  echo 'CREATE SCHEMA IF NOT EXISTS film;'
  echo 'SET search_path = film, public;'
  cat "$CLEAN"
} > "$WRAPPED"
log "stripped PRAGMA line -> $WRAPPED ($(wc -l < "$WRAPPED") statements, $(du -h "$WRAPPED" | cut -f1))"

load_into() { # container label
  local ctr="$1" label="$2"
  log "loading into $label ..."
  local t0 t1 errs errfile="$OUT_DIR/filmdb_load_$label.err"
  t0=$(date +%s)
  if [ "$label" = postgres ]; then
    docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$ctr" \
      psql -U "$PG_USER" -d "$PG_DB" -X -q -v ON_ERROR_STOP=0 < "$WRAPPED" 2> "$errfile"
  else
    docker exec -i "$ctr" su - omm -c \
      "$(printf '%q ' gsql -d "$OG_DB" -U "$OG_USER" -W "$OG_PASSWORD" -h 127.0.0.1 -p 5432 -X -q)" \
      < "$WRAPPED" 2> "$errfile"
  fi
  t1=$(date +%s)
  errs=$(grep -c -i "error" "$errfile" 2>/dev/null || true)
  log "$label: $((t1-t0))s, $errs error line(s) -> $errfile"
  [ "${errs:-0}" -eq 0 ] || { warn "$label reported $errs errors; first three:"; head -3 "$errfile" | sed 's/^/    /'; }
}

ctr_running "$PG_CTR" && load_into "$PG_CTR" postgres || warn "postgres container not running, skipped"
ctr_running "$OG_CTR" && load_into "$OG_CTR" opengauss || warn "openGauss container not running, skipped"

log "row counts (postgres):"
pg_sql -c 'select (select count(*) from film.movies) movies, (select count(*) from film.people) people, (select count(*) from film.credits) credits, (select count(*) from film.alt_titles) alt_titles;' 2>/dev/null | sed 's/^/    /' || true

# The small (S) dataset: point the benchmark tables straight at filmdb.
# No base table is involved -- 34_amplify.sh is for the IMDb-scale data only.
for pair in "$PG_CTR:postgres" "$OG_CTR:opengauss"; do
  ctr="${pair%%:*}"; eng="${pair##*:}"
  ctr_running "$ctr" || continue
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi
  log "$eng: filling bench_*_active from the film schema"
  sql -c "TRUNCATE bench_titles_active;
          INSERT INTO bench_titles_active SELECT movieid, title FROM film.movies;
          TRUNCATE bench_people_active;
          INSERT INTO bench_people_active SELECT peopleid, first_name, surname FROM film.people;
          ANALYZE bench_titles_active; ANALYZE bench_people_active;" >/dev/null
  log "$eng: $(sql -tAc 'select count(*) from bench_titles_active' 2>/dev/null) titles, $(sql -tAc 'select count(*) from bench_people_active' 2>/dev/null) people"
done

log "done.  The S-scale dataset is now in bench_titles_active / bench_people_active."
log "next: sql/01_guardrails.sql, then scripts/33_export_files.sh"
