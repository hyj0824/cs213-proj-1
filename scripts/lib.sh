#!/usr/bin/env bash
# Shared configuration + helpers. Source this from every script.
# All values can be overridden by exporting them before running a script.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
DATA_DIR="${DATA_DIR:-$ROOT/data}"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
mkdir -p "$DATA_DIR" "$OUT_DIR"

# ---------------------------------------------------------------- topology ---
# i5-12400F = 6 physical cores / 12 threads.
# SMT sibling pairs are (0,1) (2,3) (4,5) (6,7) (8,9) (10,11).
# We pin the DBMS to 4 *whole* physical cores and the client to 2 whole
# physical cores, leaving every SMT sibling idle.  Pinning "0-7" instead would
# silently give the server only 2 physical cores with sibling contention, and
# would put the client on the same cores as the server.
SERVER_CPUS="${SERVER_CPUS:-0,2,4,6}"
CLIENT_CPUS="${CLIENT_CPUS:-8,10}"

# --------------------------------------------------------------- containers ---
PG_CTR="${PG_CTR:-dbbench-pg}"
OG_CTR="${OG_CTR:-dbbench-og}"
PG_IMAGE="${PG_IMAGE:-postgres:18}"
# The official opengauss/opengauss images (7.0.0-RC3 and the 6.x line) cannot
# start as shipped -- libopenblas.so.0 is missing and their own libraries are not
# on the linker path. docker/Dockerfile.opengauss fixes exactly that and nothing
# else, so this is still the official build. Build it with:
#   docker build -f docker/Dockerfile.opengauss -t dbbench/opengauss:7.0.0-RC3 .
OG_IMAGE="${OG_IMAGE:-dbbench/opengauss:7.0.0-RC3}"
PG_HOST_PORT="${PG_HOST_PORT:-5432}"
OG_HOST_PORT="${OG_HOST_PORT:-5433}"
PG_DB="${PG_DB:-bench}"
OG_DB="${OG_DB:-bench}"
PG_USER="${PG_USER:-bench}"
OG_USER="${OG_USER:-gaussdb}"
PG_PASSWORD="${PG_PASSWORD:-bench}"
OG_PASSWORD="${OG_PASSWORD:-Bench@123}"
CTR_MEM="${CTR_MEM:-10g}"
CTR_SHM="${CTR_SHM:-2g}"

# Host directory that backs PGDATA / openGauss data dir.
# Bind-mounting onto the host SSD is what keeps the container's overlayfs
# copy-on-write layer out of the I/O path.  See README "Why the bind mount".
HOST_DATA_ROOT="${HOST_DATA_ROOT:-$HOME/dbbench}"
# Version-suffixed on purpose: a major-version change needs a fresh initdb
# (PostgreSQL cannot read an older PGDATA, and neither can openGauss), and
# keeping the directories separate means the old instance is never destroyed by
# accident mid-experiment.
PG_DATA_DIR="${PG_DATA_DIR:-pgdata18}"
OG_DATA_DIR="${OG_DATA_DIR:-ogdata7}"
# The official PostgreSQL image changed its layout in 18: the mount point is now
# the *parent* (/var/lib/postgresql, with PGDATA=/var/lib/postgresql/18/docker)
# instead of /var/lib/postgresql/data. Mounting the 17 path on an 18 image makes
# initdb refuse to start. Derived from the image's own PGDATA env so the default
# stays correct if the tag moves.
PG_MOUNT="${PG_MOUNT:-$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$PG_IMAGE" 2>/dev/null \
  | awk -F= '/^PGDATA=/{print $2}' | sed 's|/data$||; s|/[0-9]*/docker$||')}"
PG_MOUNT="${PG_MOUNT:-/var/lib/postgresql}"

# ------------------------------------------------------------------- tuning ---
# Identical absolute values on both engines.  Keep this list in sync with
# sql/guc/*.sql, which is what actually applies them.
SHARED_BUFFERS="${SHARED_BUFFERS:-4GB}"
WORK_MEM="${WORK_MEM:-64MB}"
MAINT_WORK_MEM="${MAINT_WORK_MEM:-1GB}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-200}"
MAX_WAL_SIZE="${MAX_WAL_SIZE:-8GB}"
RANDOM_PAGE_COST="${RANDOM_PAGE_COST:-1.1}"
MAX_PARALLEL_PER_GATHER="${MAX_PARALLEL_PER_GATHER:-4}"

