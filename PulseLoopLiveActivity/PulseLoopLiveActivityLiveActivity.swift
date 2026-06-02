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
                    Text(durationLabel(state.elapsedSeconds))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(WorkoutLAColors.distanceLabel(state.distanceMeters))
                            .foregroundStyle(.blue)
                        Spacer()
                        Text(state.status == "paused" ? "Paused" : WorkoutLAColors.paceLabel(state.paceSecondsPerKm))
                            .foregroundStyle(.white)
                    }
                    .font(.caption).monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: WorkoutLAColors.icon(for: state.activityType))
                    .foregroundStyle(.purple)
            } compactTrailing: {
                Text(state.lastHeartRate.map { "\($0)" } ?? durationLabel(state.elapsedSeconds))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.white)
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: WorkoutLAColors.icon(for: state.activityType))
                        .foregroundStyle(.purple)
                    Text(context.attributes.activityName)
                        .font(.headline)
                    if isPaused {
                        Text("· Paused").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(durationLabel(state.elapsedSeconds))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                metric("DIST", WorkoutLAColors.distanceLabel(state.distanceMeters), .blue)
                metric("HR", state.lastHeartRate.map { "\($0) bpm" } ?? "—", .pink)
                metric("SpO₂", state.lastSpO2.map { "\($0)%" } ?? "—", .cyan)
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

/// H:MM:SS / M:SS elapsed label. Static (re-rendered on each Live Activity content push) — avoids
/// the `Text(timerInterval:)` API which was rendering blank in this Live Activity.
func durationLabel(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
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
        WorkoutActivityAttributes.ContentState(status: "recording", elapsedSeconds: 1325, distanceMeters: 3450, paceSecondsPerKm: 312, lastHeartRate: 152, lastSpO2: 98, activityType: "run", lastUpdated: Date())
    }
    fileprivate static var paused: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(status: "paused", elapsedSeconds: 1325, distanceMeters: 3450, paceSecondsPerKm: 312, lastHeartRate: 138, lastSpO2: 97, activityType: "run", lastUpdated: Date())
    }
}

#Preview("Lock Screen", as: .content, using: WorkoutActivityAttributes.preview) {
    WorkoutLiveActivityWidget()
} contentStates: {
    WorkoutActivityAttributes.ContentState.recording
    WorkoutActivityAttributes.ContentState.paused
}
