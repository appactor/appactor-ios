import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Payment Identity Extension

extension AppActor {

    // MARK: - Configuration

    /// Configures the AppActor Payment identity module and runs the full bootstrap sequence.
    ///
    /// Performs local setup (storage, client, managers) synchronously, immediately
    /// establishes a local app user ID, then awaits the bootstrap sequence:
    /// watcher start → offerings warm-up → sweep → drain+refresh.
    ///
    /// ASA attribution runs independently in the background and does **not** block this call.
    ///
    /// ```swift
    /// await AppActor.configure(apiKey: "pk_YOUR_PUBLIC_API_KEY")
    /// // Startup is complete here. A cached appUserId was reused or a new anonymous one was created.
    /// ```
    public static func configure(
        apiKey: String,
        appUserId: String? = nil,
        options: AppActorOptions = .init()
    ) async {
        let config = AppActorPaymentConfiguration(
            apiKey: apiKey,
            baseURL: AppActorPaymentConfiguration.defaultBaseURL,
            headerMode: .bearer,
            appUserId: appUserId,
            options: options
        )
        guard shared.configureInternal(config) else { return }
        await shared.runStartupSequence()
    }

    /// Returns `true` if configuration succeeded, `false` if guards rejected it.
    @discardableResult
    func configureInternal(_ config: AppActorPaymentConfiguration, testClient: (any AppActorPaymentClientProtocol)? = nil) -> Bool {
        if let validationError = config.validationError {
            let description = validationError.errorDescription ?? validationError.message ?? "Invalid AppActor configuration."
            Log.sdk.error("configure() validation failed: \(description)")
            assertionFailure(description)
            return false
        }

        // Guard: state machine — only transition from .idle → .configured
        switch paymentLifecycle {
        case .configured:
            Log.sdk.warn("configure() called while already configured — ignored. Call reset() first.")
            return false
        case .resetting:
            Log.sdk.warn("configure() called during reset() — ignored. Wait for reset to complete.")
            return false
        case .idle:
            break // OK — proceed
        }

        paymentLifecycle = .configured

        // If payment options specify a log level, escalate (never downgrade).
        if let paymentLevel = config.options.logLevel, paymentLevel > AppActorLogger.level {
            AppActorLogger.level = paymentLevel
        }

        let storage = AppActorUserDefaultsPaymentStorage()
        let client: any AppActorPaymentClientProtocol = testClient ?? AppActorPaymentClient(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            headerMode: config.headerMode
        )

        self.paymentConfig = config
        self.paymentStorage = storage
        self.paymentClient = client
        self.paymentCurrentUser = nil

        // Centralized ETag + response cache manager (shared by all managers).
        // Passes the verification mode so cached entries track whether they were
        // stored under verified responses — enables safe cache invalidation when
        // the verification mode is escalated (off→on).
        let etagManager = AppActorETagManager(
            responseVerificationEnabled: true
        )
        self.paymentETagManager = etagManager

        // Initialize offerings manager
        self.offeringsManager = AppActorOfferingsManager(
            client: client,
            etagManager: etagManager,
            fallbackDTO: paymentContext.fallbackOfferingsDTO
        )

        // Initialize customer manager
        self.customerManager = AppActorCustomerManager(
            client: client,
            etagManager: etagManager
        )

        // Initialize remote config manager
        self.remoteConfigManager = AppActorRemoteConfigManager(client: client, etagManager: etagManager)

        // Initialize experiment manager
        self.experimentManager = AppActorExperimentManager(client: client, etagManager: etagManager)

        // Initialize payment pipeline
        let queueStore = AppActorAtomicJSONQueueStore()
        let processor = AppActorPaymentProcessor(store: queueStore, client: client)
        let silentSyncFetcher = AppActorStoreKitSilentSyncFetcher()
        self.paymentQueueStore = queueStore
        self.paymentProcessor = processor
        self.transactionWatcher = AppActorTransactionWatcher(
            processor: processor,
            storage: storage,
            silentSyncFetcher: silentSyncFetcher
        )
        self.storeKitSilentSyncFetcher = silentSyncFetcher

        // Establish the canonical local identity synchronously so configure()
        // returns with appUserId/isAnonymous immediately usable.
        storage.resolveAppUserId(explicit: config.appUserId)
        storage.ensureAppAccountToken()
        storage.clearLegacyIdentityState()

        self.asaManager = nil

        // Watcher setup and bootstrap are awaited in runStartupSequence(),
        // which is called from configure() after configureInternal().
        // ASA runs as a separate fire-and-forget task.

        // Register app lifecycle observers for offerings TTL
        registerLifecycleObservers()

        Log.sdk.info("📦 AppActor v\(AppActorSDK.version) configured (key: \(config.apiKeyHint), baseURL: \(config.baseURL.absoluteString))")
        return true
    }

