import Foundation
import AppActor

struct PresentOfferCodeRequest: AppActorPluginRequest {
    static let method = "present_offer_code_redeem_sheet"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        try await AppActor.shared.presentOfferCodeRedeemSheet()
        return .successVoid
    }
}
