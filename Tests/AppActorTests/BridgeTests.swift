import XCTest
@testable import AppActor

// MARK: - Bridge Error Tests

@MainActor
final class BridgeErrorTests: XCTestCase {

    // MARK: - Kind → Code Mapping

    func testNotConfiguredError() {
        let error = AppActorError.notConfigured
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_NOT_CONFIGURED)
        XCTAssertFalse(bridge.isTransient)
        XCTAssertNil(bridge.statusCode)
    }

    func testAlreadyConfiguredError() {
        let error = AppActorError.clientError(kind: .alreadyConfigured)
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_ALREADY_CONFIGURED)
        XCTAssertFalse(bridge.isTransient)
    }

    func testValidationError() {
        let error = AppActorError.validationError("bad input")
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_VALIDATION)
        XCTAssertFalse(bridge.isTransient)
    }

    func testNotAvailableError() {
        let error = AppActorError.notAvailable("iOS 16+ required")
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_NOT_AVAILABLE)
        XCTAssertFalse(bridge.isTransient)
    }

    func testNetworkError() {
        let error = AppActorError.networkError(URLError(.notConnectedToInternet))
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_NETWORK)
        XCTAssertTrue(bridge.isTransient)
    }

    func testDecodingError() {
        let error = AppActorError.decodingError(
            NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "bad json"]),
            requestId: "req-123"
        )
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_DECODING)
        XCTAssertFalse(bridge.isTransient)
        XCTAssertTrue(bridge.debugMessage?.contains("requestId=req-123") == true)
    }

    func testServerError5xx() {
        let error = AppActorError.serverError(
            httpStatus: 500,
            code: "INTERNAL",
            message: "internal error",
            details: nil,
            requestId: "req-456"
        )
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_SERVER)
        XCTAssertTrue(bridge.isTransient)
        XCTAssertEqual(bridge.statusCode, 500)
    }

    func testServerError429() {
        let error = AppActorError.serverError(
            httpStatus: 429,
            code: "RATE_LIMITED",
            message: "too many requests",
            details: nil,
            requestId: nil,
            scope: "app",
            retryAfterSeconds: 30.0
        )
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_SERVER)
        XCTAssertTrue(bridge.isTransient)
        XCTAssertEqual(bridge.statusCode, 429)
        XCTAssertTrue(bridge.debugMessage?.contains("scope=app") == true)
        XCTAssertTrue(bridge.debugMessage?.contains("retryAfter=30.0s") == true)
    }

    func testServerError4xxPermanent() {
        let error = AppActorError.serverError(
            httpStatus: 403,
            code: "FORBIDDEN",
            message: "invalid key",
            details: nil,
            requestId: nil
        )
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_SERVER)
        XCTAssertFalse(bridge.isTransient)
        XCTAssertEqual(bridge.statusCode, 403)
    }

    func testStoreKitProductsMissingError() {
        let error = AppActorError.storeKitProductsMissing(requestedIds: ["com.app.monthly"])
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_STORE_PRODUCTS_MISSING)
        XCTAssertFalse(bridge.isTransient)
    }

    func testCustomerNotFoundError() {
        let error = AppActorError.customerNotFound(appUserId: "user_1", requestId: "req-789")
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_CUSTOMER_NOT_FOUND)
        XCTAssertFalse(bridge.isTransient)
        XCTAssertEqual(bridge.statusCode, 404)
    }

    func testPurchaseFailedError() {
        let error = AppActorError.clientError(kind: .purchaseFailed, message: "user cancelled")
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_PURCHASE_FAILED)
    }

    func testReceiptPostFailedError() {
        let error = AppActorError.receiptPostFailed("server rejected")
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_RECEIPT_POST_FAILED)
    }

    func testReceiptQueuedForRetryError() {
        let error = AppActorError.clientError(kind: .receiptQueuedForRetry)
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_RECEIPT_QUEUED_FOR_RETRY)
        XCTAssertTrue(bridge.isTransient)
    }

    func testPurchaseAlreadyInProgressError() {
        let error = AppActorError.purchaseAlreadyInProgress
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_PURCHASE_ALREADY_IN_PROGRESS)
        XCTAssertFalse(bridge.isTransient)
    }

    func testProductNotAvailableError() {
        let error = AppActorError.clientError(kind: .productNotAvailableInStorefront)
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_PRODUCT_NOT_AVAILABLE)
    }

    func testSignatureVerificationErrors() {
        let signatureKinds: [AppActorError.Kind] = [
            .signatureVerificationFailed,
            .signatureTimestampOutOfRange,
            .signatureMissing,
            .nonceMismatch,
            .intermediateCertInvalid,
            .intermediateKeyExpired,
        ]
        for kind in signatureKinds {
            let error = AppActorError.clientError(kind: kind)
            let bridge = AppActorBridgeError(from: error)
            XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_SIGNATURE_VERIFICATION_FAILED,
                           "Kind \(kind) should map to SIGNATURE_VERIFICATION_FAILED")
        }
    }

    // MARK: - Non-AppActorError

    func testUnknownErrorMapping() {
        let error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "oops"])
        let bridge = AppActorBridgeError(from: error)
        XCTAssertEqual(bridge.code, AppActorBridgeError.CODE_UNKNOWN)
        XCTAssertFalse(bridge.isTransient)
        XCTAssertNil(bridge.statusCode)
        XCTAssertNotNil(bridge.debugMessage)
    }

    // MARK: - toDictionary

    func testToDictionaryIncludesRequiredFields() {
        let bridge = AppActorBridgeError(
            code: "SERVER",
            message: "internal error",
            isTransient: true,
            statusCode: 500,
            debugMessage: "code=INTERNAL"
        )
        let dict = bridge.toDictionary()
        XCTAssertEqual(dict["code"] as? String, "SERVER")
        XCTAssertEqual(dict["message"] as? String, "internal error")
        XCTAssertEqual(dict["isTransient"] as? Bool, true)
        XCTAssertEqual(dict["statusCode"] as? Int, 500)
        XCTAssertEqual(dict["debugMessage"] as? String, "code=INTERNAL")
    }

    func testToDictionaryIncludesStructuredFields() {
        let bridge = AppActorBridgeError(
            code: "SERVER",
            message: "too many requests",
            isTransient: true,
            statusCode: 429,
            debugMessage: "code=RATE_LIMIT_EXCEEDED, requestId=req_123",
            backendCode: "RATE_LIMIT_EXCEEDED",
            requestId: "req_123",
            scope: "app",
            retryAfterSeconds: 12.5
        )
        let dict = bridge.toDictionary()
        XCTAssertEqual(dict["backendCode"] as? String, "RATE_LIMIT_EXCEEDED")
        XCTAssertEqual(dict["requestId"] as? String, "req_123")
        XCTAssertEqual(dict["scope"] as? String, "app")
        XCTAssertEqual(dict["retryAfterSeconds"] as? Double, 12.5)
    }

    func testToDictionaryOmitsNilFields() {
        let bridge = AppActorBridgeError(
            code: "NETWORK",
            message: "no connection",
            isTransient: true
        )
        let dict = bridge.toDictionary()
        XCTAssertNil(dict["statusCode"])
        XCTAssertNil(dict["debugMessage"])
        XCTAssertEqual(dict.count, 3) // code, message, isTransient
    }

    // MARK: - Debug Message Construction

    func testDebugMessageIncludesAllParts() {
        let error = AppActorError.serverError(
            httpStatus: 429,
            code: "RATE_LIMITED",
            message: "slow down",
            details: "too many requests from IP",
            requestId: "req-abc",
            scope: "ip",
            retryAfterSeconds: 10.5
        )
        let bridge = AppActorBridgeError(from: error)
        let debug = bridge.debugMessage!
        XCTAssertTrue(debug.contains("code=RATE_LIMITED"))
        XCTAssertTrue(debug.contains("details=too many requests from IP"))
        XCTAssertTrue(debug.contains("requestId=req-abc"))
        XCTAssertTrue(debug.contains("scope=ip"))
        XCTAssertTrue(debug.contains("retryAfter=10.5s"))
    }

    func testDebugMessageNilWhenNoMetadata() {
        let error = AppActorError.clientError(kind: .notConfigured)
        let bridge = AppActorBridgeError(from: error)
        XCTAssertNil(bridge.debugMessage)
    }
}

