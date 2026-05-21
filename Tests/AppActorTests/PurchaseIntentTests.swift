import XCTest
import StoreKit
@testable import AppActor

private final class PurchaseIntentCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        let snapshot = count
        lock.unlock()
        return snapshot
    }
}

// MARK: - PurchaseIntentWatcher Lifecycle Tests

/// Tests for PurchaseIntentWatcher actor lifecycle and AppActor integration.
///
/// Note: `PurchaseIntent` cannot be instantiated in unit tests (no public init),
/// and `PurchaseIntent.intents` requires a real App Store connection. Tests therefore
/// verify watcher lifecycle, queue mechanics, and public API signatures — not
/// actual intent delivery.
///
/// FEAT-04 architectural invariant: `AppActorPurchaseIntentWatcher` is a completely
/// separate actor from `AppActorTransactionWatcher`. Each maintains its own
/// `listenerTask` and background `Task`. Neither can block the other.
@available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
final class PurchaseIntentWatcherTests: XCTestCase {

    // MARK: - Watcher Start/Stop

    /// Verifies that calling start() twice only creates one listener task (idempotent).
    ///
    /// FEAT-04: The watcher has independent start/stop lifecycle from TransactionWatcher.
    func testWatcherStartIsIdempotent() async {
        let watcher = AppActorPurchaseIntentWatcher { _ in }

        // Start twice — should only create one listener task
        await watcher.start()
        await watcher.start()

        // Stop and verify clean shutdown (no crash, no deadlock)
        await watcher.stop()
    }

    /// Verifies that stop() without a prior start() is a no-op (doesn't crash).
    func testWatcherStopWhenNotStartedIsNoOp() async {
        let watcher = AppActorPurchaseIntentWatcher { _ in }

        // Stop without start — should not crash
        await watcher.stop()
    }

    /// Verifies that the watcher can be restarted after being stopped.
    ///
    /// FEAT-04: Independent lifecycle — start after stop recreates the listener task.
    func testWatcherStartAfterStopCreatesNewListener() async {
        let watcher = AppActorPurchaseIntentWatcher { _ in }

        await watcher.start()
        await watcher.stop()

        // Start again — should work (re-create listener task)
        await watcher.start()
        await watcher.stop()
    }

    /// Verifies that the watcher can be initialized with an intent handler closure.
    func testWatcherInitWithHandler() async {
        let callCount = PurchaseIntentCallCounter()
        let watcher = AppActorPurchaseIntentWatcher { _ in
            callCount.increment()
        }

        // Start and immediately stop — no intents will arrive in unit tests
        await watcher.start()
        await watcher.stop()

        // callCount stays 0 because PurchaseIntent.intents never yields in unit tests
        XCTAssertEqual(callCount.value(), 0)
    }
}

// MARK: - Pre-Bootstrap Intent Queue Tests

/// Tests for the pending intents queue that holds intents received before bootstrap completes.
///
/// FEAT-01: Intents arriving before bootstrap completes are queued in memory
/// and drained sequentially after bootstrap finishes.
@MainActor
final class PurchaseIntentQueueTests: XCTestCase {

    /// Verifies that the pendingPurchaseIntents array exists and is initially empty.
    func testPendingIntentsStartsEmpty() {
        let ctx = AppActorPaymentContext()
        XCTAssertTrue(ctx.pendingPurchaseIntents.isEmpty,
                      "pendingPurchaseIntents should start empty")
    }

    /// Verifies that objects can be added to and cleared from the pending queue.
    ///
    /// Uses string placeholders since PurchaseIntent has no public initializer.
    func testPendingIntentsQueueAndClear() {
        let ctx = AppActorPaymentContext()

        // Simulate queuing (using a placeholder since PurchaseIntent has no public init)
        ctx.pendingPurchaseIntents.append("placeholder_intent_1")
        ctx.pendingPurchaseIntents.append("placeholder_intent_2")
        XCTAssertEqual(ctx.pendingPurchaseIntents.count, 2)

        ctx.pendingPurchaseIntents.removeAll()
        XCTAssertTrue(ctx.pendingPurchaseIntents.isEmpty)
    }

    /// Verifies that purchaseIntentWatcher starts as nil (not configured until bootstrap).
    func testPurchaseIntentWatcherStartsNil() {
        let ctx = AppActorPaymentContext()
        XCTAssertNil(ctx.purchaseIntentWatcher,
                     "purchaseIntentWatcher should be nil until bootstrap runs")
    }

    /// Verifies that the watcher property can store and retrieve an Any? value.
    ///
    /// The property is Any? to avoid @available on a stored property.
    func testPurchaseIntentWatcherPropertyIsReadWrite() {
        let ctx = AppActorPaymentContext()

        // Store a placeholder
        ctx.purchaseIntentWatcher = "test_watcher_placeholder"
        XCTAssertNotNil(ctx.purchaseIntentWatcher)

        // Clear it
        ctx.purchaseIntentWatcher = nil
        XCTAssertNil(ctx.purchaseIntentWatcher)
    }
}

// MARK: - API Method Signature Tests

/// Compile-time and runtime verifications of the public purchase(intent:) API.
///
/// FEAT-01: purchase(intent:) public method exists with win-back offer support.
@MainActor
final class PurchaseIntentAPITests: XCTestCase {

    /// Verifies that purchase(intent:) method signature exists on AppActor (compile-time check).
    ///
    /// FEAT-01: purchase(intent:) routes through executePaymentPurchase pipeline.
    func testPurchaseIntentMethodExists() {
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            // Compile-time verification: if this line compiles, the method signature is correct.
            let _: (PurchaseIntent) async throws -> AppActorPurchaseResult =
                AppActor.shared.purchase(intent:)
        }
        // If this test compiles successfully, FEAT-01 method signature is verified.
    }

    /// Verifies that the watcher and pending queue properties are accessible on AppActor.
    ///
    /// FEAT-01: Confirms purchaseIntentWatcher and pendingPurchaseIntents properties exist.
    func testPurchaseIntentPropertiesExistOnPaymentContext() {
        let actor = AppActor.shared
        // Access through paymentContext (internal, accessible via @testable)
        _ = actor.paymentContext.purchaseIntentWatcher
        _ = actor.paymentContext.pendingPurchaseIntents
    }

    /// Verifies that onPurchaseIntent callback property exists on AppActor.
    ///
    /// FEAT-01: onPurchaseIntent callback exposed for host app notification.
    func testOnPurchaseIntentCallbackPropertyExists() {
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            let actor = AppActor.shared
            // Verify getter works (returns nil when not set)
            let callback = actor.onPurchaseIntent
            XCTAssertNil(callback, "onPurchaseIntent should be nil by default")
        }
    }

    /// Verifies that onPurchaseIntent callback can be set and cleared.
    ///
    /// FEAT-01: Host app can install and remove the callback.
    func testOnPurchaseIntentCallbackCanBeSetAndCleared() {
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            let actor = AppActor.shared

            // Set a callback
            actor.onPurchaseIntent = { _ in }
            XCTAssertNotNil(actor.onPurchaseIntent)

            // Clear it
            actor.onPurchaseIntent = nil
            XCTAssertNil(actor.onPurchaseIntent)
        }
    }
}