# --------------------------------------------------------------------- bench ---
export SCALE="${SCALE:-1}"    # 1 | 2 | 4 | 8 (multiples of the base); exported so child scripts can log it
REPS="${REPS:-7}"
WARMUP="${WARMUP:-2}"
KEYWORD="${KEYWORD:-man}"
POINT_IDS="${POINT_IDS:-2000}"
SEED="${SEED:-20261006}"
THREADS="${THREADS:-8}"
COUNTER_ITERS="${COUNTER_ITERS:-500}"

# ------------------------------------------------------------------- helpers ---
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

ctr_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Run SQL against PostgreSQL from inside its container.  Setup only -- never
# used for measurement (docker exec inherits the container cpuset, so a client
# started this way would steal CPU from the server).
pg_sql() {
  docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CTR" \
    psql -U "$PG_USER" -d "$PG_DB" -X -q "$@"
}
pg_sql_db() { local db="$1"; shift; docker exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CTR" psql -U "$PG_USER" -d "$db" -X -q "$@"; }

# Run SQL against openGauss.
#
# Three things about the openGauss images that cost real time to discover, so
# they are encoded here rather than rediscovered:
#   * gsql is on the PATH of the omm user only, never of root;
#   * gsql does not read PGPASSWORD, the password has to be passed with -W;
#   * the password must be shell-quoted into the "su -c" command line, which is
#     what printf %q is doing below;
#   * gsql does NOT accept "-f -" the way psql does ("The option '-f' need a
#     parameter"). To run a script, pipe it to gsql's stdin with no -f at all.
og_sql() {
  local q
  q="$(printf '%q ' gsql -d "$OG_DB" -U "$OG_USER" -W "$OG_PASSWORD" \
        -h 127.0.0.1 -p 5432 -X -q "$@")"
  docker exec -i "$OG_CTR" su - omm -c "$q"
}

# Same, but against the maintenance database (used to CREATE DATABASE bench).
og_sql_admin() {
  local q
  q="$(printf '%q ' gsql -d postgres -U "$OG_USER" -W "$OG_PASSWORD" \
        -h 127.0.0.1 -p 5432 -X -q "$@")"
  docker exec -i "$OG_CTR" su - omm -c "$q"
}

# Edit openGauss's postgresql.conf through a throwaway root container.
# The host bind mount is mode 0700 for uid 70 (omm), so the host user cannot
# read it, and docker exec needs a *running* container -- which is exactly what
# we do not have when a bad setting has stopped the server from starting.
og_host_sed() { # sed-expression
  docker run --rm -v "$HOST_DATA_ROOT/$OG_DATA_DIR:/mnt" "$OG_IMAGE" \
    sed -i -e "$1" /mnt/data/postgresql.conf
}

require_ctr() {
  ctr_running "$1" || die "container $1 is not running -- run scripts/10_up.sh first"
}

# Warn if the *other* engine is busy while we measure one of them.
assert_idle_other() {
  local me="$1" other cnt
  if [ "$me" = "pg" ]; then other="$OG_CTR"; else other="$PG_CTR"; fi
  ctr_running "$other" || return 0
  if [ "$me" = "pg" ]; then
    cnt="$(og_sql -tAc "select count(*) from pg_stat_activity where state='active' and application_name <> 'gsql'" 2>/dev/null || echo 0)"
  else
    cnt="$(pg_sql -tAc "select count(*) from pg_stat_activity where state='active' and backend_type='client backend'" 2>/dev/null || echo 0)"
  fi
  [ "${cnt:-0}" -le 0 ] || warn "the other engine reports $cnt active session(s); ideally stop it while measuring"
}

# Names of the two benchmark tables for the *active* scale.
TITLES_TABLE="bench_titles_active"
PEOPLE_TABLE="bench_people_active"