// MARK: - Bridge Receipt Event Tests

@MainActor
final class BridgeReceiptEventTests: XCTestCase {

    func testPostedOkMapping() {
        let detail = AppActorReceiptPipelineEventDetail(
            event: .postedOk(transactionId: "tx_123"),
            productId: "com.app.monthly",
            appUserId: "user_1"
        )
        let bridge = AppActorBridgeReceiptEvent(from: detail)
        XCTAssertEqual(bridge.type, AppActorBridgeReceiptEvent.TYPE_POSTED_OK)
        XCTAssertEqual(bridge.transactionId, "tx_123")
        XCTAssertEqual(bridge.productId, "com.app.monthly")
        XCTAssertEqual(bridge.appUserId, "user_1")
        XCTAssertNil(bridge.retryCount)
        XCTAssertNil(bridge.nextAttemptAt)
        XCTAssertNil(bridge.errorCode)
        XCTAssertNil(bridge.key)
    }

    func testRetryScheduledMapping() {
        let nextAt = Date(timeIntervalSince1970: 1_700_000_000)
        let detail = AppActorReceiptPipelineEventDetail(
            event: .retryScheduled(transactionId: "tx_456", attempt: 3, nextAttemptAt: nextAt, errorCode: "TIMEOUT"),
            productId: "com.app.annual",
            appUserId: "user_2"
        )
        let bridge = AppActorBridgeReceiptEvent(from: detail)
        XCTAssertEqual(bridge.type, AppActorBridgeReceiptEvent.TYPE_RETRY_SCHEDULED)
        XCTAssertEqual(bridge.transactionId, "tx_456")
        XCTAssertEqual(bridge.retryCount, 3)
        XCTAssertNotNil(bridge.nextAttemptAt)
        XCTAssertEqual(bridge.errorCode, "TIMEOUT")
    }

