#!/usr/bin/env bash
# Re-run ONLY the indexed point-lookup series, at all four scales, into its own
# file.
#
# This is a redo: the first attempt collected the data correctly but the wrapper
# pointed the harness at out/raw.csv (40_run_all.sh had RAW hardcoded) and then
# a merge step overwrote that file with an empty "point fix" file, destroying
# 168 measurements. 40_run_all.sh now honours RAW_OUT, and this script checks the
# row count after every scale instead of trusting the pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

POINT="$OUT_DIR/raw_pointfix.csv"
MAIN="$OUT_DIR/raw_main.csv"
[ -f "$MAIN" ] || { echo "missing $MAIN"; exit 1; }

head -1 "$MAIN" > "$POINT"
echo "point re-run -> $POINT"

for S in 1 2 4 8; do
  echo
  echo "----- scale $S -----"
  SCALE="$S" bash scripts/34_amplify.sh | tail -2
  before=$(wc -l < "$POINT")
  SCALE="$S" RAW_OUT="$POINT" RUN_ID="pointfix-s$S" MODES="point" BACKENDS="pg og file" \
    REPS=7 WARMUP=2 WARM_COLD="warm cold" EXCLUSIVE=1 POINT_IDS=2000 NOINDEX=0 \
    bash scripts/40_run_all.sh
  after=$(wc -l < "$POINT")
  if [ "$after" -le "$before" ]; then
    echo "FAILED: no rows were written for scale $S (expected $POINT to grow)"; exit 1
  fi
  echo "scale $S: $POINT grew by $((after - before)) rows"
done

echo
echo "point re-run complete $(date -Is): $(($(wc -l < "$POINT") - 1)) rows"
