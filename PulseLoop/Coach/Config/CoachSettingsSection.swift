import SwiftUI
import SwiftData
import UserNotifications

/// "AI Coach" block for `SettingsView`: provider mode, model, OpenAI/Gemini/
/// OpenRouter key (stored in Keychain), action/measurement toggles, and saved
/// coach memory.
/// Daily check-in notifications live in `NotificationsSettingsView`. Visuals
/// reuse the existing design system.
struct CoachSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CoachMemory.importance, order: .reverse) private var memories: [CoachMemory]
    @State private var store = CoachSettingsStore.shared
    /// Presents the "Enable Coach Check-Ins?" prompt when the coach is first switched on.
    @State private var askEnableCheckIns = false
    /// Set when the user opts into check-ins but iOS denies notification permission.
    @State private var checkInPermissionDenied = false
    private let openAIKeyStore = OpenAIKeychainStore()
    private let geminiKeyStore = GeminiKeychainStore()
    private let openRouterKeyStore = OpenRouterKeychainStore()

    /// Picker tag that selects the free-text "Custom" OpenRouter model entry.
    private let customModelTag = "__custom__"

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

    // OpenRouter key state
    @State private var openRouterKeyDraft: String = ""
    @State private var hasOpenRouterKey: Bool = false
    @State private var showOpenRouterKey: Bool = false
    @State private var openRouterKeyError: String?

    private var flags: CoachFeatureFlags {
        let hasKey: Bool
        switch store.settings.providerMode {
        case .userGeminiKey: hasKey = hasGeminiKey
        case .userOpenRouterKey: hasKey = hasOpenRouterKey
        default: hasKey = hasSavedKey
        }
        return CoachFeatureFlags(settings: store.settings, hasAPIKey: hasKey)
    }

    /// True when the stored OpenRouter model isn't one of the curated presets
    /// (i.e. the user is using the free-text "Custom" slug).
    private var isCustomOpenRouterModel: Bool {
        !OpenRouterModel.allCases.contains { $0.rawValue == store.settings.model }
    }

    /// Which provider's key field to surface. The on-device provider needs no
    /// key (and has no cloud backup), so it surfaces none.
    private var effectiveKeyProvider: CoachProviderMode? {
        store.settings.providerMode == .appleOnDevice
            ? nil
            : store.settings.providerMode
    }

    var body: some View {
        SectionHeader(title: "AI Coach", action: nil)
        StatusCopy(title: "Status", body: flags.statusLine)
        toggleRow("Enable AI Coach", isOn: masterEnabledBinding)
            .alert("Enable Coach Check-Ins?", isPresented: $askEnableCheckIns) {
                Button("Enable") { enableCheckIns() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Get a daily check-in from your coach. You can change this anytime in Coach Check-Ins.")
            }

        if checkInPermissionDenied {
            Text("Notifications are off for PulseLoop. Turn them on in iOS Settings to get check-ins.")
                .font(.caption)
                .foregroundStyle(PulseColors.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

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

            // On-device has a single fixed model and runs only on-device (no
            // cloud backup) — show a privacy/availability card instead of a
            // model picker.
            if store.settings.providerMode == .appleOnDevice {
                appleOnDeviceCard
            } else {
                labeledRow("Model") {
                    Picker("Model", selection: modelPickerBinding) {
                        switch store.settings.providerMode {
                        case .userGeminiKey:
                            ForEach(GeminiModel.allCases) { model in
                                Text(model.label).tag(model.rawValue)
                            }
                        case .userOpenRouterKey:
                            ForEach(OpenRouterModel.allCases) { model in
                                Text(model.label).tag(model.rawValue)
                            }
                            Text("Custom…").tag(customModelTag)
                        default:
                            ForEach(CoachModel.allCases) { model in
                                Text(model.label).tag(model.rawValue)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(PulseColors.accent)
                }
            }

            if store.settings.providerMode == .userOpenRouterKey, isCustomOpenRouterModel {
                customModelField
            }

            // The key field tracks the *effective* provider — the active cloud
            // provider (none in on-device mode, which needs no key).
            if effectiveKeyProvider == .userOpenAIKey {
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
            } else if effectiveKeyProvider == .userGeminiKey {
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
            } else if effectiveKeyProvider == .userOpenRouterKey {
                apiKeyField(
                    placeholder: "sk-or-v1-…",
                    hint: "Stored only in your device Keychain. Used to call OpenRouter directly.",
                    draft: $openRouterKeyDraft,
                    showRaw: $showOpenRouterKey,
                    hasSaved: hasOpenRouterKey,
                    error: openRouterKeyError,
                    onSave: saveOpenRouterKey,
                    onRemove: removeOpenRouterKey
                )
            }

            // The on-device provider is tool-less: it ignores web search, so the
            // toggle isn't offered there.
            if store.settings.providerMode != .appleOnDevice {
                toggleRow("Web search", isOn: webSearchBinding)
            }

            // OpenRouter-only routing controls. OpenRouter exposes a unified
            // reasoning-effort hint plus provider-level privacy and sort options
            // the native OpenAI/Gemini clients don't, so they only appear here.
            if store.settings.providerMode == .userOpenRouterKey {
                labeledRow("Reasoning") {
                    Picker("Reasoning", selection: reasoningEffortBinding) {
                        Text("Default").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.menu)
                    .tint(PulseColors.accent)
                }

                toggleRow("Privacy routing", isOn: privacyRoutingBinding)

                labeledRow("Provider sort") {
                    Picker("Provider sort", selection: providerSortBinding) {
                        Text("Default").tag("")
                        Text("Price").tag("price")
                        Text("Throughput").tag("throughput")
                        Text("Latency").tag("latency")
                    }
                    .pickerStyle(.menu)
                    .tint(PulseColors.accent)
                }
            }

            toggleRow("AI actions (set goals, log, edit)", isOn: writeToolsBinding)
            toggleRow("Live ring measurements", isOn: liveMeasurementsBinding)
            // The on-device model has no image-input API in the shipping SDK, so
            // the option isn't offered there.
            if store.settings.providerMode != .appleOnDevice {
                toggleRow("Image input (attach photos)", isOn: imageInputBinding)
            }

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

    // MARK: - On-device (Apple) info card

    /// Privacy + availability panel shown when the on-device provider is picked.
    /// Replaces the model picker (the model is fixed) and explains the v1 limits.
    private var appleOnDeviceCard: some View {
        let availability = AppleOnDeviceAvailability.current
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: availability.isAvailable ? "lock.iphone" : "exclamationmark.triangle")
                    .font(.system(size: 15))
                    .foregroundStyle(availability.isAvailable ? PulseColors.accent : PulseColors.danger)
                Text(availability.isAvailable ? "On-device · private" : "On-device unavailable")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PulseColors.textPrimary)
            }
            Text(availability.isAvailable
                 ? "Your health data is analyzed entirely on your iPhone and never leaves the device. No API key, no network — works offline and free of charge."
                 : availability.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(PulseColors.textSecondary)
            Text("On-device coaching gives summaries, check-ins and chat. Charts, AI actions and web search need a cloud provider.")
                .font(.caption)
                .foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Custom OpenRouter model field

    private var customModelField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("vendor/model-slug", text: modelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(PulseColors.cardSoft, in: Capsule())
                .overlay(Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1))

            Text("Any model slug from openrouter.ai/models — e.g. anthropic/claude-sonnet-4.6.")
                .font(.caption).foregroundStyle(PulseColors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Small layout helpers

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(PulseColors.textPrimary)
                .fixedSize()
            Spacer(minLength: 8)
            // Let the picker keep its full label and grow the row height if needed,
            // rather than getting compressed and clipped at the bottom.
            content()
                .fixedSize()
                .layoutPriority(1)
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
                } else {
                    // First time on: ask before enabling check-ins (OS permission only on "Enable").
                    askEnableCheckIns = true
                }
            }
        )
    }

    /// Requests notification permission and enables daily check-ins when the user opts in.
    private func enableCheckIns() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            store.settings.notificationsEnabled = granted
            checkInPermissionDenied = !granted
            if granted { CoachNotificationScheduler.shared.scheduleNext() }
        }
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
                case .userOpenRouterKey:
                    store.settings.model = OpenRouterModel.default.rawValue
                default:
                    store.settings.model = CoachModel.gpt54.rawValue
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(get: { store.settings.model }, set: { store.settings.model = $0 })
    }

    /// Picker selection that understands the OpenRouter "Custom…" sentinel: when
    /// the stored model isn't a preset it reports `customModelTag` (so the menu
    /// highlights "Custom…" and the free-text field shows the actual slug).
    private var modelPickerBinding: Binding<String> {
        Binding(
            get: {
                if store.settings.providerMode == .userOpenRouterKey {
                    return isCustomOpenRouterModel ? customModelTag : store.settings.model
                }
                return store.settings.model
            },
            set: { newValue in
                if newValue == customModelTag {
                    // Switching into Custom: clear the slug only when leaving a preset
                    // so an existing custom value is preserved.
                    if !isCustomOpenRouterModel { store.settings.model = "" }
                } else {
                    store.settings.model = newValue
                }
            }
        )
    }
    private var webSearchBinding: Binding<Bool> {
        Binding(get: { store.settings.enableWebSearch }, set: { store.settings.enableWebSearch = $0 })
    }
    /// `reasoningEffort` is optional; the picker uses "" for the "Default" (nil) tag.
    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { store.settings.reasoningEffort ?? "" },
            set: { store.settings.reasoningEffort = $0.isEmpty ? nil : $0 }
        )
    }
    private var privacyRoutingBinding: Binding<Bool> {
        Binding(get: { store.settings.orEnablePrivacyRouting }, set: { store.settings.orEnablePrivacyRouting = $0 })
    }
    /// `orProviderSort` is optional; the picker uses "" for the "Default" (nil) tag.
    private var providerSortBinding: Binding<String> {
        Binding(
            get: { store.settings.orProviderSort ?? "" },
            set: { store.settings.orProviderSort = $0.isEmpty ? nil : $0 }
        )
    }
    private var writeToolsBinding: Binding<Bool> {
        Binding(get: { store.settings.enableWriteTools }, set: { store.settings.enableWriteTools = $0 })
    }
    private var liveMeasurementsBinding: Binding<Bool> {
        Binding(get: { store.settings.enableLiveMeasurements }, set: { store.settings.enableLiveMeasurements = $0 })
    }
    private var imageInputBinding: Binding<Bool> {
        Binding(get: { store.settings.enableImageInput }, set: { store.settings.enableImageInput = $0 })
    }

    // MARK: - Key actions

    private func refreshKeyState() {
        hasSavedKey = ((try? openAIKeyStore.readKey()) ?? nil) != nil
        hasGeminiKey = ((try? geminiKeyStore.readKey()) ?? nil) != nil
        hasOpenRouterKey = ((try? openRouterKeyStore.readKey()) ?? nil) != nil
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

    private func saveOpenRouterKey() {
        openRouterKeyError = nil
        do {
            try openRouterKeyStore.saveKey(openRouterKeyDraft)
            openRouterKeyDraft = ""
            showOpenRouterKey = false
            refreshKeyState()
        } catch {
            openRouterKeyError = error.localizedDescription
        }
    }

    private func removeOpenRouterKey() {
        openRouterKeyError = nil
        do {
            try openRouterKeyStore.deleteKey()
            openRouterKeyDraft = ""
            refreshKeyState()
        } catch {
            openRouterKeyError = error.localizedDescription
        }
    }
}
