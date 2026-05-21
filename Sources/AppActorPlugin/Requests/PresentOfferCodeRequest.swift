import Foundation
import AppActor

struct PresentOfferCodeRequest: AppActorPluginRequest {
    static let method = "present_offer_code_redeem_sheet"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        if #available(iOS 16.0, *) {
            try await AppActor.shared.presentOfferCodeRedeemSheet()
            return .successVoid
        } else {
            throw AppActorError.notAvailable("presentOfferCodeRedeemSheet requires iOS 16+")
        }
    }
}
