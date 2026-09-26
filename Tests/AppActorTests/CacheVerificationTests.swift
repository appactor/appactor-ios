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

    func testSaltRoutePurgeRemovesOnlyUnverifiedSaltRouteEntries() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("appactor-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let diskStore = AppActorCacheDiskStore(directory: cacheDir)
        let etagManager = AppActorETagManager(diskStore: diskStore, responseVerificationEnabled: true)
        let experiments = AppActorCacheResource.experiments(appUserId: "user_1")
        await etagManager.storeFresh(["v": "signed"], for: .customer(appUserId: "user_1"), eTag: nil, verified: true)
        await etagManager.storeFresh(["v": "signed"], for: .remoteConfigs(appUserId: nil), eTag: nil, verified: true)
        await etagManager.storeFresh(["v": "local"], for: experiments, eTag: nil, verified: false)
        // Left by an SDK version that accepted unsigned salt-route responses.
        await etagManager.storeFresh(["v": "unsigned"], for: .offerings, eTag: "W/\"u\"", verified: false)
        await etagManager.storeFresh(["v": "unsigned"], for: .offlineProductCatalog, eTag: nil, verified: false)
        await etagManager.storeFresh(["v": "unsigned"], for: .remoteConfigs(appUserId: "user_1"), eTag: nil, verified: false)

        // The per-launch hygiene pass leaves unsigned-but-not-failed entries alone.
        await etagManager.clearUnverifiedIfNeeded()
        let offeringsAfterHygiene = await etagManager.cached([String: String].self, for: .offerings)
        XCTAssertNotNil(offeringsAfterHygiene)

        await diskStore.clearUnverifiedSaltRouteEntries()

        let customer = await etagManager.cached([String: String].self, for: .customer(appUserId: "user_1"))
        let signedRemoteConfigs = await etagManager.cached([String: String].self, for: .remoteConfigs(appUserId: nil))
        let experimentAssignments = await etagManager.cached([String: String].self, for: experiments)
        let offerings = await etagManager.cached([String: String].self, for: .offerings)
        let catalog = await etagManager.cached([String: String].self, for: .offlineProductCatalog)
        let unsignedRemoteConfigs = await etagManager.cached([String: String].self, for: .remoteConfigs(appUserId: "user_1"))
        XCTAssertEqual(customer?.value["v"], "signed")
        XCTAssertEqual(signedRemoteConfigs?.value["v"], "signed")
        XCTAssertEqual(experimentAssignments?.value["v"], "local")
        XCTAssertNil(offerings)
        XCTAssertNil(catalog)
        XCTAssertNil(unsignedRemoteConfigs)
    }
}
