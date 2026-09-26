import XCTest
@_spi(AppActorPluginSupport) @testable import AppActor

/// Results that land after an `await` must not be applied to an identity or a session that has
/// moved on (audit I-S6-3, I-S6-2, I-S4-2), and a revoked receipt refreshes the customer (I-G-1).
@MainActor
final class IdentitySessionTests: XCTestCase {

    private var appactor: AppActor!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var etagManager: AppActorETagManager!
    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IdentitySessionTests-\(UUID().uuidString)")
        etagManager = AppActorETagManager(diskStore: AppActorCacheDiskStore(directory: cacheDir))
        configure(storage: storage)
        storage.setAppUserId("user_a")
    }

    override func tearDown() {
        appactor.profileContextSyncTask?.cancel()
        appactor.profileContextSyncTask = nil
        appactor.paymentConfig = nil
        appactor.paymentStorage = nil
        appactor.paymentClient = nil
        appactor.paymentETagManager = nil
        appactor.offeringsManager = nil
        appactor.customerManager = nil
        appactor.remoteConfigManager = nil
        appactor.experimentManager = nil
        appactor.paymentProcessor = nil
        appactor.transactionWatcher = nil
        appactor.paymentQueueStore = nil
        appactor.paymentRemoteConfigs = nil
        appactor.customerInfo = .empty
        appactor.paymentLifecycle = .idle
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    private func configure(storage: InMemoryPaymentStorage, queueStore: InMemoryPaymentQueueStore = InMemoryPaymentQueueStore()) {
        appactor.configureForTesting(
            config: AppActorPaymentConfiguration(apiKey: "pk_test_session", baseURL: URL(string: "https://api.test.appactor.com")!),
            client: mockClient,
            storage: storage,
            etagManager: etagManager,
            paymentQueueStore: queueStore
        )
    }

    /// Remote config that targets users: the public probe says so, and each user gets their
    /// own `tier`. The fetch for `user_a` waits on `release` once `started` fires.
    private func serveUserTargetedRemoteConfig(holdingUserA started: AsyncSignal? = nil, until release: AsyncSignal? = nil) {
        mockClient.getRemoteConfigsHandler = { appUserId, _, _, _ in
            guard let appUserId else {
                return .fresh([], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
            }
            if appUserId == "user_a", let started, let release {
                await started.signal()
                await release.wait()
            }
            let tier = AppActorRemoteConfigItemDTO(key: "tier", value: .string(appUserId), valueType: "string")
            return .fresh([tier], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
        }
    }

    // MARK: - I-S6-3: a logIn that resolves after reset()

    private func holdLogin(started: AsyncSignal, release: AsyncSignal) {
        mockClient.loginHandler = { request in
            await started.signal()
            await release.wait()
            return AppActorLoginResult(
                appUserId: request.newAppUserId,
                customerInfo: AppActorCustomerInfo(appUserId: request.newAppUserId),
                customerETag: nil,
                requestId: "req_late_login",
                signatureVerified: false
            )
        }
    }

    func testLogInThatResolvesAfterResetDoesNotSignTheUserBackIn() async throws {
        let loginStarted = AsyncSignal()
        let releaseLogin = AsyncSignal()
        holdLogin(started: loginStarted, release: releaseLogin)

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await loginStarted.wait()
        await appactor.reset()
        await releaseLogin.signal()

        do {
            _ = try await login.value
            XCTFail("a logIn that outlived reset() must not succeed")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
        XCTAssertNil(storage.currentAppUserId, "reset() wiped the identity; the late answer must not restore it")
        XCTAssertNil(storage.appAccountToken)
        XCTAssertNil(storage.lastRequestId)
    }

    func testLogInThatResolvesAfterResetAndConfigureLeavesTheNewSessionAlone() async throws {
        let loginStarted = AsyncSignal()
        let releaseLogin = AsyncSignal()
        holdLogin(started: loginStarted, release: releaseLogin)

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await loginStarted.wait()
        await appactor.reset()
        let nextStorage = InMemoryPaymentStorage()
        configure(storage: nextStorage)
        let nextUserId = nextStorage.currentAppUserId
        let nextToken = nextStorage.appAccountToken
        await releaseLogin.signal()

        do {
            _ = try await login.value
            XCTFail("a logIn that outlived reset() must not succeed")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
        XCTAssertEqual(nextStorage.currentAppUserId, nextUserId)
        XCTAssertEqual(nextStorage.appAccountToken, nextToken)
        XCTAssertNil(storage.currentAppUserId)
        XCTAssertNotEqual(appactor.customerInfo.appUserId, "user_b")
        let seeded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_b"))
        XCTAssertNil(seeded, "the old session's answer is not seeded into the next session's cache")
    }

    // MARK: - I-S6-2: caches go only once the login succeeded

    func testFailedLogInKeepsTheCurrentUsersCaches() async throws {
        await appactor.customerManager?.seedCache(info: AppActorCustomerInfo(appUserId: "user_a"), eTag: "etag_a", appUserId: "user_a")
        serveUserTargetedRemoteConfig()
        _ = try await appactor.getRemoteConfigs()
        mockClient.postExperimentAssignmentHandler = { _, _, _, _ in
            .success(
                AppActorExperimentAssignmentDTO(
                    inExperiment: true,
                    reason: nil,
                    experiment: .init(id: "exp_1", key: "paywall"),
                    variant: .init(id: "var_1", key: "annual_first", valueType: "string", payload: .string("annual")),
                    assignedAt: "2026-09-26T00:00:00.000Z"
                ),
                requestId: nil,
                signatureVerified: false
            )
        }
        _ = try await appactor.getExperimentAssignment(experimentKey: "paywall")

        let offline = AppActorError.networkError(URLError(.notConnectedToInternet))
        mockClient.loginHandler = { _ in throw offline }
        do {
            _ = try await appactor.logIn(newAppUserId: "user_b")
            XCTFail("expected the login to fail")
        } catch {}

        XCTAssertEqual(storage.currentAppUserId, "user_a")
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string("user_a"))
        let cachedCustomer = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_a"))
        XCTAssertNotNil(cachedCustomer)
        // Still offline: both come from what was cached before the failed login.
        mockClient.getRemoteConfigsHandler = { _, _, _, _ in throw offline }
        mockClient.postExperimentAssignmentHandler = { _, _, _, _ in throw offline }
        let configs = try await appactor.getRemoteConfigs()
        XCTAssertEqual(configs["tier"], .string("user_a"))
        let assignment = try await appactor.getExperimentAssignment(experimentKey: "paywall")
        XCTAssertEqual(assignment?.variantKey, "annual_first")
    }

    func testSuccessfulLogInClearsThePreviousUsersCaches() async throws {
        await appactor.customerManager?.seedCache(info: AppActorCustomerInfo(appUserId: "user_a"), eTag: "etag_a", appUserId: "user_a")
        serveUserTargetedRemoteConfig()
        _ = try await appactor.getRemoteConfigs()

        _ = try await appactor.logIn(newAppUserId: "user_b")

        XCTAssertEqual(storage.currentAppUserId, "user_b")
        XCTAssertNil(appactor.cachedRemoteConfigs)
        let remoteConfigCache = await appactor.remoteConfigManager?.cached
        XCTAssertNil(remoteConfigCache)
        let previousUser = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_a"))
        XCTAssertNil(previousUser)
        let newUser = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_b"))
        XCTAssertEqual(newUser?.value.appUserId, "user_b")
    }

    func testLogInToTheIdAlreadyInUseKeepsTheFreshSeed() async throws {
        _ = try await appactor.logIn(newAppUserId: "user_a")

        let seeded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_a"))
        XCTAssertEqual(seeded?.value.appUserId, "user_a")
    }

    // MARK: - I-S4-2: remote config fetched for the previous identity

    func testRemoteConfigFetchedForThePreviousUserIsNotServedAfterLogIn() async throws {
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fetchStarted.wait()
        _ = try await appactor.logIn(newAppUserId: "user_b")
        await releaseFetch.signal()
        let configs = try await fetch.value

        XCTAssertEqual(configs["tier"], .string("user_b"))
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string("user_b"))
    }

    func testRemoteConfigFetchedBeforeResetIsNotPublishedIntoTheNextSession() async throws {
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fetchStarted.wait()
        await appactor.reset()
        let nextStorage = InMemoryPaymentStorage()
        configure(storage: nextStorage)
        nextStorage.setAppUserId("user_c")
        // reset() leaves the old manager's fetch running; it completes with user_a's values.
        await releaseFetch.signal()
        let configs = try await fetch.value

        XCTAssertEqual(configs["tier"], .string("user_c"))
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string("user_c"))
    }

    func testRemoteConfigFetchThatOutlivesResetThrowsNotConfigured() async throws {
        let fetchStarted = AsyncSignal()
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fetchStarted.wait()
        await appactor.reset()
        await releaseFetch.signal()

        do {
            _ = try await fetch.value
            XCTFail("a fetch that outlived reset() must not return the old user's values")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
        XCTAssertNil(appactor.cachedRemoteConfigs)
    }

    // MARK: - I-G-1: a processed revocation refreshes the customer

    func testRevokedTransactionAnswerRefreshesCustomerInfo() async throws {
        let queueStore = InMemoryPaymentQueueStore()
        configure(storage: storage, queueStore: queueStore)
        await appactor.wireReceiptCustomerInfoUpdateHandler()
        mockClient.postReceiptHandler = { _ in PaymentProcessorTests.revokedResponse }
        let refreshed = expectation(description: "customer info fetched after the revocation")
        mockClient.getCustomerHandler = { appUserId, _ in
            refreshed.fulfill()
            return .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
        }
        queueStore.markPosted(key: "apple:12345")
        let now = Date()
        queueStore.upsert(AppActorPaymentQueueItem(
            key: "apple:12345",
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: "12345",
            jws: StoreKitJWSFixture.transaction(revoked: true),
            signedAppTransactionInfo: nil,
            appUserId: "user_a",
            productId: "com.test.monthly",
            originalTransactionId: "12345",
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            phase: .needsPost,
            attemptCount: 0,
            nextRetryAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            lastError: nil,
            sources: [.transactionUpdates],
            claimedAt: nil
        ))

        await appactor.paymentProcessor?.drainAll()

        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
        XCTAssertEqual(mockClient.getCustomerCalls.first?.appUserId, "user_a")
    }
}
