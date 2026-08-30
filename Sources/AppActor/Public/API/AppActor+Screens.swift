import Foundation
import StoreKit

// MARK: - Server-driven screens

extension AppActor {

    /// Presents a server-driven screen and returns when it closes.
    ///
    /// The screen is a JSON document you publish from the dashboard, rendered
    /// on device in a `WKWebView`. Nothing about the layout ships in your app,
    /// so a paywall change is a publish rather than a release. Purchases,
    /// restores and dismissal come back through this SDK — the screen has no
    /// network of its own.
    ///
    /// ```swift
    /// switch try await AppActor.shared.presentScreen("paywall_main") {
    /// case .purchased:  unlockPremium()
    /// case .restored:   unlockPremium()
    /// case .dismissed:  break
    /// }
    /// ```
    ///
    /// The document is read from remote config, so it is available offline once
    /// it has been fetched: on a network failure the SDK serves the disk-cached
    /// copy and the screen still opens. What is *not* cached is the App Store
    /// price, so a first launch in airplane mode has no packages to render and
    /// this throws rather than showing a paywall with blank prices.
    ///
    /// Presentation waits for the screen's first paint before revealing it, and
    /// gives up if that never arrives. A screen that cannot render throws
    /// instead of showing a blank sheet, which is what makes it safe to keep a
    /// hard-coded paywall as your fallback:
    ///
    /// ```swift
    /// do    { try await AppActor.shared.presentScreen("paywall_main") }
    /// catch { presentBundledPaywall() }
    /// ```
    ///
    /// - Parameter lookupKey: The screen's key, as published. Lowercase
    ///   letters, digits, `_` and `-`.
    /// - Returns: How the screen ended.
    /// - Throws: ``AppActorError`` when the SDK is not configured, the document
    ///   is missing or unusable, no packages could be priced, or the screen
    ///   failed to render.
    @discardableResult
    public func presentScreen(_ lookupKey: String) async throws -> AppActorScreenOutcome {
        #if canImport(UIKit) && canImport(WebKit) && !os(watchOS) && !os(tvOS)
        guard paymentLifecycle == .configured else { throw AppActorError.notConfigured }

        // Checked here rather than left to fail later: the key becomes a path
        // component of the page's origin, and a key with a space in it turns
        // into an unbuildable URL two layers down, where the error no longer
        // names what the caller got wrong.
        guard AppActorScreenDocument.isValidLookupKey(lookupKey) else {
            throw AppActorError.notAvailable(
                "\"\(lookupKey)\" is not a valid screen key: lowercase letters, digits, \"_\" and \"-\", 3-64 characters, no leading or trailing separator."
            )
        }

        // One at a time, claimed *before* the first suspension: MainActor
        // isolation serialises the check but not the awaits after it, so two
        // calls in the same turn would both read nil and both present.
        if let existing = paymentContext.presentedScreenLookupKey {
            throw AppActorError.notAvailable("A screen (\(existing)) is already being presented.")
        }
        paymentContext.presentedScreenLookupKey = lookupKey
        defer { paymentContext.presentedScreenLookupKey = nil }

        let document = try await loadScreenDocument(lookupKey: lookupKey)
        let (packages, payloads) = try await resolveScreenPackages(for: document)

        guard let presenter = AppActorScreenPresenter.topViewController() else {
            throw AppActorError.notAvailable("No view controller is available to present from.")
        }

        let adapter = AppActorScreenPurchaseAdapter(lookupKey: lookupKey, packages: packages)
        let handler = paymentContext.screenEventHandler

        let controller = AppActorScreenViewController(
            document: document,
            packages: payloads,
            gateway: adapter,
            locale: Self.bcp47Locale(),
            onEvent: handler
        )

        if !document.assetRefs.isEmpty {
            // No asset host exists to point `assetBase` at yet, so name the
            // refs that will not appear rather than shipping a screen with
            // holes in it and reporting success.
            Log.screens.error(
                "Screen \(lookupKey) uses \(document.assetRefs.count) uploaded image(s) that cannot be shown: this SDK has no asset base to resolve them against, so they will render as nothing. Use absolute https URLs until asset hosting ships. Refs: \(document.assetRefs.joined(separator: ", "))"
            )
        }

        Log.screens.info("📄 Presenting screen \(lookupKey) (runtime \(AppActorScreenRuntimeAsset.version), \(payloads.count) packages)")

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<AppActorScreenOutcome, Never>) in
            // Armed *before* presenting: `present` loads the view
            // synchronously, so `viewDidLoad` can fail and finish first.
            controller.onFinished = { outcome in continuation.resume(returning: outcome) }
            presenter.present(controller, animated: false)

