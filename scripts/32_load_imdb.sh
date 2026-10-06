#!/usr/bin/env bash
# Load IMDb data into the benchmark tables, streaming straight from gzip into
# COPY FROM STDIN so nothing is ever materialised in the container.
#
# Design notes that belong in the report:
#  * bench_titles_active gets the FULL 10,285,368 titles: it is the subject of
#    the retrieval scale sweep.
#  * bench_people_active gets PEOPLE_LIMIT rows (default 2M).  The update
#    experiment needs a table that can be restored between repetitions, and 2M
#    real names is already far more than enough to show write amplification.
#  * id = tconst/nconst with the "tt"/"nm" prefix stripped, so ids are dense and
#    fit in BIGINT.
#  * primaryName is split on the FIRST space: first_name = before, surname =
#    after ('' when there is no space).  The same split is done when the TSV is
#    exported, so both sides see identical values.
source "$(dirname "$0")/lib.sh"

RAW="$DATA_DIR/raw"
PEOPLE_LIMIT="${PEOPLE_LIMIT:-2000000}"
# TITLES_LIMIT=0 loads everything. A non-zero value is for a bounded rehearsal of
# the whole pipeline (load -> amplify -> export -> measure) before committing
# hours to the real thing: TITLES_LIMIT=200000 finishes in about a minute.
TITLES_LIMIT="${TITLES_LIMIT:-0}"
T="$RAW/title.basics.tsv.gz"; N="$RAW/name.basics.tsv.gz"
[ -s "$T" ] || die "missing $T -- run scripts/31_fetch_imdb.sh"
[ -s "$N" ] || die "missing $N -- run scripts/31_fetch_imdb.sh"

# ------------------------------------------------------------------ titles ---
# columns: tconst titleType primaryTitle originalTitle isAdult startYear ...
# Why the backslash escaping above is not paranoia:
#
# COPY's *text* format treats a backslash as an escape character, so two titles in
# the 2026 IMDb dump ("Exploring T\the Godfather's Best Deleted Scene",
# "A Cat Explains \"\n\"") arrived in the database with a real tab and a real
# newline in them -- the data was silently changed on the way in, and a
# line-oriented file reader could never represent the result. Doubling every
# backslash makes COPY store exactly the bytes the source file contains. The
# guardrail query (sql/01_guardrails.sql) then passes with 0 rows containing a
# control character, which is what makes the one-record-per-line file format valid.
expected_titles() {
  zcat "$T" | tail -n +2 | awk -F'\t' -v lim="$TITLES_LIMIT" \
    '(lim == 0 || NR <= lim) && $3 != "\\N" { n++ } END { print n+0 }'
}

expected_people() {
  zcat "$N" | tail -n +2 | awk -F'\t' -v lim="$PEOPLE_LIMIT" 'NR <= lim { n++ } END { print n+0 }'
}

# A mismatch here means the two engines (or the file export) would be compared on
# different data, which invalidates every number in the report, so it is fatal.
verify_count() { # engine label table expected
  local eng="$1" label="$2" table="$3" want="$4" got
  if [ "$eng" = postgres ]; then got="$(pg_sql -tAc "select count(*) from $table" | tr -dc 0-9)"
  else got="$(og_sql -tAc "select count(*) from $table" | tr -dc 0-9)"; fi
  if [ "${got:-0}" != "$want" ]; then
    die "$eng: $label loaded $got rows into $table but $want were expected. \
Refusing to continue: a partial load would make every comparison wrong."
  fi
  log "$eng: $label verified: $got rows"
}

# Feed a stream of SQL (or a \copy body) to one engine. openGauss's gsql only
# exists on omm's PATH, so it has to be reached through `su - omm`, and printf %q
# is what keeps the password safe on that nested command line.
stream_into() { # engine
  local eng="$1" q
  if [ "$eng" = postgres ]; then
    docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CTR" psql -U "$PG_USER" -d "$PG_DB" -X -q
  else
    q="$(printf '%q ' gsql -d "$OG_DB" -U "$OG_USER" -W "$OG_PASSWORD" -h 127.0.0.1 -p 5432 -X -q)"
    docker exec -i "$OG_CTR" su - omm -c "$q"
  fi
}

load_titles() { # container engine
  local ctr="$1" eng="$2"
  log "$eng: loading titles -> bench_titles_base ..."
  local t0 t1
  t0=$(date +%s)
  { echo '\copy bench_titles_base (id, title) from stdin'
    zcat "$T" | tail -n +2 | awk -F'\t' -v lim="$TITLES_LIMIT" '
        (lim == 0 || NR <= lim) && $3 != "\\N" {
          t = $3
          gsub(/\\/, "\\\\\\\\", t)   # see the note below
          printf "%d\t%s\n", substr($1,3)+0, t
        }'
    echo '\.'
  } | stream_into "$eng"
  t1=$(date +%s); log "$eng: titles loaded in $((t1-t0))s"
  verify_count "$eng" "titles" bench_titles_base "$(expected_titles)"
}

# ------------------------------------------------------------------ people ---
load_people() { # container engine
  local ctr="$1" eng="$2"
  log "$eng: loading up to $PEOPLE_LIMIT people -> bench_people_base ..."
  local t0 t1
  t0=$(date +%s)
  { echo '\copy bench_people_base (pid, first_name, surname) from stdin'
    zcat "$N" | tail -n +2 | awk -F'\t' -v lim="$PEOPLE_LIMIT" '
        NR <= lim {
          n = $2
          p = index(n, " ")
          if (p > 0) { f = substr(n, 1, p-1); s = substr(n, p+1) } else { f = n; s = "" }
          gsub(/\\/, "\\\\\\\\", f)
          gsub(/\\/, "\\\\\\\\", s)
          printf "%d\t%s\t%s\n", substr($1,3)+0, f, s
        }'
    echo '\.'
  } | stream_into "$eng"
  t1=$(date +%s); log "$eng: people loaded in $((t1-t0))s"
  verify_count "$eng" "people" bench_people_base "$(expected_people)"
}

for pair in "$PG_CTR:postgres" "$OG_CTR:opengauss"; do
  ctr="${pair%%:*}"; eng="${pair##*:}"
  ctr_running "$ctr" || { warn "$eng container not running, skipped"; continue; }
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi
  sql -c 'TRUNCATE bench_titles_base; TRUNCATE bench_people_base;' >/dev/null
  load_titles "$ctr" "$eng"
  load_people "$ctr" "$eng"
  sql -c 'ANALYZE bench_titles_base; ANALYZE bench_people_base;' >/dev/null
  # stamp the load so 34_amplify.sh can detect that a derived table is stale
  sql -c "DELETE FROM bench_meta WHERE key = 'base_loaded_at';
          INSERT INTO bench_meta VALUES ('base_loaded_at', to_char(now(),'YYYYMMDDHH24MISS'))" >/dev/null 2>&1 \
    || warn "$eng: could not stamp bench_meta (run scripts/25_bootstrap.sh first)"

  log "$eng: $(sql -tAc 'select count(*) from bench_titles_base' 2>/dev/null) titles, $(sql -tAc 'select count(*) from bench_people_base' 2>/dev/null) people"
done

log "next: scripts/34_amplify.sh   (derives bench_*_active at SCALE=1|2|4|8)"
