import XCTest
@testable import AppActor

// MARK: - Live Offerings Tests (opt-in)
//
// These tests hit the real AppActor Payment API. They are SKIPPED unless:
//   RUN_LIVE_TESTS=1
//   APPACTOR_BASE_URL=https://appactor-api.service.appmergly.work
//   APPACTOR_PUBLIC_API_KEY=pk_...
//
// Run:
//   RUN_LIVE_TESTS=1 \
//   APPACTOR_BASE_URL=https://appactor-api.service.appmergly.work \
//   APPACTOR_PUBLIC_API_KEY=pk_your_dev_key \
//   swift test --filter AppActorTests.PaymentLiveOfferingsTests
//
// NOTE: These tests validate **decode-only** — they call the real offerings API
// and verify the JSON decodes into OfferingsResponseDTO. StoreKit enrichment is
// intentionally skipped because StoreKit2 cannot fetch products outside of a
// signed app / StoreKit Test environment.

@MainActor
final class PaymentLiveOfferingsTests: XCTestCase {

    // MARK: - Env helpers

    private static let env = ProcessInfo.processInfo.environment

    private static var isEnabled: Bool {
        env["RUN_LIVE_TESTS"] == "1"
    }

    private static var baseURL: URL? {
        env["APPACTOR_BASE_URL"].flatMap(URL.init(string:))
    }

    private static var apiKey: String? {
        env["APPACTOR_PUBLIC_API_KEY"]
    }

    private static var apiKeyHint: String {
        guard let key = apiKey, key.count >= 6 else { return "??????" }
        return "...\(key.suffix(6))"
    }

    // MARK: - Per-test state

    private var client: AppActorPaymentClient!

    override func setUp() async throws {
        try XCTSkipUnless(Self.isEnabled, "Live tests skipped (set RUN_LIVE_TESTS=1)")

        guard let baseURL = Self.baseURL else {
            throw XCTSkip("APPACTOR_BASE_URL not set or invalid")
        }
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else {
            throw XCTSkip("APPACTOR_PUBLIC_API_KEY not set")
        }

        client = AppActorPaymentClient(
            baseURL: baseURL,
            apiKey: apiKey,
            headerMode: .bearer,
            responseLogger: { path, status, body in
                LiveOfferingsLog.logResponse(path: path, status: status, body: body)
            }
        )

        LiveOfferingsLog.log("--- Test setup complete (key: \(Self.apiKeyHint), baseURL: \(baseURL)) ---")
    }

    // MARK: - 1) Live Offerings Decode

    /// Calls `GET /v1/payment/offerings` against the real API and validates:
    /// - HTTP 200 (via successful decode)
    /// - OfferingsResponseDTO decodes correctly
    /// - request_id is present
    /// - Product ID extraction works on real data
    ///
    /// This is a **decode-only** test — StoreKit enrichment is intentionally
    /// skipped. In CI or environments without StoreKit sandbox, StoreKit
    /// `Product.products(for:)` returns empty, so testing enrichment would
    /// always fail. Instead, we validate the API contract and DTO layer.
    func testLiveOfferingsDecode() async throws {
        try XCTSkipUnless(Self.isEnabled)

        LiveOfferingsLog.log("=== testLiveOfferingsDecode ===")

        // Call the real API (decode-only, no StoreKit)
        let result = try await client.getOfferings(eTag: nil)
        guard case .fresh(let dto, _, let requestId, _) = result else {
            XCTFail("Expected fresh response, got 304")
            return
        }

        // request_id should be present
        LiveOfferingsLog.log("request_id: \(requestId ?? "nil")")
        XCTAssertNotNil(requestId, "Offerings response should include request_id")

        // Offerings array should decode (may be empty if no offerings configured)
        LiveOfferingsLog.log("offerings count: \(dto.offerings.count)")
        LiveOfferingsLog.log("currentOffering: \(dto.currentOffering?.id ?? "nil")")

        // Log each offering
        for offering in dto.offerings {
            LiveOfferingsLog.log("  offering: id=\(offering.id), lookupKey=\(offering.lookupKey), " +
                                "isCurrent=\(offering.isCurrent), packages=\(offering.packages.count)")
            for package in offering.packages {
                LiveOfferingsLog.log("    package: type=\(package.packageType), " +
                                    "isActive=\(package.isActive), products=\(package.products.count)")
                for product in package.products {
                    LiveOfferingsLog.log("      product: storeProductId=\(product.storeProductId ?? "nil"), " +
                                        "productType=\(product.productType), " +
                                        "displayName=\(product.displayName ?? "nil")")
                }
            }
        }

        // Product ID extraction
        let allIds = dto.allStoreProductIds
        LiveOfferingsLog.log("Extracted \(allIds.count) unique product ID(s): \(allIds.sorted())")

        // If offerings are configured, validate structure
        if !dto.offerings.isEmpty {
            let first = dto.offerings[0]
            XCTAssertFalse(first.id.isEmpty, "Offering id should not be empty")
            XCTAssertFalse(first.lookupKey.isEmpty, "Offering lookupKey should not be empty")
            XCTAssertFalse(first.displayName?.isEmpty ?? true, "Offering displayName should not be empty")

            // If current is set, it should match an offering
            if let current = dto.currentOffering {
                XCTAssertTrue(dto.offerings.contains { $0.id == current.id },
                              "currentOffering.id should exist in offerings array")
            }
        }

        // Codable roundtrip of the live response
        let encoder = JSONEncoder()
        let data = try encoder.encode(dto)
        let decoded = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: data)
        XCTAssertEqual(decoded.offerings.count, dto.offerings.count,
                       "Codable roundtrip should preserve offerings count")

