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
            setCustomerInfoIfIdentityMatches(info, expectedAppUserId: appUserId)
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
                setCustomerInfoIfIdentityMatches(offlineInfo, expectedAppUserId: appUserId)
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
}

// MARK: - Identity-Safe Customer Info Assignment

extension AppActor {
    /// Sets `customerInfo` only if the current user still matches the expected identity.
    /// Discards stale results from async calls that completed after a login/logout.
    func setCustomerInfoIfIdentityMatches(_ info: AppActorCustomerInfo, expectedAppUserId: String) {
        guard paymentStorage?.currentAppUserId == expectedAppUserId else {
            Log.customer.debug("Discarding stale customer info — expected \(expectedAppUserId), current \(paymentStorage?.currentAppUserId ?? "nil")")
            return
        }
        self.customerInfo = info
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var customerManager: AppActorCustomerManager? {
        get { paymentContext.customerManager }
        set { paymentContext.customerManager = newValue }
    }
}
