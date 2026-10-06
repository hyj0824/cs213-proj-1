#!/usr/bin/env bash
# Run the harness pinned to the CLIENT cpuset, with ONLY the JDBC driver of the
# selected backend on the classpath.
#
# Why the classpath is per-backend: opengauss-jdbc is a fork of pgjdbc and ships
# the *same* package/class names (org.postgresql.Driver). Putting both jars on
# one classpath means one silently shadows the other, and the failure mode is a
# confusing "Protocol error. Session setup failed." against PostgreSQL.
#
# Client/server CPU separation is not a detail either: if the JVM and the
# database compete for the same physical cores, every high-concurrency number is
# meaningless. The server owns $SERVER_CPUS, the client owns $CLIENT_CPUS, and
# neither touches the other's SMT siblings.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
[ -f "$ROOT/.tools/jdk.env" ] && . "$ROOT/.tools/jdk.env"
source "$ROOT/scripts/lib.sh" 2>/dev/null || true
CLIENT_CPUS="${CLIENT_CPUS:-8,10}"
export BENCH_ROOT="$ROOT"

JVM=(-Xms2g -Xmx2g -XX:+AlwaysPreTouch -XX:+UseParallelGC)

BACKEND=""
ARGS=()
DATA_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --backend)
      BACKEND="$2"
      case "$BACKEND" in
        pg) ARGS+=(--jdbc "jdbc:postgresql://127.0.0.1:${PG_HOST_PORT:-5432}/${PG_DB:-bench}" --user "${PG_USER:-bench}" --pass "${PG_PASSWORD:-bench}") ;;
        # NOTE: opengauss-jdbc is a pgjdbc fork that registers itself as
        # org.postgresql.Driver and only accepts jdbc:postgresql:// URLs
        # ("jdbc:opengauss://" gives "No suitable driver found"). Because the
        # classpath below contains only the openGauss jar for this backend, the
        # connection still goes through openGauss's own driver -- the harness
        # prints the driver's code source so the report can prove which one ran.
        og) ARGS+=(--jdbc "jdbc:postgresql://127.0.0.1:${OG_HOST_PORT:-5433}/${OG_DB:-bench}" --user "${OG_USER:-gaussdb}" --pass "${OG_PASSWORD:-Bench@123}") ;;
      esac
      ARGS+=("$1" "$2"); shift 2 ;;
    --data) DATA_GIVEN=1; ARGS+=("$1" "$2"); shift 2 ;;
    --files) shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ "$DATA_GIVEN" = 0 ] && ARGS+=(--data "$ROOT/data")

JARS=""
case "$BACKEND" in
  pg) for j in lib/postgresql-*.jar; do [ -e "$j" ] && JARS="$JARS:$j"; done ;;
  og) for j in lib/opengauss-jdbc-*.jar; do [ -e "$j" ] && JARS="$JARS:$j"; done ;;
  # file backend: no JDBC driver at all
esac
CP="out${JARS}"
if [ -z "$JARS" ]; then
  warn "no JDBC jar selected for backend '$BACKEND' (fine for --backend file)"
fi

PREFIX=()
command -v taskset >/dev/null && PREFIX=(taskset -c "$CLIENT_CPUS")

echo "> taskset -c $CLIENT_CPUS java ${JVM[*]} -cp $CP bench.Main ${ARGS[*]}"
exec "${PREFIX[@]}" java "${JVM[@]}" -cp "$CP" bench.Main "${ARGS[@]}"