    func testPermanentlyRejectedMapping() {
        let detail = AppActorReceiptPipelineEventDetail(
            event: .permanentlyRejected(transactionId: "tx_789", errorCode: "INVALID_RECEIPT"),
            productId: "com.app.lifetime",
            appUserId: "user_3"
        )
        let bridge = AppActorBridgeReceiptEvent(from: detail)
        XCTAssertEqual(bridge.type, AppActorBridgeReceiptEvent.TYPE_PERMANENTLY_REJECTED)
        XCTAssertEqual(bridge.transactionId, "tx_789")
        XCTAssertEqual(bridge.errorCode, "INVALID_RECEIPT")
        XCTAssertNil(bridge.retryCount)
    }

    func testDeadLetteredMapping() {
        let detail = AppActorReceiptPipelineEventDetail(
            event: .deadLettered(transactionId: "tx_dead", attemptCount: 10, lastErrorCode: "SERVER_ERROR"),
            productId: "com.app.weekly",
            appUserId: "user_4"
        )
        let bridge = AppActorBridgeReceiptEvent(from: detail)
        XCTAssertEqual(bridge.type, AppActorBridgeReceiptEvent.TYPE_DEAD_LETTERED)
        XCTAssertEqual(bridge.transactionId, "tx_dead")
        XCTAssertEqual(bridge.retryCount, 10)
        XCTAssertEqual(bridge.errorCode, "SERVER_ERROR")
    }

    func testDuplicateSkippedMapping() {
        let detail = AppActorReceiptPipelineEventDetail(
            event: .duplicateSkipped(key: "apple:com.app:sandbox:12345"),
            productId: "com.app.monthly",
            appUserId: "user_5"
        )
        let bridge = AppActorBridgeReceiptEvent(from: detail)
        XCTAssertEqual(bridge.type, AppActorBridgeReceiptEvent.TYPE_DUPLICATE_SKIPPED)
        XCTAssertNil(bridge.transactionId)
        XCTAssertEqual(bridge.key, "apple:com.app:sandbox:12345")
        XCTAssertNil(bridge.retryCount)
    }

    // MARK: - toDictionary

    func testToDictionaryIncludesRequiredFields() {
        let bridge = AppActorBridgeReceiptEvent(
            type: AppActorBridgeReceiptEvent.TYPE_POSTED_OK,
            transactionId: "tx_100",
            productId: "com.app.monthly",
            appUserId: "user_1"
        )
        let dict = bridge.toDictionary()
        XCTAssertEqual(dict["type"] as? String, "POSTED_OK")
        XCTAssertEqual(dict["transactionId"] as? String, "tx_100")
        XCTAssertEqual(dict["productId"] as? String, "com.app.monthly")
        XCTAssertEqual(dict["appUserId"] as? String, "user_1")
    }

    func testToDictionaryOmitsNilFields() {
        let bridge = AppActorBridgeReceiptEvent(
            type: AppActorBridgeReceiptEvent.TYPE_POSTED_OK,
            productId: "com.app.monthly",
            appUserId: "user_1"
        )
        let dict = bridge.toDictionary()
        XCTAssertNil(dict["transactionId"])
        XCTAssertNil(dict["retryCount"])
        XCTAssertNil(dict["nextAttemptAt"])
        XCTAssertNil(dict["errorCode"])
        XCTAssertNil(dict["key"])
        XCTAssertEqual(dict.count, 3) // type, productId, appUserId
    }
}

