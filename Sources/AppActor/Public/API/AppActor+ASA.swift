import Foundation

// MARK: - ASA Public API

extension AppActor {

    // MARK: - Enable

    /// Enables Apple Search Ads attribution tracking.
    ///
    /// Must be called **after** `configure()` has returned. Calling before
    /// configuration or during bootstrap throws ``AppActorError/notConfigured``.
    /// Attribution uses the current local app user ID immediately.
    /// Calling more than once is a no-op.
    ///
    /// The attribution task runs in the background and does **not** block this call.
    ///
    /// ```swift
    /// await AppActor.configure(apiKey: "pk_YOUR_PUBLIC_API_KEY")
    /// try AppActor.shared.enableAppleSearchAdsTracking()
    /// ```
    ///
    /// - Parameter options: ASA configuration. Default values enable auto-tracking.
    /// - Throws: ``AppActorError/notConfigured`` if the SDK is not fully configured.
    public func enableAppleSearchAdsTracking(options: AppActorASAOptions = .init()) throws {
        guard paymentLifecycle == .configured, isBootstrapComplete,
              let client = paymentClient, let storage = paymentStorage else {
            throw AppActorError.notConfigured
        }
        guard asaManager == nil else {
            Log.attribution.warn("enableAppleSearchAdsTracking() already enabled — ignored.")
            return
        }

        // Eagerly initialize installDate so it captures the actual first SDK init moment.
        _ = storage.asaInstallDate

        let manager = AppActorASAManager(
            client: client,
            storage: storage,
            eventStore: AppActorASAFileEventStore(),
            options: options,
            sdkVersion: AppActorSDK.version
        )
        self.asaManager = manager
        Log.attribution.info("📊 ASA tracking enabled (autoTrackPurchases: \(options.autoTrackPurchases))")

        // Single fire-and-forget task: wire watcher first, then run attribution
        let watcher = options.autoTrackPurchases ? transactionWatcher : nil
        asaTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let watcher {
                await watcher.configureASATracking(manager: manager, trackInSandbox: options.trackInSandbox)
            }
            let asaStart = CFAbsoluteTimeGetCurrent()
            await manager.performAttributionIfNeeded()
            await manager.flushPendingPurchaseEvents()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - asaStart) * 1000)
            Log.attribution.info("  ⏱ ASA: \(elapsed) ms")
        }
    }

    // MARK: - Diagnostics

    /// Returns a point-in-time snapshot of all ASA (Apple Search Ads) state.
    ///
    /// Returns `nil` if ASA is not enabled.
    public func asaDiagnostics() async -> AppActorASADiagnostics? {
        guard let manager = asaManager else { return nil }
        return await manager.diagnostics()
    }

    /// Number of pending ASA purchase events waiting to be flushed.
    ///
    /// Returns `0` if ASA is not enabled.
    public var pendingASAPurchaseEventCount: Int {
        get async {
            guard let manager = asaManager else { return 0 }
            return await manager.pendingPurchaseEventCount()
        }
    }

    // MARK: - Keychain State

    /// Whether this is the first install on this physical device (Keychain-based).
    ///
    /// Returns `true` if no Keychain entry exists (first launch after fresh install).
    /// Persists across uninstall/reinstall on the same device.
    public static var asaFirstInstallOnDevice: Bool {
        AppActorASAKeychainHelper.firstInstallOnDevice
    }

    /// Whether this is the first install on this Apple account (iCloud Keychain synced).
    ///
    /// Returns `true` if no Keychain entry exists.
    /// Syncs across devices on the same Apple account via iCloud Keychain.
    public static var asaFirstInstallOnAccount: Bool {
        AppActorASAKeychainHelper.firstInstallOnAccount
    }

}
