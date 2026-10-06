#!/usr/bin/env bash
# Restore the people table/file to its pre-update state.
#
# The T -> Ttt update is destructive and NOT reversible (information is lost the
# moment it runs), so every repetition has to start from a known-good copy. This
# script is what the harness calls between repetitions via --restore-cmd, which
# is why the repetition count in the update experiment is meaningful rather than
# "the first run measured something and the rest measured nothing".
#
#   usage: 91_restore_people.sh pg|og|file
source "$(dirname "$0")/lib.sh"
WHAT="${1:-all}"

restore_sql() { # container engine table-source
  local ctr="$1" eng="$2"
  ctr_running "$ctr" || return 0
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi
  local base
  base="$(sql -tAc 'select count(*) from bench_people_base' 2>/dev/null || echo 0)"
  if [ "${base:-0}" -gt 0 ]; then
    sql -c 'TRUNCATE bench_people_active;
            INSERT INTO bench_people_active SELECT pid, first_name, surname FROM bench_people_base' >/dev/null
  else
    sql -c 'TRUNCATE bench_people_active;
            INSERT INTO bench_people_active SELECT peopleid, first_name, surname FROM film.people' >/dev/null
  fi
  sql -c 'ANALYZE bench_people_active' >/dev/null 2>&1 || true
}

case "$WHAT" in
  pg)   restore_sql "$PG_CTR" postgres ;;
  og)   restore_sql "$OG_CTR" opengauss ;;
  file) [ -f "$DATA_DIR/people_active.tsv.orig" ] || die "no $DATA_DIR/people_active.tsv.orig"
        cp -f "$DATA_DIR/people_active.tsv.orig" "$DATA_DIR/people_active.tsv" ;;
  all)  restore_sql "$PG_CTR" postgres; restore_sql "$OG_CTR" opengauss
        [ -f "$DATA_DIR/people_active.tsv.orig" ] && cp -f "$DATA_DIR/people_active.tsv.orig" "$DATA_DIR/people_active.tsv" ;;
  *)    die "usage: $0 pg|og|file|all" ;;
esac
