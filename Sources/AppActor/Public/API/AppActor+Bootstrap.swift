import Foundation
import StoreKit

// MARK: - Bootstrap & Startup Sequence

extension AppActor {

    /// Runs the full startup sequence: watcher setup → bootstrap.
    ///
    /// Called from `configure()` and awaited directly. When this returns,
    /// the SDK is fully initialized (watcher running, bootstrap complete).
    func runStartupSequence() async {
        let sequenceStart = CFAbsoluteTimeGetCurrent()
        let verboseBootstrap = (paymentConfig?.options.logLevel ?? AppActorLogger.level) >= .verbose
        let watcher = transactionWatcher

        // ── Phase 1: Watcher setup (must complete before transactions arrive) ──
        if let watcher {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled else {
                await revertLifecycleIfCancelled()
                return
            }
            await watcher.start()
            Log.sdk.info("  ⏱ watcher: \(ms(since: t0)) ms")
        }

        // Start PurchaseIntent listener (iOS 16.4+) — independent from Transaction.updates
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            let intentWatcher = AppActorPurchaseIntentWatcher { [weak self] intent in
                guard let self else { return }
                await MainActor.run {
                    self.handlePurchaseIntent(intent)
                }
            }
            self.purchaseIntentWatcher = intentWatcher
            await intentWatcher.start()
        }

        guard !Task.isCancelled else {
            await revertLifecycleIfCancelled()
            return
        }

        // ── Phase 2: Bootstrap (sequential: identify → offerings(api) → sweep → drain+refresh) ──
        await self.runBootstrap(verboseBootstrap: verboseBootstrap)

        // If bootstrap was cancelled mid-way, revert lifecycle so configure() can be retried.
        guard !Task.isCancelled else {
            await revertLifecycleIfCancelled()
            return
        }

        self.isBootstrapComplete = true

