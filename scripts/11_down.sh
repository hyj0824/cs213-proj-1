#!/usr/bin/env bash
# Stop/remove containers.  Data stays on the host bind mount, so this is
# non-destructive unless you pass --purge.
source "$(dirname "$0")/lib.sh"

docker rm -f "$PG_CTR" "$OG_CTR" >/dev/null 2>&1 || true
log "containers removed"

if [ "${1:-}" = "--purge" ]; then
  warn "purging $HOST_DATA_ROOT (all database data lost)"
  sudo rm -rf "${HOST_DATA_ROOT:?}/$PG_DATA_DIR" "${HOST_DATA_ROOT:?}/$OG_DATA_DIR"
  log "purged"
fi
