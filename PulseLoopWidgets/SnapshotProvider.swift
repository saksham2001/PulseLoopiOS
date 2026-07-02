import WidgetKit
import Foundation

// Timeline plumbing for all three widgets. The app owns data freshness (it snapshots after each ring
// sync and reloads the timelines), so providers just decode the shared JSON synchronously and emit
// two entries: now, and one just past midnight so stale "today" numbers roll over to an honest empty
// state even if the app never wakes overnight. `.atEnd` re-requests after the midnight entry.

// MARK: - Snapshot loading

enum WidgetSnapshotLoader {
    static func load() -> WidgetSnapshot? {
        guard let url = PulseWidgetStore.fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Plausible demo data for `placeholder(in:)` and the widget gallery, so the picker never shows
    /// an empty card before the app has published a real snapshot.
    static let sample: WidgetSnapshot = {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)

        let activity = WidgetActivityPayload(
            steps: 6841, stepsGoal: 8000,
            distanceDisplay: 4.92, distanceGoalDisplay: 6.0, distanceUnitLabel: "KM",
            calories: 388, caloriesGoal: 520,
            stepsText: "6,841", distanceText: "4.92", caloriesText: "388"
        )

        let sleep = WidgetSleepPayload(
            durationText: "7h 23m", score: 82,
            segments: [
                .init(minutes: 78, colorHex: "#3F2DD8", label: "DEEP"),
                .init(minutes: 246, colorHex: "#7C5CFF", label: "LIGHT"),
                .init(minutes: 92, colorHex: "#2DD4D8", label: "REM"),
                .init(minutes: 27, colorHex: "#FFB86B", label: "AWK"),
            ]
        )

        // A calm resting-HR day curve (dips overnight, climbs through the day).
        let hrValues: [Double] = [62, 58, 55, 54, 56, 61, 72, 78, 74, 81, 88, 76,
                                  71, 74, 83, 91, 79, 73, 76, 84, 72, 66, 63, 60]
        let hrSamples = hrValues.enumerated().map { index, value in
            WidgetSamplePayload(t: now.addingTimeInterval(Double(index - 23) * 3600), v: value)
        }
        let heartRate = WidgetMetricPayload(
            kind: "heartRate", title: "Heart rate",
            valueText: "54–91", unitText: "bpm range",
            statusText: "Typical", statusColorHex: "#FF4D6D", isEmpty: false,
            samples: hrSamples, yLower: 40, yUpper: 140,
            referenceBands: [WidgetBandPayload(lower: 60, upper: 100, colorToken: "accent:heartRate", opacity: 0.08)],
            dashedRules: [], thresholds: [50, 60, 100, 120],
            intervalColorHexes: ["#4DA3FF", "#4DA3FF", "#FF4D6D", "#FFB86B", "#FF1744"],
            zones: [], systolic: nil, diastolic: nil, systolicZones: [], diastolicZones: []
        )

        let stress = WidgetMetricPayload(
            kind: "stress", title: "Stress",
            valueText: "34", unitText: nil,
            statusText: "Normal", statusColorHex: "#4DDCFF", isEmpty: false,
            samples: [], yLower: 0, yUpper: 100,
            referenceBands: [], dashedRules: [], thresholds: [30, 60, 80],
            intervalColorHexes: ["#35E0A1", "#4DDCFF", "#FFB86B", "#FF4D6D"],
            zones: [
                WidgetZonePayload(id: "relaxed", label: "Relaxed", lower: nil, upper: 30, severityRaw: 0, colorToken: "mint"),
                WidgetZonePayload(id: "normal", label: "Normal", lower: 30, upper: 60, severityRaw: 1, colorToken: "cyan"),
                WidgetZonePayload(id: "medium", label: "Medium", lower: 60, upper: 80, severityRaw: 2, colorToken: "amber"),
                WidgetZonePayload(id: "high", label: "High", lower: 80, upper: nil, severityRaw: 3, colorToken: "red"),
            ],
            systolic: nil, diastolic: nil, systolicZones: [], diastolicZones: []
        )

        return WidgetSnapshot(
            generatedAt: now, dayStart: dayStart,
            activity: activity, sleep: sleep,
            metrics: ["heartRate": heartRate, "stress": stress]
        )
    }()
}

// MARK: - Entry

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var single: WidgetMetric = .activity
    var left: WidgetMetric = .activity
    var right: WidgetMetric = .heartRate

    /// True once this entry's day has moved past the snapshot's — activity/sleep then show the
    /// "new day, nothing synced yet" state instead of yesterday's numbers.
    var rolledOver: Bool {
        guard let snapshot else { return false }
        return Calendar.current.startOfDay(for: date) > snapshot.dayStart
    }
}

// MARK: - Timeline assembly

enum WidgetTimelineFactory {
    /// [now, just past next midnight]; both carry the same snapshot — the views compare each entry's
    /// date against `snapshot.dayStart` to decide whether "today's" data still applies.
    static func timeline(_ entry: (Date) -> SnapshotEntry) -> Timeline<SnapshotEntry> {
        let now = Date()
        var entries = [entry(now)]
        let dayStart = Calendar.current.startOfDay(for: now)
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) {
            entries.append(entry(midnight.addingTimeInterval(5)))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

// MARK: - Providers

/// The fixed full-width activity widget (no user configuration).
struct ActivitySnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshotLoader.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = WidgetSnapshotLoader.load() ?? (context.isPreview ? WidgetSnapshotLoader.sample : nil)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshotLoader.load()
        completion(WidgetTimelineFactory.timeline { SnapshotEntry(date: $0, snapshot: snapshot) })
    }
}

/// The configurable half-width widget (one metric).
struct SingleMetricProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshotLoader.sample)
    }

    func snapshot(for configuration: SingleMetricConfigIntent, in context: Context) async -> SnapshotEntry {
        let snapshot = WidgetSnapshotLoader.load() ?? (context.isPreview ? WidgetSnapshotLoader.sample : nil)
        return SnapshotEntry(date: Date(), snapshot: snapshot, single: configuration.metric)
    }

    func timeline(for configuration: SingleMetricConfigIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        let snapshot = WidgetSnapshotLoader.load()
        return WidgetTimelineFactory.timeline {
            SnapshotEntry(date: $0, snapshot: snapshot, single: configuration.metric)
        }
    }
}

/// The configurable full-width widget (left + right metrics).
struct DualMetricProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshotLoader.sample)
    }

    func snapshot(for configuration: DualMetricConfigIntent, in context: Context) async -> SnapshotEntry {
        let snapshot = WidgetSnapshotLoader.load() ?? (context.isPreview ? WidgetSnapshotLoader.sample : nil)
        return SnapshotEntry(date: Date(), snapshot: snapshot, left: configuration.left, right: configuration.right)
    }

    func timeline(for configuration: DualMetricConfigIntent, in context: Context) async -> Timeline<SnapshotEntry> {
        let snapshot = WidgetSnapshotLoader.load()
        return WidgetTimelineFactory.timeline {
            SnapshotEntry(date: $0, snapshot: snapshot, left: configuration.left, right: configuration.right)
        }
    }
}
