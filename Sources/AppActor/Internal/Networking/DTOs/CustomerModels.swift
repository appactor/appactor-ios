import Foundation

// MARK: - Internal DTOs (matching backend JSON shape)

/// Response envelope for `GET /v1/customers/:app_user_id`.
/// Supports both the legacy flat payload and the newer `{ data: { ... } }` envelope.
struct AppActorCustomerResponseDTO: Decodable, Sendable {
    let requestDate: String?
    let requestDateMs: Int64?
    let customer: AppActorCustomerDTO
    let requestId: String?

    private enum CodingKeys: String, CodingKey {
        case requestDate, requestDateMs, customer, requestId, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.requestDate = try? container.decodeIfPresent(String.self, forKey: .requestDate)
        self.requestDateMs = try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)

        if let legacyCustomer = try? container.decode(AppActorCustomerDTO.self, forKey: .customer) {
            self.customer = legacyCustomer
            return
        }

        if let dataCustomer = try? container.decode(AppActorCustomerDTO.self, forKey: .data) {
            self.customer = dataCustomer
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.customer,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected either 'customer' or 'data' customer payload"
            )
        )
    }

    init(requestDate: String? = nil, requestDateMs: Int64? = nil, customer: AppActorCustomerDTO, requestId: String? = nil) {
        self.requestDate = requestDate
        self.requestDateMs = requestDateMs
        self.customer = customer
        self.requestId = requestId
    }
}

/// Customer data inside the response.
///
/// Backend returns `entitlements` and `subscriptions` as **dictionaries** keyed by ID,
/// not arrays. Example: `"entitlements": { "premium": { ... } }`.
/// For a user with no entitlements/subscriptions, backend returns `{}`.
struct AppActorCustomerDTO: Codable, Sendable {
    let entitlements: [String: AppActorEntitlementDTO]?
    let subscriptions: [String: AppActorSubscriptionDTO]?
    let nonSubscriptions: [String: [AppActorNonSubscriptionDTO]]?
    let managementUrl: String?
    let tokenBalance: AppActorTokenBalanceDTO?
    let firstSeen: String?
    let lastSeen: String?

    private enum CodingKeys: String, CodingKey {
        case entitlements, subscriptions, nonSubscriptions
        case managementUrl, tokenBalance, firstSeen, lastSeen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entitlements = try? container.decodeIfPresent([String: AppActorEntitlementDTO].self, forKey: .entitlements)
        self.subscriptions = try? container.decodeIfPresent([String: AppActorSubscriptionDTO].self, forKey: .subscriptions)
        // Defensive: if nonSubscriptions shape drifts, fall back to nil rather than failing the entire response
        self.nonSubscriptions = try? container.decodeIfPresent([String: [AppActorNonSubscriptionDTO]].self, forKey: .nonSubscriptions)
        self.managementUrl = try? container.decodeIfPresent(String.self, forKey: .managementUrl)
        self.tokenBalance = try? container.decodeIfPresent(AppActorTokenBalanceDTO.self, forKey: .tokenBalance)
        self.firstSeen = try? container.decodeIfPresent(String.self, forKey: .firstSeen)
        self.lastSeen = try? container.decodeIfPresent(String.self, forKey: .lastSeen)
    }

