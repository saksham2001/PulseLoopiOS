import SwiftUI
import SwiftData

// MARK: - Shared small pieces

/// Compact 3-up stat tile used on summary/detail (mirrors web `Stat`/`StatsGrid`).
private struct WorkoutStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// Large cockpit tile for the live recording screen (mirrors web `LiveStatTile`).
private struct LiveStatTile: View {
    let value: String
    let label: String
    var muted: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(muted ? PulseColors.textMuted : PulseColors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(1.0)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Stretch to fill the grid cell so all tiles in a row are the same height.
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// HR samples for a finished session, as chart-ready points.
@MainActor
private func sessionHRSamples(_ sessionId: UUID, context: ModelContext) -> [MetricSample] {
    ActivityRepository.samples(sessionId: sessionId, context: context)
        .filter { $0.kind == MeasurementKind.heartRate.rawValue && $0.value > 0 }
        .sorted { $0.timestamp < $1.timestamp }
        .map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
}

/// SpO₂ samples for a finished session, as chart-ready points.
@MainActor
private func sessionSpO2Samples(_ sessionId: UUID, context: ModelContext) -> [MetricSample] {
    ActivityRepository.samples(sessionId: sessionId, context: context)
        .filter { $0.kind == MeasurementKind.spo2.rawValue && $0.value > 0 }
        .sorted { $0.timestamp < $1.timestamp }
        .map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
}

/// Banner shown on Activity when a workout from a previous launch was left recording/paused.
struct StaleSessionRecoveryCard: View {
    @Environment(\.modelContext) private var modelContext
    let sessions: [ActivitySession]

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PulseColors.warning)
                    Text("Unfinished workout")
                        .font(.headline)
                }
                Text("A workout was left running from an earlier session. Finish it to keep its time and distance, or discard it.")
                    .font(.caption)
                    .foregroundStyle(PulseColors.textMuted)
                ForEach(sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ActivityMeta.label(session.type))
                                .font(.subheadline.weight(.medium))
                            Text(session.startedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(PulseColors.textMuted)
                        }
                        Spacer()
                        Button("Finish") {
                            ActivityRecorderService.finish(session, context: modelContext)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.success)
                        Button("Discard") {
                            ActivityRecorderService.cancel(session, context: modelContext)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.danger)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WorkoutRow: View {
    let session: ActivitySession
    var body: some View {
        PulseCard {
            HStack {
                Image(systemName: ActivityMeta.icon(session.type))
                    .font(.title2)
                    .foregroundStyle(PulseColors.steps)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ActivityMeta.label(session.type))
                        .font(.headline)
                    Text(session.startedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(session.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(PulseColors.textSecondary)
                    if let distance = session.distanceMeters {
                        let isImperial = WorkoutAppGroup.useImperialUnits
                        let divisor = isImperial ? 1609.34 : 1000.0
                        Text(String(format: "%.2f %@", distance / divisor, isImperial ? "mi" : "km"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
    }
}

// MARK: - Detail

struct ActivityDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [ActivitySession]
    let sessionId: UUID
    @State private var confirmingDelete = false

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            ScrollView {
                VStack(spacing: 16) {
                    // Same rich body as the post-record summary, kept in sync via the shared view.
                    WorkoutMetricsSections(session: session)

                    if let notes = session.notes, !notes.isEmpty {
                        StatusCopy(title: "Notes", body: notes)
                    }
                    if let effort = session.perceivedEffort, !effort.isEmpty {
                        HStack {
                            Text("Effort").foregroundStyle(PulseColors.textMuted)
                            Text(effort.replacingOccurrences(of: "_", with: " ").capitalized)
                                .foregroundStyle(PulseColors.textPrimary)
                            Spacer()
                        }
                        .font(.system(size: 14))
                        .padding(.horizontal, 4)
                    }

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete workout", systemImage: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(PulseColors.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(PulseColors.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.danger.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(16)
                .padding(.bottom, 32)
            }
            .background(PulseColors.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(PulseColors.danger)
                }
            }
            .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete workout", role: .destructive) {
                    ActivityRecorderService.delete(session, context: modelContext)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently removes the workout and its recorded heart-rate, GPS, and sensor data. This can't be undone.")
            }
        } else {
            EmptyStateView(title: "Workout not found", body: "This session is no longer in local storage.")
        }
    }
}

// MARK: - Record: select activity

struct RecordSelectView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(LiveWorkoutManager.self) private var liveWorkout
    @Binding var path: NavigationPath
    @State private var selected = "run"
    @State private var useGps = true

    private var gpsCapable: Bool { ActivityMeta.meta(selected).gpsCapable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose activity")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(PulseColors.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(ActivityMeta.allKinds) { kind in
                        let isSelected = kind.type == selected
                        Button { selected = kind.type } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: kind.symbol)
                                    .font(.system(size: 22))
                                    .foregroundStyle(isSelected ? PulseColors.accent : PulseColors.textSecondary)
                                    .frame(width: 46, height: 46)
                                    .background(isSelected ? PulseColors.accentSoft : PulseColors.cardSoft, in: Circle())
                                Text(kind.label)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(PulseColors.textPrimary)
                                Text(kind.helper)
                                    .font(.system(size: 12))
                                    .foregroundStyle(PulseColors.textMuted)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(isSelected ? PulseColors.accentSoft : PulseColors.card)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(isSelected ? PulseColors.accent : PulseColors.borderSubtle, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle(isOn: $useGps) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use GPS route").font(.system(size: 15, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                        Text(gpsCapable ? "Track your route on a map" : "Not available for this activity")
                            .font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
                    }
                }
                .tint(PulseColors.accent)
                .disabled(!gpsCapable)
                .padding(16)
                .background(PulseColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))

