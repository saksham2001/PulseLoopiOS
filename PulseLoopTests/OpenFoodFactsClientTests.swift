import XCTest
@testable import PulseLoop

/// URLProtocol stub: one handler per test, capturing the request for header/URL assertions.
final class OFFStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class OpenFoodFactsClientTests: XCTestCase {

    private func makeClient() -> OpenFoodFactsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OFFStubProtocol.self]
        return OpenFoodFactsClient(session: URLSession(configuration: config))
    }

    private func respond(_ status: Int, _ body: String, capture: @escaping (URLRequest) -> Void = { _ in }) {
        OFFStubProtocol.handler = { request in
            capture(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
    }

    override func tearDown() {
        OFFStubProtocol.handler = nil
        super.tearDown()
    }

    func testProductRequestCarriesUserAgentAndFields() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        respond(200, #"{"status": 1, "product": {"code": "123", "product_name": "Bar", "nutriments": {"energy-kcal_100g": 200}}}"#) {
            captured = $0
        }
        let product = try await makeClient().product(barcode: "123")
        XCTAssertEqual(product?.name, "Bar")
        let request = try XCTUnwrap(captured)
        let userAgent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(userAgent.hasPrefix("PulseLoop/"), "OFF requires app identification")
        XCTAssertTrue(userAgent.contains("@"), "OFF asks for a contact in the UA")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("world.openfoodfacts.org/api/v2/product/123"))
        XCTAssertTrue(url.contains("fields="), "always trim payloads")
    }

    func testUnknownBarcodeIsNilNotError() async throws {
        respond(200, #"{"status": 0}"#)
        let missing = try await makeClient().product(barcode: "000")
        XCTAssertNil(missing)

        respond(404, "not found")
        let notFound = try await makeClient().product(barcode: "000")
        XCTAssertNil(notFound)
    }

    func testRateLimitMapsToTypedError() async {
        respond(429, "slow down")
        do {
            _ = try await makeClient().search(query: "oats", pageSize: 5)
            XCTFail("expected rateLimited")
        } catch let error as OpenFoodFactsError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSearchHitsSearchALiciousHostAndDecodesHits() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        respond(200, #"{"hits": [{"code": "1", "product_name": "Rolled Oats", "nutriments": {"energy-kcal_100g": 379}}]}"#) {
            captured = $0
        }
        let results = try await makeClient().search(query: "rolled oats", pageSize: 5)
        XCTAssertEqual(results.map(\.name), ["Rolled Oats"])
        let url = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(url.contains("search.openfoodfacts.org/search"))
        XCTAssertTrue(url.contains("page_size=5"))
    }

    func testUnusableSearchRowsAreFilteredOut() async throws {
        respond(200, #"{"hits": [{"code": "1", "product_name": "Good", "nutriments": {"energy-kcal_100g": 100}}, {"code": "2", "product_name": "No energy", "nutriments": {}}]}"#)
        let results = try await makeClient().search(query: "x", pageSize: 5)
        XCTAssertEqual(results.map(\.name), ["Good"])
    }
}
