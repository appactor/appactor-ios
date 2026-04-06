import Foundation
import StoreKit

/// Single-actor payment pipeline: the ONLY code path allowed to POST receipts,
/// finish transactions, or retry.
///
/// ## Architecture
///
/// All receipt processing flows through this actor:
/// - `enqueueAndAwait()` — purchase flow (awaits server result via continuation)
/// - `enqueue()` — background flows (Transaction.updates, restore, sweep)
/// - `kick()` — triggers the drain loop
///
/// ## 3-Layer Dedup
///
/// | Layer | Where | Mechanism |
/// |-------|-------|-----------|
/// | A — Disk | `store.upsert()` | Key-based merge |
/// | B — Runtime | `inFlight` set | Skip already-POSTing keys |
/// | C — Server | `idempotency_key` | Backend unique constraint |
///
/// ## Claim/Lock Protocol
///
/// 1. `claimReady()` → phase=.posting + claimedAt persisted to disk
/// 2. POST to backend
/// 3. On response: transition phase + persist
/// 4. Crash recovery: stale claims (>2 min) reset to `.needsPost`
actor AppActorPaymentProcessor {

    private let store: AppActorPaymentQueueStoreProtocol
    private let client: AppActorPaymentClientProtocol

    /// Wake-up stream continuation. yield() = "check the queue".
    /// bufferingNewest(1) = natural coalescing (10 yields during drain → 1 pending signal).
    private var streamContinuation: AsyncStream<Void>.Continuation?

    /// Long-lived listener task — calls drainOnce() on each stream signal.
    private var listenerTask: Task<Void, Never>?

    /// Retry timer task. Yields to the stream when the deadline arrives.
    private var retryTask: Task<Void, Never>?

    /// Set to `true` by `stop()` to prevent re-entrant `kick()` from
    /// starting a new drain while `stop()` is awaiting the old one.
    private var isStopped = false

    /// Layer B dedup: keys currently being POSTed.
    private var inFlight: Set<String> = []

    /// Live transaction references for finish gating.
    private var transactionMap: [String: Transaction] = [:]

    /// Purchase flow continuations awaiting server result.
    private var pendingResults: [String: CheckedContinuation<AppActorReceiptPostResult, Never>] = [:]

    /// Timeout tasks for purchase flow — cancelled on normal completion (F5 fix).
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    /// Recently completed terminal POST results keyed by receipt key.
    ///
    /// This bridges the race where `Transaction.updates` posts a receipt before
    /// the foreground purchase flow reaches `enqueueAndAwait`.
    private var completedResults: [String: CompletedReceiptResult] = [:]

    /// Maximum concurrent POSTs in the drain loop.
    private var maxConcurrentPosts = 3

    /// Retain terminal results briefly so foreground purchase flows can recover
    /// them after a watcher-led POST wins the race.
    private static let completedResultRetention: TimeInterval = 60

    /// Rate limit cooldown: skip POSTs until this time.
    private var rateLimitCooldownUntil: Date?

    // ── Identity Gate ──
    // Receipts are enqueued to disk immediately (no data loss), but drain()
    // waits for the identity gate before POSTing. This prevents receipts from
    // reaching the server before identify() has created the user.

    /// Whether `confirmIdentity()` has been called.
    private var identityConfirmed = false

    /// Continuations waiting for the identity gate to open.
    private var identityWaiters: [CheckedContinuation<Void, Never>] = []

    /// Callback for pipeline events with product and user context.
    var onPipelineEvent: (@Sendable (AppActorReceiptPipelineEventDetail) -> Void)?

    /// Callback for customer info updates from successful receipt POSTs.
    /// Fired when the server returns customer info in a receipt response.
    /// Includes the `appUserId` from the receipt so the caller can verify identity hasn't changed (F3 fix).
    private var onCustomerInfoUpdated: (@Sendable (AppActorCustomerInfo, _ receiptAppUserId: String, _ productId: String) -> Void)?

    private struct CompletedReceiptResult {
        let result: AppActorReceiptPostResult
        let recordedAt: Date
    }

    /// Maximum retry attempts before dead-lettering.
    static let maxRetryAttempts = 3

    /// Maximum retry attempts for decode mismatches (HTTP 200 but body can't be parsed).
    /// These won't self-resolve, so dead-letter at the same limit as general retries.
    static let maxDecodeRetryAttempts = 3

    /// Timeout for purchase flow await — returns `.queued` if server doesn't respond within this window.
    /// Sized to fit 3 quick retries (0 + 0.75 + 3 = 3.75s) plus network round-trip time.
    static let purchaseAwaitTimeout: TimeInterval = 10

    /// Maximum age of a queue item before permanent dead-letter.
    /// Younger items will be recovered by sweepUnfinished() on next boot.
    static let retryLifetimeLimit: TimeInterval = 7 * 24 * 60 * 60

    init(store: AppActorPaymentQueueStoreProtocol, client: AppActorPaymentClientProtocol) {
        self.store = store
        self.client = client
    }

    /// Lazily creates the stream + listener on first kick().
    /// Cannot be done in init because actor self-capture is not allowed there.
    private func ensureListening() {
        guard listenerTask == nil, !isStopped else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.streamContinuation = continuation
        listenerTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.drainOnce()
                await self.scheduleNextDrainIfNeeded()
            }
        }
    }

    // MARK: - Identity Gate

    /// Signals that identity has been established (or attempted).
    ///
    /// Called by bootstrap after `identify()` completes — whether it succeeded
    /// or failed. The local `appUserId` is always valid (created synchronously
    /// in `configureInternal`); this gate just ensures the server has seen the
    /// identify call before we POST any receipts.
    ///
    /// If identify failed, receipts will POST and likely fail too, but they'll
    /// retry with exponential backoff — same as any transient network error.
    func confirmIdentity() {
        identityConfirmed = true
        for waiter in identityWaiters {
            waiter.resume()
        }
        identityWaiters.removeAll()
    }

    /// Suspends until `confirmIdentity()` is called. No-op if already confirmed.
    private func waitForIdentity() async {
        if identityConfirmed { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Double-check: confirmIdentity() may have been called between
            // the if-check above and this continuation registration.
            if identityConfirmed {
                continuation.resume()
            } else {
                identityWaiters.append(continuation)
            }
        }
    }

    // MARK: - Public API

    /// Enqueues a payment queue item (fire-and-forget). Used by background callers
    /// (Transaction.updates, restore, sweep).
    ///
    /// Skips enqueue if the key is already in the posted ledger (duplicate prevention).
    /// Finishes the transaction directly when skipping to prevent it from reappearing
    /// in `Transaction.unfinished` on subsequent boots.
    func enqueue(item: AppActorPaymentQueueItem, transaction: Transaction) async {
        if store.isPosted(key: item.key) {
            Log.receipts.debug("[key=\(item.key)] Skipped enqueue — already in posted ledger")
            emitEvent(.duplicateSkipped(key: item.key), item: item)
            await transaction.finish()
            return
        }
        store.upsert(item)
        transactionMap[item.key] = transaction
        kick()
    }

    /// Enqueues a payment queue item and awaits the server result. Used by the
    /// purchase flow to return a synchronous result to the caller.
    ///
    /// If the server doesn't respond within `purchaseAwaitTimeout` (35 s), returns
    /// `.queued` so `purchase()` never blocks indefinitely. The queue item stays
    /// and will be retried on the next drain cycle.
    ///
    /// Also checks the posted ledger — the same transaction may have been enqueued
    /// and posted by `Transaction.updates` before the purchase flow runs.
    func enqueueAndAwait(item: AppActorPaymentQueueItem, transaction: Transaction) async -> AppActorReceiptPostResult {
        if store.isPosted(key: item.key) {
            Log.receipts.debug("[key=\(item.key)] Skipped enqueueAndAwait — already in posted ledger")
            emitEvent(.duplicateSkipped(key: item.key), item: item)
            await transaction.finish()
            return consumeCompletedResult(for: item.key) ?? .alreadyPosted
        }
        store.upsert(item)
        transactionMap[item.key] = transaction

        let timeoutNanos = UInt64(Self.purchaseAwaitTimeout * 1_000_000_000)
        let key = item.key

        return await withCheckedContinuation { continuation in
            // F1 fix: resume any existing continuation for this key to prevent leak
            if let existing = pendingResults.removeValue(forKey: key) {
                existing.resume(returning: .queued)
                Log.receipts.debug("[key=\(key)] Overwriting pending continuation")
            }
            pendingResults[key] = continuation
            kick()

            // Hard timeout: guarantee purchase() never blocks longer than 35s
            // F5 fix: store the timeout task so it can be cancelled on normal completion
            timeoutTasks[key]?.cancel()
            timeoutTasks[key] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                } catch {
                    return // Cancelled — do not fire timeout
                }
                await self?.timeoutContinuation(key: key)
            }
        }
    }

    /// Signals the drain loop to process the queue.
    /// If a drain is already running, the signal is buffered (bufferingNewest(1))
    /// and a new drain cycle starts automatically after the current one finishes.
    func kick() {
        guard !isStopped else { return }
        ensureListening()
        streamContinuation?.yield()
    }

    /// Drains the queue synchronously until no more work remains.
    /// Bypasses the stream for deterministic, test-friendly behavior.
    /// Schedules a retry timer for any items left with future `nextRetryAt`.
    func drainAll() async {
        guard !isStopped else { return }
        var hadWork = true
        while hadWork && !isStopped {
            hadWork = await drainOnce()
        }
        // Schedule retry for items that need future processing (e.g. failed with backoff).
        // drainOnce() is pure — scheduling lives in the caller.
        ensureListening()
        scheduleNextDrainIfNeeded()
    }

    /// Cancels the in-flight drain loop, waits for it to finish, and clears
    /// pending continuations. Deterministic shutdown — when this returns,
    /// no drain work is in progress.
    func stop() async {
        isStopped = true          // Prevent re-entrant kick() during await

        // Resume identity waiters FIRST — drain() may be suspended at
        // waitForIdentity(). Without this, awaiting the listener below deadlocks:
        // stop() waits for drain, drain waits for identity gate, identity
        // waiters are only resumed after stop() returns → circular wait.
        for waiter in identityWaiters {
            waiter.resume()
        }
        identityWaiters.removeAll()

        // Close the stream — listener loop exits naturally after current drainOnce() finishes
        streamContinuation?.finish()
        streamContinuation = nil

        // Cancel and await the listener (waits for in-progress drainOnce to complete)
        listenerTask?.cancel()
        _ = await listenerTask?.value
        listenerTask = nil

        // Cancel and await retry timer
        retryTask?.cancel()
        _ = await retryTask?.value
        retryTask = nil

        // Cancel all timeout tasks (F5 fix)
        for (_, task) in timeoutTasks {
            task.cancel()
        }
        timeoutTasks.removeAll()

        // Resume any pending purchase continuations so callers don't hang
        for (key, continuation) in pendingResults {
            continuation.resume(returning: .queued)
            Log.receipts.debug("[key=\(key)] Processor stopped — continuation resumed with .queued")
        }
        pendingResults.removeAll()
        completedResults.removeAll()
    }

    /// Checks for pending items after a drain pass and schedules the next wake-up.
    /// Called from the listener loop — not from drainOnce() — to keep drainOnce() pure.
    private func scheduleNextDrainIfNeeded() {
        guard !isStopped else { return }
        let pending = store.snapshot().filter { $0.phase == .needsPost }
        if var earliest = pending.compactMap(\.nextRetryAt).min() {
            // Respect the global rate-limit cooldown to avoid a spin loop:
            // items may have nextRetryAt in the past while the cooldown is still active.
            if let cooldown = rateLimitCooldownUntil, cooldown > earliest {
                earliest = cooldown
            }
            if earliest <= Date() {
                streamContinuation?.yield()
            } else {
                scheduleRetry(at: earliest)
            }
        }
    }

    /// Schedules a retry timer that yields to the stream when the deadline arrives.
    private func scheduleRetry(at deadline: Date) {
        retryTask?.cancel()
        let delay = max(deadline.timeIntervalSinceNow, 0.5)
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            await self?.kick()
        }
    }

    // MARK: - Observability

    /// Number of pending (not dead-lettered) items.
    func pendingCount() -> Int {
        store.pendingCount()
    }

    /// Number of dead-lettered items.
    func deadLetteredCount() -> Int {
        store.deadLetteredCount()
    }

    /// Returns a snapshot of all items for diagnostic purposes.
    func snapshot() -> [AppActorReceiptEventSummary] {
        store.snapshot().map { item in
            AppActorReceiptEventSummary(
                id: item.key,
                productId: item.productId,
                status: item.phase.rawValue,
                attemptCount: item.attemptCount,
                nextAttemptAt: item.nextRetryAt,
                lastError: item.lastError
            )
        }
    }

    /// Returns and clears dead-letter records purged from local retention.
    func consumePurgedDeadLetters() -> [AppActorPurgedDeadLetterSummary] {
        store.consumePurgedDeadLetters()
    }

    /// Marks keys as posted in the ledger and removes any matching queued items.
    /// Used by bulk restore to close the dedup gap after finishing transactions directly.
    func markPostedAndReconcile(keys: [String]) {
        let keysToReconcile = Set(keys)
        let existingItems = store.snapshot()
        for key in keys {
            store.markPosted(key: key)
        }
        for item in existingItems where keysToReconcile.contains(item.key) && item.phase != .deadLettered {
            store.remove(key: item.key)
        }
    }

    /// Sets the pipeline event handler.
    func setPipelineEventHandler(_ handler: (@Sendable (AppActorReceiptPipelineEventDetail) -> Void)?) {
        self.onPipelineEvent = handler
    }

    /// Sets the handler called when a receipt POST returns updated customer info.
    func setCustomerInfoUpdateHandler(_ handler: (@Sendable (AppActorCustomerInfo, _ receiptAppUserId: String, _ productId: String) -> Void)?) {
        self.onCustomerInfoUpdated = handler
    }

    /// Returns and clears the most recent terminal result for a receipt key.
    ///
    /// Internal so tests can validate the watcher/purchase reconciliation path.
    func consumeCompletedResult(for key: String) -> AppActorReceiptPostResult? {
        purgeExpiredCompletedResults()
        return completedResults.removeValue(forKey: key)?.result
    }

    // MARK: - Drain Loop

    /// Single drain pass. Returns `true` if any work was done.
    ///
    /// 1. Hydrate persisted rate-limit cooldown (first drain only)
    /// 2. Handle `.needsFinish` items (finish tx + remove)
    /// 3. Check rate-limit cooldown — exit entirely if still active
    /// 4. Claim ready items (`.needsPost` due + stale `.posting`)
    /// 5. POST in parallel via task group
    /// 6. Loop while there's work
    @discardableResult
    private func drainOnce() async -> Bool {
        // Identity gate: wait for identify() to complete before POSTing.
        // Items are already persisted to disk by enqueue(), so no data is lost.
        // If stop() is called while waiting, Task.isCancelled breaks us out.
        await waitForIdentity()
        guard !Task.isCancelled else { return false }

        // Purge expired posted ledger entries on every drain (90 days retention)
        store.purgeExpiredLedgerEntries(olderThan: 90 * 24 * 60 * 60)
        let purgedDeadLetters = store.purgeExpiredDeadLetters()
        if purgedDeadLetters > 0 {
            Log.receipts.info("Purged \(purgedDeadLetters) expired dead-lettered item(s)")
        }

        // Hydrate persisted cooldown on first drain (survives app restart)
        if rateLimitCooldownUntil == nil, let persisted = store.getRateLimitCooldown() {
            if persisted > Date() {
                rateLimitCooldownUntil = persisted
                Log.receipts.debug("Restored rate-limit cooldown until \(persisted)")
            } else {
                // Expired — clear from disk
                store.setRateLimitCooldown(nil)
            }
        }

        var hasWork = true
        var didWork = false

        while hasWork && !Task.isCancelled {
            hasWork = false
            let now = Date()

            // Step 1: Handle items that need finishing (from previous POST results or crash recovery)
            // Also remove stale items that are already in the posted ledger (crash recovery edge case)
            let allItems = store.snapshot()
            let finishItems = allItems.filter { $0.phase == .needsFinish }
            for item in finishItems {
                hasWork = true
                didWork = true
                await finishAndRemove(item)
            }
            // Remove stale items that are in the posted ledger but not yet removed (crash recovery edge case).
            // Excludes .deadLettered items — those are intentionally kept in the store for diagnostics
            // even though they are also written to the posted ledger (to prevent re-enqueue on StoreKit re-delivery).
            let stalePosted = allItems.filter {
                $0.phase != .needsFinish && $0.phase != .deadLettered && store.isPosted(key: $0.key)
            }
            for item in stalePosted {
                hasWork = true
                didWork = true
                await finishAndRemove(item)
                Log.receipts.debug("[key=\(item.key)] Removed stale item — already in posted ledger")
            }

            // Step 2: Check rate-limit cooldown BEFORE claiming — no disk writes wasted
            if let cooldown = rateLimitCooldownUntil {
                if now < cooldown {
                    Log.receipts.debug("Rate-limit cooldown active, skipping POST cycle")
                    break
                } else {
                    // Cooldown expired — clear
                    rateLimitCooldownUntil = nil
                    store.setRateLimitCooldown(nil)
                }
            }

            // Step 3: Claim ready items — claimReady sets phase=.posting and persists
            let claimed = store.claimReady(limit: maxConcurrentPosts, now: now)

            if !claimed.isEmpty {
                hasWork = true
                didWork = true

                // Filter out items already in-flight (Layer B dedup)
                let newWork = claimed.filter { !inFlight.contains($0.key) }

                // Add to in-flight set
                for item in newWork {
                    inFlight.insert(item.key)
                }

                // Process items concurrently
                await withTaskGroup(of: Void.self) { group in
                    for item in newWork {
                        group.addTask { [weak self] in
                            await self?.processItem(item)
                        }
                    }
                }
            }
        }

        return didWork
    }

    // MARK: - Item Processing

    /// POSTs a single item to the server and handles the response.
    private func processItem(_ item: AppActorPaymentQueueItem) async {
        let request = Self.makeRequest(from: item)

        do {
            let response = try await client.postReceipt(request)
            await handleResponse(item: item, response: response)
        } catch let paymentError as AppActorError where paymentError.kind == .decoding {
            // HTTP 200 but response body couldn't be decoded — contract mismatch.
            // Won't self-resolve, so dead-letter aggressively after 5 attempts.
            var updated = item
            updated.attemptCount += 1
            updated.claimedAt = nil

            if updated.attemptCount >= Self.maxDecodeRetryAttempts {
                // Mark as posted to prevent re-enqueue if StoreKit re-delivers
                // this transaction after finish(). Decode mismatch = permanently
                // unprocessable (server contract incompatible).
                store.markPosted(key: item.key)
                updated.phase = .deadLettered
                updated.lastError = "decode_mismatch (dead-lettered after \(updated.attemptCount) attempts)"
                store.update(updated)

                // Finish the StoreKit transaction to prevent infinite re-enqueue loops.
                // Keep the item in the store for diagnostics (phase=.deadLettered).
                await finishTransaction(updated)

                Log.receipts.error(
                    "[key=\(item.key)] Decode mismatch — dead-lettered after \(updated.attemptCount) attempts: "
                    + "\(paymentError.localizedDescription)"
                )
                emitEvent(.deadLettered(
                    transactionId: item.transactionId,
                    attemptCount: updated.attemptCount,
                    lastErrorCode: "DECODE_MISMATCH"
                ), item: item)
                resumeContinuation(key: item.key, result: .queued)
            } else {
                updated.phase = .needsPost
                updated.nextRetryAt = Date().addingTimeInterval(Self.backoffDelay(attempt: updated.attemptCount))
                updated.lastError = "decode_mismatch: \(paymentError.localizedDescription)"
                store.update(updated)

                Log.receipts.warn(
                    "[key=\(item.key)] Decode mismatch (attempt \(updated.attemptCount)/\(Self.maxDecodeRetryAttempts)): "
                    + "\(paymentError.localizedDescription)"
                )
                emitEvent(.retryScheduled(
                    transactionId: item.transactionId,
                    attempt: updated.attemptCount,
                    nextAttemptAt: updated.nextRetryAt,
                    errorCode: "DECODE_MISMATCH"
                ), item: item)
                resumeContinuation(key: item.key, result: .queued)
            }
        } catch {
            var updated = item
            updated.attemptCount += 1
            updated.claimedAt = nil

            // Permanent client errors (4xx excluding 429) will never succeed on retry — dead-letter immediately.
            if let appError = error as? AppActorError, appError.isPermanentClientError {
                let rejectionResult = AppActorReceiptPostResult.permanentlyRejected(
                    errorCode: "HTTP_\(appError.httpStatus ?? 0)",
                    message: error.localizedDescription,
                    requestId: appError.requestId
                )
                rememberCompletedResult(key: item.key, result: rejectionResult)
                store.markPosted(key: item.key)
                updated.phase = .deadLettered
                updated.lastError = "permanent_client_error: \(error.localizedDescription)"
                store.update(updated)
                await finishTransaction(updated)

                Log.receipts.warn("[key=\(item.key)] Permanent client error (HTTP \(appError.httpStatus ?? 0)) — dead-lettered")
                emitEvent(.deadLettered(
                    transactionId: item.transactionId,
                    attemptCount: updated.attemptCount,
                    lastErrorCode: "HTTP_\(appError.httpStatus ?? 0)"
                ), item: item)
                resumeContinuation(key: item.key, result: rejectionResult)
            } else {
                // Network or unexpected error — mark for retry with standard backoff
                updated.phase = .needsPost
                updated.nextRetryAt = Date().addingTimeInterval(Self.backoffDelay(attempt: updated.attemptCount))
                updated.lastError = error.localizedDescription
                store.update(updated)

                Log.receipts.warn("[key=\(item.key)] Receipt POST failed (queued for retry): \(error.localizedDescription)")
                emitEvent(.retryScheduled(
                    transactionId: item.transactionId,
                    attempt: updated.attemptCount,
                    nextAttemptAt: updated.nextRetryAt,
                    errorCode: nil
                ), item: item)
                resumeContinuation(key: item.key, result: .queued)
            }
        }

        inFlight.remove(item.key)
    }

    /// Handles the server response for a POSTed item.
    private func handleResponse(item: AppActorPaymentQueueItem, response: AppActorReceiptPostResponse) async {
        switch response.status {
        case "ok":
            let shouldFinish = response.finishTransaction ?? true
            if shouldFinish {
                await markPostedFinishAndRemove(item)
            } else {
                store.markPosted(key: item.key)
                transactionMap.removeValue(forKey: item.key)
                store.remove(key: item.key)
            }

            Log.receipts.info("[key=\(item.key)] Transaction \(item.transactionId) posted ok (request_id: \(response.requestId ?? "none"), finish: \(response.finishTransaction ?? true))")
            emitEvent(.postedOk(transactionId: item.transactionId), item: item)
            let customerInfo = response.customer.map {
                AppActorCustomerInfo(dto: $0, appUserId: item.appUserId, requestDate: nil)
            }
            rememberCompletedResult(key: item.key, result: .success(customerInfo))
            if let customerInfo {
                onCustomerInfoUpdated?(customerInfo, item.appUserId, item.productId)
            }
            resumeContinuation(key: item.key, result: .success(customerInfo))

        case "permanent_error":
            let errorCode = response.error?.code
            let shouldFinish = response.finishTransaction ?? true
            let rejectionResult = AppActorReceiptPostResult.permanentlyRejected(
                errorCode: errorCode,
                message: response.error?.message,
                requestId: response.requestId
            )

            if shouldFinish {
                rememberCompletedResult(key: item.key, result: rejectionResult)
                await markPostedFinishAndRemove(item)
            } else {
                // When finishTransaction=false (consumable protection): do NOT mark as posted
                // and do NOT finish the StoreKit transaction. The transaction stays in
                // Transaction.unfinished so sweepUnfinished can re-enqueue it on next launch,
                // giving the server another chance to process it.
                transactionMap.removeValue(forKey: item.key)
                store.remove(key: item.key)
            }

            Log.receipts.warn("Receipt rejected by server (code: \(errorCode ?? "unknown"), finish: \(shouldFinish))")
            emitEvent(.permanentlyRejected(transactionId: item.transactionId, errorCode: errorCode), item: item)
            resumeContinuation(key: item.key, result: rejectionResult)

        default:
            // retryable_error or unknown status
            var updated = item
            updated.attemptCount += 1
            let errorCode = response.error?.code

            // Check for RATE_LIMIT — apply + persist cooldown (survives restart)
            if errorCode == "RATE_LIMIT" {
                let cooldown = Self.retryDelay(attempt: updated.attemptCount, serverRetryAfter: response.retryAfterSeconds)
                let cooldownDate = Date().addingTimeInterval(cooldown)
                rateLimitCooldownUntil = cooldownDate
                store.setRateLimitCooldown(cooldownDate)
                Log.receipts.debug("[key=\(item.key)] Rate-limit cooldown set until \(cooldownDate)")
            }

            if updated.attemptCount >= Self.maxRetryAttempts {
                let isExpired = item.firstSeenAt.addingTimeInterval(Self.retryLifetimeLimit) < Date()

                updated.phase = .deadLettered
                updated.claimedAt = nil

                if isExpired {
                    // Item has been retrying across boots for 7+ days — give up permanently.
                    store.markPosted(key: item.key)
                    updated.lastError = "\(response.status)\(errorCode.map { ": \($0)" } ?? "") (expired after 7+ days)"
                    store.update(updated)
                    await finishTransaction(updated)
                    Log.receipts.error("[key=\(item.key)] Retry lifetime expired — permanently dead-lettered")
                } else {
                    // Keep transaction unfinished for sweepUnfinished() recovery on next boot.
                    updated.lastError = "\(response.status)\(errorCode.map { ": \($0)" } ?? "") (dead-lettered, will retry on next boot)"
                    store.update(updated)
                    Log.receipts.warn("[key=\(item.key)] Retryable exhausted after \(updated.attemptCount) attempts — keeping unfinished for next boot")
                }

                emitEvent(.deadLettered(
                    transactionId: item.transactionId,
                    attemptCount: updated.attemptCount,
                    lastErrorCode: errorCode
                ), item: item)
                resumeContinuation(key: item.key, result: .queued)
            } else {
                let backoff = Self.retryDelay(
                    attempt: updated.attemptCount,
                    serverRetryAfter: response.retryAfterSeconds
                )
                updated.phase = .needsPost
                updated.claimedAt = nil
                updated.nextRetryAt = Date().addingTimeInterval(backoff)
                updated.lastError = response.status == "retryable_error"
                    ? "retryable_error\(errorCode.map { ": \($0)" } ?? "")"
                    : "unknown status: \(response.status)"
                store.update(updated)

                Log.receipts.debug("[key=\(item.key)] Retry scheduled (attempt \(updated.attemptCount), code: \(errorCode ?? "none"))")

                emitEvent(.retryScheduled(
                    transactionId: item.transactionId,
                    attempt: updated.attemptCount,
                    nextAttemptAt: updated.nextRetryAt,
                    errorCode: errorCode
                ), item: item)
                resumeContinuation(key: item.key, result: .queued)
            }
        }
    }

    // MARK: - Finish + Remove

    /// Finishes the StoreKit transaction without removing the item from the store.
    /// Used for dead-lettered items that need the transaction cleared from
    /// `Transaction.unfinished` but should remain in the store for diagnostics.
    ///
    /// Only uses `transactionMap` (fast-path). If the transaction isn't in the map,
    /// it's already been finished by `sweepUnfinished` or was lost to a crash.
    /// `sweepUnfinished` runs at boot and re-enqueues unfinished transactions,
    /// so the map will be populated for any transaction that needs finishing.
    private func finishTransaction(_ item: AppActorPaymentQueueItem) async {
        if let transaction = transactionMap.removeValue(forKey: item.key) {
            await transaction.finish()
            Log.receipts.debug("[key=\(item.key)] Transaction \(item.transactionId) finished")
        } else {
            Log.receipts.debug("[key=\(item.key)] Transaction \(item.transactionId) already finished")
        }
    }

    /// Finishes the StoreKit transaction and removes the item from the store.
    ///
    /// Uses `transactionMap` to find the live transaction reference.
    /// If not in the map, the transaction was already finished elsewhere
    /// (e.g. by `sweepUnfinished` at boot). Removes the item regardless.
    private func finishAndRemove(_ item: AppActorPaymentQueueItem) async {
        await finishTransaction(item)
        store.remove(key: item.key)
    }

    /// Atomically marks an item as posted, transitions to `.needsFinish`, and finishes
    /// the StoreKit transaction — all with a single disk write for crash safety.
    private func markPostedFinishAndRemove(_ item: AppActorPaymentQueueItem) async {
        var updated = item
        updated.phase = .needsFinish
        updated.claimedAt = nil
        store.markPostedAndUpdate(key: item.key, item: updated)
        await finishAndRemove(updated)
    }

    // MARK: - Continuation Management

    private func resumeContinuation(key: String, result: AppActorReceiptPostResult) {
        // F5 fix: cancel timeout task on normal completion
        timeoutTasks.removeValue(forKey: key)?.cancel()
        if let continuation = pendingResults.removeValue(forKey: key) {
            continuation.resume(returning: result)
        }
    }

    /// Resumes a pending purchase continuation with `.queued` on timeout.
    /// No-op if the continuation was already resumed by the drain loop (exactly-once guarantee).
    private func timeoutContinuation(key: String) {
        timeoutTasks.removeValue(forKey: key) // Clean up self-reference
        if let continuation = pendingResults.removeValue(forKey: key) {
            Log.receipts.debug("[key=\(key)] Purchase await timed out, returning .queued")
            continuation.resume(returning: .queued)
        }
    }

    private func rememberCompletedResult(key: String, result: AppActorReceiptPostResult) {
        purgeExpiredCompletedResults()
        completedResults[key] = CompletedReceiptResult(result: result, recordedAt: Date())
    }

    private func purgeExpiredCompletedResults(referenceDate: Date = Date()) {
        let cutoff = referenceDate.addingTimeInterval(-Self.completedResultRetention)
        completedResults = completedResults.filter { $0.value.recordedAt >= cutoff }
    }

    // MARK: - Static Helpers

    /// Builds a `PaymentQueueItem` from a verified StoreKit transaction.
    static func makePaymentQueueItem(
        from transaction: Transaction,
        jws: String,
        source: AppActorPaymentQueueItem.Source,
        appUserId: String,
        jwsPayload: [String: Any]? = nil,
        environment: AppActorTransactionEnvironment? = nil
    ) -> AppActorPaymentQueueItem {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let resolvedJWSPayload = jwsPayload ?? AppActorASATransactionSupport.decodeJWSPayload(jws)
        let resolvedEnvironment = (
            environment ?? AppActorASATransactionSupport.resolveEnvironment(
                for: transaction,
                jwsPayload: resolvedJWSPayload
            )
        ).rawValue

        var storefront: String? = nil
        if #available(iOS 17.0, macOS 14.0, *) {
            storefront = transaction.storefrontCountryCode
        }

        let now = Date()
        let transactionId = String(transaction.id)
        return AppActorPaymentQueueItem(
            key: AppActorPaymentQueueItem.makeKey(transactionId: transactionId),
            bundleId: bundleId,
            environment: resolvedEnvironment,
            transactionId: transactionId,
            jws: jws,
            appUserId: appUserId,
            productId: transaction.productID,
            originalTransactionId: String(transaction.originalID),
            storefront: storefront,
            phase: .needsPost,
            attemptCount: 0,
            nextRetryAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            lastError: nil,
            sources: [source],
            claimedAt: nil
        )
    }

    /// Builds a `AppActorReceiptPostRequest` from a `AppActorPaymentQueueItem`.
    static func makeRequest(from item: AppActorPaymentQueueItem) -> AppActorReceiptPostRequest {
        AppActorReceiptPostRequest(
            appUserId: item.appUserId,
            appId: item.bundleId,
            environment: item.environment,
            bundleId: item.bundleId,
            storefront: item.storefront,
            signedTransactionInfo: item.jws,
            transactionId: item.transactionId,
            productId: item.productId,
            idempotencyKey: item.key,
            originalTransactionId: item.originalTransactionId
        )
    }

    /// Backoff schedule: 3 retries (0s, 0.75s, 3s). Dead-lettered after 3 failed attempts.
    /// All retries complete in ~4s, well within `purchaseAwaitTimeout` (10s).
    static func backoffDelay(attempt: Int) -> TimeInterval {
        switch attempt {
        case 0:  return 0       // Immediate
        case 1:  return 0.75    // 750ms
        default: return 3       // 3 seconds
        }
    }

    /// Computes retry delay, respecting server `retryAfterSeconds` if provided.
    /// Cap at 30s to fit the 3-retry budget within a reasonable window.
    static func retryDelay(attempt: Int, serverRetryAfter: Double?) -> TimeInterval {
        let backoff = backoffDelay(attempt: attempt)
        guard let serverDelay = serverRetryAfter,
              serverDelay > 0, serverDelay <= 30 else {
            return backoff
        }
        return max(backoff, serverDelay)
    }

    /// Scans `Transaction.unfinished` to re-obtain a `Transaction` by ID.
    static func findUnfinishedTransaction(id: String) async -> Transaction? {
        for await result in Transaction.unfinished {
            if case .verified(let tx) = result, String(tx.id) == id {
                return tx
            }
        }
        return nil
    }

    // MARK: - Private

    private func emitEvent(_ event: AppActorReceiptPipelineEvent, item: AppActorPaymentQueueItem) {
        if let handler = onPipelineEvent {
            handler(AppActorReceiptPipelineEventDetail(
                event: event, productId: item.productId, appUserId: item.appUserId
            ))
        }
    }
}
