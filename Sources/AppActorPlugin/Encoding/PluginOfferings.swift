import Foundation
import AppActor

/// Encodable wrapper for `AppActorOfferings`.
/// The native `AppActorOffering.encode(to:)` excludes packages,
/// so this wrapper includes them for cross-platform consumption.
struct PluginOfferings: Encodable, Sendable {
    let current: PluginOffering?
    let all: [String: PluginOffering]
    let productEntitlements: [String: [String]]?

    init(from offerings: AppActorOfferings) {
        self.current = offerings.current.map { PluginOffering(from: $0) }
        self.all = offerings.all.mapValues { PluginOffering(from: $0) }
        self.productEntitlements = offerings.productEntitlements
    }
}

/// Encodable wrapper for `AppActorOffering` — includes packages.
struct PluginOffering: Encodable, Sendable {
    let id: String
    let displayName: String
    let isCurrent: Bool
    let lookupKey: String?
    let metadata: [String: String]?
    let packages: [AppActorPackage]

    init(from offering: AppActorOffering) {
        self.id = offering.id
        self.displayName = offering.displayName
        self.isCurrent = offering.isCurrent
        self.lookupKey = offering.lookupKey
        self.metadata = offering.metadata
        self.packages = offering.packages
    }
}
