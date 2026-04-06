import XCTest
@testable import AppActor

// MARK: - Tests

@MainActor
final class PaymentIdentityTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage
        )
    }

    override func tearDown() {
        appactor.asaTask?.cancel()
        appactor.asaTask = nil
        appactor.foregroundTask?.cancel()
        appactor.foregroundTask = nil
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
        appactor.paymentCurrentUser = nil
        appactor.paymentETagManager = nil
        appactor.offeringsManager = nil
        appactor.customerManager = nil
        appactor.remoteConfigManager = nil
        appactor.experimentManager = nil
        appactor.paymentProcessor = nil
        appactor.transactionWatcher = nil
        appactor.paymentQueueStore = nil
        appactor.paymentLifecycle = .idle
        super.tearDown()
    }

    // MARK: - Identify

    func testIdentifyGeneratesAnonIdWhenMissing() async throws {
        let info = try await appactor.identify()

        XCTAssertEqual(mockClient.identifyCalls.count, 1)
        let request = mockClient.identifyCalls[0]
        XCTAssertTrue(request.appUserId.hasPrefix("appactor-anon-"))
        XCTAssertEqual(request.platform, "ios")
        XCTAssertEqual(info.appUserId, request.appUserId)
    }

    func testIdentifyUsesExistingAppUserId() async throws {
        storage.setAppUserId("existing_user_42")

        let info = try await appactor.identify()

        XCTAssertEqual(mockClient.identifyCalls.count, 1)
        XCTAssertEqual(mockClient.identifyCalls[0].appUserId, "existing_user_42")
        XCTAssertEqual(info.appUserId, "existing_user_42")
    }

    func testIdentifyOverwritesLocalIdWhenServerDiffers() async throws {
        storage.setAppUserId("original_id")

        mockClient.identifyHandler = { _ in
            AppActorIdentifyResult(
                appUserId: "server_normalized_id",
                customerInfo: AppActorCustomerInfo(appUserId: "server_normalized_id"),
                customerETag: nil,
                requestId: "req_1",
                signatureVerified: false
            )
        }

        let info = try await appactor.identify()

        XCTAssertEqual(info.appUserId, "server_normalized_id")
        XCTAssertEqual(storage.currentAppUserId, "server_normalized_id")
    }

    func testIdentifyStoresCustomerCache() async throws {
        let entitlement = AppActorEntitlementInfo(id: "premium", isActive: true)
        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(
                    entitlements: ["premium": entitlement],
                    appUserId: request.appUserId
                ),
                customerETag: "hash_abc",
                requestId: "req_2",
                signatureVerified: false
            )
        }

        let _ = try await appactor.identify()

        // Customer cache should be seeded
        let appUserId = storage.currentAppUserId!
        let cached = await appactor.paymentETagManager?.cached(AppActorCustomerInfo.self, for: .customer(appUserId: appUserId))
        XCTAssertNotNil(cached, "Customer cache should be populated after identify")
        XCTAssertEqual(cached?.value.appUserId, appUserId)
        XCTAssertEqual(cached?.eTag, "hash_abc")
        XCTAssertEqual(cached?.value.entitlements.count, 1)
        XCTAssertEqual(cached?.value.entitlements["premium"]?.id, "premium")
    }

    func testIdentifySendsConsistentAppUserId() async throws {
        let _ = try await appactor.identify()

        let request = mockClient.identifyCalls[0]
        XCTAssertNotNil(request.appUserId)

        // Subsequent call should send the same app_user_id
        let _ = try await appactor.identify()
        XCTAssertEqual(
            mockClient.identifyCalls[0].appUserId,
            mockClient.identifyCalls[1].appUserId
        )
    }

    func testIdentifyTracksRequestId() async throws {
        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: nil,
                requestId: "req_tracked_123",
                signatureVerified: false
            )
        }

        let _ = try await appactor.identify()

        XCTAssertEqual(storage.lastRequestId, "req_tracked_123")
        XCTAssertEqual(appactor.lastPaymentRequestId, "req_tracked_123")
    }

    func testPurchaseOptionsAlwaysEnsureAppAccountToken() {
        XCTAssertNil(storage.appAccountToken)

        let prepared = appactor.attachAppAccountToken(to: [], storage: storage)

        XCTAssertEqual(storage.appAccountToken, prepared.token)
        XCTAssertEqual(prepared.token.uuidString.lowercased(), storage.appAccountToken?.uuidString.lowercased())
        XCTAssertEqual(prepared.options.count, 1)
    }

    func testIdentifyThrowsWhenNotConfigured() async {
        appactor.paymentConfig = nil
        appactor.paymentClient = nil
        appactor.paymentStorage = nil

        do {
            let _ = try await appactor.identify()
            XCTFail("Should have thrown")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Login

    func testLoginOverwritesAppUserId() async throws {
        storage.setAppUserId("old_user")

        let info = try await appactor.logIn(newAppUserId: "new_user")

        XCTAssertEqual(mockClient.loginCalls.count, 1)
        XCTAssertEqual(mockClient.loginCalls[0].currentAppUserId, "old_user")
        XCTAssertEqual(mockClient.loginCalls[0].newAppUserId, "new_user")
        XCTAssertEqual(info.appUserId, "new_user")
        XCTAssertEqual(storage.currentAppUserId, "new_user")
    }

    func testLoginCallsIdentifyFirstIfNoCurrentUser() async throws {
        // No app_user_id stored
        XCTAssertNil(storage.currentAppUserId)

        let info = try await appactor.logIn(newAppUserId: "target_user")

        // Should have called identify first (to establish identity), then login
        // Login now returns full customer info, so no post-login identify needed
        XCTAssertEqual(mockClient.identifyCalls.count, 1) // 1 pre-login only
        XCTAssertEqual(mockClient.loginCalls.count, 1)
        XCTAssertEqual(info.appUserId, "target_user")
    }

    func testLoginConflictThrows409Error() async {
        storage.setAppUserId("current_user")

        mockClient.loginHandler = { _ in
            throw AppActorError.serverError(
                httpStatus: 409,
                code: "CONFLICT",
                message: "User already exists",
                details: nil,
                requestId: "req_conflict"
            )
        }

        do {
            let _ = try await appactor.logIn(newAppUserId: "conflicting_user")
            XCTFail("Should have thrown")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .server)
            XCTAssertEqual(error.httpStatus, 409)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginDoesNotOverwriteOnConflict() async {
        storage.setAppUserId("current_user")

        mockClient.loginHandler = { _ in
            throw AppActorError.serverError(
                httpStatus: 409,
                code: "CONFLICT",
                message: "conflict",
                details: nil,
                requestId: nil
            )
        }

        do {
            let _ = try await appactor.logIn(newAppUserId: "conflict")
        } catch {
            // Expected
        }

        // app_user_id should remain unchanged
        XCTAssertEqual(storage.currentAppUserId, "current_user")
    }

    func testLoginValidatesNewAppUserId() async {
        storage.setAppUserId("current")

        do {
            let _ = try await appactor.logIn(newAppUserId: "")
            XCTFail("Should have thrown for empty ID")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .validation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoginTracksRequestId() async throws {
        storage.setAppUserId("current_user")

        let _ = try await appactor.logIn(newAppUserId: "new_user")

        // lastRequestId should be set from the login call
        XCTAssertNotNil(storage.lastRequestId)
    }

    // MARK: - Logout

    func testLogoutResetsToAnonymousAndCallsIdentify() async throws {
        storage.setAppUserId("logged_in_user")
        storage.setServerUserId("some-uuid")

        let result = try await appactor.logOut()

        XCTAssertTrue(result)

        // Should have called logout on server
        XCTAssertEqual(mockClient.logoutCalls.count, 1)
        XCTAssertEqual(mockClient.logoutCalls[0].appUserId, "logged_in_user")

        // Should have generated a new anonymous ID
        let newId = storage.currentAppUserId
        XCTAssertNotNil(newId)
        XCTAssertTrue(newId!.hasPrefix("appactor-anon-"))
        XCTAssertNotEqual(newId, "logged_in_user")

        // Should have called identify with the new anonymous ID
        XCTAssertGreaterThanOrEqual(mockClient.identifyCalls.count, 1)
    }

    func testLogoutIgnoresServerFailure() async throws {
        storage.setAppUserId("user_to_logout")

        mockClient.logoutHandler = { _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        // Should not throw (server logout is best-effort)
        let result = try await appactor.logOut()

        XCTAssertFalse(result, "Should return false when server logout fails")

        // Should still have reset to anonymous
        let newId = storage.currentAppUserId
        XCTAssertNotNil(newId)
        XCTAssertTrue(newId!.hasPrefix("appactor-anon-"))
    }

    func testLogoutGeneratesNewAnonId() async throws {
        // Must be identified (non-anonymous) to logout — matches RC/Adapty behavior
        storage.setAppUserId("real-user-123")
        let _ = try await appactor.identify()

        let _ = try await appactor.logOut()

        // identify() is called again post-logout with a new anonymous ID
        let postLogoutIdentify = mockClient.identifyCalls.last!
        XCTAssertTrue(postLogoutIdentify.appUserId.hasPrefix("appactor-anon-"),
                      "logOut() should generate a new anonymous app_user_id")
    }

    func testLogoutThrowsForAnonymousUser() async throws {
        // Anonymous user should not be able to logout
        let _ = try await appactor.identify()
        XCTAssertTrue(appactor.isAnonymous)

        do {
            let _ = try await appactor.logOut()
            XCTFail("logOut() should throw for anonymous user")
        } catch {
            // Expected — anonymous user cannot logout
        }
    }

    func testLogoutClearsCurrentUser() async throws {
        storage.setAppUserId("user")

        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: nil,
                requestId: "req_id",
                signatureVerified: false
            )
        }

        let _ = try await appactor.identify()
        XCTAssertNotNil(appactor.customerInfo.appUserId)

        let _ = try await appactor.logOut()

        // customerInfo gets set by the post-logout identify call
        // but the server user ID should have been cleared before re-identify
        XCTAssertTrue(appactor.isAnonymous)
    }

    func testLogoutThrowsWhenPostIdentifyFails() async {
        storage.setAppUserId("user")

        // First identify call (in logOut's post-logout identify) fails
        var callCount = 0
        mockClient.identifyHandler = { request in
            callCount += 1
            if callCount > 0 {
                // All identify calls fail (the one in logOut)
                throw AppActorError.networkError(URLError(.notConnectedToInternet))
            }
            return AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: nil,
                requestId: nil,
                signatureVerified: false
            )
        }

        do {
            let _ = try await appactor.logOut()
            XCTFail("Should have thrown when post-logout identify fails")
        } catch {
            // Expected — post-logout identify failure propagates
        }
    }

    // MARK: - JSON Decoding (contract verification)

    func testIdentifyResponseDecodesFromBackendJSON() throws {
        let json = """
        {
            "requestDate": "2025-06-15T12:00:00Z",
            "requestDateMs": 1750000000000,
            "requestId": "req_xyz789",
            "appUserId": "user_abc123",
            "customer": {
                "entitlements": {
                    "premium": {
                        "isActive": true,
                        "productId": "com.app.monthly",
                        "expiresAt": "2025-07-15T12:00:00Z",
                        "purchaseDate": "2025-06-15T12:00:00Z"
                    }
                },
                "subscriptions": {
                    "com.app.monthly": {
                        "productId": "com.app.monthly",
                        "isActive": true,
                        "expiresAt": "2025-07-15T12:00:00Z",
                        "purchaseDate": "2025-06-15T12:00:00Z",
                        "periodType": "normal",
                        "store": "app_store"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(AppActorIdentifyResponseDTO.self, from: json)

        XCTAssertEqual(response.appUserId, "user_abc123")
        XCTAssertEqual(response.requestId, "req_xyz789")
        XCTAssertEqual(response.requestDate, "2025-06-15T12:00:00Z")
        XCTAssertEqual(response.requestDateMs, 1750000000000)
        XCTAssertNotNil(response.customer.entitlements?["premium"])
        XCTAssertEqual(response.customer.entitlements?["premium"]?.isActive, true)
        XCTAssertNotNil(response.customer.subscriptions?["com.app.monthly"])

        // Verify DTO → ServerCustomerInfo conversion
        let info = AppActorCustomerInfo(dto: response.customer, appUserId: response.appUserId, requestDate: response.requestDate)
        XCTAssertEqual(info.appUserId, "user_abc123")
        XCTAssertEqual(info.entitlements.count, 1)
        XCTAssertEqual(info.entitlements["premium"]?.id, "premium")
        XCTAssertEqual(info.entitlements["premium"]?.isActive, true)
        XCTAssertEqual(info.subscriptions.count, 1)
        XCTAssertTrue(info.hasActiveEntitlement("premium"))
    }

    func testIdentifyResponseDecodesWithEmptyCustomer() throws {
        let json = """
        {
            "requestId": "req_001",
            "appUserId": "anon_user",
            "customer": {
                "entitlements": {},
                "subscriptions": {}
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(AppActorIdentifyResponseDTO.self, from: json)

        XCTAssertEqual(response.appUserId, "anon_user")
        XCTAssertNil(response.requestDate)
        XCTAssertNil(response.requestDateMs)

        let info = AppActorCustomerInfo(dto: response.customer, appUserId: response.appUserId, requestDate: nil)
        XCTAssertEqual(info.entitlements.count, 0)
        XCTAssertEqual(info.subscriptions.count, 0)
        XCTAssertTrue(info.activeEntitlements.isEmpty)
    }

    func testIdentifyResponseDecodesFromDataUserPayload() throws {
        let json = """
        {
            "requestId": "req_user_v2",
            "data": {
                "user": {
                    "id": "uuid_123",
                    "appUserId": "user_abc123",
                    "aliases": ["old_id"],
                    "entitlements": {
                        "premium": {
                            "isActive": true,
                            "productId": "com.app.monthly"
                        }
                    },
                    "subscriptions": {},
                    "nonSubscriptions": {},
                    "tokenBalance": {
                        "renewable": 500,
                        "nonRenewable": 200,
                        "total": 700
                    },
                    "firstSeenAt": "2026-01-15T00:00:00.000Z",
                    "lastSeenAt": "2026-03-06T12:00:00.000Z"
                }
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AppActorIdentifyResponseDTO.self, from: json)

        XCTAssertEqual(response.appUserId, "user_abc123")
        XCTAssertEqual(response.requestId, "req_user_v2")
        XCTAssertEqual(response.customer.tokenBalance?.renewable, 500)
        XCTAssertEqual(response.customer.firstSeen, "2026-01-15T00:00:00.000Z")
        XCTAssertEqual(response.customer.lastSeen, "2026-03-06T12:00:00.000Z")

        let info = AppActorCustomerInfo(dto: response.customer, appUserId: response.appUserId, requestDate: response.requestDate)
        XCTAssertTrue(info.hasActiveEntitlement("premium"))
        XCTAssertEqual(info.tokenBalance?.total, 700)
    }

    func testLoginResponseDecodesFromBackendJSON() throws {
        let json = """
        {
            "requestDate": "2024-01-15T10:30:00.000Z",
            "requestDateMs": 1705312200000,
            "requestId": "req_login_1",
            "appUserId": "new_logged_in_user",
            "serverUserId": "new-uuid",
            "customer": {
                "entitlements": {},
                "subscriptions": {},
                "firstSeen": "2024-01-15T10:30:00.000Z"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(AppActorLoginResponseDTO.self, from: json)

        XCTAssertEqual(response.appUserId, "new_logged_in_user")
        XCTAssertEqual(response.serverUserId, "new-uuid")
        XCTAssertEqual(response.requestId, "req_login_1")
        XCTAssertNotNil(response.customer)
    }

    func testLoginResponseDecodesFromDataUserPayload() throws {
        let json = """
        {
            "requestId": "req_login_v2",
            "data": {
                "serverUserId": "server_uuid_1",
                "user": {
                    "id": "uuid_123",
                    "appUserId": "new_logged_in_user",
                    "aliases": ["anon_old"],
                    "entitlements": {},
                    "subscriptions": {},
                    "nonSubscriptions": {},
                    "tokenBalance": null,
                    "firstSeenAt": "2026-01-15T00:00:00.000Z",
                    "lastSeenAt": "2026-03-06T12:00:00.000Z"
                }
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AppActorLoginResponseDTO.self, from: json)
        XCTAssertEqual(response.appUserId, "new_logged_in_user")
        XCTAssertEqual(response.serverUserId, "server_uuid_1")
        XCTAssertEqual(response.requestId, "req_login_v2")
        XCTAssertNil(response.customer.tokenBalance)
        XCTAssertEqual(response.customer.firstSeen, "2026-01-15T00:00:00.000Z")
    }

    func testLogoutResponseDecodesFromBackendJSON() throws {
        let json = """
        {
            "data": { "success": true },
            "requestId": "req_logout_1"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(AppActorPaymentResponse<AppActorLogoutData>.self, from: json)

        XCTAssertEqual(response.data.success, true)
    }

    func testErrorResponseDecodesFromBackendJSON() throws {
        let json = """
        {
            "error": {
                "code": "VALIDATION_ERROR",
                "message": "app_user_id is required",
                "details": "field: app_user_id"
            },
            "requestId": "req_err_1"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(AppActorErrorResponse.self, from: json)

        XCTAssertEqual(response.error.code, "VALIDATION_ERROR")
        XCTAssertEqual(response.error.message, "app_user_id is required")
        XCTAssertEqual(response.error.details, "field: app_user_id")
        XCTAssertEqual(response.requestId, "req_err_1")
    }

    // MARK: - Accessors

    func testIsAnonymousWithAnonId() {
        storage.setAppUserId("appactor-anon-some-uuid")
        XCTAssertTrue(appactor.isAnonymous)
    }

    func testIsAnonymousWithRealId() {
        storage.setAppUserId("real_user_123")
        XCTAssertFalse(appactor.isAnonymous)
    }

    func testIsAnonymousWhenNoId() {
        XCTAssertTrue(appactor.isAnonymous)
    }

    func testOfflineCustomerInfoHelperReturnsFreshSnapshotWhenIdentityMatches() {
        storage.setAppUserId("user_123")
        appactor.customerInfo = AppActorCustomerInfo(
            entitlements: [
                "legacy": AppActorEntitlementInfo(id: "legacy", isActive: true)
            ],
            appUserId: "user_123"
        )

        let offlineInfo = appactor.offlineCustomerInfoIfIdentityMatches(
            expectedAppUserId: "user_123",
            offlineKeys: ["premium"]
        )

        XCTAssertEqual(offlineInfo?.appUserId, "user_123")
        XCTAssertTrue(offlineInfo?.isComputedOffline == true)
        // Fresh snapshot must contain ONLY StoreKit-derived keys, not stale cached entitlements
        XCTAssertEqual(offlineInfo?.activeEntitlementKeys, ["premium"])
    }

    func testOfflineSnapshotExcludesStaleCachedEntitlements() {
        storage.setAppUserId("user_123")
        appactor.customerInfo = AppActorCustomerInfo(
            entitlements: [
                "expired_sub": AppActorEntitlementInfo(id: "expired_sub", isActive: true),
                "old_promo": AppActorEntitlementInfo(id: "old_promo", isActive: true),
            ],
            appUserId: "user_123"
        )

        let offlineInfo = appactor.offlineCustomerInfoIfIdentityMatches(
            expectedAppUserId: "user_123",
            offlineKeys: ["premium"]
        )

        XCTAssertEqual(offlineInfo?.activeEntitlementKeys, ["premium"],
                       "Offline snapshot must not include stale cached entitlements")
        XCTAssertTrue(offlineInfo?.subscriptions.isEmpty == true,
                      "Offline snapshot must not carry stale subscriptions")
    }

    func testOfflineCustomerInfoHelperReturnsNilWhenIdentityChanged() {
        storage.setAppUserId("user_123")
        storage.setAppUserId("other_user")

        let offlineInfo = appactor.offlineCustomerInfoIfIdentityMatches(
            expectedAppUserId: "user_123",
            offlineKeys: ["premium"]
        )

        XCTAssertNil(offlineInfo)
    }

    func testConsumePurgedDeadLettersReturnsRecordsOnce() async {
        let queueStore = InMemoryPaymentQueueStore()
        queueStore.enqueuePurgedDeadLetter(
            AppActorPurgedDeadLetterSummary(
                transactionId: "purged_tx",
                productId: "com.test.monthly",
                attemptCount: 3,
                lastError: "INTERNAL"
            )
        )

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            paymentQueueStore: queueStore
        )

        let purged = queueStore.consumePurgedDeadLetters()
        XCTAssertEqual(
            purged,
            [
                AppActorPurgedDeadLetterSummary(
                    transactionId: "purged_tx",
                    productId: "com.test.monthly",
                    attemptCount: 3,
                    lastError: "INTERNAL"
                )
            ]
        )
        let consumedAgain = queueStore.consumePurgedDeadLetters()
        XCTAssertTrue(consumedAgain.isEmpty)
    }

    // MARK: - Reset

    func testResetPaymentClearsIdentity() async throws {
        // Establish identity first
        let _ = try await appactor.identify()
        XCTAssertNotNil(storage.currentAppUserId)

        await appactor.reset()

        XCTAssertNil(storage.currentAppUserId)
        XCTAssertNil(storage.serverUserId)
        XCTAssertNil(storage.lastRequestId)
    }

    func testResetPaymentClearsCustomerCache() async throws {
        // Seed some customer cache data via identify
        let _ = try await appactor.identify()

        // Verify etagManager has cached data
        let appUserId = storage.currentAppUserId!
        let cached = await appactor.paymentETagManager?.cached(AppActorCustomerInfo.self, for: .customer(appUserId: appUserId))
        XCTAssertNotNil(cached, "Cache should be populated after identify")

        await appactor.reset()

        // After reset, the etagManager itself is cleared (set to nil)
        XCTAssertNil(appactor.paymentETagManager)
    }

    func testResetPaymentClearsInMemoryState() async throws {
        let _ = try await appactor.identify()
        XCTAssertNotNil(appactor.customerInfo.appUserId)
        XCTAssertNotNil(appactor.appUserId)

        await appactor.reset()

        XCTAssertNil(appactor.customerInfo.appUserId)
        XCTAssertNil(appactor.appUserId)
        XCTAssertNil(appactor.lastPaymentRequestId)
        XCTAssertTrue(appactor.isAnonymous)
    }

    func testResetPaymentRequiresReconfigure() async {
        let _ = try? await appactor.identify()

        await appactor.reset()

        // After reset, all SDK calls should throw paymentNotConfigured
        do {
            let _ = try await appactor.identify()
            XCTFail("Should have thrown paymentNotConfigured after reset")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResetIsStrongerThanLogout() async throws {
        // Must be identified (non-anonymous) to logout
        storage.setAppUserId("real-user-123")
        let _ = try await appactor.identify()
        let appUserId = storage.currentAppUserId
        XCTAssertNotNil(appUserId, "app_user_id should exist after identify")

        // Logout generates a new anonymous ID (preserves SDK state)
        let _ = try await appactor.logOut()
        XCTAssertNotNil(storage.currentAppUserId, "logOut() should generate new anonymous ID")

        // Reset clears everything
        await appactor.reset()
        XCTAssertNil(storage.currentAppUserId,
                     "reset() should clear app_user_id")
    }

    // MARK: - Validation

    func testValidationRejectsEmptyId() {
        XCTAssertThrowsError(try AppActorPaymentValidation.validateAppUserId(""))
    }

    func testValidationRejectsNan() {
        XCTAssertThrowsError(try AppActorPaymentValidation.validateAppUserId("nan"))
        XCTAssertThrowsError(try AppActorPaymentValidation.validateAppUserId("NaN"))
        XCTAssertThrowsError(try AppActorPaymentValidation.validateAppUserId("NAN"))
    }

    func testValidationRejectsTooLong() {
        let longId = String(repeating: "x", count: 256)
        XCTAssertThrowsError(try AppActorPaymentValidation.validateAppUserId(longId))
    }

    func testValidationAcceptsValidIds() {
        XCTAssertNoThrow(try AppActorPaymentValidation.validateAppUserId("user_123"))
        XCTAssertNoThrow(try AppActorPaymentValidation.validateAppUserId("a"))
        XCTAssertNoThrow(try AppActorPaymentValidation.validateAppUserId(String(repeating: "x", count: 255)))
    }

    // MARK: - Identify → Customer Cache Integration

    /// After identify(), getCustomerInfo() fetches fresh data from server.
    /// The identify-seeded ETag is sent as a conditional request.
    func testIdentifyThenFetchCustomerInfoUsesETag() async throws {
        let entitlement = AppActorEntitlementInfo(id: "premium", isActive: true)
        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(
                    entitlements: ["premium": entitlement],
                    appUserId: request.appUserId
                ),
                customerETag: "hash_from_identify",
                requestId: "req_id_1",
                signatureVerified: false
            )
        }

        var capturedETag: String?
        mockClient.getCustomerHandler = { appUserId, eTag in
            capturedETag = eTag
            let info = AppActorCustomerInfo(
                entitlements: ["premium": entitlement],
                appUserId: appUserId
            )
            return .fresh(info, eTag: "new_hash", requestId: "req_2", signatureVerified: false)
        }

        // Step 1: identify seeds the cache (including ETag)
        let _ = try await appactor.identify()

        // Step 2: getCustomerInfo always goes to network
        let customerInfo = try await appactor.getCustomerInfo()

        XCTAssertEqual(customerInfo.appUserId, storage.currentAppUserId)
        XCTAssertEqual(customerInfo.entitlements.count, 1)
        XCTAssertTrue(customerInfo.hasActiveEntitlement("premium"))

        // ETag from identify should NOT be sent (forceRefresh skips ETag)
        XCTAssertNil(capturedETag, "getCustomerInfo() should skip ETag (force refresh)")
    }

    /// Identify should store the eTag from ETag header even when customer has empty entitlements.
    func testIdentifyStoresHashEvenWithEmptyCustomer() async throws {
        mockClient.identifyHandler = { request in
            AppActorIdentifyResult(
                appUserId: request.appUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
                customerETag: "empty_customer_hash",
                requestId: "req_empty",
                signatureVerified: false
            )
        }

        let _ = try await appactor.identify()

        let appUserId = storage.currentAppUserId!
        let cached = await appactor.paymentETagManager?.cached(AppActorCustomerInfo.self, for: .customer(appUserId: appUserId))
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.eTag, "empty_customer_hash")
        XCTAssertEqual(cached?.value.entitlements.count, 0)
        XCTAssertTrue(cached?.value.activeEntitlements.isEmpty == true)
    }

    func testGetCustomerInfoFallsBackToOfflineSnapshotWhenIdentityMatches() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentIdentityOffline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
        let checker = MockStoreKitEntitlementChecker()
        checker.productIds = ["com.app.monthly"]
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager,
            entitlementChecker: checker,
            cacheTTL: 3600
        )

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager
        )

        storage.setAppUserId("user_123")
        appactor.customerInfo = .empty
        await etagManager.storeFresh(
            AppActorOfferingsResponseDTO(
                currentOffering: nil,
                offerings: [],
                productEntitlements: ["com.app.monthly": ["premium"]]
            ),
            for: .offerings,
            eTag: nil
        )

        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        let info = try await appactor.getCustomerInfo()

        XCTAssertEqual(info.appUserId, "user_123")
        XCTAssertTrue(info.isComputedOffline)
        XCTAssertEqual(info.activeEntitlementKeys, ["premium"])
        XCTAssertEqual(appactor.customerInfo.activeEntitlementKeys, ["premium"])
    }

    func testQueuedPurchaseOfflineCustomerInfoReturnsSnapshotWhenIdentityMatches() async throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentQueuedOffline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
        let checker = MockStoreKitEntitlementChecker()
        checker.productIds = ["com.app.monthly"]
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager,
            entitlementChecker: checker,
            cacheTTL: 3600
        )

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager
        )

        storage.setAppUserId("user_123")
        appactor.customerInfo = .empty
        await etagManager.storeFresh(
            AppActorOfferingsResponseDTO(
                currentOffering: nil,
                offerings: [],
                productEntitlements: ["com.app.monthly": ["premium"]]
            ),
            for: .offerings,
            eTag: nil
        )

        let info = await appactor.queuedPurchaseOfflineCustomerInfo(appUserId: "user_123")

        XCTAssertEqual(info?.appUserId, "user_123")
        XCTAssertTrue(info?.isComputedOffline == true)
        XCTAssertEqual(info?.activeEntitlementKeys, ["premium"])
    }

    func testGetCustomerInfoOfflineFallbackSkipsWhenIdentityChanges() async {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentIdentityOfflineRace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
        let checker = MockStoreKitEntitlementChecker()
        checker.activeProductIdsHandler = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["com.app.monthly"]
        }
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager,
            entitlementChecker: checker,
            cacheTTL: 3600
        )

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager
        )

        storage.setAppUserId("user_123")
        appactor.customerInfo = .empty
        await etagManager.storeFresh(
            AppActorOfferingsResponseDTO(
                currentOffering: nil,
                offerings: [],
                productEntitlements: ["com.app.monthly": ["premium"]]
            ),
            for: .offerings,
            eTag: nil
        )

        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.networkError(URLError(.notConnectedToInternet))
        }

        let task = Task {
            try await self.appactor.getCustomerInfo()
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        storage.setAppUserId("other_user")

        do {
            _ = try await task.value
            XCTFail("Expected original network error when identity changes during offline fallback")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .network)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(appactor.customerInfo, .empty)
    }

    func testQueuedPurchaseOfflineCustomerInfoReturnsNilWhenIdentityChanges() async {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaymentQueuedOfflineRace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
        let checker = MockStoreKitEntitlementChecker()
        checker.activeProductIdsHandler = {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["com.app.monthly"]
        }
        let customerManager = AppActorCustomerManager(
            client: mockClient,
            etagManager: etagManager,
            entitlementChecker: checker,
            cacheTTL: 3600
        )

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_123",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            customerManager: customerManager
        )

        storage.setAppUserId("user_123")
        await etagManager.storeFresh(
            AppActorOfferingsResponseDTO(
                currentOffering: nil,
                offerings: [],
                productEntitlements: ["com.app.monthly": ["premium"]]
            ),
            for: .offerings,
            eTag: nil
        )

        let task = Task {
            await self.appactor.queuedPurchaseOfflineCustomerInfo(appUserId: "user_123")
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        storage.setAppUserId("other_user")

        let info = await task.value
        XCTAssertNil(info)
    }
}
