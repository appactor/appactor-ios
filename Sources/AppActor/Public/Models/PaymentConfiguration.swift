import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public Type Aliases

/// Shorthand for payment configuration options.
public typealias AppActorOptions = AppActorPaymentConfiguration.Options

// MARK: - Configuration

/// Canonical wrapper-platform metadata used by bridge/plugin consumers.
public struct AppActorPlatformInfo: Sendable, Equatable, Codable {

    public var flavor: String
    public var version: String?

    public init(flavor: String, version: String? = nil) {
        self.flavor = flavor
        self.version = version
    }
}

/// Configuration for the AppActor Payment identity module.
public struct AppActorPaymentConfiguration: Sendable {

    /// Default payment API base URL.
    public static let defaultBaseURL = URL(string: "https://api.appactor.com")!

    /// How the API key is sent in requests.
    public enum HeaderMode: Sendable {
        /// `Authorization: Bearer pk_...` (default)
        case bearer
        /// `X-API-Key: pk_...`
        case apiKey
    }

    /// Public API key (e.g. `pk_...`).
    public let apiKey: String

    /// Base URL for the payment API.
    public let baseURL: URL

    /// How the API key is sent. Default `.bearer`.
    public let headerMode: HeaderMode

    /// Optional overrides.
    public let options: Options

    public init(
        apiKey: String,
        baseURL: URL = AppActorPaymentConfiguration.defaultBaseURL,
        headerMode: HeaderMode = .bearer,
        options: Options = .init()
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.headerMode = headerMode
        self.options = options
    }

    @_spi(AppActorPluginSupport)
    public var validationError: AppActorError? {
        Self.validationError(apiKey: apiKey)
    }

    @_spi(AppActorPluginSupport)
    public static func validationError(apiKey: String) -> AppActorError? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AppActorError.validationError("apiKey must not be blank.")
        }
        return nil
    }

    /// Optional settings for the payment module.
    public struct Options: Sendable {

        /// Override the SDK log level. Default `nil` (no override — uses the global `AppActor.logLevel`).
        /// Set to a specific level (e.g. `.debug`) to escalate logging for payment mode.
        public var logLevel: AppActorLogLevel?

        /// Canonical wrapper-platform metadata for bridge/plugin consumers.
        public var platformInfo: AppActorPlatformInfo?

        /// Legacy flat bridge field kept for native ergonomics and one migration window.
        public var platformFlavor: String? {
            get { platformInfo?.flavor }
            set {
                if let flavor = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !flavor.isEmpty {
                    platformInfo = AppActorPlatformInfo(flavor: flavor, version: platformInfo?.version)
                } else if platformInfo?.version == nil {
                    platformInfo = nil
                }
            }
        }

        /// Legacy flat bridge field kept for native ergonomics and one migration window.
        public var platformVersion: String? {
            get { platformInfo?.version }
            set {
                if let existingFlavor = platformInfo?.flavor {
                    platformInfo = AppActorPlatformInfo(flavor: existingFlavor, version: newValue)
                } else if let newValue {
                    platformInfo = AppActorPlatformInfo(flavor: "flutter", version: newValue)
                }
            }
        }

        public init(
            logLevel: AppActorLogLevel? = nil,
            platformInfo: AppActorPlatformInfo? = nil,
            platformFlavor: String? = nil,
            platformVersion: String? = nil
        ) {
            self.logLevel = logLevel
            if let platformInfo {
                self.platformInfo = platformInfo
            } else if let platformFlavor, !platformFlavor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.platformInfo = AppActorPlatformInfo(flavor: platformFlavor, version: platformVersion)
            } else if let platformVersion {
                self.platformInfo = AppActorPlatformInfo(flavor: "flutter", version: platformVersion)
            } else {
                self.platformInfo = nil
            }
        }
    }

    /// Last 4 chars of the API key for safe logging.
    var apiKeyHint: String {
        guard apiKey.count >= 4 else { return "****" }
        return "...\(apiKey.suffix(4))"
    }
}

// MARK: - ASA Options

/// Configuration for Apple Search Ads attribution tracking.
public struct AppActorASAOptions: Sendable {

    /// Automatically track StoreKit 2 purchase events for ASA attribution linking.
    /// Default `true`.
    public var autoTrackPurchases: Bool

    /// Track purchase events in sandbox/StoreKit Testing environments.
    /// Default `false`. When `false`, ASA purchase event enqueue is skipped for
    /// non-production transactions (sandbox, Xcode, simulator).
    /// Set to `true` during development if you want to verify the ASA pipeline end-to-end.
    public var trackInSandbox: Bool

    /// Enable verbose ASA-specific debug logging. Default `false`.
    public var debugMode: Bool

    public init(
        autoTrackPurchases: Bool = true,
        trackInSandbox: Bool = false,
        debugMode: Bool = false
    ) {
        self.autoTrackPurchases = autoTrackPurchases
        self.trackInSandbox = trackInSandbox
        self.debugMode = debugMode
    }
}

// MARK: - Auto Device Info Helpers

enum AppActorAutoDeviceInfo {

    static var platform: String { "ios" }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var deviceLocale: String? {
        let locale = Locale.current.identifier
        return String(locale.prefix(20))
    }

    static var deviceModel: String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.model
        #else
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #endif
    }

    /// Build a `PaymentDeviceInfo` from automatic detection, with optional overrides.
    static func resolve(override: AppActorPaymentDeviceInfo?, sdkVersion: String) -> AppActorPaymentDeviceInfo {
        AppActorPaymentDeviceInfo(
            platform: override?.platform ?? platform,
            appVersion: override?.appVersion ?? appVersion,
            sdkVersion: override?.sdkVersion ?? sdkVersion,
            deviceLocale: override?.deviceLocale ?? deviceLocale,
            deviceModel: override?.deviceModel ?? deviceModel,
            osVersion: override?.osVersion ?? osVersion
        )
    }
}
