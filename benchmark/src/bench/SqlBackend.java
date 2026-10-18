package bench;

import java.sql.*;
import java.util.Locale;

/** PostgreSQL / openGauss backend. Same code for both: they speak the same protocol. */
public final class SqlBackend implements Backend {

    private final Connection c;
    private final String engine;
    private final String titlesTable, peopleTable;
    private final int parallel;

    public SqlBackend(String engine, String jdbcUrl, String user, String pass,
                      String titlesTable, String peopleTable, int parallel) throws Exception {
        this.engine = engine;
        this.titlesTable = titlesTable;
        this.peopleTable = peopleTable;
        this.parallel = parallel;

        // opengauss-jdbc ships org.postgresql.Driver too (it is a pgjdbc fork),
        // so the class name alone does not identify the driver -- the code
        // source printed below does.
        if ("pg".equals(engine)) {
            Class.forName("org.postgresql.Driver");
        } else {
            try { Class.forName("org.opengauss.Driver"); }
            catch (ClassNotFoundException e) { Class.forName("org.postgresql.Driver"); }
        }
        this.c = DriverManager.getConnection(jdbcUrl, user, pass);
        this.c.setAutoCommit(true);
        // Record the client stack: "which driver" belongs in the report next to
        // "which engine version", because it is part of the measurement apparatus.
        try {
            java.sql.Driver d = DriverManager.getDriver(jdbcUrl);
            String src = "unknown";
            try {
                java.security.CodeSource cs = d.getClass().getProtectionDomain().getCodeSource();
                if (cs != null) src = new java.io.File(cs.getLocation().toURI()).getName();
            } catch (Exception ignore) { }
            System.out.printf("# driver: %s (JDBC %d.%d) from %s%n",
                    d.getClass().getName(), d.getMajorVersion(), d.getMinorVersion(), src);
        } catch (SQLException ignore) { }
        try (Statement s = c.createStatement()) {
            // Each SET is independent: `SET jit` is PostgreSQL-only and throws
            // on openGauss, and a single try/catch around all of them would
            // silently skip the settings below it (including query_dop).
            try { s.execute("SET jit = off"); } catch (SQLException ignore) { }
            try { s.execute("SET synchronous_commit = on"); } catch (SQLException ignore) { }
            if (parallel >= 0) {
                if ("og".equals(engine)) {
                    // openGauss SMP: query_dop=1 is serial; 4 uses four threads.
                    // The lite build used here accepts this despite the published matrix.
                    try { s.execute("SET query_dop = " + Math.max(1, parallel)); }
                    catch (SQLException ignore) { }
                } else {
                    try { s.execute("SET max_parallel_workers_per_gather = " + parallel); }
                    catch (SQLException ignore) { }
                }
            }
            try { s.execute("SET statement_timeout = 0"); } catch (SQLException ignore) { }
        }
    }

    @Override public String engine() { return engine; }

    /**
     * The physical design and the parallelism actually requested, encoded so the
     * summary tables cannot be misread: "heap+default" is whatever the server is
     * configured with, "heap+parallel0" is this session pinned to one core, and
     * "heap+parallel4" is four workers. Comparing the two engines on scan cost
     * requires knowing which of these ran -- PostgreSQL 18 uses parallel workers,
     * openGauss uses SMP threads controlled by query_dop. The lite build used
     * here accepts query_dop even though the published matrix says it does not.
     */
    @Override public String impl() {
        String storage = "pg".equals(engine) ? "heap" : "astore";
        return parallel < 0 ? storage + "+default" : storage + "+parallel" + parallel;
    }

