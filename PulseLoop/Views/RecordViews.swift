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
                .font(PulseFont.title3)
                .monospacedDigit()
                .foregroundStyle(PulseColors.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label.uppercased())
                .font(PulseFont.micro)
                .tracking(0.6)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .font(PulseFont.title)
                .monospacedDigit()
                .foregroundStyle(muted ? PulseColors.textMuted : PulseColors.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label.uppercased())
                .font(PulseFont.caption2)
                .tracking(1.0)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Stretch to fill the grid cell so all tiles in a row are the same height.
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
    @Environment(LiveWorkoutManager.self) private var liveWorkout
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
                        // Route through the manager (not ActivityRecorderService directly) so the
                        // lingering Live Activity is ended and GPS/polling are torn down too.
                        Button("Finish") {
                            liveWorkout.finish(session)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.success)
                        Button("Discard") {
                            liveWorkout.cancel(session)
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
    @Query private var profiles: [UserProfile]
    let sessionId: UUID
    @State private var confirmingDelete = false
    @State private var editing = false

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

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
                        .font(PulseFont.subheadline.weight(.regular))
                        .padding(.horizontal, 4)
                    }

                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete workout", systemImage: "trash")
                            .font(PulseFont.callout)
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
                    Button { editing = true } label: {
                        Image(systemName: "pencil")
                    }
                    .tint(PulseColors.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .tint(PulseColors.danger)
                }
            }
            .sheet(isPresented: $editing) {
                EditWorkoutSheet(session: session)
            }
            .sheet(isPresented: $confirmingDelete) {
                WorkoutEndSheet(
                    title: "Delete this workout?",
                    message: "This permanently removes the workout and its recorded heart-rate, GPS, and sensor data. This can't be undone.",
                    stats: deleteSheetStats(session),
                    confirmTitle: "Delete workout",
                    confirmIcon: "trash",
                    destructive: true,
                    cancelTitle: "Keep workout"
                ) {
                    ActivityRecorderService.delete(session, context: modelContext)
                    dismiss()
                }
            }
        } else {
            EmptyStateView(title: "Workout not found", body: "This session is no longer in local storage.")
        }
    }

    /// Mini recap on the delete sheet — what the user is about to lose.
    private func deleteSheetStats(_ session: ActivitySession) -> [(label: String, value: String)] {
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) } ?? 0
        var stats: [(label: String, value: String)] = [
            (label: "Duration", value: ActivityMeta.duration(duration))
        ]
        if let meters = session.distanceMeters, meters > 0 {
            let d = UnitsFormatter.distance(meters: meters, units: units)
            stats.append((label: "Distance", value: "\(d.value) \(d.unit)"))
        }
        if let avg = session.avgHeartRate {
            stats.append((label: "Avg HR", value: "\(Int(avg)) bpm"))
        }
        return stats
    }
}

