#!/usr/bin/env bash
# Start both engines as containers, with the data directory bind-mounted onto
# the host NVMe (not the container's overlayfs layer) and pinned to the same
# cpuset so the comparison is apples-to-apples.
source "$(dirname "$0")/lib.sh"

mkdir -p "$HOST_DATA_ROOT/$PG_DATA_DIR" "$HOST_DATA_ROOT/$OG_DATA_DIR"
# the postgres image runs as uid 999; openGauss runs as omm (uid 1000 inside the image).
# the official image entrypoint runs as root and chowns PGDATA itself

log "postgres : $PG_IMAGE -> $HOST_DATA_ROOT/$PG_DATA_DIR mounted at $PG_MOUNT (cpuset $SERVER_CPUS)"
docker rm -f "$PG_CTR" >/dev/null 2>&1 || true
docker run -d --name "$PG_CTR" \
  --cpuset-cpus "$SERVER_CPUS" \
  --memory "$CTR_MEM" --memory-swap "$CTR_MEM" \
  --shm-size "$CTR_SHM" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_DB="$PG_DB" \
  -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C.UTF-8" \
  -v "$HOST_DATA_ROOT/$PG_DATA_DIR":"$PG_MOUNT" \
  -p "$PG_HOST_PORT":5432 \
  "$PG_IMAGE" >/dev/null

log "openGauss: $OG_IMAGE -> $HOST_DATA_ROOT/$OG_DATA_DIR (cpuset $SERVER_CPUS)"
docker rm -f "$OG_CTR" >/dev/null 2>&1 || true
docker run -d --name "$OG_CTR" \
  --privileged=true \
  --cpuset-cpus "$SERVER_CPUS" \
  --memory "$CTR_MEM" --memory-swap "$CTR_MEM" \
  --shm-size "$CTR_SHM" \
  -e GS_PASSWORD="$OG_PASSWORD" \
  -v "$HOST_DATA_ROOT/$OG_DATA_DIR":/var/lib/opengauss \
  -p "$OG_HOST_PORT":5432 \
  "$OG_IMAGE" >/dev/null

log "waiting for readiness ..."
"$(dirname "$0")/12_wait_ready.sh" || true

cat <<EOF

Both engines are up.
  postgres  : host 127.0.0.1:$PG_HOST_PORT  db=$PG_DB  user=$PG_USER
  openGauss : host 127.0.0.1:$OG_HOST_PORT  db=$OG_DB  user=$OG_USER

Next:  scripts/20_align_guc.sh        # identical settings on both engines
EOF
