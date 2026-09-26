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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        packageType = try container.decode(String.self, forKey: .packageType)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        position = try container.decode(Int.self, forKey: .position)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        metadata = try container.decodeMetadataIfPresent(forKey: .metadata)
        tokenAmount = try container.decodeIfPresent(Int.self, forKey: .tokenAmount)
        products = try container.decode([AppActorProductRefDTO].self, forKey: .products)
    }
}

extension AppActorOfferingDTO {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lookupKey = try container.decode(String.self, forKey: .lookupKey)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        metadata = try container.decodeMetadataIfPresent(forKey: .metadata)
        packages = try container.decode([AppActorPackageDTO].self, forKey: .packages)
    }
}

// MARK: - Metadata

extension KeyedDecodingContainer {
    /// Offering and package metadata. The server stores any JSON value while the SDK's model is
    /// `[String: String]`, and one non-string value used to fail the whole offerings decode. Each
    /// value becomes the string Android's plugin hands the wrappers (OfferingsSurrogate.kt,
    /// `v?.toString() ?: ""`): null → "" with the key kept, a string as is, a bool as
    /// "true"/"false", an integer as "20" (never "20.0"), any other number as a Double, and an
    /// array or object as Kotlin prints a collection ("[a, 1]", "{k=v}"). Two edges differ: an
    /// object's keys come in the decoder's order, not the document's, and a number beyond Int64
    /// or a Double outside 10^-3..10^7 prints as Swift writes it ("1e+20", Kotlin "1.0E20").
    func decodeMetadataIfPresent(forKey key: Key) throws -> [String: String]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        let values = try nestedContainer(keyedBy: AppActorMetadataKey.self, forKey: key)
        return try Dictionary(uniqueKeysWithValues: values.allKeys.map { valueKey in
            let value = try values.decodeNil(forKey: valueKey)
                ? "" : try values.decode(AppActorMetadataValue.self, forKey: valueKey).string
            return (valueKey.stringValue, value)
        })
    }
}

private struct AppActorMetadataKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A non-null metadata value, as `decodeMetadataIfPresent(forKey:)` stringifies it. A null
/// inside an array or object prints as "null", as Kotlin prints it.
private struct AppActorMetadataValue: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: AppActorMetadataKey.self) {
            let entries = try object.allKeys.map { key in
                let value = try object.decodeNil(forKey: key) ? "null" : try object.decode(Self.self, forKey: key).string
                return "\(key.stringValue)=\(value)"
            }
            string = "{\(entries.joined(separator: ", "))}"
        } else if var array = try? decoder.unkeyedContainer() {
            var items: [String] = []
            while !array.isAtEnd {
                items.append(try array.decodeNil() ? "null" : try array.decode(Self.self).string)
            }
            string = "[\(items.joined(separator: ", "))]"
        } else {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) {
                string = text
            } else if let flag = try? value.decode(Bool.self) {
                string = String(flag)
            } else if let integer = try? value.decode(Int64.self) {
                string = String(integer)
            } else {
                string = String(try value.decode(Double.self))
            }
        }
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
