#!/usr/bin/env bash
# Write amplification: what does the T -> Ttt update actually cost the engine?
#
# Three targets, one statement:
#   pg  bench_people_active   append-only heap (PostgreSQL's only row design)
#   og  bench_people_active   ASTORE  -- openGauss's append-update engine
#   og  bench_people_ustore   USTORE  -- in-place update + undo, openGauss only
#
# The update GROWS every touched row, which is the worst case for an
# append-only heap: each updated row is written to a new location, the old
# version stays behind as dead space, and only VACUUM (a rewrite of the whole
# table) can give it back.  USTORE keeps the live version in place and moves the
# previous version to undo space, so it should not bloat.
#
# Everything here is measured with bash timestamps rather than the harness,
# because the point is the bytes, not the latency.
source "$(dirname "$0")/lib.sh"
OUT="$OUT_DIR/storage_ab.md"
TARGETS="${TARGETS:-pg:bench_people_active og:bench_people_active og:bench_people_ustore}"

now_ns() { date +%s%N; }

# runs the statement on one engine and echoes elapsed milliseconds
run_sql() { # engine  sql  -> prints "milliseconds<TAB>result"
  local eng="$1" sql="$2" t0 t1
  if [ "$eng" = pg ]; then sqlf() { pg_sql "$@"; }; else sqlf() { og_sql "$@"; }; fi
  t0=$(now_ns)
  sqlf -c "$sql" >/dev/null 2>&1
  t1=$(now_ns)
  echo $(( (t1 - t0) / 1000000 ))
}

rel_bytes() { # engine  table  -> total bytes
  local eng="$1" tbl="$2"
  if [ "$eng" = pg ]; then sqlf() { pg_sql -tAc "$@"; }; else sqlf() { og_sql -tAc "$@"; }; fi
  sqlf "select pg_relation_size('$tbl') + pg_indexes_size('$tbl')" 2>/dev/null | tr -dc 0-9
}

scalar() { # engine sql -> first column of the first row, digits only
  local eng="$1" q="$2"
  if [ "$eng" = pg ]; then pg_sql -tAc "$q" 2>/dev/null | tr -dc 0-9
  else og_sql -tAc "$q" 2>/dev/null | tr -dc 0-9; fi
}

dead_tuples() { # engine table
  local eng="$1" tbl="$2"
  if [ "$eng" = pg ]; then sqlf() { pg_sql -tAc "$@"; }; else sqlf() { og_sql -tAc "$@"; }; fi
  sqlf "select coalesce(n_dead_tup,-1) from pg_stat_user_tables where relname='$tbl'" 2>/dev/null | tr -dc 0-9
}

# The placeholder must not be '%T%': that pattern also occurs inside the WHERE
# clause, and a naive ${var//%T%/$tbl} would rewrite the predicate into
# LIKE 'bench_people_active' and silently match zero rows.
UPDSQL="UPDATE @@T@@ SET first_name = replace(first_name,'T','Ttt'), surname = replace(surname,'T','Ttt')
        WHERE coalesce(first_name,'') LIKE '%T%' OR coalesce(surname,'') LIKE '%T%'"

{
  echo "# Write amplification of the \`T -> Ttt\` update"
  echo
  echo "Measured $(date -Is) on \`$(hostname)\`. All values are total relation bytes"
  echo "(\`pg_relation_size\` + \`pg_indexes_size\`). Autovacuum is **off** during the"
  echo "measurement and reclamation is timed explicitly, so that no background"
  echo "process can be credited (or blamed) for anything."
  echo
  echo "| target | rows changed | before (B) | after update (B) | growth | growth % | dead tuples | VACUUM (ms) | after VACUUM (B) | VACUUM FULL (ms) | after FULL (B) | update (ms) |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
} > "$OUT"

