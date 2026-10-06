package bench;

/** Everything the harness can ask a backend to do. */
public interface Backend extends AutoCloseable {

    /** "pg" | "og" | "file" */
    String engine();

    /** Short description of the physical design in use, e.g. "heap+btree", "seqscan", "sorted+idx". */
    String impl();

    // ---- retrieval -------------------------------------------------------
    /** Number of titles containing the keyword (Semantics.titleMatches). */
    long titlesContaining(String keyword) throws Exception;

    /** One single-row lookup per id; returns how many were found. */
    long pointLookups(long[] ids) throws Exception;

    /** Inclusive id range present in the data. */
    long[] idRange() throws Exception;

    // ---- update ----------------------------------------------------------
    /** Row-by-row T -> Ttt rewrite; returns the number of rows actually changed. */
    long rewriteNames() throws Exception;

    // ---- concurrency / durability ---------------------------------------
    /** One increment of bench_counter / counter.txt. */
    long counterIncr() throws Exception;

    long counterRead() throws Exception;

    void resetCounter(long v) throws Exception;

    /** {data bytes, index bytes} on disk for the main relation. */
    long[] relationSizes() throws Exception;

    // ---- optional --------------------------------------------------------
    /** NULL for the file backend; SQL backends return EXPLAIN (ANALYZE, BUFFERS) text. */
    default String explain(String mode, String param) throws Exception { return null; }

    /** Only meaningful for the join mode; SQL and file both implement it. */
    default long joinCount(String keyword) throws Exception {
        throw new UnsupportedOperationException("join not implemented for " + engine());
    }

    @Override default void close() throws Exception {}
}