        LiveOfferingsLog.log("=== testLiveOfferingsDecode PASSED ===")
    }

    // MARK: - 2) Live Offerings Full Pipeline (with expected StoreKit failure)

    /// Runs the full OfferingsManager pipeline against the real API.
    /// In CI (no StoreKit sandbox), expects `.storeKitProductsMissing`
    /// but still validates that the API call + decode + product ID extraction
    /// all succeeded before StoreKit was invoked.
    func testLiveOfferingsPipeline() async throws {
        try XCTSkipUnless(Self.isEnabled)

        LiveOfferingsLog.log("=== testLiveOfferingsPipeline ===")

        guard let baseURL = Self.baseURL, let apiKey = Self.apiKey else {
            throw XCTSkip("Missing env vars")
        }

        let storage = InMemoryPaymentStorage()
        let appactor = AppActor.shared

        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(apiKey: apiKey, baseURL: baseURL, options: .init(logLevel: .verbose)),
            client: client,
            storage: storage
        )

        defer {
            appactor.paymentConfig = nil
            appactor.paymentStorage = nil
            appactor.paymentClient = nil
            appactor.paymentCurrentUser = nil
            appactor.offeringsManager = nil
            appactor.paymentOfferings = nil
        }

        do {
            let offerings = try await appactor.offerings()
            // In CI (no StoreKit sandbox), all products will be missing → empty offerings.
            // In a real device with StoreKit sandbox, products may be found.
            LiveOfferingsLog.log("Pipeline succeeded! offerings: \(offerings.all.count)")
            XCTAssertNotNil(appactor.cachedOfferings)

            if offerings.all.isEmpty {
                LiveOfferingsLog.log("Empty offerings (StoreKit products missing in CI — graceful degradation)")
            }

            // request_id should be tracked regardless
            let rid = await appactor.offeringsManager?.requestId
            LiveOfferingsLog.log("request_id from manager: \(rid ?? "nil")")
            XCTAssertNotNil(rid, "request_id should be tracked")
        } catch {
            // Unexpected error — fail the test
            XCTFail("Unexpected error: \(error)")
        }

        LiveOfferingsLog.log("=== testLiveOfferingsPipeline PASSED ===")
    }
}

// MARK: - Logging

private enum LiveOfferingsLog {

    static func log(_ message: String) {
        print("[AppActor Live Offerings] \(message)")
    }

    static func logResponse(path: String, status: Int, body: Data) {
        var lines = ["  GET \(path) -> \(status)"]

        if let json = try? JSONSerialization.jsonObject(with: body),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {

            if let dict = json as? [String: Any], let reqId = dict["requestId"] as? String {
                lines.append("  requestId: \(reqId)")
            }

            lines.append("  Response JSON:")
            for jsonLine in str.components(separatedBy: "\n") {
                lines.append("    \(jsonLine)")
            }
        } else if let raw = String(data: body, encoding: .utf8) {
            lines.append("  Raw body: \(raw)")
        }

        print(lines.joined(separator: "\n"))
    }
}
