#!/usr/bin/env bash
# Mechanism evidence for the cold-cache finding.
#
# The EXPLAIN (ANALYZE, BUFFERS) dumps taken during the cold sweep were captured
# with a WARM cache: the harness writes the EXPLAIN once per case, before the
# first repetition, and in a cold phase the cache is dropped *before each
# repetition* -- i.e. after the EXPLAIN. So the plan showed warm I/O numbers.
#
# This script captures the plan in a genuinely cold state (drop, then immediately
# EXPLAIN with --reps 1 --warmup 0) and then again warm, so the two can be
# compared. It must run in a pane whose sudo timestamp is valid.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
OUTDIR="$OUT_DIR/explain_cold"
mkdir -p "$OUTDIR"

for spec in "pg:0" "pg:4" "og:0"; do
  eng="${spec%%:*}"; par="${spec##*:}"
  label="$eng"
  [ "$par" = 0 ] && label="$eng-1core" || label="$eng-parallel"

  for mode in cold warm; do
    if [ "$mode" = cold ]; then
      bash scripts/90_drop_caches.sh >/dev/null 2>&1 || { echo "drop failed"; exit 1; }
    fi
    echo "--- $label / $mode ---"
    ./benchmark/run.sh --backend "$eng" --mode scan --keyword the --parallel "$par" \
      --reps 1 --warmup 0 --scale "${SCALE:-8}" --group "coldev_$mode" --run-id coldev \
      --out "$OUT_DIR/raw.csv" --explain "$OUTDIR" 2>&1 | grep -E "^(==|# driver)" || true
  done
done
# keep only the plans, drop the temporary measurement log
rm -f "$OUT_DIR/raw.csv"
echo
echo "=== plans ==="
for f in "$OUTDIR"/*.txt; do
  printf '%-46s %s\n' "$(basename "$f")" "$(grep -m1 -E 'I/O Timings' "$f" || echo '(no I/O timings)')"
done
