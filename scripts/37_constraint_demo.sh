#!/usr/bin/env bash
# "The DBMS refused. The file program complied."
#
# The same T -> Ttt rewrite, on a table that declares an integrity rule, and on
# the flat file that has no way to declare anything at all.
#
# Whether a length rule bites depends on the limit and on how long real names
# are, so instead of picking one number the script sweeps it. The interesting
# output is at which declared limit the rewrite stops being legal, and what each
# side does about it.
#
#   LIMITS="10 15 20 25 30" bash scripts/37_constraint_demo.sh
source "$(dirname "$0")/lib.sh"
OUT="$OUT_DIR/constraint_demo.txt"
LIMITS="${LIMITS:-10 15 20 25 30}"

{
  echo "# Integrity: what the DBMS refuses and the file program cannot notice"
  echo
  echo "Generated $(date -Is)"
  echo
  echo 'The update replaces every `T` with `Ttt`, so a field of length L with k'
  echo 'occurrences of `T` becomes L + 2k. A declared limit such as'
  echo '`VARCHAR(n)` + `CHECK (length(x) <= n)` therefore stops the statement as'
  echo 'soon as a single row would grow past n.'
  echo
} > "$OUT"

# --- the DBMS side -----------------------------------------------------------
for pair in "$PG_CTR:postgres:pg" "$OG_CTR:opengauss:og"; do
  ctr="${pair%%:*}"; rest="${pair#*:}"; eng="${rest%%:*}"; tag="${rest##*:}"
  ctr_running "$ctr" || { warn "$eng not running, skipped"; continue; }
  if [ "$eng" = postgres ]; then sql() { pg_sql "$@"; }; else sql() { og_sql "$@"; }; fi

  log "$eng: sweeping the declared length limit (restoring the table first)"
  # T -> Ttt is not idempotent: "Ttt" still matches LIKE '%T%', so an
  # unrestored table both inflates the violation count and makes the
  # "rows bearing the rewrite afterwards" column meaningless.
  bash "$(dirname "$0")/91_restore_people.sh" "$tag" >/dev/null 2>&1 || true

  {
    echo "## $eng"
    echo
    echo "| declared limit n | table rows | rows the rewrite would push past n | outcome |"
    echo "|---|---|---|---|"
  } >> "$OUT"

  for L in $LIMITS; do
    # 1. Declare the rule and load only rows that already satisfy it. The rule
    #    must be declared at CREATE TABLE time: adding it afterwards would be
    #    rejected by the existing rows and we would be testing nothing.
    sql -c "DROP TABLE IF EXISTS bench_people_strict;
            CREATE TABLE bench_people_strict (
              pid BIGINT PRIMARY KEY,
              first_name VARCHAR($L),
              surname    VARCHAR($L),
              CONSTRAINT bench_strict_len CHECK (
                length(coalesce(first_name,'')) <= $L AND length(coalesce(surname,'')) <= $L));
            INSERT INTO bench_people_strict SELECT pid, first_name, surname
              FROM bench_people_active
             WHERE length(coalesce(first_name,'')) <= $L
               AND length(coalesce(surname,''))    <= $L;
            ANALYZE bench_people_strict" >/dev/null 2>&1 \
      || { warn "$eng: could not build the limit-$L table"; continue; }

    # 2. how much headroom does the rule actually have?
    nrows="$(sql -tAc 'select count(*) from bench_people_strict' 2>/dev/null | tr -dc 0-9 || true)"
    viol="$(sql -tAc "select count(*) from bench_people_strict
                       where length(replace(coalesce(first_name,''),'T','Ttt')) > $L
                          or length(replace(coalesce(surname,''),'T','Ttt')) > $L" 2>/dev/null | tr -dc 0-9 || true)"

    # 3. run the rewrite and see whether the engine lets it through
    out="$(sql -c "UPDATE bench_people_strict
                      SET first_name = replace(first_name,'T','Ttt'),
                          surname    = replace(surname,'T','Ttt')
                    WHERE coalesce(first_name,'') LIKE '%T%' OR coalesce(surname,'') LIKE '%T%'" 2>&1 || true)"
    applied="$(sql -tAc "select count(*) from bench_people_strict where first_name like '%Ttt%' or surname like '%Ttt%'" 2>/dev/null | tr -dc 0-9 || true)"

    if echo "$out" | grep -qi 'error\|violat'; then
      err="$(echo "$out" | head -1 | tr -d '\n' | cut -c1-100)"
      verdict="**refused**, rolled back -- \`$err\`"
    else
      verdict="**accepted**"
    fi
    printf '| %s | %s | %s | %s, rows bearing the rewrite afterwards: %s |\n' \
      "$L" "${nrows:-?}" "${viol:-?}" "$verdict" "${applied:-0}" >> "$OUT"
    log "$eng limit<=$L: ${nrows:-?} rows, ${viol:-?} would break the rule -> ${verdict%% *}"
    sql -c "DROP TABLE IF EXISTS bench_people_strict" >/dev/null 2>&1 || true
  done
  echo >> "$OUT"
done

# --- the file side -----------------------------------------------------------
log "file: applying the identical rewrite and checking the same limits afterwards"
bash "$(dirname "$0")/91_restore_people.sh" file >/dev/null 2>&1 || true
./benchmark/run.sh --backend file --mode update --reps 1 --out "$OUT_DIR/raw_constraint.csv" \
  2>&1 | grep '^==' | sed 's/^/    /' || true

{
  echo "## file backend"
  echo
  echo "The identical rewrite, streamed to a new file. The columns are separated so"
  echo 'the comparison with the table above is honest: "created by the rewrite"'
  echo 'counts only rows that satisfied the rule *before* the update and stopped'
  echo 'satisfying it afterwards -- the same quantity as the DBMS column above.'
  echo '"already invalid" counts rows the flat file never had a way to reject.'
  echo
  echo "| declared limit n | created by the rewrite | already invalid before it | reported to anyone |"
  echo "|---|---|---|---|"
} >> "$OUT"

for L in $LIMITS; do
  read -r created preexisting <<<"$(python3 - "$L" <<'EOPY'
import sys
L = int(sys.argv[1])
created = pre = 0
before = {}
for line in open('data/people_active.tsv.orig', encoding='utf-8'):
    f = line.rstrip('\n').split('\t')
    if len(f) < 3:
        continue
    before[f[0]] = (len(f[1]) <= L and len(f[2]) <= L)
for line in open('data/people_active.tsv', encoding='utf-8'):
    f = line.rstrip('\n').split('\t')
    if len(f) < 3:
        continue
    if len(f[1]) <= L and len(f[2]) <= L:
        continue
    if before.get(f[0], True):
        created += 1
    else:
        pre += 1
print(created, pre)
EOPY
)"
  printf '| %s | %s | %s | 0 -- there is no mechanism |\n' "$L" "${created:-0}" "${preexisting:-0}" >> "$OUT"
done

{
  echo
  echo "The file program did not fail, and nothing downstream will ever know. This is"
  echo "the difference between *faster* and *possible*: a schema can state a rule and"
  echo "the engine will enforce it on every write, including writes nobody"
  echo "contemplated when the rule was written. The DBMS paid for that refusal with"
  echo "**0 rows changed** -- all or nothing, not \\"most of it\\"."
} >> "$OUT"

log "wrote $OUT"
sed -n '/## /,$p' "$OUT"
