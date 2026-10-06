#!/usr/bin/env bash
# Fetch the JDBC drivers into lib/ and compile.  No build tool needed.
set -euo pipefail
cd "$(dirname "$0")"
# use the self-contained JDK if the system has only a JRE
[ -f ../.tools/jdk.env ] && . ../.tools/jdk.env
command -v javac >/dev/null || { echo "no javac: run scripts/05_install_jdk.sh first" >&2; exit 1; }
LIB=lib; OUT=out; mkdir -p "$LIB" "$OUT"

PG_VER=${PG_JDBC_VER:-42.7.4}
if [ ! -f "$LIB/postgresql-$PG_VER.jar" ]; then
  echo "downloading PostgreSQL JDBC driver $PG_VER ..."
  curl -fsSL -o "$LIB/postgresql-$PG_VER.jar" \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/$PG_VER/postgresql-$PG_VER.jar" \
    || echo "WARN: could not download the PostgreSQL driver -- put a jar in lib/ manually"
fi

# openGauss JDBC.  If this artifact is unavailable, the PostgreSQL driver works
# against openGauss as long as its pg_hba uses md5 (sql/guc/og_guc.sql sets
# password_encryption_type = 0 for exactly this reason).  See lib/README.md.
OG_VER=${OG_JDBC_VER:-5.0.0}
if ! ls "$LIB"/opengauss-jdbc*.jar >/dev/null 2>&1; then
  echo "downloading openGauss JDBC driver $OG_VER (optional) ..."
  curl -fsSL -o "$LIB/opengauss-jdbc-$OG_VER.jar" \
    "https://repo1.maven.org/maven2/org/opengauss/opengauss-jdbc/$OG_VER/opengauss-jdbc-$OG_VER.jar" \
    || echo "WARN: openGauss JDBC unavailable; the harness will fall back to the PostgreSQL driver"
fi

CP="$OUT:$(ls "$LIB"/*.jar 2>/dev/null | tr '\n' ':')"
echo "classpath: $CP"
javac -encoding UTF-8 --release 11 -d "$OUT" -cp "$CP" $(find src -name '*.java')
echo "compiled $(find "$OUT" -name '*.class' | wc -l) classes -> $OUT"
