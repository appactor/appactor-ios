import Foundation
import AppActor

struct SetFallbackOfferingsRequest: AppActorPluginRequest {
    static let method = "set_fallback_offerings"

    let jsonData: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let data = Data(base64Encoded: jsonData) else {
            throw AppActorPluginError(
                code: AppActorPluginError.sdkValidation,
                message: "Invalid base64-encoded JSON data for fallback offerings")
        }
        try await AppActor.shared.setFallbackOfferings(jsonData: data)
        return .successVoid
    }
}
