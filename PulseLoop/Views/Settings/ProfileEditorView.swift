import SwiftUI

struct ProfileEditorView: View {
    @Binding var draft: ProfileDraft
    @State private var activePicker: ProfilePickerKind?

    var body: some View {
        VStack(spacing: 16) {
            SectionHeader(title: "Units", action: nil)
            formCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Measurement units")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PulseColors.textPrimary)
                    Picker("Measurement units", selection: $draft.units) {
                        ForEach(UnitsPreference.allCases, id: \.self) { units in
                            Text(units.label).tag(units)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            SectionHeader(title: "Identity", action: nil)
            formCard {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Name")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer()
                        TextField("Optional", text: $draft.name)
                            .textInputAutocapitalization(.words)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(PulseColors.textPrimary)
                    }
                    .frame(minHeight: 44)

                    Divider().overlay(PulseColors.borderSubtle)

                    HStack(spacing: 12) {
                        Text("Sex")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(PulseColors.textPrimary)
                        Spacer(minLength: 8)
                        Picker("Sex", selection: $draft.sex) {
                            Text("Not set").tag(String?.none)
                            Text("Female").tag(String?.some("female"))
                            Text("Male").tag(String?.some("male"))
                            Text("Other").tag(String?.some("other"))
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 300)
                    }
                    .padding(.vertical, 10)
                }
            }

            SectionHeader(title: "Body metrics", action: "Optional")
            formCard {
                VStack(spacing: 0) {
                    pickerRow(
                        title: "Age",
                        value: draft.age.map { "\($0) years" },
                        kind: .age
                    )
                    Divider().overlay(PulseColors.borderSubtle)
                    pickerRow(
                        title: "Height",
                        value: heightLabel,
                        kind: .height
                    )
                    Divider().overlay(PulseColors.borderSubtle)
                    pickerRow(
                        title: "Weight",
                        value: weightLabel,
                        kind: .weight
                    )
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
        return "\(value) \(draft.units == .metric ? "kg" : "lb")"
    }

    private func formCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(PulseColors.borderSubtle, lineWidth: 1)
            )
    }

    private func pickerRow(title: String, value: String?, kind: ProfilePickerKind) -> some View {
        Button {
            activePicker = kind
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Spacer()
                Text(value ?? "Not set")
                    .font(.system(size: 14))
                    .foregroundStyle(value == nil ? PulseColors.textMuted : PulseColors.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PulseColors.textMuted)
            }
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
            let values = draft.units == .metric ? Array(35...250) : Array(77...551)
            IntegerPickerSheet(
                title: "Weight",
                values: values,
                initialValue: draft.weightDisplayValue,
                fallback: draft.units == .metric ? 70 : 154,
                label: { "\($0) \(draft.units == .metric ? "kg" : "lb")" },
                onSave: { draft.setWeight(displayValue: $0) }
            )
        }
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
