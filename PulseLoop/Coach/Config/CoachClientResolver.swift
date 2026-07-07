import Foundation

/// Single source of truth for "which `ResponsesClient` runs, given the user's
/// settings + stored keys." Shared by the chat view-model, the summary service,
/// and the notification service so provider logic lives in exactly one place.
///
/// The returned `key` is a readiness sentinel: non-`nil` means the provider can
/// run (used to build `CoachFeatureFlags.hasAPIKey`). For cloud providers it's
/// the actual key; for on-device it's a `"on-device"` placeholder.
@MainActor
enum CoachClientResolver {
    static func resolve(
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient = { OpenAIResponsesClient(apiKey: $0) }
    ) -> (key: String?, client: ResponsesClient) {
        switch settings.providerMode {
        case .appleOnDevice:
            // On-device only — no cloud backup. When the local model is usable,
            // run it; otherwise hand back the client (it throws a clear error
            // that surfaces in chat) and signal "not ready" so generators degrade
            // to scripted.
            let onDevice = AppleFoundationModelsClient()
            let available = AppleOnDeviceAvailability.current.isAvailable
            return (available ? "on-device" : nil, onDevice)
        default:
            return directClient(
                settings.providerMode, settings: settings,
                openAIKeyStore: openAIKeyStore, geminiKeyStore: geminiKeyStore,
                openRouterKeyStore: openRouterKeyStore, openAIClientFactory: openAIClientFactory
            )
        }
    }

    /// Builds a client for a concrete (non-on-device) provider, mirroring the
    /// prior per-call-site logic. Returns a client even when the key is absent
    /// (`key == nil`); the feature-flags gate prevents an empty-key call.
    private static func directClient(
        _ mode: CoachProviderMode,
        settings: CoachSettings,
        openAIKeyStore: APIKeyStore,
        geminiKeyStore: APIKeyStore,
        openRouterKeyStore: APIKeyStore,
        openAIClientFactory: (String) -> ResponsesClient
    ) -> (key: String?, client: ResponsesClient) {
        switch mode {
        case .userGeminiKey:
            let key = (try? geminiKeyStore.readKey()) ?? nil
            return (key, GeminiClient(apiKey: key ?? ""))
        case .userOpenRouterKey:
            let key = (try? openRouterKeyStore.readKey()) ?? nil
            return (key, OpenRouterClient(
                apiKey: key ?? "",
                model: settings.openRouterModel,
                privacyRouting: settings.orEnablePrivacyRouting,
                providerSort: settings.orProviderSort))
        default:
            // userOpenAIKey / offlineStub / backendProxy (and appleOnDevice never
            // reaches here) all use the OpenAI key + factory.
            let key = (try? openAIKeyStore.readKey()) ?? nil
            return (key, openAIClientFactory(key ?? ""))
        }
    }
}