                PrimaryButton(title: "Start", systemImage: "play.fill") {
                    let willUseGps = useGps && gpsCapable
                    let session = liveWorkout.start(type: selected, useGps: willUseGps)
                    path.append(AppRoute.recordLive(session.id))
                }
            }
            .padding(16)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Record: live cockpit

struct RecordLiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(RingBLEClient.self) private var ble
    @Environment(GpsRouteRecorder.self) private var gps
    @Environment(LiveWorkoutManager.self) private var liveWorkout
    @Query private var sessions: [ActivitySession]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext).filter { $0.accepted }
            let paused = session.status == .paused
            TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                let elapsedSec = elapsed(session: session, now: timeline.date)
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: ActivityMeta.icon(session.type)).foregroundStyle(PulseColors.accent)
                                Text("\(paused ? "Paused" : "Recording") \(ActivityMeta.label(session.type))")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(PulseColors.textPrimary)
                            }
                            WorkoutStatusStrip(session: session, ringState: ble.state, gpsAccuracy: latestAccuracy(points))
                        }
                        .padding(.top, 8)

                        VStack(spacing: 6) {
                            Text(ActivityMeta.duration(elapsedSec))
                                .font(.system(size: 60, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(paused ? PulseColors.textMuted : PulseColors.textPrimary)
                            Text("DURATION").font(.system(size: 11, weight: .medium)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                        }
                        .padding(.vertical, 8)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            // GPS-only tiles are hidden for indoor activities (no map/distance/pace).
                            if session.useGps {
                                LiveStatTile(value: distanceLabel(points: points, session: session), label: "Distance")
                            }
                            LiveSensorTile(
                                value: coordinator.latestHRValue.map { "\($0)" } ?? "—",
                                unit: coordinator.latestHRValue == nil ? nil : "bpm",
                                label: "Heart rate",
                                subtitle: hrSubtitle(session),
                                pulsing: coordinator.hrState == .measuring,
                                tint: PulseColors.heartRate,
                                muted: coordinator.latestHRValue == nil
                            )
                            LiveSensorTile(
                                value: coordinator.latestSpO2Value.map { "\($0)%" } ?? "—",
                                unit: nil,
                                label: "SpO₂",
                                subtitle: spo2Subtitle(session, now: timeline.date),
                                pulsing: coordinator.spo2State == .measuring,
                                tint: PulseColors.spo2,
                                muted: coordinator.latestSpO2Value == nil
                            )
                            if session.useGps {
                                LiveStatTile(value: paceLabel(points: points, elapsedSec: elapsedSec, session: session), label: "Pace")
                            }
                        }

                        if showSplits(session) {
                            SplitStrip(points: points)
                        }

                        if session.useGps {
                            ZStack {
                                WorkoutMapView(points: points, unavailable: gps.isPermissionDenied, height: 220, follow: !paused)
                                    .opacity(paused ? 0.55 : 1)
                                if paused {
                                    Text("PAUSED")
                                        .font(.system(size: 13, weight: .semibold)).tracking(2)
                                        .foregroundStyle(PulseColors.textPrimary)
                                        .padding(.horizontal, 18).padding(.vertical, 10)
                                        .background(.ultraThinMaterial, in: Capsule())
                                }
                            }

                            if gps.isPermissionDenied {
                                Text("Location access is denied — enable it in Settings to record your route.")
                                    .font(.caption).foregroundStyle(PulseColors.warning).multilineTextAlignment(.center)
                            }
                        } else if paused {
                            Text("PAUSED")
                                .font(.system(size: 13, weight: .semibold)).tracking(2)
                                .foregroundStyle(PulseColors.textPrimary)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 12)
                }
                .background(PulseColors.background)
                .onChange(of: timeline.date) { _, _ in liveWorkout.syncLiveActivity(session) }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        SecondaryButton(title: paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                            if paused { liveWorkout.resume(session) } else { liveWorkout.pause(session) }
                        }
                        PrimaryButton(title: "Finish", systemImage: "flag.checkered") { confirmFinish = true }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationBarBackButtonHidden(true)
            .onAppear { liveWorkout.ensureActive(session) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { confirmDiscard = true } label: { Image(systemName: "xmark") }
                        .tint(PulseColors.textSecondary)
                }
            }
            .confirmationDialog("Finish workout?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish") { finish(session) }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text("Your workout will be saved with its time, route, and ring measurements.")
            }
            .confirmationDialog("Discard workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { discard(session) }
                Button("Keep recording", role: .cancel) {}
            } message: {
                Text("This recording will be deleted and won't count toward your activity.")
            }
        } else {
            EmptyStateView(title: "No active workout", body: "Start a workout from Activity.")
        }
    }

    private func finish(_ session: ActivitySession) {
        liveWorkout.finish(session)
        // Replace the live screen with the summary so back/Done returns to the Activity tab,
        // not into the finished recording.
        path.removeLast(path.count)
        path.append(AppRoute.recordSummary(session.id))
    }

    private func discard(_ session: ActivitySession) {
        liveWorkout.cancel(session)
        path.removeLast(path.count)
    }

    // MARK: freshness copy

    private func hrSubtitle(_ session: ActivitySession) -> String {
        // Keep the last value on screen and never flash an error: while a reading is in progress show
        // "measuring…", otherwise the time since the last sample. Only "waiting…" before the first one.
        if coordinator.hrState == .measuring { return "measuring…" }
        guard let last = lastSampleTime(session.id, kind: "hr") else { return "waiting…" }
        return "updated \(agoLabel(last))"
    }

    private func spo2Subtitle(_ session: ActivitySession, now: Date) -> String {
        if coordinator.spo2State == .measuring { return "reading…" }
        guard let last = lastSampleTime(session.id, kind: "spo2") else { return "every 5 min" }
        let remaining = max(0, 300 - now.timeIntervalSince(last))
        return remaining > 0 ? "next in \(ActivityMeta.duration(Int(remaining)))" : "due now"
    }

    private func agoLabel(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }

    private func lastSampleTime(_ sessionId: UUID, kind: String) -> Date? {
        ActivityRepository.samples(sessionId: sessionId, context: modelContext)
            .last { $0.kind == kind && $0.value > 0 }?.timestamp
    }

    private func latestAccuracy(_ points: [ActivityGpsPoint]) -> Double? {
        points.last?.horizontalAccuracy
    }

    private func showSplits(_ session: ActivitySession) -> Bool {
        session.useGps && ["run", "walk", "cycle", "hike"].contains(session.type)
    }

    // MARK: live stats

    private func distanceLabel(points: [ActivityGpsPoint], session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        let meters = routeDistance(points)
        guard meters > 0 else { return "—" }
        let isImperial = WorkoutAppGroup.useImperialUnits
        let divisor = isImperial ? 1609.34 : 1000.0
        return String(format: "%.2f %@", meters / divisor, isImperial ? "mi" : "km")
    }

    private func paceLabel(points: [ActivityGpsPoint], elapsedSec: Int, session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        return ActivityMeta.pace(distanceMeters: routeDistance(points), durationSeconds: elapsedSec) ?? "—"
    }

    private func routeDistance(_ points: [ActivityGpsPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + haversineMeters(pair.0, pair.1)
        }
    }

    private func elapsed(session: ActivitySession, now: Date) -> Int {
        max(0, Int((session.endedAt ?? now).timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
    }
}

/// Shared haversine in meters for route points (used by live view + split strip).
func haversineMeters(_ a: ActivityGpsPoint, _ b: ActivityGpsPoint) -> Double {
    let r = 6_371_000.0
    let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
    let dPhi = (b.latitude - a.latitude) * .pi / 180
    let dLambda = (b.longitude - a.longitude) * .pi / 180
    let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
    return 2 * r * asin(min(1, sqrt(h)))
}

/// Seconds elapsed for each *completed* kilometre of a route, in order. Walks the cumulative
/// haversine distance and records the elapsed time every time distance crosses the next km mark.
/// Shared by the live `SplitStrip` and the summary `SplitsTable`.
func kmSplitSeconds(_ points: [ActivityGpsPoint]) -> [Double] {
    guard points.count >= 2, let first = points.first else { return [] }
    let isImperial = WorkoutAppGroup.useImperialUnits
    let divisor = isImperial ? 1609.34 : 1000.0
    var cumulative = 0.0
    var markTime = first.timestamp
    var nextMark = divisor
    var splits: [Double] = []
    for (a, b) in zip(points, points.dropFirst()) {
        cumulative += haversineMeters(a, b)
        while cumulative >= nextMark {
            splits.append(b.timestamp.timeIntervalSince(markTime))
            markTime = b.timestamp
            nextMark += divisor
        }
    }
    return splits
}

/// Total ascent / descent in metres over a route, ignoring sub-metre jitter. nil when there is
/// no usable altitude data.
func routeElevation(_ points: [ActivityGpsPoint]) -> (gain: Double, loss: Double)? {
    let alts = points.compactMap(\.altitude)
    guard alts.count >= 3 else { return nil }
    var gain = 0.0, loss = 0.0
    for (a, b) in zip(alts, alts.dropFirst()) {
        let delta = b - a
        if delta > 1 { gain += delta } else if delta < -1 { loss += -delta }
    }
    return (gain, loss)
}

/// One heart-rate training zone: a %HRmax band with a label and palette colour.
struct HRZone: Identifiable {
    let id: Int        // 1...5
    let name: String
    let color: Color
    let seconds: Double
}

/// Time spent in each of the 5 HR zones, derived from sorted HR samples. Zone boundaries are
/// 50/60/70/80/90/100 % of an estimated HRmax (`220 − age`, fallback 190). Each inter-sample
/// interval (capped at 30 s to ignore gaps) is credited to the earlier sample's zone.
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
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        let dt = min(30, b.timestamp.timeIntervalSince(a.timestamp))
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
    @Query private var sessions: [ActivitySession]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var effort: String?
    @State private var note = ""

    private let efforts: [(String, String)] = [("easy", "Easy"), ("moderate", "Moderate"), ("hard", "Hard"), ("very_hard", "Very hard")]

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            ScrollView {
                VStack(spacing: 16) {
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
                    .background(.ultraThinMaterial)
            }
            .onAppear { effort = session.perceivedEffort; note = session.notes ?? "" }
        } else {
            EmptyStateView(title: "Summary unavailable", body: "This workout could not be loaded.")
        }
    }

    private var effortCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did this feel?").font(.system(size: 15, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            HStack(spacing: 8) {
                ForEach(efforts, id: \.0) { value, label in
                    let active = effort == value
                    Button { effort = value } label: {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(active ? PulseColors.textPrimary : PulseColors.textSecondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(active ? PulseColors.accentSoft : PulseColors.cardSoft, in: Capsule())
                            .overlay(Capsule().stroke(active ? PulseColors.accent : PulseColors.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("Add a note…", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 14))
                .padding(12)
                .background(PulseColors.cardSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
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

// MARK: - Summary components

/// The full rich body of a finished workout — header, hero band, stat grid, map, splits, HR chart
/// + zones, SpO₂ chart, elevation profile, and the recording-quality card. Shared by the
/// post-record summary (`RecordSummaryView`) and the activity detail screen (`ActivityDetailView`)
/// so the two never drift apart. Read-only; each host supplies its own footer (editable
/// effort/notes + Done, or read-only notes + Delete).
struct WorkoutMetricsSections: View {
    @Environment(\.modelContext) private var modelContext
    let session: ActivitySession
    /// Shows the "WORKOUT SAVED" badge in the header (only meaningful right after recording).
    var savedBadge: Bool = false

    var body: some View {
        let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext)
        let accepted = points.filter { $0.accepted }.sorted { $0.timestamp < $1.timestamp }
        let hr = sessionHRSamples(session.id, context: modelContext)
        let spo2 = sessionSpO2Samples(session.id, context: modelContext)
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) }
        let elevation = session.useGps ? routeElevation(accepted) : nil
        let altitudes = accepted.compactMap(\.altitude)

        VStack(spacing: 16) {
            header

            SummaryHeroBand(session: session, durationSeconds: duration)

            statsGrid(elevationGain: elevation?.gain)

            if session.useGps {
                WorkoutMapView(points: points)
                SplitsTable(points: accepted)
            }

            if hr.count > 1 {
                chartCard(title: "HEART RATE", footnote: hrFootnote) {
                    HRLineChart(samples: hr, height: 120)
                }
                HRZonesCard(samples: hr, age: userAge)
            }

            if spo2.count > 1 {
                chartCard(title: "BLOOD OXYGEN", footnote: spo2Footnote) {
                    SpO2DotsChart(samples: spo2, height: 110)
                }
            }

            if let elevation, altitudes.count >= 3 {
                chartCard(title: "ELEVATION",
                          footnote: String(format: "↑ %.0f m   ↓ %.0f m", elevation.gain, elevation.loss)) {
                    ElevationAreaChart(altitudes: altitudes, height: 120)
                }
            }

            RecordingQualityCard(session: session)
        }
    }

    /// Age from the (single) user profile, used to estimate HRmax for the zones card.
    private var userAge: Int? {
        (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first?.age
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: ActivityMeta.icon(session.type))
                .font(.system(size: 34)).foregroundStyle(PulseColors.accent)
                .frame(width: 72, height: 72).background(PulseColors.accentSoft, in: Circle())
            if savedBadge {
                Text("WORKOUT SAVED").font(.system(size: 11, weight: .medium)).tracking(1.8).foregroundStyle(PulseColors.accent)
            }
            Text(ActivityMeta.label(session.type)).font(.system(size: 24, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
            Text(dateRange).font(.system(size: 13)).foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// e.g. "Today · 7:32 – 8:05 AM" or "May 28 · 6:10 – 6:48 PM".
    private var dateRange: String {
        let time = DateFormatter(); time.dateFormat = "h:mm"
        let timeAmPm = DateFormatter(); timeAmPm.dateFormat = "h:mm a"
        let day: String
        if Calendar.current.isDateInToday(session.startedAt) {
            day = "Today"
        } else if Calendar.current.isDateInYesterday(session.startedAt) {
            day = "Yesterday"
        } else {
            let d = DateFormatter(); d.dateFormat = "MMM d"
            day = d.string(from: session.startedAt)
        }
        guard let ended = session.endedAt else { return day }
        return "\(day) · \(time.string(from: session.startedAt)) – \(timeAmPm.string(from: ended))"
    }

    @ViewBuilder
    private func chartCard<Content: View>(title: String, footnote: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                Spacer()
                if let footnote {
                    Text(footnote).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(PulseColors.textMuted)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private var hrFootnote: String? {
        guard let avg = session.avgHeartRate else { return nil }
        let mn = session.minHeartRate.map { Int($0) }
        let mx = session.maxHeartRate.map { Int($0) }
        if let mn, let mx { return "\(mn) · avg \(Int(avg)) · \(mx) bpm" }
        return "avg \(Int(avg)) bpm"
    }

    private var spo2Footnote: String? {
        session.avgSpO2.map { "avg \(Int($0))%" }
    }

    private func statsGrid(elevationGain: Double?) -> some View {
        // The hero band already shows the headline metrics (GPS: distance/duration/pace,
        // indoor: duration/active-min/calories), so the grid fills in the rest without repeating.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            if session.useGps {
                WorkoutStat(label: "Calories", value: session.calories.map { "\(Int($0))" } ?? "—")
            }
            WorkoutStat(label: "Avg HR", value: session.avgHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Max HR", value: session.maxHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Min HR", value: session.minHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "SpO₂", value: session.latestSpO2.map { "\(Int($0))%" } ?? "—")
            if session.useGps, let elevationGain {
                WorkoutStat(label: "Elev gain", value: String(format: "%.0f m", elevationGain))
            }
        }
    }
}

/// Three large headline stats in one card. Adapts to whether the workout used GPS:
/// outdoor → Distance · Duration · Pace; indoor → Duration · Active min · Calories.
private struct SummaryHeroBand: View {
    let session: ActivitySession
    let durationSeconds: Int?

    private struct Metric { let value: String; let label: String; let tint: Color }

    private var metrics: [Metric] {
        let dur = durationSeconds.map { ActivityMeta.duration($0) } ?? "—"
        if session.useGps {
            let isImperial = WorkoutAppGroup.useImperialUnits
            let divisor = isImperial ? 1609.34 : 1000.0
            let dist = session.distanceMeters.map { String(format: "%.2f", $0 / divisor) } ?? "—"
            let pace = ActivityMeta.pace(distanceMeters: session.distanceMeters, durationSeconds: durationSeconds)
            return [
                Metric(value: dist, label: isImperial ? "MI" : "KM", tint: PulseColors.distance),
                Metric(value: dur, label: "DURATION", tint: PulseColors.textPrimary),
                Metric(value: pace?.replacingOccurrences(of: " /km", with: "").replacingOccurrences(of: " /mi", with: "") ?? "—", label: isImperial ? "PACE /MI" : "PACE /KM", tint: PulseColors.accent)
            ]
        } else {
            let cals = session.calories.map { "\(Int($0))" } ?? "—"
            return [
                Metric(value: dur, label: "DURATION", tint: PulseColors.textPrimary),
                Metric(value: durationSeconds.map { "\($0 / 60)" } ?? "—", label: "ACTIVE MIN", tint: PulseColors.success),
                Metric(value: cals, label: "CALORIES", tint: PulseColors.calories)
            ]
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, m in
                VStack(spacing: 6) {
                    Text(m.value)
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(m.tint)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text(m.label)
                        .font(.system(size: 10, weight: .medium)).tracking(0.8)
                        .foregroundStyle(PulseColors.textMuted)
                }
                .frame(maxWidth: .infinity)
                if index != metrics.count - 1 {
                    Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 40)
                }
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// Per-kilometre splits with a relative pace bar; the fastest km is highlighted. Hidden when
/// there isn't at least one full completed kilometre.
private struct SplitsTable: View {
    let points: [ActivityGpsPoint]

    var body: some View {
        let splits = kmSplitSeconds(points)
        if splits.count >= 1 {
            let fastest = splits.min() ?? 0
            let slowest = splits.max() ?? 1
            let isImperial = WorkoutAppGroup.useImperialUnits
            let unitLabelCaps = isImperial ? "MI" : "KM"
            VStack(alignment: .leading, spacing: 10) {
                Text("SPLITS").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                ForEach(Array(splits.enumerated()), id: \.offset) { index, seconds in
                    let isFastest = seconds == fastest
                    let frac = slowest > fastest ? (seconds - fastest) / (slowest - fastest) : 0
                    HStack(spacing: 12) {
                        Text("\(unitLabelCaps) \(index + 1)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 44, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PulseColors.cardSoft)
                                Capsule().fill(isFastest ? PulseColors.accent : PulseColors.distance)
                                    // Faster = longer bar (invert the fraction).
                                    .frame(width: max(8, geo.size.width * (0.25 + 0.75 * (1 - frac))))
                            }
                        }
                        .frame(height: 8)
                        Text(paceLabel(seconds))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(isFastest ? PulseColors.accent : PulseColors.textPrimary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
    }

    private func paceLabel(_ secPerUnit: Double) -> String {
        let isImperial = WorkoutAppGroup.useImperialUnits
        let label = isImperial ? "/mi" : "/km"
        return String(format: "%d:%02d %@", Int(secPerUnit) / 60, Int(secPerUnit.rounded()) % 60, label)
    }
}

/// Time-in-zone breakdown derived from HR samples (zones by %HRmax). Hidden when no usable time
/// accrued in any zone.
private struct HRZonesCard: View {
    let samples: [MetricSample]
    let age: Int?

    var body: some View {
        let zones = hrZoneDurations(samples: samples, age: age)
        let total = zones.reduce(0) { $0 + $1.seconds }
        if total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("HEART RATE ZONES").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                ForEach(zones.reversed()) { zone in
                    let frac = zone.seconds / total
                    HStack(spacing: 10) {
                        Text(zone.name)
                            .font(.system(size: 12)).foregroundStyle(PulseColors.textSecondary)
                            .frame(width: 132, alignment: .leading).lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PulseColors.cardSoft)
                                Capsule().fill(zone.color)
                                    .frame(width: max(frac > 0 ? 6 : 0, geo.size.width * frac))
                            }
                        }
                        .frame(height: 8)
                        Text(zone.seconds >= 1 ? ActivityMeta.duration(Int(zone.seconds)) : "—")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(zone.seconds >= 1 ? PulseColors.textPrimary : PulseColors.textMuted)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        }
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
                Text(label.uppercased()).font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(muted ? PulseColors.textMuted : PulseColors.textPrimary)
                    .minimumScaleFactor(0.6).lineLimit(1)
                if let unit { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(PulseColors.textMuted) }
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(PulseColors.textMuted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Stretch to fill the grid cell so all tiles in a row are the same height.
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
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

    var body: some View {
        HStack(spacing: 6) {
            if session.useGps {
                StatusPill(icon: "location.fill", text: "GPS \(gpsLabel.0)", tint: gpsLabel.1)
            }
            StatusPill(icon: "dot.radiowaves.left.and.right", text: ringLabel.0, tint: ringLabel.1)
            StatusPill(icon: "heart.fill", text: "HR 1m", tint: PulseColors.textMuted)
            StatusPill(icon: "drop.fill", text: "SpO₂ 5m", tint: PulseColors.textMuted)
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
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(PulseColors.cardSoft, in: Capsule())
        .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

/// Per-kilometre/mile splits for distance activities (last / best / current pace).
struct SplitStrip: View {
    let points: [ActivityGpsPoint]
    var body: some View {
        let splits = kmSplits()
        let isImperial = WorkoutAppGroup.useImperialUnits
        let unitLabel = isImperial ? "mi" : "km"
        HStack(spacing: 12) {
            WorkoutStat(label: "Last \(unitLabel)", value: splits.last ?? "—")
            WorkoutStat(label: "Best \(unitLabel)", value: splits.best ?? "—")
            WorkoutStat(label: "This \(unitLabel)", value: splits.current ?? "—")
        }
    }

    private func kmSplits() -> (last: String?, best: String?, current: String?) {
        guard points.count >= 2, let lastPoint = points.last else { return (nil, nil, nil) }
        let isImperial = WorkoutAppGroup.useImperialUnits
        let divisor = isImperial ? 1609.34 : 1000.0
        let splitSeconds = kmSplitSeconds(points)
        let cumulative = zip(points, points.dropFirst()).reduce(0) { $0 + haversineMeters($1.0, $1.1) }
        // Partial distance / time since the last whole-unit mark.
        let distSinceMark = cumulative.truncatingRemainder(dividingBy: divisor)
        let elapsed = lastPoint.timestamp.timeIntervalSince(points.first?.timestamp ?? lastPoint.timestamp)
        let timeSinceMark = elapsed - splitSeconds.reduce(0, +)
        let currentPace = distSinceMark >= 50 && timeSinceMark > 0 ? timeSinceMark / (distSinceMark / divisor) : nil
        return (paceString(splitSeconds.last), paceString(splitSeconds.min()), paceString(currentPace))
    }

    private func paceString(_ secPerUnit: Double?) -> String? {
        guard let secPerUnit, secPerUnit > 0 else { return nil }
        return String(format: "%d:%02d", Int(secPerUnit) / 60, Int(secPerUnit.rounded()) % 60)
    }
}

/// Post-workout transparency about how well the (reverse-engineered) ring + GPS performed.
struct RecordingQualityCard: View {
    @Environment(\.modelContext) private var modelContext
    let session: ActivitySession

    var body: some View {
        let rows = qualityRows()
        VStack(alignment: .leading, spacing: 12) {
            Text("RECORDING QUALITY").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    Text(rows[i].0).font(.system(size: 13)).foregroundStyle(PulseColors.textSecondary)
                    Spacer()
                    Text(rows[i].1).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(rows[i].2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func qualityRows() -> [(String, String, Color)] {
        let samples = ActivityRepository.samples(sessionId: session.id, context: modelContext)
        let hrCount = samples.filter { $0.kind == MeasurementKind.heartRate.rawValue && $0.value > 0 }.count
        let spo2Count = samples.filter { $0.kind == MeasurementKind.spo2.rawValue && $0.value > 0 }.count
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) } ?? 0
        let expectedHR = max(1, duration / 60)
        let expectedSpO2 = max(1, duration / 300)
        let pollFailures = session.hrPollFailureCount + session.spo2PollFailureCount

        var rows: [(String, String, Color)] = []
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
