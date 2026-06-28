import Foundation

// MARK: - Customer Public API

extension AppActor {

    /// Fetches the current customer's entitlement and subscription info from the server.
    ///
    /// Always makes a network request. Uses conditional requests (`If-None-Match` / `ETag`)
    /// to minimize data transfer when info hasn't changed (server returns 304).
    /// Concurrent calls are coalesced into a single network request.
    ///
    /// - Returns: The latest `AppActorCustomerInfo`.
    /// - Throws: `AppActorError` on network, decode, or server failures.
    @discardableResult
    public func getCustomerInfo() async throws -> AppActorCustomerInfo {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let manager = customerManager,
              let appUserId = paymentStorage?.currentAppUserId else {
            throw AppActorError.notConfigured
        }
        do {
            let info = try await manager.getCustomerInfo(appUserId: appUserId)
            await setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
            await paymentProcessor?.kick()
            return info
        } catch let appError as AppActorError where appError.isTransient {
            // Clear cache timestamp so staleness timer/foreground handler retries immediately
            await manager.clearCache(appUserId: appUserId)
            let offlineKeys = await manager.activeEntitlementKeysOffline(appUserId: appUserId)
            if let offlineInfo = await offlineCustomerInfoIfIdentityMatches(
                expectedAppUserId: appUserId,
                offlineKeys: offlineKeys
            ) {
                await setCustomerInfoIfIdentityMatches(offlineInfo, expectedAppUserId: appUserId)
                Log.customer.info("Server unreachable — offline entitlements: \(offlineKeys)")
                return offlineInfo
            }
            throw appError
        } catch {
            // Non-transient errors (401, 403, decode, signature) — rethrow directly
            throw error
        }
    }

    /// Derives active entitlement keys offline using StoreKit 2 transactions and the
    /// cached offerings `productEntitlements` mapping.
    ///
    /// Fallback order:
    /// 1. SK2 active product IDs + offerings mapping → entitlement keys.
    /// 2. Cached `CustomerInfo` within TTL → `activeEntitlementKeys`.
    /// 3. Empty set (no data available).
    ///
    /// Use this when the device is offline or as a fast local check.
    /// For authoritative data, use ``getCustomerInfo()`` instead.
    ///
    /// - Returns: Set of entitlement keys that are active offline.
    public func activeEntitlementKeysOffline() async -> Set<String> {
        guard let manager = customerManager else { return [] }
        return await manager.activeEntitlementKeysOffline()
    }

    func offlineCustomerInfoIfIdentityMatches(
        expectedAppUserId: String,
        offlineKeys: Set<String>
    ) async -> AppActorCustomerInfo? {
        guard paymentStorage?.currentAppUserId == expectedAppUserId else {
            return nil
        }

        let offlineNonSubscriptions = await customerManager?.derivedNonSubscriptionsFromStoreKit(
            offeringsManager: offeringsManager
        ) ?? [:]
        guard !offlineKeys.isEmpty || !offlineNonSubscriptions.isEmpty else {
            return nil
        }

        let offlineEntitlements = Dictionary(
            uniqueKeysWithValues: offlineKeys.map { key in
                (key, AppActorEntitlementInfo(id: key, isActive: true))
            }
        )

        return AppActorCustomerInfo(
            entitlements: offlineEntitlements,
            subscriptions: [:],
            nonSubscriptions: offlineNonSubscriptions,
            snapshotDate: Date(),
            appUserId: expectedAppUserId,
            isComputedOffline: true,
            verification: .verifiedOnDevice
        )
    }

    /// Cache-first cold-start seed.
    ///
    /// Surfaces persisted (or, on a cache miss, StoreKit-derived) entitlement state
    /// into the published `customerInfo` immediately at launch, before the network
    /// refresh in bootstrap completes — so premium UI renders instantly instead of
    /// waiting on a round-trip. Never downgrades an already-published value: it only
    /// seeds when `customerInfo` is still empty, and the identity/ordering guards in
    /// `setCustomerInfoIfIdentityMatches` let the later network value win.
    func seedCustomerInfoFromCacheOnLaunch() async {
        guard let manager = customerManager,
              let appUserId = paymentStorage?.currentAppUserId else { return }
        // Only seed when nothing real is published yet (avoid racing/downgrading bootstrap).
        guard customerInfo.appUserId == nil else { return }

        // 1. Disk cache (survives relaunch) — renders premium instantly.
        if let cached = await manager.cachedInfo(appUserId: appUserId) {
            await setCustomerInfoIfIdentityMatches(cached, expectedAppUserId: appUserId)
            return
        }

        // 2. Cache miss (e.g. reinstall) → derive from StoreKit so premium still shows.
        let offlineKeys = await manager.activeEntitlementKeysOffline(appUserId: appUserId)
        if let offlineInfo = await offlineCustomerInfoIfIdentityMatches(
            expectedAppUserId: appUserId,
            offlineKeys: offlineKeys
        ) {
            await setCustomerInfoIfIdentityMatches(offlineInfo, expectedAppUserId: appUserId)
        }
    }
}

