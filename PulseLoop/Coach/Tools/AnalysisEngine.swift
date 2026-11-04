import Foundation

/// Deterministic Swift analysis over numeric series — the iOS replacement for
/// the web app's `run_health_analysis_code` Python sandbox. Covers the common
/// health-coach questions (trend, period comparison, correlation, outliers,
/// distribution) without arbitrary code execution.
enum AnalysisEngine {
    struct TrendResult: Encodable {
        var count: Int
        var direction: String       // "rising" | "falling" | "flat"
        var slopePerDay: Double
        var first: Double?
        var last: Double?
        var changeAbsolute: Double?
        var changePercent: Double?
        var average: Double?
    }

    struct ComparisonResult: Encodable {
        var aAverage: Double?
        var bAverage: Double?
        var aCount: Int
        var bCount: Int
        var deltaAbsolute: Double?
        var deltaPercent: Double?
        var direction: String
    }

    struct CorrelationResult: Encodable {
        var pairs: Int
        var pearson: Double?
        var strength: String        // "strong" | "moderate" | "weak" | "none"
        var note: String
    }

    struct Outlier: Encodable {
        var date: String
        var value: Double
        var zScore: Double
    }

    struct DistributionResult: Encodable {
        var count: Int
        var mean: Double?
        var median: Double?
        var min: Double?
        var max: Double?
        var stddev: Double?
        var p25: Double?
        var p75: Double?
    }

    // MARK: - Trend

    static func trend(_ series: [(date: Date, value: Double)]) -> TrendResult {
        let values = series.map(\.value)
        guard values.count >= 2 else {
            return TrendResult(count: values.count, direction: "flat", slopePerDay: 0,
                               first: values.first, last: values.last, changeAbsolute: 0,
                               changePercent: nil, average: values.first)
        }
        // Linear regression slope using day offsets from the first sample.
        let day0 = series[0].date.timeIntervalSince1970
        let xs = series.map { ($0.date.timeIntervalSince1970 - day0) / 86_400 }
        let n = Double(values.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = values.reduce(0, +) / n
        let cov = zip(xs, values).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let varX = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        let slope = varX == 0 ? 0 : cov / varX
        let first = values.first!, last = values.last!
        let change = last - first
        let pct = first == 0 ? nil : (change / abs(first) * 100).rounded(toPlaces: 1)
        let direction = abs(slope) < 0.0001 ? "flat" : (slope > 0 ? "rising" : "falling")
        return TrendResult(
            count: values.count, direction: direction, slopePerDay: slope.rounded(toPlaces: 3),
            first: first, last: last, changeAbsolute: change.rounded(toPlaces: 2),
            changePercent: pct, average: meanY.rounded(toPlaces: 2)
        )
    }

    // MARK: - Period comparison

    static func comparePeriods(a: [Double], b: [Double]) -> ComparisonResult {
        let aAvg = a.isEmpty ? nil : (a.reduce(0, +) / Double(a.count)).rounded(toPlaces: 2)
        let bAvg = b.isEmpty ? nil : (b.reduce(0, +) / Double(b.count)).rounded(toPlaces: 2)
        var delta: Double?
        var pct: Double?
        var direction = "flat"
        if let aAvg, let bAvg {
            delta = (bAvg - aAvg).rounded(toPlaces: 2)
            pct = aAvg == 0 ? nil : ((bAvg - aAvg) / abs(aAvg) * 100).rounded(toPlaces: 1)
            direction = abs(bAvg - aAvg) < 0.0001 ? "flat" : (bAvg > aAvg ? "up" : "down")
        }
        return ComparisonResult(aAverage: aAvg, bAverage: bAvg, aCount: a.count, bCount: b.count,
                                deltaAbsolute: delta, deltaPercent: pct, direction: direction)
    }

    // MARK: - Correlation (paired by day)

    static func correlation(_ pairs: [(Double, Double)]) -> CorrelationResult {
        guard pairs.count >= 3 else {
            return CorrelationResult(pairs: pairs.count, pearson: nil, strength: "none",
                                     note: "Need at least 3 overlapping days to correlate.")
        }
        let xs = pairs.map(\.0), ys = pairs.map(\.1)
        let n = Double(pairs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sx = sqrt(xs.reduce(0) { $0 + pow($1 - mx, 2) })
        let sy = sqrt(ys.reduce(0) { $0 + pow($1 - my, 2) })
        guard sx > 0, sy > 0 else {
            return CorrelationResult(pairs: pairs.count, pearson: nil, strength: "none",
                                     note: "One series has no variation.")
        }
        let r = (cov / (sx * sy)).rounded(toPlaces: 3)
        let mag = abs(r)
        let strength = mag >= 0.6 ? "strong" : (mag >= 0.3 ? "moderate" : (mag >= 0.1 ? "weak" : "none"))
        return CorrelationResult(pairs: pairs.count, pearson: r, strength: strength,
                                 note: "Correlation is not causation; small sample.")
    }

    // MARK: - Outliers (z-score)

    static func outliers(
        _ series: [(date: Date, value: Double)], threshold: Double = 2.0
    ) -> [Outlier] {
        let values = series.map(\.value)
        guard values.count >= 4 else { return [] }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let sd = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / n)
        guard sd > 0 else { return [] }
        let f = DateFormatter.stableKey("yyyy-MM-dd")
        return series.compactMap { item in
            let z = (item.value - mean) / sd
            guard abs(z) >= threshold else { return nil }
            return Outlier(date: f.string(from: item.date), value: item.value, zScore: z.rounded(toPlaces: 2))
        }
    }

    // MARK: - Distribution

    static func distribution(_ values: [Double]) -> DistributionResult {
        guard !values.isEmpty else {
            return DistributionResult(count: 0, mean: nil, median: nil, min: nil, max: nil,
                                      stddev: nil, p25: nil, p75: nil)
        }
        let sorted = values.sorted()
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let sd = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / n)
        return DistributionResult(
            count: values.count,
            mean: mean.rounded(toPlaces: 2),
            median: percentile(sorted, 0.5).rounded(toPlaces: 2),
            min: sorted.first, max: sorted.last,
            stddev: sd.rounded(toPlaces: 2),
            p25: percentile(sorted, 0.25).rounded(toPlaces: 2),
            p75: percentile(sorted, 0.75).rounded(toPlaces: 2)
        )
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}
