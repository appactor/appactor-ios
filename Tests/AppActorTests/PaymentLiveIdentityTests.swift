import XCTest
@testable import AppActor

// MARK: - Live Integration Tests (opt-in)
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
//   swift test --filter AppActorTests.PaymentLiveIdentityTests

// MARK: - Logging (nonisolated, safe to call from @Sendable closures)

private enum LiveTestLog {

    static func log(_ message: String) {
        print("[AppActor Live Test] \(message)")
    }

    static func logResponse(path: String, status: Int, body: Data) {
        var lines = ["  POST \(path) -> \(status)"]

        if let json = try? JSONSerialization.jsonObject(with: body),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let str = String(data: pretty, encoding: .utf8) {

            // Extract requestId if present
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

// MARK: - Tests

@MainActor
final class PaymentLiveIdentityTests: XCTestCase {

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

    /// Last 6 chars of the API key for safe logging.
    private static var apiKeyHint: String {
        guard let key = apiKey, key.count >= 6 else { return "??????" }
        return "...\(key.suffix(6))"
    }

    // MARK: - Per-test state

    private var appactor: AppActor!
    private var storage: InMemoryPaymentStorage!

    override func setUp() async throws {
        try XCTSkipUnless(Self.isEnabled, "Live tests skipped (set RUN_LIVE_TESTS=1)")

        guard let baseURL = Self.baseURL else {
            throw XCTSkip("APPACTOR_BASE_URL not set or invalid")
        }
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else {
            throw XCTSkip("APPACTOR_PUBLIC_API_KEY not set")
        }

        storage = InMemoryPaymentStorage()
        appactor = AppActor.shared

        let client = AppActorPaymentClient(
            baseURL: baseURL,
            apiKey: apiKey,
            headerMode: .bearer,
            responseLogger: { path, status, body in
                LiveTestLog.logResponse(path: path, status: status, body: body)
            }
        )

        let config = AppActorPaymentConfiguration(
            apiKey: apiKey,
            baseURL: baseURL,
            options: .init(logLevel: .verbose)
        )

        appactor.configureForTesting(
            config: config,
            client: client,
            storage: storage
        )

        LiveTestLog.log("--- Test setup complete (key: \(Self.apiKeyHint), baseURL: \(baseURL)) ---")
    }

    override func tearDown() {
        appactor?.asaTask?.cancel()
        appactor?.asaTask = nil
        appactor?.foregroundTask?.cancel()
        appactor?.foregroundTask = nil
        appactor?.paymentConfig = nil
        appactor?.paymentStorage = nil
        appactor?.paymentClient = nil
        appactor?.paymentCurrentUser = nil
        appactor?.paymentETagManager = nil
        appactor?.offeringsManager = nil
        appactor?.customerManager = nil
        appactor?.remoteConfigManager = nil
        appactor?.experimentManager = nil
        appactor?.paymentProcessor = nil
        appactor?.transactionWatcher = nil
        appactor?.paymentQueueStore = nil
        appactor?.paymentLifecycle = .idle
        super.tearDown()
    }

    // MARK: - 1) Live Identify

    func testLiveIdentify() async throws {
        try XCTSkipUnless(Self.isEnabled)

        LiveTestLog.log("=== testLiveIdentify ===")

        // Fresh anon ID (storage is empty)
        XCTAssertNil(storage.currentAppUserId, "Storage should start empty")

        let info = try await appactor.identify()

        LiveTestLog.log("Returned user: appUserId=\(info.appUserId ?? "nil")")

        // Assertions
        XCTAssertTrue(info.appUserId?.hasPrefix("appactor-anon-") == true,
                       "Anon ID should start with appactor-anon-, got: \(info.appUserId ?? "nil")")
        XCTAssertEqual(appactor.appUserId, info.appUserId)
        XCTAssertNotNil(appactor.customerInfo.appUserId)
        XCTAssertNotNil(appactor.lastPaymentRequestId, "request_id should be tracked")

        LiveTestLog.log("=== testLiveIdentify PASSED ===")
    }

    // MARK: - 2) Live Login

    func testLiveLoginAliasBehavior() async throws {
        try XCTSkipUnless(Self.isEnabled)

        LiveTestLog.log("=== testLiveLoginAliasBehavior ===")

        // Step 1: Identify to get an anonymous baseline
        let anonInfo = try await appactor.identify()
        LiveTestLog.log("Step 1 - Identified as anon: \(anonInfo.appUserId ?? "nil")")
        XCTAssertTrue(anonInfo.appUserId?.hasPrefix("appactor-anon-") == true)

        // Step 2: Login with a unique test user ID
        let testUserId = "test_user_\(UUID().uuidString.prefix(8).lowercased())"
        LiveTestLog.log("Step 2 - Logging in as: \(testUserId)")

        let loginInfo = try await appactor.logIn(newAppUserId: testUserId)
        LiveTestLog.log("Step 2 - Login returned: appUserId=\(loginInfo.appUserId ?? "nil")")

        XCTAssertEqual(appactor.appUserId, testUserId,
                       "SDK currentAppUserId should be \(testUserId), got: \(appactor.appUserId ?? "nil")")
        XCTAssertFalse(appactor.isAnonymous)

        // Step 3: Re-identify should return the same user
        let refreshed = try await appactor.identify()
        LiveTestLog.log("Step 3 - Re-identify returned: \(refreshed.appUserId ?? "nil")")
        XCTAssertEqual(refreshed.appUserId, testUserId,
                       "Re-identify should return same user ID")

        LiveTestLog.log("=== testLiveLoginAliasBehavior PASSED ===")
    }

    // MARK: - 3) Live Logout

    func testLiveLogout() async throws {
        try XCTSkipUnless(Self.isEnabled)

        LiveTestLog.log("=== testLiveLogout ===")

        // Step 1: Identify
        let info = try await appactor.identify()
        LiveTestLog.log("Step 1 - Identified as: \(info.appUserId ?? "nil")")

        // Step 2: Login to a named user
        let namedId = "logout_test_\(UUID().uuidString.prefix(8).lowercased())"
        let _ = try await appactor.logIn(newAppUserId: namedId)
        LiveTestLog.log("Step 2 - Logged in as: \(namedId)")
        XCTAssertEqual(appactor.appUserId, namedId)

        // Step 3: Logout
        LiveTestLog.log("Step 3 - Logging out...")
        let result = try await appactor.logOut()
        LiveTestLog.log("Step 3 - Logout completed locally: \(result)")

        let postLogoutId = appactor.appUserId
        LiveTestLog.log("Step 3 - Post-logout currentAppUserId: \(postLogoutId ?? "nil")")

        // Assertions
        XCTAssertNotNil(postLogoutId, "Should have a new anon ID after logout")
        XCTAssertTrue(postLogoutId!.hasPrefix("appactor-anon-"),
                       "Post-logout ID should be anonymous, got: \(postLogoutId!)")
        XCTAssertNotEqual(postLogoutId, namedId,
                          "Post-logout ID should differ from the logged-in ID")

        XCTAssertEqual(appactor.customerInfo, .empty,
                       "RC-style logOut() should clear customerInfo until the next explicit refresh")

        LiveTestLog.log("=== testLiveLogout PASSED ===")
    }
}
