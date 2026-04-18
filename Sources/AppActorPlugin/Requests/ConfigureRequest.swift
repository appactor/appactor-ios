import Foundation
@_spi(AppActorPluginSupport) import AppActor

struct ConfigureRequest: AppActorPluginRequest {
    static let method = "configure"

    let apiKey: String
    let options: OptionsPayload?
    let logLevel: String?
    let platformFlavor: String?
    let platformVersion: String?
    let platformInfo: PlatformInfo?

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let config = AppActorPaymentConfiguration(apiKey: apiKey)
        if let validationError = config.validationError {
            throw AppActorPluginError(from: validationError)
        }

        let options = resolvedOptions()
        await AppActor.configure(apiKey: apiKey, options: options)
        return .successVoid
    }

    func resolvedOptions() -> AppActorOptions {
        var resolved = AppActorOptions()
        let resolvedLogLevel = options?.logLevel ?? logLevel
        if let resolvedLogLevel {
            resolved.logLevel = AppActorLogLevel(stringLiteral: resolvedLogLevel)
        }
        resolved.platformInfo = resolvedPlatformInfo()
        return resolved
    }

    private func resolvedPlatformInfo() -> AppActorPlatformInfo? {
        let canonicalFlavor = options?.platformInfo?.flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nestedFlavor = platformInfo?.flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyFlavor = platformFlavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFlavor = [canonicalFlavor, nestedFlavor, legacyFlavor]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .first
        let resolvedVersion = options?.platformInfo?.version ?? platformInfo?.version ?? platformVersion

        if let resolvedFlavor {
            return AppActorPlatformInfo(flavor: resolvedFlavor, version: resolvedVersion)
        }
        if let resolvedVersion {
            return AppActorPlatformInfo(flavor: "flutter", version: resolvedVersion)
        }
        return nil
    }

    struct PlatformInfo: Codable {
        let flavor: String?
        let version: String?
    }

    struct OptionsPayload: Codable {
        let logLevel: String?
        let platformInfo: PlatformInfo?
    }
}
