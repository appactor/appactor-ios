import XCTest
import StoreKit
@testable import AppActor

private func makeASAConcurrencyOptions() -> AppActorASAOptions {
    AppActorASAOptions(autoTrackPurchases: true, debugMode: true)
}

private func makeASA500Error() -> AppActorError {
    .serverError(httpStatus: 500, code: "INTERNAL", message: "server error", details: nil, requestId: nil)
}

final class ASATransactionSupportTests: XCTestCase {

    func testRestoreSourceIsNeverEligible() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .restore,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .production,
            reason: .purchase,
            trackInSandbox: false
        )

        XCTAssertFalse(eligible)
    }

    func testSweepPurchaseIsEligible() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .sweep,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .production,
            reason: .purchase,
            trackInSandbox: false
        )

        XCTAssertTrue(eligible)
    }

    func testSweepRenewalIsNotEligible() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .sweep,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .production,
            reason: .renewal,
            trackInSandbox: false
        )

        XCTAssertFalse(eligible)
    }

    func testUnknownReasonFailsClosedForTransactionUpdates() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .transactionUpdates,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .production,
            reason: .unknown,
            trackInSandbox: false
        )

        XCTAssertFalse(eligible)
    }

    func testUnknownEnvironmentSkipsWhenSandboxTrackingDisabled() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .purchase,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .unknown,
            reason: .purchase,
            trackInSandbox: false
        )

        XCTAssertFalse(eligible)
    }

    func testUnknownEnvironmentAllowedWhenSandboxTrackingEnabled() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .purchase,
            isRevoked: false,
            ownershipType: .purchased,
            environment: .unknown,
            reason: .purchase,
            trackInSandbox: true
        )

        XCTAssertTrue(eligible)
    }

    func testFamilySharedTransactionIsNeverEligible() {
        let eligible = AppActorASATransactionSupport.isEligibleForASAPurchaseEvent(
            source: .purchase,
            isRevoked: false,
            ownershipType: .familyShared,
            environment: .production,
            reason: .purchase,
            trackInSandbox: false
        )

        XCTAssertFalse(eligible)
    }

    func testResolveEnvironmentUsesJWSBeforeReceiptFallback() {
        let environment = AppActorASATransactionSupport.resolveEnvironment(
            storeKitEnvironmentRaw: nil,
            jwsPayload: ["environment": "Sandbox"],
            receiptFileName: "receipt"
        )

        XCTAssertEqual(environment, .sandbox)
    }

    func testResolveEnvironmentUsesReceiptFallbackForTestFlightLikeReceipts() {
        let environment = AppActorASATransactionSupport.resolveEnvironment(
            storeKitEnvironmentRaw: nil,
            jwsPayload: nil,
            receiptFileName: "sandboxReceipt"
        )

        XCTAssertEqual(environment, .sandbox)
    }

    func testResolveEnvironmentMapsXcodeToSandbox() {
        let environment = AppActorASATransactionSupport.resolveEnvironment(
            storeKitEnvironmentRaw: "xcode",
            jwsPayload: nil,
            receiptFileName: nil
        )

        XCTAssertEqual(environment, .sandbox)
    }

    func testResolveEnvironmentReturnsUnknownWhenNoSignalsExist() {
        let environment = AppActorASATransactionSupport.resolveEnvironment(
            storeKitEnvironmentRaw: nil,
            jwsPayload: nil,
            receiptFileName: nil
        )

        XCTAssertEqual(environment, .unknown)
    }

    func testResolveReasonUsesJWSFallback() {
        let reason = AppActorASATransactionSupport.resolveReason(
            storeKitReasonRaw: nil,
            jwsPayload: ["transactionReason": "PURCHASE"]
        )

        XCTAssertEqual(reason, .purchase)
    }

    func testResolveReasonReturnsUnknownForMissingSignal() {
        let reason = AppActorASATransactionSupport.resolveReason(
            storeKitReasonRaw: nil,
            jwsPayload: nil
        )

        XCTAssertEqual(reason, .unknown)
    }
}

final class ASAQuiescentFlushTests: XCTestCase {

    private var client: MockPaymentClient!
    private var storage: InMemoryPaymentStorage!
    private var eventStore: InMemoryASAEventStore!

    override func setUp() {
        super.setUp()
        client = MockPaymentClient()
        storage = InMemoryPaymentStorage()
        eventStore = InMemoryASAEventStore()
    }

    private func makeManager() -> AppActorASAManager {
        AppActorASAManager(
            client: client,
            storage: storage,
            eventStore: eventStore,
            tokenProvider: MockASATokenProvider(),
            options: makeASAConcurrencyOptions(),
            sdkVersion: "1.0.0-test"
        )
    }

    private func enqueueEvent(
        on manager: AppActorASAManager,
        productId: String,
        originalTransactionId: String
    ) async {
        await manager.enqueuePurchaseEvent(
            userId: "user_1",
            productId: productId,
            transactionId: "tx_\(productId)",
            originalTransactionId: originalTransactionId,
            purchaseDate: Date(),
            countryCode: "US",
            storekit2Json: nil
        )
    }

    func testEnqueueDuringFlushTriggersFollowUpPass() async {
        let firstCallStarted = expectation(description: "first purchase event call started")
        client.purchaseEventHandler = { request in
            if request.productId == "prod_1" {
                firstCallStarted.fulfill()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            return AppActorASAPurchaseEventResponseDTO(status: "ok", eventId: "evt_\(request.productId)")
        }

        let manager = makeManager()

        let firstEnqueueTask = Task {
            await self.enqueueEvent(on: manager, productId: "prod_1", originalTransactionId: "orig_1")
        }

        await fulfillment(of: [firstCallStarted], timeout: 1.0)
        await enqueueEvent(on: manager, productId: "prod_2", originalTransactionId: "orig_2")
        await firstEnqueueTask.value

        XCTAssertEqual(client.purchaseEventCalls.map(\.productId), ["prod_1", "prod_2"])
        XCTAssertEqual(eventStore.count(), 0)
        XCTAssertTrue(storage.isAsaOriginalTransactionIdSent("orig_1"))
        XCTAssertTrue(storage.isAsaOriginalTransactionIdSent("orig_2"))
    }

    func testBlockedHeadEventDoesNotForceFollowUpPass() async {
        let firstCallStarted = expectation(description: "blocked purchase event call started")
        client.purchaseEventHandler = { request in
            if request.productId == "prod_1" {
                firstCallStarted.fulfill()
                try await Task.sleep(nanoseconds: 200_000_000)
                throw makeASA500Error()
            }
            return AppActorASAPurchaseEventResponseDTO(status: "ok", eventId: "evt_\(request.productId)")
        }

        let manager = makeManager()

        let firstEnqueueTask = Task {
            await self.enqueueEvent(on: manager, productId: "prod_1", originalTransactionId: "orig_1")
        }

        await fulfillment(of: [firstCallStarted], timeout: 1.0)
        await enqueueEvent(on: manager, productId: "prod_2", originalTransactionId: "orig_2")
        await firstEnqueueTask.value

        XCTAssertEqual(client.purchaseEventCalls.map(\.productId), ["prod_1"])
        XCTAssertEqual(eventStore.count(), 2)

        let pending = eventStore.pending()
        XCTAssertEqual(pending.first { $0.request.productId == "prod_1" }?.retryCount, 1)
        XCTAssertEqual(pending.first { $0.request.productId == "prod_2" }?.retryCount, 0)
    }
}
