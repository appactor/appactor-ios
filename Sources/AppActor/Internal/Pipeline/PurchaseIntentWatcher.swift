import Foundation
import StoreKit

/// Listens for `PurchaseIntent.intents` in a dedicated background Task.
///
/// Completely isolated from `TransactionWatcher` (which listens `Transaction.updates`).
/// Both run independently at `.utility` priority — neither blocks the other.
/// Mirrors RevenueCat's `StoreKit2PurchaseIntentListener` architecture.
///
/// When an intent arrives, it is forwarded to the `onIntent` handler via
/// `Task.detached` to avoid blocking the intent stream.
@available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
actor AppActorPurchaseIntentWatcher {

    private var listenerTask: Task<Void, Never>?
    private let onIntent: @Sendable (PurchaseIntent) async -> Void

    /// Creates a watcher with an intent handler.
    ///
    /// - Parameter onIntent: Called for each incoming `PurchaseIntent`.
    ///   Invoked via `Task.detached` to avoid blocking the intent stream.
    init(onIntent: @escaping @Sendable (PurchaseIntent) async -> Void) {
        self.onIntent = onIntent
    }

    /// Starts listening for `PurchaseIntent.intents`.
    ///
    /// Idempotent — calling `start()` when already running is a no-op.
    func start() {
        guard listenerTask == nil else { return }

        listenerTask = Task(priority: .utility) { [weak self] in
            for await intent in PurchaseIntent.intents {
                guard let self, !Task.isCancelled else { break }
                let handler = await self.onIntent
                // Detach to avoid blocking the intent stream
                Task.detached { await handler(intent) }
            }
        }

        Log.storeKit.info("🍎 PurchaseIntentWatcher started")
    }

    /// Stops the listener and waits for it to finish.
    func stop() async {
        let task = listenerTask
        task?.cancel()
        await task?.value
        listenerTask = nil
        Log.storeKit.info("🍎 PurchaseIntentWatcher stopped")
    }
}
