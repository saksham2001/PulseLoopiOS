import SwiftUI
import SwiftData
import UIKit

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
            UINotificationFeedbackGenerator().notificationOccurred(.success)   // "activity logged" cue
            path.removeLast()
            path.append(AppRoute.activityDetail(session.id))
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
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
        .sensoryFeedback(.selection, trigger: selectedType)
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
                    .foregroundStyle(isSelected ? .white : PulseColors.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(isSelected ? Color.white.opacity(0.22) : PulseColors.cardSoft, in: Circle())
                Text(kind.label)
                    .font(PulseFont.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : PulseColors.textPrimary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(PulseColors.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous))
            // Selected = dim accent-tinted glass; others = plain glass.
            .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous),
                        interactive: true, tint: isSelected ? PulseColors.accentSoft : nil)
            .overlay(
                RoundedRectangle(cornerRadius: PulseRadius.compact, style: .continuous)
                    .strokeBorder(isSelected ? PulseColors.accent.opacity(0.9) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func row<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(PulseColors.accent)
                .frame(width: 24)
            Text(title)
                .font(PulseFont.subheadline)
                .foregroundStyle(PulseColors.textPrimary)
                .fixedSize()   // never wrap "Started" when the date/time chips are wide
            Spacer(minLength: 8)
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

    private var atFloor: Bool { minutes <= 5 }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                durationButton(systemImage: "minus", disabled: atFloor) { onChange(max(5, minutes - 5)) }
                    .accessibilityLabel("Decrease duration")
                    .accessibilityValue(durationText)
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
                    .accessibilityLabel("Increase duration")
                    .accessibilityValue(durationText)
            }

            HStack(spacing: 8) {
                ForEach(Self.quickDurations, id: \.self) { value in
                    let chipSelected = minutes == value
                    Button("\(value)m") { onChange(value) }
                        .font(PulseFont.caption.weight(.semibold))
                        .foregroundStyle(chipSelected ? PulseColors.accent : PulseColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(chipSelected ? PulseColors.accentSoft : PulseColors.cardSoft, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(chipSelected ? PulseColors.accent.opacity(0.9) : Color.clear, lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(value) minutes")
                        .accessibilityAddTraits(chipSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .sensoryFeedback(.selection, trigger: minutes)
        }
        .padding(16)
        .pulseGlass(RoundedRectangle(cornerRadius: PulseRadius.card, style: .continuous))
    }

    private func durationButton(systemImage: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(disabled ? PulseColors.textMuted : PulseColors.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())   // whole 44pt circle taps, not just the thin glyph
        }
        .buttonStyle(.plain)
        .background(PulseColors.cardSoft, in: Circle())
        .disabled(disabled)
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
