#!/usr/bin/env bash
# Download the IMDb non-commercial datasets (free for non-commercial use).
#   title.basics.tsv.gz : 172 MB -> 841 MB, 10,285,368 rows   (titles)
#   name.basics.tsv.gz  : 245 MB -> 753 MB, 12,981,035 rows   (people)
#
# Why: filmdb.sql is 3.9 MB / 9,204 titles.  Everything fits in shared_buffers,
# so it cannot show an I/O bound or a cache-boundary effect.  These files give a
# genuinely large, real-world, correctly-distributed dataset, which is what
# turns the scale sweep into a real experiment instead of three noisy numbers.
source "$(dirname "$0")/lib.sh"

RAW="$DATA_DIR/raw"
mkdir -p "$RAW"
BASE="https://datasets.imdbws.com"
FILES="title.basics.tsv.gz name.basics.tsv.gz"
[ "${WITH_PRINCIPALS:-0}" = 1 ] && FILES="$FILES title.principals.tsv.gz"

for f in $FILES; do
  if [ -s "$RAW/$f" ]; then
    log "$f already present ($(du -h "$RAW/$f" | cut -f1)), skipping"
  else
    log "downloading $f ..."
    curl -fL --retry 3 --progress-bar -o "$RAW/$f.part" "$BASE/$f" || die "download failed: $BASE/$f"
    mv "$RAW/$f.part" "$RAW/$f"
  fi
  zcat -t "$RAW/$f" 2>/dev/null || die "$RAW/$f is not a valid gzip"
  log "  $(zcat "$RAW/$f" | wc -l) lines"
done

log "done -> $RAW"
