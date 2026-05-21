import Foundation

/// Top-level non-subscription purchase record returned in payment mode.
///
/// Replaces the old nested `AppActorCustomerInfo.NonSubscription`. Represents
/// a one-time purchase (consumable or non-consumable) from the server.
public struct AppActorNonSubscription: Sendable, Codable, Equatable {

    public let productIdentifier: String
    public let offerId: String?
    public let purchaseDate: String?
    public let store: AppActorStore?
    public let isSandbox: Bool?
    public let isConsumable: Bool?
    public let isRefund: Bool?
    public let storeTransactionIdentifier: String?

    // MARK: - Computed Date Helper

    /// Parsed `purchaseDate` as `Date`, or `nil` if missing/unparseable.
    public var purchased: Date? { purchaseDate.flatMap { AppActorCustomerDateParser.date(from: $0) } }

    // MARK: - Initializer

    public init(
        productIdentifier: String,
        offerId: String? = nil,
        purchaseDate: String? = nil,
        store: AppActorStore? = nil,
        isSandbox: Bool? = nil,
        isConsumable: Bool? = nil,
        isRefund: Bool? = nil,
        storeTransactionIdentifier: String? = nil
    ) {
        self.productIdentifier = productIdentifier
        self.offerId = offerId
        self.purchaseDate = purchaseDate
        self.store = store
        self.isSandbox = isSandbox
        self.isConsumable = isConsumable
        self.isRefund = isRefund
        self.storeTransactionIdentifier = storeTransactionIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case productIdentifier
        case productId
        case offerId
        case purchaseDate
        case store
        case isSandbox
        case isConsumable
        case isRefund
        case storeTransactionIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let productIdentifier = try container.decodeIfPresent(String.self, forKey: .productIdentifier)
            ?? container.decodeIfPresent(String.self, forKey: .productId)
            ?? ""

        self.init(
            productIdentifier: productIdentifier,
            offerId: try container.decodeIfPresent(String.self, forKey: .offerId),
            purchaseDate: try container.decodeIfPresent(String.self, forKey: .purchaseDate),
            store: try container.decodeIfPresent(AppActorStore.self, forKey: .store),
            isSandbox: try container.decodeIfPresent(Bool.self, forKey: .isSandbox),
            isConsumable: try container.decodeIfPresent(Bool.self, forKey: .isConsumable),
            isRefund: try container.decodeIfPresent(Bool.self, forKey: .isRefund),
            storeTransactionIdentifier: try container.decodeIfPresent(String.self, forKey: .storeTransactionIdentifier)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(productIdentifier, forKey: .productIdentifier)
        try container.encodeIfPresent(offerId, forKey: .offerId)
        try container.encodeIfPresent(purchaseDate, forKey: .purchaseDate)
        try container.encodeIfPresent(store, forKey: .store)
        try container.encodeIfPresent(isSandbox, forKey: .isSandbox)
        try container.encodeIfPresent(isConsumable, forKey: .isConsumable)
        try container.encodeIfPresent(isRefund, forKey: .isRefund)
        try container.encodeIfPresent(storeTransactionIdentifier, forKey: .storeTransactionIdentifier)
    }
}