    /// Registers NotificationCenter observers for background/foreground transitions.
    /// Removes any previous observers to avoid duplicates on re-configure.
    func registerLifecycleObservers() {
        // Remove previous observers
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []

        #if canImport(UIKit) && !os(watchOS)
        let bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let manager = self.offeringsManager else { return }
            Task { await manager.setBackground(true) }
            self.stalenessTimerTask?.cancel()
            self.stalenessTimerTask = nil
            Log.sdk.debug("App entered background — offerings TTL set to 24h, staleness timer stopped")
        }

        let fgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.paymentLifecycle == .configured,
                  self.isBootstrapComplete else { return }
            if let manager = self.offeringsManager {
                Task { await manager.setBackground(false) }
            }
            // Cancel any previous foreground task before starting a new one.
            // Track this task so reset() can cancel+await it for
            // deterministic shutdown (prevents stale writes during reset).
            self.foregroundTask?.cancel()
            self.foregroundTask = Task { [weak self] in
                guard let self else { return }
                await self.runForegroundMaintenance()
            }
            Log.sdk.debug("App entering foreground — offerings TTL set to 5m, draining receipts")

            // Start periodic staleness timer for long foreground sessions.
            // Ensures customer info doesn't stay stale indefinitely when the app
            // remains in foreground without backgrounding.
            self.stalenessTimerTask?.cancel()
            self.stalenessTimerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 min
                    guard let self, !Task.isCancelled,
                          self.paymentLifecycle == .configured,
                          self.isBootstrapComplete else { break }
                    guard let manager = self.customerManager,
                          let userId = self.paymentStorage?.currentAppUserId else { continue }
                    if !(await manager.isCustomerCacheFresh(appUserId: userId)) {
                        _ = try? await self.getCustomerInfo()
                        Log.sdk.debug("Staleness timer: customer cache refreshed")
                    }
                }
            }
        }

        lifecycleObservers = [bgObserver, fgObserver]
        #endif
    }

    /// Runs the foreground maintenance sequence shared by lifecycle notifications
    /// and tests that need to validate foreground behavior without UIKit hooks.
    func runForegroundMaintenance() async {
        // Retry deferred ASA work using the current local app user ID.
        if let asaManager = self.asaManager {
            await asaManager.performAttributionIfNeeded()
            guard !Task.isCancelled else { return }
            await asaManager.flushPendingPurchaseEvents()
        }
        guard !Task.isCancelled else { return }

        // Always drain pending receipts on foreground
        if let processor = self.paymentProcessor {
            await processor.drainAll()
        }
        guard !Task.isCancelled else { return }

        // Only refresh customer info if cache is stale (>5 min)
        if let manager = self.customerManager,
           let userId = self.paymentStorage?.currentAppUserId {
            let fresh = await manager.isCustomerCacheFresh(appUserId: userId)
            if !fresh {
                _ = try? await self.getCustomerInfo()
                Log.sdk.debug("Foreground: customer cache stale — refreshed")
            } else {
                Log.sdk.debug("Foreground: customer cache fresh — skipped refresh")
            }
        }
    }

    // MARK: - Identify

    /// Identifies the current user with the payment backend for internal bootstrap flows.
    ///
    /// If no `app_user_id` is stored, generates an anonymous one.
    /// Sends device metadata for tracking.
    ///
    /// - Returns: The server-authoritative `AppActorCustomerInfo` with entitlements and subscriptions.
    @discardableResult
    func identify() async throws -> AppActorCustomerInfo {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let client = paymentClient, let storage = paymentStorage,
              paymentConfig != nil else {
            throw AppActorError.notConfigured
        }

        // Ensure IDs exist
        let currentId = storage.ensureAppUserId()

        // Ensure appAccountToken exists for StoreKit purchase binding
        storage.ensureAppAccountToken()

        let resolved = AppActorAutoDeviceInfo.resolve(
            override: nil,
            sdkVersion: AppActorSDK.version
        )

        let request = AppActorIdentifyRequest(
            appUserId: currentId,
            platform: resolved.platform,
            appVersion: resolved.appVersion,
            sdkVersion: resolved.sdkVersion,
            deviceLocale: resolved.deviceLocale,
            deviceModel: resolved.deviceModel,
            osVersion: resolved.osVersion,
            platformFlavor: paymentConfig?.options.platformFlavor,
            platformVersion: paymentConfig?.options.platformVersion
        )

        let result = try await client.identify(request)

        // Track request_id
        storage.setLastRequestId(result.requestId)

        // Server may normalize the app_user_id — overwrite if different
        if result.appUserId != currentId {
            storage.setAppUserId(result.appUserId)
        }

        // Seed customer cache with the snapshot from identify
        // so that subsequent calls can benefit from ETag/304 responses
        let verification = AppActorVerificationResult.from(signatureVerified: result.signatureVerified)
        let verifiedInfo = result.customerInfo.withVerification(verification)

        if let manager = customerManager {
            await manager.seedCache(info: verifiedInfo, eTag: result.customerETag, appUserId: result.appUserId, verified: result.signatureVerified)
        }

        self.paymentCurrentUser = verifiedInfo
        self.customerInfo = verifiedInfo
        Log.identity.debug("Identified as \(String(result.appUserId.prefix(8)))…")
        Log.identity.info("👤 Identity established")
        return verifiedInfo
    }

    // MARK: - Login

    /// Switches the identity to a new app user ID.
    ///
    /// Uses the stored local `current_app_user_id` directly.
    ///
    /// - Parameter newAppUserId: The new user identifier (e.g. your backend user ID).
    /// - Returns: The server-authoritative `AppActorCustomerInfo` with entitlements and subscriptions.
    /// - Throws: `AppActorError` with `.server` kind and 409 status if the ID belongs to another user.
    @discardableResult
    public func logIn(newAppUserId: String) async throws -> AppActorCustomerInfo {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let client = paymentClient, let storage = paymentStorage else {
            throw AppActorError.notConfigured
        }

        try AppActorPaymentValidation.validateAppUserId(newAppUserId)

        let currentId = storage.ensureAppUserId()

        let request = AppActorLoginRequest(
            currentAppUserId: currentId,
            newAppUserId: newAppUserId
        )

        // Buffer incoming transactions during identity transition to prevent wrong-user attribution.
        if let watcher = transactionWatcher {
            await watcher.beginIdentityTransition()
        }

        // Guarantee endIdentityTransition is called on ALL exit paths (success, error, cancellation).
        let loginResult: AppActorLoginResult
        do {
            // Wait for in-flight receipt POSTs to complete before identity transition.
            if let processor = paymentProcessor {
                await processor.drainAll()
            }

            // Clear user-specific caches before switching identity.
            if let etagMgr = paymentETagManager {
                await etagMgr.clear(.customer(appUserId: currentId))
            }
            if let rcManager = remoteConfigManager {
                await rcManager.clearCache(appUserId: currentId)
            }
            if let expManager = experimentManager {
                await expManager.clearCache(appUserId: currentId)
            }
            self.paymentRemoteConfigs = nil

            loginResult = try await client.login(request)
        } catch {
            // Flush buffered transactions with their captured (old) appUserId before rethrowing
            if let watcher = transactionWatcher {
                await watcher.endIdentityTransition()
            }
            throw error
        }

        // Track request_id
        storage.setLastRequestId(loginResult.requestId)

        // Overwrite local identity
        storage.setAppUserId(loginResult.appUserId)

        // Rotate appAccountToken for new identity
        storage.clearAppAccountToken()
        storage.ensureAppAccountToken()

        let loginVerification = AppActorVerificationResult.from(signatureVerified: loginResult.signatureVerified)
        let verifiedLoginInfo = loginResult.customerInfo.withVerification(loginVerification)

        // Seed customer cache with the snapshot from login
        if let manager = customerManager {
            await manager.seedCache(info: verifiedLoginInfo, eTag: loginResult.customerETag, appUserId: loginResult.appUserId, verified: loginResult.signatureVerified)
        }

        self.paymentCurrentUser = verifiedLoginInfo
        self.customerInfo = verifiedLoginInfo

        // End identity transition — flush buffered transactions with their captured appUserId
        if let watcher = transactionWatcher {
            await watcher.endIdentityTransition()
        }

        Log.identity.debug("Logged in as \(String(loginResult.appUserId.prefix(8)))…")
        Log.identity.info("👤 Login complete")
        return verifiedLoginInfo
    }

    // MARK: - Logout

    /// Logs out the current user and resets to an anonymous identity.
    ///
    /// 1. Generates a new anonymous `app_user_id`.
    /// 2. Clears user-scoped caches.
    /// 3. Rotates the appAccountToken for the new local identity.
    ///
    /// - Returns: `true` on success.
    @discardableResult
    public func logOut() async throws -> Bool {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        guard let storage = paymentStorage else {
            throw AppActorError.notConfigured
        }

        // Cannot logout an anonymous user — matches RevenueCat/Adapty behavior.
        // Prevents creating orphan anonymous users on the server.
        guard !isAnonymous else {
            throw AppActorError.validationError("logOut() called on an anonymous user. Use logIn() to switch identity.")
        }

        // Buffer incoming transactions during identity transition
        if let watcher = transactionWatcher {
            await watcher.beginIdentityTransition()
        }

        // Wait for in-flight receipt POSTs to complete before identity transition.
        // Prevents transaction loss when a receipt is being posted during logout.
        if let processor = paymentProcessor {
            await processor.drainAll()
        }

        // Clear user-specific caches on identity switch.
        // Offerings are project-level and preserved across identity changes.
        let currentId = storage.currentAppUserId ?? ""
        if let etagMgr = paymentETagManager {
            await etagMgr.clear(.customer(appUserId: currentId))
        }
        if let rcManager = remoteConfigManager {
            await rcManager.clearCache(appUserId: currentId)
        }
        if let expManager = experimentManager {
            await expManager.clearCache(appUserId: currentId)
        }
        self.paymentRemoteConfigs = nil

        // Rotate appAccountToken for the new local identity.
        storage.clearAppAccountToken()

        storage.generateAnonymousAppUserId()

        storage.ensureAppAccountToken()
        storage.clearLegacyIdentityState()
        self.paymentCurrentUser = nil
        self.customerInfo = .empty

        Log.identity.debug("Logged out. New anonymous ID: \(String((storage.currentAppUserId ?? "nil").prefix(8)))…")
        Log.identity.info("👤 Logout complete")

        // End identity transition — flush buffered transactions with their captured appUserId
        if let watcher = transactionWatcher {
            await watcher.endIdentityTransition()
        }

        return true
    }

    // MARK: - Reset

    /// Resets all payment state locally. **No server calls are made.**
    ///
    /// Clears:
    /// - Identity (`app_user_id`, `server_user_id`)
    /// - Disk cache (offerings + customer via ETagManager)
    /// - Last `request_id`
    /// - In-memory user, offerings, and managers
    ///
    /// After calling this, you must call ``AppActor.configure(apiKey:baseURL:headerMode:options:)``
    /// again before using any payment API.
    ///
    /// This is a **stronger** reset than ``logOut()``, which only switches to an anonymous
    /// user. Use this to fully wipe SDK state (e.g. for a "Reset" button in a test app).
    public func reset() async {
        // ── Phase 0: State transition ──
        paymentLifecycle = .resetting

        // ── Phase 1: Synchronous — runs before any suspension point ──
        // Remove lifecycle observers FIRST to close the race window where
        // a foreground notification fires during the await phase below and
        // spawns a new Task that writes back stale state.
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []

        // ── Phase 2: Cancel + await all tracked tasks ──
        // The ASA task runs independently after configure completes.
        // The foreground task runs ASA flush + sync + customer refresh.
        // Cancelling propagates to all children automatically (structured concurrency).
        // URLSession and Task.sleep respect cooperative cancellation, so
        // the await resolves quickly after cancel().
        asaTask?.cancel()
        foregroundTask?.cancel()
        stalenessTimerTask?.cancel()
        offeringsPrefetchTask?.cancel()
        await asaTask?.value
        await foregroundTask?.value
        await stalenessTimerTask?.value
        await offeringsPrefetchTask?.value
        asaTask = nil
        foregroundTask = nil
        stalenessTimerTask = nil
        offeringsPrefetchTask = nil

        // Stop transaction watcher and payment processor explicitly.
        // The supervisor started them but stop() requires deterministic await.
        await transactionWatcher?.stop()
        await paymentProcessor?.stop()
        transactionWatcher = nil
        paymentProcessor = nil
        paymentQueueStore = nil
        onReceiptPipelineEvent = nil

        // Stop purchase intent watcher (iOS 16.4+)
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            if let watcher = purchaseIntentWatcher as? AppActorPurchaseIntentWatcher {
                await watcher.stop()
            }
        }
        purchaseIntentWatcher = nil
        pendingPurchaseIntents.removeAll()
        _onPurchaseIntent = nil
        paymentContext.pendingProductCounts.removeAll()
        paymentContext.deferredPurchaseHandler = nil

        // ── Phase 3: Clear persisted + in-memory state ──
        if let storage = paymentStorage {
            storage.remove(forKey: AppActorPaymentStorageKey.appUserId)
            storage.remove(forKey: AppActorPaymentStorageKey.lastRequestId)
            storage.clearAppAccountToken()
            storage.setAsaAttributionCompleted(false)
            storage.clearAsaSentOriginalTransactionIds()
            storage.remove(forKey: AppActorPaymentStorageKey.asaInstallDate)
            storage.clearAsaTokenOnlyAttempts()
            storage.clearLegacyIdentityState()
        }

        await paymentETagManager?.clearAll()
        await offeringsManager?.clearCache()

        paymentCurrentUser = nil
        customerInfo = .empty
        paymentConfig = nil
        paymentClient = nil
        paymentStorage = nil
        paymentOfferings = nil
        paymentRemoteConfigs = nil
        paymentETagManager = nil

        offeringsManager = nil
        customerManager = nil
        remoteConfigManager = nil
        experimentManager = nil
        asaManager = nil

        AppActorAtomicJSONQueueStore.deletePersistedFile()
        AppActorASAFileEventStore.deletePersistedFile()

        // ── Phase 4: State transition complete ──
        isBootstrapComplete = false
        paymentLifecycle = .idle

        Log.sdk.info("Payment reset — call configure() to reconfigure")
    }

    // MARK: - Accessors

    /// The current `app_user_id` when the SDK is configured. Synchronous, no `await` needed.
    public nonisolated var appUserId: String? {
        guard AppActorPaymentContext._lifecycle == .configured else { return nil }
        return AppActorPaymentContext._storage?.currentAppUserId
    }

    /// Whether the current identity is anonymous. Defaults to `true` while not configured.
    public nonisolated var isAnonymous: Bool {
        guard AppActorPaymentContext._lifecycle == .configured else { return true }
        guard let id = AppActorPaymentContext._storage?.currentAppUserId else { return true }
        return id.hasPrefix("appactor-anon-")
    }

    /// The `request_id` from the last server response, for debugging.
    var lastPaymentRequestId: String? {
        paymentStorage?.lastRequestId
    }
}
