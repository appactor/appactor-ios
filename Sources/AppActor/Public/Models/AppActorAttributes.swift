import Foundation

/// A JSON-compatible customer attribute value.
///
/// Strings, numbers, booleans, dates, and flat arrays are supported. Dates are
/// sent with a lightweight type envelope so the API stores them as date values.
public enum AppActorAttributeValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case array([AppActorAttributeValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let envelope = try? container.decode(AppActorAttributeTypedEnvelope.self),
           envelope.valueType == "date" {
            guard let date = Self.isoFormatter.date(from: envelope.value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid AppActor date attribute value"
                )
            }
            self = .date(date)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([AppActorAttributeValue].self) {
            self = .array(array)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported AppActorAttributeValue JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .date(let value):
            try container.encode(AppActorAttributeTypedEnvelope(
                value: Self.isoFormatter.string(from: value),
                valueType: "date"
            ))
        case .array(let values):
            try container.encode(values)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct AppActorAttributeTypedEnvelope: Codable {
    let value: String
    let valueType: String
}

public enum AppActorIntegrationIdentifier: String, Sendable, Codable, CaseIterable {
    case appsflyerId = "appsflyer_id"
    case adjustId = "adjust_adid"
    case branchId = "branch_id"
    case firebaseAppInstanceId = "firebase_app_instance_id"
    case amplitudeUserId = "amplitude_user_id"
    case amplitudeDeviceId = "amplitude_device_id"
    case mixpanelDistinctId = "mixpanel_distinct_id"
    case facebookAnonymousId = "fb_anon_id"
    case oneSignalId = "onesignal_id"
}

extension AppActorAttributeValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AppActorAttributeValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AppActorAttributeValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension AppActorAttributeValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension AppActorAttributeValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AppActorAttributeValue...) {
        self = .array(elements)
    }
}

/// Attribution fields for customer-level acquisition metadata.
public struct AppActorAttribution: Sendable, Equatable, Codable {
    public var provider: String?
    public var status: String?
    public var providerName: String?
    public var campaignId: String?
    public var campaignName: String?
    public var adGroupId: String?
    public var adGroupName: String?
    public var adId: String?
    public var adName: String?
    public var creativeId: String?
    public var creativeName: String?
    public var keywordId: String?
    public var network: String?
    public var source: String?
    public var medium: String?
    public var campaign: String?
    public var adGroup: String?
    public var ad: String?
    public var keyword: String?
    public var creative: String?
    public var clickId: String?
    public var attributedAt: String?
    public var metadata: [String: AppActorAttributeValue]

    public init(
        provider: String? = nil,
        status: String? = nil,
        providerName: String? = nil,
        campaignId: String? = nil,
        campaignName: String? = nil,
        adGroupId: String? = nil,
        adGroupName: String? = nil,
        adId: String? = nil,
        adName: String? = nil,
        creativeId: String? = nil,
        creativeName: String? = nil,
        keywordId: String? = nil,
        keyword: String? = nil,
        attributedAt: String? = nil,
        metadata: [String: AppActorAttributeValue] = [:]
    ) {
        self.provider = provider
        self.status = status
        self.providerName = providerName
        self.campaignId = campaignId
        self.campaignName = campaignName
        self.adGroupId = adGroupId
        self.adGroupName = adGroupName
        self.adId = adId
        self.adName = adName
        self.creativeId = creativeId
        self.creativeName = creativeName
        self.keywordId = keywordId
        self.network = provider
        self.source = providerName
        self.medium = nil
        self.campaign = campaignName
        self.adGroup = adGroupName
        self.ad = adName
        self.keyword = keyword
        self.creative = creativeName
        self.clickId = nil
        self.attributedAt = attributedAt
        self.metadata = metadata
    }

    public init(
        network: String? = nil,
        source: String? = nil,
        medium: String? = nil,
        campaign: String? = nil,
        adGroup: String? = nil,
        ad: String? = nil,
        keyword: String? = nil,
        creative: String? = nil,
        clickId: String? = nil,
        metadata: [String: AppActorAttributeValue] = [:]
    ) {
        self.provider = network
        self.status = nil
        self.providerName = source
        self.campaignId = nil
        self.campaignName = campaign
        self.adGroupId = nil
        self.adGroupName = adGroup
        self.adId = nil
        self.adName = ad
        self.creativeId = nil
        self.creativeName = creative
        self.keywordId = nil
        self.network = network
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.adGroup = adGroup
        self.ad = ad
        self.keyword = keyword
        self.creative = creative
        self.clickId = clickId
        self.attributedAt = nil
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case status
        case providerName = "provider_name"
        case campaignId = "campaign_id"
        case campaignName = "campaign_name"
        case adGroupId = "ad_group_id"
        case adGroupName = "ad_group_name"
        case adId = "ad_id"
        case adName = "ad_name"
        case creativeId = "creative_id"
        case creativeName = "creative_name"
        case keywordId = "keyword_id"
        case keyword
        case attributedAt = "attributed_at"
        case network
        case source
        case medium
        case campaign
        case adGroup = "ad_group"
        case ad
        case creative
        case clickId = "click_id"
        case metadata
    }

    private enum DecodingKeys: String, CodingKey {
        case provider
        case status
        case providerName
        case campaignId
        case campaignName
        case adGroupId
        case adGroupName
        case adId
        case adName
        case creativeId
        case creativeName
        case keywordId
        case keyword
        case attributedAt
        case network
        case source
        case medium
        case campaign
        case adGroup
        case ad
        case creative
        case clickId
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternateContainer = try decoder.container(keyedBy: DecodingKeys.self)

        func decode(_ key: CodingKeys, _ alternateKey: DecodingKeys) throws -> String? {
            try container.decodeIfPresent(String.self, forKey: key)
                ?? alternateContainer.decodeIfPresent(String.self, forKey: alternateKey)
        }

        let provider = try decode(.provider, .provider)
        let providerName = try decode(.providerName, .providerName)
        let campaignName = try decode(.campaignName, .campaignName)
        let adGroupName = try decode(.adGroupName, .adGroupName)
        let adName = try decode(.adName, .adName)
        let creativeName = try decode(.creativeName, .creativeName)

        self.provider = provider
        self.status = try decode(.status, .status)
        self.providerName = providerName
        self.campaignId = try decode(.campaignId, .campaignId)
        self.campaignName = campaignName
        self.adGroupId = try decode(.adGroupId, .adGroupId)
        self.adGroupName = adGroupName
        self.adId = try decode(.adId, .adId)
        self.adName = adName
        self.creativeId = try decode(.creativeId, .creativeId)
        self.creativeName = creativeName
        self.keywordId = try decode(.keywordId, .keywordId)
        self.network = try decode(.network, .network) ?? provider
        self.source = try decode(.source, .source) ?? providerName
        self.medium = try decode(.medium, .medium)
        self.campaign = try decode(.campaign, .campaign) ?? campaignName
        self.adGroup = try decode(.adGroup, .adGroup) ?? adGroupName
        self.ad = try decode(.ad, .ad) ?? adName
        self.keyword = try decode(.keyword, .keyword)
        self.creative = try decode(.creative, .creative) ?? creativeName
        self.clickId = try decode(.clickId, .clickId)
        self.attributedAt = try decode(.attributedAt, .attributedAt)
        self.metadata = try container.decodeIfPresent([String: AppActorAttributeValue].self, forKey: .metadata)
            ?? alternateContainer.decodeIfPresent([String: AppActorAttributeValue].self, forKey: .metadata)
            ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(provider ?? network, forKey: .provider)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(providerName ?? source, forKey: .providerName)
        try container.encodeIfPresent(network, forKey: .network)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(campaignId, forKey: .campaignId)
        try container.encodeIfPresent(campaignName ?? campaign, forKey: .campaignName)
        try container.encodeIfPresent(campaign, forKey: .campaign)
        try container.encodeIfPresent(adGroupId, forKey: .adGroupId)
        try container.encodeIfPresent(adGroupName ?? adGroup, forKey: .adGroupName)
        try container.encodeIfPresent(adGroup, forKey: .adGroup)
        try container.encodeIfPresent(adId, forKey: .adId)
        try container.encodeIfPresent(adName ?? ad, forKey: .adName)
        try container.encodeIfPresent(ad, forKey: .ad)
        try container.encodeIfPresent(creativeId, forKey: .creativeId)
        try container.encodeIfPresent(creativeName ?? creative, forKey: .creativeName)
        try container.encodeIfPresent(creative, forKey: .creative)
        try container.encodeIfPresent(keywordId, forKey: .keywordId)
        try container.encodeIfPresent(keyword, forKey: .keyword)
        try container.encodeIfPresent(attributedAt, forKey: .attributedAt)
        try container.encodeIfPresent(medium, forKey: .medium)
        try container.encodeIfPresent(clickId, forKey: .clickId)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

enum AppActorAttributeKey {
    static let email = "$email"
    static let displayName = "$displayName"
    static let phoneNumber = "$phoneNumber"
    static let apnsToken = "$apnsToken"
    static let idfv = "$idfv"
    static let bundleId = "$bundleId"
    static let locale = "$locale"
    static let timezone = "$timezone"
    static let platform = "$platform"
    static let deviceModel = "$deviceModel"
    static let osVersion = "$osVersion"
    static let sdkVersion = "$sdkVersion"
    static let appVersion = "$appVersion"
    static let appBuild = "$appBuild"
    private static let allowedCustomCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-")

    static func validateCustom(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == key, !key.isEmpty else {
            throw AppActorError.validationError("Attribute key must not be empty or padded with whitespace")
        }
        guard key.count <= 64 else {
            throw AppActorError.validationError("Attribute key must be at most 64 characters")
        }
        guard key.rangeOfCharacter(from: allowedCustomCharacters.inverted) == nil else {
            throw AppActorError.validationError("Attribute keys may only contain letters, numbers, underscore, dot, colon, or dash.")
        }
        guard !key.hasPrefix("$") else {
            throw AppActorError.validationError("Custom attribute key '\(key)' must not start with '$'. Use the reserved helper API instead.")
        }
        guard !key.lowercased().hasPrefix("appactor.") else {
            throw AppActorError.validationError("Custom attribute key '\(key)' must not start with 'appactor.'")
        }
    }

    static func validateReservedOrCustom(_ key: String) throws {
        if key.hasPrefix("$") {
            try validateReserved(key)
            return
        }
        try validateCustom(key)
    }

    static func validateReserved(_ key: String) throws {
        switch key {
        case email, displayName, phoneNumber, apnsToken, idfv,
            bundleId, locale, timezone, platform, deviceModel, osVersion, sdkVersion, appVersion, appBuild:
            return
        default:
            throw AppActorError.validationError("Unknown reserved attribute key '\(key)'")
        }
    }

    static func validateIntegrationIdentifier(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == key, !key.isEmpty else {
            throw AppActorError.validationError("Integration identifier key must not be empty or padded with whitespace")
        }
        guard key.count <= 64 else {
            throw AppActorError.validationError("Integration identifier key must be at most 64 characters")
        }
        guard key.rangeOfCharacter(from: allowedCustomCharacters.inverted) == nil else {
            throw AppActorError.validationError("Integration identifier keys may only contain letters, numbers, underscore, dot, colon, or dash.")
        }
        guard !key.hasPrefix("$"), !key.lowercased().hasPrefix("appactor.") else {
            throw AppActorError.validationError("Integration identifier key '\(key)' uses a reserved prefix")
        }
    }

    static func validateValue(_ value: AppActorAttributeValue, key: String) throws {
        switch value {
        case .string(let string):
            guard string.utf8.count <= 1024 else {
                throw AppActorError.validationError("Attribute '\(key)' string value must be at most 1024 bytes")
            }
        case .number(let number):
            guard number.isFinite else {
                throw AppActorError.validationError("Attribute '\(key)' number value must be finite")
            }
        case .bool, .date:
            return
        case .array(let values):
            guard values.count <= 20 else {
                throw AppActorError.validationError("Attribute '\(key)' array value must contain at most 20 items")
            }
            var itemKind: String?
            for item in values {
                let currentKind: String
                switch item {
                case .string:
                    currentKind = "string"
                case .number:
                    currentKind = "number"
                case .bool:
                    currentKind = "boolean"
                case .date:
                    throw AppActorError.validationError("Attribute '\(key)' array value must not contain dates")
                case .array:
                    throw AppActorError.validationError("Attribute '\(key)' array value must not contain nested arrays")
                }
                if let itemKind, itemKind != currentKind {
                    throw AppActorError.validationError("Attribute '\(key)' array value must contain values of one primitive type")
                }
                itemKind = currentKind
                try validateValue(item, key: key)
            }
        }
    }

    static func validateEmail(_ email: String) throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == email, !email.isEmpty else {
            throw AppActorError.validationError("Email must not be empty or padded with whitespace")
        }
        guard email.utf8.count <= 320 else {
            throw AppActorError.validationError("Email must be at most 320 bytes")
        }
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        guard email.range(of: pattern, options: .regularExpression) != nil else {
            throw AppActorError.validationError("Email must be a valid email address")
        }
    }

    static func validatePhoneNumber(_ phoneNumber: String) throws {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == phoneNumber, !phoneNumber.isEmpty else {
            throw AppActorError.validationError("Phone number must not be empty or padded with whitespace")
        }
        guard phoneNumber.utf8.count <= 64 else {
            throw AppActorError.validationError("Phone number must be at most 64 bytes")
        }
        let digitCount = phoneNumber.filter(\.isNumber).count
        guard digitCount >= 3 else {
            throw AppActorError.validationError("Phone number must contain at least 3 digits")
        }
        let pattern = #"^[+0-9().\-\s]+$"#
        guard phoneNumber.range(of: pattern, options: .regularExpression) != nil else {
            throw AppActorError.validationError("Phone number contains unsupported characters")
        }
    }
}
