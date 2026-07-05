import SwiftUI
import SwiftData

// MARK: - Shared small pieces

/// Compact 3-up stat tile used on summary/detail (mirrors web `Stat`/`StatsGrid`).
/// Internal (not `private`) because `RecordSummaryComponents.swift` reuses it.
struct WorkoutStat: View {
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
func sessionHRSamples(_ sessionId: UUID, context: ModelContext) -> [MetricSample] {
    ActivityRepository.samples(sessionId: sessionId, context: context)
        .filter { $0.kind == MeasurementKind.heartRate.rawValue && $0.value > 0 }
        .sorted { $0.timestamp < $1.timestamp }
        .map { MetricSample(timestamp: $0.timestamp, value: $0.value) }
}

/// SpO₂ samples for a finished session, as chart-ready points.
@MainActor
func sessionSpO2Samples(_ sessionId: UUID, context: ModelContext) -> [MetricSample] {
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
    @Query private var profiles: [UserProfile]
    private var units: UnitsPreference { profiles.first?.units ?? .metric }
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
                        let d = UnitsFormatter.distance(meters: distance, units: units)
                        Text("\(d.value) \(d.unit)")
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
        // Seed the GPS toggle from the user's Activity-Tracking default (still per-workout overridable).
        .onAppear { useGps = WorkoutPrefsStore.shared.settings.useGpsByDefault }
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
    @Query private var profiles: [UserProfile]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext).filter { $0.accepted }
            let paused = session.status == .paused
            TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                let elapsedSec = elapsed(session: session, now: timeline.date)
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: ActivityMeta.icon(session.type))
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(PulseColors.accent)
                                Text(ActivityMeta.label(session.type))
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(PulseColors.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                RecordingStatusPill(paused: paused)
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
                                value: spo2TileValue().map { "\($0)%" } ?? "—",
                                unit: nil,
                                label: "SpO₂",
                                subtitle: spo2Subtitle(session, now: timeline.date),
                                pulsing: coordinator.spo2State == .measuring,
                                tint: PulseColors.spo2,
                                muted: spo2TileValue() == nil
                            )
                            if session.useGps {
                                if ActivityMetricSet.set(for: session.type).showsSpeed {
                                    LiveStatTile(value: speedLabel(points: points, elapsedSec: elapsedSec, session: session), label: "Speed")
                                } else {
                                    LiveStatTile(value: paceLabel(points: points, elapsedSec: elapsedSec, session: session), label: "Pace")
                                }
                            }
                        }

                        if showSplits(session) {
                            SplitStrip(points: points, units: units, activityType: session.type)
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
                            } else if !gps.hasAlwaysAuthorization {
                                Text("Route will pause when the screen locks — allow “Always” location in Settings for full background tracking.")
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
            .sheet(isPresented: $confirmFinish) {
                WorkoutEndSheet(
                    title: "Finish workout?",
                    message: "Your workout will be saved with its time, route, and ring measurements.",
                    stats: endSheetStats(session: session, points: points),
                    confirmTitle: "Finish workout",
                    confirmIcon: "flag.checkered",
                    destructive: false
                ) { finish(session) }
            }
            .sheet(isPresented: $confirmDiscard) {
                WorkoutEndSheet(
                    title: "Discard workout?",
                    message: "This recording will be deleted and won't count toward your activity.",
                    stats: endSheetStats(session: session, points: points),
                    confirmTitle: "Discard workout",
                    confirmIcon: "trash",
                    destructive: true
                ) { discard(session) }
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
        // Stream mode: samples land continuously — say "live" while they're fresh, then fall back to
        // the staleness copy (ring away / stream stalled).
        if liveWorkout.activePlan?.hrMode == .stream,
           let last = lastSampleTime(session.id, kind: "hr"),
           Date().timeIntervalSince(last) < 15 {
            return "live"
        }
        // Keep the last value on screen and never flash an error: while a reading is in progress show
        // "measuring…", otherwise the time since the last sample. Only "waiting…" before the first one.
        if coordinator.hrState == .measuring { return "measuring…" }
        guard let last = lastSampleTime(session.id, kind: "hr") else { return "waiting…" }
        return "updated \(agoLabel(last))"
    }

    private func spo2Subtitle(_ session: ActivitySession, now: Date) -> String {
        if coordinator.spo2State == .measuring { return "reading…" }
        switch liveWorkout.activePlan?.spo2Mode {
        case .ringLog:
            // No instant SpO2 on this ring — the tile shows the newest all-day log value.
            if let ts = MetricsRepository.latestMeasurement(kind: .spo2, context: modelContext)?.timestamp {
                return "ring log · \(agoLabel(ts))"
            }
            return "from ring log"
        case .off:
            return "off"
        default:
            break
        }
        let interval = TimeInterval(WorkoutPrefsStore.shared.settings.spo2PollIntervalSeconds)
        guard let last = lastSampleTime(session.id, kind: "spo2") else { return "every \(max(1, Int(interval) / 60)) min" }
        let remaining = max(0, interval - now.timeIntervalSince(last))
        return remaining > 0 ? "next in \(ActivityMeta.duration(Int(remaining)))" : "due now"
    }

    /// Tile value: live reading normally; in ring-log mode, the newest all-day log value.
    private func spo2TileValue() -> Int? {
        if liveWorkout.activePlan?.spo2Mode == .ringLog {
            return MetricsRepository.latestMeasurement(kind: .spo2, context: modelContext).map { Int($0.value) }
        }
        return coordinator.latestSpO2Value
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
        session.useGps && ActivityMetricSet.set(for: session.type).showsSplits
    }

    // MARK: live stats

    private func distanceLabel(points: [ActivityGpsPoint], session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        let meters = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: session.type))
        guard meters > 0 else { return "—" }
        let d = UnitsFormatter.distance(meters: meters, units: units)
        return "\(d.value) \(d.unit)"
    }

    private func paceLabel(points: [ActivityGpsPoint], elapsedSec: Int, session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        let meters = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: session.type))
        return ActivityMeta.pace(distanceMeters: meters, durationSeconds: elapsedSec, units: units) ?? "—"
    }

    /// Average speed for cycling (pace-style min/km reads oddly on a bike).
    private func speedLabel(points: [ActivityGpsPoint], elapsedSec: Int, session: ActivitySession) -> String {
        guard session.useGps, elapsedSec > 0 else { return "—" }
        let meters = RouteDistanceEngine.distanceMeters(points, profile: .profile(for: session.type))
        guard meters >= 50 else { return "—" }
        let mps = meters / Double(elapsedSec)
        return units == .imperial
            ? String(format: "%.1f mph", mps * 2.23694)
            : String(format: "%.1f km/h", mps * 3.6)
    }

    private func elapsed(session: ActivitySession, now: Date) -> Int {
        max(0, Int((session.endedAt ?? now).timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
    }

    /// Mini recap shown on the finish/discard sheets.
    private func endSheetStats(session: ActivitySession, points: [ActivityGpsPoint]) -> [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = [
            (label: "Duration", value: ActivityMeta.duration(elapsed(session: session, now: Date())))
        ]
        if session.useGps {
            stats.append((label: "Distance", value: distanceLabel(points: points, session: session)))
        }
        if let hr = coordinator.latestHRValue {
            stats.append((label: "Heart rate", value: "\(hr) bpm"))
        }
        return stats
    }
}

/// Small REC / PAUSED chip next to the activity name on the live screen.
struct RecordingStatusPill: View {
    let paused: Bool

    private var color: Color { paused ? PulseColors.warning : PulseColors.danger }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(paused ? "PAUSED" : "REC")
                .font(.system(size: 11, weight: .semibold)).tracking(1.0)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Branded replacement for the system finish/discard dialogs: a compact bottom sheet with a mini
/// recap of the workout and the app's own button styling.
private struct WorkoutEndSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let stats: [(label: String, value: String)]
    let confirmTitle: String
    let confirmIcon: String
    var destructive: Bool = false
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 8)

            HStack(spacing: 0) {
                ForEach(stats.indices, id: \.self) { i in
                    if i > 0 {
                        Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 34)
                    }
                    VStack(spacing: 4) {
                        Text(stats[i].value)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(stats[i].label.uppercased())
                            .font(.system(size: 10, weight: .medium)).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 14)
            .background(PulseColors.cardSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
                onConfirm()
            } label: {
                Label(confirmTitle, systemImage: confirmIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(.white)
                    .background(destructive ? PulseColors.danger : PulseColors.accent)
                    .clipShape(Capsule())
            }

            Button { dismiss() } label: {
                Text("Keep recording")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(PulseColors.textPrimary)
                    .background(PulseColors.cardSoft)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))
            }
        }
        .padding(20)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .presentationBackground(PulseColors.card)
    }
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
                                .font(.system(size: 12))
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
                    .background(.ultraThinMaterial)
            }
            .onAppear { effort = session.perceivedEffort; note = session.notes ?? "" }
            .onChange(of: samples.count) { _, _ in
                // Late ring-log samples attached — recompute the aggregates (idempotent).
                ActivityService.refreshSummary(for: session, context: modelContext)
            }
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

