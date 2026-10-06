#!/usr/bin/env bash
# Create/reset the benchmark tables (sql/00_bootstrap.sql) on both engines.
# Destructive: it drops and recreates bench_*_active. Callers run it before
# loading, never during a measurement.
source "$(dirname "$0")/lib.sh"

# openGauss images vary in which database exists out of the box, so create the
# benchmark database if it is missing rather than assuming.
ensure_og_db() {
  ctr_running "$OG_CTR" || return 0
  if og_sql -tAc 'select 1' >/dev/null 2>&1; then
    log "openGauss: database '$OG_DB' present"
    return 0
  fi
  # DBCOMPATIBILITY matters more than it looks. openGauss defaults to Oracle
  # compatibility, where the empty string IS NULL, so the filmdb dump dies on
  # "null value in column surname violates not-null constraint" and the whole
  # 76k-statement transaction aborts. Comparing PostgreSQL against an
  # Oracle-compatibility database would be comparing two SQL dialects rather
  # than two engines, which is not the experiment.
  log "openGauss: creating database '$OG_DB' (DBCOMPATIBILITY 'PG') owned by $OG_USER"
  og_sql_admin -c "CREATE DATABASE $OG_DB WITH OWNER $OG_USER DBCOMPATIBILITY 'PG' \
                     ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0" 2>&1 | grep -i error \
    && warn "database creation reported an error; inspect above"
  og_sql_admin -tAc "select datname, datcompatibility from pg_database where datname='$OG_DB'"
}

ensure_og_db

for pair in "$PG_CTR:postgres" "$OG_CTR:opengauss"; do
  ctr="${pair%%:*}"; eng="${pair##*:}"
  ctr_running "$ctr" || { warn "$eng container not running, skipped"; continue; }
  log "$eng: applying sql/00_bootstrap.sql"
  if [ "$eng" = postgres ]; then
    pg_sql -v ON_ERROR_STOP=1 -f - < "$ROOT/sql/00_bootstrap.sql" >/dev/null
  else
    og_sql < "$ROOT/sql/00_bootstrap.sql" >/dev/null
  fi
  log "$eng: ok"
done
