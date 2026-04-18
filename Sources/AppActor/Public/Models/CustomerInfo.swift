import Foundation

/// Single source of truth for a user's entitlement and purchase state.
///
/// `AppActorCustomerInfo` is an immutable snapshot — every state change produces
/// a brand-new instance to avoid partial-update bugs.
///
/// Works in **both modes**:
/// - **Local mode:** `entitlements` populated from StoreKit 2; `subscriptions`,
///   `nonSubscriptions` are empty dicts; `consumableBalances` is populated;
///   payment-mode fields (`appUserId`, `requestDate`, etc.) are `nil`.
/// - **Payment mode:** All fields populated from server; `consumableBalances` is `nil`.
public struct AppActorCustomerInfo: Sendable, Codable, Equatable {

    // MARK: - Universal Fields

    /// All entitlements keyed by their identifier.
    public let entitlements: [String: AppActorEntitlementInfo]

    /// All subscriptions keyed by an opaque subscription key.
    /// iOS keys are typically `ios:{productId}` while Android may use compound keys.
    public let subscriptions: [String: AppActorSubscriptionInfo]

    /// Non-subscription purchases keyed by backend-defined grouping keys.
    public let nonSubscriptions: [String: [AppActorNonSubscription]]

    /// Consumable balances keyed by product ID. `nil` in payment mode.
    public let consumableBalances: [String: Int]?

    /// Token balance reported by the payment backend. `nil` in local mode and
    /// when token support is disabled on the server.
    public let tokenBalance: AppActorTokenBalance?

    /// When this snapshot was generated.
    public let snapshotDate: Date

    // MARK: - Payment-mode Fields (nil in local mode)

    /// The server-assigned user ID. `nil` in local mode.
    public let appUserId: String?

    /// The server request ID for this snapshot. `nil` in local mode.
    public let requestId: String?

    /// The server request date string. `nil` in local mode.
    public let requestDate: String?

    /// When the user was first seen by the server. `nil` in local mode.
    public let firstSeen: String?

    /// When the user was last seen by the server. `nil` in local mode.
    public let lastSeen: String?

    /// The management URL for subscription management. `nil` in local mode.
    public let managementUrl: String?

    /// `true` when entitlements were derived locally from StoreKit transactions
    /// rather than confirmed by the server. The next `getCustomerInfo()` call
    /// will replace this with server-authoritative data.
    public let isComputedOffline: Bool

    /// How this snapshot's data was verified.
    /// - `.verified`: server response signature passed Ed25519 verification.
    /// - `.verifiedOnDevice`: entitlements derived from StoreKit 2 verified transactions.
    /// - `.notRequested`: verification was not performed (signing disabled or transitional).
    /// - `.failed`: verification was attempted but failed.
    public let verification: AppActorVerificationResult

    /// Mapping of product IDs to entitlement keys they grant.
    /// Populated from offerings cache, NOT from the customer endpoint.
    /// Remains `nil` when constructed from server customer responses.
    public let productEntitlements: [String: [String]]?

    // MARK: - Computed Helpers

    /// All currently active entitlements.
    public var activeEntitlements: [String: AppActorEntitlementInfo] {
        entitlements.filter { $0.value.isActive }
    }

    /// Set of active entitlement keys for quick lookups.
    public var activeEntitlementKeys: Set<String> {
        Set(activeEntitlements.keys)
    }

    /// Returns `true` if the given entitlement key is currently active.
    public func hasActiveEntitlement(_ key: String) -> Bool {
        entitlements[key]?.isActive == true
    }

