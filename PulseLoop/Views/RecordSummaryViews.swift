import SwiftUI
import SwiftData

// MARK: - Record summary & live-screen views

/// One heart-rate training zone: a %HRmax band with a label and palette colour.
struct HRZone: Identifiable {
    let id: Int        // 1...5
    let name: String
    let color: Color
    let seconds: Double
}

/// Time spent in each of the 5 HR zones, derived from sorted HR samples. Zone boundaries are
/// 50/60/70/80/90/100 % of an estimated HRmax (`220 − age`, fallback 190). Each inter-sample
/// interval is credited to the earlier sample's zone, capped to ignore genuine dropouts — but the
/// cap ADAPTS to the session's own cadence so a sparsely-sampled (e.g. retroactively-backfilled)
/// session still accounts for its full duration instead of only ~30 s per gap.
func hrZoneDurations(samples: [MetricSample], age: Int?) -> [HRZone] {
    let hrMax = Double(age.map { 220 - $0 } ?? 190)
    let palette: [(String, Color)] = [
        ("Zone 1 · Easy", PulseColors.spo2),
        ("Zone 2 · Fat burn", PulseColors.success),
        ("Zone 3 · Aerobic", PulseColors.warning),
        ("Zone 4 · Threshold", PulseColors.calories),
        ("Zone 5 · Max", PulseColors.heartRate)
    ]
    var seconds = [Double](repeating: 0, count: 5)
    let sorted = samples.sorted { $0.timestamp < $1.timestamp }
    // Adaptive per-interval cap: credit each gap fully up to ~2× the median spacing (so normally-spaced
    // samples count their whole interval), but never more than 5 min (a real dropout stays uncredited).
    let gaps = zip(sorted, sorted.dropFirst()).map { $1.timestamp.timeIntervalSince($0.timestamp) }.filter { $0 > 0 }.sorted()
    let median = gaps.isEmpty ? 30 : gaps[gaps.count / 2]
    let cap = min(300, max(30, median * 2))
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        let dt = min(cap, b.timestamp.timeIntervalSince(a.timestamp))
        guard dt > 0 else { continue }
        let pct = a.value / hrMax
        let zone: Int
        switch pct {
        case ..<0.60: zone = 0
        case ..<0.70: zone = 1
        case ..<0.80: zone = 2
        case ..<0.90: zone = 3
        default:      zone = 4
        }
        seconds[zone] += dt
    }
    return (0..<5).map { HRZone(id: $0 + 1, name: palette[$0].0, color: palette[$0].1, seconds: seconds[$0]) }
}

// MARK: - Record: summary

