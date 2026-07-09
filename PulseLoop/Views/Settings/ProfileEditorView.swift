import SwiftUI

struct ProfileEditorView: View {
    @Binding var draft: ProfileDraft
    @State private var activePicker: ProfilePickerKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(header: "Identity") {
                FormValueRow(title: "Name") {
                    TextField("Optional", text: $draft.name)
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(PulseColors.textPrimary)
                }
            }

            SettingsGroup(header: "Sex", footer: "Optional") {
                FormField {
                    Picker("Sex", selection: $draft.sex) {
                        Text("Not set").tag(String?.none)
                        Text("Male").tag(String?.some("male"))
                        Text("Female").tag(String?.some("female"))
                        Text("Other").tag(String?.some("other"))
                    }
                    .pickerStyle(.segmented)
                }
            }

            SettingsGroup(header: "Body metrics", footer: "Optional") {
                pickerRow(
                    title: "Age",
                    value: draft.age.map { "\($0) years" },
                    kind: .age
                )
                pickerRow(
                    title: "Height",
                    value: heightLabel,
                    kind: .height
                )
                pickerRow(
                    title: "Weight",
                    value: weightLabel,
                    kind: .weight
                )
            }

            SettingsGroup(header: "Measurement") {
                FormField {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Measurement units")
                            .font(PulseFont.subheadline)
                            .foregroundStyle(PulseColors.textPrimary)
                        Picker("Measurement units", selection: $draft.units) {
                            ForEach(UnitsPreference.allCases, id: \.self) { units in
                                Text(units.label).tag(units)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
        .sheet(item: $activePicker) { kind in
            pickerSheet(for: kind)
        }
    }

    private var heightLabel: String? {
        guard let value = draft.heightDisplayValue else { return nil }
        if draft.units == .metric { return "\(value) cm" }
        return "\(value / 12)' \(value % 12)\""
    }

    private var weightLabel: String? {
        guard let value = draft.weightDisplayValue else { return nil }
        return "\(LocalizedDecimalInput.format(value)) \(draft.units == .metric ? "kg" : "lb")"
    }

    private func pickerRow(title: String, value: String?, kind: ProfilePickerKind) -> some View {
        Button {
            activePicker = kind
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(PulseFont.body)
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text(value ?? "Not set")
                    .font(PulseFont.subheadline.weight(.regular))
                    .foregroundStyle(value == nil ? PulseColors.textMuted : PulseColors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(PulseFont.caption2.weight(.semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(value ?? "Not set")
    }

    @ViewBuilder
    private func pickerSheet(for kind: ProfilePickerKind) -> some View {
        switch kind {
        case .age:
            IntegerPickerSheet(
                title: "Age",
                values: Array(13...100),
                initialValue: draft.age,
                fallback: 30,
                label: { "\($0) years" },
                onSave: { draft.age = $0 }
            )
        case .height:
            let values = draft.units == .metric ? Array(120...220) : Array(48...87)
            IntegerPickerSheet(
                title: "Height",
                values: values,
                initialValue: draft.heightDisplayValue,
                fallback: draft.units == .metric ? 175 : 69,
                label: { value in
                    draft.units == .metric ? "\(value) cm" : "\(value / 12)' \(value % 12)\""
                },
                onSave: { draft.setHeight(displayValue: $0) }
            )
        case .weight:
            DecimalValueSheet(
                title: "Weight",
                initialValue: draft.weightDisplayValue,
                unit: draft.units == .metric ? "kg" : "lb",
                validRange: draft.units == .metric ? 35...250 : 77...551,
                onSave: { draft.setWeight(displayValue: $0) }
            )
        }
    }
}

private struct DecimalValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var text: String

    let title: String
    let unit: String
    let validRange: ClosedRange<Double>
    let onSave: (Double?) -> Void

    init(
        title: String,
        initialValue: Double?,
        unit: String,
        validRange: ClosedRange<Double>,
        onSave: @escaping (Double?) -> Void
    ) {
        self.title = title
        self.unit = unit
        self.validRange = validRange
        self.onSave = onSave
        _text = State(initialValue: initialValue.map { LocalizedDecimalInput.format($0) } ?? "")
    }

    private var parsedValue: Double? {
        guard let value = LocalizedDecimalInput.parse(text), validRange.contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter your weight in \(unit)")
                    .font(PulseFont.subheadline)
                    .foregroundStyle(PulseColors.textPrimary)

                SettingsCard(cornerRadius: 14, padding: 14) {
                    TextField(LocalizedDecimalInput.format(70.5), text: $text)
                        .keyboardType(.decimalPad)
                        .focused($fieldFocused)
                        .font(PulseFont.numberL)
                }
                .accessibilityLabel("Weight in \(unit)")

                Text("You can use either a comma or a period as the decimal separator.")
                    .font(.caption)
                    .foregroundStyle(PulseColors.textMuted)

                if !text.isEmpty && parsedValue == nil {
                    Text("Enter a weight between \(Int(validRange.lowerBound)) and \(Int(validRange.upperBound)) \(unit).")
                        .font(.caption)
                        .foregroundStyle(PulseColors.danger)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(PulseColors.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        onSave(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(parsedValue)
                        dismiss()
                    }
                    .disabled(parsedValue == nil)
                }
            }
            .onAppear { fieldFocused = true }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

private enum ProfilePickerKind: String, Identifiable {
    case age
    case height
    case weight

    var id: String { rawValue }
}

private struct IntegerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    let title: String
    let values: [Int]
    let label: (Int) -> String
    let onSave: (Int?) -> Void

    init(
        title: String,
        values: [Int],
        initialValue: Int?,
        fallback: Int,
        label: @escaping (Int) -> String,
        onSave: @escaping (Int?) -> Void
    ) {
        self.title = title
        self.values = values
        self.label = label
        self.onSave = onSave
        _selection = State(initialValue: initialValue ?? fallback)
    }

    var body: some View {
        NavigationStack {
            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        onSave(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(selection)
                        dismiss()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
    }
}
