import Foundation

// MARK: - Remote Config Public API

extension AppActor {

    /// Loads all remote config values from the server.
    ///
    /// This is an **explicit call** — remote configs are NOT loaded during `configure()`.
    /// Call this method when your app is ready to consume remote config values.
    ///
    /// The resolved config values are based on:
    /// - **Platform**: derived from the API key (iOS/Android) — no parameter needed.
    /// - **App version**: auto-detected from `CFBundleShortVersionString`.
    /// - **Country**: auto-detected from device locale.
    /// - **User entitlements**: resolved from `app_user_id` if identified.
    ///
    /// ```swift
    /// // Load configs (explicit call)
    /// let configs = try await AppActor.shared.getRemoteConfigs()
    ///
    /// // Access typed values
    /// let hasRating = AppActor.shared.getRemoteConfigBool("has_rating") ?? false
    /// let minVersion = AppActor.shared.getRemoteConfigString("min_version") ?? "1.0.0"
    /// ```
    ///
    /// - Returns: The resolved remote configs.
    /// - Throws: `AppActorError` if payment is not configured or network fails.
    @discardableResult
    public func getRemoteConfigs() async throws -> AppActorRemoteConfigs {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let manager = remoteConfigManager else {
            throw AppActorError.notConfigured
        }

        let appUserId = paymentStorage?.currentAppUserId
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let country = Self.deviceCountryCode

        let result = try await manager.getRemoteConfigs(
            appUserId: appUserId,
            appVersion: appVersion,
            country: country
        )
        self.paymentRemoteConfigs = result
        if let rid = await manager.requestId {
            paymentStorage?.setLastRequestId(rid)
        }
        return result
    }

    // MARK: - Typed Accessors (nonisolated — safe to call from any context)

    /// Returns the raw config value for the given key, or `nil` if not found or not loaded.
    public nonisolated func getRemoteConfig(_ key: String) -> AppActorConfigValue? {
        AppActorPaymentContext._remoteConfigs?[key]
    }

    /// Returns the config value as a `Bool`, or `nil` if not found or wrong type.
    public nonisolated func getRemoteConfigBool(_ key: String) -> Bool? {
        getRemoteConfig(key)?.boolValue
    }

    /// Returns the config value as a `String`, or `nil` if not found or wrong type.
    public nonisolated func getRemoteConfigString(_ key: String) -> String? {
        getRemoteConfig(key)?.stringValue
    }

    /// Returns the config value as a `Double`, or `nil` if not found or wrong type.
    /// Also accepts integer config values (implicit widening).
    public nonisolated func getRemoteConfigNumber(_ key: String) -> Double? {
        getRemoteConfig(key)?.doubleValue
    }

    /// Returns the config value as an `Int`, or `nil` if not found or wrong type.
    /// Also accepts whole-number doubles (e.g. `3.0` → `3`).
    public nonisolated func getRemoteConfigInt(_ key: String) -> Int? {
        getRemoteConfig(key)?.intValue
    }

    /// The most recently loaded remote configs, or `nil` if ``getRemoteConfigs()`` has not been called yet.
    public nonisolated var cachedRemoteConfigs: AppActorRemoteConfigs? {
        AppActorPaymentContext._remoteConfigs
    }

    // MARK: - Helpers

    /// ISO 3166-1 alpha-2 country code from the device locale.
    private static var deviceCountryCode: String? {
        if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
            return Locale.current.region?.identifier
        } else {
            return Locale.current.regionCode
        }
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var remoteConfigManager: AppActorRemoteConfigManager? {
        get { paymentContext.remoteConfigManager }
        set { paymentContext.remoteConfigManager = newValue }
    }

    var paymentRemoteConfigs: AppActorRemoteConfigs? {
        get { paymentContext.remoteConfigs }
        set {
            paymentContext.remoteConfigs = newValue
            AppActorPaymentContext._remoteConfigs = newValue
        }
    }
}
