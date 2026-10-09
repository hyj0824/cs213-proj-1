#!/usr/bin/env bash
# Put the machine into a state where two runs can be compared.
#
# Cold cache matters more than anything else in this project. On a 16 GiB host a
# 0.8 GiB table is entirely in the OS page cache after the first read, so a
# "cold" number and a "warm" number for the same query can differ by an order of
# magnitude. If you do not control for that, you end up comparing cache states,
# not engines.
#
# Two methods, in order of preference:
#
#   1. drop_caches (exact, needs root)
#        echo 3 > /proc/sys/vm/drop_caches
#      Note it still does NOT clear the server's shared_buffers -- a true cold
#      start needs `docker restart`.
#
#   2. scratch-file eviction (approximate, no root needed)
#      Stream a file larger than the working set through the page cache. The
#      kernel's LRU reclaims the pages we care about in the process. Dentry and
#      inode caches survive, so this is weaker than drop_caches; the method that
#      was actually used is written to out/cold_method.txt and belongs in the
#      report's methodology section.
#
# Either way, the database's own buffer pool is untouched. That is a real
# limitation and it is reported, not hidden.
source "$(dirname "$0")/lib.sh"

EVICT_GB="${EVICT_GB:-14}"                       # > the SCALE=8 heap (6.3 GB) with room to spare
SCRATCH="${SCRATCH:-$HOST_DATA_ROOT/cache_evict.bin}"
METHOD_FILE="$OUT_DIR/cold_method.txt"

sync

drop_caches() {
  if [ -w /proc/sys/vm/drop_caches ]; then
    echo 3 > /proc/sys/vm/drop_caches
  elif sudo -n true 2>/dev/null; then
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  else
    return 1
  fi
}

scratch_evict() {
  local want=$((EVICT_GB * 1024 * 1024 * 1024))
  if [ ! -f "$SCRATCH" ] || [ "$(stat -c%s "$SCRATCH" 2>/dev/null || echo 0)" -lt "$want" ]; then
    log "creating the ${EVICT_GB}G cache-eviction scratch file (one time, ~20s)"
    mkdir -p "$(dirname "$SCRATCH")"
    dd if=/dev/zero of="$SCRATCH" bs=1M count=$((EVICT_GB * 1024)) status=none \
      || { warn "could not create $SCRATCH"; return 1; }
  fi
  log "evicting the page cache by streaming ${EVICT_GB}G through it ..."
  cat "$SCRATCH" > /dev/null || return 1
  # the scratch file's own pages are now cached; drop them so they do not count
  # as part of the working set we are about to measure
  if command -v posix_fadvise >/dev/null 2>&1; then :; fi
  return 0
}

# Recording. In a cold phase this script runs once per repetition, so every
# invocation is logged to out/cold_invocations.log, but the human-readable summary
# records each (method, scale) pair only once -- otherwise the file that the
# report cites as evidence becomes a list of hundreds of identical lines.
record() { # method
  local method="$1"
  printf '%s method=%s scale=%s\n' "$(date -Is)" "$method" "${SCALE:-?}" >> "$OUT_DIR/cold_invocations.log"
  if ! { [ -f "$METHOD_FILE" ] && tail -1 "$METHOD_FILE" | grep -q "method=$method scale=${SCALE:-?}"; }; then
    printf '%s  %s  scale=%s\n' "$(date -Is)" "$method" "${SCALE:-?}" >> "$METHOD_FILE"
  fi
}

if drop_caches; then
  log "page cache dropped (method: drop_caches)"
  record "drop_caches (exact, root)"
elif scratch_evict; then
  log "page cache evicted by streaming a scratch file (method: scratch, no root)"
  warn "this is weaker than drop_caches: dentry/inode caches survive. State that in the report."
  record "scratch eviction ${EVICT_GB}G (approximate, no root)"
else
  warn "no cold-cache control available; this phase is really a warm pass"
  record "NONE -- phase ran warm"
  exit 1
fi

log "note: shared_buffers is NOT cleared by either method; restart the containers for a true cold start:"
log "      docker restart $PG_CTR $OG_CTR"