/// Limited post-finish editing: activity type and the start/end window. Everything derived —
/// distance, calories, HR aggregates, the sample window, the daily rollup — is recomputed by
/// `ActivityService.applyEdit`, which also pulls all-day ring data into an expanded window.
private struct EditWorkoutSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let session: ActivitySession
    @State private var type: String
    @State private var startedAt: Date
    @State private var endedAt: Date

    init(session: ActivitySession) {
        self.session = session
        _type = State(initialValue: ActivityMeta.meta(session.type).type)
        _startedAt = State(initialValue: session.startedAt)
        _endedAt = State(initialValue: session.endedAt ?? Date())
    }

    private var validationMessage: String? {
        if endedAt > Date() { return "End time can't be in the future." }
        if endedAt.timeIntervalSince(startedAt) <= session.totalPauseSeconds {
            return session.totalPauseSeconds > 0
                ? "The window must be longer than the \(max(1, Int(session.totalPauseSeconds / 60))) min of pauses in this workout."
                : "End must be after the start."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Edit workout")
                .font(PulseFont.title3.weight(.bold))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 8)

            fieldRow("Activity") {
                Picker("Activity type", selection: $type) {
                    ForEach(ActivityMeta.allKinds) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind.type)
                    }
                }
                .pickerStyle(.menu)
                .tint(PulseColors.accent)
            }

            fieldRow("Starts") {
                DatePicker("", selection: $startedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .tint(PulseColors.accent)
            }

            fieldRow("Ends") {
                DatePicker("", selection: $endedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .tint(PulseColors.accent)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.warning)
                    .multilineTextAlignment(.center)
            } else {
                Text("Distance, calories, and heart-rate stats are recalculated. Ring data recorded in the new window is pulled in automatically.")
                    .font(PulseFont.caption.weight(.regular))
                    .foregroundStyle(PulseColors.textMuted)
                    .multilineTextAlignment(.center)
            }

            Button {
                if ActivityService.applyEdit(
                    session: session, newType: type, newStartedAt: startedAt, newEndedAt: endedAt,
                    context: modelContext
                ) {
                    dismiss()
                }
            } label: {
                Label("Save changes", systemImage: "checkmark")
                    .font(PulseFont.bodyEmphasis)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(.white)
                    .background(validationMessage == nil ? PulseColors.accent : PulseColors.accent.opacity(0.4))
                    .clipShape(Capsule())
            }
            .disabled(validationMessage != nil)

            Button { dismiss() } label: {
                Text("Cancel")
                    .font(PulseFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(PulseColors.textPrimary)
                    .pulseGlass(Capsule(), interactive: true)
            }
        }
        .padding(20)
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
        .presentationBackground(PulseColors.card)
    }

    private func fieldRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .font(PulseFont.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(PulseColors.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(ActivityMeta.allKinds) { kind in
                        let isSelected = kind.type == selected
                        Button { selected = kind.type } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: kind.symbol)
                                    .font(PulseFont.title2.weight(.regular))
                                    .foregroundStyle(isSelected ? PulseColors.accent : PulseColors.textSecondary)
                                    .frame(width: 46, height: 46)
                                    .background(isSelected ? PulseColors.accentSoft : PulseColors.cardSoft, in: Circle())
                                Text(kind.label)
                                    .font(PulseFont.bodyEmphasis)
                                    .foregroundStyle(PulseColors.textPrimary)
                                Text(kind.helper)
                                    .font(PulseFont.caption.weight(.regular))
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
                        Text("Use GPS route").font(PulseFont.callout).foregroundStyle(PulseColors.textPrimary)
                        Text(gpsCapable ? "Track your route on a map" : "Not available for this activity")
                            .font(PulseFont.caption.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                    }
                }
                .tint(PulseColors.accent)
                .disabled(!gpsCapable)
                .padding(16)
                .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))

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
    @Environment(GpsRouteRecorder.self) private var gps
    @Environment(LiveWorkoutManager.self) private var liveWorkout
    @Query private var sessions: [ActivitySession]
    @Query private var profiles: [UserProfile]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    init(sessionId: UUID, path: Binding<NavigationPath>) {
        self.sessionId = sessionId
        self._path = path
        // Scope the query to this one session — the live screen must never fetch the whole table.
        self._sessions = Query(filter: #Predicate<ActivitySession> { $0.id == sessionId })
    }

    private var units: UnitsPreference { profiles.first?.units ?? .metric }

    // Body notes: no whole-screen TimelineView and no per-render store fetches. The 1 Hz clock is
    // confined to `ElapsedTimeText`; every stat tile reads `LiveWorkoutStats` (O(1) values kept
    // current by LiveWorkoutManager's event-bus feed) in its own body so only the affected tile
    // re-renders when a sample or GPS fix lands.
    var body: some View {
        if let session = sessions.first {
            let paused = session.status == .paused
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: ActivityMeta.icon(session.type))
                                .font(PulseFont.title2)
                                .foregroundStyle(PulseColors.accent)
                            Text(ActivityMeta.label(session.type))
                                .font(PulseFont.title.weight(.bold))
                                .foregroundStyle(PulseColors.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            RecordingStatusPill(paused: paused)
                        }
                        LiveStatusStrip(session: session, plan: liveWorkout.activePlan, stats: liveWorkout.stats)
                    }
                    .padding(.top, 8)

                    ElapsedTimeText(
                        startedAt: session.startedAt,
                        totalPauseSeconds: session.totalPauseSeconds,
                        pausedAt: paused ? (liveWorkout.stats?.pausedAt ?? Date()) : nil
                    )

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        // GPS-only tiles are hidden for indoor activities (no map/distance/pace).
                        if session.useGps {
                            LiveDistanceTile(stats: liveWorkout.stats, units: units)
                        }
                        LiveHRTile(stats: liveWorkout.stats, plan: liveWorkout.activePlan)
                        LiveSpO2Tile(stats: liveWorkout.stats, plan: liveWorkout.activePlan)
                        if session.useGps {
                            LivePaceTile(
                                stats: liveWorkout.stats,
                                startedAt: session.startedAt,
                                totalPauseSeconds: session.totalPauseSeconds,
                                showsSpeed: ActivityMetricSet.set(for: session.type).showsSpeed,
                                units: units
                            )
                        }
                    }

                    if showSplits(session) {
                        LiveSplitStrip(stats: liveWorkout.stats, units: units)
                    }

                    if session.useGps {
                        LiveRouteMapSection(
                            stats: liveWorkout.stats,
                            paused: paused,
                            permissionDenied: gps.isPermissionDenied,
                            hasAlwaysAuthorization: gps.hasAlwaysAuthorization
                        )
                    } else if paused {
                        Text("PAUSED")
                            .font(PulseFont.footnote.weight(.semibold)).tracking(2)
                            .foregroundStyle(PulseColors.textPrimary)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .pulseGlass(Capsule())
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background(PulseColors.background)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    SecondaryButton(title: paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                        if paused { liveWorkout.resume(session) } else { liveWorkout.pause(session) }
                    }
                    PrimaryButton(title: "Finish", systemImage: "flag.checkered") { confirmFinish = true }
                }
                .padding(16)
                .pulseGlass(Rectangle())
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
                    stats: endSheetStats(session: session),
                    confirmTitle: "Finish workout",
                    confirmIcon: "flag.checkered",
                    destructive: false
                ) { finish(session) }
            }
            .sheet(isPresented: $confirmDiscard) {
                WorkoutEndSheet(
                    title: "Discard workout?",
                    message: "This recording will be deleted and won't count toward your activity.",
                    stats: endSheetStats(session: session),
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

    private func showSplits(_ session: ActivitySession) -> Bool {
        session.useGps && ActivityMetricSet.set(for: session.type).showsSplits
    }

    private func elapsed(session: ActivitySession, now: Date) -> Int {
        max(0, Int((session.endedAt ?? now).timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
    }

    /// Mini recap shown on the finish/discard sheets.
    private func endSheetStats(session: ActivitySession) -> [(label: String, value: String)] {
        var stats: [(label: String, value: String)] = [
            (label: "Duration", value: ActivityMeta.duration(elapsed(session: session, now: Date())))
        ]
        if session.useGps {
            let meters = liveWorkout.stats?.distanceMeters ?? 0
            let value: String
            if meters > 0 {
                let d = UnitsFormatter.distance(meters: meters, units: units)
                value = "\(d.value) \(d.unit)"
            } else {
                value = "—"
            }
            stats.append((label: "Distance", value: value))
        }
        if let hr = liveWorkout.stats?.lastHR?.value ?? coordinator.latestHRValue {
            stats.append((label: "Heart rate", value: "\(hr) bpm"))
        }
        return stats
    }
}

// MARK: - Live screen subviews
// Each reads only the observable values it renders, so an HR sample re-renders one tile — not the
// whole screen — and the 1 Hz clock invalidates nothing but the duration text.

/// "Xs ago" copy for tile subtitles. Takes `now` so a slow TimelineView can keep it honest.
private func agoLabel(_ date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
}

/// The only 1 Hz-invalidated view on the live screen. Freezes at `pausedAt` while paused
/// (`totalPauseSeconds` only accumulates on resume, so subtracting it stays correct mid-pause).
private struct ElapsedTimeText: View {
    let startedAt: Date
    let totalPauseSeconds: Double
    let pausedAt: Date?

    var body: some View {
        if let pausedAt {
            clock(now: pausedAt, muted: true)
        } else {
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                clock(now: timeline.date, muted: false)
            }
        }
    }

    private func clock(now: Date, muted: Bool) -> some View {
        VStack(spacing: 6) {
            Text(ActivityMeta.duration(max(0, Int(now.timeIntervalSince(startedAt) - totalPauseSeconds))))
                .font(PulseFont.numberHero)
                .monospacedDigit()
                .foregroundStyle(muted ? PulseColors.textMuted : PulseColors.textPrimary)
            Text("DURATION").font(PulseFont.caption2).tracking(1.4).foregroundStyle(PulseColors.textMuted)
        }
        .padding(.vertical, 8)
    }
}

/// Wraps `WorkoutStatusStrip` so ring-state / GPS-accuracy changes re-render just the pills.
private struct LiveStatusStrip: View {
    @Environment(RingBLEClient.self) private var ble
    let session: ActivitySession
    let plan: WorkoutVitalsPlan?
    let stats: LiveWorkoutStats?

    var body: some View {
        WorkoutStatusStrip(session: session, ringState: ble.state, gpsAccuracy: stats?.latestAccuracy, plan: plan)
    }
}

private struct LiveDistanceTile: View {
    let stats: LiveWorkoutStats?
    let units: UnitsPreference

    var body: some View {
        LiveStatTile(value: label, label: "Distance")
    }

    private var label: String {
        guard let meters = stats?.distanceMeters, meters > 0 else { return "—" }
        let d = UnitsFormatter.distance(meters: meters, units: units)
        return "\(d.value) \(d.unit)"
    }
}

private struct LiveHRTile: View {
    @Environment(RingSyncCoordinator.self) private var coordinator
    let stats: LiveWorkoutStats?
    let plan: WorkoutVitalsPlan?

    var body: some View {
        // A slow 10 s tick keeps the freshness copy ("live" / "Xs ago") honest between samples.
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            let hr = stats?.lastHR
            LiveSensorTile(
                value: hr.map { "\($0.value)" } ?? "—",
                unit: hr == nil ? nil : "bpm",
                label: "Heart rate",
                subtitle: subtitle(now: timeline.date),
                pulsing: coordinator.hrState == .measuring,
                tint: PulseColors.heartRate,
                muted: hr == nil
            )
        }
    }

    private func subtitle(now: Date) -> String {
        if let hr = stats?.lastHR {
            switch hr.source {
            case .live:
                // Stream mode: samples land continuously — say "live" while fresh, then fall back
                // to the staleness copy (ring away / stream stalled).
                if plan?.hrMode == .stream, now.timeIntervalSince(hr.at) < 15 { return "live" }
                if coordinator.hrState == .measuring { return "measuring…" }
                return "updated \(agoLabel(hr.at, now: now))"
            case .ringLog:
                // Fallback while the stream has nothing: the ring's own 5-min log.
                return "ring log · \(agoLabel(hr.at, now: now))"
            }
        }
        if coordinator.hrState == .measuring { return "measuring…" }
        return "waiting…"
    }
}

private struct LiveSpO2Tile: View {
    @Environment(RingSyncCoordinator.self) private var coordinator
    let stats: LiveWorkoutStats?
    let plan: WorkoutVitalsPlan?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { timeline in
            let spo2 = stats?.lastSpO2
            LiveSensorTile(
                value: spo2.map { "\($0.value)%" } ?? "—",
                unit: nil,
                label: "SpO₂",
                subtitle: subtitle(now: timeline.date),
                pulsing: coordinator.spo2State == .measuring,
                tint: PulseColors.spo2,
                muted: spo2 == nil
            )
        }
    }

    private func subtitle(now: Date) -> String {
        if coordinator.spo2State == .measuring { return "reading…" }
        switch plan?.spo2Mode {
        case .ringLog:
            // No instant SpO2 on this ring — the tile shows the newest all-day log value.
            if let at = stats?.lastSpO2?.at { return "ring log · \(agoLabel(at, now: now))" }
            return "from ring log"
        case .off:
            return "off"
        default:
            break
        }
        let interval = TimeInterval(WorkoutPrefsStore.shared.settings.spo2PollIntervalSeconds)
        guard let last = stats?.lastSpO2?.at else { return "every \(max(1, Int(interval) / 60)) min" }
        let remaining = max(0, interval - now.timeIntervalSince(last))
        return remaining > 0 ? "next in \(ActivityMeta.duration(Int(remaining)))" : "due now"
    }
}

