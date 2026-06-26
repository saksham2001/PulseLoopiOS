import SwiftUI
import SwiftData

/// "AI Coach" block for `SettingsView`: provider mode, model, OpenAI/Gemini key
/// (stored in Keychain), action/measurement toggles, and saved coach memory.
/// Daily check-in notifications live in `NotificationsSettingsView`. Visuals
/// reuse the existing design system.
struct CoachSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CoachMemory.importance, order: .reverse) private var memories: [CoachMemory]
    @State private var store = CoachSettingsStore.shared
    private let openAIKeyStore = OpenAIKeychainStore()
    private let geminiKeyStore = GeminiKeychainStore()

    // OpenAI key state
    @State private var keyDraft: String = ""
    @State private var hasSavedKey: Bool = false
    @State private var showKey: Bool = false
    @State private var keyError: String?

    // Gemini key state
    @State private var geminiKeyDraft: String = ""
    @State private var hasGeminiKey: Bool = false
    @State private var showGeminiKey: Bool = false
    @State private var geminiKeyError: String?

    private var flags: CoachFeatureFlags {
        let hasKey = store.settings.providerMode == .userGeminiKey ? hasGeminiKey : hasSavedKey
        return CoachFeatureFlags(settings: store.settings, hasAPIKey: hasKey)
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
                    if store.settings.providerMode == .userGeminiKey {
                        ForEach(GeminiModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    } else {
                        ForEach(CoachModel.allCases) { model in
                            Text(model.label).tag(model.rawValue)
                        }
                    }
                }
                .pickerStyle(.menu)
                .tint(PulseColors.accent)
            }

            if store.settings.providerMode == .userOpenAIKey {
                apiKeyField(
                    placeholder: "sk-…",
                    hint: "Stored only in your device Keychain. Used to call OpenAI directly.",
                    draft: $keyDraft,
                    showRaw: $showKey,
                    hasSaved: hasSavedKey,
                    error: keyError,
                    onSave: saveOpenAIKey,
                    onRemove: removeOpenAIKey
                )
            } else if store.settings.providerMode == .userGeminiKey {
                apiKeyField(
                    placeholder: "AIza…",
                    hint: "Stored only in your device Keychain. Used to call Gemini directly.",
                    draft: $geminiKeyDraft,
                    showRaw: $showGeminiKey,
                    hasSaved: hasGeminiKey,
                    error: geminiKeyError,
                    onSave: saveGeminiKey,
                    onRemove: removeGeminiKey
                )
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

    // MARK: - Key field (reused for both providers)

    private func apiKeyField(
        placeholder: String,
        hint: String,
        draft: Binding<String>,
        showRaw: Binding<Bool>,
        hasSaved: Bool,
        error: String?,
        onSave: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if showRaw.wrappedValue {
                        TextField(placeholder, text: draft)
                    } else {
                        SecureField(placeholder, text: draft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(PulseColors.cardSoft, in: Capsule())
                .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))

                Button { showRaw.wrappedValue.toggle() } label: {
                    Image(systemName: showRaw.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(PulseColors.textMuted)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                QuickActionButton(label: hasSaved ? "Update key" : "Save key", accent: true) { onSave() }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasSaved {
                    QuickActionButton(label: "Remove") { onRemove() }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(PulseColors.danger)
            } else {
                Text(hint).font(.caption).foregroundStyle(PulseColors.textMuted)
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
                    CoachNotificationScheduler.shared.cancel()
                } else if store.settings.notificationsEnabled {
                    CoachNotificationScheduler.shared.scheduleNext()
                }
            }
        )
    }

    private var providerBinding: Binding<CoachProviderMode> {
        Binding(
            get: { store.settings.providerMode },
            set: { newProvider in
                store.settings.providerMode = newProvider
                // Reset model to the default for the selected provider.
                switch newProvider {
                case .userGeminiKey:
                    store.settings.model = GeminiModel.flash25.rawValue
                default:
                    store.settings.model = CoachModel.gpt54.rawValue
                }
            }
        )
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
        hasSavedKey = ((try? openAIKeyStore.readKey()) ?? nil) != nil
        hasGeminiKey = ((try? geminiKeyStore.readKey()) ?? nil) != nil
    }

    private func saveOpenAIKey() {
        keyError = nil
        do {
            try openAIKeyStore.saveKey(keyDraft)
            keyDraft = ""
            showKey = false
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeOpenAIKey() {
        keyError = nil
        do {
            try openAIKeyStore.deleteKey()
            keyDraft = ""
            refreshKeyState()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func saveGeminiKey() {
        geminiKeyError = nil
        do {
            try geminiKeyStore.saveKey(geminiKeyDraft)
            geminiKeyDraft = ""
            showGeminiKey = false
            refreshKeyState()
        } catch {
            geminiKeyError = error.localizedDescription
        }
    }

    private func removeGeminiKey() {
        geminiKeyError = nil
        do {
            try geminiKeyStore.deleteKey()
            geminiKeyDraft = ""
            refreshKeyState()
        } catch {
            geminiKeyError = error.localizedDescription
        }
    }
}