/// Per-kilometre splits for distance activities (last / best / current km pace).
struct SplitStrip: View {
    let points: [ActivityGpsPoint]
    var units: UnitsPreference = .metric
    var activityType: String = "run"

    private var splitMeters: Double { units == .imperial ? 1609.344 : 1000 }
    private var splitWord: String { units == .imperial ? "mi" : "km" }

    var body: some View {
        let splits = kmSplits()
        HStack(spacing: 12) {
            WorkoutStat(label: "Last \(splitWord)", value: splits.last ?? "—")
            WorkoutStat(label: "Best \(splitWord)", value: splits.best ?? "—")
            WorkoutStat(label: "This \(splitWord)", value: splits.current ?? "—")
        }
    }

    private func kmSplits() -> (last: String?, best: String?, current: String?) {
        let result = RouteDistanceEngine.splits(points, splitMeters: splitMeters, profile: .profile(for: activityType))
        let completed = result.completedSeconds
        let currentPace = result.partialMeters >= 50 && result.partialSeconds > 0
            ? result.partialSeconds / (result.partialMeters / splitMeters) : nil
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
        let streamed = session.vitalsModeRaw == "stream"
        // Healthy coverage baseline: a stream should land a sample at least every ~10s; spot polls
        // aim for one per minute.
        let expectedHR = max(1, duration / (streamed ? 10 : 60))
        let expectedSpO2 = max(1, duration / 300)
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
