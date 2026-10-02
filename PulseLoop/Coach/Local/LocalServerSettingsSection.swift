import SwiftUI

/// The "Local server" + "Request options" block of `CoachSettingsSection`, for the
/// `localOpenAICompat` provider.
///
/// Its own view rather than more of `CoachSettingsSection` for two reasons: the probe state
/// (discovered models, the in-flight Detect, its summary and notes) is meaningful only while this
/// provider is selected and should die with it, and the parent struct was already at SwiftLint's
/// `type_body_length` ceiling. The optional API key stays in the parent so it renders identically
/// to every other provider's.
struct LocalServerSettingsSection: View {
    @State private var store = CoachSettingsStore.shared
    private let keyStore = LocalLLMKeychainStore()

    /// Models the last `/v1/models` call returned — advisory, the stored name stays free text.
    @State private var localDiscovered: [String] = []
    @State private var localProbeBusy = false
    /// One line summarising the last Detect run: the report summary, or why it failed.
    @State private var localProbeResult: String?
    @State private var localProbeOK = false
    /// Per-probe detail, so an inconclusive result is explainable rather than mysterious.
    @State private var localProbeNotes: [String] = []

    /// Footer for the local provider's Request options group. Each sentence exists because the
    /// setting above it is otherwise inexplicable: the tool-calling switch looks redundant until
    /// you have hit vLLM's 400, and a blank Max tokens looks unfinished rather than deliberate.
    private static let localRequestOptionsFooter = """
        Turn tool calling off if your server was started without it — vLLM returns HTTP 400 for \
        `tools` unless launched with --enable-auto-tool-choice. Leave Max tokens blank to let the \
        server decide; raise the timeout for a large model on CPU, since a slow reply is not retried.
        """

    /// Shown under the address field while it is valid. The ports are the whole point: the one
    /// thing a user reliably does not remember is which of the five their engine listens on.
    private static let addressHint = """
        Default ports — Ollama 11434 · LM Studio 1234 · llama.cpp 8080 · vLLM 8000 · SGLang 30000. \
        The /v1 path is added for you.
        """

    /// Display label for the model row: whatever the user's own server calls it. Blank is
    /// legitimate — llama.cpp ignores the field unless started with `--alias`.
    private var currentModelLabel: String {
        store.settings.resolvedLocalModel.isEmpty ? "Not set" : store.settings.resolvedLocalModel
    }

    /// The URL problem to show inline, or nil while the field is blank (an empty field isn't an
    /// error yet — it's an unconfigured one).
    private var localURLProblem: LocalEndpoint.Problem? {
        store.settings.localBaseURL.isEmpty ? nil : LocalEndpoint.validate(store.settings.localBaseURL)
    }

