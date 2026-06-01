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
                        Text(String(format: "%.2f km", distance / 1000))
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
    @Query private var sessions: [ActivitySession]
    let sessionId: UUID

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext)
            let hr = sessionHRSamples(session.id, context: modelContext)
            ScrollView {
                VStack(spacing: 16) {
                    activityHeader(session)
                    statsGrid(session)
                    if session.useGps {
                        WorkoutMapView(points: points, unavailable: false)
                    }
                    if hr.count > 1 {
                        hrCard(hr)
                    }
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
                }
                .padding(16)
                .padding(.bottom, 32)
            }
            .background(PulseColors.background)
        } else {
            EmptyStateView(title: "Workout not found", body: "This session is no longer in local storage.")
        }
    }

    private func activityHeader(_ session: ActivitySession) -> some View {
        VStack(spacing: 8) {
            Image(systemName: ActivityMeta.icon(session.type))
                .font(.system(size: 34))
                .foregroundStyle(PulseColors.accent)
                .frame(width: 72, height: 72)
                .background(PulseColors.accentSoft, in: Circle())
            Text(ActivityMeta.label(session.type))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(PulseColors.textPrimary)
            Text(session.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                .font(.system(size: 13))
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func statsGrid(_ session: ActivitySession) -> some View {
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            WorkoutStat(label: "Duration", value: duration.map { ActivityMeta.duration($0) } ?? "—")
            WorkoutStat(label: "Distance", value: session.distanceMeters.map { String(format: "%.2f km", $0 / 1000) } ?? "—")
            WorkoutStat(label: "Avg HR", value: session.avgHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Max HR", value: session.maxHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Min HR", value: session.minHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "SpO₂", value: session.latestSpO2.map { "\(Int($0))%" } ?? "—")
        }
    }

    private func hrCard(_ hr: [MetricSample]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEART RATE").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
            HRLineChart(samples: hr, height: 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }
}

// MARK: - Record: select activity

struct RecordSelectView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(GpsRouteRecorder.self) private var gps
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
                    let session = ActivityRecorderService.start(type: selected, useGps: willUseGps, notes: nil, context: modelContext)
                    coordinator.startWorkoutHeartRate()
                    if willUseGps { gps.start(sessionId: session.id) }
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
    @Environment(GpsRouteRecorder.self) private var gps
    @Query private var sessions: [ActivitySession]
    let sessionId: UUID
    @Binding var path: NavigationPath
    @State private var confirmFinish = false
    @State private var confirmDiscard = false

    var body: some View {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext)
            TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                let elapsedSec = elapsed(session: session, now: timeline.date)
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: ActivityMeta.icon(session.type)).foregroundStyle(PulseColors.accent)
                                Text("\(session.status == .paused ? "Paused" : "Recording") \(ActivityMeta.label(session.type))")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(PulseColors.textPrimary)
                            }
                            Text(subtitle(session))
                                .font(.system(size: 11)).foregroundStyle(PulseColors.textMuted)
                        }
                        .padding(.top, 8)

                        VStack(spacing: 6) {
                            Text(ActivityMeta.duration(elapsedSec))
                                .font(.system(size: 60, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(PulseColors.textPrimary)
                            Text("DURATION").font(.system(size: 11, weight: .medium)).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                        }
                        .padding(.vertical, 8)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            LiveStatTile(value: distanceLabel(points: points, session: session), label: "Distance", muted: !session.useGps)
                            LiveStatTile(value: coordinator.latestHRValue.map { "\($0) bpm" } ?? "—", label: "Last HR", muted: coordinator.latestHRValue == nil)
                            LiveStatTile(value: coordinator.latestSpO2Value.map { "\($0)%" } ?? "—", label: "Last SpO₂", muted: coordinator.latestSpO2Value == nil)
                            LiveStatTile(value: paceLabel(points: points, elapsedSec: elapsedSec, session: session), label: "Pace", muted: !session.useGps)
                        }

                        WorkoutMapView(points: points, unavailable: !session.useGps || gps.isPermissionDenied, height: 200)

                        if session.useGps && gps.isPermissionDenied {
                            Text("Location access is denied — enable it in Settings to record your route.")
                                .font(.caption).foregroundStyle(PulseColors.warning).multilineTextAlignment(.center)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 12)
                }
                .background(PulseColors.background)
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        SecondaryButton(title: session.status == .paused ? "Resume" : "Pause", systemImage: session.status == .paused ? "play.fill" : "pause.fill") {
                            if session.status == .paused {
                                ActivityRecorderService.resume(session, context: modelContext)
                                if session.useGps { gps.start(sessionId: session.id) }
                            } else {
                                ActivityRecorderService.pause(session, context: modelContext)
                                gps.stop()
                            }
                        }
                        PrimaryButton(title: "Finish", systemImage: "flag.checkered") { confirmFinish = true }
                    }
                    .padding(16)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationBarBackButtonHidden(true)
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
        coordinator.stopWorkoutHeartRate()
        gps.stop()
        ActivityRecorderService.finish(session, context: modelContext)
        // Replace the live screen with the summary so back/Done returns to the Activity tab,
        // not into the finished recording.
        path.removeLast(path.count)
        path.append(AppRoute.recordSummary(session.id))
    }

    private func discard(_ session: ActivitySession) {
        coordinator.stopWorkoutHeartRate()
        gps.stop()
        ActivityRecorderService.cancel(session, context: modelContext)
        path.removeLast(path.count)
    }

    private func subtitle(_ session: ActivitySession) -> String {
        let gpsPart = session.useGps ? (gps.isPermissionDenied ? "GPS unavailable" : "GPS active") : "No GPS"
        return "\(gpsPart) · HR live"
    }

    private func distanceLabel(points: [ActivityGpsPoint], session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        let meters = routeDistance(points)
        return meters > 0 ? String(format: "%.2f km", meters / 1000) : "—"
    }

    private func paceLabel(points: [ActivityGpsPoint], elapsedSec: Int, session: ActivitySession) -> String {
        guard session.useGps else { return "—" }
        return ActivityMeta.pace(distanceMeters: routeDistance(points), durationSeconds: elapsedSec) ?? "—"
    }

    private func routeDistance(_ points: [ActivityGpsPoint]) -> Double {
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return 0 }
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            total + haversine(pair.0, pair.1)
        }
    }

    private func haversine(_ a: ActivityGpsPoint, _ b: ActivityGpsPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dPhi / 2) * sin(dPhi / 2) + cos(p1) * cos(p2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    private func elapsed(session: ActivitySession, now: Date) -> Int {
        max(0, Int((session.endedAt ?? now).timeIntervalSince(session.startedAt) - session.totalPauseSeconds))
    }
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
            let points = ActivityRepository.gpsPoints(sessionId: session.id, context: modelContext)
            let hr = sessionHRSamples(session.id, context: modelContext)
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: ActivityMeta.icon(session.type))
                            .font(.system(size: 34)).foregroundStyle(PulseColors.accent)
                            .frame(width: 72, height: 72).background(PulseColors.accentSoft, in: Circle())
                        Text("WORKOUT SAVED").font(.system(size: 11, weight: .medium)).tracking(1.8).foregroundStyle(PulseColors.accent)
                        Text(ActivityMeta.label(session.type)).font(.system(size: 24, weight: .semibold)).foregroundStyle(PulseColors.textPrimary)
                    }
                    .padding(.top, 8)

                    statsGrid(session)

                    if session.useGps {
                        WorkoutMapView(points: points)
                    }

                    if hr.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HEART RATE").font(.system(size: 11, weight: .medium)).tracking(1.0).foregroundStyle(PulseColors.textMuted)
                            HRLineChart(samples: hr, height: 120)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(PulseColors.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
                    }

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

    private func statsGrid(_ session: ActivitySession) -> some View {
        let duration = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt) - session.totalPauseSeconds) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            WorkoutStat(label: "Duration", value: duration.map { ActivityMeta.duration($0) } ?? "—")
            WorkoutStat(label: "Distance", value: session.distanceMeters.map { String(format: "%.2f km", $0 / 1000) } ?? "—")
            WorkoutStat(label: "Avg HR", value: session.avgHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Max HR", value: session.maxHeartRate.map { "\(Int($0))" } ?? "—")
            WorkoutStat(label: "Active min", value: duration.map { "\($0 / 60)" } ?? "—")
            WorkoutStat(label: "SpO₂", value: session.latestSpO2.map { "\(Int($0))%" } ?? "—")
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
