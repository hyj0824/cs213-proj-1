package bench;

import java.io.*;

/**
 * Line oriented TSV reader.
 *
 * The export format is deliberately escape-free (>TAB< separated, no embedded
 * tabs or newlines -- asserted by sql/01_guardrails.sql), so a correct reader
 * is a few lines long and cannot silently disagree with the SQL side. This is a
 * design decision, not laziness: a CSV reader that mishandles quoted commas
 * would have produced a wrong answer that looked like a performance result.
 */
public final class Tsv {

    public static final byte TAB = (byte) '\t';
    public static final byte LF = (byte) '\n';

    private Tsv() {}

    /** Splits a UTF-8 line into at most n fields on TAB. Last field keeps any TABs. */
    public static String[] split(String line, int n) {
        String[] out = new String[n];
        int from = 0;
        for (int i = 0; i < n - 1; i++) {
            int t = line.indexOf('\t', from);
            if (t < 0) { out[i] = line.substring(from); from = line.length(); }
            else       { out[i] = line.substring(from, t); from = t + 1; }
        }
        out[n - 1] = from <= line.length() ? line.substring(from) : "";
        return out;
    }

    public static long parseLong(String s) {
        long v = 0; boolean neg = false; int i = 0;
        if (s.charAt(0) == '-') { neg = true; i = 1; }
        for (; i < s.length(); i++) v = v * 10 + (s.charAt(i) - '0');
        return neg ? -v : v;
    }

    /**
     * Buffered byte reader that yields whole lines as byte arrays, so the common
     * "this record is untouched, copy it through" path never allocates a String.
     * A well-written native file program looks like this; comparing against a
     * String-per-line version would be comparing against a straw man.
     */
    public static final class LineReader implements Closeable {
        private final InputStream in;
        private final byte[] buf;
        private int pos, len;
        private byte[] line = new byte[256];

        public LineReader(InputStream in, int bufSize) {
            this.in = in instanceof BufferedInputStream ? in : new BufferedInputStream(in, bufSize);
            this.buf = new byte[Math.max(1 << 16, bufSize)];
        }

        public LineReader(InputStream in) { this(in, 1 << 20); }

        /** Writes the next line (without LF) into {@link #line}; returns length or -1. */
        public int next() throws IOException {
            int n = 0;
            boolean any = false;
            while (true) {
                if (pos >= len) {
                    len = in.read(buf);
                    pos = 0;
                    if (len <= 0) return any ? n : -1;
                }
                int start = pos;
                while (pos < len && buf[pos] != LF) pos++;
                int chunk = pos - start;
                if (chunk > 0) {
                    if (n + chunk > line.length) {
                        int cap = Math.max(line.length * 2, n + chunk);
                        byte[] bigger = new byte[cap];
                        System.arraycopy(line, 0, bigger, 0, n);
                        line = bigger;
                    }
                    System.arraycopy(buf, start, line, n, chunk);
                    n += chunk;
                }
                any = true;
                if (pos < len && buf[pos] == LF) { pos++; break; }
            }
            if (n > 0 && line[n - 1] == '\r') n--;   // tolerate CRLF
            return n;
        }

        public byte[] line() { return line; }

        @Override public void close() throws IOException { in.close(); }
    }

    /** Is the ASCII keyword present anywhere in [0,len)? */
    public static boolean contains(byte[] hay, int len, byte[] needle) {
        int n = needle.length;
        if (n == 0 || n > len) return false;
        outer:
        for (int i = 0, last = len - n; i <= last; i++) {
            for (int j = 0; j < n; j++) {
                if (hay[i + j] != needle[j]) continue outer;
            }
            return true;
        }
        return false;
    }

    /** Is 'T' present in [0,len)? */
    public static boolean containsT(byte[] hay, int len) {
        for (int i = 0; i < len; i++) if (hay[i] == 'T') return true;
        return false;
    }
}
