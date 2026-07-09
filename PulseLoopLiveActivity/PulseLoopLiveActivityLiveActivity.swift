//
//  PulseLoopLiveActivityLiveActivity.swift
//  PulseLoopLiveActivity
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Widget

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock Screen / banner. Kept deliberately simple + high-contrast (white on black)
            // to guarantee it renders in the Live Activity environment.
            WorkoutLockScreenView(context: context)
                .widgetURL(URL(string: "pulseloop://workout/\(context.attributes.sessionID)"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.activityName, systemImage: WorkoutLAColors.icon(for: state.activityType))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.lastHeartRate.map { "\($0) bpm" } ?? "—")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.center) {
                    elapsedTimer(state)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if state.status == "finished" {
                            Text("Complete").foregroundStyle(.green)
                            Spacer()
                            if state.usesGps {
                                Text(WorkoutLAColors.distanceLabel(state.distanceMeters, imperial: state.useImperial))
                                    .foregroundStyle(.blue)
                            }
                            Text(state.avgHeartRate.map { "avg \($0) bpm" } ?? "")
                                .foregroundStyle(.pink)
                        } else {
                            if state.usesGps {
                                Text(WorkoutLAColors.distanceLabel(state.distanceMeters, imperial: state.useImperial))
                                    .foregroundStyle(.blue)
                            } else {
                                Text(state.lastSpO2.map { "SpO₂ \($0)%" } ?? "SpO₂ —")
                                    .foregroundStyle(WorkoutLAColors.spo2)
                            }
                            Spacer()
                            Text(state.status == "paused" ? "Paused"
                                 : (state.usesGps ? WorkoutLAColors.paceLabel(state.paceSecondsPerKm, imperial: state.useImperial) : ""))
                                .foregroundStyle(.white)
                        }
                    }
                    .font(.caption).monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: WorkoutLAColors.icon(for: state.activityType))
                    .foregroundStyle(.purple)
            } compactTrailing: {
                if let hr = state.lastHeartRate {
                    Text("\(hr)").font(.caption2).monospacedDigit().foregroundStyle(.white)
                } else {
                    elapsedTimer(state).font(.caption2).monospacedDigit().foregroundStyle(.white)
                }
            } minimal: {
                Image(systemName: WorkoutLAColors.icon(for: state.activityType))
                    .foregroundStyle(.purple)
            }
            .widgetURL(URL(string: "pulseloop://workout/\(context.attributes.sessionID)"))
            .keylineTint(.purple)
        }
    }
}

// MARK: - Lock Screen

struct WorkoutLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        let state = context.state
        let isPaused = state.status == "paused"
        let isFinished = state.status == "finished"
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isFinished ? "flag.checkered" : WorkoutLAColors.icon(for: state.activityType))
                        .foregroundStyle(isFinished ? .green : .purple)
                    Text(context.attributes.activityName)
                        .font(.headline)
                    if isPaused {
                        Text("· Paused").font(.subheadline).foregroundStyle(.secondary)
                    } else if isFinished {
                        Text("· Complete").font(.subheadline).foregroundStyle(.green)
                    }
                }
                elapsedTimer(state)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                // Distance is only meaningful for GPS activities; indoor shows HR/SpO₂ only.
                if state.usesGps {
                    metric("DIST", WorkoutLAColors.distanceLabel(state.distanceMeters, imperial: state.useImperial), .blue)
                }
                if isFinished {
                    // Final card: the session average, not a stale "last" reading.
                    metric("AVG HR", state.avgHeartRate.map { "\($0) bpm" } ?? "—", .pink)
                } else {
                    metric("HR", state.lastHeartRate.map { "\($0) bpm" } ?? "—", .pink)
                    metric("SpO₂", state.lastSpO2.map { "\($0)%" } ?? "—", .cyan)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
    }
}

// MARK: - Helpers

/// Self-counting elapsed timer. `Text(timerInterval:)` ticks in the system process, so it keeps
/// counting on the Lock Screen / Dynamic Island even when the app is backgrounded and pushing no
/// updates. `startDate` already excludes paused time; while paused, `pauseTime` freezes the display.
/// A finished workout shows its final duration as static text — the self-counting interval would
/// otherwise keep ticking on the "complete" card.
func elapsedTimer(_ state: WorkoutActivityAttributes.ContentState) -> Text {
    if state.status == "finished" {
        return Text(formatDuration(state.elapsedSeconds))
    }
    return Text(timerInterval: state.startDate...state.startDate.addingTimeInterval(48 * 3600),
                pauseTime: state.status == "paused" ? state.pausedAt : nil,
                countsDown: false)
}

/// h:mm:ss / m:ss for the frozen final duration (the widget can't see the app-only `ActivityMeta`).
func formatDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - Previews

extension WorkoutActivityAttributes {
    fileprivate static var preview: WorkoutActivityAttributes {
        WorkoutActivityAttributes(sessionID: "preview-session", activityName: "Morning Run")
    }
}

extension WorkoutActivityAttributes.ContentState {
    fileprivate static var recording: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            status: "recording",
            elapsedSeconds: 1325,
            startDate: Date().addingTimeInterval(-1325),
            pausedAt: nil,
            usesGps: true,
            distanceMeters: 3450,
            paceSecondsPerKm: 312,
            lastHeartRate: 152,
            lastSpO2: 98,
            activityType: "run",
            lastUpdated: Date()
        )
    }
    fileprivate static var paused: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            status: "paused",
            elapsedSeconds: 1325,
            startDate: Date().addingTimeInterval(-1325),
            pausedAt: Date(),
            usesGps: true,
            distanceMeters: 3450,
            paceSecondsPerKm: 312,
            lastHeartRate: 138,
            lastSpO2: 97,
            activityType: "run",
            lastUpdated: Date()
        )
    }
    fileprivate static var indoor: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            status: "recording",
            elapsedSeconds: 640,
            startDate: Date().addingTimeInterval(-640),
            pausedAt: nil,
            usesGps: false,
            distanceMeters: 0,
            paceSecondsPerKm: nil,
            lastHeartRate: 121,
            lastSpO2: 97,
            activityType: "gym",
            lastUpdated: Date()
        )
    }
}

#Preview("Lock Screen", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivityWidget()
} contentStates: {
    WorkoutActivityAttributes.ContentState.recording
    WorkoutActivityAttributes.ContentState.paused
    WorkoutActivityAttributes.ContentState.indoor
}
