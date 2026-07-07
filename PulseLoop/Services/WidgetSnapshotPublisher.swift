import SwiftUI
import SwiftData
import WidgetKit

/// Publishes the home-screen-widget snapshot: projects the same prepared tile state the Today page
/// renders (`MetricsService.buildTodaySummary` + `VitalsCardFactory` cards) into the Codable
/// `WidgetSnapshot`, writes it atomically into the app-group container, and reloads the widget
/// timelines. Retained for the app's lifetime by `PulseLoopApp` (like `DiagnosticsSubscriber`).
///
/// Refresh discipline: data only changes when the app syncs with the ring, so publishing rides the
/// coalesced `PulseDataChange` signal (debounced — a history sync bumps it once per batch, but several
/// batches can land in quick succession) plus the scene-phase edges (catches goal/unit/visibility
/// edits made in Settings, which don't bump the sync token). Timeline reloads while the app is in the
/// foreground don't count against the WidgetKit refresh budget; reloads from background BLE syncs do,
/// so those are throttled to one per 20 minutes.
@MainActor
final class WidgetSnapshotPublisher {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    enum Reason { case dataChange, scenePhase }

    private let modelContext: ModelContext
    private var debounceTask: Task<Void, Never>?
    /// Hash of the last snapshot's content (excluding `generatedAt`), so an unchanged rebuild skips
    /// the file write and — more importantly — the budget-limited timeline reload.
    private var lastContentHash: Int?

    private static let debounceSeconds: Double = 2
    private static let backgroundReloadMinInterval: TimeInterval = 20 * 60
    /// Chart payloads carry at most this many points — plenty for a 56 pt-tall axis-less widget
    /// chart, and it keeps the snapshot file small enough to decode in the extension instantly.
    private static let maxChartPoints = 48

    init(context: ModelContext) {
        self.modelContext = context
    }

    func start() {
        observeDataChange()
        publish(reason: .scenePhase)   // seed the container so widgets work before the first sync
    }

