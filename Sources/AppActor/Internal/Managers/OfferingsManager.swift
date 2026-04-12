import Foundation
import StoreKit

/// Core actor that manages the offerings pipeline:
/// network fetch → StoreKit product enrichment → filtering → caching.
///
/// Features:
/// - **Single-flight**: concurrent `getOfferings()` calls coalesce into one network request.
/// - **TTL + SWR**: in-memory cache with foreground (5 min) / background (24 hr) TTL. Stale cache returns immediately while a background refresh runs (stale-while-revalidate). Cold cache blocks until fresh data arrives.
/// - **Disk cache**: persists raw DTO via centralized ETagManager for cold-start; re-enriches on load.
actor AppActorOfferingsManager {

    private struct NetworkStagePayload {
        let dto: AppActorOfferingsResponseDTO?
        let cacheDate: Date?
        let verification: AppActorVerificationResult
    }

    // MARK: - Dependencies

    private let client: AppActorPaymentClientProtocol
    private let productFetcher: AppActorStoreKitProductFetcherProtocol
    private let etagManager: AppActorETagManager
    private let dateProvider: @Sendable () -> Date

    // MARK: - In-Memory State

    private var cachedOfferings: AppActorOfferings?
    private var cachedAt: Date?
    private var cachedLocales: [String] = []
    private var lastRequestId: String?
    private var inFlightTask: Task<AppActorOfferings, Error>?
    private var networkStageTask: Task<NetworkStagePayload, Error>?
    private var enrichmentTask: Task<AppActorOfferings, Error>?
    private var revalidationTask: Task<Void, Never>?
    private var isBackground: Bool = false
    /// Generation counter incremented on `clearCache()` to prevent stale task writes.
    private var cacheGeneration: UInt64 = 0
    /// Bundled fallback DTO for first-launch offline scenarios.
    private var fallbackDTO: AppActorOfferingsResponseDTO?

    // MARK: - TTL Constants

    private static let foregroundTTL: TimeInterval = 5 * 60      // 5 minutes
    private static let backgroundTTL: TimeInterval = 24 * 60 * 60 // 24 hours

    // MARK: - Init

    init(
        client: AppActorPaymentClientProtocol,
        productFetcher: AppActorStoreKitProductFetcherProtocol = AppActorDefaultStoreKitProductFetcher(),
        etagManager: AppActorETagManager,
        dateProvider: @escaping @Sendable () -> Date = { Date() },
        fallbackDTO: AppActorOfferingsResponseDTO? = nil
    ) {
        self.client = client
        self.productFetcher = productFetcher
        self.etagManager = etagManager
        self.dateProvider = dateProvider
        self.fallbackDTO = fallbackDTO
    }

    /// Sets a bundled fallback DTO for first-launch offline scenarios.
    func setFallbackOfferings(dto: AppActorOfferingsResponseDTO) {
        self.fallbackDTO = dto
    }

    // MARK: - Cache Freshness

    /// Returns `true` when the in-memory cache exists, is within TTL, and locale hasn't changed.
    private func isCacheFresh() -> Bool {
        guard cachedOfferings != nil, let at = cachedAt else { return false }
        let ttl = isBackground ? Self.backgroundTTL : Self.foregroundTTL
        let age = dateProvider().timeIntervalSince(at)
        guard age < ttl else { return false }
        return cachedLocales == Locale.preferredLanguages
    }

    // MARK: - Public API

    /// Returns offerings, using cache when fresh or fetching from network.
    ///
    /// - If memory cache is fresh → returns immediately.
    /// - If stale cache exists → returns stale immediately, refreshes in background (SWR).
    /// - If no cache → awaits network + StoreKit enrichment.
    func getOfferings() async throws -> AppActorOfferings {
        // Fresh cache → return immediately
        if let cached = cachedOfferings, isCacheFresh() {
            return cached
        }

        // Stale cache exists → return it immediately, refresh in background
        if let cached = cachedOfferings {
            if revalidationTask == nil {
                revalidationTask = Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.fetchCoalesced()
                    await self.clearRevalidationTask()
                }
            }
            return cached
        }

        // No cache at all → must wait
        if let enrichmentTask = enrichmentTask {
            return try await enrichmentTask.value
        }

        return try await fetchCoalesced()
    }

    /// Returns the current in-memory cached offerings, or `nil`.
    var cached: AppActorOfferings? { cachedOfferings }

    /// The last `request_id` from an offerings response.
    var requestId: String? { lastRequestId }

    /// Resolves a single StoreKit product through the manager's injected fetcher.
    func storeKitProduct(for identifier: String) async throws -> Product? {
        let products = try await productFetcher.fetchProducts(for: [identifier])
        return products[identifier]
    }

    /// Toggle background mode (longer TTL).
    func setBackground(_ bg: Bool) {
        isBackground = bg
    }

    /// Clears both in-memory and disk caches.
    /// Cancels any in-flight fetch to prevent actor-reentrancy stale writes.
    func clearCache() async {
        cacheGeneration &+= 1
        inFlightTask?.cancel()
        networkStageTask?.cancel()
        enrichmentTask?.cancel()
        revalidationTask?.cancel()
        inFlightTask = nil
        networkStageTask = nil
        enrichmentTask = nil
        revalidationTask = nil
        cachedOfferings = nil
        cachedAt = nil
        cachedLocales = []
        await etagManager.clear(.offerings)
    }

    /// Bootstrap fast path: wait for the offerings API response so product-entitlement
    /// mapping is cached for offline fallback, then continue StoreKit enrichment in
    /// the background without blocking configure().
    func prefetchForBootstrap() async {
        if let cached = cachedOfferings, isCacheFresh(), !cached.all.isEmpty {
            return
        }

        let gen = cacheGeneration
        do {
            let payload = try await fetchNetworkStageCoalesced(generation: gen)
            guard let dto = payload.dto, let cacheDate = payload.cacheDate else { return }
            startEnrichmentTaskIfNeeded(dto: dto, cacheDate: cacheDate, generation: gen, verification: payload.verification)
        } catch is CancellationError {
            return
        } catch let error as AppActorError where error.kind == .network || (error.kind == .server && (error.httpStatus ?? 0) >= 500) {
            if let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings) {
                startEnrichmentTaskIfNeeded(dto: entry.value, cacheDate: entry.cachedAt, generation: gen, verification: entry.verification)
            } else if let fallback = fallbackDTO {
                Log.offerings.debug("Bootstrap prefetch — using bundled fallback offerings")
                startEnrichmentTaskIfNeeded(dto: fallback, cacheDate: dateProvider(), generation: gen)
            }
        } catch {
            Log.offerings.debug("Bootstrap offerings prefetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Single-Flight Coalescing

    private func fetchCoalesced() async throws -> AppActorOfferings {
        if let existing = inFlightTask {
            return try await existing.value
        }

        let gen = cacheGeneration
        let task = Task<AppActorOfferings, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                let result = try await self.executePipeline(generation: gen)
                await self.setInFlightComplete(generation: gen)
                return result
            } catch let error as AppActorError where error.kind == .network || (error.kind == .server && (error.httpStatus ?? 0) >= 500) {
                // Network / 5xx fallback chain: disk cache → bundled fallback → throw
                // Keep inFlightTask alive during recovery so concurrent callers coalesce
                if let cached = await self.loadFromDiskCache(generation: gen) {
                    await self.setInFlightComplete(generation: gen)
                    Log.offerings.debug("Network/5xx error — returning disk-cached offerings")
                    return cached
                }
                if let fallback = await self.loadFromFallbackDTO(generation: gen) {
                    await self.setInFlightComplete(generation: gen)
                    Log.offerings.debug("Network/5xx error — returning bundled fallback offerings")
                    return fallback
                }
                await self.setInFlightComplete(generation: gen)
                throw error
            } catch {
                await self.setInFlightComplete(generation: gen)
                throw error
            }
        }

        inFlightTask = task
        return try await task.value
    }

    private func clearRevalidationTask() {
        revalidationTask = nil
    }

    /// Only clears inFlightTask if the generation matches (clearCache hasn't been called).
    private func setInFlightComplete(generation: UInt64) {
        guard cacheGeneration == generation else { return }
        inFlightTask = nil
    }

    private func clearLastRequestId(generation: UInt64) {
        guard cacheGeneration == generation else { return }
        lastRequestId = nil
    }

    // MARK: - Pipeline

    private func executePipeline(generation: UInt64) async throws -> AppActorOfferings {
        let payload: NetworkStagePayload
        do {
            payload = try await fetchNetworkStageCoalesced(generation: generation)
        } catch let error as AppActorError where error.code == "CACHE_INCONSISTENCY" {
            Log.offerings.debug("Cache inconsistency on 304, trying fallback chain")
            if let fallback = await fallbackOfferings(generation: generation) { return fallback }
            throw error
        }

        if let dto = payload.dto, let cacheDate = payload.cacheDate {
            return try await awaitEnrichment(dto: dto, cacheDate: cacheDate, generation: generation, verification: payload.verification)
        }

        if let fallback = await fallbackOfferings(generation: generation) {
            return fallback
        }

        throw AppActorError.serverError(
            httpStatus: 304,
            code: "CACHE_INCONSISTENCY",
            message: "Offerings API returned no fresh payload and no cache is available",
            details: nil,
            requestId: nil
        )
    }

    /// Returns the first available fallback: in-memory cache → disk cache → bundled fallback DTO.
    private func fallbackOfferings(generation: UInt64) async -> AppActorOfferings? {
        if let existing = cachedOfferings { return existing }
        if let disk = await loadFromDiskCache(generation: generation) { return disk }
        if let fallback = await loadFromFallbackDTO(generation: generation) { return fallback }
        return nil
    }

    private func fetchNetworkStageCoalesced(generation: UInt64) async throws -> NetworkStagePayload {
        if let existing = networkStageTask {
            return try await existing.value
        }

        let task = Task<NetworkStagePayload, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            do {
                let result = try await self.executeNetworkStage(generation: generation)
                await self.setNetworkStageComplete(generation: generation)
                return result
            } catch {
                await self.setNetworkStageComplete(generation: generation)
                throw error
            }
        }

        networkStageTask = task
        return try await task.value
    }

    private func setNetworkStageComplete(generation: UInt64) {
        guard cacheGeneration == generation else { return }
        networkStageTask = nil
    }

    private func executeNetworkStage(generation: UInt64) async throws -> NetworkStagePayload {
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        let lastETag = await etagManager.eTag(for: .offerings)
        let result = try await client.getOfferings(eTag: lastETag)
        let apiMs = Int((CFAbsoluteTimeGetCurrent() - pipelineStart) * 1000)

        switch result {
        case .fresh(let dto, let eTag, let requestId, let signatureVerified):
            Log.offerings.info("  ⏱ offerings/api: \(apiMs) ms (200 fresh)")
            let verification = AppActorVerificationResult.from(signatureVerified: signatureVerified)
            if cacheGeneration == generation {
                await etagManager.storeFresh(dto, for: .offerings, eTag: eTag, verified: signatureVerified)
                lastRequestId = requestId
            }
            return NetworkStagePayload(dto: dto, cacheDate: dateProvider(), verification: verification)

        case .notModified(let eTag, let requestId):
            Log.offerings.info("  ⏱ offerings/api: \(apiMs) ms (304 not modified)")
            if cacheGeneration == generation {
                lastRequestId = requestId
            }

            if cachedOfferings != nil {
                if cacheGeneration == generation {
                    _ = await etagManager.handleNotModified(
                        AppActorOfferingsResponseDTO.self, for: .offerings, rotatedETag: eTag
                    )
                    cachedAt = dateProvider()
                }
                Log.offerings.debug("Offerings not modified (304), using in-memory cache")
                Log.offerings.info("  ⏱ offerings/storekit: 0 ms (memory cache hit)")
                return NetworkStagePayload(dto: nil, cacheDate: nil, verification: cachedOfferings?.verification ?? .notRequested)
            }

            if cacheGeneration == generation, let result = await etagManager.handleNotModified(
                AppActorOfferingsResponseDTO.self, for: .offerings, rotatedETag: eTag
            ) {
                return NetworkStagePayload(dto: result.value, cacheDate: dateProvider(), verification: result.verification)
            }

            Log.offerings.debug("Cache miss on 304, refreshing offerings")
            let retry = try await client.getOfferings(eTag: nil)
            guard case .fresh(let dto, let retryETag, let retryReqId, let retryVerified) = retry else {
                throw AppActorError.serverError(
                    httpStatus: 304,
                    code: "CACHE_INCONSISTENCY",
                    message: "Server returned 304 but local offerings cache is unavailable",
                    details: nil,
                    requestId: requestId
                )
            }

            let retryVerification = AppActorVerificationResult.from(signatureVerified: retryVerified)
            if cacheGeneration == generation {
                await etagManager.storeFresh(dto, for: .offerings, eTag: retryETag, verified: retryVerified)
                lastRequestId = retryReqId
            }
            return NetworkStagePayload(dto: dto, cacheDate: dateProvider(), verification: retryVerification)
        }
    }

    private func awaitEnrichment(
        dto: AppActorOfferingsResponseDTO,
        cacheDate: Date,
        generation: UInt64,
        verification: AppActorVerificationResult = .notRequested
    ) async throws -> AppActorOfferings {
        startEnrichmentTaskIfNeeded(dto: dto, cacheDate: cacheDate, generation: generation, verification: verification)
        guard let task = enrichmentTask else {
            throw AppActorError.serverError(
                httpStatus: 500,
                code: "ENRICHMENT_TASK_MISSING",
                message: "Offerings enrichment task was not created",
                details: nil,
                requestId: nil
            )
        }
        return try await task.value
    }

    private func startEnrichmentTaskIfNeeded(
        dto: AppActorOfferingsResponseDTO,
        cacheDate: Date,
        generation: UInt64,
        verification: AppActorVerificationResult = .notRequested
    ) {
        guard enrichmentTask == nil else { return }

        let task = Task<AppActorOfferings, Error> { [weak self] in
            guard let self else { throw AppActorError.notConfigured }
            let storeKitStart = CFAbsoluteTimeGetCurrent()
            do {
                let offerings = try await self.enrich(dto: dto, verification: verification)
                let storeKitMs = Int((CFAbsoluteTimeGetCurrent() - storeKitStart) * 1000)
                Log.offerings.info("  ⏱ offerings/storekit: \(storeKitMs) ms (\(dto.allStoreProductIds.count) product(s))")

                await self.finishEnrichment(
                    result: .success(offerings),
                    cacheDate: cacheDate,
                    generation: generation
                )
                return offerings
            } catch {
                await self.finishEnrichment(
                    result: .failure(error),
                    cacheDate: cacheDate,
                    generation: generation
                )
                throw error
            }
        }

        enrichmentTask = task
    }

    private func finishEnrichment(
        result: Result<AppActorOfferings, Error>,
        cacheDate: Date,
        generation: UInt64
    ) {
        if cacheGeneration == generation {
            enrichmentTask = nil
        }

        if case .success(let offerings) = result, cacheGeneration == generation {
            cachedOfferings = offerings
            cachedAt = cacheDate
            cachedLocales = Locale.preferredLanguages
            Log.offerings.info("🏷️ Offerings loaded: \(offerings.all.count) offering(s)")
        }
    }

    // MARK: - Enrichment

    /// Extracts App Store product IDs, bulk-fetches from StoreKit, builds public models.
    /// Drops packages/offerings that have zero products after enrichment.
    private func enrich(dto: AppActorOfferingsResponseDTO, verification: AppActorVerificationResult = .notRequested) async throws -> AppActorOfferings {
        let allIds = dto.allStoreProductIds

        guard !allIds.isEmpty else {
            // Server returned offerings with no product IDs — valid empty config
            return AppActorOfferings(current: nil, all: [:], productEntitlements: dto.productEntitlements, verification: verification)
        }

        // Bulk fetch from StoreKit
        let productMap = try await productFetcher.fetchProducts(for: allIds)

        let missingIds = allIds.subtracting(Set(productMap.keys))
        if !missingIds.isEmpty {
            Log.offerings.warn("StoreKit products not found: \(missingIds.sorted().joined(separator: ", "))")
        }

        if productMap.isEmpty {
            Log.offerings.error("All StoreKit products missing — cannot build offerings. Missing IDs: \(allIds.sorted().joined(separator: ", "))")
            throw AppActorError.storeKitProductsMissing(requestedIds: allIds)
        }

        // Build offerings, filtering out missing products
        var allOfferings: [String: AppActorOffering] = [:]
        var currentOffering: AppActorOffering?

        for offeringDTO in dto.offerings {
            var enrichedPackages: [AppActorPackage] = []

            for packageDTO in offeringDTO.packages where packageDTO.isActive {
                let appStoreRefs = packageDTO.products.filter { $0.store == .appStore }
                guard let productRef = appStoreRefs.first(where: {
                    let lookupId = $0.storeProductId ?? $0.productId
                    return productMap[lookupId] != nil
                }) else {
                    let missingIds = appStoreRefs.map { $0.storeProductId ?? $0.productId }
                    Log.offerings.warn("Offering '\(offeringDTO.id)': skipping package '\(packageDTO.packageType)' — StoreKit product(s) not found: \(missingIds.joined(separator: ", "))")
                    continue
                }

                let lookupId = productRef.storeProductId ?? productRef.productId
                guard let skProduct = productMap[lookupId] else {
                    continue
                }

                let pkgType = AppActorPackageType(serverString: packageDTO.packageType)
                let customIdentifier: String? = (pkgType == .custom) ? packageDTO.packageType : nil
                let packageId = "\(offeringDTO.id)_\(packageDTO.packageType)"

                let currencyCode: String?
                if #available(iOS 16.0, macOS 13.0, *) {
                    currencyCode = skProduct.priceFormatStyle.currencyCode
                } else {
                    currencyCode = nil
                }

                let subscriptionGroupId = skProduct.subscription?.subscriptionGroupID

                enrichedPackages.append(AppActorPackage(
                    id: packageId,
                    packageType: pkgType,
                    customTypeIdentifier: customIdentifier,
                    store: productRef.store,
                    productId: productRef.productId,
                    storeProductId: productRef.storeProductId,
                    basePlanId: productRef.basePlanId,
                    offerId: productRef.offerId,
                    localizedPriceString: skProduct.displayPrice,
                    offeringId: offeringDTO.id,
                    serverId: packageDTO.id,
                    displayName: packageDTO.displayName,
                    metadata: packageDTO.metadata,
                    tokenAmount: packageDTO.tokenAmount,
                    position: packageDTO.position,
                    price: skProduct.price,
                    currencyCode: currencyCode,
                    productType: productRef.productType,
                    productName: productRef.displayName ?? skProduct.displayName,
                    productDescription: skProduct.description,
                    subscriptionGroupId: subscriptionGroupId
                ))
            }

            enrichedPackages.sort { ($0.position ?? 0) < ($1.position ?? 0) }

            guard !enrichedPackages.isEmpty else {
                let missingProductIds = offeringDTO.packages
                    .filter { $0.isActive }
                    .flatMap { package in
                        package.products
                            .filter { $0.store == .appStore }
                            .map { $0.storeProductId ?? $0.productId }
                    }
                Log.offerings.warn("Offering '\(offeringDTO.id)' dropped — all packages have missing StoreKit products: \(missingProductIds.joined(separator: ", "))")
                continue
            }

            let offering = AppActorOffering(
                id: offeringDTO.id,
                displayName: offeringDTO.displayName ?? offeringDTO.id,
                isCurrent: offeringDTO.isCurrent,
                lookupKey: offeringDTO.lookupKey,
                metadata: offeringDTO.metadata,
                packages: enrichedPackages
            )

            allOfferings[offering.id] = offering

            if offeringDTO.isCurrent {
                currentOffering = offering
            }
        }

        if currentOffering == nil, let serverCurrent = dto.currentOffering {
            currentOffering = allOfferings[serverCurrent.id]
        }

        return AppActorOfferings(current: currentOffering, all: allOfferings, productEntitlements: dto.productEntitlements, verification: verification)
    }

    // MARK: - Cold Start (Disk Cache)

    /// Attempts to load offerings from disk cache and enrich with StoreKit products.
    /// Returns `nil` if no cache or enrichment fails. Does not throw.
    func loadFromDiskCache(generation: UInt64? = nil) async -> AppActorOfferings? {
        guard let entry = await etagManager.cached(AppActorOfferingsResponseDTO.self, for: .offerings) else {
            return nil
        }
        return await enrichAndCache(dto: entry.value, cacheDate: entry.cachedAt, context: "disk cache", generation: generation, verification: entry.verification)
    }

    /// Attempts to load offerings from the bundled fallback DTO and enrich with StoreKit products.
    /// Returns `nil` if no fallback DTO is set or enrichment fails. Does not throw.
    ///
    /// Uses `distantPast` as `cacheDate` so the result is immediately stale —
    /// the next `offerings()` call will attempt a fresh network fetch rather than
    /// serving the bundled fallback for the full TTL window.
    private func loadFromFallbackDTO(generation: UInt64? = nil) async -> AppActorOfferings? {
        guard let dto = fallbackDTO else { return nil }
        return await enrichAndCache(dto: dto, cacheDate: .distantPast, context: "bundled fallback", generation: generation)
    }

    // MARK: - Enrichment Helpers

    /// Enriches a DTO with StoreKit products and caches the result.
    /// Returns `nil` if enrichment fails. Does not throw.
    /// When `generation` is provided, only writes in-memory state if generation still matches.
    private func enrichAndCache(
        dto: AppActorOfferingsResponseDTO,
        cacheDate: Date,
        context: String,
        generation: UInt64? = nil,
        verification: AppActorVerificationResult = .notRequested
    ) async -> AppActorOfferings? {
        do {
            let offerings = try await enrich(dto: dto, verification: verification)
            if generation == nil || cacheGeneration == generation {
                cachedOfferings = offerings
                cachedAt = cacheDate
                cachedLocales = Locale.preferredLanguages
            }
            Log.offerings.debug("\(context): \(offerings.all.count) offering(s)")
            return offerings
        } catch {
            Log.offerings.debug("Enrichment failed (\(context)): \(error.localizedDescription)")
            return nil
        }
    }
}