// MARK: - Bridge Integration Tests

@MainActor
final class BridgeIntegrationTests: XCTestCase {

    private var appactor: AppActor!
    private var bridge: AppActorBridge!
    private var mockClient: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!

    override func setUp() {
        super.setUp()
        appactor = AppActor.shared
        bridge = AppActorBridge.shared
        mockClient = MockPaymentClient()
        storage = InMemoryPaymentStorage()

        let config = AppActorPaymentConfiguration(
            apiKey: "pk_test_bridge",
            baseURL: URL(string: "https://api.test.appactor.com")!
        )
        appactor.configureForTesting(
            config: config,
            client: mockClient,
            storage: storage
        )
    }

    override func tearDown() {
        bridge.clearListeners()
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

    // MARK: - Synchronous Accessors

    func testBridgeExposesConfiguredIdentityAfterSetup() {
        XCTAssertNotNil(bridge.appUserId)
    }

    func testBridgeAppUserIdNilBeforeSetup() {
        // Tear down the configured state first
        appactor.paymentStorage = nil
        appactor.paymentLifecycle = .idle
        XCTAssertNil(bridge.appUserId)
    }

    func testBridgeAccessorsRequireConfiguredLifecycleEvenWhenStorageExists() {
        storage.setAppUserId("test_user_42")
        appactor.paymentLifecycle = .idle

        XCTAssertNil(bridge.appUserId)
        XCTAssertTrue(bridge.isAnonymous)
        XCTAssertNotNil(appactor.paymentStorage)
    }

    func testAppUserIdReturnsStoredValue() {
        storage.setAppUserId("test_user_42")
        XCTAssertEqual(bridge.appUserId, "test_user_42")
    }

    func testAppUserIdNilWhenNotConfiguredEvenWhenStorageExists() {
        storage.setAppUserId("stale_user_42")
        appactor.paymentLifecycle = .idle

        XCTAssertNil(bridge.appUserId)
    }

    func testAppUserIdReturnsLocalIdentityImmediatelyAfterConfiguration() {
        storage.setAppUserId("pending_user_42")
        XCTAssertEqual(bridge.appUserId, "pending_user_42")
    }

    func testIsAnonymousForAnonUser() {
        storage.setAppUserId("appactor-anon-abc123")
        XCTAssertTrue(bridge.isAnonymous)
    }

    func testIsAnonymousForIdentifiedUser() {
        storage.setAppUserId("real_user_123")
        XCTAssertFalse(bridge.isAnonymous)
    }

    func testIsAnonymousDefaultsToTrueWhenNotConfiguredEvenWhenStorageExists() {
        storage.setAppUserId("real_user_123")
        appactor.paymentLifecycle = .idle

        XCTAssertTrue(bridge.isAnonymous)
    }

    func testIsAnonymousUsesLocalIdentityImmediately() {
        storage.setAppUserId("real_user_123")
        XCTAssertFalse(bridge.isAnonymous)
    }

    func testCachedCustomerInfoReturnsCurrentValue() {
        // Reset to known state (other tests may have mutated the singleton)
        appactor.customerInfo = .empty
        let info = bridge.cachedCustomerInfo
        XCTAssertEqual(info, AppActorCustomerInfo.empty)
    }

    func testCachedOfferingsNilBeforeFetch() {
        XCTAssertNil(bridge.cachedOfferings)
    }

    // MARK: - Callback-Based Method Tests

    func testGetCustomerInfoSuccess() async {
        let expectedInfo = AppActorCustomerInfo(appUserId: "user_1")
        mockClient.getCustomerHandler = { _, _ in
            .fresh(expectedInfo, eTag: nil, requestId: nil, signatureVerified: false)
        }
        storage.setAppUserId("user_1")

        let expectation = XCTestExpectation(description: "getCustomerInfo callback")
        bridge.getCustomerInfo(
            onSuccess: { info in
                XCTAssertEqual(info.appUserId, "user_1")
                expectation.fulfill()
            },
            onError: { error in
                XCTFail("Unexpected error: \(error.code)")
            }
        )
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testGetCustomerInfoError() async {
        mockClient.getCustomerHandler = { _, _ in
            throw AppActorError.serverError(
                httpStatus: 500,
                code: "INTERNAL",
                message: "boom",
                details: nil,
                requestId: nil
            )
        }
        storage.setAppUserId("user_1")

        let expectation = XCTestExpectation(description: "getCustomerInfo error callback")
        bridge.getCustomerInfo(
            onSuccess: { _ in
                XCTFail("Should not succeed")
            },
            onError: { error in
                XCTAssertEqual(error.code, AppActorBridgeError.CODE_SERVER)
                XCTAssertTrue(error.isTransient)
                XCTAssertEqual(error.statusCode, 500)
                expectation.fulfill()
            }
        )
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testLogInSuccess() async {
        let expectedInfo = AppActorCustomerInfo(appUserId: "new_user")
        mockClient.loginHandler = { request in
            AppActorLoginResult(
                appUserId: request.newAppUserId,
                customerInfo: expectedInfo,
                customerETag: nil,
                requestId: nil,
                signatureVerified: false
            )
        }
        storage.setAppUserId("old_user")

        let expectation = XCTestExpectation(description: "logIn callback")
        bridge.logIn(
            newAppUserId: "new_user",
            onSuccess: { info in
                XCTAssertEqual(info.appUserId, "new_user")
                expectation.fulfill()
            },
            onError: { error in
                XCTFail("Unexpected error: \(error.code)")
            }
        )
        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testLogOutSuccess() async {
        storage.setAppUserId("user_to_logout")

        let expectation = XCTestExpectation(description: "logOut callback")
        bridge.logOut(
            onSuccess: { result in
                XCTAssertTrue(result)
                XCTAssertTrue(self.storage.currentAppUserId?.hasPrefix("appactor-anon-") == true)
                expectation.fulfill()
            },
            onError: { error in
                XCTFail("Unexpected error: \(error.code)")
            }
        )
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertEqual(mockClient.identifyCalls.count, 0, "RC-style logout should not re-identify")
    }

    func testConfigureValidationErrorReportsBridgeErrorWithoutCompleting() async {
        let completeExpectation = XCTestExpectation(description: "configure should not complete")
        completeExpectation.isInverted = true
        let errorExpectation = XCTestExpectation(description: "configure validation error")

        bridge.configure(
            apiKey: "   ",
            onComplete: {
                completeExpectation.fulfill()
            },
            onError: { error in
                XCTAssertEqual(error.code, AppActorBridgeError.CODE_VALIDATION)
                XCTAssertEqual(error.message, "[AppActor] Validation: apiKey must not be blank.")
                errorExpectation.fulfill()
            }
        )

        await fulfillment(of: [errorExpectation, completeExpectation], timeout: 1.0)
        XCTAssertEqual(appactor.paymentLifecycle, .configured, "Existing configured state should stay untouched")
    }

    // MARK: - Listener Tests

    func testCustomerInfoListenerFires() async {
        let expectation = XCTestExpectation(description: "customerInfo listener")
        let newInfo = AppActorCustomerInfo(appUserId: "updated_user")

        bridge.setCustomerInfoListener { info in
            XCTAssertEqual(info.appUserId, "updated_user")
            expectation.fulfill()
        }

        // Trigger the change
        appactor.customerInfo = newInfo

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    func testClearListenersRemovesCallbacks() {
        bridge.setCustomerInfoListener { _ in
            XCTFail("Listener should have been cleared")
        }
        bridge.clearListeners()

        // This should NOT trigger the listener
        appactor.customerInfo = AppActorCustomerInfo(appUserId: "no_listener")

        // No assertion needed — the XCTFail inside the listener will trigger if it fires
    }

    func testReceiptPipelineListenerFires() async {
        let expectation = XCTestExpectation(description: "receipt pipeline listener")

        bridge.setReceiptPipelineListener { event in
            XCTAssertEqual(event.type, AppActorBridgeReceiptEvent.TYPE_POSTED_OK)
            XCTAssertEqual(event.productId, "com.app.monthly")
            expectation.fulfill()
        }

        // Simulate a pipeline event via the onReceiptPipelineEvent callback
        let detail = AppActorReceiptPipelineEventDetail(
            event: .postedOk(transactionId: "tx_999"),
            productId: "com.app.monthly",
            appUserId: "user_1"
        )
        appactor.onReceiptPipelineEvent?(detail)

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    // MARK: - Reset

    func testResetCallsCompletion() async {
        let expectation = XCTestExpectation(description: "reset callback")
        bridge.reset {
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 5.0)
    }
}
