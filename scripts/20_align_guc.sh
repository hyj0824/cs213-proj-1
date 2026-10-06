#!/usr/bin/env bash
# Apply the SAME absolute configuration values to both engines, restart them so
# postmaster-level parameters take effect, then show a side-by-side diff.
#
# Rationale (goes in the report): a comparison where PostgreSQL runs with
# default shared_buffers=128MB and openGauss runs with its shipped defaults is
# not a comparison of engines, it is a comparison of two config files.
#
# The two engines do not even accept configuration the same way:
#   PostgreSQL : ALTER SYSTEM SET ... (sql/guc/pg_guc.sql)
#   openGauss  : rejects most of those through ALTER SYSTEM, so the settings are
#                appended to postgresql.conf (sql/guc/og_conf.conf) instead.
# Both paths are attempted and the outcome is reported.
source "$(dirname "$0")/lib.sh"
require_ctr "$PG_CTR"; require_ctr "$OG_CTR"

log "PostgreSQL: ALTER SYSTEM SET (sql/guc/pg_guc.sql)"
pg_sql -v ON_ERROR_STOP=0 --echo-errors -f - < "$ROOT/sql/guc/pg_guc.sql" 2>&1 | sed 's/^/    /' || true

log "openGauss: ALTER SYSTEM SET first, to record that it is refused"
og_sql_admin < "$ROOT/sql/guc/og_guc.sql" > "$OUT_DIR/og_alter_system.log" 2>&1 || true
grep -ci 'error\|not support' "$OUT_DIR/og_alter_system.log" >/dev/null 2>&1 \
  && log "    $(grep -ci 'error\|not support' "$OUT_DIR/og_alter_system.log") statement(s) rejected -- see $OUT_DIR/og_alter_system.log"

log "openGauss: appending sql/guc/og_conf.conf to postgresql.conf (idempotent)"
OG_DATADIR="$(og_sql_admin -tAc 'show data_directory' 2>/dev/null | tr -d ' \r\n')"
[ -n "$OG_DATADIR" ] || die "could not read openGauss data_directory"
# USTORE is off by default in openGauss 7.0. Keeping it off is the honest way to
# compare the two engines' *default* storage behaviour; turning it on is required
# for the in-place-update experiment. Run the matrix twice if you want both, and
# label the runs.
USTORE="${ENABLE_USTORE:-off}"
log "    enable_ustore=$USTORE (override with ENABLE_USTORE=on|off)"
if grep -q '# === dbbench overrides ===' "$ROOT/sql/guc/og_conf.conf"; then
  { sed "s/@ENABLE_USTORE@/$USTORE/" "$ROOT/sql/guc/og_conf.conf"; } | docker exec -i "$OG_CTR" bash -c \
    "cp -n '$OG_DATADIR/postgresql.conf' '$OG_DATADIR/postgresql.conf.orig' 2>/dev/null;
     sed -i '/^# === dbbench overrides ===/,/^# === end dbbench overrides ===/d' '$OG_DATADIR/postgresql.conf';
     cat >> '$OG_DATADIR/postgresql.conf'" \
    && log "    wrote $(grep -c '=' "$ROOT/sql/guc/og_conf.conf") settings into $OG_DATADIR/postgresql.conf"
else
  warn "og_conf.conf is missing its sentinel comments; refusing to edit postgresql.conf"
fi

log "restarting both engines (postmaster parameters need it)"
docker restart "$PG_CTR" >/dev/null & docker restart "$OG_CTR" >/dev/null & wait

if ! "$(dirname "$0")/12_wait_ready.sh"; then
  warn "an engine did not come back up. If it is openGauss, the appended block is"
  warn "the prime suspect; rolling it back and restarting."
  if grep -q '# === dbbench overrides ===' "$ROOT/sql/guc/og_conf.conf"; then
    og_host_sed '/^# === dbbench overrides ===/,/^# === end dbbench overrides ===/d' || true
  fi
  docker restart "$OG_CTR" >/dev/null
  "$(dirname "$0")/12_wait_ready.sh" || die "still down -- inspect: docker logs $OG_CTR"
  warn "rolled back; the openGauss side is now running on its shipped defaults,"
  warn "which must be stated in the report's threats-to-validity section."
fi

log "settings that actually took effect:"
"$(dirname "$0")/21_dump_guc.sh" "$OUT_DIR/guc_compare.md"