/// Pace (or average speed for cycling — min/km reads oddly on a bike). Recomputes when distance
/// changes (each accepted fix); pace drifts slowly, so no per-second tick is needed.
private struct LivePaceTile: View {
    let stats: LiveWorkoutStats?
    let startedAt: Date
    let totalPauseSeconds: Double
    let showsSpeed: Bool
    let units: UnitsPreference

    var body: some View {
        LiveStatTile(value: label, label: showsSpeed ? "Speed" : "Pace")
    }

    private var label: String {
        guard let stats else { return "—" }
        let meters = stats.distanceMeters
        let frozenNow = stats.pausedAt ?? Date()
        let elapsedSec = max(0, Int(frozenNow.timeIntervalSince(startedAt) - totalPauseSeconds))
        if showsSpeed {
            guard elapsedSec > 0, meters >= 50 else { return "—" }
            let mps = meters / Double(elapsedSec)
            return units == .imperial
                ? String(format: "%.1f mph", mps * 2.23694)
                : String(format: "%.1f km/h", mps * 3.6)
        }
        return ActivityMeta.pace(distanceMeters: meters, durationSeconds: elapsedSec, units: units) ?? "—"
    }
}

private struct LiveSplitStrip: View {
    let stats: LiveWorkoutStats?
    let units: UnitsPreference

