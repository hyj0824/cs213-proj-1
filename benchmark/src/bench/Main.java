package bench;

import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * Experiment driver.
 *
 * One process = one (backend, mode, parameter) combination. Warm-up runs are
 * discarded, then REPS measurements are taken and every one of them is written
 * to the raw CSV -- the median and IQR are computed afterwards by
 * analysis/analyze.py, never here. Single-run numbers are not measurements.
 *
 * The destructive modes (update, counter) take a --restore-cmd that is executed
 * between repetitions, so each repetition really does start from the same state.
 */
public final class Main {

    interface Op { long run() throws Exception; }

    public static void main(String[] args) throws Exception {
        Map<String, String> a = parse(args);
        String backendName = arg(a, "--backend", "file");
        String mode        = arg(a, "--mode", "scan");
        String scale       = arg(a, "--scale", System.getenv().getOrDefault("SCALE", "1"));
        String group       = arg(a, "--group", "");
        String runId       = arg(a, "--run-id", String.valueOf(System.currentTimeMillis() / 1000));
        int reps           = Integer.parseInt(arg(a, "--reps", "7"));
        int warmup         = Integer.parseInt(arg(a, "--warmup", "2"));
        Path outFile       = resolve(arg(a, "--out", "out/raw.csv"));
        Path explainDir    = a.containsKey("--explain") ? resolve(a.get("--explain")) : null;
        String restoreCmd  = a.get("--restore-cmd");
        // --pre-rep-cmd runs before EVERY repetition including the first.
        // --restore-cmd is for destructive modes, where repetition 0 already
        // starts from pristine state; a cache control command cannot assume that,
        // because the previous case just warmed the cache.
        String preRepCmd   = a.get("--pre-rep-cmd");

        if ("update".equals(mode) || "counter".equals(mode)) warmup = 0;   // destructive

        Backend b = open(backendName, a);
        System.out.printf("# %s / %s / impl=%s / scale=%s / reps=%d warmup=%d%n",
                backendName, mode, b.impl(), scale, reps, warmup);

        long[] ids = null;
        String param;
        switch (mode) {
            case "scan":   param = arg(a, "--keyword", "man"); Semantics.validateKeyword(param); break;
            case "point":  param = "n=" + arg(a, "--ids", "2000"); break;   // replaced below with the real count
            case "join":   param = arg(a, "--keyword", "man"); Semantics.validateKeyword(param); break;
            case "update": param = "T->Ttt"; break;
            case "counter":param = "threads=" + arg(a, "--threads", "8") + "x" + arg(a, "--iters", "500"); break;
            case "size":   param = "measured"; break;
            default: throw new IllegalArgumentException("unknown --mode " + mode);
        }

        if ("point".equals(mode)) {
            int n = Integer.parseInt(arg(a, "--ids", "2000"));
            long seed = Long.parseLong(arg(a, "--seed", "20261006"));
            Path idFile = resolve(arg(a, "--data", "data")).resolve("titles_active.ids");
            if (Files.exists(idFile)) {
                List<Long> pool = new ArrayList<>();
                for (String line : Files.readAllLines(idFile)) {
                    line = line.trim();
                    if (!line.isEmpty()) pool.add(Long.parseLong(line));
                }
                ids = sampleDistinct(pool, n, seed);
                System.out.printf("# ids: %d sampled from %d known-existing ids in %s%n",
                        ids.length, pool.size(), idFile.getFileName());
                // report the batch size that actually ran, so a pool smaller than
                // the requested count cannot masquerade as the requested count
                param = "n=" + ids.length;
            } else {
                long[] range = b.idRange();
                ids = randomIds(range[0], range[1], n, seed);
                System.out.println("# ids: WARNING uniform over [" + range[0] + "," + range[1]
                        + "] -- sparse id spaces make most of these miss; "
                        + "run scripts/33_export_files.sh to produce titles_active.ids");
            }
        }

        long[] results = new long[reps];
        long[] latencies = new long[reps];

        if ("counter".equals(mode)) {
            int threads = Integer.parseInt(arg(a, "--threads", "8"));
            int iters   = Integer.parseInt(arg(a, "--iters", "500"));
            long expected = (long) threads * iters;
            try (RawCsv csv = new RawCsv(outFile)) {
                for (int r = 0; r < reps; r++) {
                    b.resetCounter(0);   // every repetition starts from the same state
                    long t0 = System.nanoTime();
                    runConcurrent(b, threads, iters);
                    long t1 = System.nanoTime();
                    long v = b.counterRead();
                    results[r] = v;
                    latencies[r] = t1 - t0;
                    boolean ok = (v == expected);
                    String extra = "";
                    if (b instanceof FileBackend) {
                        long bad = ((FileBackend) b).corruptReads();
                        extra = " unparseable_reads=" + bad
                              + (bad > 0 ? " (file corrupted by concurrent writers)" : "");
                    }
                    csv.row(runId, group, b.engine(), b.impl(), mode, param, scale, r,
                            latencies[r], v, ok,
                            "expected=" + expected + " lost=" + (expected - v)
                          + " threads=" + threads + extra);
                    System.out.printf("  rep %d: %.3f s  final=%d expected=%d  %s%n",
                            r, latencies[r] / 1e9, v, expected, ok ? "ok" : "LOST UPDATES");
                }
                csv.flush();
                System.out.printf("== %s counter %s: median %.3f s  survived %d/%d (%.1f%%)  n=%d%n",
                        b.engine(), param, Stats.median(latencies) / 1e9,
                        results[0], expected, 100.0 * results[0] / expected, reps);
            }
            b.close();
            return;
        }

        try (RawCsv csv = new RawCsv(outFile)) {
            String note = "";
            if (explainDir != null) {
                String ex = b.explain(mode, param);
                if (ex != null) {
                    Files.createDirectories(explainDir);
                    // the group is part of the name because a cold phase and a
                    // warm phase run the same case, and without it the second
                    // capture silently overwrites the first -- which is exactly
                    // how the cold plans ended up being warm plans
                    Path f = explainDir.resolve(sanitize(b.engine() + "_" + b.impl() + "_" + mode + "_"
                            + param + "_s" + scale + "_" + group + ".txt"));
                    Files.write(f, ex.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    long[] buf = SqlBackend.parseBuffers(ex);
                    if (buf[0] >= 0 || buf[1] >= 0) {
                        long pages = Math.max(0, buf[0]) + Math.max(0, buf[1]);
                        note = "shared_hit=" + buf[0] + " shared_read=" + buf[1]
                             + " bytes_touched=" + (pages * 8192);
                    }
                    System.out.println("  explain -> " + f);
                }
            }

            Op op = makeOp(b, mode, param, ids, a);

            for (int i = 0; i < warmup; i++) op.run();

            for (int r = 0; r < reps; r++) {
                String cmd = preRepCmd != null ? preRepCmd : (r > 0 ? restoreCmd : null);
                if (cmd != null) {
                    ProcessBuilder pb = new ProcessBuilder("bash", "-lc", cmd);
                    // the harness runs from benchmark/, but these commands are
                    // written relative to the project root
                    String root = System.getenv("BENCH_ROOT");
                    if (root != null) pb.directory(new java.io.File(root));
                    pb.inheritIO();
                    int rc = pb.start().waitFor();
                    if (rc != 0) throw new IllegalStateException("pre-repetition command failed: " + cmd);
                }
                long t0 = System.nanoTime();
                long v = op.run();
                long t1 = System.nanoTime();
                latencies[r] = t1 - t0;
                results[r] = v;
                boolean consistent = true;
                for (int j = 0; j < r; j++) if (results[j] != v) consistent = false;
                csv.row(runId, group, b.engine(), b.impl(), mode, param, scale, r, latencies[r], v,
                        consistent, note + extraNote(b, mode));
                System.out.printf("  rep %d: %s ms   result=%d%n", r, Stats.ms(latencies[r]), v);
            }
            csv.flush();

            boolean allSame = true;
            for (long v : results) if (v != results[0]) allSame = false;
            System.out.printf("== %s %s %s: median %s ms  (IQR %s ms, min %s, max %s)  n=%d  result=%d  consistent=%s%n",
                    b.engine(), mode, param,
                    Stats.ms(Stats.median(latencies)), Stats.ms(Stats.iqr(latencies)),
                    Stats.ms(Stats.min(latencies)), Stats.ms(Stats.max(latencies)), reps, results[0], allSame);
            if (mode.equals("update")) {
                long heap = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();
                System.out.printf("== heap in use after run: %.1f MiB%n", heap / 1048576.0);
            }
        }
        b.close();
    }

    private static String extraNote(Backend b, String mode) {
        if (b instanceof FileBackend && "update".equals(mode)) {
            long[] u = ((FileBackend) b).lastUpdateBytes();
            return "bytes_in=" + u[0] + " bytes_out=" + u[1] + " rows_changed=" + u[2]
                 + " write_amplification=" + (u[0] == 0 ? "0" : String.format(LocaleRoot(), "%.3f", u[1] * 1.0 / u[0]));
        }
        return "";
    }

    private static java.util.Locale LocaleRoot() { return java.util.Locale.ROOT; }

    private static Op makeOp(Backend b, String mode, String param, long[] ids, Map<String, String> a) {
        switch (mode) {
            case "scan":   return () -> b.titlesContaining(param);
            case "point":  return () -> b.pointLookups(ids);
            case "update": return () -> b.rewriteNames();
            case "join":   return () -> b.joinCount(param);
            case "size":   return () -> { long[] s = b.relationSizes(); return s[0]; };
            default: throw new IllegalArgumentException("unknown mode " + mode);
        }
    }

    private static void runConcurrent(Backend b, int threads, int iters) throws Exception {
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done  = new CountDownLatch(threads);
        final Exception[] err = new Exception[threads];
        for (int t = 0; t < threads; t++) {
            final int me = t;
            new Thread(() -> {
                try {
                    start.await();
                    for (int i = 0; i < iters; i++) b.counterIncr();
                } catch (Exception e) {
                    err[me] = e;
                } finally {
                    done.countDown();
                }
            }).start();
        }
        start.countDown();
        done.await();
        for (Exception e : err) if (e != null) throw e;
    }

    /**
     * Distinct random ids.
     *
     * Distinctness is a correctness requirement, not tidiness: the file backend
     * answers a batch of point lookups with one scan and a set membership test,
     * so a repeated id would be counted once by the file and twice by the DBMS
     * and the two sides would stop being comparable.
     */
    static long[] randomIds(long min, long max, int n, long seed) {
        Random rnd = new Random(seed);
        long span = Math.max(1, max - min + 1);
        if (n > span) n = (int) span;
        LinkedHashSet<Long> seen = new LinkedHashSet<>(n * 2);
        while (seen.size() < n) seen.add(min + Math.floorMod(rnd.nextLong(), span));
        long[] out = new long[n];
        int i = 0;
        for (long v : seen) out[i++] = v;
        return out;
    }

    /** Distinct ids drawn from a pool of ids that are known to exist. */
    static long[] sampleDistinct(List<Long> pool, int n, long seed) {
        if (pool.isEmpty()) return new long[0];
        if (n > pool.size()) n = pool.size();
        List<Long> copy = new ArrayList<>(pool);
        Collections.shuffle(copy, new Random(seed));
        long[] out = new long[n];
        for (int i = 0; i < n; i++) out[i] = copy.get(i);
        Arrays.sort(out);
        return out;
    }

    private static Backend open(String name, Map<String, String> a) throws Exception {
        if ("file".equals(name)) {
            String im = a.getOrDefault("--file-impl", "seq");
            FileBackend.Impl join = "hash".equals(im) ? FileBackend.Impl.HASH : FileBackend.Impl.SEQ;
            return new FileBackend(Paths.get(a.getOrDefault("--data", "data")),
                    "idx".equals(im) ? "idx" : "seq",
                    a.containsKey("--file-fsync"),
                    a.containsKey("--allow-corruption"),
                    join);
        }
        String url  = a.getOrDefault("--jdbc", "jdbc:postgresql://127.0.0.1:5432/bench");
        String user = a.getOrDefault("--user", "bench");
        String pass = a.getOrDefault("--pass", "bench");
        int par = Integer.parseInt(a.getOrDefault("--parallel", "-1"));
        return new SqlBackend(name, url, user, pass,
                a.getOrDefault("--titles-table", "bench_titles_active"),
                a.getOrDefault("--people-table", "bench_people_active"), par);
    }

    private static String arg(Map<String, String> a, String k, String dflt) {
        return a.getOrDefault(k, dflt);
    }

    static Map<String, String> parse(String[] args) {
        Map<String, String> m = new LinkedHashMap<>();
        for (int i = 0; i < args.length; i++) {
            String k = args[i];
            if (!k.startsWith("--")) continue;
            if (i + 1 < args.length && !args[i + 1].startsWith("--")) m.put(k, args[++i]);
            else m.put(k, "true");
        }
        return m;
    }

    /** Relative paths are resolved against the project root, not the JVM's cwd. */
    private static Path resolve(String p) {
        Path path = Paths.get(p);
        String root = System.getenv("BENCH_ROOT");
        if (root != null && !path.isAbsolute()) return Paths.get(root).resolve(path);
        return path;
    }

    private static String sanitize(String s) {
        return s.replaceAll("[^A-Za-z0-9._=-]", "_");
    }
}
