# Write amplification of the `T -> Ttt` update

Measured 2026-10-09T17:17:52+00:00 on `benchmark-host`. All values are total relation bytes
(`pg_relation_size` + `pg_indexes_size`). Autovacuum is **off** during the
measurement and reclamation is timed explicitly, so that no background
process can be credited (or blamed) for anything.

| target | rows changed | before (B) | after update (B) | growth | growth % | dead tuples | VACUUM (ms) | after VACUUM (B) | VACUUM FULL (ms) | after FULL (B) | update (ms) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pg/bench_people_active | 161542 | 153305088 | 163708928 | 10403840 | 6.79% | 161009 | 159 | 163708928 | 772 | 153632768 | 610 |
| og/bench_people_astore | 161542 | 153976832 | 166846464 | 12869632 | 8.36% | 161542 | 138 | 166846464 | 1393 | 167149568 | 796 |
| og/bench_people_ustore | 161542 | 141287424 | 149725184 | 8437760 | 5.97% | 161542 | 165 | 149725184 | 1169 | 141623296 | 1395 |

Reading the table:

* An append-only engine shows `after > before` even though no row was added:
  that difference is the update's write amplification, and it is why the
  same statement costs more the second time.
* `VACUUM FULL` needs a second copy of the table on disk. On a 12 GB table
  that is a real operational constraint, not a footnote.
* openGauss `USTORE` trades `after` for undo space, which lives outside the
  relation and therefore does not show up in `pg_relation_size` -- state that
  caveat explicitly when you quote these numbers.
