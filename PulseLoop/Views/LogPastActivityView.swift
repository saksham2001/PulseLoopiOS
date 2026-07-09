import SwiftUI
import SwiftData

struct LogPastActivityView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding private var path: NavigationPath

    @State private var selectedType = "run"
    @State private var startedAt: Date
    @State private var durationMinutes = 60
    @State private var saveError: String?

    /// A stable picker range prevents SwiftUI from reconfiguring UIKit's date picker on every
    /// state update. A past-workout form does not need its upper bound to move while it is open.
    private let maximumDate: Date

    init(path: Binding<NavigationPath>) {
        let now = Date()
        _path = path
        _startedAt = State(initialValue: now.addingTimeInterval(-3600))
        maximumDate = now
    }

    var body: some View {
        let endedAt = startedAt.addingTimeInterval(Double(durationMinutes) * 60)
        let isValid = durationMinutes > 0 && endedAt <= maximumDate

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LogPastActivityHeader()

                FormSectionLabel("Activity type")
                ActivityTypeGrid(selectedType: selectedType) { type in
                    selectedType = type
                    saveError = nil
                }
                .equatable()

                FormSectionLabel("When")
                PastActivityTimeCard(
                    startedAt: $startedAt,
                    endedAt: endedAt,
                    maximumDate: maximumDate,
                    isValid: isValid
                )
                .onChange(of: startedAt) { _, _ in saveError = nil }

                FormSectionLabel("Duration")
                PastActivityDurationCard(minutes: durationMinutes) { newValue in
                    durationMinutes = newValue
                    saveError = nil
                }
                .equatable()

                FormMessages(isValid: isValid, saveError: saveError)
                    .equatable()

                PrimaryButton(title: "Log Activity", systemImage: "checkmark") {
                    save()
                }
                .disabled(!isValid)
                .opacity(isValid ? 1 : 0.45)
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .background(PulseColors.background.ignoresSafeArea())
        .pageChrome("Log Past Activity")
    }

    private func save() {
        do {
            let session = try ManualActivityService.create(
                type: selectedType,
                startedAt: startedAt,
                durationMinutes: Double(durationMinutes),
                context: modelContext
            )
            path.removeLast()
            path.append(AppRoute.activityDetail(session.id))
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct LogPastActivityHeader: View, Equatable {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What did you do?")
                .font(PulseFont.title2.weight(.bold))
                .foregroundStyle(PulseColors.textPrimary)
            Text("Choose an activity, when it started, and how long it lasted.")
                .font(PulseFont.subheadline.weight(.regular))
                .foregroundStyle(PulseColors.textMuted)
        }
    }
}

private struct FormSectionLabel: View, Equatable {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(PulseFont.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(PulseColors.textMuted)
    }
}

private struct ActivityTypeGrid: View, Equatable {
    private static let rows: [[ActivityKind]] = stride(from: 0, to: ActivityMeta.allKinds.count, by: 2).map { index in
        Array(ActivityMeta.allKinds[index..<min(index + 2, ActivityMeta.allKinds.count)])
    }

    let selectedType: String
    let onSelect: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedType == rhs.selectedType
    }

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(Self.rows[rowIndex]) { kind in
                        ActivityTypeButton(
                            kind: kind,
                            isSelected: kind.type == selectedType,
                            onSelect: onSelect
                        )
                    }
                }
            }
        }
    }
}

private struct ActivityTypeButton: View, Equatable {
    let kind: ActivityKind
    let isSelected: Bool
    let onSelect: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind.id == rhs.kind.id && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        Button { onSelect(kind.type) } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(PulseFont.title3.weight(.regular))
                    .foregroundStyle(isSelected ? PulseColors.accent : PulseColors.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(isSelected ? PulseColors.accentSoft : PulseColors.cardSoft, in: Circle())
                Text(kind.label)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            // Selected = accent-tinted glass; others = plain glass.
            .pulseGlass(RoundedRectangle(cornerRadius: 18, style: .continuous),
                        interactive: true, tint: isSelected ? PulseColors.accent : nil)
        }
        .buttonStyle(.plain)
    }
}

private struct PastActivityTimeCard: View {
    @Binding var startedAt: Date
    let endedAt: Date
    let maximumDate: Date
    let isValid: Bool

    var body: some View {
        VStack(spacing: 0) {
            row(title: "Started", systemImage: "calendar") {
                DatePicker(
                    "Started",
                    selection: $startedAt,
                    in: ...maximumDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .tint(PulseColors.accent)
            }
            Divider().overlay(PulseColors.borderSubtle).padding(.leading, 52)
            row(title: "Ends", systemImage: "clock") {
                Text(endedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(PulseFont.subheadline)
                    .foregroundStyle(isValid ? PulseColors.textSecondary : PulseColors.warning)
            }
        }
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(PulseColors.accent)
                .frame(width: 24)
            Text(title)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }
}

private struct PastActivityDurationCard: View, Equatable {
    private static let quickDurations = [15, 30, 45, 60, 90]

    let minutes: Int
    let onChange: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.minutes == rhs.minutes }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                durationButton(systemImage: "minus") { onChange(max(5, minutes - 5)) }
                Spacer()
                VStack(spacing: 2) {
                    Text(durationText)
                        .font(PulseFont.title)
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                    Text("DURATION")
                        .font(PulseFont.micro)
                        .tracking(1.1)
                        .foregroundStyle(PulseColors.textMuted)
                }
                Spacer()
                durationButton(systemImage: "plus") { onChange(minutes + 5) }
            }

            HStack(spacing: 8) {
                ForEach(Self.quickDurations, id: \.self) { value in
                    Button("\(value)m") { onChange(value) }
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(minutes == value ? Color.white : PulseColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(minutes == value ? PulseColors.accent : PulseColors.cardSoft, in: Capsule())
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func durationButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PulseColors.textPrimary)
        .background(PulseColors.cardSoft, in: Circle())
    }

    private var durationText: String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 { return "\(remainingMinutes) min" }
        if remainingMinutes == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainingMinutes) min"
    }
}

private struct FormMessages: View, Equatable {
    let isValid: Bool
    let saveError: String?

    var body: some View {
        Group {
            if !isValid {
                Label("The workout must finish before now.", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(PulseColors.warning)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(PulseColors.danger)
            }
        }
        .font(PulseFont.footnote)
    }
}
