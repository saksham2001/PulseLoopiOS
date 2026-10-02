import Foundation

/// URL handling for the self-hosted ("local") coach provider — see `docs/local-llm-coach.md` §3.
///
/// The user types a *base* URL (`http://192.168.1.50:11434`, `http://localhost:1234/v1`,
/// `https://llm.example.com`), not a full endpoint path, because every engine serves the same
/// OpenAI-compatible routes under a `/v1` prefix: Ollama on 11434, llama.cpp on 8080, vLLM on
/// 8000, SGLang on 30000, LM Studio on 1234. This type turns whatever they typed into the two
/// concrete URLs the app calls, and enforces the plaintext-host rule.
///
/// On iOS that rule is layered differently than on Android. ATS already blocks cleartext, and
/// `NSAllowsLocalNetworking` (Info.plist) re-permits it *only* for local-network destinations —
/// so unlike Android's `network_security_config.xml`, the platform is doing real work here. This
/// check still exists because it runs at type-time, in the Settings field, where it can say what
/// is wrong instead of letting the first request fail opaquely.
enum LocalEndpoint {

    /// Why a base URL can't be used. `nil` from ``validate(_:)`` means it's fine.
    enum Problem { case blank, malformed, unsupportedScheme, publicCleartext }

    /// Normalizes a user-typed base URL to its scheme+authority+path root, with any trailing `/`
    /// and any trailing `/v1` (or `/v1/chat/completions`, if they pasted the full endpoint)
    /// stripped — so ``chatCompletionsURL(_:)`` and ``modelsURL(_:)`` can append the canonical
    /// suffix without producing `/v1/v1`. A bare `host:port` with no scheme is assumed to be
    /// `http://` (the overwhelmingly common local case; a public host would be rejected by
    /// ``validate(_:)`` anyway).
    ///
    /// Returns nil when the input can't be parsed into a scheme + host.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://\(text)" }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        // Tolerate a pasted full endpoint or an explicit /v1 — both are re-appended by callers.
        for suffix in ["/v1/chat/completions", "/chat/completions", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        while path.hasSuffix("/") { path.removeLast() }

        let port = components.port.map { ":\($0)" } ?? ""
        // An IPv6 literal must stay bracketed in the reassembled URL; URLComponents.host strips them.
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(authority)\(port)\(path)"
    }

    /// `POST` target for a chat turn.
    static func chatCompletionsURL(_ base: String) -> URL? {
        normalize(base).flatMap { URL(string: "\($0)/v1/chat/completions") }
    }

    /// `GET` target that lists the models the server currently has loaded/available.
    static func modelsURL(_ base: String) -> URL? {
        normalize(base).flatMap { URL(string: "\($0)/v1/models") }
    }

    /// The reason [raw] can't be used, or nil if it's usable.
    ///
    /// `https://` is unrestricted — a self-hosted box with a real certificate is the user's call.
    /// Plaintext `http://` is confined to hosts that can't be on the public internet: loopback,
    /// RFC1918 / CGNAT / link-local addresses, and local-only names.
    static func validate(_ raw: String) -> Problem? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        guard let normalized = normalize(raw),
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return .malformed }
        switch scheme {
        case "https": return nil
        case "http": return isPrivateHost(host) ? nil : .publicCleartext
        default: return .unsupportedScheme
        }
    }

    /// A short, user-facing explanation for a ``Problem``, for the Settings field.
    static func message(_ problem: Problem) -> String {
        switch problem {
        case .blank:
            return "Enter your server's address, e.g. http://192.168.1.50:11434"
        case .malformed:
            return "That doesn't look like a URL — use host:port or http://host:port"
        case .unsupportedScheme:
            return "Only http:// and https:// are supported."
        case .publicCleartext:
            return "Plain http:// is only allowed for a server on this device or your local "
                + "network (an IP address, a plain hostname, or a .local / .lan / .ts.net name). "
                + "Use https:// to reach one over the internet."
        }
    }

    /// True when [host] can't be routed off the local network: loopback, RFC1918 (`10/8`,
    /// `172.16/12`, `192.168/16`), CGNAT `100.64/10` (Tailscale), link-local `169.254/16`, IPv6
    /// loopback/ULA/link-local, mDNS `.local` names, and the name forms that only resolve on a
    /// local network.
    ///
    /// That last group is why this isn't purely an address test. Addressing an inference box by
    /// the name its router or mDNS hands out — `http://nas:11434`, `http://ollama.lan:8080`, a
    /// Tailscale MagicDNS `http://box.tail1234.ts.net:11434` — is an ordinary setup, and
    /// rejecting it would tell the user their server had to be on their local network, which is
    /// exactly where it is. A single-label host has no public TLD and cannot be resolved off-LAN;
    /// the suffixes in ``localSuffixes`` are the reserved/local-scope ones (RFC 8375 `.home.arpa`,
    /// RFC 6762 `.local`, the `.lan`/`.home`/`.internal` conventions, Tailscale's `.ts.net`).
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h.isEmpty { return false }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if localSuffixes.contains(where: { h.hasSuffix($0) }) { return true }
        // A bare hostname with no dot at all: resolvable only via a DNS search domain, mDNS or
        // NetBIOS, i.e. on-link. The IPv6 check below still catches a bracket-less literal.
        if !h.contains(".") && !h.contains(":") { return true }
        if h.contains(":") {   // IPv6
            return h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:")
        }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let nums = octets.compactMap { Int($0) }
        guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (nums[0], nums[1])
        switch true {
        case a == 127: return true                      // loopback
        case a == 10: return true                       // RFC1918
        case a == 192 && b == 168: return true           // RFC1918
        case a == 172 && (16...31).contains(b): return true  // RFC1918
        case a == 169 && b == 254: return true           // link-local
        case a == 100 && (64...127).contains(b): return true // CGNAT / Tailscale
        default: return false
        }
    }

    /// Suffixes that are reserved for, or conventionally used on, a local network only.
    private static let localSuffixes = [
        ".local",       // RFC 6762 mDNS
        ".home.arpa",   // RFC 8375
        ".lan", ".home", ".internal",   // common router defaults
        ".ts.net",      // Tailscale MagicDNS
    ]
}
