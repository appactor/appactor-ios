import Foundation

/// A package representing a single purchasable product within an offering.
///
/// Used in both local mode (configured via DSL) and payment mode (server-driven).
public struct AppActorPackage: Sendable, Identifiable, Hashable, Codable {

    // MARK: - Identity

    /// Canonical package identifier.
    ///
    /// For server-backed offerings this is the backend package UUID.
    /// For local or direct-purchase flows it remains the caller-provided identifier.
    public let id: String

    /// The role of this package (e.g. `.monthly`, `.annual`).
    public let packageType: AppActorPackageType

    /// For `.custom` type packages: the original server string used to identify this package.
    /// `nil` for all standard package types.
    public let customTypeIdentifier: String?

    // MARK: - Product

    /// The store through which this package is purchased.
    public let store: AppActorStore

    /// Logical product identifier shared across backend contracts.
    public let productId: String

    /// Store-specific product identifier used to resolve native store products.
    /// On iOS this typically matches App Store Connect's product identifier.
    public let storeProductId: String?

    /// Android base plan identifier when present. `nil` for iOS or one-time products.
    public let basePlanId: String?

    /// Android offer identifier when present. `nil` for iOS or products without offers.
    public let offerId: String?

    /// Localized price string (e.g. `"$9.99"`).
    public let localizedPriceString: String

    // MARK: - Payment-Only Fields

    /// The offering identifier this package belongs to. `nil` in local mode or direct product purchases.
    public let offeringId: String?

    /// Display name for this package.
    public let displayName: String?

    /// Optional metadata from the server.
    public let metadata: [String: String]?

    /// Number of tokens granted by this package, when token products are enabled.
    public let tokenAmount: Int?

    /// Sort position within the offering. `nil` in local mode.
    public let position: Int?

    /// The product's price as a `Decimal`. `nil` in local mode.
    public let price: Decimal?

    /// ISO 4217 currency code (e.g. `"USD"`). `nil` in local mode or on iOS 15.
    public let currencyCode: String?

    /// The product type string from the server (e.g. `"subscription"`, `"consumable"`).
    public let productType: String?

    /// Localized display name of the product.
    public let productName: String?

    /// Localized product description.
    public let productDescription: String?