            // UIKit silently refuses a presentation when the presenter is
            // already presenting: `viewDidLoad` never runs, so nothing is left
            // to resume this continuation and the caller would hang for the
            // life of the process. `presentedViewController` is set
            // synchronously when UIKit accepts.
            if presenter.presentedViewController !== controller {
                controller.failToRender("the presenting view controller refused it; it is already presenting something else")
            }
        }

        if case .dismissed = outcome, controller.failedToRender {
            throw AppActorError.notAvailable("Screen \"\(lookupKey)\" did not render.")
        }
        return outcome
        #else
        throw AppActorError.notAvailable("Screens require UIKit and WebKit.")
        #endif
    }

    /// Analytics from presented screens.
    ///
    /// Fires for `impression`, `screen_view`, `cta_tap`, `purchase_started`,
    /// `purchase_completed`, `purchase_cancelled`, `dismiss`, `fallback_shown`
    /// and `slow_first_paint`. The names are a frozen list —
    /// `purchase_completed` in particular is tied to historical revenue
    /// attribution — so new ones may be added but none is ever renamed.
    ///
    /// ```swift
    /// AppActor.shared.onScreenEvent = { event in
    ///     analytics.track(event.name, properties: event.properties)
    /// }
    /// ```
    public var onScreenEvent: ((AppActorScreenEvent) -> Void)? {
        get { paymentContext.screenEventHandler }
        set { paymentContext.screenEventHandler = newValue }
    }

    // MARK: - Document

    /// The device locale as a BCP 47 tag. `Locale.current.identifier` is ICU
    /// (`en_US`) and the frozen contract says BCP 47 (`en-US`). Nothing reads
    /// it yet, which is why it has to be right now: the first
    /// `new Intl.NumberFormat(state.locale)` would throw on every non-`en`
    /// device, and Android sends the other spelling.
    private static func bcp47Locale() -> String {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            return Locale.current.identifier(.bcp47)
        }
        return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    private func loadScreenDocument(lookupKey: String) async throws -> AppActorScreenDocument {
        let key = AppActorScreenDocument.remoteConfigKey(for: lookupKey)

        // Already in memory from an earlier `getRemoteConfigs()`: no round trip
        // on the path to first paint.
        if let cached = getRemoteConfig(key) {
            return try parseScreenDocument(cached, lookupKey: lookupKey)
        }

        // Otherwise fetch. This is also the airplane-mode path: the remote
        // config manager falls back to its disk cache on a network error or a
        // 5xx, so a screen fetched once stays openable with no connection.
        let configs = try await getRemoteConfigs()
        return try parseScreenDocument(configs[key], lookupKey: lookupKey)
    }

    private func parseScreenDocument(
        _ value: AppActorConfigValue?,
        lookupKey: String
    ) throws -> AppActorScreenDocument {
        do {
            return try AppActorScreenDocument.parse(value, lookupKey: lookupKey)
        } catch let error as AppActorScreenDocumentError {
            Log.screens.error("Screen \(lookupKey): \(error.message)")
            throw AppActorError.notAvailable(error.message)
        }
    }

    // MARK: - Packages

    /// Prices only the packages the document names: a screen showing three of
    /// an offering's nine should not wait on six lookups it will not display.
    /// When it names none, the current offering is used — a lone "start trial"
    /// button still needs something selected.
    private func resolveScreenPackages(
        for document: AppActorScreenDocument
    ) async throws -> ([AppActorPackage], [[String: Any]]) {
        let offerings = try await offerings(fetchPolicy: .returnCachedThenRefresh)

        let everyPackage = offerings.allOfferings.flatMap(\.packages)
        let wanted: [AppActorPackage]
        if document.packageIds.isEmpty {
            wanted = offerings.current?.packages ?? everyPackage
        } else {
            // Document order, not offering order: the runtime selects the first
            // package the document lays out when nothing else is chosen.
            let byId = Dictionary(everyPackage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            wanted = document.packageIds.compactMap { byId[$0] }
        }

        guard !wanted.isEmpty else {
            // Two different failures, and the difference is what the caller has
            // to fix: a screen naming packages that do not exist is a publishing
            // mistake, an empty offering is a catalog one.
            if document.packageIds.isEmpty {
                throw AppActorError.notAvailable(
                    "Screen \"\(document.lookupKey)\" names no packages and no offering has any to fall back on."
                )
            }
            throw AppActorError.notAvailable(
                "Screen \"\(document.lookupKey)\" names \(document.packageIds.count) package(s), none of which are in your offerings: \(document.packageIds.joined(separator: ", "))."
            )
        }

        var products: [String: Product] = [:]
        if let manager = offeringsManager {
            let identifiers = Set(wanted.map { $0.storeProductId ?? $0.productId })
            // A StoreKit outage should not take the screen with it: the document
            // may not interpolate a single price. What it must not do is show a
            // paywall with the price silently missing, which is why the
            // packages themselves still have to resolve above.
            products = (try? await manager.storeKitProducts(for: identifiers)) ?? [:]
            if products.isEmpty {
                Log.screens.warn("Screen \(document.lookupKey): StoreKit returned no products; prices will be the cached ones")
            }
        }

        let pairs = wanted.map { (package: $0, product: products[$0.storeProductId ?? $0.productId]) }
        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(pairs.count)
        for pair in pairs {
            payloads.append(await AppActorScreenPackagePayload.make(package: pair.package, product: pair.product))
        }

        payloads = AppActorScreenPackagePayload.attachDiscounts(
            to: payloads,
            comparisons: document.comparisons,
            dailyRates: AppActorScreenPackagePayload.dailyRates(for: pairs)
        )

        return (wanted, payloads)
    }
}
