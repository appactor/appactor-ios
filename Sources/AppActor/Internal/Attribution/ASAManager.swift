import Foundation

/// Coordinates Apple Search Ads attribution tracking.
///
/// Manages:
/// - One-time attribution via `AAAttribution.attributionToken()` + `POST /v1/asa/attribution`
/// - Purchase event tracking via `POST /v1/asa/purchase-event`
/// - User ID migration via `POST /v1/asa/update-user-id`
///
/// Created when `enableAppleSearchAdsTracking()` is called.
/// Lifecycle is managed by `AppActor+Payment.swift`.
///
/// Actor isolation guarantees:
/// - No data races on mutable state (`isPerformingAttribution`, `isFlushingPurchaseEvents`, `isFlushingUserIdChange`)
/// - Re-entrancy guards prevent overlapping calls at `await` suspension points
actor AppActorASAManager {

    private let client: any AppActorPaymentClientProtocol
    private let storage: any AppActorPaymentStorage
    private let eventStore: any AppActorASAEventStoreProtocol
    private let tokenProvider: any AppActorASATokenProviderProtocol
    private let options: AppActorASAOptions
    private let sdkVersion: String


    /// Maximum attribution retry attempts for transient failures.
    private static let maxAttributionAttempts = 3

    /// Maximum number of token-only POSTs across launches before marking completed.
    /// Prevents infinite re-posts when Apple's API is persistently unavailable.
    private static let maxTokenOnlyAttempts = 3

    /// Re-entrancy guards to prevent overlapping calls.
    /// Actor isolation ensures check-and-set is atomic (no `await` between guard and flag set).
    private var isPerformingAttribution = false
    private var isFlushingPurchaseEvents = false
    private var isFlushingUserIdChange = false
    private var needsAnotherPurchaseFlushPass = false

    init(
        client: any AppActorPaymentClientProtocol,
        storage: any AppActorPaymentStorage,
        eventStore: any AppActorASAEventStoreProtocol,
        tokenProvider: any AppActorASATokenProviderProtocol = AppActorASALiveTokenProvider(),
        options: AppActorASAOptions,
        sdkVersion: String
    ) {
        self.client = client
        self.storage = storage
        self.eventStore = eventStore
        self.tokenProvider = tokenProvider
        self.options = options
        self.sdkVersion = sdkVersion
    }

    // MARK: - Attribution

    /// Performs ASA attribution if not already completed for this install.
    /// Called once during bootstrap after identify.
    ///
    /// Flow:
    /// 1. Get attribution token from AdServices
    /// 2. Validate a confirmed userId exists (captured once — update-user-id mechanism handles changes)
    /// 3. Call Apple AdServices API for raw attribution data (graceful degradation on failure)
    /// 4. Build request with token + Apple response + device info
    /// 5. POST with retry for transient failures (up to 3 times with exponential backoff)
    ///    - On success with Apple response or permanent Apple failure → mark completed
    ///    - On success with transient Apple failure → return result but do NOT mark completed (retry next launch for richer data)
    /// 6. On permanent backend failure (4xx) → mark completed to avoid infinite retries
    /// 7. On token provider error → defer to next launch (do NOT mark organic)
    @discardableResult
    func performAttributionIfNeeded() async -> AppActorASAAttributionResult? {
        guard !Task.isCancelled else { return nil }

        // [M1] Re-entrancy guard: prevents duplicate POSTs if called concurrently
        guard !isPerformingAttribution else {
            if options.debugMode {
                Log.attribution.debug("Attribution already in-flight, skipping.")
            }
            return nil
        }
        isPerformingAttribution = true
        defer { isPerformingAttribution = false }

        guard !storage.asaAttributionCompleted else {
            Log.attribution.info("Attribution already completed, skipping.")
            return nil
        }

        // 1. Get attribution token (tri-state: token / unavailable / error)
        let tokenResult = await tokenProvider.attributionToken()

        let token: String
        switch tokenResult {
        case .token(let t):
            token = t
        case .unavailable:
            // [P1-fix] Platform doesn't support ASA → mark organic (correct)
            Log.attribution.info("No attribution token available (unsupported platform), marking as completed (organic).")
            storage.setAsaAttributionCompleted(true)
            AppActorASAKeychainHelper.markAttributionCompleted()
            return nil
        case .error(let error):
            // [P1-fix] Transient AdServices error → do NOT mark completed, retry on next launch
            Log.attribution.warn("Attribution token fetch error, deferring to next launch: \(error.localizedDescription)")
            return nil
        }

        if options.debugMode {
            Log.attribution.debug("Got attribution token (\(token.prefix(20))...)")
        }

        // 2. Require a confirmed server identity before making the attribution call.
        guard let userId = storage.currentAppUserId,
              storage.serverUserId != nil,
              !storage.needsReidentify else {
            Log.attribution.info("Server identity not ready, deferring ASA attribution.")
            return nil
        }

        // 3. Call Apple's AdServices API to get raw attribution response
        var appleAttributionResponse: [String: AnyCodable]? = nil
        var hasAppleResponse = false
        /// If Apple returns a permanent error (e.g. 4xx), retrying on next launch won't help.
        var appleFailurePermanent = false
        let appleResult = await tokenProvider.fetchAppleAttribution(token: token)
        switch appleResult {
        case .success(let response):
            appleAttributionResponse = response.json.asAnyCodable
            hasAppleResponse = true
            if options.debugMode {
                Log.attribution.debug("Apple AdServices API returned: \(response.json.keys.joined(separator: ", "))")
            }
        case .error(let error):
            // Check if the Apple API error is permanent (4xx except 429) by inspecting NSError code
            let nsError = error as NSError
            let code = nsError.code
            if (400..<500).contains(code) && code != 429 {
                appleFailurePermanent = true
                Log.attribution.warn("Apple AdServices API permanent error (HTTP \(code)): \(error.localizedDescription). Proceeding with token only, will mark completed.")
            } else {
                Log.attribution.warn("Apple AdServices API call failed: \(error.localizedDescription). Proceeding with token only.")
            }
        }

        // 4. Build request once — userId is captured once and NOT re-read during retries.
        // If userId changes during backoff (login/logout), the update-user-id mechanism
        // (enqueueUserIdChange → flushPendingUserIdChange on next bootstrap) handles
        // transferring the attribution to the new user on the backend.
        let request = AppActorASAAttributionRequest(
            userId: userId,
            attributionToken: token,
            osVersion: AppActorAutoDeviceInfo.osVersion,
            appVersion: AppActorAutoDeviceInfo.appVersion,
            libVersion: sdkVersion,
            firstInstallOnDevice: AppActorASAKeychainHelper.firstInstallOnDevice,
            firstInstallOnAccount: AppActorASAKeychainHelper.firstInstallOnAccount,
            installDate: storage.asaInstallDate,
            asaAttributionResponse: appleAttributionResponse
        )

        // Log the request payload for debugging
        Log.attribution.info("→ POST /v1/asa/attribution | userId: \(request.userId), token: \(request.attributionToken.prefix(20))..., osVersion: \(request.osVersion ?? "n/a"), appVersion: \(request.appVersion ?? "n/a"), libVersion: \(request.libVersion), firstInstallOnDevice: \(request.firstInstallOnDevice), firstInstallOnAccount: \(request.firstInstallOnAccount), installDate: \(request.installDate ?? "n/a"), hasAppleResponse: \(request.asaAttributionResponse != nil)")

        // 5. POST with retry for transient failures
        var lastRetryAfter: TimeInterval? = nil
        for attempt in 0..<Self.maxAttributionAttempts {
            // Check cancellation before each attempt
            guard !Task.isCancelled else {
                Log.attribution.debug("Attribution cancelled.")
                return nil
            }

            if attempt > 0 {
                let delay = Self.backoffDelay(attempt: attempt, retryAfter: lastRetryAfter)
                lastRetryAfter = nil // consumed
                if options.debugMode {
                    Log.attribution.debug("Attribution retry \(attempt)/\(Self.maxAttributionAttempts - 1) after \(String(format: "%.1f", delay))s")
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // Sleep interrupted (cancellation) — abort
                    Log.attribution.debug("Attribution cancelled during backoff.")
                    return nil
                }
            }

            do {
                let response = try await client.postASAAttribution(request)

                Log.attribution.info("← 200 /v1/asa/attribution | status: \(response.status), attributionStatus: \(response.attribution.attributionStatus)")

                // [M3] Validate response status
                guard response.status == "ok" else {
                    Log.attribution.warn("Attribution response status: \(response.status), treating as transient error.")
                    continue
                }

                // Mark completed if we had the Apple response, or if Apple failure was permanent
                // (permanent = 4xx, retrying on next launch won't yield richer data).
                // Only leave uncompleted for transient Apple failures (network, 5xx, 429)
                // so the next launch can re-attempt with richer data.
                if hasAppleResponse || appleFailurePermanent {
                    storage.setAsaAttributionCompleted(true)
                    storage.clearAsaTokenOnlyAttempts()
                    AppActorASAKeychainHelper.markAttributionCompleted()
                } else {
                    // Token-only success — increment attempt counter.
                    // After maxTokenOnlyAttempts, mark completed to prevent infinite re-posts
                    // across launches when Apple's API is persistently unavailable.
                    storage.incrementAsaTokenOnlyAttempts()
                    let attempts = storage.asaTokenOnlyAttempts
                    if attempts >= Self.maxTokenOnlyAttempts {
                        storage.setAsaAttributionCompleted(true)
                        storage.clearAsaTokenOnlyAttempts()
                        AppActorASAKeychainHelper.markAttributionCompleted()
                        Log.attribution.info("Attribution sent with token only, max attempts (\(Self.maxTokenOnlyAttempts)) reached — marking completed.")
                    } else {
                        Log.attribution.info("Attribution sent with token only (attempt \(attempts)/\(Self.maxTokenOnlyAttempts)). Will re-attempt next launch for richer data.")
                    }
                }
                let result = AppActorASAAttributionResult(dto: response.attribution)
                let isCompleted = storage.asaAttributionCompleted
                let completedStr = isCompleted ? "completed" : "sent (pending re-attempt)"
                Log.attribution.info("Attribution \(completedStr): \(result.attributionStatus)")
                return result

            } catch let error as AppActorError {
                Log.attribution.error("← ERROR /v1/asa/attribution | HTTP \(error.httpStatus ?? 0), kind: \(error.kind), message: \(error.localizedDescription)")
                // Only mark completed on definitive 4xx client errors (not 429)
                if error.isPermanentClientError {
                    Log.attribution.error("Attribution permanent error (\(error.httpStatus ?? 0)): \(error.localizedDescription)")
                    storage.setAsaAttributionCompleted(true)
                    storage.clearAsaTokenOnlyAttempts()
                    AppActorASAKeychainHelper.markAttributionCompleted()
                    return nil
                }

                // [L1] Capture server retryAfter for next backoff
                lastRetryAfter = error.retryAfterSeconds

                // Transient (network, 5xx, 429, decoding, signature) — retry
                Log.attribution.warn("Attribution transient error (attempt \(attempt + 1)): \(error.localizedDescription)")
                continue

            } catch is CancellationError {
                Log.attribution.debug("Attribution cancelled.")
                return nil
            } catch {
                // Unknown error — treat as transient
                Log.attribution.warn("Attribution error (attempt \(attempt + 1)): \(error.localizedDescription)")
                continue
            }
        }

        // All retries exhausted — do NOT mark completed, will retry on next bootstrap
        Log.attribution.warn("Attribution failed after \(Self.maxAttributionAttempts) attempts, will retry on next launch.")
        return nil
    }

    // MARK: - User ID Change

    /// Flushes any pending user ID change to the server.
    ///
    /// Called during bootstrap BEFORE attribution and purchase flush,
    /// so the server always has the correct user identity.
    ///
    /// - Success (status == "ok") → clear pending
    /// - Permanent 4xx → clear pending (prevent infinite loop)
    /// - Transient error → leave pending for next bootstrap
    /// - Cancellation → return without clearing
    func flushPendingUserIdChange() async {
        // Re-entrancy guard: actor isolation ensures this check-and-set is atomic
        // (no suspension point between guard and flag set)
        guard !Task.isCancelled else { return }

        guard !isFlushingUserIdChange else {
            if options.debugMode {
                Log.attribution.debug("User ID change flush already in-flight, skipping.")
            }
            return
        }
        isFlushingUserIdChange = true
        defer { isFlushingUserIdChange = false }

        guard let pending = storage.asaPendingUserIdChange else { return }

        // Skip no-op changes
        if pending.oldUserId == pending.newUserId {
            if options.debugMode {
                Log.attribution.debug("User ID change is no-op (same ID), clearing.")
            }
            storage.clearAsaPendingUserIdChange()
            return
        }

        if options.debugMode {
            Log.attribution.debug("Flushing pending user ID change: \(pending.oldUserId) → \(pending.newUserId)")
        }

        let request = AppActorASAUpdateUserIdRequest(
            oldUserId: pending.oldUserId,
            newUserId: pending.newUserId
        )

        do {
            let response = try await client.postASAUpdateUserId(request)

            // [M3] Validate response status
            guard response.status == "ok" else {
                Log.attribution.warn("User ID change response status: \(response.status), will retry next launch.")
                return
            }

            // [N1] Compare-and-clear: only clear if pending hasn't been replaced during await
            clearPendingIfUnchanged(old: pending.oldUserId, new: pending.newUserId)
            Log.attribution.info("User ID change synced: \(pending.oldUserId) → \(pending.newUserId)")

        } catch let error as AppActorError {
            if error.isPermanentClientError {
                // [N1] Compare-and-clear: only clear if pending hasn't been replaced during await
                Log.attribution.error("User ID change permanent error (\(error.httpStatus ?? 0)), clearing pending.")
                clearPendingIfUnchanged(old: pending.oldUserId, new: pending.newUserId)
            } else {
                // Transient — leave for next bootstrap
                Log.attribution.warn("User ID change transient error, will retry next launch: \(error.localizedDescription)")
            }

        } catch is CancellationError {
            Log.attribution.debug("User ID change cancelled.")

        } catch {
            // Unknown error — leave for next bootstrap
            Log.attribution.warn("User ID change error, will retry next launch: \(error.localizedDescription)")
        }
    }

    /// [N1] Clears pending user ID change only if it still matches the snapshotted values.
    /// Prevents wiping a newer enqueue that arrived during the network await.
    private func clearPendingIfUnchanged(old: String, new: String) {
        if let current = storage.asaPendingUserIdChange,
           current.oldUserId == old, current.newUserId == new {
            storage.clearAsaPendingUserIdChange()
        }
    }

    /// Enqueues a user ID change for ASA sync.
    ///
    /// **Chain-aware**: If a pending change already exists (A→B), and a new
    /// change arrives (B→C), the result is A→C — preserving the original
    /// user ID so the backend can transfer attribution from the very first user.
    /// If chaining would result in a no-op (A→B then B→A), the pending is cleared.
    func enqueueUserIdChange(oldUserId: String, newUserId: String) {
        let effectiveOld: String
        if let existing = storage.asaPendingUserIdChange {
            // Chain: existing A→B + new B→C = A→C
            effectiveOld = existing.oldUserId
        } else {
            effectiveOld = oldUserId
        }

        // No-op: chaining resolved to same user (e.g. A→B then B→A)
        if effectiveOld == newUserId {
            storage.clearAsaPendingUserIdChange()
            if options.debugMode {
                Log.attribution.debug("User ID change is no-op after chaining (\(effectiveOld) → \(newUserId)), cleared.")
            }
            return
        }

        storage.setAsaPendingUserIdChange(oldUserId: effectiveOld, newUserId: newUserId)
        if options.debugMode {
            Log.attribution.debug("User ID change enqueued: \(effectiveOld) → \(newUserId)")
        }
    }

    // MARK: - Purchase Events

    /// Maximum retry attempts per purchase event before removal.
    private static let maxPurchaseEventRetries = 5

    /// Flushes any pending purchase events to the server.
    ///
    /// Processes events serially in FIFO order (oldest first).
    /// - Success (status == "ok") → remove from store
    /// - Permanent 4xx → remove (bad request, won't succeed on retry)
    /// - Transient → increment retryCount; remove if >= maxRetries
    /// - Cancellation → stop loop, keep remaining events
    func flushPendingPurchaseEvents() async {
        guard !Task.isCancelled else { return }

        // Re-entrancy guard: actor isolation ensures this check-and-set is atomic
        // (no suspension point between guard and flag set)
        guard !isFlushingPurchaseEvents else {
            if options.debugMode {
                Log.attribution.debug("Purchase event flush already in-flight, skipping.")
            }
            return
        }
        isFlushingPurchaseEvents = true
        defer { isFlushingPurchaseEvents = false }

        while true {
            needsAnotherPurchaseFlushPass = false

            switch await flushPendingPurchaseEventsPass() {
            case .completed:
                guard needsAnotherPurchaseFlushPass else {
                    if options.debugMode {
                        Log.attribution.debug("All purchase events flushed successfully.")
                    }
                    return
                }
                if options.debugMode {
                    Log.attribution.debug("Purchase queue changed during flush, starting another pass.")
                }
            case .blocked, .cancelled:
                return
            }
        }
    }

    /// Enqueues a purchase event for ASA sync.
    ///
    /// Deduplicates by `originalTransactionId`: if a pending event with the same
    /// original transaction ID already exists in the store, the enqueue is silently
    /// skipped. This achieves subscription-level dedup — renewals share the same
    /// `originalTransactionId`, so only the first purchase per subscription is tracked.
    /// This matches ASA attribution semantics: we care about the initial purchase
    /// driven by the ad, not subsequent auto-renewals.
    func enqueuePurchaseEvent(
        userId: String,
        productId: String,
        transactionId: String?,
        originalTransactionId: String?,
        purchaseDate: Date,
        countryCode: String?,
        storekit2Json: [String: Any]?
    ) async {
        // Lifetime dedup by originalTransactionId (subscription-level).
        // Checks both pending events AND previously sent events in storage.
        // Renewals share the same originalTransactionId, so only the initial
        // purchase per subscription is ever tracked — matching ASA attribution semantics.
        if let originalTransactionId, !originalTransactionId.isEmpty {
            // Check 1: already sent to backend (persisted across app launches)
            if storage.isAsaOriginalTransactionIdSent(originalTransactionId) {
                if options.debugMode {
                    Log.attribution.debug("Purchase event skipped (already sent): originalTransactionId \(originalTransactionId)")
                }
                return
            }
            // Check 2: already pending in queue (not yet sent)
            let pendingEvents = eventStore.pending()
            if pendingEvents.contains(where: { $0.request.originalTransactionId == originalTransactionId }) {
                if options.debugMode {
                    Log.attribution.debug("Purchase event skipped (already pending): originalTransactionId \(originalTransactionId)")
                }
                return
            }
        }

        let iso8601 = ISO8601DateFormatter()
        let request = AppActorASAPurchaseEventRequest(
            userId: userId,
            productId: productId,
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            purchaseDate: iso8601.string(from: purchaseDate),
            countryCode: countryCode,
            storekit2Json: storekit2Json?.asAnyCodable,
            appVersion: AppActorAutoDeviceInfo.appVersion,
            osVersion: AppActorAutoDeviceInfo.osVersion,
            libVersion: sdkVersion
        )

        let storedEvent = AppActorASAStoredEvent(
            id: UUID().uuidString.lowercased(),
            request: request,
            retryCount: 0,
            createdAt: Date()
        )

        eventStore.enqueue(storedEvent)

        if options.debugMode {
            Log.attribution.debug("Purchase event enqueued: \(productId) (id: \(storedEvent.id))")
        }

        if isFlushingPurchaseEvents {
            needsAnotherPurchaseFlushPass = true
            if options.debugMode {
                Log.attribution.debug("Purchase event queued while flush in-flight, scheduling follow-up pass.")
            }
            return
        }

        // Trigger immediate flush so events don't wait until next foreground/bootstrap.
        // Re-entrancy guard inside flushPendingPurchaseEvents() prevents overlapping calls.
        await flushPendingPurchaseEvents()
    }

    // MARK: - Diagnostics

    /// Returns a point-in-time snapshot of all ASA state for debugging.
    func diagnostics() -> AppActorASADiagnostics {
        let pending = storage.asaPendingUserIdChange
        return AppActorASADiagnostics(
            attributionCompleted: storage.asaAttributionCompleted,
            pendingPurchaseEventCount: eventStore.count(),
            hasPendingUserIdChange: pending != nil,
            pendingUserIdChange: pending.map {
                .init(oldUserId: $0.oldUserId, newUserId: $0.newUserId)
            },
            debugMode: options.debugMode,
            autoTrackPurchases: options.autoTrackPurchases,
            trackInSandbox: options.trackInSandbox
        )
    }

    /// Number of pending purchase events in the queue.
    func pendingPurchaseEventCount() -> Int {
        eventStore.count()
    }

    // MARK: - Backoff

    /// Maximum backoff delay (caps both computed and server-provided retryAfter).
    private static let maxBackoffDelay: TimeInterval = 120.0

    /// Exponential backoff with jitter for retry attempts.
    /// [L1] Honors server-provided retryAfter when available.
    /// [N2] Capped to maxBackoffDelay to prevent excessively long sleeps.
    /// attempt 1 → ~2s, attempt 2 → ~4s (or retryAfter if larger, up to 120s)
    private static func backoffDelay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let base = min(pow(2.0, Double(attempt)), 30.0)
        let jitter = Double.random(in: 0..<base)
        let computed = base + jitter
        // Honor server retry-after if provided and larger than our computed backoff
        if let retryAfter, retryAfter > computed {
            return min(retryAfter, maxBackoffDelay)
        }
        return computed
    }

    private enum PurchaseEventFlushPassResult {
        case completed
        case blocked
        case cancelled
    }

    private func flushPendingPurchaseEventsPass() async -> PurchaseEventFlushPassResult {
        let events = eventStore.pending()
        guard !events.isEmpty else { return .completed }

        if options.debugMode {
            Log.attribution.debug("Flushing \(events.count) pending purchase event(s)")
        }

        var processedCount = 0

        for event in events {
            guard !Task.isCancelled else {
                let remaining = events.count - processedCount
                Log.attribution.debug("Purchase event flush cancelled, \(remaining) event(s) remain.")
                return .cancelled
            }

            do {
                let response = try await client.postASAPurchaseEvent(event.request)

                guard response.status == "ok" else {
                    Log.attribution.warn("Purchase event response status: \(response.status), treating as transient error for \(event.request.productId)")
                    var updated = event
                    updated.retryCount += 1
                    if updated.retryCount >= Self.maxPurchaseEventRetries {
                        eventStore.remove(id: event.id)
                        Log.attribution.warn("Purchase event dropped (non-ok status, \(updated.retryCount) retries): \(event.request.productId)")
                    } else {
                        eventStore.update(updated)
                    }
                    return .blocked
                }

                if let origTxId = event.request.originalTransactionId, !origTxId.isEmpty {
                    storage.markAsaSentOriginalTransactionId(origTxId)
                }
                eventStore.remove(id: event.id)
                processedCount += 1
                if options.debugMode {
                    Log.attribution.debug("Purchase event sent: \(event.request.productId) (eventId: \(response.eventId))")
                }

            } catch let error as AppActorError {
                if error.isPermanentClientError {
                    eventStore.remove(id: event.id)
                    processedCount += 1
                    Log.attribution.error("Purchase event permanent error (\(error.httpStatus ?? 0)), removed: \(event.request.productId)")
                } else {
                    var updated = event
                    updated.retryCount += 1

                    if updated.retryCount >= Self.maxPurchaseEventRetries {
                        eventStore.remove(id: event.id)
                        Log.attribution.warn("Purchase event max retries (\(Self.maxPurchaseEventRetries)) reached, removed: \(event.request.productId)")
                    } else {
                        eventStore.update(updated)
                        Log.attribution.warn("Purchase event transient error (retry \(updated.retryCount)/\(Self.maxPurchaseEventRetries)): \(event.request.productId)")
                    }
                    return .blocked
                }

            } catch is CancellationError {
                Log.attribution.debug("Purchase event flush cancelled.")
                return .cancelled

            } catch {
                var updated = event
                updated.retryCount += 1

                if updated.retryCount >= Self.maxPurchaseEventRetries {
                    eventStore.remove(id: event.id)
                    Log.attribution.warn("Purchase event max retries reached (unknown error), removed: \(event.request.productId)")
                } else {
                    eventStore.update(updated)
                    Log.attribution.warn("Purchase event unknown error (retry \(updated.retryCount)): \(error.localizedDescription)")
                }
                return .blocked
            }
        }

        return .completed
    }
}
