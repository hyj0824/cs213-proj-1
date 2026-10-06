package bench;

/**
 * The single source of truth for what each experiment MEANS.
 *
 * Every backend must implement exactly these operations. If the SQL side and
 * the file side ever disagree about semantics, the whole comparison is
 * meaningless -- so the definitions live here, are quoted verbatim in the
 * report, and are checked by the cross-backend consistency report produced by
 * analysis/analyze.py.
 */
public final class Semantics {

    private Semantics() {}

    /**
     * Retrieval: does the title contain the keyword, case sensitively, as a
     * plain substring? SQL side: {@code title LIKE '%kw%'}.
     *
     * The harness refuses keywords outside [A-Za-z0-9 ], because LIKE's
     * metacharacters % and _ would make the two sides answer different
     * questions (LIKE also treats the backslash as an escape character).
     */
    public static boolean titleMatches(String title, String keyword) {
        return title != null && title.contains(keyword);
    }

    /**
     * Update: every uppercase ASCII 'T' becomes "Ttt".
     * SQL side: {@code replace(x, 'T', 'Ttt')}.
     *
     * Note this GROWS the record, which is the interesting part: it defeats
     * fixed-width in-place rewriting and is the worst case for an append-only
     * heap.
     */
    public static String rewriteT(String s) {
        if (s == null || s.indexOf('T') < 0) return s;
        return s.replace("T", "Ttt");
    }

    public static boolean needsRewrite(String s) {
        return s != null && s.indexOf('T') >= 0;
    }

    /** The predicate and the set expression used by the SQL backends. */
    public static final String UPDATE_PREDICATE =
            "(coalesce(first_name,'') LIKE '%T%' OR coalesce(surname,'') LIKE '%T%')";

    public static final String UPDATE_ASSIGN =
            "first_name = replace(first_name,'T','Ttt'), surname = replace(surname,'T','Ttt')";

    /** Rejects a keyword that would mean different things in LIKE and indexOf. */
    public static void validateKeyword(String kw) {
        if (kw == null || kw.isEmpty())
            throw new IllegalArgumentException("--keyword must not be empty");
        for (int i = 0; i < kw.length(); i++) {
            char c = kw.charAt(i);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                      || (c >= '0' && c <= '9') || c == ' ';
            if (!ok)
                throw new IllegalArgumentException(
                    "keyword '" + kw + "' contains '" + c + "', which LIKE treats specially. "
                  + "The experiment is only well defined for [A-Za-z0-9 ].");
        }
    }
}
