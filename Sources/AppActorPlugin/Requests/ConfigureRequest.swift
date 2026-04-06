import Foundation
@_spi(AppActorPluginSupport) import AppActor

struct ConfigureRequest: AppActorPluginRequest {
    static let method = "configure"

    let apiKey: String
    let logLevel: String?
    let platformFlavor: String?
    let platformVersion: String?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let config = AppActorPaymentConfiguration(apiKey: apiKey)
        if let validationError = config.validationError {
            throw AppActorPluginError(from: validationError)
        }

        var options = AppActorOptions()
        if let logLevel {
            options.logLevel = AppActorLogLevel(stringLiteral: logLevel)
        }
        options.platformFlavor = platformFlavor
        options.platformVersion = platformVersion
        await AppActor.configure(apiKey: apiKey, options: options)
        return .successVoid
    }
}
