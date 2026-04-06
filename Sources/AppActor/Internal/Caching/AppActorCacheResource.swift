import Foundation
import CryptoKit

/// Identifies a cacheable resource in the centralized ETag cache.
enum AppActorCacheResource: Hashable, Sendable {
    case offerings
    case customer(appUserId: String)
    case remoteConfigs(appUserId: String?)
    case experiments(appUserId: String)

    /// Filename-safe key used for disk persistence.
    var cacheKey: String {
        switch self {
        case .offerings:
            return "offerings"
        case .customer(let appUserId):
            // SHA-256 truncated to 16 hex chars — collision-safe and filesystem-safe
            let digest = SHA256.hash(data: Data(appUserId.utf8))
            let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "customer_\(hex)"
        case .remoteConfigs(let appUserId):
            guard let appUserId, !appUserId.isEmpty else {
                return "remote_configs_anon"
            }
            let digest = SHA256.hash(data: Data(appUserId.utf8))
            let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "remote_configs_\(hex)"
        case .experiments(let appUserId):
            let digest = SHA256.hash(data: Data(appUserId.utf8))
            let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "experiments_\(hex)"
        }
    }
}

/// Disk-serializable cache entry: raw response data + ETag + timestamp.
struct AppActorCacheEntry: Codable, Sendable {
    let data: Data
    let eTag: String?
    let cachedAt: Date
    /// Whether the response was stored after passing Ed25519 signature verification.
    let responseVerified: Bool
}
