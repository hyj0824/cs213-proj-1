#!/usr/bin/env bash
# Re-measure the cold series properly, at all four scales, with one method.
#
# What was wrong with the first attempt, in order of severity:
#
#   1. The "cold" phase was not cold. run_engine() began with a warm-up scan,
#      which reads the whole table and warms exactly the cache we were trying to
#      keep cold. Measured effect: at SCALE=8 the PostgreSQL single-core cold
#      number was 1.000x the warm number. The series was a repeat warm pass with a
#      cold label.
#
#   2. The cache was dropped once per phase, not per repetition, so even without
#      the warm-up only the first repetition would have been cold.
#
#   3. The method differed by scale: a real drop_caches at SCALE=1 (root was still
#      available), and a weaker scratch-file eviction afterwards.
#
# This script fixes all three: no warm-up, a real drop_caches before EVERY
# repetition (--pre-rep-cmd), and the same method at every scale. It needs root,
# so it asks for the password once in this pane and then keeps the sudo timestamp
# alive for the duration -- the timestamp is per-TTY, which is why this has to run
# here rather than from another terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

COLD="$OUT_DIR/raw_coldfix.csv"
MAIN="$OUT_DIR/raw_main.csv"
POINTFIX="$OUT_DIR/raw_pointfix.csv"
[ -f "$MAIN" ] || { echo "missing $MAIN"; exit 1; }

# ------------------------------------------------------------------- root ------
echo "=== obtaining root for drop_caches ==="
if ! sudo -n true 2>/dev/null; then
  echo "    >>> sudo will ask for your password now. Type it in this pane. <<<"
  sudo -v
fi
# Keep the timestamp alive: without this it expires 15 minutes in and every
# later repetition silently falls back to the weaker method.
cat > /tmp/coldfix_keepalive.sh <<'KA'
#!/usr/bin/env bash
while true; do sudo -n -v 2>/dev/null || exit 0; sleep 60; done
KA
chmod +x /tmp/coldfix_keepalive.sh
setsid nohup /tmp/coldfix_keepalive.sh >/dev/null 2>&1 &
echo "    keep-alive pid $(pgrep -f coldfix_keepalive | head -1); stop it with: pkill -f coldfix_keepalive"

export SCALE=0
if ! bash scripts/90_drop_caches.sh >/dev/null 2>&1; then
  echo "FATAL: drop_caches did not work; refusing to produce another mislabelled cold series"
  exit 1
fi
echo "    drop_caches verified"

# --------------------------------------------------------------- cold sweep ----
head -1 "$MAIN" > "$COLD"
for S in 1 2 4 8; do
  echo
  echo "########## SCALE=$S ##########"
  SCALE="$S" bash scripts/34_amplify.sh | tail -2
  before=$(wc -l < "$COLD")
  SCALE="$S" RAW_OUT="$COLD" RUN_ID="coldfix-s$S" MODES="scan point join" \
    BACKENDS="pg og file" REPS=7 WARMUP=0 WARM_COLD="cold" EXCLUSIVE=1 \
    KEYWORDS="the a man love" POINT_IDS=2000 NOINDEX=0 \
    bash scripts/40_run_all.sh
  after=$(wc -l < "$COLD")
  [ "$after" -gt "$before" ] || { echo "FATAL: scale $S wrote no rows"; exit 1; }
  echo "scale $S: +$((after - before)) rows"
done

# ------------------------------------------------------------------ merge ------
echo
echo "=== merging: replace the old cold rows with these ==="
{
  awk -F, 'NR==1 || $3 !~ /_cold/' out/raw.csv      # drop the old (invalid) cold groups
  tail -n +2 "$COLD"
} > /tmp/raw_merged.csv
mv /tmp/raw_merged.csv out/raw.csv
echo "out/raw.csv: $(($(wc -l < out/raw.csv) - 1)) measurement rows"

python3 analysis/analyze.py
echo
if [ -f .tools/mpl.env ]; then
  . .tools/mpl.env
  python3 analysis/plot.py --summary out/summary.csv --raw out/raw.csv \
                           --storage out/storage_ab.md --outdir out/figures
fi

echo
echo "=== cold-cache evidence ==="
cat out/cold_method.txt
echo
echo "warm vs cold, ratio (1.00 means the cache made no difference):"
python3 - <<'PY'
import csv
rows=[r for r in csv.DictReader(open('out/summary.csv')) if r['mode']=='scan' and r['param']=='the']
by={}
for r in rows:
    if '_warmup' in r['group']: continue
    ph='cold' if '_cold' in r['group'] else 'warm'
    by.setdefault((r['scale'],r['backend'],r['impl'],ph),[]).append(float(r['median_ms']))
for k in sorted(by, key=lambda k:(int(k[0]),k[1],k[2],k[3])):
    if k[3]!='warm': continue
    w=by[k][0]; c=by.get((k[0],k[1],k[2],'cold'),[float('nan')])[0]
    print(f"  s{k[0]:>2s} {k[1]:5s} {k[2]:18s} warm {w:8.0f} ms  cold {c:9.0f} ms  {c/w:5.3f}x")
PY
echo
echo "cold fix complete $(date -Is)"