    /// The subscription group identifier from StoreKit. `nil` for non-subscription products or in local mode.
    public let subscriptionGroupId: String?

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case packageType
        case customTypeIdentifier
        case store
        case productId
        case storeProductId
        case basePlanId
        case offerId
        case localizedPriceString
        case offeringId
        case legacyServerId = "serverId"
        case displayName
        case metadata
        case tokenAmount
        case position
        case price
        case currencyCode
        case productType
        case productName
        case productDescription
        case subscriptionGroupId
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decode(String.self, forKey: .id)
        packageType = try container.decode(AppActorPackageType.self, forKey: .packageType)
        customTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .customTypeIdentifier)
        store = (try? container.decodeIfPresent(AppActorStore.self, forKey: .store)) ?? .appStore
        productId = try container.decode(String.self, forKey: .productId)
        storeProductId = try container.decodeIfPresent(String.self, forKey: .storeProductId)
        basePlanId = try container.decodeIfPresent(String.self, forKey: .basePlanId)
        offerId = try container.decodeIfPresent(String.self, forKey: .offerId)
        localizedPriceString = try container.decode(String.self, forKey: .localizedPriceString)
        offeringId = try container.decodeIfPresent(String.self, forKey: .offeringId)
        let legacyServerId = try container.decodeIfPresent(String.self, forKey: .legacyServerId)
        if offeringId != nil,
           UUID(uuidString: decodedId) == nil,
           let legacyServerId,
           !legacyServerId.isEmpty {
            id = legacyServerId
        } else {
            id = decodedId
        }
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        tokenAmount = try container.decodeIfPresent(Int.self, forKey: .tokenAmount)
        position = try container.decodeIfPresent(Int.self, forKey: .position)
        price = try container.decodeIfPresent(Decimal.self, forKey: .price)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode)
        productType = try container.decodeIfPresent(String.self, forKey: .productType)
        productName = try container.decodeIfPresent(String.self, forKey: .productName)
        productDescription = try container.decodeIfPresent(String.self, forKey: .productDescription)
        subscriptionGroupId = try container.decodeIfPresent(String.self, forKey: .subscriptionGroupId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(packageType, forKey: .packageType)
        try container.encodeIfPresent(customTypeIdentifier, forKey: .customTypeIdentifier)
        try container.encode(store, forKey: .store)
        try container.encode(productId, forKey: .productId)
        try container.encodeIfPresent(storeProductId, forKey: .storeProductId)
        try container.encodeIfPresent(basePlanId, forKey: .basePlanId)
        try container.encodeIfPresent(offerId, forKey: .offerId)
        try container.encode(localizedPriceString, forKey: .localizedPriceString)
        try container.encodeIfPresent(offeringId, forKey: .offeringId)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(tokenAmount, forKey: .tokenAmount)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(price, forKey: .price)
        try container.encodeIfPresent(currencyCode, forKey: .currencyCode)
        try container.encodeIfPresent(productType, forKey: .productType)
        try container.encodeIfPresent(productName, forKey: .productName)
        try container.encodeIfPresent(productDescription, forKey: .productDescription)
        try container.encodeIfPresent(subscriptionGroupId, forKey: .subscriptionGroupId)
    }

    // MARK: - Hashable / Equatable

    public static func == (lhs: AppActorPackage, rhs: AppActorPackage) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Internal Init (used by SDK adapters only)

    init(
        id: String,
        packageType: AppActorPackageType,
        customTypeIdentifier: String?,
        store: AppActorStore = .appStore,
        productId: String,
        storeProductId: String? = nil,
        basePlanId: String? = nil,
        offerId: String? = nil,
        localizedPriceString: String,
        offeringId: String? = nil,
        displayName: String?,
        metadata: [String: String]?,
        tokenAmount: Int? = nil,
        position: Int?,
        price: Decimal?,
        currencyCode: String?,
        productType: String?,
        productName: String?,
        productDescription: String?,
        subscriptionGroupId: String? = nil
    ) {
        self.id = id
        self.packageType = packageType
        self.customTypeIdentifier = customTypeIdentifier
        self.store = store
        self.productId = productId
        self.storeProductId = storeProductId
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.localizedPriceString = localizedPriceString
        self.offeringId = offeringId
        self.displayName = displayName
        self.metadata = metadata
        self.tokenAmount = tokenAmount
        self.position = position
        self.price = price
        self.currencyCode = currencyCode
        self.productType = productType
        self.productName = productName
        self.productDescription = productDescription
        self.subscriptionGroupId = subscriptionGroupId
    }

    init(
        id: String,
        packageType: AppActorPackageType,
        customTypeIdentifier: String?,
        productId: String,
        localizedPriceString: String,
        product: Any? = nil,
        displayName: String?,
        metadata: [String: String]?,
        tokenAmount: Int? = nil,
        position: Int?,
        price: Decimal?,
        currencyCode: String?,
        productType: String?,
        productName: String?,
        productDescription: String?,
        subscriptionPeriod: Any? = nil,
        introductoryOffer: Any? = nil,
        storeProduct: Any? = nil
    ) {
        _ = product
        _ = subscriptionPeriod
        _ = introductoryOffer
        _ = storeProduct
        self.init(
            id: id,
            packageType: packageType,
            customTypeIdentifier: customTypeIdentifier,
            store: .appStore,
            productId: productId,
            storeProductId: productId,
            localizedPriceString: localizedPriceString,
            displayName: displayName,
            metadata: metadata,
            tokenAmount: tokenAmount,
            position: position,
            price: price,
            currencyCode: currencyCode,
            productType: productType,
            productName: productName,
            productDescription: productDescription
        )
    }
}