    /// Parsed `requestDate` as `Date`, or `nil` if missing/unparseable.
    public var requestDateParsed: Date? { requestDate.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `firstSeen` as `Date`, or `nil` if missing/unparseable.
    public var firstSeenDate: Date? { firstSeen.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Parsed `lastSeen` as `Date`, or `nil` if missing/unparseable.
    public var lastSeenDate: Date? { lastSeen.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    /// Returns a copy with the given verification result.
    func withVerification(_ result: AppActorVerificationResult) -> AppActorCustomerInfo {
        AppActorCustomerInfo(
            entitlements: entitlements, subscriptions: subscriptions,
            nonSubscriptions: nonSubscriptions, consumableBalances: consumableBalances,
            tokenBalance: tokenBalance, snapshotDate: snapshotDate,
            appUserId: appUserId, requestId: requestId, requestDate: requestDate,
            firstSeen: firstSeen, lastSeen: lastSeen, managementUrl: managementUrl,
            isComputedOffline: isComputedOffline, verification: result,
            productEntitlements: productEntitlements
        )
    }

    // MARK: - Empty

    /// An empty `AppActorCustomerInfo` with no active purchases.
    /// Uses `Date.distantPast` as sentinel so all `.empty` instances are `Equatable`.
    public static let empty = AppActorCustomerInfo(
        entitlements: [:],
        subscriptions: [:],
        nonSubscriptions: [:],
        consumableBalances: nil,
        tokenBalance: nil,
        snapshotDate: .distantPast,
        appUserId: nil,
        requestId: nil,
        requestDate: nil,
        firstSeen: nil,
        lastSeen: nil,
        managementUrl: nil,
        productEntitlements: nil
    )

    // MARK: - Initializer

    public init(
        entitlements: [String: AppActorEntitlementInfo] = [:],
        subscriptions: [String: AppActorSubscriptionInfo] = [:],
        nonSubscriptions: [String: [AppActorNonSubscription]] = [:],
        consumableBalances: [String: Int]? = nil,
        tokenBalance: AppActorTokenBalance? = nil,
        snapshotDate: Date = Date(),
        appUserId: String? = nil,
        requestId: String? = nil,
        requestDate: String? = nil,
        firstSeen: String? = nil,
        lastSeen: String? = nil,
        managementUrl: String? = nil,
        isComputedOffline: Bool = false,
        verification: AppActorVerificationResult = .notRequested,
        productEntitlements: [String: [String]]? = nil
    ) {
        self.entitlements = entitlements
        self.subscriptions = subscriptions
        self.nonSubscriptions = nonSubscriptions
        self.consumableBalances = consumableBalances
        self.tokenBalance = tokenBalance
        self.snapshotDate = snapshotDate
        self.appUserId = appUserId
        self.requestId = requestId
        self.requestDate = requestDate
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.managementUrl = managementUrl
        self.isComputedOffline = isComputedOffline
        self.verification = verification
        self.productEntitlements = productEntitlements
    }

    // MARK: - Defensive Decodable

    private enum CodingKeys: String, CodingKey {
        case entitlements, subscriptions, nonSubscriptions
        case consumableBalances, tokenBalance, snapshotDate
        case appUserId, requestId
        case requestDate, firstSeen, lastSeen, managementUrl
        case isComputedOffline, verification, productEntitlements, activeEntitlementKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Entitlements: try dict first (canonical new shape), then array fallback (old payment-mode shape).
        if let dict = try? container.decodeIfPresent([String: AppActorEntitlementInfo].self, forKey: .entitlements) {
            self.entitlements = dict
        } else if let lossy = try? container.decodeIfPresent(LossyDecodableArray<_LegacyEntitlement>.self, forKey: .entitlements) {
            // Old array format: each item has an "id" field — build dict keyed by id.
            var dict: [String: AppActorEntitlementInfo] = [:]
            for item in lossy.elements {
                dict[item.id] = item.info
            }
            self.entitlements = dict
        } else {
            self.entitlements = [:]
        }

        // Subscriptions: try dict first, then array fallback.
        if let dict = try? container.decodeIfPresent([String: AppActorSubscriptionInfo].self, forKey: .subscriptions) {
            self.subscriptions = dict
        } else if let lossy = try? container.decodeIfPresent(LossyDecodableArray<AppActorSubscriptionInfo>.self, forKey: .subscriptions) {
            var dict: [String: AppActorSubscriptionInfo] = [:]
            for item in lossy.elements {
                dict[item.subscriptionKey] = item
            }
            self.subscriptions = dict
        } else {
            self.subscriptions = [:]
        }

        // NonSubscriptions: try dict first, then flat array fallback.
        if let dict = try? container.decodeIfPresent([String: [AppActorNonSubscription]].self, forKey: .nonSubscriptions) {
            self.nonSubscriptions = dict
        } else if let lossy = try? container.decodeIfPresent(LossyDecodableArray<AppActorNonSubscription>.self, forKey: .nonSubscriptions) {
            var dict: [String: [AppActorNonSubscription]] = [:]
            for item in lossy.elements {
                dict[item.productIdentifier, default: []].append(item)
            }
            self.nonSubscriptions = dict
        } else {
            self.nonSubscriptions = [:]
        }

        self.consumableBalances = try? container.decodeIfPresent([String: Int].self, forKey: .consumableBalances)
        self.tokenBalance = try? container.decodeIfPresent(AppActorTokenBalance.self, forKey: .tokenBalance)
        self.snapshotDate = (try? container.decodeIfPresent(Date.self, forKey: .snapshotDate)) ?? Date()
        self.appUserId = try? container.decodeIfPresent(String.self, forKey: .appUserId)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.requestDate = try? container.decodeIfPresent(String.self, forKey: .requestDate)
        self.firstSeen = try? container.decodeIfPresent(String.self, forKey: .firstSeen)
        self.lastSeen = try? container.decodeIfPresent(String.self, forKey: .lastSeen)
        self.managementUrl = try? container.decodeIfPresent(String.self, forKey: .managementUrl)
        self.isComputedOffline = false  // Transient in-memory state — always false when decoded
        self.verification = (try? container.decodeIfPresent(AppActorVerificationResult.self, forKey: .verification)) ?? .notRequested
        self.productEntitlements = try? container.decodeIfPresent([String: [String]].self, forKey: .productEntitlements)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entitlements, forKey: .entitlements)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(nonSubscriptions, forKey: .nonSubscriptions)
        try container.encodeIfPresent(consumableBalances, forKey: .consumableBalances)
        try container.encodeIfPresent(tokenBalance, forKey: .tokenBalance)
        try container.encode(snapshotDate, forKey: .snapshotDate)
        try container.encodeIfPresent(appUserId, forKey: .appUserId)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encodeIfPresent(requestDate, forKey: .requestDate)
        try container.encodeIfPresent(firstSeen, forKey: .firstSeen)
        try container.encodeIfPresent(lastSeen, forKey: .lastSeen)
        try container.encodeIfPresent(managementUrl, forKey: .managementUrl)
        try container.encode(isComputedOffline, forKey: .isComputedOffline)
        try container.encode(verification, forKey: .verification)
        try container.encodeIfPresent(productEntitlements, forKey: .productEntitlements)
        try container.encode(activeEntitlementKeys, forKey: .activeEntitlementKeys)
    }
}

// MARK: - Legacy Array Decode Helper

/// Helper for decoding old array-shaped entitlements (used in backward-compat decode path).
/// Old format: array of `{ id: "premium", isActive: true, ... }`.
private struct _LegacyEntitlement: Decodable {
    let id: String
    let info: AppActorEntitlementInfo

    init(from decoder: Decoder) throws {
        // Decode the id separately to use as key
        let container = try decoder.container(keyedBy: _LegacyEntitlementCodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        // Decode the full AppActorEntitlementInfo from the same payload
        self.info = try AppActorEntitlementInfo(from: decoder)
    }

    private enum _LegacyEntitlementCodingKeys: String, CodingKey {
        case id
    }
}

// MARK: - Lossy Array Decoding

/// Wrapper that decodes each element individually, skipping malformed items
/// instead of failing the entire array. Critical for payment data where one
/// bad entitlement/subscription must not erase all valid ones.
private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                // Skip the malformed element by advancing the container
                _ = try? container.decode(AppActorAnyCodableSkip.self)
                skipped += 1
            }
        }
        if skipped > 0 {
            Log.customer.warn("LossyDecodableArray<\(Element.self)>: skipped \(skipped) malformed item(s)")
        }
        elements = result
    }
}

/// Accepts any JSON value to advance the unkeyed container past a bad element.
private struct AppActorAnyCodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

// MARK: - Date Parser

/// Shared ISO8601 date parser for customer date strings.
enum AppActorCustomerDateParser {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string) ?? fallback.date(from: string)
    }
}

// MARK: - Fetch Result

/// Result type for conditional GET on customer endpoint.
enum AppActorCustomerFetchResult: Sendable {
    /// Fresh data from the server.
    case fresh(AppActorCustomerInfo, eTag: String?, requestId: String?, signatureVerified: Bool)
    /// Server returned 304 — cached data is still valid.
    case notModified(eTag: String?, requestId: String?)
}