    // ---- retrieval -------------------------------------------------------
    @Override public long titlesContaining(String keyword) throws Exception {
        String sql = "SELECT count(*) FROM " + titlesTable + " WHERE title LIKE ?";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, "%" + keyword + "%");
            try (ResultSet rs = ps.executeQuery()) { rs.next(); return rs.getLong(1); }
        }
    }

    @Override public long pointLookups(long[] ids) throws Exception {
        String sql = "SELECT id FROM " + titlesTable + " WHERE id = ?";
        long found = 0;
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            for (long id : ids) {
                ps.setLong(1, id);
                try (ResultSet rs = ps.executeQuery()) { if (rs.next()) found++; }
            }
        }
        return found;
    }

    @Override public long[] idRange() throws Exception {
        try (Statement s = c.createStatement();
             ResultSet rs = s.executeQuery("SELECT min(id), max(id) FROM " + titlesTable)) {
            rs.next();
            return new long[]{rs.getLong(1), rs.getLong(2)};
        }
    }

    // ---- update ----------------------------------------------------------
    @Override public long rewriteNames() throws Exception {
        String sql = "UPDATE " + peopleTable + " SET " + Semantics.UPDATE_ASSIGN
                   + " WHERE " + Semantics.UPDATE_PREDICATE;
        long t0 = System.nanoTime();
        try (Statement s = c.createStatement()) { int n = s.executeUpdate(sql); return n; }
    }

    // ---- concurrency -----------------------------------------------------
    @Override public long counterIncr() throws Exception {
        try (Statement s = c.createStatement()) {
            return s.executeUpdate("UPDATE bench_counter SET v = v + 1 WHERE id = 0");
        }
    }

    @Override public long counterRead() throws Exception {
        try (Statement s = c.createStatement();
             ResultSet rs = s.executeQuery("SELECT v FROM bench_counter WHERE id = 0")) {
            rs.next(); return rs.getLong(1);
        }
    }

    @Override public void resetCounter(long v) throws Exception {
        try (Statement s = c.createStatement()) {
            s.executeUpdate("UPDATE bench_counter SET v = " + v + " WHERE id = 0");
        }
    }

    // ---- accounting ------------------------------------------------------
    @Override public long[] relationSizes() throws Exception {
        String q = "SELECT pg_relation_size(?), pg_indexes_size(?)";
        try (PreparedStatement ps = c.prepareStatement(q)) {
            ps.setString(1, peopleTable); ps.setString(2, peopleTable);
            try (ResultSet rs = ps.executeQuery()) { rs.next(); return new long[]{rs.getLong(1), rs.getLong(2)}; }
        } catch (SQLException e) {
            try (PreparedStatement ps = c.prepareStatement("SELECT pg_relation_size(?), 0")) {
                ps.setString(1, titlesTable);
                try (ResultSet rs = ps.executeQuery()) { rs.next(); return new long[]{rs.getLong(1), rs.getLong(2)}; }
            }
        }
    }

    /** Live/dead tuple census -- this is the evidence for the write-amplification claim. */
    public long deadTuples(String table) throws Exception {
        try (Statement s = c.createStatement();
             ResultSet rs = s.executeQuery(
                 "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname = '" + table + "'")) {
            return rs.next() ? rs.getLong(1) : -1;
        }
    }

    @Override public long joinCount(String keyword) throws Exception {
        String sql =
            "SELECT count(*) FROM film.movies m JOIN film.credits cr ON cr.movieid = m.movieid "
          + "WHERE m.title LIKE ?";
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            ps.setString(1, "%" + keyword + "%");
            try (ResultSet rs = ps.executeQuery()) { rs.next(); return rs.getLong(1); }
        }
    }

    // ---- explain ---------------------------------------------------------
    @Override public String explain(String mode, String param) throws Exception {
        String sql;
        if ("scan".equals(mode))
            sql = "SELECT count(*) FROM " + titlesTable + " WHERE title LIKE '%" + param + "%'";
        else if ("point".equals(mode))
            // use an id that certainly exists, so the plan shown is the one the
            // benchmark actually exercises
            sql = "SELECT id FROM " + titlesTable + " WHERE id = (SELECT min(id)+1 FROM " + titlesTable + ")";
        else if ("update".equals(mode))
            sql = "UPDATE " + peopleTable + " SET " + Semantics.UPDATE_ASSIGN
                + " WHERE " + Semantics.UPDATE_PREDICATE;
        else if ("join".equals(mode))
            sql = "SELECT count(*) FROM film.movies m JOIN film.credits cr ON cr.movieid = m.movieid "
                + "WHERE m.title LIKE '%" + param + "%'";
        else
            sql = null;
        if (sql == null) return null;
        StringBuilder sb = new StringBuilder();
        try (Statement s = c.createStatement()) {
            s.setFetchSize(1);
            try (ResultSet rs = s.executeQuery("EXPLAIN (ANALYZE, BUFFERS) " + sql)) {
                while (rs.next()) sb.append(rs.getString(1)).append('\n');
            }
        } catch (SQLException e) {
            return "EXPLAIN failed: " + e.getMessage() + '\n';
        }
        return sb.toString();
    }

    /** "Buffers: shared hit=12 read=3456" -> {hit, read}. */
    public static long[] parseBuffers(String explainText) {
        long hit = -1, read = -1;
        if (explainText == null) return new long[]{-1, -1};
        String t = explainText.toLowerCase(Locale.ROOT);
        int i = t.indexOf("shared hit=");
        if (i >= 0) hit = leadingNumber(t, i + "shared hit=".length());
        i = t.indexOf(" read=");
        if (i >= 0) read = leadingNumber(t, i + " read=".length());
        return new long[]{hit, read};
    }

    private static long leadingNumber(String s, int from) {
        int i = from;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        if (i == from) return -1;
        return Long.parseLong(s.substring(from, i));
    }

    @Override public void close() throws Exception { c.close(); }
}
