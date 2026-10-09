#!/usr/bin/env bash
# Re-run the point-lookup series with ids that are known to exist, and redo the
# storage-engine A/B and the constraint sweep that a mid-flight script edit
# interrupted.
#
# The point timings from the main run are still valid -- a B-tree probe costs
# the same whether or not the row is there -- but the result column read 0/40/28/20
# because uniform sampling over a sparse, block-offset id space mostly lands on
# empty ids. It reads like a broken experiment, so it is redone properly.
#
# Old point rows are archived rather than deleted: out/raw.csv is rebuilt at the
# end from the main run minus the superseded point rows, plus this run.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

MAIN="$OUT_DIR/raw_main.csv"
POINT="$OUT_DIR/raw_pointfix.csv"

# archive once (idempotent)
if [ ! -f "$MAIN" ]; then
  cp out/raw.csv "$MAIN"
  echo "archived the main run to $MAIN ($(wc -l < "$MAIN") rows)"
fi
[ -f "$POINT" ] || head -1 "$MAIN" > "$POINT"

echo
echo "=== 1/3: storage-engine A/B at equal row counts ==="
TARGETS="pg:bench_people_active og:bench_people_astore og:bench_people_ustore" \
  bash scripts/36_storage_ab.sh

echo
echo "=== 2/3: constraint sweep ==="
bash scripts/37_constraint_demo.sh

echo
echo "=== 3/3: point lookups with real ids, all four scales ==="
for S in 1 2 4 8; do
  echo
  echo "----- scale $S: amplify + export (which writes titles_active.ids) -----"
  SCALE="$S" bash scripts/34_amplify.sh | tail -3
  echo "----- scale $S: point only -----"
  SCALE="$S" RUN_ID="pointfix-s$S" MODES="point" BACKENDS="pg og file" \
    REPS=7 WARMUP=2 WARM_COLD="warm cold" EXCLUSIVE=1 \
    POINT_IDS=2000 NOINDEX=0 bash scripts/40_run_all.sh
done

echo
echo "=== merging: main run (minus superseded point rows) + this run ==="
# Drop only the superseded *indexed* point rows (param n=2000). The unindexed
# series (param n=10) came from the main run and is kept: its timings are valid
# and it is filed under a different param, so it cannot be confused with this one.
{ head -1 "$MAIN"
  awk -F, 'NR>1 && !($6=="point" && $7=="n=2000")' "$MAIN"
  tail -n +2 "$POINT"
} > out/raw.csv
echo "out/raw.csv now has $(($(wc -l < out/raw.csv) - 1)) measurement rows"

python3 analysis/analyze.py
echo
echo "point fix complete $(date -Is)"
