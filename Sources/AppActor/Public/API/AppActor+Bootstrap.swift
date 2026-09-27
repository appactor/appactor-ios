import Foundation
import StoreKit
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// MARK: - Bootstrap & Startup Sequence

extension AppActor {

    /// Runs the full startup sequence: watcher setup → bootstrap.
    ///
    /// Called from `configureAndStart()` and awaited directly. When this returns,
    /// the SDK is fully initialized (watcher running, bootstrap complete), unless the
    /// startup was cancelled (it reverted to `.idle`) or its session ended (reset()).
    func runStartupSequence() async {
        // Every exit settles it: a completed bootstrap, a revert, or a reset() that took over.
        defer { settleStartup() }
        // reset(), and a configure() after it, can run while this awaits. The startup of a session
        // that ended stops at its next check instead of reverting, starting or completing the
        // next session.
        let session = sessionGeneration
        let sequenceStart = CFAbsoluteTimeGetCurrent()
        let verboseBootstrap = (paymentConfig?.options.logLevel ?? AppActorLogger.level) >= .verbose
        let watcher = transactionWatcher

        // First: the cache seed below already notifies the host, which may enqueue work.
        if let processor = paymentProcessor, let storage = paymentStorage {
            await processor.reassignUnpostedItemsWithRejectedAppUserId(to: storage.ensureAppUserId())
        }
        // Wire receipt callbacks before Transaction.updates can enqueue work.
        await wireReceiptCustomerInfoUpdateHandler()

        // ── Cache-first: surface persisted/offline premium instantly, before the
        // network refresh in bootstrap. The later fresh value overwrites this seed. ──
        await seedCustomerInfoFromCacheOnLaunch()

        // ── Phase 1: Watcher setup (must complete before transactions arrive) ──
        if let watcher {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled, isSessionCurrent(session) else {
                await revertLifecycleIfCancelled(session: session)
                return
            }
            await watcher.start()
            Log.sdk.info("  ⏱ watcher: \(ms(since: t0)) ms")
        }
        guard isSessionCurrent(session) else { return }

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

        guard !Task.isCancelled, isSessionCurrent(session) else {
            await revertLifecycleIfCancelled(session: session)
            return
        }

        // ── Phase 2: Bootstrap (sequential: offerings(api) → sweep → drain+refresh) ──
        // Cancelled, the startup reverts the session (below), and a configure() may be waiting
        // for that. The customer fetch bootstrap waits on is shared, and this cancellation doesn't
        // reach it (see cancelInFlight()): the startup owns the teardown and cancels it itself.
        let customerManager = self.customerManager
        await withTaskCancellationHandler {
            await self.runBootstrap(verboseBootstrap: verboseBootstrap, session: session)
        } onCancel: {
            Task { await customerManager?.cancelInFlight() }
        }

        // If bootstrap was cancelled mid-way, revert lifecycle so configure() can be retried.
        guard !Task.isCancelled, isSessionCurrent(session) else {
            await revertLifecycleIfCancelled(session: session)
            return
        }

        self.isBootstrapComplete = true
        settleStartup()
        #if canImport(UIKit) && !os(watchOS)
        // The foreground observer starts it too, but at a cold launch into the foreground its
        // notification comes before bootstrap completes (or before configure() registered it).
        // Not in the background: the background observer that stops it may have fired already,
        // before there was a timer, and a background launch gets it on its first foreground.
        if stalenessTimerTask == nil, UIApplication.shared.applicationState != .background {
            startStalenessTimer()
        }
        #endif

        do {
            try await collectAutomaticProfileContext()
        } catch {
            Log.customer.warn(
                "Automatic profile context sync failed during bootstrap; continuing with queued retry: \(error.localizedDescription)"
            )
        }
        try? await flushPendingCustomerAttributeWritesForAllUsers()

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

    func handleReceiptCustomerInfoUpdate(
        _ info: AppActorCustomerInfo,
        receiptContext: AppActorReceiptCustomerUpdateContext
    ) async {
        guard let manager = customerManager,
              let currentAppUserId = paymentStorage?.currentAppUserId else { return }
        // F3 fix: only seed cache if the receipt belongs to the current user.
        // A login/logout between enqueue and response could cause stale data.
        guard receiptContext.appUserId == currentAppUserId else {
            Log.customer.debug("Skipping customer cache seed — receipt userId (\(receiptContext.appUserId)) != current userId (\(currentAppUserId))")
            // Posted under the anonymous ID the last logIn folded into the current one: bought by
            // the same customer, so a deferred purchase still resolves for them. Forced, so it
            // doesn't join a customer fetch already in flight that may predate the purchase.
            if paymentLifecycle == .configured, receiptContext.isDeferredPurchaseResolution,
               let fold = paymentStorage?.foldedAnonymousAppUser,
               fold.anonymousId == receiptContext.appUserId, fold.into == currentAppUserId {
                do {
                    let refreshed = try await manager.getCustomerInfo(appUserId: currentAppUserId, forceRefresh: true)
                    await setCustomerInfoIfIdentityMatches(refreshed, expectedAppUserId: currentAppUserId)
                    if paymentStorage?.currentAppUserId == currentAppUserId {
                        resolveDeferredPurchase(receiptContext, info: refreshed)
                    }
                    return
                } catch is CancellationError {
                    return // a logOut or reset() is deleting this user's cache
                } catch {}
            }
            _ = try? await getCustomerInfo()
            return
        }
        await manager.seedCache(
            info: info,
            eTag: nil,
            appUserId: currentAppUserId,
            verified: info.verification == .verified
        )
        await setCustomerInfoIfIdentityMatches(info, expectedAppUserId: currentAppUserId)
        resolveDeferredPurchase(receiptContext, info: info)
    }

    /// Tells the host when the receipt resolves a purchase that `purchase()` returned as `.pending`.
    private func resolveDeferredPurchase(_ receiptContext: AppActorReceiptCustomerUpdateContext, info: AppActorCustomerInfo) {
        if paymentContext.consumeDeferredPurchaseResolution(
            productId: receiptContext.productId,
            receiptContext: receiptContext
        ) {
            Log.receipts.info("Deferred purchase resolved: \(receiptContext.productId)")
            paymentContext.deferredPurchaseHandler?(receiptContext.productId, info)
        }
    }

    func wireReceiptCustomerInfoUpdateHandler() async {
        if let processor = self.paymentProcessor {
            await processor.setCustomerInfoUpdateHandler { [weak self] info, receiptContext in
                Task { @MainActor [weak self] in
                    await self?.handleReceiptCustomerInfoUpdate(info, receiptContext: receiptContext)
                }
            }
            await processor.setRevokedTransactionHandler { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refreshCustomerInfoAfterRevocation()
                }
            }
        }
    }

