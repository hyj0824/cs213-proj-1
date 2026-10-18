#!/usr/bin/env bash
# The experiment matrix, one command.
#
#   SCALE=1 scripts/40_run_all.sh                    # small filmdb dataset
#   SCALE=8 scripts/40_run_all.sh                    # 8 x the IMDb titles (~12 GB)
#   BACKENDS="pg" MODES="scan" SCALE=1 scripts/40_run_all.sh
#
# Structure: phases (warm/warm/.../cold) outermost, then ONE ENGINE AT A TIME
# running all of its experiments. That ordering is not cosmetic. The host has
# 16 GiB, so two servers each holding a 4 GiB shared_buffers plus a 12 GiB table
# simply do not fit; with EXCLUSIVE=1 the idle container is stopped for the
# duration of the other one's block, which both frees the RAM and gives every
# backend the same cold buffer pool. The price is that the two engines are
# measured minutes apart rather than interleaved, which is why the whole matrix
# is repeated in several phases and why analysis/analyze.py prints the
# coefficient of variation -- drift has to be visible, not assumed away.
source "$(dirname "$0")/lib.sh"

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M)}"
# Callers can redirect the measurement log. Without this a wrapper that wanted
# its own file had no way to say so, and a later merge silently overwrote the
# rows it had just collected.
RAW="${RAW_OUT:-$OUT_DIR/raw.csv}"
MODES="${MODES:-scan point update counter join}"
BACKENDS="${BACKENDS:-pg og file}"
WARM_COLD="${WARM_COLD:-warm warm warm cold}"
KEYWORDS="${KEYWORDS:-the a man love}"
POINT_IDS="${POINT_IDS:-2000}"
# Without an index every point lookup is a full table scan, so the no-index
# variant uses a much smaller sample. What is being measured is the per-lookup
# cost, and that does not need 2000 samples: at 12.8M rows, 2000 unindexed
# lookups would be 2000 x 792 MB of I/O per repetition.
NOINDEX_IDS="${NOINDEX_IDS:-50}"
# The unindexed variant is the most expensive measurement in the whole matrix
# (every lookup is a full table scan). NOINDEX=0 skips it when only the indexed
# series needs redoing.
NOINDEX="${NOINDEX:-1}"
THREADS_LIST="${THREADS_LIST:-1 4 16 64}"
COUNTER_ITERS="${COUNTER_ITERS:-500}"
EXCLUSIVE="${EXCLUSIVE:-0}"

log "run $RUN_ID  scale $SCALE  modes[$MODES]  backends[$BACKENDS]  phases[$WARM_COLD]  exclusive=$EXCLUSIVE"

harness() { # backend mode extra-args...
  local backend="$1" mode="$2"; shift 2
  ./benchmark/run.sh --backend "$backend" --mode "$mode" \
      --reps "$REPS" --warmup "$WARMUP" --scale "$SCALE" --group "$GROUP" \
      --run-id "$RUN_ID" --out "$RAW" "$@" 2>&1 \
    | grep -E '^(==|# driver)' || true
}

enabled() { case " $MODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

container_of() { [ "$1" = pg ] && echo "$PG_CTR" || echo "$OG_CTR"; }

begin_backend() { # free the host for one engine
  local eng="$1" other
  [ "$EXCLUSIVE" = 1 ] && [ "$eng" != file ] || return 0
  other="$(container_of "$([ "$eng" = pg ] && echo og || echo pg)")"
  ctr_running "$other" && { log "  (exclusive) stopping $other"; docker stop "$other" >/dev/null; }
}
end_backend() {
  local eng="$1" other
  [ "$EXCLUSIVE" = 1 ] && [ "$eng" != file ] || return 0
  other="$(container_of "$([ "$eng" = pg ] && echo og || echo pg)")"
  ctr_running "$other" || { log "  (exclusive) restarting $other"; docker start "$other" >/dev/null; }
}

# In a cold phase every repetition must start with a cold page cache, and there
# must be no warm-up at all: a warm-up run reads the whole table and would warm
# exactly the cache we are trying to keep cold. Passing --warmup 0 and running the
# drop command before every repetition is the only way this measures what it says.
# COLD_CMD must be a single executable path with no spaces: the harness takes one
# token as the option value, and an earlier version of this silently ran `sh` with
# no arguments because the command string was word-split. Nothing failed loudly --
# the cache simply was not dropped -- so the guard below is deliberate.
COLD_CMD="${COLD_CMD:-scripts/90_drop_caches.sh}"
case "$COLD_CMD" in *" "*) die "COLD_CMD must be a single path with no spaces (got: $COLD_CMD)" ;; esac
[ -x "$COLD_CMD" ] || die "COLD_CMD is not executable: $COLD_CMD"

cache_args() {
  if [ "$PHASE_COLD" = 1 ]; then printf -- '--warmup 0 --pre-rep-cmd %s' "$COLD_CMD"; fi
}
# shellcheck disable=SC2086
run_cached() { harness "$1" "$2" "${@:3}" $(cache_args); }

