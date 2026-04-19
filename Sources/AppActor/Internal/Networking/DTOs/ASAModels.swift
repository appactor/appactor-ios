import Foundation

// MARK: - ASA Attribution

/// POST /v1/asa/attribution — request body
struct AppActorASAAttributionRequest: Encodable, Sendable {
    let userId: String
    let attributionToken: String
    let osVersion: String?
    let appVersion: String?
    let libVersion: String?
    let firstInstallOnDevice: Bool?
    let firstInstallOnAccount: Bool?
    let installDate: String?
    /// Raw Apple AdServices attribution response from api-adservices.apple.com
    let asaAttributionResponse: [String: AnyCodable]?
}

/// POST /v1/asa/attribution — response body `{ status, attribution }`
struct AppActorASAAttributionResponseDTO: Decodable, Sendable {
    let status: String
    let attribution: AppActorASAAttributionResultDTO
}

/// Attribution result within the response.
struct AppActorASAAttributionResultDTO: Decodable, Sendable {
    let attributionStatus: String
    let appleOrgId: Int?
    let campaignId: Int?
    let campaignName: String?
    let adGroupId: Int?
    let adGroupName: String?
    let keywordId: Int?
    let keywordName: String?
    let creativeSetId: Int?
    let conversionType: String?
    let claimType: String?
    let region: String?
    let supplyPlacement: String?
}

/// Internal attribution result.
struct AppActorASAAttributionResult: Sendable {
    let attributionStatus: AppActorASAAttributionStatus
    let appleOrgId: Int?
    let campaignId: Int?
    let campaignName: String?
    let adGroupId: Int?
    let adGroupName: String?
    let keywordId: Int?
    let keywordName: String?
    let creativeSetId: Int?
    let conversionType: String?
    let claimType: String?
    let region: String?
    let supplyPlacement: String?

    init(dto: AppActorASAAttributionResultDTO) {
        self.attributionStatus = AppActorASAAttributionStatus(rawValue: dto.attributionStatus) ?? .error
        self.appleOrgId = dto.appleOrgId
        self.campaignId = dto.campaignId
        self.campaignName = dto.campaignName
        self.adGroupId = dto.adGroupId
        self.adGroupName = dto.adGroupName
        self.keywordId = dto.keywordId
        self.keywordName = dto.keywordName
        self.creativeSetId = dto.creativeSetId
        self.conversionType = dto.conversionType
        self.claimType = dto.claimType
        self.region = dto.region
        self.supplyPlacement = dto.supplyPlacement
    }
}

/// Attribution status enum.
enum AppActorASAAttributionStatus: String, Sendable {
    case attributed
    case organic
    case error
}

// MARK: - ASA Purchase Event

/// POST /v1/asa/purchase-event — request body
struct AppActorASAPurchaseEventRequest: Codable, Sendable {
    let userId: String
    let productId: String
    let transactionId: String?
    let originalTransactionId: String?
    let purchaseDate: String
    let countryCode: String?
    let storekit2Json: [String: AnyCodable]?
    let appVersion: String?
    let osVersion: String?
    let libVersion: String?
}

/// POST /v1/asa/purchase-event — response body `{ status, eventId }`
struct AppActorASAPurchaseEventResponseDTO: Decodable, Sendable {
    let status: String
    let eventId: String
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for arbitrary JSON values (e.g. Apple's attribution response).
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            // [L4] Encode unsupported types as their string description instead of throwing.
            // Prevents late failures during network encoding of persisted events.
            Log.attribution.warn("[AnyCodable] Unsupported type '\(type(of: value))', encoding as string description")
            try container.encode(String(describing: value))
        }
    }
}

// MARK: - Dictionary → AnyCodable Conversion

extension Dictionary where Key == String, Value == Any {
    /// Convert `[String: Any]` to `[String: AnyCodable]` for JSON encoding.
    var asAnyCodable: [String: AnyCodable] {
        mapValues { AnyCodable($0) }
    }
}