    /// The server processed a refund or revoke and answered without customer info. Forced, so
    /// it doesn't join a customer fetch already in flight that may predate the revocation.
    func refreshCustomerInfoAfterRevocation() async {
        guard paymentLifecycle == .configured,
              let manager = customerManager,
              let appUserId = paymentStorage?.currentAppUserId,
              let info = try? await manager.getCustomerInfo(appUserId: appUserId, forceRefresh: true) else { return }
        await setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
    }

    /// Handles an incoming PurchaseIntent.
    ///
    /// If bootstrap is not yet complete, queues the intent for later processing.
    /// Otherwise, notifies the host app via callback or auto-purchases.
    @available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
    private func handlePurchaseIntent(_ intent: PurchaseIntent) {
        // The watcher hands intents over asynchronously, so one can land while reset() runs
        // or after it. It belongs to the reset session: dropped, neither bought nor queued.
        guard paymentLifecycle == .configured else {
            Log.storeKit.info("🍎 PurchaseIntent dropped (SDK not configured): \(intent.product.id)")
            return
        }
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

    /// Suspends until the startup in flight settles (bootstrap completes or the startup reverts
    /// to `.idle`), or the caller is cancelled.
    func waitForStartupToSettle() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled, paymentLifecycle == .configured, !isBootstrapComplete else {
                    continuation.resume()
                    return
                }
                paymentContext.startupWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.paymentContext.startupWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    /// Resumes every configure() waiting in `waitForStartupToSettle()`.
    private func settleStartup() {
        let waiters = paymentContext.startupWaiters.values
        paymentContext.startupWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
    /// Only reverts while `session` is still current (avoids conflicting with `reset()`,
    /// which sets `.resetting` before cancellation propagates, and with the session after it).
    ///
    /// Stops the transaction watcher and payment processor to prevent orphan actors
    /// from running in the background after a cancelled bootstrap.
    private func revertLifecycleIfCancelled(session: UInt64) async {
        guard isSessionCurrent(session) else { return }
        // Captured: reset() and a configure() after it can run during the awaits below, and the
        // next session's watcher, processor and prefetch must not be the ones stopped.
        let prefetch = offeringsPrefetchTask
        let offeringsManager = self.offeringsManager
        let transactionWatcher = self.transactionWatcher
        let paymentProcessor = self.paymentProcessor
        let intentWatcher = purchaseIntentWatcher
        prefetch?.cancel()
        await offeringsManager?.cancelInFlight() // the prefetch waits on the shared network task
        await prefetch?.value
        await transactionWatcher?.stop()
        await paymentProcessor?.stop()
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if let watcher = intentWatcher as? AppActorPurchaseIntentWatcher {
                await watcher.stop()
            }
        }
        guard isSessionCurrent(session) else { return }
        offeringsPrefetchTask = nil
        self.transactionWatcher = nil
        self.paymentProcessor = nil
        purchaseIntentWatcher = nil
        pendingPurchaseIntents.removeAll()
        isBootstrapComplete = false
        paymentLifecycle = .idle
        Log.sdk.warn("Startup cancelled before bootstrap completed — reverted to idle.")
    }

    /// Publishes the offerings the bootstrap prefetch loaded as `cachedOfferings`, as Android
    /// does, unless an offerings() call published some first. Not tracked by reset(), which
    /// would wait on StoreKit: it only publishes, and nothing for a session that ended.
    private func publishBootstrapOfferings(after prefetch: Task<Void, Never>, from manager: AppActorOfferingsManager) {
        let session = sessionGeneration
        Task { [weak self] in
            await prefetch.value
            guard let offerings = await manager.settledOfferings(),
                  let self, self.isSessionCurrent(session), self.offeringsManager === manager,
                  self.paymentOfferings == nil else { return }
            self.paymentOfferings = offerings
        }
    }

    /// The bootstrap sequence extracted into a standalone method for use inside
    /// the supervisor TaskGroup. Errors are logged, never thrown.
    private func runBootstrap(verboseBootstrap: Bool, session: UInt64) async {
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

        // 0b. Keep handler wiring idempotent for tests and custom setup paths.
        await wireReceiptCustomerInfoUpdateHandler()
        logStep("setup")

        // 1. Fire-and-forget: warm offerings cache in the background.
        // getOfferings() will coalesce with this in-flight request if called early.
        guard isSessionCurrent(session) else { return }
        if let manager = self.offeringsManager {
            let prefetch = Task { await manager.prefetchForBootstrap() }
            self.offeringsPrefetchTask = prefetch
            publishBootstrapOfferings(after: prefetch, from: manager)
        }
        logStep("offerings/api")
        guard !Task.isCancelled else { return }

        // 2. Sweep unfinished transactions from previous sessions.
        if let watcher = self.transactionWatcher {
            await watcher.sweepUnfinished()
        }
        logStep("sweepUnfinished")
        guard !Task.isCancelled, isSessionCurrent(session) else { return }

        // 3+4. Drain pending receipts and refresh customer info in one step.
        // drainReceiptQueueAndRefreshCustomer() preserves the previous preload
        // behavior. The new syncPurchases() is reserved for explicit quiet SK2 sync.
        // The drain doesn't throw, so a failure is the customer refresh's own, which has already
        // run its retries: not tried again here.
        do {
            let info = try await self.drainReceiptQueueAndRefreshCustomer()
            if verboseBootstrap {
                let activeKeys = info.activeEntitlementKeys
                Log.sdk.verbose("Bootstrap sync+refresh OK — active entitlements: \(activeKeys.isEmpty ? "none" : activeKeys.joined(separator: ", "))")
            }
        } catch is CancellationError {
            return
        } catch {
            Log.sdk.warn("Bootstrap customer refresh failed: \(error.localizedDescription)")
        }
        logStep("drainReceiptQueueAndRefreshCustomer")

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        Log.sdk.info("  ⏱ bootstrap: \(totalMs) ms")
    }
}
