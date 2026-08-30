import Foundation

@testable import AppActor

/// The one stand-in for ``AppActorScreenPurchaseGateway``.
///
/// It lives here rather than beside either suite because one of its two callers
/// (`ScreenWebViewIntegrationTests`) only compiles where UIKit and WebKit exist,
/// so a copy kept next to that suite is a copy a macOS `swift test` never
/// builds -- and a protocol change would then break it silently, on the lane
/// nobody runs. `AppActorScreenPurchaseGateway` itself is declared
/// unconditionally, so this file needs no availability fence.
@MainActor
final class FakeScreenPurchaseGateway: AppActorScreenPurchaseGateway {
    var purchaseOutcome: AppActorScreenPurchaseOutcome = .cancelled
    var restoreOutcome: AppActorScreenRestoreOutcome = .nothingToRestore
    var confirmation: AppActorScreenConfirmation = .unknown

    /// Holds the purchase open so a test can inject messages while the runtime
    /// still has a request in flight.
    var stall = false

    private(set) var purchasedPackageIds: [String] = []
    private(set) var confirmedTransactionIds: [String] = []

    func purchase(packageId: String) async -> AppActorScreenPurchaseOutcome {
        purchasedPackageIds.append(packageId)
        while stall {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return purchaseOutcome
    }

    func restore() async -> AppActorScreenRestoreOutcome { restoreOutcome }

    func awaitServerConfirmation(transactionId: String) async -> AppActorScreenConfirmation {
        confirmedTransactionIds.append(transactionId)
        return confirmation
    }
}
