import Foundation

/// Interface for food-database lookups, so views/tools depend on the protocol and tests
/// inject a stub (same pattern as `ResponsesClient`).
protocol FoodDatabaseClient: Sendable {
    /// Product by barcode. nil = not found (a valid answer, not an error).
    func product(barcode: String) async throws -> FoodProduct?
    /// Full-text search, best matches first.
    func search(query: String, pageSize: Int) async throws -> [FoodProduct]
}

enum OpenFoodFactsError: Error, Equatable {
    case invalidURL
    /// HTTP 429 — the caller must back off and offer manual entry; never auto-retry.
    case rateLimited
    case httpStatus(Int)
    case decoding(String)
    case network(String)
}

/// Thin URLSession client for Open Food Facts (ODbL). Usage rules honored here:
/// - Every call maps to a real user action (explicit search submit, barcode scan, coach tool
///   call) — callers must check the local `CachedFoodProduct` table first.
/// - A custom User-Agent identifies the app, as OFF requires.
/// - `fields=` trims every payload to the nutriments the app actually stores.
/// Product reads hit world.openfoodfacts.org; full-text search is only served by the newer
/// Search-a-licious host (v2 search is structured-filter only).
struct OpenFoodFactsClient: FoodDatabaseClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// OFF-required app identification: AppName/Version (contact).
    nonisolated static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "PulseLoop/\(version) (sakshambhutani2001@gmail.com)"
    }

    private static let productFields = [
        "code", "product_name", "brands", "nutriments", "serving_size", "serving_quantity"
    ].joined(separator: ",")

    func product(barcode: String) async throws -> FoodProduct? {
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode)")
        components?.queryItems = [URLQueryItem(name: "fields", value: Self.productFields)]
        guard let url = components?.url else { throw OpenFoodFactsError.invalidURL }
        // OFF returns 404 for unknown barcodes; map that (and status 0) to nil, not an error.
        do {
            let envelope: OFFProductResponse = try await get(url)
            guard envelope.status == 1, let dto = envelope.product else { return nil }
            return dto.asFoodProduct()
        } catch OpenFoodFactsError.httpStatus(404) {
            return nil
        }
    }

    func search(query: String, pageSize: Int = 10) async throws -> [FoodProduct] {
        var components = URLComponents(string: "https://search.openfoodfacts.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "fields", value: Self.productFields),
        ]
        guard let url = components?.url else { throw OpenFoodFactsError.invalidURL }
        let envelope: OFFSearchResponse = try await get(url)
        return envelope.results.compactMap { $0.asFoodProduct() }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenFoodFactsError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 429 { throw OpenFoodFactsError.rateLimited }
            throw OpenFoodFactsError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenFoodFactsError.decoding(String(describing: error))
        }
    }
}

extension FoodProduct {
    /// Persist into (or refresh) the local cache table form.
    func asCachedProduct() -> CachedFoodProduct {
        CachedFoodProduct(
            code: code,
            name: name,
            brand: brand,
            energyKcal100g: energyKcal100g,
            protein100g: protein100g,
            carbs100g: carbs100g,
            fat100g: fat100g,
            fiber100g: fiber100g,
            sugars100g: sugars100g,
            saturatedFat100g: saturatedFat100g,
            sodiumMg100g: sodiumMg100g,
            servingSizeText: servingSizeText,
            servingQuantityG: servingQuantityG
        )
    }
}

extension CachedFoodProduct {
    /// Back to the value form the pickers work with.
    func asFoodProduct() -> FoodProduct {
        FoodProduct(
            code: code,
            name: name,
            brand: brand,
            energyKcal100g: energyKcal100g,
            protein100g: protein100g,
            carbs100g: carbs100g,
            fat100g: fat100g,
            fiber100g: fiber100g,
            sugars100g: sugars100g,
            saturatedFat100g: saturatedFat100g,
            sodiumMg100g: sodiumMg100g,
            servingSizeText: servingSizeText,
            servingQuantityG: servingQuantityG
        )
    }
}
