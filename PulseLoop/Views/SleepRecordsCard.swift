import SwiftUI
import SwiftData

/// The ring's own sleep records behind a merged night (Android #68/#71, delete from #78/#80).
///
/// A ring closes a record when the wearer gets up and opens a new one when they settle; merging
/// those is right — the headline stays the merged night — but the records are real information,
/// so they're listed underneath. Shown for single-record nights too, so any record can be managed.
/// Deleting one is the escape hatch for a ring that opened a record on a still wrist (an evening on
/// the sofa): the wearer knows which run is wrong, the sensor cannot.
struct SleepRecordsCard: View {
    @Environment(\.modelContext) private var modelContext
    let session: SleepSession
    let runs: [SleepRecordRun]

    /// The run whose trash button armed the confirmation.
    @State private var pendingDelete: SleepRecordRun?
    /// The run whose times are being edited.
    @State private var editing: SleepRecordEditTarget?
    @State private var failureMessage: String?

    var body: some View {
        SleepVisualizationCard(
            eyebrow: "Records",
            // One run happens on a carousel page too, which may be a nap rather than a night.
            title: runs.count == 1 ? "The ring recorded this as one record"
                : "The ring recorded this night in \(runs.count) parts",
            legend: false
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                    row(index: index, run: run)
                    let gap = index < runs.count - 1 ? SleepRecords.betweenRecordAwakeMinutes(run, runs[index + 1]) : 0
                    if gap > 0 {
                        Text("Awake \(SleepFormat.duration(gap)) between")
                            .font(PulseFont.caption)
                            .foregroundStyle(PulseColors.textMuted)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .alert("Delete this record?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { run in
            Button("Delete", role: .destructive) { delete(run) }
            Button("Keep", role: .cancel) {}
        } message: { run in
            Text("\(Self.range(run)) leaves tonight's totals and the hypnogram, and it won't come back on re-sync.")
        }
        .sheet(item: $editing) { target in
            SleepRecordEditSheet(target: target) { start, end in
                editing = nil
                if !SleepRecordEditor.edit(sessionId: session.id, recordStartAt: target.run.recordStartAt,
                                           newStart: start, newEnd: end, context: modelContext) {
                    failureMessage = "Couldn't update this record"
                }
            }
        }
        .alert(failureMessage ?? "", isPresented: Binding(
            get: { failureMessage != nil },
            set: { if !$0 { failureMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(index: Int, run: SleepRecordRun) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text("\(index + 1)")
                .font(PulseFont.caption2)
                .foregroundStyle(PulseColors.textMuted)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.range(run))
                    .font(PulseFont.subheadline)
                    .foregroundStyle(PulseColors.textPrimary)
                Text("Asleep \(SleepFormat.duration(run.asleepMinutes))")
                    .font(PulseFont.caption)
                    .foregroundStyle(PulseColors.textMuted)
                // Minutes the wearer added over time the ring missed (#106).
                if run.addedMinutes > 0 {
                    Text("Includes \(SleepFormat.duration(run.addedMinutes)) added by you, not staged or scored")
                        .font(PulseFont.caption)
                        .foregroundStyle(PulseColors.textMuted)
                }
            }
            Spacer(minLength: 4)
            iconButton("pencil", label: "Edit this record's times") {
                editing = SleepRecordEditTarget(
                    run: run,
                    limits: SleepRecordExtension.limits(
                        run: run,
                        previous: index > 0 ? runs[index - 1] : nil,
                        next: index + 1 < runs.count ? runs[index + 1] : nil,
                        wakingDay: session.date))
            }
            iconButton("trash", label: "Delete this record") { pendingDelete = run }
        }
        .accessibilityElement(children: .contain)
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(PulseColors.textMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func delete(_ run: SleepRecordRun) {
        pendingDelete = nil
        if !SleepRecordEditor.delete(sessionId: session.id, recordStartAt: run.recordStartAt, context: modelContext) {
            failureMessage = "Couldn't delete this record"
        }
    }

    static func range(_ run: SleepRecordRun) -> String {
        "\(SleepFormat.clockTime(run.startAt)) – \(SleepFormat.clockTime(run.endAt))"
    }
}

/// The record a sheet is editing, with the limits it's held to.
struct SleepRecordEditTarget: Identifiable {
    let run: SleepRecordRun
    let limits: RecordEditLimits
    var id: Int64 { SleepRecords.key(run.recordStartAt) }
}

/// Edit one record's start and end (Android #92/#130): trim it, or extend it over time the ring
/// missed. A pick past a limit is held at the limit and the limit is named, never silently snapped.
struct SleepRecordEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: SleepRecordEditTarget
    let onSave: (Date, Date) -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var limitMessage: String?

    init(target: SleepRecordEditTarget, onSave: @escaping (Date, Date) -> Void) {
        self.target = target
        self.onSave = onSave
        _start = State(initialValue: target.run.startAt)
        _end = State(initialValue: target.run.endAt)
    }

    private var changed: Bool { start != target.run.startAt || end != target.run.endAt }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: pick(isStart: true), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: pick(isStart: false), displayedComponents: .hourAndMinute)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let limitMessage {
                            Text(limitMessage).foregroundStyle(PulseColors.danger)
                        }
                        if start >= end {
                            Text("Start time must be before end time.").foregroundStyle(PulseColors.danger)
                        }
                        Text("Trim this record, or extend it over time the ring missed. Added time counts "
                             + "as asleep but has no stage, so it stays out of the stage breakdown and score.")
                    }
                }
            }
            .navigationTitle("Edit sleep record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(start, end) }
                        .disabled(start >= end || !changed)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// A picker binding that resolves the picked clock time to the right date around the record
    /// (crossing midnight either way), then holds it to the record's limits.
    private func pick(isStart: Bool) -> Binding<Date> {
        Binding(
            get: { isStart ? start : end },
            set: { picked in
                let calendar = Calendar.current
                let parts = calendar.dateComponents([.hour, .minute], from: picked)
                let limits = target.limits
                let resolved = SleepRecordExtension.resolveAdjustedTime(
                    target: isStart ? start : end, recordStart: limits.earliestStart, recordEnd: limits.latestEnd,
                    hour: parts.hour ?? 0, minute: parts.minute ?? 0, calendar: calendar)
                let clamped = isStart
                    ? SleepRecordExtension.clampStartPick(resolved, limits: limits)
                    : SleepRecordExtension.clampEndPick(resolved, limits: limits)
                limitMessage = clamped.limit.map {
                    SleepRecordExtension.limitMessage($0, isStart: isStart, at: clamped.at, limits: limits)
                }
                if isStart { start = clamped.at } else { end = clamped.at }
            }
        )
    }
}