    /// Everything the local provider needs: where the server is, what it serves, and which optional
    /// request fields it will accept. Grouped together because they're useless apart — a model name
    /// without a URL configures nothing.
    @ViewBuilder
    var body: some View {
        SettingsGroup(header: "Local server") {
            FormField {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("http://192.168.1.50:11434", text: localBaseURLBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(PulseFont.subheadline.weight(.regular).monospaced())
                        .foregroundStyle(PulseColors.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .pulseGlass(Capsule())

                    Text(localURLProblem.map(LocalEndpoint.message) ?? Self.addressHint)
                        .font(.caption)
                        .foregroundStyle(localURLProblem == nil ? PulseColors.textMuted : PulseColors.danger)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // One press does the whole setup: identifies the engine, lists models, and probes
            // whether the server actually accepts `tools` and `response_format` — which depend on
            // launch flags that no metadata endpoint exposes. Detected values land on the controls
            // below, which stay editable.
            FormField {
                VStack(alignment: .leading, spacing: 8) {
                    QuickActionButton(
                        label: localProbeBusy ? "Detecting…" : "Detect server & configure",
                        accent: true
                    ) { detectLocalServer() }
                    .disabled(localProbeBusy || localURLProblem != nil
                              || store.settings.resolvedLocalBaseURL.isEmpty)

                    if localProbeBusy {
                        Text("Sending three tiny test messages. This can take a minute if the model still has to load.")
                            .font(.caption).foregroundStyle(PulseColors.textMuted)
                    }
                    if let localProbeResult {
                        Text(localProbeResult)
                            .font(.caption)
                            .foregroundStyle(localProbeOK ? PulseColors.textSecondary : PulseColors.danger)
                    }
                    ForEach(localProbeNotes, id: \.self) { note in
                        Text(note).font(.caption2).foregroundStyle(PulseColors.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The picker only appears once a listing exists; the field below always does, because
            // a router in front of any engine can serve names `/v1/models` doesn't enumerate.
            if !localDiscovered.isEmpty {
                FormMenuRow(title: "Model", value: currentModelLabel) {
                    Picker("Model", selection: localModelBinding) {
                        ForEach(localDiscovered, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
            }

            FormField {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("model name", text: localModelBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(PulseFont.subheadline.weight(.regular).monospaced())
                        .foregroundStyle(PulseColors.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .pulseGlass(Capsule())

                    Text("llama.cpp ignores this unless started with --alias; every other engine needs it to match.")
                        .font(.caption).foregroundStyle(PulseColors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        SettingsGroup(header: "Request options", footer: Self.localRequestOptionsFooter) {
            FormToggleRow(title: "Tool calling", isOn: localToolCallingBinding)

            FormMenuRow(title: "Response format", value: store.settings.localStructuredOutput.label) {
                Picker("Response format", selection: localStructuredOutputBinding) {
                    ForEach(LocalStructuredOutput.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            FormField {
                HStack(spacing: 10) {
                    numericField(title: "Max tokens", placeholder: "auto", binding: localMaxTokensBinding)
                    numericField(title: "Timeout (s)", placeholder: "180", binding: localTimeoutBinding)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

    }

    /// A small labelled numeric entry. Both values it serves are integers with a "leave it alone"
    /// meaning at zero/blank, so neither is a stepper.
    private func numericField(
        title: String, placeholder: String, binding: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(PulseColors.textMuted)
            TextField(placeholder, text: binding)
                .keyboardType(.numberPad)
                .font(PulseFont.subheadline.weight(.regular).monospaced())
                .foregroundStyle(PulseColors.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .pulseGlass(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Runs the probe and applies what it actually established.
    ///
    /// Only a conclusive verdict may overwrite a stored setting. Detect is also how you refresh the
    /// model list, so it gets pressed on setups that already work — and the safe defaults behind
    /// `suggested*` (tools ON, structured OFF) are right for a first run and wrong for a re-detect:
    /// a user who turned tools off for a vLLM server without `--enable-auto-tool-choice` would
    /// otherwise have them switched back on by a press meant to do something else. Likewise a
    /// `suggestedMaxTokens` of 0 means "the server reported no context window", not "clear what the
    /// user typed".
    private func detectLocalServer() {
        localProbeBusy = true
        localProbeResult = nil
        localProbeNotes = []
        let baseURL = store.settings.resolvedLocalBaseURL
        let key = (try? keyStore.readKey()) ?? nil
        let currentModel = store.settings.resolvedLocalModel
        Task { @MainActor in
            defer { localProbeBusy = false }
            do {
                let report = try await LocalCapabilityProbe.run(
                    baseURL: baseURL, apiKey: key, currentModel: currentModel)
                localDiscovered = report.models
                if !report.suggestedModel.isEmpty { store.settings.localModel = report.suggestedModel }
                if report.toolCallingConclusive {
                    store.settings.localToolCalling = report.suggestedToolCalling
                }
                if report.structuredOutputConclusive {
                    store.settings.localStructuredOutput = report.suggestedStructuredOutput
                }
                // Derived from the context window minus a prompt reserve — never a straight copy,
                // or `prompt + max_tokens` would exceed the context and the server would reject
                // the request outright.
                if report.suggestedMaxTokens > 0 {
                    store.settings.localMaxTokens = report.suggestedMaxTokens
                }
                localProbeOK = true
                localProbeResult = report.summary
                localProbeNotes = report.notes
            } catch {
                localProbeOK = false
                localProbeResult = (error as? LocalCapabilityProbe.Unreachable)?.reason
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Bindings

    private var localBaseURLBinding: Binding<String> {
        Binding(
            get: { store.settings.localBaseURL },
            set: { newValue in
                store.settings.localBaseURL = newValue
                // A new address invalidates everything the last probe learned — the model list
                // especially, since it belongs to whatever server used to be at the old URL.
                localDiscovered = []
                localProbeResult = nil
                localProbeOK = false
                localProbeNotes = []
            }
        )
    }

    private var localModelBinding: Binding<String> {
        Binding(get: { store.settings.localModel }, set: { store.settings.localModel = $0 })
    }

    private var localToolCallingBinding: Binding<Bool> {
        Binding(get: { store.settings.localToolCalling }, set: { store.settings.localToolCalling = $0 })
    }

    private var localStructuredOutputBinding: Binding<LocalStructuredOutput> {
        Binding(
            get: { store.settings.localStructuredOutput },
            set: { store.settings.localStructuredOutput = $0 }
        )
    }

    /// 0 means "omit `max_tokens` and let the server decide", which is what an empty field shows.
    private var localMaxTokensBinding: Binding<String> {
        Binding(
            get: { store.settings.localMaxTokens > 0 ? "\(store.settings.localMaxTokens)" : "" },
            set: { store.settings.localMaxTokens = Int($0.filter(\.isNumber)) ?? 0 }
        )
    }

    /// Clamped on write, since a 2-second timeout would fail every local generation and a
    /// multi-hour one would hang the coach with no way back.
    private var localTimeoutBinding: Binding<String> {
        Binding(
            get: { "\(store.settings.localTimeoutSeconds)" },
            set: { raw in
                guard let value = Int(raw.filter(\.isNumber)) else { return }
                store.settings.localTimeoutSeconds = min(max(value, 10), 1800)
            }
        )
    }
}
