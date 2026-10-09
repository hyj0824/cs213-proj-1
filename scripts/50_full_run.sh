#!/usr/bin/env bash
# The full-scale benchmark, in one resumable script.
#
#   nohup scripts/50_full_run.sh > out/full_run.log 2>&1 &
#
# It is designed around the two facts that make this job awkward:
#
#   * It takes hours. Every phase is guarded by a marker in out/phases/, so
#     re-running the script continues instead of starting over. Delete a marker
#     (or all of them) to redo that phase.
#
#   * The host has 16 GiB. Two servers with 4 GiB shared_buffers each plus a
#     12 GiB table do not fit, so the two engines are never measured at the same
#     time: EXCLUSIVE=1 stops the idle container (which also releases its buffer
#     pool, giving every backend the same cold start). Set EXCLUSIVE=0 only if
#     you have more RAM.
source "$(dirname "$0")/lib.sh"

PHASES="$OUT_DIR/phases"
mkdir -p "$PHASES" "$OUT_DIR/explain"
SCALES="${SCALES:-1 2 4 8}"
# the largest scale, used for labelling the experiments that do not themselves
# sweep the scale (the counter table is scale independent, but the row in the raw
# log should still say which dataset was loaded)
SCALE_LAST="$(echo $SCALES | awk '{print $NF}')"
EXCLUSIVE="${EXCLUSIVE:-1}"
RUN_ID="${RUN_ID:-full-$(date +%Y%m%d-%H%M)}"
LOG_PREFIX="[$(date +%H:%M:%S)]"

phase_done() { [ -f "$PHASES/$1" ]; }
phase_run()  { # name description command...
  local name="$1" desc="$2"; shift 2
  if phase_done "$name"; then
    log "SKIP  $name ($desc) -- already done"
    return 0
  fi
  log "BEGIN $name -- $desc"
  local t0 t1
  t0=$(date +%s)
  if "$@"; then
    t1=$(date +%s)
    date -Is > "$PHASES/$name"
    echo "elapsed $((t1 - t0))s" >> "$PHASES/$name"
    log "DONE  $name -- $(( (t1 - t0) / 60 ))m$(( (t1 - t0) % 60 ))s"
  else
    warn "FAILED $name -- fix the cause and re-run; completed phases are kept"
    return 1
  fi
}

# ---------------------------------------------------------------- preflight ---
log "=== preflight ==="
AVAIL_GB="$(df -BG --output=avail "$HOST_DATA_ROOT" | tail -1 | tr -dc 0-9)"
log "free space on $HOST_DATA_ROOT: ${AVAIL_GB}G (need ~60G for scale 8)"
[ "${AVAIL_GB:-0}" -ge 60 ] || die "not enough disk for the full sweep"
ctr_running "$PG_CTR" || die "$PG_CTR is not running: scripts/10_up.sh"
ctr_running "$OG_CTR" || die "$OG_CTR is not running: scripts/10_up.sh"
bash scripts/00_check_env.sh >/dev/null 2>&1 || true
grep -q 'DIFFERS' "$OUT_DIR/guc_compare.md" 2>/dev/null && \
  warn "out/guc_compare.md still lists divergent parameters -- read it before trusting the numbers"
log "run id: $RUN_ID   scales: $SCALES   exclusive: $EXCLUSIVE"

# ----------------------------------------------------------- data pipeline ---
phase_run fetch  "download the IMDb datasets (420 MB)" \
  bash scripts/31_fetch_imdb.sh

phase_run load   "load 10.29M titles + 2M names into both engines (~25 min)" \
  bash scripts/32_load_imdb.sh

# ------------------------------------------------------------- scale sweep ---
for S in $SCALES; do
  phase_run "amplify_$S" "build the ${S}x table on both engines + export the file side" \
    env SCALE="$S" bash scripts/34_amplify.sh

  phase_run "guardrails_$S" "assert the file export and the SQL side encode the same data" \
    bash -c "docker exec -i -e PGPASSWORD=bench $PG_CTR psql -U $PG_USER -d $PG_DB -X -q -f - < $ROOT/sql/01_guardrails.sql"

  # NOINDEX_IDS is small on purpose: without an index every single lookup is a
# full table scan (6.3 GB at SCALE=8), so 10 samples already give a stable
# per-lookup cost while 2000 would mean 2000 sequential scans per repetition.
phase_run "measure_$S" "scan/point/join at ${S}x, one engine at a time" \
    env SCALE="$S" RUN_ID="$RUN_ID-s$S" EXCLUSIVE="$EXCLUSIVE" \
        MODES="scan point join" REPS="${REPS:-7}" WARMUP="${WARMUP:-2}" \
        KEYWORDS="${KEYWORDS:-the a man love}" POINT_IDS="${POINT_IDS:-2000}" \
        NOINDEX_IDS="${NOINDEX_IDS:-10}" \
        PARALLEL_SWEEP="${PARALLEL_SWEEP:-1}" \
        WARM_COLD="${WARM_COLD:-warm cold}" \
        bash scripts/40_run_all.sh
done

# ------------------------------------------------- destructive experiments ---
# These need the people table, which is refreshed from the 2M-row base at every
# amplify step, so run them after the last scale has been built.
phase_run constraints "the declared-limit sweep: what the DBMS refuses" \
  bash scripts/37_constraint_demo.sh

# Two separate things, and the first was missing from the first full run: the
# harness-level update *timing* on all three backends (the measure phases never
# collected it, because they run MODES="scan point join"), and the storage-engine
# byte accounting. Without the first line there are no update rows in raw.csv.
phase_run updates "T -> Ttt: harness timing, then bloat/VACUUM/ASTORE-vs-USTORE" \
  bash -c 'set -e
           ENABLE_USTORE=on bash scripts/20_align_guc.sh
           MODES=update BACKENDS="pg og file" SCALE="${SCALE_LAST:-1}" REPS="${REPS:-7}" WARMUP=0 \
             WARM_COLD=warm EXCLUSIVE="${EXCLUSIVE:-1}" RUN_ID="'"$RUN_ID"'-update" \
             bash scripts/40_run_all.sh
           TARGETS="pg:bench_people_active og:bench_people_astore og:bench_people_ustore" \
             bash scripts/36_storage_ab.sh'

phase_run concurrency "lost updates and durability vs client count" \
  env SCALE="$SCALE_LAST" RUN_ID="$RUN_ID-conc" MODES="counter" REPS="${REPS:-7}" \
      THREADS_LIST="${THREADS_LIST:-1 4 16 64}" COUNTER_ITERS="${COUNTER_ITERS:-500}" \
      WARM_COLD="warm" EXCLUSIVE="$EXCLUSIVE" bash scripts/40_run_all.sh

# ----------------------------------------------------------------- report ----
phase_run analyse "median/IQR tables + the cross-backend consistency check" \
  python3 analysis/analyze.py

phase_run figures "the five figures (skipped cleanly if matplotlib is missing)" \
  python3 analysis/plot.py

cat <<EOF

$(log "")full run complete.

  raw      out/raw.csv
  summary  out/summary.csv
  tables   out/report_tables.md      <- paste into the report
  figures  out/figures/
  explain  out/explain/              <- the mechanism evidence

Phase markers live in $PHASES. Delete one to redo that phase.
EOF
