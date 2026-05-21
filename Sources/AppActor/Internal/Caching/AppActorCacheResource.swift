import Foundation
import CryptoKit

/// Identifies a cacheable resource in the centralized ETag cache.
enum AppActorCacheResource: Hashable, Sendable {
    case offerings
    case offlineProductCatalog
    case customer(appUserId: String)
    case remoteConfigs(appUserId: String?)
    case remoteConfigsContext(appUserId: String?, appVersion: String?, country: String?)
    case experiments(appUserId: String)
    case experimentsContext(appUserId: String, appVersion: String?, country: String?)

    /// Filename-safe key used for disk persistence.
    var cacheKey: String {
        switch self {
        case .offerings:
            return "offerings"
        case .offlineProductCatalog:
            return "offline_product_catalog"
        case .customer(let appUserId):
            // SHA-256 truncated to 16 hex chars — collision-safe and filesystem-safe
            let digest = SHA256.hash(data: Data(appUserId.utf8))
            let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "customer_\(hex)"
        case .remoteConfigs(let appUserId):
            return Self.remoteConfigsPrefix(appUserId: appUserId)
        case .remoteConfigsContext(let appUserId, let appVersion, let country):
            return "\(Self.remoteConfigsPrefix(appUserId: appUserId))_\(Self.contextHash(appVersion: appVersion, country: country))"
        case .experiments(let appUserId):
            return Self.experimentsPrefix(appUserId: appUserId)
        case .experimentsContext(let appUserId, let appVersion, let country):
            return "\(Self.experimentsPrefix(appUserId: appUserId))_\(Self.contextHash(appVersion: appVersion, country: country))"
        }
    }

    static func remoteConfigsPrefix(appUserId: String?) -> String {
        guard let appUserId, !appUserId.isEmpty else {
            return "remote_configs_anon"
        }
        return "remote_configs_\(hash(appUserId))"
    }

    static func experimentsPrefix(appUserId: String) -> String {
        "experiments_\(hash(appUserId))"
    }

    private static func contextHash(appVersion: String?, country: String?) -> String {
        hash("v=\(appVersion ?? "")|c=\(country ?? "")")
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Disk-serializable cache entry: raw response data + ETag + timestamp.
struct AppActorCacheEntry: Codable, Sendable {
    let data: Data
    let eTag: String?
    let cachedAt: Date
    /// Whether the response was stored after passing Ed25519 signature verification.
    let responseVerified: Bool
    /// Richer verification status. Optional for backward compat with older cache files on disk.
    let verificationResult: AppActorVerificationResult?

    /// Resolves the verification status, preferring the richer enum when available,
    /// falling back to the legacy bool for old cache entries.
    var resolvedVerification: AppActorVerificationResult {
        if let verificationResult { return verificationResult }
        return responseVerified ? .verified : .failed
    }

    /// Returns a copy with an updated timestamp and optional ETag rotation.
    func refreshed(cachedAt: Date = Date(), eTag: String? = nil) -> AppActorCacheEntry {
        AppActorCacheEntry(
            data: data,
            eTag: eTag ?? self.eTag,
            cachedAt: cachedAt,
            responseVerified: responseVerified,
            verificationResult: verificationResult
        )
    }
}