struct RecordSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Query private var sessions: [ActivitySession]
    /// This session's linked samples — observed so the summary recomputes as the post-workout
    /// ring-log backfill lands (samples can keep arriving for a few seconds after finish).
    @Query private var samples: [ActivitySample]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var effort: String?
    @State private var note = ""
    /// Debounce for the backfill-driven summary refresh (samples arrive in bursts after finish).
    @State private var refreshTask: Task<Void, Never>?

    private let efforts: [(String, String)] = [("easy", "Easy"), ("moderate", "Moderate"), ("hard", "Hard"), ("very_hard", "Very hard")]

    init(sessionId: UUID, path: Binding<NavigationPath>) {
        self.sessionId = sessionId
        self._path = path
        _samples = Query(filter: #Predicate<ActivitySample> { $0.sessionId == sessionId })
    }

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            ScrollView {
                VStack(spacing: 16) {
                    if coordinator.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Updating from ring…")
                                .font(PulseFont.caption.weight(.regular))
                                .foregroundStyle(PulseColors.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Same rich body as the activity detail screen, kept in sync via the shared view.
                    WorkoutMetricsSections(session: session, savedBadge: true)

                    effortCard

                    Spacer(minLength: 8)
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(PulseColors.background)
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Done", systemImage: "checkmark") { done(session) }
                    .padding(16)
            }
            .onAppear { effort = session.perceivedEffort; note = session.notes ?? "" }
            .onChange(of: samples.count) { _, _ in
                // Late ring-log samples attached — recompute the aggregates (idempotent). The
                // backfill lands in bursts, so wait for ~1 s of quiet instead of recomputing per
                // batch flush.
                refreshTask?.cancel()
                refreshTask = Task {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    ActivityService.refreshSummary(for: session, context: modelContext)
                }
            }
            .onDisappear { refreshTask?.cancel() }
        } else {
            EmptyStateView(title: "Summary unavailable", body: "This workout could not be loaded.")
        }
    }

    private var effortCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did this feel?").font(PulseFont.callout).foregroundStyle(PulseColors.textPrimary)
            HStack(spacing: 8) {
                ForEach(efforts, id: \.0) { value, label in
                    let active = effort == value
                    Button { effort = value } label: {
                        Text(label)
                            .font(PulseFont.footnote)
                            .foregroundStyle(active ? PulseColors.textPrimary : PulseColors.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .pulseGlass(Capsule(), interactive: true, tint: active ? PulseColors.accent : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Add a note…", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .font(PulseFont.subheadline.weight(.regular))
                .padding(12)
                .pulseGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func done(_ session: ActivitySession) {
        session.perceivedEffort = effort
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        session.notes = trimmed.isEmpty ? nil : trimmed
        session.updatedAt = Date()
        try? modelContext.save()
        path.removeLast(path.count)
    }
}

// MARK: - Live screen components

/// Sensor tile with a value, optional unit, freshness subtitle, and a pulse dot while a read
/// is in progress. Used for HR (continuous-ish) and SpO₂ (every 5 min) on the live screen.
struct LiveSensorTile: View {
    let value: String
    var unit: String?
    let label: String
    let subtitle: String
    var pulsing: Bool = false
    var tint: Color = PulseColors.accent
    var muted: Bool = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if pulsing {
                    Circle().fill(tint).frame(width: 7, height: 7).opacity(pulse ? 0.3 : 1)
                }
                Text(label.uppercased()).font(PulseFont.caption2).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(PulseFont.title).monospacedDigit()
                    .foregroundStyle(muted ? PulseColors.textMuted : PulseColors.textPrimary)
                    .minimumScaleFactor(0.6).lineLimit(1)
                if let unit { Text(unit).font(PulseFont.footnote).foregroundStyle(PulseColors.textMuted) }
            }
            Text(subtitle).font(PulseFont.caption2.weight(.regular)).foregroundStyle(PulseColors.textMuted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Stretch to fill the grid cell so all tiles in a row are the same height.
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { startPulse(pulsing) }
        .onChange(of: pulsing) { _, now in startPulse(now) }
    }

    private func startPulse(_ on: Bool) {
        pulse = false
        guard on else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// Compact technical pills under the live header: GPS quality, ring link, sensor cadences.
struct WorkoutStatusStrip: View {
    let session: ActivitySession
    let ringState: RingConnectionState
    let gpsAccuracy: Double?
    var plan: WorkoutVitalsPlan? = nil

    var body: some View {
        HStack(spacing: 6) {
            if session.useGps {
                StatusPill(icon: "location.fill", text: "GPS \(gpsLabel.0)", tint: gpsLabel.1)
            }
            StatusPill(icon: "dot.radiowaves.left.and.right", text: ringLabel.0, tint: ringLabel.1)
            StatusPill(icon: "heart.fill", text: hrPillText, tint: PulseColors.textMuted)
            StatusPill(icon: "drop.fill", text: spo2PillText, tint: PulseColors.textMuted)
        }
    }

    /// Honest capture cadence: reflect the actual plan (stream vs spot interval) instead of a
    /// hard-coded "1m".
    private var hrPillText: String {
        switch plan?.hrMode {
        case .stream:
            return "HR live"
        case .spotPoll:
            let minutes = max(1, WorkoutPrefsStore.shared.settings.hrPollIntervalSeconds / 60)
            return "HR \(minutes)m"
        case .off:
            return "HR off"
        case nil:
            return "HR —"
        }
    }

    private var spo2PillText: String {
        switch plan?.spo2Mode {
        case .spotPoll:
            let minutes = max(1, WorkoutPrefsStore.shared.settings.spo2PollIntervalSeconds / 60)
            return "SpO₂ \(minutes)m"
        case .ringLog:
            return "SpO₂ log"
        case .off:
            return "SpO₂ off"
        case nil:
            return "SpO₂ —"
        }
    }

    private var gpsLabel: (String, Color) {
        guard let a = gpsAccuracy else { return ("Lost", PulseColors.danger) }
        return a <= 10 ? ("Good", PulseColors.success) : ("Weak", PulseColors.warning)
    }

    /// Ring pill: green when linked, amber while (re)connecting, red when dropped — so the user sees
    /// the workout is handling a disconnect rather than silently stalling.
    private var ringLabel: (String, Color) {
        switch ringState {
        case .connected:                  return ("Ring on", PulseColors.success)
        case .reconnecting, .connecting:  return ("Reconnecting…", PulseColors.warning)
        case .disconnected, .failed:      return ("Ring lost", PulseColors.danger)
        case .scanning:                   return ("Searching…", PulseColors.warning)
        case .idle:                       return ("Ring off", PulseColors.textMuted)
        }
    }
}

struct StatusPill: View {
    let icon: String
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(PulseFont.nano.weight(.regular))
            Text(text).font(PulseFont.micro)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .pulseGlass(Capsule())
    }
}

/// Per-kilometre splits for distance activities (last / best / current km pace). Takes the
/// already-maintained `Splits` (incremental during recording) instead of recomputing from points.
struct SplitStrip: View {
    let splits: RouteDistanceEngine.Splits
    var units: UnitsPreference = .metric

    private var splitMeters: Double { units == .imperial ? 1609.344 : 1000 }
    private var splitWord: String { units == .imperial ? "mi" : "km" }

    var body: some View {
        let labels = kmSplits()
        HStack(spacing: 12) {
            WorkoutStat(label: "Last \(splitWord)", value: labels.last ?? "—")
            WorkoutStat(label: "Best \(splitWord)", value: labels.best ?? "—")
            WorkoutStat(label: "This \(splitWord)", value: labels.current ?? "—")
        }
    }

    private func kmSplits() -> (last: String?, best: String?, current: String?) {
        let completed = splits.completedSeconds
        let currentPace = splits.partialMeters >= 50 && splits.partialSeconds > 0
            ? splits.partialSeconds / (splits.partialMeters / splitMeters) : nil
        return (paceString(completed.last), paceString(completed.min()), paceString(currentPace))
    }

    private func paceString(_ secPerUnit: Double?) -> String? {
        guard let secPerUnit, secPerUnit > 0 else { return nil }
        // Round to whole seconds before splitting so :60 carries the minute.
        let total = Int(secPerUnit.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Post-workout transparency about how well the (reverse-engineered) ring + GPS performed.
struct RecordingQualityCard: View {
    @Environment(\.modelContext) private var modelContext
    let session: ActivitySession

    var body: some View {
        let rows = qualityRows()
        VStack(alignment: .leading, spacing: 12) {
            Text("RECORDING QUALITY").font(PulseFont.caption2).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].0).font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
                    Spacer()
                    Text(rows[i].1).font(PulseFont.footnote.monospacedDigit()).foregroundStyle(rows[i].2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func qualityRows() -> [(String, String, Color)] {
        let samples = ActivityRepository.samples(sessionId: session.id, context: modelContext)
        let hrCount = samples.filter { $0.kind == MeasurementKind.heartRate.rawValue && $0.value > 0 }.count
        let spo2Count = samples.filter { $0.kind == MeasurementKind.spo2.rawValue && $0.value > 0 }.count
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) } ?? 0
        let streamed = session.vitalsModeRaw == "stream"
        let prefs = WorkoutPrefsStore.shared.settings
        // Healthy coverage baseline: a stream should land a sample at least every ~10s; spot polls
        // aim for one per configured HR interval; SpO₂ per its configured interval.
        let expectedHR = max(1, duration / (streamed ? 10 : max(10, prefs.hrPollIntervalSeconds)))
        let expectedSpO2 = max(1, duration / max(60, prefs.spo2PollIntervalSeconds))
        let pollFailures = session.hrPollFailureCount + session.spo2PollFailureCount

        var rows: [(String, String, Color)] = [
            ("HR capture", streamed ? "Live stream" : "Spot readings", PulseColors.textPrimary)
        ]
        if session.useGps {
            let accepted = session.gpsPointCount
            let total = accepted + session.rejectedGpsPointCount
            let coverage = total > 0 ? Int(Double(accepted) / Double(total) * 100) : 0
            rows.append(("GPS coverage", total > 0 ? "\(coverage)%" : "—", coverage >= 80 ? PulseColors.success : PulseColors.warning))
            rows.append(("Dropped GPS points", "\(session.rejectedGpsPointCount)", session.rejectedGpsPointCount == 0 ? PulseColors.textPrimary : PulseColors.warning))
            rows.append(("Distance source", session.distanceMeters != nil ? "GPS route" : "—", PulseColors.textPrimary))
        } else {
            rows.append(("Distance source", "Not tracked", PulseColors.textMuted))
        }
        rows.append(("HR samples", "\(hrCount) / \(expectedHR)", hrCount >= expectedHR ? PulseColors.success : PulseColors.warning))
        rows.append(("SpO₂ samples", "\(spo2Count) / \(expectedSpO2)", spo2Count >= expectedSpO2 ? PulseColors.success : PulseColors.warning))
        rows.append(("Sensor read failures", "\(pollFailures)", pollFailures == 0 ? PulseColors.textPrimary : PulseColors.warning))
        return rows
    }
}
