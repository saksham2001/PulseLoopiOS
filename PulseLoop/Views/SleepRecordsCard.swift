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
            }
            Spacer(minLength: 4)
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
