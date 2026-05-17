import Foundation
import StoreKit
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
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
        if let email {
            try AppActorAttributeKey.validateEmail(email)
        }
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
        if let phoneNumber {
            try AppActorAttributeKey.validatePhoneNumber(phoneNumber)
        }
        try await setReservedAttribute(AppActorAttributeKey.phoneNumber, value: phoneNumber.map { .string($0) })
    }

    public static func setPushToken(_ pushToken: String?) async throws {
        try await shared.setPushToken(pushToken)
    }

    public func setPushToken(_ pushToken: String?) async throws {
        try await setReservedAttribute(AppActorAttributeKey.apnsToken, value: pushToken.map { .string($0) })
    }

    public static func setPushToken(_ pushToken: Data) async throws {
        try await shared.setPushToken(pushToken)
    }

    public func setPushToken(_ pushToken: Data) async throws {
        try await setPushToken(Self.hexString(from: pushToken))
    }

    /// Collects supported system profile context into the server-routed
    /// profile-current store.
    ///
    /// The collected values use AppActor system keys (for example
    /// `$appVersion`, `$sdkVersion`, `$platform`, `$locale`, and `$timezone`).
    /// Custom ``setAttributes(_:)`` calls remain developer-owned and reject
    /// `$` system keys.
    public static func collectProfileContext() async throws {
        try await shared.collectProfileContext()
    }

    /// Collects supported system profile context into the server-routed
    /// profile-current store.
    ///
    /// This method does not collect optional device identifiers such as IDFV.
    /// Use ``collectDeviceIdentifiers()`` only when the host app intentionally
    /// opts in to identifier collection and matching App Store privacy disclosure.
    public func collectProfileContext() async throws {
        try await collectSystemProfileContext(includeDeviceIdentifiers: false)
    }

    /// Collects system profile context plus optional device/customer identifiers
    /// that are not sent by default.
    ///
    /// AppActor does not collect IDFV automatically. Calling this method may send
    /// `$idfv` on supported iOS devices. The host app remains responsible for
    /// its App Store privacy disclosure when it opts in to identifier collection.
    public static func collectDeviceIdentifiers() async throws {
        try await shared.collectDeviceIdentifiers()
    }

    /// Collects system profile context plus optional device/customer identifiers
    /// that are not sent by default.
    ///
    /// AppActor does not collect IDFV automatically. Calling this method may send
    /// `$idfv` on supported iOS devices. The host app remains responsible for
    /// its App Store privacy disclosure when it opts in to identifier collection.
    public func collectDeviceIdentifiers() async throws {
        try await collectSystemProfileContext(includeDeviceIdentifiers: true)
    }

    private func collectSystemProfileContext(includeDeviceIdentifiers: Bool) async throws {
        var attributes: [String: AppActorAttributeValue] = [:]

        attributes[AppActorAttributeKey.sdkVersion] = .string(AppActorSDK.version)
        attributes[AppActorAttributeKey.platform] = .string(Self.platformName)
        attributes[AppActorAttributeKey.locale] = .string(Locale.current.identifier)
        attributes[AppActorAttributeKey.timezone] = .string(TimeZone.current.identifier)
        attributes[AppActorAttributeKey.osVersion] = .string(Self.osVersion)

        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            attributes[AppActorAttributeKey.bundleId] = .string(bundleId)
        }
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !appVersion.isEmpty {
            attributes[AppActorAttributeKey.appVersion] = .string(appVersion)
        }
        if let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !appBuild.isEmpty {
            attributes[AppActorAttributeKey.appBuild] = .string(appBuild)
        }
        if let deviceModel = Self.deviceModelName, !deviceModel.isEmpty {
            attributes[AppActorAttributeKey.deviceModel] = .string(deviceModel)
        }
        if let localeCountry = Self.localeCountryCode {
            attributes[AppActorAttributeKey.localeCountry] = .string(localeCountry)
        }
        if let storefrontCountry = await Self.currentStorefrontCountryCode() {
            attributes[AppActorAttributeKey.storefrontCountry] = .string(storefrontCountry)
        }
        if let attConsentStatus = Self.attConsentStatus {
            attributes[AppActorAttributeKey.attConsentStatus] = .string(attConsentStatus)
        }

        #if canImport(UIKit) && !os(watchOS)
        if includeDeviceIdentifiers, let idfv = UIDevice.current.identifierForVendor?.uuidString {
            attributes[AppActorAttributeKey.idfv] = .string(idfv)
        }
        #endif

        guard !attributes.isEmpty else {
            Log.customer.debug("No supported profile context values found on this platform")
            return
        }
        try validateAttributes(attributes, allowReserved: true)
        try await enqueueAttributes(attributes)
    }

    public static func setIntegrationIdentifier(_ key: String, value: String?) async throws {
        try await shared.setIntegrationIdentifier(key, value: value)
    }

    public func setIntegrationIdentifier(_ key: String, value: String?) async throws {
        try AppActorAttributeKey.validateIntegrationIdentifier(key)
        guard let value else {
            try await unsetIntegrationIdentifier(key)
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try await unsetIntegrationIdentifier(key)
            return
        }
        guard trimmed == value else {
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

    public static func unsetIntegrationIdentifier(_ key: String) async throws {
        try await shared.unsetIntegrationIdentifier(key)
    }

    public func unsetIntegrationIdentifier(_ key: String) async throws {
        try AppActorAttributeKey.validateIntegrationIdentifier(key)
        let appUserId = customerAttributesManager.ensureAppUserId()
        try customerAttributesManager.unsetIntegrationIdentifier(
            appUserId: appUserId,
            key: key
        )
        try await flushIfConfigured(appUserId: appUserId)
    }

    public static func setIntegrationIdentifier(_ type: AppActorIntegrationIdentifier, value: String?) async throws {
        try await shared.setIntegrationIdentifier(type, value: value)
    }

    public func setIntegrationIdentifier(_ type: AppActorIntegrationIdentifier, value: String?) async throws {
        try await setIntegrationIdentifier(type.rawValue, value: value)
    }

    public static func unsetIntegrationIdentifier(_ type: AppActorIntegrationIdentifier) async throws {
        try await shared.unsetIntegrationIdentifier(type)
    }

    public func unsetIntegrationIdentifier(_ type: AppActorIntegrationIdentifier) async throws {
        try await unsetIntegrationIdentifier(type.rawValue)
    }

    public static func setAppsflyerID(_ appsflyerID: String?) async throws {
        try await shared.setAppsflyerID(appsflyerID)
    }

    public func setAppsflyerID(_ appsflyerID: String?) async throws {
        try await setIntegrationIdentifier(.appsflyerId, value: appsflyerID)
    }

    public static func setAppsFlyerID(_ appsFlyerID: String?) async throws {
        try await shared.setAppsFlyerID(appsFlyerID)
    }

    public func setAppsFlyerID(_ appsFlyerID: String?) async throws {
        try await setAppsflyerID(appsFlyerID)
    }

    public static func setAdjustID(_ adjustID: String?) async throws {
        try await shared.setAdjustID(adjustID)
    }

    public func setAdjustID(_ adjustID: String?) async throws {
        try await setIntegrationIdentifier(.adjustId, value: adjustID)
    }

    public static func setBranchID(_ branchID: String?) async throws {
        try await shared.setBranchID(branchID)
    }

    public func setBranchID(_ branchID: String?) async throws {
        try await setIntegrationIdentifier(.branchId, value: branchID)
    }

    public static func setFirebaseAppInstanceID(_ firebaseAppInstanceID: String?) async throws {
        try await shared.setFirebaseAppInstanceID(firebaseAppInstanceID)
    }

    public func setFirebaseAppInstanceID(_ firebaseAppInstanceID: String?) async throws {
        try await setIntegrationIdentifier(.firebaseAppInstanceId, value: firebaseAppInstanceID)
    }

    public static func setOneSignalID(_ oneSignalID: String?) async throws {
        try await shared.setOneSignalID(oneSignalID)
    }

    public func setOneSignalID(_ oneSignalID: String?) async throws {
        try await setIntegrationIdentifier(.oneSignalId, value: oneSignalID)
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

    public static func setMediaSource(_ mediaSource: String) async throws {
        try await shared.setMediaSource(mediaSource)
    }

    public func setMediaSource(_ mediaSource: String) async throws {
        try await updateCustomAttribution(
            providerName: mediaSource,
            network: mediaSource,
            source: mediaSource
        )
    }

    public static func setCampaign(_ campaign: String) async throws {
        try await shared.setCampaign(campaign)
    }

    public func setCampaign(_ campaign: String) async throws {
        try await updateCustomAttribution(campaignName: campaign, campaign: campaign)
    }

    public static func setAdGroup(_ adGroup: String) async throws {
        try await shared.setAdGroup(adGroup)
    }

    public func setAdGroup(_ adGroup: String) async throws {
        try await updateCustomAttribution(adGroupName: adGroup, adGroup: adGroup)
    }

    public static func setAd(_ ad: String) async throws {
        try await shared.setAd(ad)
    }

    public func setAd(_ ad: String) async throws {
        try await updateCustomAttribution(adName: ad, ad: ad)
    }

    public static func setKeyword(_ keyword: String) async throws {
        try await shared.setKeyword(keyword)
    }

    public func setKeyword(_ keyword: String) async throws {
        try await updateCustomAttribution(keyword: keyword)
    }

    public static func setCreative(_ creative: String) async throws {
        try await shared.setCreative(creative)
    }

    public func setCreative(_ creative: String) async throws {
        try await updateCustomAttribution(creativeName: creative, creative: creative)
    }

    func flushPendingCustomerAttributeWritesForCurrentUser() async throws {
        guard let appUserId = paymentStorage?.currentAppUserId else { return }
        try await customerAttributesManager.flush(appUserId: appUserId)
    }

    func flushPendingCustomerAttributeWritesForAllUsers() async throws {
        for appUserId in customerAttributesManager.pendingUserIds() {
            do {
                try await customerAttributesManager.flush(appUserId: appUserId)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.customer.warn("Customer attribute flush failed for pending user \(String(appUserId.prefix(8)))…; keeping queued mutations")
            }
        }
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
		if let provider = attribution.provider {
			try AppActorAttributeKey.validateAttributionString(provider, field: "provider", maxBytes: 64)
		}
		let values: [(String, String?)] = [
			("status", attribution.status),
			("provider_name", attribution.providerName),
			("campaign_id", attribution.campaignId),
			("campaign_name", attribution.campaignName),
			("ad_group_id", attribution.adGroupId),
			("ad_group_name", attribution.adGroupName),
			("ad_id", attribution.adId),
			("ad_name", attribution.adName),
			("creative_id", attribution.creativeId),
			("creative_name", attribution.creativeName),
			("keyword_id", attribution.keywordId),
			("network", attribution.network),
			("source", attribution.source),
			("medium", attribution.medium),
			("campaign", attribution.campaign),
			("ad_group", attribution.adGroup),
			("ad", attribution.ad),
			("keyword", attribution.keyword),
			("creative", attribution.creative),
			("click_id", attribution.clickId),
			("attributed_at", attribution.attributedAt),
		]
		for (field, value) in values {
			try AppActorAttributeKey.validateAttributionString(value, field: field)
		}
	}

	private static func hexString(from data: Data) -> String {
		data.map { String(format: "%02x", $0) }.joined()
	}

	private func updateCustomAttribution(
		providerName: String? = nil,
		campaignName: String? = nil,
		adGroupName: String? = nil,
		adName: String? = nil,
		creativeName: String? = nil,
		network: String? = nil,
		source: String? = nil,
		campaign: String? = nil,
		adGroup: String? = nil,
		ad: String? = nil,
		keyword: String? = nil,
		creative: String? = nil
	) async throws {
		var patch = AppActorAttribution()
		patch.provider = "custom"
		patch.providerName = providerName
		patch.campaignName = campaignName
		patch.adGroupName = adGroupName
		patch.adName = adName
		patch.creativeName = creativeName
		patch.keyword = keyword
		patch.network = network
		patch.source = source
		patch.campaign = campaign
		patch.adGroup = adGroup
		patch.ad = ad
		patch.creative = creative

		let appUserId = customerAttributesManager.ensureAppUserId()
		let attribution = customerAttributesManager.mergeCustomAttribution(appUserId: appUserId, patch: patch)
		try await updateAttribution(attribution)
	}

	private static var platformName: String {
		#if os(iOS)
		return "ios"
		#elseif os(tvOS)
		return "tvos"
		#elseif os(watchOS)
		return "watchos"
		#elseif os(macOS)
		return "macos"
		#else
		return "apple"
		#endif
	}

    private static var osVersion: String {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.systemVersion
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    private static var deviceModelName: String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.model
        #else
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: model)
        return value.isEmpty ? nil : value
        #endif
    }

    private static var localeCountryCode: String? {
        let region: String?
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            region = Locale.current.region?.identifier
        } else {
            region = Locale.current.regionCode
        }
        return normalizedCountryCode(region)
    }

    private static func currentStorefrontCountryCode() async -> String? {
        if let storefront = await Storefront.current {
            return normalizedCountryCode(storefront.countryCode)
        }
        return nil
    }

    private static var attConsentStatus: String? {
        #if canImport(AppTrackingTransparency) && !os(watchOS)
        if #available(iOS 14.0, tvOS 14.0, macCatalyst 14.0, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .notDetermined:
                return "not_determined"
            case .restricted:
                return "restricted"
            case .denied:
                return "denied"
            case .authorized:
                return "authorized"
            @unknown default:
                return "unknown"
            }
        }
        #endif
        return nil
    }

    private static func normalizedCountryCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        let locale = Locale(identifier: "und_\(trimmed)")
        let region: String?
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            region = locale.region?.identifier
        } else {
            region = locale.regionCode
        }
        guard let region = region?.uppercased(),
              region.range(of: #"^[A-Z]{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return region
    }
}

private extension AppActorAttributeKey {
	static func validateAttributionString(
		_ value: String?,
		field: String,
		maxBytes: Int = 1024
	) throws {
		guard let value else { return }
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed == value, !value.isEmpty else {
			throw AppActorError.validationError("Attribution field '\(field)' must not be empty or padded with whitespace")
		}
		guard value.utf8.count <= maxBytes else {
			throw AppActorError.validationError("Attribution field '\(field)' must be at most \(maxBytes) bytes")
		}
	}
}