for t in $TARGETS; do
  eng="${t%%:*}"; tbl="${t##*:}"
  if [ "$eng" = pg ]; then ctr="$PG_CTR"; else ctr="$OG_CTR"; fi
  if ! ctr_running "$ctr"; then warn "$eng not running, skipping $tbl"; continue; fi

  log "----- $eng / $tbl -----"
  # The comparison is only meaningful at equal row counts, for EVERY target on
  # this engine. An earlier version guarded only bench_people_ustore, and the run
  # then compared a 2,000,000-row PostgreSQL heap against a 16,489-row ASTORE
  # table left over from the filmdb phase -- a comparison that looked perfectly
  # healthy and was meaningless.
  if [ "$eng" = og ]; then
    # NB: this block sits in the loop body, not in a function, so no `local`.
    want="$(og_sql -tAc 'select count(*) from bench_people_active' 2>/dev/null | tr -dc 0-9 || true)"
    for t2 in bench_people_astore bench_people_ustore; do
      have="$(og_sql -tAc "select count(*) from $t2" 2>/dev/null | tr -dc 0-9 || echo 0)"
      if [ "${have:-0}" != "${want:-0}" ]; then
        log "$eng: $t2 has ${have:-0} rows, bench_people_active has ${want:-0} -- rebuilding both"
        if ! og_sql < "$ROOT/sql/03_storage_engines.sql" >/dev/null 2>&1; then
          warn "$eng: USTORE unavailable in this build -- recording that as a finding"
          echo "| $eng/$t2 | USTORE not available in this build | - | - | - | - | - | - | - | - |" >> "$OUT"
          continue
        fi
        break
      fi
    done
  fi


  # Start from a known-good, *compact* state.
  #
  # Without this the measurement is meaningless in two ways: (a) T -> Ttt is not
  # idempotent, because "Ttt" still matches LIKE '%T%', so a second run rewrites
  # the already-rewritten rows; (b) an append-only heap can absorb new row
  # versions into space freed by the previous update, so the relation does not
  # grow and the growth number silently becomes 0.
  log "$eng/$tbl: restoring and compacting before measuring"
  bash "$(dirname "$0")/91_restore_people.sh" "$eng" >/dev/null 2>&1 || true
  run_sql "$eng" "VACUUM FULL $tbl" >/dev/null 2>&1 || run_sql "$eng" "VACUUM $tbl" >/dev/null
  run_sql "$eng" "ANALYZE $tbl" >/dev/null

  before="$(rel_bytes "$eng" "$tbl")"
  ms="$(run_sql "$eng" "${UPDSQL//@@T@@/$tbl}")"
  changed="$(scalar "$eng" "select count(*) from $tbl where first_name like '%Ttt%' or surname like '%Ttt%'")"
  after="$(rel_bytes "$eng" "$tbl")"
  dead="$(dead_tuples "$eng" "$tbl")"
  vms="$(run_sql "$eng" "VACUUM $tbl")"
  vafter="$(rel_bytes "$eng" "$tbl")"
  fms="$(run_sql "$eng" "VACUUM FULL $tbl")"
  fafter="$(rel_bytes "$eng" "$tbl")"

  growth=$(( ${after:-0} - ${before:-0} ))
  pct="$(awk -v b="${before:-1}" -v g="$growth" 'BEGIN{printf "%.2f", 100*g/b}')"
  printf '| %s/%s | %s | %s | %s | %s | %s%% | %s | %s | %s | %s | %s | %s |\n' \
    "$eng" "$tbl" "${changed:-?}" \
    "${before:-0}" "${after:-0}" "$growth" "$pct" "${dead:-?}" \
    "${vms:-?}" "${vafter:-0}" "${fms:-?}" "${fafter:-0}" "${ms:-?}" >> "$OUT"

  log "$eng/$tbl: ${before} -> ${after} bytes (+$(( ${after:-0} - ${before:-0} )), dead=${dead}), vacuum ${vms}ms, vacuum full ${fms}ms"
done

{
  echo
  echo "Reading the table:"
  echo
  echo "* An append-only engine shows \`after > before\` even though no row was added:"
  echo "  that difference is the update's write amplification, and it is why the"
  echo "  same statement costs more the second time."
  echo "* \`VACUUM FULL\` needs a second copy of the table on disk. On a 12 GB table"
  echo "  that is a real operational constraint, not a footnote."
  echo "* openGauss \`USTORE\` trades \`after\` for undo space, which lives outside the"
  echo "  relation and therefore does not show up in \`pg_relation_size\` -- state that"
  echo "  caveat explicitly when you quote these numbers."
} >> "$OUT"

log "wrote $OUT"
cat "$OUT"
