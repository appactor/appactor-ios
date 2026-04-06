import XCTest
@testable import AppActor

final class PaymentStorageTests: XCTestCase {

    private var defaults: UserDefaults!
    private var storage: AppActorUserDefaultsPaymentStorage!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.appactor.payment.tests")!
        defaults.removePersistentDomain(forName: "com.appactor.payment.tests")
        storage = AppActorUserDefaultsPaymentStorage(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.appactor.payment.tests")
        super.tearDown()
    }

    // MARK: - App User ID

    func testCurrentAppUserIdIsNilInitially() {
        XCTAssertNil(storage.currentAppUserId)
    }

    func testGenerateAnonymousAppUserId() {
        let id = storage.generateAnonymousAppUserId()
        XCTAssertTrue(id.hasPrefix("appactor-anon-"))
        XCTAssertEqual(storage.currentAppUserId, id)
    }

    func testAnonymousAppUserIdMatchesUUIDv4Format() {
        let id = storage.generateAnonymousAppUserId()

        // Must be exactly: appactor-anon-<lowercased-uuid>
        // UUID format: 8-4-4-4-12 hex chars
        let pattern = #"^appactor-anon-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        let match = regex.firstMatch(in: id, range: range)

        XCTAssertNotNil(match, "Anon ID '\(id)' must match appactor-anon-<uuid-v4-lowercase>")
    }

    func testEnsureAppUserIdGeneratesIfMissing() {
        let id = storage.ensureAppUserId()
        XCTAssertTrue(id.hasPrefix("appactor-anon-"))
        XCTAssertEqual(storage.currentAppUserId, id)
    }

    func testEnsureAppUserIdReturnsExisting() {
        storage.setAppUserId("user_123")
        let id = storage.ensureAppUserId()
        XCTAssertEqual(id, "user_123")
    }

    func testSetAppUserId() {
        storage.setAppUserId("custom_user")
        XCTAssertEqual(storage.currentAppUserId, "custom_user")
    }

    // MARK: - Server User ID

    func testServerUserIdIsNilInitially() {
        XCTAssertNil(storage.serverUserId)
    }

    func testSetServerUserId() {
        storage.setServerUserId("550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(storage.serverUserId, "550e8400-e29b-41d4-a716-446655440000")
    }

    func testClearServerUserId() {
        storage.setServerUserId("some-uuid")
        storage.setServerUserId(nil)
        XCTAssertNil(storage.serverUserId)
    }

    // MARK: - Last Request ID

    func testLastRequestIdIsNilInitially() {
        XCTAssertNil(storage.lastRequestId)
    }

    func testSetLastRequestId() {
        storage.setLastRequestId("req_abc123")
        XCTAssertEqual(storage.lastRequestId, "req_abc123")
    }

    // MARK: - Clear All

    func testClearAllKeepsLastRequestId() {
        storage.setAppUserId("user")
        storage.setServerUserId("uuid")
        storage.setLastRequestId("req_xyz")

        storage.clearAll()

        XCTAssertNil(storage.currentAppUserId)
        XCTAssertNil(storage.serverUserId)
        XCTAssertEqual(storage.lastRequestId, "req_xyz", "lastRequestId should survive clearAll")
    }
}
