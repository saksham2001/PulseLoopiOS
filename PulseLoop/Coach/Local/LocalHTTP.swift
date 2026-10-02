import Foundation

/// The HTTP the local provider uses, kept apart from the cloud clients' plain `URLSession.shared`
/// for one reason: **it must not follow redirects.**
///
/// `LocalEndpoint.validate` vets the URL the *user typed*. It cannot vet where a redirect lands,
/// and `NSAllowsLocalNetworking` re-permits cleartext for local destinations — so a `307` from the
/// validated LAN host to a public `http://` one would resend the coach's health-context POST body
/// in the clear, past every check the app makes. Cloud providers keep the default session; their
/// hosts are `https://` constants.
///
/// The delegate is also where the long read timeout lives: a 30B model on CPU can spend minutes on
/// one round, which is nothing like a hosted API's latency profile.
enum LocalHTTP {

    /// Refuses every redirect. `nil` to the completion handler makes URLSession return the
    /// redirect response itself instead of chasing it.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let delegate = NoRedirectDelegate()

    private static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        // Belt and braces: the delegate is the real guard, but a session that never caches also
        // never keeps a copy of a health-context response on disk.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// `POST` a JSON body and return the raw response data.
    ///
    /// Throws `ResponsesError.transport` on a network failure and `ResponsesError.http` (with the
    /// body) on a non-2xx status — including a 3xx, which reaches here precisely because the
    /// redirect was refused.
    static func post(
        url: URL,
        body: Data,
        headers: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        request.timeoutInterval = timeout
        return try await perform(request, timeout: timeout)
    }

    /// A one-off `GET`, for model discovery and the engine-identity routes.
    static func get(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = timeout
        return try await perform(request, timeout: timeout)
    }

    private static func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session(timeout: timeout).data(for: request)
        } catch {
            throw ResponsesError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ResponsesError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