        // Drain any PurchaseIntents that arrived before bootstrap completed
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            let pending = pendingPurchaseIntents.compactMap { $0 as? PurchaseIntent }
            pendingPurchaseIntents.removeAll()
            for intent in pending {
                handlePurchaseIntent(intent)
            }
        }

        let totalMs = ms(since: sequenceStart)
        Log.sdk.info("✅ Configure total: \(totalMs) ms")
    }

    /// Handles an incoming PurchaseIntent.
    ///
    /// If bootstrap is not yet complete, queues the intent for later processing.
    /// Otherwise, notifies the host app via callback or auto-purchases.
    @available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
    private func handlePurchaseIntent(_ intent: PurchaseIntent) {
        guard isBootstrapComplete else {
            // Not yet ready — queue for post-bootstrap processing
            pendingPurchaseIntents.append(intent)
            Log.storeKit.info("🍎 PurchaseIntent queued (bootstrap not complete): \(intent.product.id)")
            return
        }

        if let callback = onPurchaseIntent {
            callback(intent)
        } else {
            // No callback set — auto-purchase
            Task { @MainActor in
                do {
                    _ = try await self.purchase(intent: intent)
                    Log.storeKit.info("🍎 Auto-purchased from PurchaseIntent: \(intent.product.id)")
                } catch {
                    Log.storeKit.warn("Auto-purchase from PurchaseIntent failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Milliseconds elapsed since the given `CFAbsoluteTime` reference point.
    private func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Static variant for use inside `@Sendable` closures (e.g. Task bodies).
    private static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Reverts lifecycle to `.idle` when startup is cancelled before completion.
    /// This ensures `configure()` can be called again without needing `reset()`.
    /// Only reverts if still in `.configured` state (avoids conflicting with `reset()`
    /// which sets `.resetting` before cancellation propagates).
    ///
    /// Stops the transaction watcher and payment processor to prevent orphan actors
    /// from running in the background after a cancelled bootstrap.
    private func revertLifecycleIfCancelled() async {
        guard paymentLifecycle == .configured else { return }
        offeringsPrefetchTask?.cancel()
        identityReadyTask?.cancel()
        await offeringsPrefetchTask?.value
        _ = try? await identityReadyTask?.value
        offeringsPrefetchTask = nil
        identityReadyTask = nil
        await transactionWatcher?.stop()
        await paymentProcessor?.stop()
        transactionWatcher = nil
        paymentProcessor = nil
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if let watcher = purchaseIntentWatcher as? AppActorPurchaseIntentWatcher {
                await watcher.stop()
            }
        }
        purchaseIntentWatcher = nil
        pendingPurchaseIntents.removeAll()
        isBootstrapComplete = false
        paymentLifecycle = .idle
        Log.sdk.warn("Startup cancelled before bootstrap completed — reverted to idle.")
    }

    /// The bootstrap sequence extracted into a standalone method for use inside
    /// the supervisor TaskGroup. Errors are logged, never thrown.
    private func runBootstrap(verboseBootstrap: Bool) async {
        let start = CFAbsoluteTimeGetCurrent()
        var stepStart = start

        func logStep(_ name: String) {
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = Int((now - stepStart) * 1000)
            Log.sdk.info("  ⏱ \(name): \(elapsed) ms")
            stepStart = now
        }

        // 0a. Clear stale unverified cache if verification mode was escalated (off→on)
        if let etagMgr = self.paymentETagManager {
            await etagMgr.clearUnverifiedIfNeeded()
        }

        // 0b. Wire customer info updates BEFORE any receipt processing.
        if let processor = self.paymentProcessor {
            await processor.setCustomerInfoUpdateHandler { [weak self] info, receiptAppUserId, productId in
                Task { @MainActor [weak self] in
                    guard let self, let manager = self.customerManager,
                          let currentAppUserId = self.paymentStorage?.currentAppUserId else { return }
                    // F3 fix: only seed cache if the receipt belongs to the current user.
                    // A login/logout between enqueue and response could cause stale data.
                    guard receiptAppUserId == currentAppUserId else {
                        Log.customer.debug("Skipping customer cache seed — receipt userId (\(receiptAppUserId)) != current userId (\(currentAppUserId))")
                        _ = try? await self.getCustomerInfo()
                        return
                    }
                    await manager.seedCache(
                        info: info,
                        eTag: nil,
                        appUserId: currentAppUserId,
                        verified: info.verification == .verified
                    )
                    self.customerInfo = info

                    // Fire deferred purchase callback if this product was previously pending
                    if let count = self.paymentContext.pendingProductCounts[productId], count > 0 {
                        if count <= 1 {
                            self.paymentContext.pendingProductCounts.removeValue(forKey: productId)
                        } else {
                            self.paymentContext.pendingProductCounts[productId] = count - 1
                        }
                        Log.receipts.info("Deferred purchase resolved: \(productId)")
                        self.paymentContext.deferredPurchaseHandler?(productId, info)
                    }
                }
            }
        }
        logStep("setup")

        // 1. Identify first so the payment identity is established deterministically.
        do {
            _ = try await self.identify()
            // Clear re-identify flag if it was set by a previous failed logOut()
            self.paymentStorage?.setNeedsReidentify(false)
        } catch is CancellationError {
            return
        } catch {
            if verboseBootstrap {
                Log.sdk.warn("Bootstrap identify failed: \(error.localizedDescription)")
            }
        }

        // 2. Fire-and-forget: warm offerings cache in the background.
        // getOfferings() will coalesce with this in-flight request if called early.
        if let manager = self.offeringsManager {
            self.offeringsPrefetchTask = Task { await manager.prefetchForBootstrap() }
        }
        logStep("identify")
        guard !Task.isCancelled else { return }

        // 3. Sweep unfinished transactions from previous sessions.
        if let watcher = self.transactionWatcher {
            await watcher.sweepUnfinished()
        }
        logStep("sweepUnfinished")
        guard !Task.isCancelled else { return }

        // 4+5. Drain pending receipts and refresh customer info in one step.
        // drainReceiptQueueAndRefreshCustomer() preserves the previous preload
        // behavior. The new syncPurchases() is reserved for explicit quiet SK2 sync.
        // If the drain+refresh step fails, fall back to a standalone customerInfo refresh.
        do {
            let info = try await self.drainReceiptQueueAndRefreshCustomer()
            if verboseBootstrap {
                let activeKeys = info.activeEntitlementKeys
                Log.sdk.verbose("Bootstrap sync+refresh OK — active entitlements: \(activeKeys.isEmpty ? "none" : activeKeys.joined(separator: ", "))")
            }
        } catch is CancellationError {
            return
        } catch {
            Log.sdk.warn("Bootstrap drainReceiptQueueAndRefreshCustomer failed: \(error.localizedDescription)")
            do {
                let fresh = try await self.getCustomerInfo()
                if verboseBootstrap {
                    let activeKeys = fresh.activeEntitlementKeys
                    Log.sdk.verbose("Bootstrap customer refresh OK (fallback) — active entitlements: \(activeKeys.isEmpty ? "none" : activeKeys.joined(separator: ", "))")
                }
            } catch is CancellationError {
                return
            } catch {
                Log.sdk.warn("Bootstrap customer refresh failed: \(error.localizedDescription)")
            }
        }
        logStep("drainReceiptQueueAndRefreshCustomer")

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        Log.sdk.info("  ⏱ bootstrap: \(totalMs) ms")
    }
}
