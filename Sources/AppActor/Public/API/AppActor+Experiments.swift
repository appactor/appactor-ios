import Foundation

// MARK: - Experiments (A/B Testing) Public API

extension AppActor {

    /// Fetches the experiment assignment for the given key.
    ///
    /// Returns the assigned variant if the user is in the experiment, or `nil` if the user
    /// is not targeted, the experiment is not running, etc.
    ///
    /// Assignments are **idempotent** — the same user + experiment always returns the same variant.
    /// Results are cached in-memory (5-minute TTL) and on disk for offline access.
    ///
    /// ```swift
    /// // Boolean experiment — control: true, treatment: false
    /// if let a = try await AppActor.shared.getExperimentAssignment(
    ///     experimentKey: "has_onboard"
    /// ) {
    ///     let showOnboard = a.payload.boolValue ?? true
    ///     if showOnboard { presentOnboarding() }
    /// }
    ///
    /// // Numeric experiment — different values per variant
    /// if let a = try await AppActor.shared.getExperimentAssignment(
    ///     experimentKey: "discount_test"
    /// ) {
    ///     let discount = a.payload.intValue ?? 0
    ///     applyDiscount(discount)
    /// }
    ///
    /// // JSON experiment — multiple values per variant
    /// if let a = try await AppActor.shared.getExperimentAssignment(
    ///     experimentKey: "onboarding_flow"
    /// ) {
    ///     let title = a.payload["title"]?.stringValue ?? "Welcome"
    ///     let steps = a.payload["steps"]?.intValue ?? 3
    ///     let showSkip = a.payload["showSkip"]?.boolValue ?? true
    /// }
    /// ```
    ///
    /// - Parameter experimentKey: The developer-defined experiment key.
    /// - Returns: The assignment if the user is in the experiment, or `nil`.
    /// - Throws: `AppActorError` if payment is not configured or network fails.
    public func getExperimentAssignment(
        experimentKey: String
    ) async throws -> AppActorExperimentAssignment? {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let manager = experimentManager else {
            throw AppActorError.notConfigured
        }
        guard let appUserId = paymentStorage?.currentAppUserId else {
            throw AppActorError.notConfigured
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let country = Self.experimentDeviceCountryCode

        let assignment = try await manager.getAssignment(
            experimentKey: experimentKey,
            appUserId: appUserId,
            appVersion: appVersion,
            country: country
        )
        if let rid = await manager.lastRequestId {
            paymentStorage?.setLastRequestId(rid)
        }
        return assignment
    }

    // MARK: - Helpers

    private static var experimentDeviceCountryCode: String? {
        if #available(iOS 16, macOS 13, tvOS 16, watchOS 9, *) {
            return Locale.current.region?.identifier
        } else {
            return Locale.current.regionCode
        }
    }
}

// MARK: - Payment State Accessors (delegating to PaymentContext)

extension AppActor {
    var experimentManager: AppActorExperimentManager? {
        get { paymentContext.experimentManager }
        set { paymentContext.experimentManager = newValue }
    }

    /// Clears experiment caches on login/logout/reset to prevent cross-user leaks.
    func clearExperimentCaches() async {
        if let manager = experimentManager,
           let currentUserId = paymentStorage?.currentAppUserId {
            await manager.clearCache(appUserId: currentUserId)
        }
    }
}
