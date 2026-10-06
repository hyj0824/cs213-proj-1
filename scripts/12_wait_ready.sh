#!/usr/bin/env bash
# Block until both engines accept connections, then report which SQL entry
# points work. openGauss images differ in who they run as and how gsql must be
# invoked, so we probe instead of guessing.
source "$(dirname "$0")/lib.sh"

probe() {  # name container timeout
  local name="$1" ctr="$2" t="${3:-90}" i=0
  log "waiting for $name ..."
  while [ "$i" -lt "$t" ]; do
    if [ "$name" = postgres ]; then
      docker exec -e PGPASSWORD="$PG_PASSWORD" "$ctr" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1 \
        && { log "$name ready"; return 0; }
    else
      docker exec "$ctr" su - omm -c \
        "gsql -d $OG_DB -U $OG_USER -W '$OG_PASSWORD' -h 127.0.0.1 -p 5432 -A -t -c 'select 1'" >/dev/null 2>&1 \
        && { log "$name ready (database '$OG_DB')"; return 0; }
      docker exec "$ctr" su - omm -c "gsql -d postgres -p 5432 -A -t -c 'select 1'" >/dev/null 2>&1 \
        && { log "$name running, but database '$OG_DB' does not exist yet -- 25_bootstrap.sh creates it"; return 0; }
    fi
    i=$((i + 1)); sleep 1
  done
  warn "$name not ready after ${t}s -- last 30 log lines:"
  docker logs --tail 30 "$ctr" 2>&1 | sed 's/^/    /' >&2
  return 1
}

rc=0
ctr_running "$PG_CTR" && probe postgres "$PG_CTR" 60 || rc=1
ctr_running "$OG_CTR" && probe opengauss "$OG_CTR" 120 || rc=1
exit $rc
