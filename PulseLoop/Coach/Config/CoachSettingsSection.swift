import SwiftUI
import SwiftData

/// "AI Coach" block for `SettingsView`: provider mode, model, OpenAI key
/// (stored in Keychain), action/measurement toggles, and saved coach memory.
/// Daily check-in notifications live in `NotificationsSettingsView`. Visuals
/// reuse the existing design system.
struct CoachSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CoachMemory.importance, order: .reverse) private var memories: [CoachMemory]
    @State private var store = CoachSettingsStore.shared
    private let keyStore = OpenAIKeychainStore()

    @State private var keyDraft: String = ""
    @State private var hasSavedKey: Bool = false
    @State private var showKey: Bool = false
    @State private var keyError: String?

    private var flags: CoachFeatureFlags {
        CoachFeatureFlags(settings: store.settings, hasAPIKey: hasSavedKey)
    }

    var body: some View {
        SectionHeader(title: "AI Coach", action: nil)
        StatusCopy(title: "Status", body: flags.statusLine)
        toggleRow("Enable AI Coach", isOn: masterEnabledBinding)

        if store.settings.coachMasterEnabled {
            labeledRow("Provider") {
                Picker("Provider", selection: providerBinding) {
                    ForEach(CoachProviderMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(PulseColors.accent)
            }

            labeledRow("Model") {
                Picker("Model", selection: modelBinding) {
                    ForEach(CoachModel.allCases) { model in
                        Text(model.label).tag(model.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(PulseColors.accent)
            }

            if store.settings.providerMode == .userOpenAIKey {
                keyField
            }

            toggleRow("Web search", isOn: webSearchBinding)
            toggleRow("AI actions (set goals, log, edit)", isOn: writeToolsBinding)
            toggleRow("Live ring measurements", isOn: liveMeasurementsBinding)

            if !memories.isEmpty {
                SectionHeader(title: "Coach memory", action: nil)
                ForEach(memories) { memory in memoryRow(memory) }
            }
        }
    }

    private func memoryRow(_ memory: CoachMemory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.key)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PulseColors.textPrimary)
                Text(memory.value)
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textSecondary)
                Text(memory.memoryType.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 9, weight: .medium)).tracking(0.6)
                    .foregroundStyle(PulseColors.textMuted)
            }
            Spacer(minLength: 8)
            Button {
                modelContext.delete(memory)
                try? modelContext.save()
            } label: {
                Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(PulseColors.danger)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Key field

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $keyDraft)
                    } else {
                        SecureField("sk-…", text: $keyDraft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(PulseColors.cardSoft, in: Capsule())
                .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))

                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                QuickActionButton(label: hasSavedKey ? "Update key" : "Save key", accent: true) { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSavedKey {
                    QuickActionButton(label: "Remove") { removeKey() }
                }
            }

            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(PulseColors.danger)
            } else {
                Text("Stored only in your device Keychain. Used to call OpenAI directly.")
                    .font(.caption).foregroundStyle(PulseColors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
        .onAppear(perform: refreshKeyState)
    }

    // MARK: - Small layout helpers

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
        }
        .tint(PulseColors.accent)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Bindings

    private var masterEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.coachMasterEnabled },
            set: { newValue in
                store.settings.coachMasterEnabled = newValue
                if !newValue {
                    // Tear down anything scheduled so a future re-enable starts clean.
                    CoachNotificationScheduler.shared.cancel()
                } else if store.settings.notificationsEnabled {
                    CoachNotificationScheduler.shared.scheduleNext()
                }
            }
        )
    }

    private var providerBinding: Binding<CoachProviderMode> {
        Binding(get: { store.settings.providerMode }, set: { store.settings.providerMode = $0 })
    }
    private var modelBinding: Binding<String> {
        Binding(get: { store.settings.model }, set: { store.settings.model = $0 })
    }
    private var webSearchBinding: Binding<Bool> {
        Binding(get: { store.settings.enableWebSearch }, set: { store.settings.enableWebSearch = $0 })
    }
    private var writeToolsBinding: Binding<Bool> {
        Binding(get: { store.settings.enableWriteTools }, set: { store.settings.enableWriteTools = $0 })
    }
    private var liveMeasurementsBinding: Binding<Bool> {
        Binding(get: { store.settings.enableLiveMeasurements }, set: { store.settings.enableLiveMeasurements = $0 })
    }

    // MARK: - Key actions

    private func refreshKeyState() {
        hasSavedKey = ((try? keyStore.readKey()) ?? nil) != nil
    }

    private func saveKey() {
        keyError = nil
        do {
            try keyStore.saveKey(keyDraft)
            keyDraft = ""
            showKey = false
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        keyError = nil
        do {
            try keyStore.deleteKey()
            keyDraft = ""
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }
}
