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

    override func tearDown() async throws {
        appactor.profileContextSyncTask?.cancel()
        await appactor.profileContextSyncTask?.value
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
        appactor.onCustomerInfoChanged = nil
        appactor.customerInfo = .empty
        appactor.paymentLifecycle = .idle
        try? FileManager.default.removeItem(at: cacheDir)
        try await super.tearDown()
    }

    /// Awaits `task` and asserts it failed with `.notConfigured`: a result from a session that ended.
    private func assertNotConfigured<T>(_ task: Task<T, Error>, _ message: String, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail(message, line: line)
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .notConfigured, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }

    /// Fulfilled by a mocked call the code under test is expected to make. Waited on with a
    /// timeout, so a regression that skips the call fails instead of hanging.
    private func calledExpectation(_ description: String) -> XCTestExpectation {
        let called = expectation(description: description)
        called.assertForOverFulfill = false
        return called
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
    private func serveUserTargetedRemoteConfig(holdingUserA started: XCTestExpectation? = nil, until release: AsyncSignal? = nil) {
        mockClient.getRemoteConfigsHandler = { appUserId, _, _, _ in
            guard let appUserId else {
                return .fresh([], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
            }
            if appUserId == "user_a", let started, let release {
                started.fulfill()
                await release.wait()
            }
            let tier = AppActorRemoteConfigItemDTO(key: "tier", value: .string(appUserId), valueType: "string")
            return .fresh([tier], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
        }
    }

    // MARK: - I-S6-3: a logIn that resolves after reset()

    private func holdLogin(started: XCTestExpectation, release: AsyncSignal) {
        mockClient.loginHandler = { request in
            started.fulfill()
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
        let loginStarted = calledExpectation("/login sent")
        let releaseLogin = AsyncSignal()
        holdLogin(started: loginStarted, release: releaseLogin)

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await fulfillment(of: [loginStarted], timeout: 2)
        await appactor.reset()
        await releaseLogin.signal()

        await assertNotConfigured(login, "a logIn that outlived reset() must not succeed")
        XCTAssertNil(storage.currentAppUserId, "reset() wiped the identity; the late answer must not restore it")
        XCTAssertNil(storage.appAccountToken)
        XCTAssertNil(storage.lastRequestId)
    }

    func testLogInThatResolvesAfterResetAndConfigureLeavesTheNewSessionAlone() async throws {
        let loginStarted = calledExpectation("/login sent")
        let releaseLogin = AsyncSignal()
        holdLogin(started: loginStarted, release: releaseLogin)

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await fulfillment(of: [loginStarted], timeout: 2)
        await appactor.reset()
        let nextStorage = InMemoryPaymentStorage()
        configure(storage: nextStorage)
        let nextUserId = nextStorage.currentAppUserId
        let nextToken = nextStorage.appAccountToken
        // Another logIn of the new session is mid-transition; the late one must not end it.
        let nextWatcher = try XCTUnwrap(appactor.transactionWatcher)
        await nextWatcher.beginIdentityTransition(appUserId: nextUserId)
        await releaseLogin.signal()

        await assertNotConfigured(login, "a logIn that outlived reset() must not succeed")
        XCTAssertEqual(nextStorage.currentAppUserId, nextUserId)
        XCTAssertEqual(nextStorage.appAccountToken, nextToken)
        XCTAssertNil(storage.currentAppUserId)
        XCTAssertNotEqual(appactor.customerInfo.appUserId, "user_b")
        let seeded = await etagManager.cached(AppActorCustomerInfo.self, for: .customer(appUserId: "user_b"))
        XCTAssertNil(seeded, "the old session's answer is not seeded into the next session's cache")
        let stillTransitioning = await nextWatcher.isIdentityTransitioning
        XCTAssertTrue(stillTransitioning)
        await nextWatcher.endIdentityTransition()
    }

    func testLogInThatResolvesAfterAReconfigureIsDropped() async throws {
        let loginStarted = calledExpectation("/login sent")
        let releaseLogin = AsyncSignal()
        holdLogin(started: loginStarted, release: releaseLogin)

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await fulfillment(of: [loginStarted], timeout: 2)
        // A cancelled startup reverts to idle without reset(); configure() then runs again.
        appactor.paymentLifecycle = .idle
        configure(storage: InMemoryPaymentStorage())
        await releaseLogin.signal()

        await assertNotConfigured(login, "a logIn from the previous session must not succeed")
        XCTAssertEqual(storage.currentAppUserId, "user_a")
    }

    func testResetDuringTheReceiptDrainKeepsLogInFromReachingTheServer() async throws {
        let queueStore = InMemoryPaymentQueueStore()
        configure(storage: storage, queueStore: queueStore)
        let postStarted = calledExpectation("receipt POST sent")
        let releasePost = AsyncSignal()
        mockClient.postReceiptHandler = { _ in
            postStarted.fulfill()
            await releasePost.wait()
            return AppActorReceiptPostResponse(status: "ok", requestId: nil)
        }
        queueStore.upsert(.fixture(key: "apple:1", transactionId: "1", appUserId: "user_a"))

        let login = Task { try await appactor.logIn(newAppUserId: "user_b") }
        await fulfillment(of: [postStarted], timeout: 2)
        await appactor.reset()
        await releasePost.signal()

        await assertNotConfigured(login, "a logIn that outlived reset() must not succeed")
        XCTAssertTrue(mockClient.loginCalls.isEmpty, "the reset identity is never merged into user_b")
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
        let fetchStarted = calledExpectation("user_a's fetch sent")
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fulfillment(of: [fetchStarted], timeout: 2)
        _ = try await appactor.logIn(newAppUserId: "user_b")
        await releaseFetch.signal()
        let configs = try await fetch.value

        XCTAssertEqual(configs["tier"], .string("user_b"))
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string("user_b"))
    }

    func testRemoteConfigFetchCancelledByLogOutIsFetchedAgainForTheNewUser() async throws {
        let client = try XCTUnwrap(mockClient)
        let fetchStarted = calledExpectation("user_a's fetch sent")
        let fetchCancelled = calledExpectation("user_a's fetch cancelled by logOut's cache clear")
        let releaseLaterFetches = AsyncSignal()
        client.getRemoteConfigsHandler = { appUserId, _, _, _ in
            guard let appUserId else {
                return .fresh([], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
            }
            if appUserId == "user_a" {
                if client.getRemoteConfigsCalls.filter({ $0.appUserId == "user_a" }).count == 1 {
                    fetchStarted.fulfill()
                    // Like URLSession, a cancelled request ends at once.
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        fetchCancelled.fulfill()
                        throw error
                    }
                } else {
                    // A retry that still read user_a completes only after logOut switched.
                    await releaseLaterFetches.wait()
                }
            }
            let tier = AppActorRemoteConfigItemDTO(key: "tier", value: .string(appUserId), valueType: "string")
            return .fresh([tier], eTag: nil, requestId: nil, signatureVerified: false, requiresUserContext: true)
        }

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fulfillment(of: [fetchStarted], timeout: 2)
        _ = try await appactor.logOut()
        await fulfillment(of: [fetchCancelled], timeout: 2)
        await releaseLaterFetches.signal()
        let configs = try await fetch.value

        let anonymousId = try XCTUnwrap(storage.currentAppUserId)
        XCTAssertTrue(anonymousId.hasPrefix("appactor-anon-"))
        XCTAssertEqual(configs["tier"], .string(anonymousId))
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string(anonymousId))
    }

    func testRemoteConfigFetchedForAnIdSwitchedAwayFromIsFetchedAgain() async throws {
        let fetchStarted = calledExpectation("user_a's fetch sent")
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fulfillment(of: [fetchStarted], timeout: 2)
        // Same session, no cache clear and so no cancel: only the ID check catches it.
        storage.setAppUserId("user_z")
        await releaseFetch.signal()
        let configs = try await fetch.value

        XCTAssertEqual(configs["tier"], .string("user_z"))
        XCTAssertEqual(appactor.cachedRemoteConfigs?["tier"], .string("user_z"))
    }

    func testRemoteConfigFetchedBeforeResetIsNotPublishedIntoTheNextSession() async throws {
        let fetchStarted = calledExpectation("user_a's fetch sent")
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fulfillment(of: [fetchStarted], timeout: 2)
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
        let fetchStarted = calledExpectation("user_a's fetch sent")
        let releaseFetch = AsyncSignal()
        serveUserTargetedRemoteConfig(holdingUserA: fetchStarted, until: releaseFetch)

        let fetch = Task { try await appactor.getRemoteConfigs() }
        await fulfillment(of: [fetchStarted], timeout: 2)
        await appactor.reset()
        await releaseFetch.signal()

        await assertNotConfigured(fetch, "a fetch that outlived reset() must not return the old user's values")
        XCTAssertNil(appactor.cachedRemoteConfigs)
    }

    // MARK: - I-G-1: a processed revocation refreshes the customer

    func testRevokedTransactionAnswerRefreshesCustomerInfo() async throws {
        let queueStore = InMemoryPaymentQueueStore()
        configure(storage: storage, queueStore: queueStore)
        await appactor.wireReceiptCustomerInfoUpdateHandler()
        mockClient.postReceiptHandler = { _ in .revokedTransaction }
        let refreshed = calledExpectation("customer info fetched after the revocation")
        let published = calledExpectation("the refreshed customer info published")
        appactor.onCustomerInfoChanged = { _ in published.fulfill() }
        mockClient.getCustomerHandler = { appUserId, _ in
            refreshed.fulfill()
            return .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
        }
        queueStore.markPosted(key: "apple:12345")
        queueStore.upsert(.fixture(
            transactionId: "12345",
            jws: StoreKitJWSFixture.transaction(revoked: true),
            appUserId: "user_a",
            source: .transactionUpdates
        ))

        await appactor.paymentProcessor?.drainAll()

        await fulfillment(of: [refreshed, published], timeout: 2)
        XCTAssertEqual(mockClient.postReceiptCalls.count, 1)
        XCTAssertEqual(mockClient.getCustomerCalls.first?.appUserId, "user_a")
        XCTAssertEqual(appactor.customerInfo.appUserId, "user_a")
    }

    func testRevocationRefreshDoesNotJoinACustomerFetchAlreadyInFlight() async throws {
        let client = try XCTUnwrap(mockClient)
        let firstStarted = calledExpectation("the host's customer fetch sent")
        let releaseFirst = AsyncSignal()
        let ownRequest = calledExpectation("the refresh sends its own request")
        client.getCustomerHandler = { appUserId, _ in
            if client.getCustomerCalls.count == 1 {
                // The host's fetch, sent before the server committed the revocation.
                firstStarted.fulfill()
                await releaseFirst.wait()
            } else {
                ownRequest.fulfill()
            }
            return .fresh(AppActorCustomerInfo(appUserId: appUserId), eTag: nil, requestId: nil, signatureVerified: false)
        }
        let hostFetch = Task { try await appactor.getCustomerInfo() }
        await fulfillment(of: [firstStarted], timeout: 2)

        // A refresh that joined the host's fetch would wait on it: the expectation then times
        // out, and releasing the host's fetch afterwards lets the test end instead of hanging.
        let refresh = Task { await appactor.refreshCustomerInfoAfterRevocation() }
        await fulfillment(of: [ownRequest], timeout: 2)
        await releaseFirst.signal()
        await refresh.value
        _ = try await hostFetch.value
    }
}
