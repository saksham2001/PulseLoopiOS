import SwiftUI
import SwiftData

/// The intraday activity records behind the shown day's total, each deletable (issue #70).
///
/// The counterpart to a vital's READINGS list: a ring logs activity in blocks, so a block inflated by
/// carrying the ring rather than wearing it is otherwise stuck in the day's total. Deletion only,
/// behind a confirmation that says how far the total drops. Collapsed by default and paged.
struct ActivityRecordsCard: View {
    let day: Date
    let units: UnitsPreference
    @Environment(\.modelContext) private var modelContext
    @State private var dataChange = PulseDataChange.shared
    @State private var expanded = false
    @State private var records: [ActivityBucketDeletion.Record] = []
    @State private var visible = Self.pageSize
    @State private var pending: ActivityBucketDeletion.Record?
    @State private var pendingTotals: (before: Int, after: Int) = (0, 0)

    private static let pageSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(PulseMotion.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("RECORDS").font(PulseFont.caption2).tracking(1.4).foregroundStyle(PulseColors.textMuted)
                    Spacer()
                    Text("\(records.count)").font(PulseFont.caption).monospacedDigit().foregroundStyle(PulseColors.textMuted)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(PulseColors.textMuted)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activity records, \(records.count)")
            .accessibilityHint(expanded ? "Hides the records" : "Shows the records")

            if expanded {
                if records.isEmpty {
                    Text("No activity records synced for this day.")
                        .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textMuted)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(records.prefix(visible)) { record in row(record) }
                    }
                    if records.count > visible {
                        Button("Show \(min(Self.pageSize, records.count - visible)) more") { visible += Self.pageSize }
                            .font(PulseFont.footnote.weight(.semibold))
                            .foregroundStyle(PulseColors.accent)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    Spacer().frame(height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: day) { visible = Self.pageSize; reload() }
        .onChange(of: dataChange.token) { _, _ in reload() }
        .alert("Delete this activity record?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending) { record in
            Button("Delete", role: .destructive) { delete(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("\(record.steps.formatted()) steps at \(time(record)).\n\n"
                 + "The day's total drops by \((pendingTotals.before - pendingTotals.after).formatted()) steps, "
                 + "from \(pendingTotals.before.formatted()) to \(pendingTotals.after.formatted()). "
                 + "This can't be undone, and the record stays deleted the next time this day syncs.")
        }
    }

    private func row(_ record: ActivityBucketDeletion.Record) -> some View {
        HStack(spacing: 6) {
            Text(time(record))
                .font(PulseFont.footnote.weight(.regular)).foregroundStyle(PulseColors.textSecondary)
            Spacer(minLength: 8)
            Text("\(record.steps.formatted()) steps")
                .font(PulseFont.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(PulseColors.textPrimary)
            if record.distanceMeters > 0 {
                let d = UnitsFormatter.distance(meters: record.distanceMeters, units: units)
                Text("· \(d.value) \(d.unit)")
                    .font(PulseFont.caption2.weight(.regular)).foregroundStyle(PulseColors.textMuted)
            }
            Button {
                pendingTotals = ActivityBucketDeletion.stepsAfterDeleting(record, context: modelContext)
                pending = record
            } label: {
                Image(systemName: "trash")
                    .font(PulseFont.footnote)
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete record, \(record.steps) steps at \(time(record))")
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .accessibilityElement(children: .contain)
    }

    private func time(_ record: ActivityBucketDeletion.Record) -> String {
        record.timestamp.formatted(date: .omitted, time: .shortened)
    }

    private func reload() {
        records = ActivityBucketDeletion.records(on: day, context: modelContext)
    }

    private func delete(_ record: ActivityBucketDeletion.Record) {
        ActivityBucketDeletion.delete(startEpoch: record.startEpoch, context: modelContext)
        pending = nil
        reload()
    }
}
