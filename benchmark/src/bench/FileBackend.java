package bench;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

/**
 * The plain-file backend.
 *
 * Deliberately not a straw man. It reads exactly the bytes the DBMS exported,
 * uses a zero-copy line reader, avoids String allocation on the untouched path,
 * can use a fixed-width page cache friendly buffer, and offers an optional
 * sorted-file + byte-offset-index variant so that "the file program had no
 * index" cannot be used as an excuse for the DBMS's win.
 *
 * Two implementation variants exist for retrieval, and the raw log records
 * which one ran (see {@link #impl()}):
 *
 *   seq   - one streaming pass. For a batch of point lookups this is the only
 *           thing a sequential file can do, so it collects the wanted ids in a
 *           HashSet along the way. Correct, and the fastest possible answer to
 *           "find 2000 rows in a file", but it is still a full scan.
 *   idx   - binary search over a byte-offset index built beside the sorted
 *           file, i.e. we rebuilt the DBMS's row directory by hand. This is the
 *           apples-to-apples opponent for a B-tree lookup.
 */
public final class FileBackend implements Backend {

    private final Path titles, titlesSorted, titlesIdx, titlesRange, people, counter;
    private final String mode;        // seq | idx
    private final boolean fsync;
    private final boolean allowCorruption;

    public enum Impl { SEQ, IDX, HASH }

    private final Impl joinImpl;

    public FileBackend(Path dir, String retrievalImpl, boolean fsync,
                       boolean allowCorruption, Impl joinImpl) {
        this.titles       = dir.resolve("titles_active.tsv");
        this.titlesSorted = dir.resolve("titles_active.sorted.tsv");
        this.titlesIdx    = dir.resolve("titles_active.sorted.idx");
        this.titlesRange  = dir.resolve("titles_active.range");
        this.people       = dir.resolve("people_active.tsv");
        this.counter      = dir.resolve("counter.txt");
        this.fsync        = fsync;
        this.allowCorruption = allowCorruption;
        this.joinImpl     = joinImpl;
        boolean idxAvailable = Files.exists(titlesSorted) && Files.exists(titlesIdx);
        if ("idx".equals(retrievalImpl) && !idxAvailable)
            throw new IllegalStateException("--file-impl idx requested but "
                    + titlesSorted.getFileName() + " / " + titlesIdx.getFileName()
                    + " are missing; run scripts/33_export_files.sh");
        this.mode = "idx".equals(retrievalImpl) ? "idx" : "seq";
    }

    @Override public String engine() { return "file"; }

    /**
     * The fsync flag is part of the physical design being measured, not a detail:
     * without it the file program never asks the disk to confirm anything, which
     * is exactly why it looks 20x faster than a committing DBMS. It has to appear
     * in the label or the two variants get pooled in the summary.
     */
    @Override public String impl() {
        String base = "idx".equals(mode) ? "sorted+byteindex"
                    : (joinImpl == Impl.HASH ? "seqscan+hashjoin" : "seqscan");
        return fsync ? base + "+fsync" : base;
    }

