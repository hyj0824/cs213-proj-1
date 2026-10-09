#!/usr/bin/env bash
# One-shot launcher for the full benchmark, used to start it in a Herdr tab.
#
#   1. pins the CPU governor to `performance` (this is the only step that needs
#      sudo; the prompt appears in this pane, type the password once)
#   2. runs the full sweep and mirrors everything to out/full_run.log
#
# Doing the two steps in one process matters: the governor is part of the
# measurement apparatus, and a run started without it is not comparable with the
# numbers already in out/pilot_raw.csv.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p out

LOG="$ROOT/out/full_run.log"
echo "launcher started $(date -Is)" | tee -a "$LOG"

# ------------------------------------------------------------------ governor ---
GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
if [ "$GOV" = "performance" ]; then
  echo "[1/2] CPU governor already 'performance'" | tee -a "$LOG"
else
  echo "[1/2] CPU governor is '$GOV' -> setting 'performance'." | tee -a "$LOG"
  echo "      >>> sudo will ask for your password now. Type it in this pane. <<<" | tee -a "$LOG"
  sudo -v                                  # prompt once, visibly
  sudo sh -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null'
  echo "[1/2] governor is now: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)" | tee -a "$LOG"
fi

# ------------------------------------------------------------------ the run ---
echo "[2/2] starting the full benchmark at $(date -Is)" | tee -a "$LOG"
echo "      phases already done: $(ls out/phases 2>/dev/null | tr '\n' ' ')" | tee -a "$LOG"
echo "      monitor:  tail -f $LOG" | tee -a "$LOG"
echo | tee -a "$LOG"

set +e
bash scripts/50_full_run.sh 2>&1 | tee -a "$LOG"
RC="${PIPESTATUS[0]}"
set -e

echo | tee -a "$LOG"
if [ "$RC" -eq 0 ]; then
  echo "launcher: full run COMPLETED at $(date -Is)" | tee -a "$LOG"
  echo "next:  python3 analysis/analyze.py   and read out/report_tables.md" | tee -a "$LOG"
else
  echo "launcher: full run STOPPED with exit $RC at $(date -Is)" | tee -a "$LOG"
  echo "phases completed so far: $(ls out/phases 2>/dev/null | tr '\n' ' ')" | tee -a "$LOG"
  echo "re-running the launcher resumes from the last completed phase." | tee -a "$LOG"
fi
exit "$RC"
