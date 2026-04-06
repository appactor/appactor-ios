import Foundation
import StoreKit

// MARK: - Offer Code Redemption

extension AppActor {

    /// Presents the system offer code redemption sheet.
    ///
    /// The native StoreKit sheet handles code validation. On successful redemption,
    /// `Transaction.updates` delivers the new transaction automatically —
    /// `TransactionWatcher` handles the rest.
    ///
    /// An explicit `customerInfo(forceRefresh: true)` is triggered after the sheet
    /// dismisses to ensure the caller receives updated entitlements.
    ///
    /// - Important: Only available on iOS 16.0+. Throws ``AppActorError/notAvailable(_:)``
    ///   on unsupported platforms (macOS, tvOS, watchOS).
    /// - Throws: ``AppActorError`` if the SDK is not configured or the platform does
    ///   not support offer code sheets, or a StoreKit error if the sheet fails.
    @available(iOS 16.0, *)
    public func presentOfferCodeRedeemSheet() async throws {
        guard paymentLifecycle == .configured else {
            throw AppActorError.notConfigured
        }
        #if canImport(UIKit) && !os(tvOS) && !os(watchOS)
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            throw AppActorError.notAvailable("No active UIWindowScene found")
        }
        try await AppStore.presentOfferCodeRedeemSheet(in: scene)
        // Transaction.updates fires on successful redemption — TransactionWatcher handles it.
        // Force-refresh customer info so caller gets updated entitlements.
        _ = try? await getCustomerInfo()
        #else
        throw AppActorError.notAvailable("Offer code redemption sheet is not supported on this platform")
        #endif
    }
}