    var body: some View {
        SplitStrip(splits: stats?.splits ?? RouteDistanceEngine.Splits(), units: units)
    }
}

private struct LiveRouteMapSection: View {
    let stats: LiveWorkoutStats?
    let paused: Bool
    let permissionDenied: Bool
    let hasAlwaysAuthorization: Bool

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                WorkoutMapView(
                    coordinates: stats?.coordinates ?? [],
                    latestAccuracy: stats?.latestAccuracy,
                    unavailable: permissionDenied,
                    height: 220,
                    follow: !paused
                )
                .opacity(paused ? 0.55 : 1)
                if paused {
                    Text("PAUSED")
                        .font(PulseFont.footnote.weight(.semibold)).tracking(2)
                        .foregroundStyle(PulseColors.textPrimary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .pulseGlass(Capsule())
                }
            }

            if permissionDenied {
                Text("Location access is denied — enable it in Settings to record your route.")
                    .font(.caption).foregroundStyle(PulseColors.warning).multilineTextAlignment(.center)
            } else if !hasAlwaysAuthorization {
                Text("Route will pause when the screen locks — allow “Always” location in Settings for full background tracking.")
                    .font(.caption).foregroundStyle(PulseColors.warning).multilineTextAlignment(.center)
            }
        }
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
                .font(PulseFont.caption2.weight(.semibold)).tracking(1.0)
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
    var cancelTitle: String = "Keep recording"
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(PulseFont.title3.weight(.bold))
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.top, 8)

            HStack(spacing: 0) {
                ForEach(stats.indices, id: \.self) { i in
                    if i > 0 {
                        Rectangle().fill(PulseColors.borderSubtle).frame(width: 1, height: 34)
                    }
                    VStack(spacing: 4) {
                        Text(stats[i].value)
                            .font(PulseFont.numberM)
                            .monospacedDigit()
                            .foregroundStyle(PulseColors.textPrimary)
                        Text(stats[i].label.uppercased())
                            .font(PulseFont.micro).tracking(1.0)
                            .foregroundStyle(PulseColors.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 14)
            .pulseGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(message)
                .font(PulseFont.footnote.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
                onConfirm()
            } label: {
                Label(confirmTitle, systemImage: confirmIcon)
                    .font(PulseFont.bodyEmphasis)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(.white)
                    .pulseGlass(Capsule(), interactive: true, tint: destructive ? PulseColors.danger : PulseColors.accent)
            }

            Button { dismiss() } label: {
                Text(cancelTitle)
                    .font(PulseFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(PulseColors.textPrimary)
                    .pulseGlass(Capsule(), interactive: true)
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