// MARK: - Identity-Safe Customer Info Assignment

extension AppActor {
    /// Sets `customerInfo` only if the current user still matches the expected identity.
    /// Discards stale results from async calls that completed after a login/logout.
    func setCustomerInfoIfIdentityMatches(_ info: AppActorCustomerInfo, expectedAppUserId: String) async {
        guard paymentStorage?.currentAppUserId == expectedAppUserId else {
            Log.customer.debug("Discarding stale customer info — expected \(expectedAppUserId), current \(paymentStorage?.currentAppUserId ?? "nil")")
            return
        }

        // Monotonic ordering guard: concurrent receipt POSTs (drainOnce posts up to
        // maxConcurrentPosts in parallel) can complete out of order, each dispatching a
        // detached @MainActor task that lands here. Without this guard the last task to run
        // wins, so an older snapshot can overwrite a newer one and cause entitlement flicker.
        // Reject an incoming snapshot that is strictly older than the currently published one
        // for the same identity. Gated on matching appUserId so identity transitions
        // (login/logout reset to `.empty`, which carries a nil appUserId and `.distantPast`)
        // and the very first real snapshot always apply. See `isSnapshot(_:olderThan:)` for
        // the ordering basis and its best-effort nature for receipt POSTs.
        if customerInfo.appUserId == info.appUserId,
           Self.isSnapshot(info, olderThan: customerInfo) {
            Log.customer.debug("Discarding out-of-order customer info — incoming snapshot older than current published snapshot")
            return
        }

        let previousActiveKeys = customerInfo.activeEntitlementKeys
        let activeEntitlementsChanged = previousActiveKeys != info.activeEntitlementKeys

        if activeEntitlementsChanged {
            self.paymentRemoteConfigs = nil
            if let remoteConfigManager {
                await remoteConfigManager.clearCache(appUserId: expectedAppUserId)
            }
            if let experimentManager {
                await experimentManager.clearCache(appUserId: expectedAppUserId)
            }

            guard paymentStorage?.currentAppUserId == expectedAppUserId else {
                Log.customer.debug("Discarding stale customer info after cache invalidation — expected \(expectedAppUserId), current \(paymentStorage?.currentAppUserId ?? "nil")")
                return
            }
        }

        self.customerInfo = info

        if activeEntitlementsChanged {
            Log.customer.debug("Customer entitlements changed — invalidated remote config and experiment caches")
        }
    }

    /// Returns `true` when `incoming` represents a strictly older snapshot than `current`.
    ///
    /// Picks a clock-consistent ordering basis so the monotonic guard in
    /// ``setCustomerInfoIfIdentityMatches(_:expectedAppUserId:)`` never compares a
    /// server-assigned timestamp against a locally-stamped one:
    /// - When **both** snapshots carry a parseable server `requestDate`, compare those
    ///   (authoritative across server responses — e.g. the customer endpoint).
    /// - Otherwise compare `snapshotDate`, which is always present and is stamped on the
    ///   same local clock when each response object is constructed. Receipt POST responses
    ///   carry no server `requestDate`, so this orders them by response *construction/arrival*
    ///   time. That is a best-effort heuristic (not a strict guarantee under network
    ///   reordering) but it closes the common out-of-order window that causes the entitlement
    ///   flicker this guard targets.
    static func isSnapshot(_ incoming: AppActorCustomerInfo, olderThan current: AppActorCustomerInfo) -> Bool {
        if let incomingRequest = incoming.requestDateParsed,
           let currentRequest = current.requestDateParsed {
            return incomingRequest < currentRequest
        }
        return incoming.snapshotDate < current.snapshotDate
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var customerManager: AppActorCustomerManager? {
        get { paymentContext.customerManager }
        set { paymentContext.customerManager = newValue }
    }
}
