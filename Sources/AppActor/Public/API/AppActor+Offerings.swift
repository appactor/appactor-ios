import Foundation

// MARK: - Payment Offerings Public API

extension AppActor {

    /// Returns server-driven offerings enriched with StoreKit products.
    ///
    /// Behaviour depends on ``AppActorOfferingsFetchPolicy``:
    /// - `.freshIfStale` → stale or missing cache waits for a fresh network fetch.
    /// - `.returnCachedThenRefresh` → suitable cached offerings return immediately and refresh in background.
    /// - `.cacheOnly` → returns only a locale-compatible cache, otherwise throws `OFFERINGS_CACHE_MISS`.
    ///
    /// Multiple concurrent calls are coalesced into a single network request.
    ///
    /// - Parameter fetchPolicy: Controls whether stale cache is returned or refreshed eagerly.
    /// - Returns: The resolved `AppActorOfferings` with StoreKit-enriched products.
    /// - Throws: `AppActorError` on network, decode, or StoreKit failures.
    public func offerings(
        fetchPolicy: AppActorOfferingsFetchPolicy = .freshIfStale
    ) async throws -> AppActorOfferings {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let manager = offeringsManager else {
            throw AppActorError.notConfigured
        }
        let result = try await manager.getOfferings(fetchPolicy: fetchPolicy)
        self.paymentOfferings = result
        if let rid = await manager.requestId {
            paymentStorage?.setLastRequestId(rid)
        }
        return result
    }

    /// Returns the most recently cached offerings without making a network call.
    /// Returns `nil` if offerings have not been fetched yet.
    public var cachedOfferings: AppActorOfferings? {
        paymentOfferings
    }

    /// Sets a bundled JSON file as fallback offerings for first-launch offline scenarios.
    ///
    /// When the network fetch fails and no disk cache exists, the SDK will use this
    /// fallback DTO to display offerings. The fallback still goes through StoreKit
    /// product enrichment, so only products available in the App Store will appear.
    ///
    /// Can be called before or after `configure()`.
    ///
    /// - Parameter fileURL: Local URL to a JSON file containing an offerings response DTO.
    public func setFallbackOfferings(from fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        try await setFallbackOfferings(jsonData: data)
    }

    /// Sets raw JSON data as fallback offerings for first-launch offline scenarios.
    ///
    /// - Parameter jsonData: JSON data containing an offerings response DTO.
    public func setFallbackOfferings(jsonData: Data) async throws {
        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: jsonData)
        paymentContext.fallbackOfferingsDTO = dto
        // If manager already exists (configure already called), push immediately
        if let manager = offeringsManager {
            await manager.setFallbackOfferings(dto: dto)
        }
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var offeringsManager: AppActorOfferingsManager? {
        get { paymentContext.offeringsManager }
        set { paymentContext.offeringsManager = newValue }
    }

    var paymentOfferings: AppActorOfferings? {
        get { paymentContext.offerings }
        set { paymentContext.offerings = newValue }
    }
}
