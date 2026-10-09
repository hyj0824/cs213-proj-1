#!/usr/bin/env bash
# Fill the three gaps the full run left behind.
#
#   1. The harness `update` timing was never collected: the measure phases ran
#      MODES="scan point join" and the storage-engine phase does its own,
#      separate update measurement. out/raw.csv therefore had zero update rows.
#
#   2. The ASTORE/USTORE comparison was invalid. 36_storage_ab.sh used to create
#      those tables only if they did not exist, so it measured a 2,000,000-row
#      PostgreSQL heap against a USTORE table left over at 16,489 rows from the
#      filmdb phase. It now rebuilds whenever the row counts differ.
#
#   3. The constraint sweep was re-run with corrected captions.
#
# The fsync variant of the file counter is also now labelled separately
# ("seqscan+fsync"), so the summary stops pooling it with the non-durable run.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

echo "=== gap 1/3: harness update timing, three backends, 7 destructive runs each ==="
MODES="update" BACKENDS="pg og file" SCALE="${SCALE:-8}" REPS="${REPS:-7}" WARMUP=0 \
  WARM_COLD="warm" EXCLUSIVE=1 RUN_ID="full-update" bash scripts/40_run_all.sh

echo
echo "=== gap 2/3: storage engines at equal row counts (enable_ustore=on) ==="
ENABLE_USTORE=on bash scripts/20_align_guc.sh
TARGETS="pg:bench_people_active og:bench_people_astore og:bench_people_ustore" \
  bash scripts/36_storage_ab.sh

echo
echo "=== gap 3/3: constraint sweep, corrected captions ==="
bash scripts/37_constraint_demo.sh

echo
echo "=== re-analysing everything ==="
python3 analysis/analyze.py

echo
echo "gap-fill complete $(date -Is)"
