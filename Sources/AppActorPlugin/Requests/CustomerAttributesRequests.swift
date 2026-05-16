import Foundation
import AppActor

struct SetAttributesRequest: AppActorPluginRequest {
    static let method = "set_attributes"

    let attributes: [String: AppActorAttributeValue]

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setAttributes(attributes)
        return .successVoid
    }
}

struct SetAttributeRequest: AppActorPluginRequest {
    static let method = "set_attribute"

    let key: String
    let value: AppActorAttributeValue

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setAttribute(key, value: value)
        return .successVoid
    }
}

struct UnsetAttributeRequest: AppActorPluginRequest {
    static let method = "unset_attribute"

    let key: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.unsetAttribute(key)
        return .successVoid
    }
}

struct SetEmailRequest: AppActorPluginRequest {
    static let method = "set_email"

    let email: String?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setEmail(email)
        return .successVoid
    }
}

struct SetDisplayNameRequest: AppActorPluginRequest {
    static let method = "set_display_name"

    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName
        case displayNameSnake = "display_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displayNameSnake)
    }

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setDisplayName(displayName)
        return .successVoid
    }
}

struct SetPhoneNumberRequest: AppActorPluginRequest {
    static let method = "set_phone_number"

    let phoneNumber: String?

    private enum CodingKeys: String, CodingKey {
        case phoneNumber
        case phoneNumberSnake = "phone_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phoneNumber = try container.decodeIfPresent(String.self, forKey: .phoneNumber)
            ?? container.decodeIfPresent(String.self, forKey: .phoneNumberSnake)
    }

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setPhoneNumber(phoneNumber)
        return .successVoid
    }
}

struct SetPushTokenRequest: AppActorPluginRequest {
    static let method = "set_push_token"

    let pushToken: String?

    private enum CodingKeys: String, CodingKey {
        case pushToken
        case pushTokenSnake = "push_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pushToken = try container.decodeIfPresent(String.self, forKey: .pushToken)
            ?? container.decodeIfPresent(String.self, forKey: .pushTokenSnake)
    }

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setPushToken(pushToken)
        return .successVoid
    }
}

struct CollectDeviceIdentifiersRequest: AppActorPluginRequest {
    static let method = "collect_device_identifiers"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.collectDeviceIdentifiers()
        return .successVoid
    }
}

struct SetIntegrationIdentifierRequest: AppActorPluginRequest {
    static let method = "set_integration_identifier"

    let key: String
    let value: String

    private enum CodingKeys: String, CodingKey {
        case key
        case type
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
            ?? container.decode(String.self, forKey: .type)
        value = try container.decode(String.self, forKey: .value)
    }

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setIntegrationIdentifier(key, value: value)
        return .successVoid
    }
}

struct UpdateAttributionRequest: AppActorPluginRequest {
    static let method = "update_attribution"

    let attribution: AppActorAttribution

    private enum CodingKeys: String, CodingKey {
        case attribution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let attribution = try container.decodeIfPresent(AppActorAttribution.self, forKey: .attribution) {
            self.attribution = attribution
        } else {
            self.attribution = try AppActorAttribution(from: decoder)
        }
    }

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.updateAttribution(attribution)
        return .successVoid
    }
}

struct SetMediaSourceRequest: AppActorPluginRequest {
    static let method = "set_media_source"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setMediaSource(value)
        return .successVoid
    }
}

struct SetCampaignRequest: AppActorPluginRequest {
    static let method = "set_campaign"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setCampaign(value)
        return .successVoid
    }
}

struct SetAdGroupRequest: AppActorPluginRequest {
    static let method = "set_ad_group"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setAdGroup(value)
        return .successVoid
    }
}

struct SetAdRequest: AppActorPluginRequest {
    static let method = "set_ad"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setAd(value)
        return .successVoid
    }
}

struct SetKeywordRequest: AppActorPluginRequest {
    static let method = "set_keyword"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setKeyword(value)
        return .successVoid
    }
}

struct SetCreativeRequest: AppActorPluginRequest {
    static let method = "set_creative"

    let value: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.setCreative(value)
        return .successVoid
    }
}
