import Foundation

/// Callback-based API wrapper for hybrid frameworks (Flutter, React Native, Unity).
///
/// Converts the `async`/`await` API of ``AppActor`` into closure-based callbacks.
/// All callbacks are delivered on the main thread (MainActor).
///
/// ```swift
/// AppActorBridge.shared.configure(apiKey: "pk_YOUR_PUBLIC_API_KEY") {
///     print("SDK ready")
/// }
/// ```
///
/// **Design:** Mirrors the Android `AppActorBridge` object — same method names,
/// same callback pattern, same bridge-specific types (`AppActorBridgeError`,
/// `AppActorBridgeReceiptEvent`).
@MainActor
public final class AppActorBridge {

    // MARK: - Singleton

    public static let shared = AppActorBridge()
    private init() {}

    // MARK: - Synchronous Accessors (nonisolated)

    /// Whether the SDK has been configured.
    public nonisolated var isConfigured: Bool {
        AppActorPaymentContext._lifecycle == .configured
    }

    /// The current app user ID, or `nil` if not configured.
    public nonisolated var appUserId: String? {
        guard isConfigured else { return nil }
        return AppActor.shared.appUserId
    }

    /// Whether the current user is anonymous.
    public nonisolated var isAnonymous: Bool {
        guard isConfigured else { return true }
        return AppActor.shared.isAnonymous
    }

    /// The most recently cached remote configs, or `nil` if not fetched yet.
    public nonisolated var cachedRemoteConfigs: AppActorRemoteConfigs? {
        AppActor.shared.cachedRemoteConfigs
    }

    /// Synchronous remote config lookup by key.
    public nonisolated func getRemoteConfig(_ key: String) -> AppActorConfigValue? {
        AppActor.shared.getRemoteConfig(key)
    }

    public nonisolated func getRemoteConfigBool(_ key: String) -> Bool? {
        AppActor.shared.getRemoteConfigBool(key)
    }

    public nonisolated func getRemoteConfigString(_ key: String) -> String? {
        AppActor.shared.getRemoteConfigString(key)
    }

    public nonisolated func getRemoteConfigNumber(_ key: String) -> Double? {
        AppActor.shared.getRemoteConfigNumber(key)
    }

    public nonisolated func getRemoteConfigInt(_ key: String) -> Int? {
        AppActor.shared.getRemoteConfigInt(key)
    }

    // MARK: - Synchronous Accessors (@MainActor)

    /// The current customer info snapshot. Starts as `.empty`.
    public var cachedCustomerInfo: AppActorCustomerInfo {
        AppActor.shared.customerInfo
    }

    /// The most recently cached offerings, or `nil` if not fetched yet.
    public var cachedOfferings: AppActorOfferings? {
        AppActor.shared.cachedOfferings
    }

    // MARK: - Configuration

    /// Configures the SDK with the given API key.
    ///
    /// - Parameters:
    ///   - apiKey: Your AppActor API key (e.g. `"pk_YOUR_PUBLIC_API_KEY"`).
    ///   - options: Optional configuration options.
    ///   - onComplete: Called on the main thread when configuration finishes.
    ///   - onError: Called with an ``AppActorBridgeError`` when validation fails.
    public func configure(
        apiKey: String,
        options: AppActorOptions = .init(),
        onComplete: (() -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        if let validationError = AppActorPaymentConfiguration.validationError(apiKey: apiKey) {
            Log.sdk.error("Bridge configure validation failed: \(validationError.localizedDescription)")
            onError?(AppActorBridgeError(from: validationError))
            return
        }

        Task { @MainActor in
            await AppActor.configure(apiKey: apiKey, options: options)
            onComplete?()
        }
    }

    /// Resets the SDK to its initial state.
    ///
    /// - Parameter onComplete: Called on the main thread when reset finishes.
    public func reset(onComplete: (() -> Void)? = nil) {
        Task { @MainActor in
            clearListeners()
            await AppActor.shared.reset()
            onComplete?()
        }
    }

    // MARK: - ASA

    /// Enables Apple Search Ads attribution tracking.
    ///
    /// Must be called after `configure()` has completed.
    ///
    /// - Parameters:
    ///   - options: ASA configuration. Default values enable auto-tracking.
    ///   - onSuccess: Called on the main thread when ASA setup finishes.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func enableAppleSearchAdsTracking(
        options: AppActorASAOptions = .init(),
        onSuccess: (() -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        Task { @MainActor in
            do {
                try AppActor.shared.enableAppleSearchAdsTracking(options: options)
                onSuccess?()
            } catch {
                onError?(AppActorBridgeError(from: error))
            }
        }
    }

    // MARK: - Identity

    /// Logs in with a custom app user ID.
    ///
    /// - Parameters:
    ///   - newAppUserId: The user ID to log in with.
    ///   - onSuccess: Called with the updated customer info on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func logIn(
        newAppUserId: String,
        onSuccess: ((AppActorCustomerInfo) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.logIn(newAppUserId: newAppUserId)
        }
    }

