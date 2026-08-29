import Foundation

// MARK: - Experiments (A/B Testing) Public API

extension AppActor {

    /// Resolves the user's standing in an experiment.
    ///
    /// Never `nil`: when the user is not in the experiment the result reports
    /// `isEnrolled == false`, `variantKey == nil`, and every typed getter returns its default.
    /// Same caching and errors as ``getExperimentAssignment(experimentKey:)``.
    ///
    /// ```swift
    /// let paywall = try await AppActor.shared.experiment("paywall_test")
    /// if paywall.isVariant("annual_first") { showAnnualFirst() }
    ///
    /// let showOnboarding = try await AppActor.shared.experiment("has_onboard").boolValue(default: true)
    /// let title = try await AppActor.shared.experiment("onboarding_flow")["title"]?.stringValue ?? "Welcome"
    /// ```
    public func experiment(_ experimentKey: String) async throws -> AppActorExperiment {
        AppActorExperiment(
            experimentKey: experimentKey,
            assignment: try await getExperimentAssignment(experimentKey: experimentKey)
        )
    }

    /// Fetches the experiment assignment for the given key.
    ///
    /// Prefer ``experiment(_:)`` — it never returns `nil` and carries typed getters with defaults.
    ///
    /// Returns the assigned variant if the user is in the experiment, or `nil` if the user
    /// is not targeted, the experiment is not running, etc.
    ///
    /// Assignments are **idempotent** — the same user + experiment always returns the same variant.
    /// Results are cached in-memory (5-minute TTL) and on disk for offline access.
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
