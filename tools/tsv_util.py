#!/usr/bin/env python3
"""Streaming TSV utilities for the file backend.

The file side of the comparison must read *exactly* the same values the SQL side
sees.  Rather than re-implementing RFC4180 quoting in two languages and hoping
the two parsers agree, the export is done in a TSV dialect that needs no
escaping at all:

    id <TAB> title

sql/01_guardrails.sql asserts that no loaded value contains a tab or a newline,
which is what makes this sound.  That assertion is part of the experiment, not
an afterthought: it is the reason the comparison is valid.

Commands
    to-tsv    <csv-file> <out-tsv>          CSV (as produced by COPY) -> id<TAB>text
    to-tsv3   <csv-file> <out-tsv>          CSV -> a<TAB>b<TAB>c
    index     <sorted-tsv> <out-idx>        write 8-byte big-endian offsets
"""
import csv
import struct
import sys


def to_tsv(src, dst, ncols):
    written = 0
    with open(src, "r", encoding="utf-8", newline="") as fi, \
         open(dst, "w", encoding="utf-8", newline="") as fo:
        for row in csv.reader(fi, delimiter=",", quotechar='"'):
            if not row:
                continue
            fields = []
            for i in range(ncols):
                v = row[i] if i < len(row) else ""
                v = v.replace("\t", " ").replace("\n", " ").replace("\r", " ")
                fields.append(v)
            fo.write("\t".join(fields))
            fo.write("\n")
            written += 1
    print(f"to-tsv: {written} rows -> {dst}", file=sys.stderr)


def build_index(src, dst):
    """Record the byte offset of every record in an id-sorted TSV.

    This is the file-side equivalent of a row directory / B-tree leaf level, and
    building it is exactly the work a DBMS does on your behalf.  Keeping it
    explicit is the point of the "armed file program" experiment.
    """
    offsets = 0
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        buf = bytearray()
        pos = fi.tell()
        while True:
            line = fi.readline()
            if not line:
                break
            buf += struct.pack(">q", pos)
            offsets += 1
            pos = fi.tell()
            if len(buf) >= 1 << 20:
                fo.write(buf)
                buf = bytearray()
        if buf:
            fo.write(buf)
    print(f"index: {offsets} offsets ({offsets * 8} bytes) -> {dst}", file=sys.stderr)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "to-tsv":
        to_tsv(sys.argv[2], sys.argv[3], 2)
    elif cmd == "to-tsv3":
        to_tsv(sys.argv[2], sys.argv[3], 3)
    elif cmd == "index":
        build_index(sys.argv[2], sys.argv[3])
    else:
        sys.exit(f"unknown command {cmd}")
