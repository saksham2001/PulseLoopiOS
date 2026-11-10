import SwiftUI

/// Loads a cloud provider's live model list (`CoachModelCatalog`) for Settings. One
/// load at a time: a refresh still in flight when the provider or key changes is
/// superseded, so an older answer can't land on top of the current one.
@MainActor
@Observable
final class CoachModelListLoader {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private(set) var provider: CoachProviderMode?
    private(set) var result: CoachModelCatalog.Result?
    private(set) var isLoading = false
    private(set) var hasKey = false
    private var generation = 0
    private var task: Task<Void, Never>?

    var listing: CoachModelCatalog.Listing? { result?.listing }

    /// The saved Keychain key for a cloud provider with a model list.
    static func storedKey(for provider: CoachProviderMode) -> String? {
        let keyStore: APIKeyStore? = switch provider {
        case .userOpenAIKey: OpenAIKeychainStore()
        case .userGeminiKey: GeminiKeychainStore()
        case .userOpenRouterKey: OpenRouterKeychainStore()
        case .userMiniMaxKey: MiniMaxKeychainStore()
        default: nil
        }
        return try? keyStore?.readKey()
    }

    func load(_ provider: CoachProviderMode, apiKey: String?, force: Bool = false) {
        task?.cancel()
        generation += 1
        if provider != self.provider { result = nil }
        self.provider = provider
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasKey = !key.isEmpty
        guard CoachModelCatalog.supports(provider), hasKey else {
            result = nil
            isLoading = false
            return
        }
        let current = generation
        isLoading = true
        task = Task { [weak self] in
            let fetched = await CoachModelCatalog.fetch(provider, apiKey: key, force: force)
            guard let self, current == self.generation else { return }
            self.result = fetched
            self.isLoading = false
        }
    }
}

/// The live listing's status under the Model row: how many models the provider lists
/// (or why it couldn't say), a Refresh/Retry button, and what the listing says about
/// the stored model — not listed any more, or announced for retirement. Also owns the
/// load (as soon as the provider is picked with a saved key, and again when the key
/// changes) and the all-models sheet the Model menu opens.
struct CoachModelListStatus: View {
    let loader: CoachModelListLoader
    let provider: CoachProviderMode
    let selected: String
    /// Changes whenever Settings re-reads the stored keys, so a new key reloads the list.
    let keyRevision: Int
    @Binding var showAll: Bool
    let onPick: (String) -> Void

    private var providerName: String { provider.label }

    var body: some View {
        FormField(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if loader.isLoading { ProgressView().controlSize(.small) }
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(status.isError ? PulseColors.danger : PulseColors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if loader.hasKey, !loader.isLoading {
                        Button(isFailure ? "Retry" : "Refresh") { load(force: true) }
                            .font(.caption.weight(.semibold))
                            .tint(PulseColors.accent)
                    }
                }
                if let listing = loader.listing {
                    if CoachModelCatalog.isUnlisted(provider, listing: listing, model: selected) {
                        Text("\(providerName) doesn't list “\(selected)” any more — it may have been retired. "
                             + "Pick another model.")
                            .font(.caption).foregroundStyle(PulseColors.danger)
                    } else if let expiry = listing.entry(for: selected)?.expiresOn {
                        Text("\(providerName) is retiring this model on \(expiry).")
                            .font(.caption).foregroundStyle(PulseColors.warning)
                    }
                }
            }
        }
        .task(id: "\(provider.rawValue)#\(keyRevision)") { load(force: false) }
        .sheet(isPresented: $showAll) {
            CoachModelPickerSheet(
                providerName: providerName,
                presets: CoachModelPickerSheet.Preset.curated(for: provider),
                listing: loader.provider == provider ? loader.listing : nil,
                selected: selected,
                onPick: onPick)
        }
    }

    private func load(force: Bool) {
        loader.load(provider, apiKey: CoachModelListLoader.storedKey(for: provider), force: force)
    }

    private var isFailure: Bool {
        if case .failure = loader.result { return true }
        return false
    }

    private var status: (text: String, isError: Bool) {
        if !loader.hasKey { return ("Save your key to see every model \(providerName) offers.", false) }
        if loader.isLoading { return ("Loading models from \(providerName)…", false) }
        switch loader.result {
        case .failure(let message): return (message, true)
        case .success(let listing): return ("\(listing.entries.count) models available from \(providerName)", false)
        case nil: return ("", false)
        }
    }
}

/// Every model the provider lists, with the curated presets first. A sheet with a
/// filter, because OpenRouter lists hundreds. Picking a model stores its slug; the
/// listing is advisory, so a slug it omits keeps working if the provider serves it.
struct CoachModelPickerSheet: View {
    struct Preset: Identifiable {
        let id: String
        let blurb: String

        /// The provider's curated picks, shown first.
        static func curated(for provider: CoachProviderMode) -> [Preset] {
            switch provider {
            case .userGeminiKey: return GeminiModel.allCases.map { Preset(id: $0.rawValue, blurb: $0.blurb) }
            case .userOpenRouterKey: return OpenRouterModel.allCases.map { Preset(id: $0.rawValue, blurb: $0.blurb) }
            case .userMiniMaxKey: return MiniMaxModel.allCases.map { Preset(id: $0.rawValue, blurb: $0.blurb) }
            default: return CoachModel.allCases.map { Preset(id: $0.rawValue, blurb: $0.blurb) }
            }
        }
    }

    let providerName: String
    let presets: [Preset]
    let listing: CoachModelCatalog.Listing?
    let selected: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var others: [CoachModelCatalog.Entry] {
        let presetIds = Set(presets.map(\.id))
        let all = (listing?.entries ?? []).filter { !presetIds.contains($0.id) }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.id.localizedCaseInsensitiveContains(query) || ($0.name?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    private var allCount: Int {
        let presetIds = Set(presets.map(\.id))
        return (listing?.entries ?? []).filter { !presetIds.contains($0.id) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if filter.isEmpty, !presets.isEmpty {
                    Section("Recommended") {
                        ForEach(presets) { preset in row(preset.id, detail: preset.blurb) }
                    }
                }
                Section("All models from \(providerName) (\(allCount))") {
                    ForEach(others, id: \.id) { entry in
                        row(entry.id, detail: [
                            entry.name.flatMap { $0 == entry.id ? nil : $0 },
                            entry.expiresOn.map { "retiring \($0)" },
                        ].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PulseColors.background)
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter, e.g. claude")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ slug: String, detail: String) -> some View {
        Button { onPick(slug); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slug)
                        .font(PulseFont.callout.monospaced())
                        .foregroundStyle(PulseColors.textPrimary)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(PulseColors.textMuted)
                    }
                }
                Spacer()
                if slug == selected.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Image(systemName: "checkmark").foregroundStyle(PulseColors.accent)
                }
            }
        }
        .listRowBackground(PulseColors.card)
    }
}
