import Foundation
import AppActor

struct PurchasePackageRequest: AppActorPluginRequest {
    static let method = "purchase_package"

    let packageId: String
    let offeringId: String?
    let quantity: Int?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        guard let offerings = AppActor.shared.cachedOfferings else {
            throw AppActorPluginError(
                code: AppActorPluginError.sdkValidation,
                message: "Offerings not loaded. Call get_offerings first.")
        }

        let package: AppActorPackage?
        if let offeringId, let offering = offerings.offering(id: offeringId) {
            package = offering.packages.first { $0.id == packageId }
        } else {
            package = offerings.all.values.flatMap(\.packages).first { $0.id == packageId }
        }

        guard let package else {
            throw AppActorPluginError(
                code: AppActorPluginError.sdkValidation,
                message: "Package '\(packageId)' not found in cached offerings")
        }

        let result = try await AppActor.shared.purchase(package: package, quantity: quantity ?? 1)
        return .encoding(PluginPurchaseResult(from: result))
    }
}
