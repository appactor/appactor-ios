import Foundation

// MARK: - AppActorOffering

/// A named group of packages presented to the user.
///
/// Used in both local mode (configured via DSL) and payment mode (server-driven).
/// In local mode, `lookupKey` is `nil` and `isCurrent` is determined by the container.
/// In payment mode, all fields are populated from the server response.
public struct AppActorOffering: Sendable, Identifiable, Hashable, Codable {

    /// Server-assigned offering identifier.
    public let id: String

    /// Display name. Non-optional — local mode always has it; payment mode falls back to id in adapter.
    public let displayName: String

    /// Whether this is the current (default) offering.
    public let isCurrent: Bool

    /// Lookup key for programmatic access. `nil` in local mode.
    public let lookupKey: String?

    /// Optional metadata from the server.
    public let metadata: [String: String]?

    /// Packages in this offering, sorted by position.
    public let packages: [AppActorPackage]

    // MARK: - Quick-Access Helpers

    /// The first package with type `.monthly`, if any.
    public var monthly: AppActorPackage? { packages.first { $0.packageType == .monthly } }

    /// The first package with type `.annual`, if any.
    public var annual: AppActorPackage? { packages.first { $0.packageType == .annual } }

    /// The first package with type `.weekly`, if any.
    public var weekly: AppActorPackage? { packages.first { $0.packageType == .weekly } }

    /// The first package with type `.sixMonth`, if any.
    public var sixMonth: AppActorPackage? { packages.first { $0.packageType == .sixMonth } }

    /// The first package with type `.threeMonth`, if any.
    public var threeMonth: AppActorPackage? { packages.first { $0.packageType == .threeMonth } }

    /// The first package with type `.twoMonth`, if any.
    public var twoMonth: AppActorPackage? { packages.first { $0.packageType == .twoMonth } }

    /// The first package with type `.lifetime`, if any.
    public var lifetime: AppActorPackage? { packages.first { $0.packageType == .lifetime } }

    /// Returns the package matching the given type, or `nil`.
    public func package(for type: AppActorPackageType) -> AppActorPackage? {
        packages.first { $0.packageType == type }
    }

    public static func == (lhs: AppActorOffering, rhs: AppActorOffering) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Codable (excludes packages — contains non-Codable StoreKit types)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, isCurrent, lookupKey, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        isCurrent = (try? c.decodeIfPresent(Bool.self, forKey: .isCurrent)) ?? false
        lookupKey = try? c.decodeIfPresent(String.self, forKey: .lookupKey)
        metadata = try? c.decodeIfPresent([String: String].self, forKey: .metadata)
        packages = []  // excluded — re-enriched from StoreKit at runtime
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(isCurrent, forKey: .isCurrent)
        try c.encodeIfPresent(lookupKey, forKey: .lookupKey)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }

    // MARK: - Internal Memberwise Init

    /// Internal init for SDK adapters (local mode and payment mode adapters).
    /// Not part of the public API — SDK consumers receive offerings from `AppActor`.
    init(
        id: String,
        displayName: String,
        isCurrent: Bool,
        lookupKey: String?,
        metadata: [String: String]?,
        packages: [AppActorPackage]
    ) {
        self.id = id
        self.displayName = displayName
        self.isCurrent = isCurrent
        self.lookupKey = lookupKey
        self.metadata = metadata
        self.packages = packages
    }
}

// MARK: - AppActorOfferings

/// Container for all available offerings, with a designated `.current` offering.
///
/// Used in both local mode and payment mode. `productEntitlements` is populated
/// only in payment mode (server-driven); it is `nil` in local mode.
public struct AppActorOfferings: Sendable, Codable {

    /// The current (default) offering, if set.
    public let current: AppActorOffering?

    /// All offerings keyed by their `id`.
    public let all: [String: AppActorOffering]

    /// Maps backend-defined product entitlement keys to entitlement identifiers.
    /// Used for offline entitlement derivation from active StoreKit transactions.
    /// `nil` in local mode; populated in payment mode.
    public let productEntitlements: [String: [String]]?

    /// How this offerings data was verified.
    public let verification: AppActorVerificationResult

    /// Returns the offering with the given ID, or `nil`.
    public func offering(id: String) -> AppActorOffering? {
        all[id]
    }

    /// Returns the offering with the given lookup key, or `nil`.
    public func offering(lookupKey: String) -> AppActorOffering? {
        all.values.first { $0.lookupKey == lookupKey }
    }

    // MARK: - Internal Init

    private enum CodingKeys: String, CodingKey {
        case current, all, productEntitlements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.current = try container.decodeIfPresent(AppActorOffering.self, forKey: .current)
        self.all = try container.decode([String: AppActorOffering].self, forKey: .all)
        self.productEntitlements = try container.decodeIfPresent([String: [String]].self, forKey: .productEntitlements)
        self.verification = .notRequested  // Set by SDK after decode
    }

    init(
        current: AppActorOffering?,
        all: [String: AppActorOffering],
        productEntitlements: [String: [String]]? = nil,
        verification: AppActorVerificationResult = .notRequested
    ) {
        self.current = current
        self.all = all
        self.productEntitlements = productEntitlements
        self.verification = verification
    }
}
