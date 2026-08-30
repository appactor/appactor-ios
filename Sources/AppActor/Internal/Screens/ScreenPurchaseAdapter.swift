import Foundation
import StoreKit

/// Turns the screen's four-state purchase contract into SDK calls, and the
/// SDK's answers back into the four states.
///
/// The translation is not mechanical in one place: the wire format's
/// `server_confirmed` has no direct counterpart in ``AppActorPurchaseResult``,
/// and it is the field the whole contract exists for.
@MainActor
final class AppActorScreenPurchaseAdapter: AppActorScreenPurchaseGateway {

    /// How long to wait for a queued receipt before giving up and saying so.
    ///
    /// Comfortably inside the runtime's own confirmation timer, so when this
    /// gives up the runtime is still listening and the screen releases its
    /// controls on a decision rather than on a timeout at both ends.
    private static let confirmationWindow: TimeInterval = 30
    private static let pollInterval: TimeInterval = 1.5

    private let lookupKey: String
    private let packagesById: [String: AppActorPackage]

    init(lookupKey: String, packages: [AppActorPackage]) {
        self.lookupKey = lookupKey
        self.packagesById = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Purchase

    func purchase(packageId: String) async -> AppActorScreenPurchaseOutcome {
        guard let package = packagesById[packageId] else {
            Log.screens.error("Screen \(lookupKey) asked to buy \(packageId), which is not in its offering")
            return .failed("That option is no longer available.")
        }

        do {
            // `placement` is the screen's lookup key. It travels with the
            // receipt into revenue attribution, which is also why the key is
            // immutable once published.
            let result = try await AppActor.shared.purchase(package: package, quantity: 1, placement: lookupKey)

            switch result {
            case .success(let customerInfo, let purchaseInfo):
                // Rule #13. `.success` alone does not mean the server agreed:
                // when the receipt POST does not come back in time the SDK
                // computes entitlements from StoreKit and returns success
                // anyway, with the receipt still queued. `isComputedOffline` is
                // that state, and reporting it as `completed` with no
                // qualification is how a screen ends up saying "Premium
                // active" over a receipt that never posts.
                let confirmed = !customerInfo.isComputedOffline
                return .completed(
                    serverConfirmed: confirmed,
                    transactionId: confirmed ? nil : purchaseInfo?.transactionId
                )
            case .cancelled:
                return .cancelled
            case .pending:
                // Ask to Buy / SCA. Approval can arrive days later, and the
                // screen stays open and locked until it does.
                return .pending
            }
        } catch let error as AppActorError {
            Log.screens.error("Screen \(lookupKey) purchase failed: \(error.kind.rawValue) \(error.message ?? "")")
            return .failed(userFacing(error))
        } catch {
            Log.screens.error("Screen \(lookupKey) purchase failed: \(error.localizedDescription)")
            return .failed("Something went wrong. Please try again.")
        }
    }

    // MARK: - Restore

    func restore() async -> AppActorScreenRestoreOutcome {
        do {
            let info = try await AppActor.shared.restorePurchases()
            // "Restored" means the user got something back. An empty result is
            // not a failure -- there was simply nothing to restore, and the
            // runtime has a distinct message for it so the user is not left
            // reading "Something went wrong" after a correct answer.
            return info.activeEntitlements.isEmpty && info.nonSubscriptions.isEmpty
                ? .nothingToRestore
                : .restored
        } catch let error as AppActorError {
            Log.screens.error("Screen \(lookupKey) restore failed: \(error.kind.rawValue)")
            return .failed(userFacing(error))
        } catch {
            Log.screens.error("Screen \(lookupKey) restore failed: \(error.localizedDescription)")
            return .failed("Could not restore purchases. Please try again.")
        }
    }

    // MARK: - Confirmation follow-up

    /// Waits out a receipt that was still queued when the purchase returned.
    ///
    /// Two signals, because neither alone is enough:
    ///
    /// 1. **The receipt queue**, polled until the item leaves it. A dead-lettered
    ///    item is a definite rejection. An item that simply disappears is
    ///    *usually* a successful post -- but the server answering
    ///    `permanent_error` with `finishTransaction: true` also removes it, so
    ///    disappearing is not by itself proof of anything.
    /// 2. **The server**, asked once at the end. Whether the entitlement this
    ///    product grants is actually active is the only answer that settles
    ///    case (1)'s ambiguity, and it is the same answer the user's app will
    ///    act on tomorrow.
    ///
    /// Anything left undecided returns `.unknown` and nothing is sent. Claiming
    /// "failed" over a receipt that may well post a minute later is worse than
    /// letting the runtime release its own controls on its own timer.
    func awaitServerConfirmation(transactionId: String) async -> AppActorScreenConfirmation {
        guard let store = AppActor.shared.paymentContext.paymentQueueStore else { return .unknown }

        // Read the product now, while the receipt is still queued. Once the
        // pipeline finishes with the item it is removed, and the whole reason
        // for asking the server below is that the item is gone.
        let productId = store.snapshot().first { $0.transactionId == transactionId }?.productId

        let deadline = Date().addingTimeInterval(Self.confirmationWindow)
        var stillQueued = true

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            if Task.isCancelled { return .unknown }

            guard let item = store.snapshot().first(where: { $0.transactionId == transactionId }) else {
                stillQueued = false
                break
            }
            if item.phase == .deadLettered {
                Log.screens.error("Screen \(lookupKey): receipt \(transactionId) dead-lettered — \(item.lastError ?? "no detail")")
                return .failed("We could not confirm your purchase. Contact support if you were charged.")
            }
        }

        guard !stillQueued else { return .unknown }

        // The receipt left the queue. Ask the server what it thinks happened.
        guard let info = try? await AppActor.shared.getCustomerInfo(), !info.isComputedOffline else {
            return .unknown
        }

        // Prefer the product → entitlement mapping when the server sent one:
        // it answers for this purchase rather than for the account in general.
        if let productId, let granted = info.productEntitlements?[productId] {
            let active = info.activeEntitlementKeys
            if granted.contains(where: active.contains) { return .confirmed }
            Log.screens.error("Screen \(lookupKey): server confirmed no entitlement for \(productId)")
            return .failed("We could not confirm your purchase. Contact support if you were charged.")
        }

        // No mapping available -- an older server, a product that grants no
        // entitlement at all (a consumable, a token pack), or a receipt that
        // was already gone from the queue when this started. The item reached a
        // terminal state without dead-lettering and the server answered, so the
        // pipeline is done with it.
        return .confirmed
    }

    // MARK: - Messages

    /// Screen-facing copy for an SDK error.
    ///
    /// Deliberately not `error.localizedDescription`: those carry HTTP codes and
    /// internal identifiers, and this string goes on a paywall.
    private func userFacing(_ error: AppActorError) -> String {
        switch error.kind {
        case .network:
            return "No connection. Check your network and try again."
        case .productNotAvailableInStorefront:
            return "This option is not available in your region."
        case .purchaseIneligible, .invalidOffer:
            return "You are not eligible for this offer."
        case .purchaseAlreadyInProgress:
            return "A purchase is already in progress."
        case .receiptQueuedForRetry:
            return "Your purchase went through. We are still confirming it."
        case .storeKitProductsMissing:
            return "This option is temporarily unavailable."
        default:
            return "Something went wrong. Please try again."
        }
    }
}
