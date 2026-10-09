#!/usr/bin/env bash
# Final consolidation.
#
#   1. Re-run ONLY the file backend's counter series. The main run was taken
#      before the fsync variant was labelled separately, so "seqscan" and
#      "seqscan+fsync" were pooled into one summary row with n=14 and a shared
#      median -- which hides the single most interesting comparison in the whole
#      project (the file program's speed advantage is the fsync it never paid).
#
#   2. Regenerate the figures from the consolidated data.
#
#   3. Print the numbers that go into the report's Key Findings.
#
# Safe to re-run: each step is idempotent and writes to its own file until the
# final merge.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

MAIN="$OUT_DIR/raw_main.csv"        # the full run (minus superseded point rows)
POINTFIX="$OUT_DIR/raw_pointfix.csv"
COUNTERFIX="$OUT_DIR/raw_counterfix.csv"

# ---------------------------------------------------------------- 1. counter ---
if [ ! -f "$COUNTERFIX" ]; then
  echo "=== re-running the file backend counter series (fsync vs not) ==="
  : > "$COUNTERFIX"
  for t in 1 4 16 64; do
    ./benchmark/run.sh --backend file --mode counter --threads "$t" --iters 500 \
      --reps 7 --scale "${SCALE:-8}" --group "counter_t${t}_fix" --run-id counterfix \
      --out "$COUNTERFIX" 2>&1 | grep -E '^==' || true
    ./benchmark/run.sh --backend file --mode counter --threads "$t" --iters 500 \
      --reps 7 --scale "${SCALE:-8}" --group "counter_t${t}_fix" --run-id counterfix \
      --file-fsync --out "$COUNTERFIX" 2>&1 | grep -E '^==' || true
  done
fi

# ------------------------------------------------------------------ 2. merge ---
echo
echo "=== consolidating out/raw.csv ==="
{
  # header + main run, minus the rows the re-runs supersede
  awk -F, 'NR==1 || !($6=="point" && $7=="n=2000")' "$MAIN" \
  | awk -F, 'NR==1 || !($4=="file" && $5=="seqscan" && $6=="counter")'
  tail -n +2 "$POINTFIX" 2>/dev/null || true
  tail -n +2 "$COUNTERFIX" 2>/dev/null || true
} > out/raw.csv

echo "out/raw.csv: $(($(wc -l < out/raw.csv) - 1)) measurement rows"

# --------------------------------------------------------------- 3. analyse ----
python3 analysis/analyze.py

echo
echo "=== figures ==="
if [ -f .tools/mpl.env ]; then
  . .tools/mpl.env
  python3 analysis/plot.py --summary out/summary.csv --raw out/raw.csv \
                           --storage out/storage_ab.md --outdir out/figures
else
  echo "matplotlib environment not found (.tools/mpl.env); tables are still complete"
fi

echo
echo "=== report inputs ==="
ls -la out/report_tables.md out/summary.csv out/figures/ 2>/dev/null | head -12
echo
echo "consolidation complete $(date -Is)"
