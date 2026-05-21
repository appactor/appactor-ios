import Foundation

// MARK: - Offerings API Response

/// Top-level response from `GET /v1/payment/offerings`.
struct AppActorOfferingsResponseDTO: Codable, Sendable {
    let currentOffering: AppActorOfferingDTO?
    let offerings: [AppActorOfferingDTO]
    /// Maps backend-defined product entitlement keys to entitlement identifiers.
    /// Optional for backward compatibility with servers that don't send this field.
    var productEntitlements: [String: [String]]? = nil
}

/// A single offering with its packages.
struct AppActorOfferingDTO: Codable, Sendable {
    let id: String
    let lookupKey: String
    let displayName: String?
    let isCurrent: Bool
    let metadata: [String: String]?
    let packages: [AppActorPackageDTO]
}

/// A package within an offering, containing product references.
struct AppActorPackageDTO: Codable, Sendable {
    let id: String?
    let packageType: String
    let displayName: String?
    let position: Int
    let isActive: Bool
    let metadata: [String: String]?
    let tokenAmount: Int?
    let products: [AppActorProductRefDTO]

    init(
        id: String?,
        packageType: String,
        displayName: String?,
        position: Int,
        isActive: Bool,
        metadata: [String: String]?,
        tokenAmount: Int? = nil,
        products: [AppActorProductRefDTO]
    ) {
        self.id = id
        self.packageType = packageType
        self.displayName = displayName
        self.position = position
        self.isActive = isActive
        self.metadata = metadata
        self.tokenAmount = tokenAmount
        self.products = products
    }
}

/// A reference to a StoreKit product.
struct AppActorProductRefDTO: Codable, Sendable {
    let id: String?
    let store: AppActorStore
    let productId: String
    let storeProductId: String?
    let productType: String
    let basePlanId: String?
    let offerId: String?
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case store
        case productId
        case storeProductId
        case productType
        case basePlanId
        case offerId
        case displayName
    }

    init(
        id: String? = nil,
        store: AppActorStore = .appStore,
        productId: String,
        storeProductId: String? = nil,
        productType: String,
        basePlanId: String? = nil,
        offerId: String? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.store = store
        self.productId = productId
        self.storeProductId = storeProductId
        self.productType = productType
        self.basePlanId = basePlanId
        self.offerId = offerId
        self.displayName = displayName
    }

    init(
        id: String? = nil,
        storeProductId: String,
        productType: String,
        displayName: String? = nil
    ) {
        self.init(
            id: id,
            store: .appStore,
            productId: storeProductId,
            storeProductId: storeProductId,
            productType: productType,
            displayName: displayName
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        store = (try? container.decodeIfPresent(AppActorStore.self, forKey: .store)) ?? .appStore

        let legacyStoreProductId = try container.decodeIfPresent(String.self, forKey: .storeProductId)
        let decodedProductId = try container.decodeIfPresent(String.self, forKey: .productId)
        let resolvedProductId = decodedProductId ?? legacyStoreProductId

        guard let resolvedProductId else {
            throw DecodingError.keyNotFound(
                CodingKeys.productId,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected either 'productId' or legacy 'storeProductId'"
                )
            )
        }

        productId = resolvedProductId
        storeProductId = legacyStoreProductId ?? decodedProductId
        productType = try container.decode(String.self, forKey: .productType)
        basePlanId = try container.decodeIfPresent(String.self, forKey: .basePlanId)
        offerId = try container.decodeIfPresent(String.self, forKey: .offerId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

// MARK: - Conditional Fetch Result

/// Result type for conditional GET on offerings endpoint.
enum AppActorOfferingsFetchResult: Sendable {
    /// Fresh data from the server (HTTP 200).
    case fresh(AppActorOfferingsResponseDTO, eTag: String?, requestId: String?, signatureVerified: Bool)
    /// Server returned 304 — cached data is still valid.
    case notModified(eTag: String?, requestId: String?)
}

// MARK: - Helpers

extension AppActorOfferingsResponseDTO {
    /// Extracts all unique App Store lookup IDs from every offering/package/product.
    var allStoreProductIds: Set<String> {
        var ids = Set<String>()
        for offering in offerings {
            for package in offering.packages {
                for product in package.products {
                    guard product.store == .appStore else { continue }
                    ids.insert(product.storeProductId ?? product.productId)
                }
            }
        }
        return ids
    }
}
