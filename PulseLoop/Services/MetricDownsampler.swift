import Foundation

/// Display-only downsampling for vitals charts. High measurement frequency produces hundreds of points
/// that make a chart noisy; bucket-averaging collapses them into a smoother line. This operates purely
/// on the `[MetricSample]` value array returned to the UI — it never touches stored `Measurement` rows.
enum MetricDownsampler {
    /// Bucket-average `samples` into at most `targetBuckets` equal **time** buckets across the data's
    /// [min, max] timestamp span. Each non-empty bucket emits one sample at its midpoint with the mean
    /// value. Time-bucketing (not index-bucketing) keeps irregularly-sampled data honest.
    ///
    /// Returns the input unchanged when `targetBuckets <= 0` (the "Full" resolution) or when there are
    /// already no more points than buckets.
    static func bucketAverage(_ samples: [MetricSample], targetBuckets: Int) -> [MetricSample] {
        guard targetBuckets > 0, samples.count > targetBuckets else { return samples }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let start = sorted.first?.timestamp,
              let end = sorted.last?.timestamp else { return samples }

        let span = end.timeIntervalSince(start)
        // All points share a timestamp — averaging into one is the only honest reduction.
        guard span > 0 else {
            let mean = sorted.reduce(0) { $0 + $1.value } / Double(sorted.count)
            return [MetricSample(timestamp: start, value: mean)]
        }

        let bucketWidth = span / Double(targetBuckets)

        var sums = [Double](repeating: 0, count: targetBuckets)
        var counts = [Int](repeating: 0, count: targetBuckets)
        for sample in sorted {
            let offset = sample.timestamp.timeIntervalSince(start)
            // Clamp the final point (offset == span) into the last bucket.
            let index = min(targetBuckets - 1, Int(offset / bucketWidth))
            sums[index] += sample.value
            counts[index] += 1
        }

        var result: [MetricSample] = []
        result.reserveCapacity(targetBuckets)
        for i in 0..<targetBuckets where counts[i] > 0 {
            let midpoint = start.addingTimeInterval((Double(i) + 0.5) * bucketWidth)
            result.append(MetricSample(timestamp: midpoint, value: sums[i] / Double(counts[i])))
        }
        return result
    }
}