    init(
        entitlements: [String: AppActorEntitlementDTO]? = nil,
        subscriptions: [String: AppActorSubscriptionDTO]? = nil,
        nonSubscriptions: [String: [AppActorNonSubscriptionDTO]]? = nil,
        managementUrl: String? = nil,
        tokenBalance: AppActorTokenBalanceDTO? = nil,
        firstSeen: String? = nil,
        lastSeen: String? = nil
    ) {
        self.entitlements = entitlements
        self.subscriptions = subscriptions
        self.nonSubscriptions = nonSubscriptions
        self.managementUrl = managementUrl
        self.tokenBalance = tokenBalance
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

struct AppActorTokenBalanceDTO: Codable, Sendable {
    let renewable: Int
    let nonRenewable: Int
    let total: Int
}

struct AppActorEntitlementDTO: Codable, Sendable {
    let isActive: Bool?
    let productId: String?
    let basePlanId: String?
    let offerId: String?
    let expiresAt: String?
    let purchaseDate: String?
    let status: String?
    let store: String?
    let grantedBy: String?
    let ownershipType: String?
    let periodType: String?
    let isSandbox: Bool?
    let gracePeriodExpiresAt: String?
    let billingIssueDetectedAt: String?
    let unsubscribeDetectedAt: String?
    let cancellationReason: String?
    let renewedAt: String?
    let startsAt: String?
    let activePromotionalOfferType: String?
    let activePromotionalOfferId: String?

    init(
        isActive: Bool? = nil,
        productId: String? = nil,
        basePlanId: String? = nil,
        offerId: String? = nil,
        expiresAt: String? = nil,
        purchaseDate: String? = nil,
        status: String? = nil,
        store: String? = nil,
        grantedBy: String? = nil,
        ownershipType: String? = nil,
        periodType: String? = nil,
        isSandbox: Bool? = nil,
        gracePeriodExpiresAt: String? = nil,
        billingIssueDetectedAt: String? = nil,
        unsubscribeDetectedAt: String? = nil,
        cancellationReason: String? = nil,
        renewedAt: String? = nil,
        startsAt: String? = nil,
        activePromotionalOfferType: String? = nil,
        activePromotionalOfferId: String? = nil
    ) {
        self.isActive = isActive
        self.productId = productId
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.expiresAt = expiresAt
        self.purchaseDate = purchaseDate
        self.status = status
        self.store = store
        self.grantedBy = grantedBy
        self.ownershipType = ownershipType
        self.periodType = periodType
        self.isSandbox = isSandbox
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.billingIssueDetectedAt = billingIssueDetectedAt
        self.unsubscribeDetectedAt = unsubscribeDetectedAt
        self.cancellationReason = cancellationReason
        self.renewedAt = renewedAt
        self.startsAt = startsAt
        self.activePromotionalOfferType = activePromotionalOfferType
        self.activePromotionalOfferId = activePromotionalOfferId
    }
}

struct AppActorSubscriptionDTO: Codable, Sendable {
    let productId: String?
    let basePlanId: String?
    let offerId: String?
    let isActive: Bool?
    let expiresAt: String?
    let purchaseDate: String?
    let startsAt: String?
    let periodType: String?
    let store: String?
    let status: String?
    let autoRenew: Bool?
    let isSandbox: Bool?
    let gracePeriodExpiresAt: String?
    let unsubscribeDetectedAt: String?
    let cancellationReason: String?
    let renewedAt: String?
    let originalTransactionId: String?
    let latestTransactionId: String?
    let activePromotionalOfferType: String?
    let activePromotionalOfferId: String?

    init(
        productId: String? = nil,
        basePlanId: String? = nil,
        offerId: String? = nil,
        isActive: Bool? = nil,
        expiresAt: String? = nil,
        purchaseDate: String? = nil,
        startsAt: String? = nil,
        periodType: String? = nil,
        store: String? = nil,
        status: String? = nil,
        autoRenew: Bool? = nil,
        isSandbox: Bool? = nil,
        gracePeriodExpiresAt: String? = nil,
        unsubscribeDetectedAt: String? = nil,
        cancellationReason: String? = nil,
        renewedAt: String? = nil,
        originalTransactionId: String? = nil,
        latestTransactionId: String? = nil,
        activePromotionalOfferType: String? = nil,
        activePromotionalOfferId: String? = nil
    ) {
        self.productId = productId
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.isActive = isActive
        self.expiresAt = expiresAt
        self.purchaseDate = purchaseDate
        self.startsAt = startsAt
        self.periodType = periodType
        self.store = store
        self.status = status
        self.autoRenew = autoRenew
        self.isSandbox = isSandbox
        self.gracePeriodExpiresAt = gracePeriodExpiresAt
        self.unsubscribeDetectedAt = unsubscribeDetectedAt
        self.cancellationReason = cancellationReason
        self.renewedAt = renewedAt
        self.originalTransactionId = originalTransactionId
        self.latestTransactionId = latestTransactionId
        self.activePromotionalOfferType = activePromotionalOfferType
        self.activePromotionalOfferId = activePromotionalOfferId
    }
}

/// DTO for non-subscription purchases within customer response.
struct AppActorNonSubscriptionDTO: Codable, Sendable {
    let productId: String?
    let basePlanId: String?
    let offerId: String?
    let purchaseDate: String?
    let store: String?
    let isSandbox: Bool?
    let isConsumable: Bool?
    let isRefund: Bool?
    let storeTransactionIdentifier: String?

    init(
        productId: String? = nil,
        basePlanId: String? = nil,
        offerId: String? = nil,
        purchaseDate: String? = nil,
        store: String? = nil,
        isSandbox: Bool? = nil,
        isConsumable: Bool? = nil,
        isRefund: Bool? = nil,
        storeTransactionIdentifier: String? = nil
    ) {
        self.productId = productId
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.purchaseDate = purchaseDate
        self.store = store
        self.isSandbox = isSandbox
        self.isConsumable = isConsumable
        self.isRefund = isRefund
        self.storeTransactionIdentifier = storeTransactionIdentifier
    }
}

// MARK: - DTO → Public Model Conversion

extension AppActorCustomerInfo {
    /// Creates a unified `AppActorCustomerInfo` from internal DTOs.
    ///
    /// The `appUserId` comes from the request URL (it's not in the customer response body).
    init(dto: AppActorCustomerDTO, appUserId: String, requestDate: String?,
         requestId: String? = nil) {
        let entitlements = (dto.entitlements ?? [:]).reduce(into: [String: AppActorEntitlementInfo]()) { result, pair in
            result[pair.key] = AppActorEntitlementInfo(id: pair.key, dto: pair.value)
        }

        let subscriptions = (dto.subscriptions ?? [:]).reduce(into: [String: AppActorSubscriptionInfo]()) { result, pair in
            result[pair.key] = AppActorSubscriptionInfo(
                subscriptionKey: pair.key,
                productIdentifier: pair.value.productId ?? pair.key,
                dto: pair.value
            )
        }

        let nonSubscriptions = (dto.nonSubscriptions ?? [:]).reduce(into: [String: [AppActorNonSubscription]]()) { result, pair in
            result[pair.key] = pair.value.map {
                AppActorNonSubscription(
                    productIdentifier: $0.productId ?? pair.key,
                    fallbackKey: pair.key,
                    dto: $0
                )
            }
        }

        self.init(
            entitlements: entitlements,
            subscriptions: subscriptions,
            nonSubscriptions: nonSubscriptions,
            consumableBalances: nil,
            tokenBalance: dto.tokenBalance.map(AppActorTokenBalance.init(dto:)),
            snapshotDate: Date(),
            appUserId: appUserId,
            requestId: requestId,
            requestDate: requestDate,
            firstSeen: dto.firstSeen,
            lastSeen: dto.lastSeen,
            managementUrl: dto.managementUrl
        )
    }
}

extension AppActorTokenBalance {
    init(dto: AppActorTokenBalanceDTO) {
        self.init(
            renewable: dto.renewable,
            nonRenewable: dto.nonRenewable,
            total: dto.total
        )
    }
}

// MARK: - Sub-type DTO Initializers

extension AppActorEntitlementInfo {
    /// Creates an `AppActorEntitlementInfo` from a server DTO.
    init(id: String, dto: AppActorEntitlementDTO) {
        self.init(
            id: id,
            isActive: dto.isActive ?? false,
            productID: dto.productId,
            originalPurchaseDate: dto.purchaseDate.flatMap { AppActorCustomerDateParser.date(from: $0) },
            expirationDate: dto.expiresAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            ownershipType: dto.ownershipType.flatMap { AppActorOwnershipType(rawValue: $0) } ?? .unknown,
            periodType: dto.periodType.flatMap { AppActorPeriodType(rawValue: $0) } ?? .unknown,
            willRenew: dto.unsubscribeDetectedAt == nil && (dto.isActive ?? false),
            subscriptionStatus: nil, // server uses status string, not enum
            store: dto.store.flatMap { AppActorStore(rawValue: $0) },
            basePlanId: dto.basePlanId,
            offerId: dto.offerId,
            isSandbox: dto.isSandbox,
            cancellationReason: dto.cancellationReason.flatMap { AppActorCancellationReason(rawValue: $0) },
            gracePeriodExpiresAt: dto.gracePeriodExpiresAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            billingIssueDetectedAt: dto.billingIssueDetectedAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            unsubscribeDetectedAt: dto.unsubscribeDetectedAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            renewedAt: dto.renewedAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            startsAt: dto.startsAt.flatMap { AppActorCustomerDateParser.date(from: $0) },
            grantedBy: dto.grantedBy,
            activePromotionalOfferType: dto.activePromotionalOfferType,
            activePromotionalOfferId: dto.activePromotionalOfferId
        )
    }
}

extension AppActorSubscriptionInfo {
    /// Creates an `AppActorSubscriptionInfo` from a server DTO.
    init(productIdentifier: String, dto: AppActorSubscriptionDTO) {
        self.init(subscriptionKey: productIdentifier, productIdentifier: productIdentifier, dto: dto)
    }

    init(subscriptionKey: String, productIdentifier: String, dto: AppActorSubscriptionDTO) {
        self.init(
            subscriptionKey: subscriptionKey,
            productIdentifier: productIdentifier,
            basePlanId: dto.basePlanId,
            offerId: dto.offerId,
            isActive: dto.isActive ?? false,
            expiresDate: dto.expiresAt,
            purchaseDate: dto.purchaseDate,
            startsAt: dto.startsAt,
            periodType: dto.periodType.flatMap { AppActorPeriodType(rawValue: $0) },
            store: dto.store.flatMap { AppActorStore(rawValue: $0) },
            status: dto.status,
            autoRenew: dto.autoRenew,
            isSandbox: dto.isSandbox,
            gracePeriodExpiresAt: dto.gracePeriodExpiresAt,
            unsubscribeDetectedAt: dto.unsubscribeDetectedAt,
            cancellationReason: dto.cancellationReason.flatMap { AppActorCancellationReason(rawValue: $0) },
            renewedAt: dto.renewedAt,
            originalTransactionId: dto.originalTransactionId,
            latestTransactionId: dto.latestTransactionId,
            activePromotionalOfferType: dto.activePromotionalOfferType,
            activePromotionalOfferId: dto.activePromotionalOfferId
        )
    }
}

extension AppActorNonSubscription {
    /// Creates an `AppActorNonSubscription` from a server DTO.
    init(productIdentifier: String, fallbackKey: String, dto: AppActorNonSubscriptionDTO) {
        _ = fallbackKey
        self.init(
            productIdentifier: productIdentifier,
            offerId: dto.offerId,
            purchaseDate: dto.purchaseDate,
            store: dto.store.flatMap { AppActorStore(rawValue: $0) },
            isSandbox: dto.isSandbox,
            isConsumable: dto.isConsumable,
            isRefund: dto.isRefund,
            storeTransactionIdentifier: dto.storeTransactionIdentifier
        )
    }
}