    // ------------------------------------------------------------- retrieval --
    @Override public long titlesContaining(String keyword) throws Exception {
        byte[] needle = keyword.getBytes(StandardCharsets.UTF_8);
        long hits = 0;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(titles))) {
            int n;
            byte[] line = null;
            while ((n = r.next()) >= 0) {
                line = r.line();
                int tab = indexOf(line, n, Tsv.TAB);
                int from = tab < 0 ? 0 : tab + 1;   // ids are digits too, so only
                if (indexOfFrom(line, n, needle, from) >= 0) hits++;   // the title counts
            }
        }
        return hits;
    }

    @Override public long pointLookups(long[] ids) throws Exception {
        if ("idx".equals(mode)) return pointLookupsIndexed(ids);
        return pointLookupsScan(ids);
    }

    /** Best a plain sequential file can do for a batch of point queries: one pass. */
    private long pointLookupsScan(long[] ids) throws IOException {
        HashSet<Long> want = new HashSet<>(ids.length * 2);
        for (long id : ids) want.add(id);
        long found = 0;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(titles))) {
            int n;
            while ((n = r.next()) >= 0) {
                byte[] line = r.line();
                int tab = indexOf(line, n, Tsv.TAB);
                if (tab <= 0) continue;
                long id = parseLong(line, tab);
                if (want.contains(id)) found++;
            }
        }
        return found;
    }

    /**
     * Binary search over a fixed-width byte-offset index, then one positional
     * read per probe. This is the file-side equivalent of a B-tree descent, and
     * measuring it is the whole point of the "reimplement the DBMS" experiment.
     */
    private long pointLookupsIndexed(long[] ids) throws IOException {
        long found = 0;
        try (FileChannel data = FileChannel.open(titlesSorted, StandardOpenOption.READ);
             FileChannel idxc = FileChannel.open(titlesIdx, StandardOpenOption.READ)) {

            long nrec = idxc.size() / 8;
            MappedByteBuffer idx = idxc.map(FileChannel.MapMode.READ_ONLY, 0, idxc.size());
            idx.order(ByteOrder.BIG_ENDIAN);
            ByteBuffer rec = ByteBuffer.allocateDirect(256);
            for (long id : ids) {
                long lo = 0, hi = nrec - 1;
                while (lo <= hi) {
                    long mid = (lo + hi) >>> 1;
                    long off = idx.getLong((int) (mid * 8));
                    long got = readIdAt(data, rec, off);
                    if (got == id) { found++; break; }
                    if (got < id) lo = mid + 1; else hi = mid - 1;
                }
            }
        }
        return found;
    }

    private static long readIdAt(FileChannel data, ByteBuffer rec, long off) throws IOException {
        rec.clear();
        rec.limit(64);
        int n = data.read(rec, off);
        if (n <= 0) return Long.MIN_VALUE;
        rec.flip();
        long v = 0;
        for (int i = 0; i < rec.limit(); i++) {
            byte b = rec.get(i);
            if (b == Tsv.TAB) break;
            if (b < '0' || b > '9') return Long.MIN_VALUE;
            v = v * 10 + (b - '0');
        }
        return v;
    }

    @Override public long[] idRange() throws Exception {
        if (Files.exists(titlesRange)) {
            String[] p = new String(Files.readAllBytes(titlesRange), StandardCharsets.UTF_8).trim().split("\\s+");
            return new long[]{Long.parseLong(p[0]), Long.parseLong(p[1])};
        }
        Path src = Files.exists(titlesSorted) ? titlesSorted : titles;
        long min = Long.MAX_VALUE, max = Long.MIN_VALUE;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(src))) {
            int n;
            while ((n = r.next()) >= 0) {
                int tab = indexOf(r.line(), n, Tsv.TAB);
                if (tab <= 0) continue;
                long id = parseLong(r.line(), tab);
                if (id < min) min = id;
                if (id > max) max = id;
            }
        }
        return new long[]{min, max};
    }

    // ---------------------------------------------------------------- update --
    /**
     * Streaming rewrite into a fresh file, then an atomic rename.
     *
     * A correct in-place rewrite is impossible here: "T" -> "Ttt" makes every
     * touched record 2 bytes longer per affected field, so the whole file has to
     * be rewritten. That is a fact about the data, not about the implementation,
     * and it is the honest cost of updating a variable-length flat file.
     */
    @Override public long rewriteNames() throws Exception {
        if (allowCorruption) return rewriteNamesNaive();
        Path tmp = people.resolveSibling(people.getFileName() + ".tmp");
        long changed = 0, bytesIn = 0, bytesOut = 0;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(people));
             BufferedOutputStream out = new BufferedOutputStream(
                     Files.newOutputStream(tmp, StandardOpenOption.CREATE,
                             StandardOpenOption.TRUNCATE_EXISTING), 1 << 20)) {
            int n;
            while ((n = r.next()) >= 0) {
                byte[] line = r.line();
                bytesIn += n + 1;
                if (!Tsv.containsT(line, n)) {                 // untouched records: byte copy
                    out.write(line, 0, n);
                    out.write('\n');
                    bytesOut += n + 1;
                    continue;
                }
                String s = new String(line, 0, n, StandardCharsets.UTF_8);
                String[] f = Tsv.split(s, 3);
                f[1] = Semantics.rewriteT(f[1]);
                f[2] = Semantics.rewriteT(f[2]);
                byte[] rb = (f[0] + '\t' + f[1] + '\t' + f[2]).getBytes(StandardCharsets.UTF_8);
                out.write(rb);
                out.write('\n');
                bytesOut += rb.length + 1;
                changed++;
            }
        }
        if (fsync) {
            try (FileChannel ch = FileChannel.open(tmp, StandardOpenOption.READ)) { ch.force(true); }
        }
        Files.move(tmp, people, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        lastUpdateBytes = new long[]{bytesIn, bytesOut, changed};
        return changed;
    }

    /**
     * What a programmer who assumes "these fields are fixed width" writes.
     * It overwrites in place, so the longer replacement spills into the next
     * record. Nothing detects it; the file is simply wrong afterwards.
     * Requires --allow-corruption because it destroys the input.
     */
    private long rewriteNamesNaive() throws IOException {
        long changed = 0;
        try (RandomAccessFile raf = new RandomAccessFile(people.toFile(), "rw")) {
            long pos = 0, len = raf.length();
            byte[] buf = new byte[4096];
            while (pos < len) {
                raf.seek(pos);
                int n = 0, b;
                while ((b = raf.read()) >= 0 && b != '\n') {
                    if (n == buf.length) buf = Arrays.copyOf(buf, buf.length * 2);
                    buf[n++] = (byte) b;
                }
                if (n == 0 && b < 0) break;
                boolean need = false;
                for (int i = 0; i < n; i++) if (buf[i] == 'T') { need = true; break; }
                if (need) {
                    String s = new String(buf, 0, n, StandardCharsets.UTF_8);
                    String[] f = Tsv.split(s, 3);
                    if (Semantics.needsRewrite(f[1]) || Semantics.needsRewrite(f[2])) {
                        f[1] = Semantics.rewriteT(f[1]);
                        f[2] = Semantics.rewriteT(f[2]);
                        byte[] rb = (f[0] + '\t' + f[1] + '\t' + f[2]).getBytes(StandardCharsets.UTF_8);
                        raf.seek(pos);
                        raf.write(rb);                    // <- runs past the record boundary
                        changed++;
                    }
                }
                pos += n + 1;                             // <- and we keep counting as if it didn't
            }
        }
        return changed;
    }

    private long[] lastUpdateBytes = new long[]{0, 0, 0};

    public long[] lastUpdateBytes() { return lastUpdateBytes; }

    // ----------------------------------------------------------- concurrency --
    @Override public long counterIncr() throws Exception {
        long cur = counterRead();
        long v = (cur < 0 ? 0 : cur) + 1;
        writeCounterAtomically(v);
        return v;
    }

    /**
     * Read the counter.
     *
     * Returns -1 when the file content is no longer a number. That is not a bug
     * in this reader: under concurrent read-modify-write the file genuinely does
     * become unparseable, because two writers can both extend it. The count of
     * such reads is reported as evidence, which is far more informative than
     * letting a NumberFormatException abort the experiment.
     */
    @Override public long counterRead() throws Exception {
        if (!Files.exists(counter)) return 0;
        String s = new String(Files.readAllBytes(counter), StandardCharsets.UTF_8).trim();
        if (s.isEmpty()) return 0;
        for (int i = 0; i < s.length(); i++) {
            if (s.charAt(i) < '0' || s.charAt(i) > '9') { corruptReads.incrementAndGet(); return -1; }
        }
        return Long.parseLong(s);
    }

    public long corruptReads() { return corruptReads.get(); }

    private final java.util.concurrent.atomic.AtomicLong corruptReads =
            new java.util.concurrent.atomic.AtomicLong();

    @Override public void resetCounter(long v) throws Exception { writeCounterAtomically(v); }

    private void writeCounterAtomically(long v) throws IOException {
        try (FileChannel ch = FileChannel.open(counter, StandardOpenOption.CREATE,
                StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)) {
            ByteBuffer b = ByteBuffer.wrap((v + "\n").getBytes(StandardCharsets.UTF_8));
            ch.write(b);
            if (fsync) ch.force(true);      // the flag that makes this comparable to COMMIT
        }
    }

    // -------------------------------------------------------------- sizes ----
    @Override public long[] relationSizes() throws Exception {
        long data = Files.exists(people) ? Files.size(people) : 0;
        long idx = Files.exists(titlesIdx) ? Files.size(titlesIdx) : 0;
        return new long[]{data, idx};
    }

    public long titlesBytes() throws IOException {
        return Files.exists(titles) ? Files.size(titles) : 0;
    }

    // --------------------------------------------------------------- join ----
    @Override public long joinCount(String keyword) throws Exception {
        Path dir = people.getParent();
        Path movies = dir.resolve("film_movies.tsv");
        Path credits = dir.resolve("film_credits.tsv");
        if (!Files.exists(movies) || !Files.exists(credits))
            throw new IllegalStateException("film_movies.tsv / film_credits.tsv missing");

        // credits fit in memory at this scale (46,850 rows); the choice that
        // matters is whether we scan them per movie (nested loop) or index them.
        long[] cMovie = new long[50000];
        int nc = 0;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(credits))) {
            int n;
            while ((n = r.next()) >= 0) {
                int t1 = indexOf(r.line(), n, Tsv.TAB);
                if (t1 <= 0) continue;
                if (nc == cMovie.length) cMovie = Arrays.copyOf(cMovie, nc * 2);
                cMovie[nc++] = parseLong(r.line(), t1);
            }
        }
        final long[] cArr = Arrays.copyOf(cMovie, nc);

        if (joinImpl == Impl.HASH) {
            HashMap<Long, int[]> byMovie = new HashMap<>(1 << 16);
            // build an index movieid -> range is not possible without a sort; use counts per movie
            HashMap<Long, Integer> counts = new HashMap<>(1 << 16);
            for (long m : cArr) counts.merge(m, 1, Integer::sum);
            long total = 0;
            try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(movies))) {
                int n;
                while ((n = r.next()) >= 0) {
                    int tab = indexOf(r.line(), n, Tsv.TAB);
                    if (tab <= 0) continue;
                    String title = new String(r.line(), tab + 1, n - tab - 1, StandardCharsets.UTF_8);
                    if (!Semantics.titleMatches(title, keyword)) continue;
                    long id = parseLong(r.line(), tab);
                    Integer c = counts.get(id);
                    if (c != null) total += c;
                }
            }
            return total;
        }

        // nested loop: for every matching movie, walk the whole credits array
        long total = 0;
        try (Tsv.LineReader r = new Tsv.LineReader(Files.newInputStream(movies))) {
            int n;
            while ((n = r.next()) >= 0) {
                int tab = indexOf(r.line(), n, Tsv.TAB);
                if (tab <= 0) continue;
                String title = new String(r.line(), tab + 1, n - tab - 1, StandardCharsets.UTF_8);
                if (!Semantics.titleMatches(title, keyword)) continue;
                long id = parseLong(r.line(), tab);
                for (long m : cArr) if (m == id) total++;
            }
        }
        return total;
    }

    // ------------------------------------------------------------- helpers ---
    private static int indexOf(byte[] a, int len, byte v) {
        for (int i = 0; i < len; i++) if (a[i] == v) return i;
        return -1;
    }

    private static int indexOfFrom(byte[] a, int len, byte[] needle, int from) {
        int n = needle.length;
        outer:
        for (int i = from, last = len - n; i <= last; i++) {
            for (int j = 0; j < n; j++) if (a[i + j] != needle[j]) continue outer;
            return i;
        }
        return -1;
    }

    private static long parseLong(byte[] a, int len) {
        long v = 0;
        for (int i = 0; i < len; i++) {
            byte b = a[i];
            if (b < '0' || b > '9') break;
            v = v * 10 + (b - '0');
        }
        return v;
    }

    @Override public void close() {}
}
