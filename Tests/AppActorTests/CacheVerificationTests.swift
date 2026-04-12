import XCTest
@testable import AppActor

final class CacheVerificationTests: XCTestCase {

    // MARK: - resolvedVerification

    func testResolvedVerificationPrefersNewField() {
        let entry = AppActorCacheEntry(
            data: Data(), eTag: nil, cachedAt: Date(),
            responseVerified: false,
            verificationResult: .verified
        )
        XCTAssertEqual(entry.resolvedVerification, .verified)
    }

    func testResolvedVerificationFallsBackToLegacyTrue() {
        let entry = AppActorCacheEntry(
            data: Data(), eTag: nil, cachedAt: Date(),
            responseVerified: true,
            verificationResult: nil
        )
        XCTAssertEqual(entry.resolvedVerification, .verified)
    }

    func testResolvedVerificationFallsBackToLegacyFalse() {
        let entry = AppActorCacheEntry(
            data: Data(), eTag: nil, cachedAt: Date(),
            responseVerified: false,
            verificationResult: nil
        )
        XCTAssertEqual(entry.resolvedVerification, .failed)
    }

    func testResolvedVerificationNotRequested() {
        let entry = AppActorCacheEntry(
            data: Data(), eTag: nil, cachedAt: Date(),
            responseVerified: false,
            verificationResult: .notRequested
        )
        XCTAssertEqual(entry.resolvedVerification, .notRequested)
    }

    func testResolvedVerificationFailedOverridesLegacyTrue() {
        let entry = AppActorCacheEntry(
            data: Data(), eTag: nil, cachedAt: Date(),
            responseVerified: true,
            verificationResult: .failed
        )
        XCTAssertEqual(entry.resolvedVerification, .failed)
    }

    // MARK: - Backward-compatible Codable decoding

    func testLegacyCacheEntryDecodesWithNilVerificationResult() throws {
        // Simulate a cache file written by an older SDK version (no verificationResult key)
        let json = """
        {
            "data": "\(Data("test".utf8).base64EncodedString())",
            "eTag": "W/\\"abc\\"",
            "cachedAt": 1000000,
            "responseVerified": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(AppActorCacheEntry.self, from: Data(json.utf8))

        XCTAssertNil(entry.verificationResult)
        XCTAssertTrue(entry.responseVerified)
        XCTAssertEqual(entry.resolvedVerification, .verified)
    }

    func testLegacyCacheEntryUnverifiedDecodesAsFailed() throws {
        let json = """
        {
            "data": "\(Data("test".utf8).base64EncodedString())",
            "cachedAt": 1000000,
            "responseVerified": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(AppActorCacheEntry.self, from: Data(json.utf8))

        XCTAssertNil(entry.verificationResult)
        XCTAssertFalse(entry.responseVerified)
        XCTAssertEqual(entry.resolvedVerification, .failed)
    }

    // MARK: - New cache entry encodes verificationResult

    func testNewCacheEntryEncodesVerificationResult() throws {
        let entry = AppActorCacheEntry(
            data: Data("test".utf8), eTag: "W/\"abc\"", cachedAt: Date(),
            responseVerified: true,
            verificationResult: .verified
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(entry)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("verificationResult"))
        XCTAssertTrue(json.contains("verified"))
    }
}
