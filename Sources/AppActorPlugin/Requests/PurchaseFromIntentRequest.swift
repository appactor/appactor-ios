import Foundation
import AppActor

@available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *)
struct PurchaseFromIntentRequest: AppActorPluginRequest {
    static let method = "purchase_from_intent"

    let intentId: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let intent = PurchaseIntentStore.shared.remove(intentId) else {
            throw AppActorPluginError(
                code: AppActorPluginError.sdkValidation,
                message: "Purchase intent '\(intentId)' not found or already consumed."
            )
        }
        let result = try await AppActor.shared.purchase(intent: intent)
        return .encoding(PluginPurchaseResult(from: result))
    }
}