    /// `withObservationTracking` is one-shot: re-arm after every fire, then debounce the publish so
    /// one burst of persistence batches produces one snapshot.
    private func observeDataChange() {
        withObservationTracking {
            _ = PulseDataChange.shared.token
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDataChange()
                self.debounceTask?.cancel()
                self.debounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.debounceSeconds))
                    guard !Task.isCancelled else { return }
                    self?.publish(reason: .dataChange)
                }
            }
        }
    }

    func publish(reason: Reason) {
        guard let url = PulseWidgetStore.fileURL else { return }
        var snapshot = buildSnapshot()

        // Content comparison with a fixed timestamp: an unchanged snapshot skips write + reload
        // (keeping the honest "as of" time of the data it still shows).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let stamp = snapshot.generatedAt
        snapshot.generatedAt = .distantPast
        guard let comparable = try? encoder.encode(snapshot) else { return }
        let hash = comparable.hashValue
        guard hash != lastContentHash else { return }
        snapshot.generatedAt = stamp

        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        lastContentHash = hash
        reloadTimelines(reason: reason)
    }

    /// Foreground reloads are free; background data-change reloads (BLE sync while suspended) are
    /// throttled so a chatty ring can't burn the ~40–70/day system refresh budget.
    private func reloadTimelines(reason: Reason) {
        let foreground = UIApplication.shared.applicationState != .background
        if reason == .dataChange && !foreground {
            let defaults = UserDefaults(suiteName: PulseWidgetStore.suite)
            if let last = defaults?.object(forKey: PulseWidgetStore.lastBackgroundReloadKey) as? Date,
               Date().timeIntervalSince(last) < Self.backgroundReloadMinInterval {
                return
            }
            defaults?.set(Date(), forKey: PulseWidgetStore.lastBackgroundReloadKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Snapshot assembly

    /// Mirrors `TodayStore.rebuildCards()` — same summary, same series fetches, same factory, same
    /// physiology/calibration inputs — so a widget tile is pixel- and label-identical to its Today
    /// tile at publish time.
    private func buildSnapshot() -> WidgetSnapshot {
        let summary = MetricsService.buildTodaySummary(context: modelContext, scope: .today)
        let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first
        let physiology = UserPhysiologyProfile(profile)
        let calibration = CalibrationStore.shared.settings
        let units = profile?.units ?? .metric

        func series(_ metric: MetricKey) -> [MetricSample] {
            MetricsService.metricRange(metric: metric, range: .twentyFourHours, context: modelContext, scope: .today)
        }
        let hrv = series(.hrv)
        let systolic = series(.bloodPressureSystolic)
        let diastolic = series(.bloodPressureDiastolic)
        let inputs = VitalsCardFactory.Inputs(
            hr: series(.heartRate), spo2: series(.spo2), hrv: hrv,
            stress: series(.stress), fatigue: series(.fatigue), temperature: series(.temperature),
            systolic: systolic, diastolic: diastolic, glucose: series(.bloodSugar),
            summary: summary, range: .twentyFourHours
        )

        var metrics: [String: WidgetMetricPayload] = [:]
        for metric in MetricKind.allCases {
            let model = VitalsCardFactory.card(metric, inputs: inputs, profile: physiology, calibration: calibration)
            // TodayChartTile colors with a baseline only for HRV (mirrored here).
            let baseline = metric == .hrv ? BaselineStats.compute(hrv) : nil
            var payload = metricPayload(model, physiology: physiology, baseline: baseline)
            if metric == .bloodPressure {
                payload.systolic = systolic.last?.value
                payload.diastolic = diastolic.last?.value
                payload.systolicZones = VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology)
                    .map(WidgetZonePayload.init)
                payload.diastolicZones = VitalsThresholdEngine.diastolicReferenceZones()
                    .map(WidgetZonePayload.init)
            }
            metrics[metric.rawValue] = payload
        }

        return WidgetSnapshot(
            generatedAt: Date(),
            dayStart: Calendar.current.startOfDay(for: Date()),
            activity: activityPayload(summary, units: units),
            sleep: sleepPayload(summary.sleep),
            metrics: metrics
        )
    }

    /// Replicates `ActivityTileView`'s value derivations (unit conversion, formatting, calorie gate).
    private func activityPayload(_ summary: TodaySummary, units: UnitsPreference) -> WidgetActivityPayload {
        let caloriesAvailable = MetricsService.isVisible(.calories, context: modelContext, scope: .today)
        let calories = caloriesAvailable ? summary.calories : nil
        let distanceText = summary.distanceMeters.map { UnitsFormatter.distance(meters: $0, units: units).value }
        return WidgetActivityPayload(
            steps: summary.steps.map(Double.init),
            stepsGoal: Double(summary.goals.stepsDaily),
            distanceDisplay: distanceText.flatMap(Double.init),
            distanceGoalDisplay: Double(UnitsFormatter.distance(meters: summary.goals.distanceMetersDaily, units: units).value) ?? 0,
            distanceUnitLabel: units == .imperial ? "MI" : "KM",
            calories: calories,
            caloriesGoal: Double(summary.goals.caloriesDaily),
            stepsText: summary.steps.map { $0.formatted() },
            distanceText: distanceText,
            caloriesText: calories.map { Int($0).formatted() }
        )
    }

    /// Replicates `SleepTileView`'s derivations (stage distribution, score, duration formatting).
    private func sleepPayload(_ sleep: SleepSummary?) -> WidgetSleepPayload? {
        guard let sleep else { return nil }
        let stages = SleepStageDistribution(sleep)
        return WidgetSleepPayload(
            durationText: SleepFormat.duration(sleep.session.totalMinutes),
            score: SleepScore.calculate(sleep).score,
            segments: stages.segments.map {
                WidgetSleepPayload.Segment(minutes: $0.minutes, colorHex: Self.hexString($0.color), label: $0.label)
            }
        )
    }

    private func metricPayload(_ model: VitalCardViewModel,
                               physiology: UserPhysiologyProfile,
                               baseline: BaselineStats?) -> WidgetMetricPayload {
        // Bake the threshold engine's value→color step function in: the sorted zone boundaries plus
        // the resolved color of each interval between them (evaluated at an interior point — the
        // engine's color is constant within an interval).
        let thresholds = VitalsThresholdEngine.zoneThresholds(for: model.metric, profile: physiology, baseline: baseline)
        var intervalColors: [String] = []
        for index in 0...thresholds.count {
            let representative: Double
            if thresholds.isEmpty {
                representative = model.samples.last?.value ?? model.yDomain.lowerBound
            } else if index == 0 {
                representative = thresholds[0] - 1
            } else if index == thresholds.count {
                representative = thresholds[index - 1] + 1
            } else {
                representative = (thresholds[index - 1] + thresholds[index]) / 2
            }
            let token = VitalsThresholdEngine.colorToken(
                forValue: representative, metric: model.metric, profile: physiology, baseline: baseline
            )
            intervalColors.append(Self.hexString(token.color))
        }

        let downsampled = MetricDownsampler.bucketAverage(
            model.samples.map { MetricSample(timestamp: $0.timestamp, value: $0.value) },
            targetBuckets: Self.maxChartPoints
        )

        return WidgetMetricPayload(
            kind: model.metric.rawValue,
            title: model.title,
            valueText: model.valueText,
            unitText: model.unitText,
            statusText: model.statusText,
            statusColorHex: Self.hexString(model.statusColor),
            isEmpty: model.isEmpty,
            samples: downsampled.map { WidgetSamplePayload(t: $0.timestamp, v: $0.value) },
            yLower: model.yDomain.lowerBound,
            yUpper: model.yDomain.upperBound,
            referenceBands: model.referenceBands.map(WidgetBandPayload.init),
            dashedRules: model.dashedRules,
            thresholds: thresholds,
            intervalColorHexes: intervalColors,
            zones: model.zones.map(WidgetZonePayload.init),
            systolic: nil, diastolic: nil, systolicZones: [], diastolicZones: []
        )
    }

    /// Resolve a SwiftUI `Color` to a hex string (8-digit when translucent) the widget rebuilds via
    /// the shared `Color(hex:)`. All crossing colors originate from `PulseColors` hex values (sRGB),
    /// so the round trip is lossless.
    private static func hexString(_ color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#FFFFFF" }
        func byte(_ c: CGFloat) -> Int { Int((max(0, min(1, c)) * 255).rounded()) }
        if a < 0.999 {
            return String(format: "#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
        }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