    /// Logs out the current user, reverting to an anonymous ID.
    ///
    /// - Parameters:
    ///   - onSuccess: Called with `true` on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func logOut(
        onSuccess: ((Bool) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.logOut()
        }
    }

    // MARK: - Customer Info

    /// Fetches the latest customer info from the server.
    ///
    /// - Parameters:
    ///   - onSuccess: Called with the customer info on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func getCustomerInfo(
        onSuccess: ((AppActorCustomerInfo) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.getCustomerInfo()
        }
    }

    /// Derives active entitlement keys offline using StoreKit 2 transactions.
    ///
    /// - Parameter onSuccess: Called with the set of active entitlement keys.
    public func activeEntitlementKeysOffline(
        onSuccess: ((Set<String>) -> Void)? = nil
    ) {
        Task { @MainActor in
            let keys = await AppActor.shared.activeEntitlementKeysOffline()
            onSuccess?(keys)
        }
    }

    // MARK: - Offerings

    /// Fetches offerings from the server.
    ///
    /// - Parameters:
    ///   - onSuccess: Called with the offerings on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func getOfferings(
        onSuccess: ((AppActorOfferings) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.offerings()
        }
    }

    /// Sets bundled fallback offerings for first-launch offline scenarios.
    ///
    /// - Parameter jsonData: JSON data containing an offerings response DTO.
    /// - Parameter onError: Called if the JSON data is invalid.
    public func setFallbackOfferings(
        jsonData: Data,
        onSuccess: (() -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: { (_: Void) in onSuccess?() }, onError: onError) {
            try await AppActor.shared.setFallbackOfferings(jsonData: jsonData)
        }
    }

    // MARK: - Purchases

    /// Purchases a product from a package.
    ///
    /// - Parameters:
    ///   - package: The ``AppActorPackage`` to purchase.
    ///   - onSuccess: Called with the purchase result on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func purchasePackage(
        package: AppActorPackage,
        quantity: Int = 1,
        onSuccess: ((AppActorPurchaseResult) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.purchase(package: package, quantity: quantity)
        }
    }

    // MARK: - Restore & Sync

    /// Restores purchases from the App Store.
    ///
    /// - Parameters:
    ///   - syncWithAppStore: Whether to also sync with the App Store (default: `false`).
    ///   - onSuccess: Called with the updated customer info on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func restorePurchases(
        syncWithAppStore: Bool = false,
        onSuccess: ((AppActorCustomerInfo) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.restorePurchases(syncWithAppStore: syncWithAppStore)
        }
    }

    /// Syncs purchases from previous sessions.
    ///
    /// - Parameters:
    ///   - onSuccess: Called with the updated customer info on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func syncPurchases(
        onSuccess: ((AppActorCustomerInfo) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.syncPurchases()
        }
    }

    // MARK: - Remote Config

    /// Fetches remote configs from the server.
    ///
    /// - Parameters:
    ///   - onSuccess: Called with the remote configs on success.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func getRemoteConfigs(
        onSuccess: ((AppActorRemoteConfigs) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.getRemoteConfigs()
        }
    }

    // MARK: - Experiments

    /// Fetches an experiment assignment for the given key.
    ///
    /// - Parameters:
    ///   - experimentKey: The experiment key.
    ///   - onSuccess: Called with the assignment (or `nil` if not assigned).
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    public func getExperimentAssignment(
        experimentKey: String,
        onSuccess: ((AppActorExperimentAssignment?) -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        launchAsync(onSuccess: onSuccess, onError: onError) {
            try await AppActor.shared.getExperimentAssignment(experimentKey: experimentKey)
        }
    }

    // MARK: - Offer Code Redemption (iOS 16+)

    /// Presents the App Store offer code redemption sheet.
    ///
    /// - Parameters:
    ///   - onComplete: Called when the sheet is dismissed.
    ///   - onError: Called with an ``AppActorBridgeError`` on failure.
    @available(iOS 16.0, macOS 14.0, *)
    public func presentOfferCodeRedeemSheet(
        onComplete: (() -> Void)? = nil,
        onError: ((AppActorBridgeError) -> Void)? = nil
    ) {
        Task { @MainActor in
            do {
                try await AppActor.shared.presentOfferCodeRedeemSheet()
                onComplete?()
            } catch {
                onError?(AppActorBridgeError(from: error))
            }
        }
    }

    // MARK: - Listener Management

    private var currentCustomerInfoListener: ((AppActorCustomerInfo) -> Void)?
    private var currentReceiptPipelineListener: ((AppActorBridgeReceiptEvent) -> Void)?
    private var currentDeferredPurchaseListener: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)?

    /// The currently set customer info listener, or `nil` if none.
    public var customerInfoListener: ((AppActorCustomerInfo) -> Void)? {
        currentCustomerInfoListener
    }

    /// The currently set receipt pipeline listener, or `nil` if none.
    public var receiptPipelineListener: ((AppActorBridgeReceiptEvent) -> Void)? {
        currentReceiptPipelineListener
    }

    /// The currently set deferred purchase listener, or `nil` if none.
    public var deferredPurchaseListener: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)? {
        currentDeferredPurchaseListener
    }

    /// Sets a listener that fires whenever customer info changes.
    ///
    /// Replaces any previously set listener. Pass `nil` to remove.
    ///
    /// - Parameter listener: The callback, or `nil` to remove.
    public func setCustomerInfoListener(
        _ listener: ((AppActorCustomerInfo) -> Void)?
    ) {
        currentCustomerInfoListener = listener
        AppActor.shared.onCustomerInfoChanged = listener
    }

    /// Sets a listener that fires on receipt pipeline events.
    ///
    /// Events are automatically converted to ``AppActorBridgeReceiptEvent``
    /// for easy serialization. Pass `nil` to remove.
    ///
    /// - Parameter listener: The callback, or `nil` to remove.
    public func setReceiptPipelineListener(
        _ listener: ((AppActorBridgeReceiptEvent) -> Void)?
    ) {
        currentReceiptPipelineListener = listener
        if let listener {
            AppActor.shared.onReceiptPipelineEvent = { detail in
                listener(AppActorBridgeReceiptEvent(from: detail))
            }
        } else {
            AppActor.shared.onReceiptPipelineEvent = nil
        }
    }

    /// Sets a listener for deferred (Ask to Buy / SCA) purchase resolutions.
    ///
    /// Fires when a previously `.pending` purchase resolves via `Transaction.updates`.
    /// Pass `nil` to remove.
    public func setDeferredPurchaseListener(
        _ listener: ((_ productId: String, _ customerInfo: AppActorCustomerInfo) -> Void)?
    ) {
        currentDeferredPurchaseListener = listener
        AppActor.shared.onDeferredPurchaseResolved = listener
    }

    /// Removes all listeners and clears the underlying AppActor callbacks.
    public func clearListeners() {
        currentCustomerInfoListener = nil
        currentReceiptPipelineListener = nil
        currentDeferredPurchaseListener = nil
        AppActor.shared.onCustomerInfoChanged = nil
        AppActor.shared.onReceiptPipelineEvent = nil
        AppActor.shared.onDeferredPurchaseResolved = nil
    }

    // MARK: - Private: Async-to-Callback Conversion

    /// Wraps an async throwing operation into a callback-based call.
    ///
    /// The operation runs on `@MainActor`. On success, `onSuccess` is called
    /// with the result. On failure, the error is converted to ``AppActorBridgeError``
    /// and delivered via `onError`. Both callbacks execute on the main thread.
    private func launchAsync<T>(
        onSuccess: ((T) -> Void)?,
        onError: ((AppActorBridgeError) -> Void)?,
        operation: @escaping @MainActor () async throws -> T
    ) {
        Task { @MainActor in
            do {
                let result = try await operation()
                onSuccess?(result)
            } catch {
                onError?(AppActorBridgeError(from: error))
            }
        }
    }
}
