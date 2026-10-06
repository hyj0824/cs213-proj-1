package bench;

import java.util.Arrays;

/** Median / IQR. Reported instead of "the average of one run", which is not a measurement. */
public final class Stats {

    private Stats() {}

    public static double median(long[] v) { return percentile(v, 0.50); }

    public static double percentile(long[] v, double p) {
        long[] s = v.clone();
        Arrays.sort(s);
        if (s.length == 0) return Double.NaN;
        if (s.length == 1) return s[0];
        double idx = p * (s.length - 1);
        int lo = (int) Math.floor(idx), hi = (int) Math.ceil(idx);
        if (lo == hi) return s[lo];
        return s[lo] + (s[hi] - s[lo]) * (idx - lo);
    }

    public static double iqr(long[] v) { return percentile(v, 0.75) - percentile(v, 0.25); }

    public static double mean(long[] v) {
        double s = 0;
        for (long x : v) s += x;
        return s / v.length;
    }

    public static double stddev(long[] v) {
        double m = mean(v), s = 0;
        for (long x : v) s += (x - m) * (x - m);
        return Math.sqrt(s / Math.max(1, v.length - 1));
    }

    public static double min(long[] v) { return percentile(v, 0.0); }

    public static double max(long[] v) { return percentile(v, 1.0); }

    /** ms with 3 significant digits, for tables. */
    public static String ms(double ns) {
        double ms = ns / 1e6;
        if (ms >= 1000) return String.format("%.0f", ms);
        if (ms >= 100)  return String.format("%.1f", ms);
        if (ms >= 10)   return String.format("%.2f", ms);
        return String.format("%.3f", ms);
    }

    public static double cv(long[] v) {
        double m = mean(v);
        return m == 0 ? 0 : stddev(v) / m;
    }
}
