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
        let result: AppActorOfferings
        do {
            result = try await manager.getOfferings(fetchPolicy: fetchPolicy)
        } catch let error where !(error is AppActorError) && !(error is CancellationError) {
            // StoreKit's own error, from loading the products.
            throw AppActorError.fromProductLookupError(error)
        }
        self.paymentOfferings = result
        if let rid = await manager.requestId {
            paymentStorage?.setLastRequestId(rid)
        }
        return result
    }

    /// Fetches offerings (see ``offerings(fetchPolicy:)``) and returns the one with the given
    /// ``AppActorOffering/offeringKey``, or `nil` if the app has no such offering.
    ///
    /// ```swift
    /// if let onboarding = try await AppActor.shared.offering("onboarding") {
    ///     try await AppActor.shared.purchase(package: onboarding.annual!)
    /// }
    /// ```
    public func offering(
        _ offeringKey: String,
        fetchPolicy: AppActorOfferingsFetchPolicy = .freshIfStale
    ) async throws -> AppActorOffering? {
        try await offerings(fetchPolicy: fetchPolicy).offering(offeringKey)
    }

    /// Returns the most recently cached offerings without making a network call: the last
    /// ``offerings(fetchPolicy:)`` result, or those `configure()` loaded before any call.
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
    /// - Parameter fileURL: Local URL to a JSON file holding the offerings: a saved
    ///   `GET /v1/payment/offerings` body, or its `data` object.
    public func setFallbackOfferings(from fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)
        try await setFallbackOfferings(jsonData: data)
    }

    /// Sets raw JSON data as fallback offerings for first-launch offline scenarios.
    ///
    /// - Parameter jsonData: JSON holding the offerings: a saved `GET /v1/payment/offerings` body
    ///   (`{"data": {…}}`, the shape Android takes too), or its `data` object.
    /// - Throws: `AppActorError` with `.decoding` kind if the JSON holds no offerings.
    public func setFallbackOfferings(jsonData: Data) async throws {
        let dto: AppActorOfferingsResponseDTO
        do {
            dto = try JSONDecoder().decode(FallbackOfferingsFile.self, from: jsonData).dto
        } catch {
            throw AppActorError.decodingError(error, requestId: nil)
        }
        paymentContext.fallbackOfferingsDTO = dto
        // If manager already exists (configure already called), push immediately
        if let manager = offeringsManager {
            await manager.setFallbackOfferings(dto: dto)
        }
    }
}

/// A fallback offerings file: the endpoint's body, or the `data` object inside it.
struct FallbackOfferingsFile: Decodable {
    let dto: AppActorOfferingsResponseDTO

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dto = container.contains(.data)
            ? try container.decode(AppActorOfferingsResponseDTO.self, forKey: .data)
            : try AppActorOfferingsResponseDTO(from: decoder)
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
