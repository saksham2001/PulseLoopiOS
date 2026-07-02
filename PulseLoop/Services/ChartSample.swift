import Foundation

/// A charting sample carrying enough context to render honestly: a real timestamp (so spacing
/// reflects time, not array index) and a source-quality flag (so low-confidence stretches can be
/// styled differently). Built from the store's `[MetricSample]` at view-model time.
struct ChartSample: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let value: Double
    let quality: SourceQuality

    init(id: UUID = UUID(), timestamp: Date, value: Double, quality: SourceQuality = .good) {
        self.id = id
        self.timestamp = timestamp
        self.value = value
        self.quality = quality
    }
}

enum ChartSampleBuilder {
    /// Map stored samples to chart samples, tagging each with a single resolved quality. Samples are
    /// assumed already time-sorted by `metricRange`; we sort defensively anyway.
    static func from(_ samples: [MetricSample], quality: SourceQuality = .good) -> [ChartSample] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChartSample(timestamp: $0.timestamp, value: $0.value, quality: quality) }
    }

    /// Split a series into contiguous segments, breaking wherever the gap between adjacent samples
    /// exceeds `maxGap`. This prevents a line from drawing a false bridge across hours with no data
    /// (e.g. connecting a 2 AM reading straight to a 10 PM reading). Pure and order-preserving.
    static func segments(_ samples: [ChartSample], maxGap: TimeInterval) -> [[ChartSample]] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return [[first]] }

        var result: [[ChartSample]] = []
        var current: [ChartSample] = [first]
        for (a, b) in zip(samples, samples.dropFirst()) {
            if b.timestamp.timeIntervalSince(a.timestamp) > maxGap {
                result.append(current)
                current = [b]
            } else {
                current.append(b)
            }
        }
        result.append(current)
        return result
    }

    /// The maximum allowed gap before a line breaks, tuned per range so denser windows break sooner.
    /// 24h → 90 min, 7d → 36 h, 30d → 4 days, 12mo → ~45 days.
    static func maxGap(for range: MetricRange) -> TimeInterval {
        switch range {
        case .twentyFourHours: return 90 * 60
        case .sevenDays: return 36 * 3600
        case .thirtyDays: return 4 * 86_400
        case .twelveMonths: return 45 * 86_400
        }
    }
}

/// A point on the chart in value space (time + value), used by the threshold-splitting math so it
/// stays pure and unit-testable independent of SwiftUI/Charts geometry.
struct LinePoint: Equatable {
    let time: Date
    let value: Double
}

/// A point in pure value space: `x` is any linear coordinate (a timestamp's `timeIntervalSince1970`,
/// or minutes-elapsed for activity charts). Keeps the splitting math independent of Date/geometry.
struct ValuePoint: Equatable {
    let x: Double
    let value: Double
}

enum ZoneLineSplitter {
    /// Split the segment between `a` and `b` at every threshold strictly between their values, so each
    /// returned piece lies entirely within one zone. Crossing points are linearly interpolated in both
    /// time and value. A pair within a single zone returns one piece `[a, b]`. Endpoints are preserved
    /// exactly. `thresholds` should be sorted ascending (zone boundaries).
    static func split(_ a: LinePoint, _ b: LinePoint, thresholds: [Double]) -> [(LinePoint, LinePoint)] {
        // Delegate to the value-space core using the timestamps as the x coordinate.
        let pieces = split(x0: a.time.timeIntervalSince1970, v0: a.value,
                           x1: b.time.timeIntervalSince1970, v1: b.value, thresholds: thresholds)
        return pieces.map { start, end in
            (LinePoint(time: Date(timeIntervalSince1970: start.x), value: start.value),
             LinePoint(time: Date(timeIntervalSince1970: end.x), value: end.value))
        }
    }

    /// Value-space core: split the segment `(x0,v0)→(x1,v1)` at every threshold strictly between the
    /// values. `x` can be any linear coordinate (elapsed minutes, seconds, epoch). Pure + testable.
    static func split(x0: Double, v0: Double, x1: Double, v1: Double,
                      thresholds: [Double]) -> [(ValuePoint, ValuePoint)] {
        let a = ValuePoint(x: x0, value: v0)
        let b = ValuePoint(x: x1, value: v1)
        let lo = min(v0, v1)
        let hi = max(v0, v1)
        let crossings = thresholds
            .filter { $0 > lo && $0 < hi }
            .sorted { v0 <= v1 ? $0 < $1 : $0 > $1 }

        guard !crossings.isEmpty, v0 != v1 else { return [(a, b)] }

        var pieces: [(ValuePoint, ValuePoint)] = []
        var current = a
        for threshold in crossings {
            let point = interpolate(a, b, atValue: threshold)
            pieces.append((current, point))
            current = point
        }
        pieces.append((current, b))
        return pieces
    }

    /// The point on segment a→b where the value equals `target` (assumes target is between the values).
    private static func interpolate(_ a: ValuePoint, _ b: ValuePoint, atValue target: Double) -> ValuePoint {
        let span = b.value - a.value
        guard span != 0 else { return a }
        let t = (target - a.value) / span               // 0…1 along a→b
        return ValuePoint(x: a.x + (b.x - a.x) * t, value: target)
    }
}