run_engine() { # engine
  local eng="$1"
  if [ "$eng" != file ] && ! ctr_running "$(container_of "$eng")"; then
    warn "$eng container not running, skipped"; return 0
  fi
  begin_backend "$eng"

  if [ "$PHASE_COLD" = 1 ]; then
    log "  cold phase: no warm-up, cache dropped before every repetition"
  else
    # the first run of any session is always slower: JIT, buffer pool, page cache
    log "  warming up $eng"
    local keep="$GROUP"; GROUP="${GROUP}_warmup"
    harness "$eng" scan --keyword the --reps 1 --warmup 0 >/dev/null
    GROUP="$keep"
  fi

  # ------------------------------------------------------------ retrieval ---
  if enabled scan; then
    for kw in $KEYWORDS; do
      # PostgreSQL 18 can split a sequential scan across parallel workers;
      # openGauss uses query_dop, default 1 (serial). The lite binary accepts
      # query_dop=4 despite the published matrix. Reporting only the default run
      # would therefore compare four cores against one and call it an engine
      # difference. So the scan is measured twice:
      #   *_1core  -- max_parallel_workers_per_gather=0, one core on each side,
      #               which is the only setting in which the DBMS and the
      #               single-threaded file program do the same amount of work
      #   default  -- as shipped, which is what a user actually gets
      if [ "$eng" != file ] && [ "${PARALLEL_SWEEP:-1}" = 1 ]; then
        local keep="$GROUP"; GROUP="${GROUP}_1core"
        run_cached "$eng" scan --keyword "$kw" --parallel 0 --explain "$OUT_DIR/explain"
        GROUP="$keep"
      fi
      run_cached "$eng" scan --keyword "$kw" --explain "$OUT_DIR/explain"
    done
  fi

  if enabled point; then
    run_cached "$eng" point --ids "$POINT_IDS" --explain "$OUT_DIR/explain"
    # Same query, no index. This is the cheapest possible evidence that the
    # DBMS's speed comes from maintaining an access structure, not from magic.
    if [ "$eng" != file ] && [ "$NOINDEX" = 1 ]; then
      log "  dropping the primary key to measure the same query without an index ($NOINDEX_IDS lookups)"
      bash scripts/35_toggle_index.sh down >/dev/null 2>&1
      run_cached "$eng" point --ids "$NOINDEX_IDS" --explain "$OUT_DIR/explain"
      bash scripts/35_toggle_index.sh up >/dev/null 2>&1
    fi
  fi

  if enabled join; then
    run_cached "$eng" join --keyword the --explain "$OUT_DIR/explain"
  fi

  # ------------------------------------------------------------- update -----
  if enabled update; then
    log "  update: $REPS destructive runs, input restored between each"
    harness "$eng" update --explain "$OUT_DIR/explain" \
            --restore-cmd "bash scripts/91_restore_people.sh $eng"
  fi

  # -------------------------------------------------------- concurrency -----
  if enabled counter; then
    for t in $THREADS_LIST; do
      harness "$eng" counter --threads "$t" --iters "$COUNTER_ITERS"
      if [ "$eng" = file ]; then
        # The flag that makes the file side's result comparable at all: without
        # fsync the file program never asks the disk to confirm anything, so its
        # speed advantage is the durability cost it did not pay.
        harness "$eng" counter --threads "$t" --iters "$COUNTER_ITERS" --file-fsync
      fi
    done
  fi

  end_backend "$eng"
}

for phase in $WARM_COLD; do
  GROUP="scale${SCALE}_${phase}"
  log "================= phase $phase ($GROUP) ================="
  case "$phase" in
    cold)
      export PHASE_COLD=1
      if ! "$COLD_CMD"; then
        warn "no cold-cache control available -- the 'cold' phase would really be"
        warn "another warm pass. Aborting instead of mislabelling data."
        exit 1
      fi ;;
    *) export PHASE_COLD=0 ;;
  esac

  for eng in $BACKENDS; do
    log "--- $eng ---"
    run_engine "$eng"
    if [ "$eng" = file ] && enabled point; then
      # the armed variant: a sorted file plus a hand-built byte-offset index,
      # i.e. the DBMS's row directory rebuilt by hand
      GROUP="${GROUP}_fileidx"; run_cached file point --ids "$POINT_IDS" --file-impl idx
    fi
    if [ "$eng" = file ] && enabled join; then
      GROUP="${GROUP}_hashjoin"; run_cached file join --keyword the --file-impl hash
    fi
    GROUP="scale${SCALE}_${phase}"
  done
done

# both engines must be up again for whatever comes next
docker start "$PG_CTR" >/dev/null 2>&1; docker start "$OG_CTR" >/dev/null 2>&1

log "raw results: $RAW ($(wc -l < "$RAW") data lines)"
log "now:  python3 analysis/analyze.py --raw $RAW"
