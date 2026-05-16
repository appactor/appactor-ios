import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Customer Attributes Public API

extension AppActor {
    public static func setAttributes(_ attributes: [String: AppActorAttributeValue]) async throws {
        try await shared.setAttributes(attributes)
    }

    public func setAttributes(_ attributes: [String: AppActorAttributeValue]) async throws {
        try validateAttributes(attributes, allowReserved: false)
        try await enqueueAttributes(attributes)
    }

    public static func setAttribute(_ key: String, value: AppActorAttributeValue) async throws {
        try await shared.setAttribute(key, value: value)
    }

    public func setAttribute(_ key: String, value: AppActorAttributeValue) async throws {
        try AppActorAttributeKey.validateCustom(key)
        try AppActorAttributeKey.validateValue(value, key: key)
        try await enqueueAttributes([key: value])
    }

    public static func unsetAttribute(_ key: String) async throws {
        try await shared.unsetAttribute(key)
    }

    public func unsetAttribute(_ key: String) async throws {
        try AppActorAttributeKey.validateCustom(key)
        try await enqueueAttributes([:], unsetKeys: [key])
    }

    public static func setEmail(_ email: String?) async throws {
        try await shared.setEmail(email)
    }

    public func setEmail(_ email: String?) async throws {
        try await setReservedAttribute(AppActorAttributeKey.email, value: email.map { .string($0) })
    }

    public static func setDisplayName(_ displayName: String?) async throws {
        try await shared.setDisplayName(displayName)
    }

    public func setDisplayName(_ displayName: String?) async throws {
        try await setReservedAttribute(AppActorAttributeKey.displayName, value: displayName.map { .string($0) })
    }

    public static func setPhoneNumber(_ phoneNumber: String?) async throws {
        try await shared.setPhoneNumber(phoneNumber)
    }

    public func setPhoneNumber(_ phoneNumber: String?) async throws {
        try await setReservedAttribute(AppActorAttributeKey.phoneNumber, value: phoneNumber.map { .string($0) })
    }

    public static func setPushToken(_ pushToken: String?) async throws {
        try await shared.setPushToken(pushToken)
    }

    public func setPushToken(_ pushToken: String?) async throws {
        try await setReservedAttribute(AppActorAttributeKey.apnsToken, value: pushToken.map { .string($0) })
    }

    public static func setPushToken(_ pushToken: Data?) async throws {
        try await shared.setPushToken(pushToken)
    }

    public func setPushToken(_ pushToken: Data?) async throws {
        try await setPushToken(pushToken.map(Self.hexString))
    }

    public static func collectDeviceIdentifiers() async throws {
        try await shared.collectDeviceIdentifiers()
    }

    public func collectDeviceIdentifiers() async throws {
        var attributes: [String: AppActorAttributeValue] = [:]

        #if canImport(UIKit) && !os(watchOS)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            attributes[AppActorAttributeKey.idfv] = .string(idfv)
        }
        #endif

        guard !attributes.isEmpty else {
            Log.customer.debug("collectDeviceIdentifiers() found no supported identifiers on this platform")
            return
        }
        try validateAttributes(attributes, allowReserved: true)
        try await enqueueAttributes(attributes)
    }

    public static func setIntegrationIdentifier(_ key: String, value: String) async throws {
        try await shared.setIntegrationIdentifier(key, value: value)
    }

    public func setIntegrationIdentifier(_ key: String, value: String) async throws {
        try AppActorAttributeKey.validateIntegrationIdentifier(key)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !value.isEmpty else {
            throw AppActorError.validationError("Integration identifier value must not be empty or padded with whitespace")
        }
        guard value.utf8.count <= 1024 else {
            throw AppActorError.validationError("Integration identifier value must be at most 1024 bytes")
        }

        let appUserId = customerAttributesManager.ensureAppUserId()
        try customerAttributesManager.enqueueIntegrationIdentifier(
            appUserId: appUserId,
            key: key,
            value: value
        )
        try await flushIfConfigured(appUserId: appUserId)
    }

    public static func updateAttribution(_ attribution: AppActorAttribution) async throws {
        try await shared.updateAttribution(attribution)
    }

    public func updateAttribution(_ attribution: AppActorAttribution) async throws {
        try validateAttribution(attribution)
        let appUserId = customerAttributesManager.ensureAppUserId()
        try customerAttributesManager.enqueueAttribution(appUserId: appUserId, attribution: attribution)
        try await flushIfConfigured(appUserId: appUserId)
    }

    public static func updateAttribution(
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
    ) async throws {
        try await shared.updateAttribution(
            network: network,
            source: source,
            medium: medium,
            campaign: campaign,
            adGroup: adGroup,
            ad: ad,
            keyword: keyword,
            creative: creative,
            clickId: clickId,
            metadata: metadata
        )
    }

    public func updateAttribution(
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
    ) async throws {
        try await updateAttribution(AppActorAttribution(
            network: network,
            source: source,
            medium: medium,
            campaign: campaign,
            adGroup: adGroup,
            ad: ad,
            keyword: keyword,
            creative: creative,
            clickId: clickId,
            metadata: metadata
        ))
    }

    func flushPendingCustomerAttributeWritesForCurrentUser() async throws {
        guard let appUserId = paymentStorage?.currentAppUserId else { return }
        try await customerAttributesManager.flush(appUserId: appUserId)
    }

    private func setReservedAttribute(_ key: String, value: AppActorAttributeValue?) async throws {
        try AppActorAttributeKey.validateReserved(key)
        if let value {
            try AppActorAttributeKey.validateValue(value, key: key)
            try await enqueueAttributes([key: value])
        } else {
            try await enqueueAttributes([:], unsetKeys: [key])
        }
    }

    private func enqueueAttributes(
        _ attributes: [String: AppActorAttributeValue],
        unsetKeys: [String] = []
    ) async throws {
        let appUserId = customerAttributesManager.ensureAppUserId()
        try customerAttributesManager.enqueueAttributes(
            appUserId: appUserId,
            attributes: attributes,
            unsetKeys: unsetKeys
        )
        try await flushIfConfigured(appUserId: appUserId)
    }

    private func flushIfConfigured(appUserId: String) async throws {
        guard paymentLifecycle == .configured else { return }
        try await customerAttributesManager.flush(appUserId: appUserId)
    }

    private func validateAttributes(
        _ attributes: [String: AppActorAttributeValue],
        allowReserved: Bool
    ) throws {
        guard !attributes.isEmpty else { return }
        for (key, value) in attributes {
            if allowReserved {
                try AppActorAttributeKey.validateReservedOrCustom(key)
            } else {
                try AppActorAttributeKey.validateCustom(key)
            }
            try AppActorAttributeKey.validateValue(value, key: key)
        }
    }

    private func validateAttribution(_ attribution: AppActorAttribution) throws {
        for (key, value) in attribution.metadata {
            try AppActorAttributeKey.validateCustom(key)
            try AppActorAttributeKey.validateValue(value, key: key)
        }
        let values = [
            attribution.network,
            attribution.source,
            attribution.medium,
            attribution.campaign,
            attribution.adGroup,
            attribution.ad,
            attribution.keyword,
            attribution.creative,
            attribution.clickId,
        ].compactMap { $0 }
        for value in values {
            guard value.utf8.count <= 1024 else {
                throw AppActorError.validationError("Attribution string values must be at most 1024 bytes")
            }
        }
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
