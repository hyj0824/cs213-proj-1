package bench;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Instant;
import java.util.Locale;

/** Append-only raw result log. One row per measurement; nothing is summarised here. */
public final class RawCsv implements Closeable {

    public static final String HEADER =
            "ts,run_id,group,backend,impl,mode,param,scale,rep,latency_ns,result,ok,note";

    private final BufferedWriter w;

    public RawCsv(Path file) throws IOException {
        Files.createDirectories(file.toAbsolutePath().getParent());
        boolean fresh = !Files.exists(file) || Files.size(file) == 0;
        w = Files.newBufferedWriter(file, StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        if (fresh) { w.write(HEADER); w.newLine(); }
    }

    public void row(String runId, String group, String backend, String impl, String mode,
                    String param, String scale, int rep, long latencyNs, long result,
                    boolean ok, String note) throws IOException {
        StringBuilder sb = new StringBuilder(160);
        sb.append(Instant.now()).append(',')
          .append(esc(runId)).append(',').append(esc(group)).append(',')
          .append(esc(backend)).append(',').append(esc(impl)).append(',')
          .append(esc(mode)).append(',').append(esc(param)).append(',')
          .append(esc(scale)).append(',').append(rep).append(',')
          .append(latencyNs).append(',').append(result).append(',')
          .append(ok ? 1 : 0).append(',').append(esc(note));
        w.write(sb.toString());
        w.newLine();
    }

    public void flush() throws IOException { w.flush(); }

    private static String esc(String s) {
        if (s == null) return "";
        if (s.indexOf(',') < 0 && s.indexOf('"') < 0 && s.indexOf('\n') < 0) return s;
        return '"' + s.replace("\"", "\"\"") + '"';
    }

    public static String num(double d) { return String.format(Locale.ROOT, "%.3f", d); }

    @Override public void close() throws IOException { w.close(); }
}
