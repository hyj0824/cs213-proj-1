#!/usr/bin/env bash
# Export the active tables to the plain files the C/Java program reads.
#
# This is the single most important fairness measure in the whole project: the
# file backend never sees an independently produced dataset.  It reads bytes
# that the DBMS itself emitted, so "the same operation on the same data" is a
# fact about the pipeline rather than a claim in the report.
#
# Produces (in $DATA_DIR):
#   titles_active.tsv          id<TAB>title        heap order, for full scans
#   titles_active.sorted.tsv   id<TAB>title        sorted by id
#   titles_active.sorted.idx   8-byte offsets      for binary search
#   people_active.tsv          pid<TAB>first<TAB>last  (+ .orig backup)
#   counter.txt                "0"
#   film_movies.tsv / film_credits.tsv / film_people.tsv   (join experiment)
#   MANIFEST.txt               row counts, sizes, sha256 -- goes in the appendix
source "$(dirname "$0")/lib.sh"
require_ctr "$PG_CTR"

MAN="$DATA_DIR/MANIFEST.txt"
{
  echo "# canonical file export"
  echo "# generated $(date -Is)"
  echo "# source: postgres container $PG_CTR, database $PG_DB"
} > "$MAN"

copy_out() { # sql  outfile  extra-copy-options
  local sql="$1" out="$2" opts="${3:-}"
  log "exporting $(basename "$out") ..."
  pg_sql -c "COPY ($sql) TO STDOUT WITH (FORMAT csv, HEADER false $opts)" > "$out.raw" || die "COPY failed for $out"
}

to_tsv() { # raw-csv  out-tsv  [3col]
  local raw="$1" out="$2" mode="${3:-2}"
  if [ "$mode" = 3 ]; then
    python3 "$ROOT/tools/tsv_util.py" to-tsv3 "$raw" "$out"
  else
    python3 "$ROOT/tools/tsv_util.py" to-tsv "$raw" "$out"
  fi
  rm -f "$raw"
  printf '%s  rows=%s  bytes=%s  sha256=%s\n' "$(basename "$out")" \
    "$(wc -l < "$out")" "$(stat -c%s "$out")" "$(sha256sum "$out" | cut -c1-16)" >> "$MAN"
}

# --------------------------------------------------------------- titles ------
NT="$(pg_sql -tAc 'select count(*) from bench_titles_active')"
if [ "${NT:-0}" -gt 0 ]; then
  copy_out "SELECT id, title FROM bench_titles_active" "$DATA_DIR/titles_active.tsv"
  to_tsv "$DATA_DIR/titles_active.tsv.raw" "$DATA_DIR/titles_active.tsv" 2

  log "building sorted variant + byte-offset index (this is the 'armed' file layout)"
  LC_ALL=C sort -t$'\t' -k1,1n -S 2G --parallel=4 \
      -o "$DATA_DIR/titles_active.sorted.tsv" "$DATA_DIR/titles_active.tsv"
  printf '%s  rows=%s  bytes=%s  sha256=%s\n' "titles_active.sorted.tsv" \
    "$(wc -l < "$DATA_DIR/titles_active.sorted.tsv")" "$(stat -c%s "$DATA_DIR/titles_active.sorted.tsv")" \
    "$(sha256sum "$DATA_DIR/titles_active.sorted.tsv" | cut -c1-16)" >> "$MAN"
  python3 "$ROOT/tools/tsv_util.py" index "$DATA_DIR/titles_active.sorted.tsv" "$DATA_DIR/titles_active.sorted.idx"
  printf '%s  bytes=%s\n' "titles_active.sorted.idx" "$(stat -c%s "$DATA_DIR/titles_active.sorted.idx")" >> "$MAN"

  # the id range, so the file backend does not have to scan to discover it
  pg_sql -tAc "select min(id) || ' ' || max(id) from bench_titles_active" > "$DATA_DIR/titles_active.range"
  printf '%s  %s\n' "titles_active.range" "$(cat "$DATA_DIR/titles_active.range")" >> "$MAN"

  # A list of ids that are known to exist.
  #
  # IMDb tconsts are sparse (12.8M rows spread over a 48M id space) and the
  # amplified blocks sit 1e9 apart, so sampling uniformly over [min(id), max(id)]
  # lands on an empty id almost every time at SCALE>1: the point-lookup tables
  # came out with result=0, which is not wrong but reads like a broken
  # experiment. The harness prefers this file when it is present.
  log "sampling real ids for the point-lookup experiment (pool must exceed the batch size at every scale)"
  pg_sql -c "COPY (SELECT id FROM bench_titles_active WHERE id % 1009 = 0 LIMIT 40000)
             TO STDOUT WITH (FORMAT csv, HEADER false)" > "$DATA_DIR/titles_active.ids"
  printf '%s  rows=%s\n' "titles_active.ids" "$(wc -l < "$DATA_DIR/titles_active.ids")" >> "$MAN"

  log "titles: $NT rows"
else
  warn "bench_titles_active is empty -- skipped"
fi

# --------------------------------------------------------------- people ------
NP="$(pg_sql -tAc 'select count(*) from bench_people_active')"
if [ "${NP:-0}" -gt 0 ]; then
  copy_out "SELECT pid, coalesce(first_name,''), coalesce(surname,'') FROM bench_people_active" \
           "$DATA_DIR/people_active.tsv"
  to_tsv "$DATA_DIR/people_active.tsv.raw" "$DATA_DIR/people_active.tsv" 3
  cp -f "$DATA_DIR/people_active.tsv" "$DATA_DIR/people_active.tsv.orig"
  log "people: $NP rows (backup written to people_active.tsv.orig)"
else
  warn "bench_people_active is empty -- skipped"
fi

# ------------------------------------------------------ join experiment ------
if pg_sql -tAc "select count(*) from information_schema.tables where table_schema='film' and table_name='credits'" 2>/dev/null | grep -q '^[1-9]'; then
  copy_out "SELECT movieid, title FROM film.movies"            "$DATA_DIR/film_movies.tsv"
  to_tsv "$DATA_DIR/film_movies.tsv.raw"  "$DATA_DIR/film_movies.tsv" 2
  copy_out "SELECT movieid, peopleid, credited_as FROM film.credits" "$DATA_DIR/film_credits.tsv"
  to_tsv "$DATA_DIR/film_credits.tsv.raw" "$DATA_DIR/film_credits.tsv" 3
  copy_out "SELECT peopleid, coalesce(first_name,''), surname FROM film.people" "$DATA_DIR/film_people.tsv"
  to_tsv "$DATA_DIR/film_people.tsv.raw"  "$DATA_DIR/film_people.tsv" 3
else
  warn "schema 'film' not found -- join experiment files skipped (run scripts/30_load_filmdb.sh)"
fi

echo 0 > "$DATA_DIR/counter.txt"

log "manifest:"
sed 's/^/    /' "$MAN"
