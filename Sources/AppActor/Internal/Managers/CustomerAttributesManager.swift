import Foundation

final class AppActorCustomerAttributesManager: @unchecked Sendable {
    fileprivate static let maxQueuedUsers = 10
    fileprivate static let maxQueuedAttributesPerUser = 100
    fileprivate static let maxQueuedIntegrationIdentifiersPerUser = 50
    fileprivate static let maxIntegrationIdentifiersPerRequest = 25

    private let lock = NSLock()
    private var storage: any AppActorPaymentStorage
    private var client: (any AppActorPaymentClientProtocol)?
    private var customAttributionSnapshots: [String: AppActorAttribution] = [:]

    init(
        storage: any AppActorPaymentStorage = AppActorUserDefaultsPaymentStorage(),
        client: (any AppActorPaymentClientProtocol)? = nil
    ) {
        self.storage = storage
        self.client = client
    }

    func updateDependencies(
        storage: any AppActorPaymentStorage,
        client: (any AppActorPaymentClientProtocol)?
    ) {
        lock.withLock {
            self.storage = storage
            self.client = client
        }
    }

    func resetToDefaultStorage(clearQueue: Bool) {
        let defaultStorage = AppActorUserDefaultsPaymentStorage()
        lock.withLock {
            if clearQueue {
                storage.remove(forKey: AppActorPaymentStorageKey.customerAttributesQueue)
                defaultStorage.remove(forKey: AppActorPaymentStorageKey.customerAttributesQueue)
            }
            customAttributionSnapshots.removeAll()
            storage = defaultStorage
            client = nil
        }
    }

    @discardableResult
    func ensureAppUserId() -> String {
        currentStorage().ensureAppUserId()
    }

    func enqueueAttributes(
        appUserId: String,
        attributes: [String: AppActorAttributeValue],
        unsetKeys: [String] = []
    ) throws {
        try mutateState { state in
            var bucket = state.buckets[appUserId] ?? PendingBucket()
            for (key, value) in attributes {
                bucket.attributes[key] = value
                bucket.unsetAttributeKeys.removeAll { $0 == key }
            }
            for key in unsetKeys {
                bucket.attributes.removeValue(forKey: key)
                if !bucket.unsetAttributeKeys.contains(key) {
                    bucket.unsetAttributeKeys.append(key)
                }
            }
            try enforceCaps(bucket)
            bucket.updatedAt = Date()
            state.buckets[appUserId] = bucket
            trimQueuedUsers(&state, preserving: appUserId)
        }
    }

    func enqueueIntegrationIdentifier(
        appUserId: String,
        key: String,
        value: String
    ) throws {
        try mutateState { state in
            var bucket = state.buckets[appUserId] ?? PendingBucket()
            bucket.integrationIdentifiers[key] = value
            bucket.unsetIntegrationIdentifierKeys.removeAll { $0 == key }
            try enforceCaps(bucket)
            bucket.updatedAt = Date()
            state.buckets[appUserId] = bucket
            trimQueuedUsers(&state, preserving: appUserId)
        }
    }

    func unsetIntegrationIdentifier(
        appUserId: String,
        key: String
    ) throws {
        try mutateState { state in
            var bucket = state.buckets[appUserId] ?? PendingBucket()
            bucket.integrationIdentifiers.removeValue(forKey: key)
            if !bucket.unsetIntegrationIdentifierKeys.contains(key) {
                bucket.unsetIntegrationIdentifierKeys.append(key)
            }
            try enforceCaps(bucket)
            bucket.updatedAt = Date()
            state.buckets[appUserId] = bucket
            trimQueuedUsers(&state, preserving: appUserId)
        }
    }

    func enqueueAttribution(
        appUserId: String,
        attribution: AppActorAttribution
    ) throws {
        try mutateState { state in
            var bucket = state.buckets[appUserId] ?? PendingBucket()
            bucket.attribution = attribution
            bucket.updatedAt = Date()
            state.buckets[appUserId] = bucket
            customAttributionSnapshots[appUserId] = attribution
            state.customAttributionSnapshots[appUserId] = attribution
            trimQueuedUsers(&state, preserving: appUserId)
        }
    }

    func mergeCustomAttribution(
        appUserId: String,
        patch: AppActorAttribution,
        clearing fieldsToClear: Set<AppActorCustomAttributionField> = []
    ) -> AppActorAttribution {
        lock.withLock {
            var state = loadState(from: storage)
            let queuedAttribution = state.buckets[appUserId]?.attribution
            let persistedSnapshot = state.customAttributionSnapshots[appUserId]
            var merged = customAttributionSnapshots[appUserId] ?? persistedSnapshot ?? queuedAttribution ?? AppActorAttribution()
            merged.provider = patch.provider ?? merged.provider ?? "custom"
            merged.status = patch.status ?? merged.status
            merged.providerName = fieldsToClear.contains(.mediaSource) ? nil : patch.providerName ?? merged.providerName
            merged.campaignId = patch.campaignId ?? merged.campaignId
            merged.campaignName = fieldsToClear.contains(.campaign) ? nil : patch.campaignName ?? merged.campaignName
            merged.adGroupId = patch.adGroupId ?? merged.adGroupId
            merged.adGroupName = fieldsToClear.contains(.adGroup) ? nil : patch.adGroupName ?? merged.adGroupName
            merged.adId = patch.adId ?? merged.adId
            merged.adName = fieldsToClear.contains(.ad) ? nil : patch.adName ?? merged.adName
            merged.creativeId = patch.creativeId ?? merged.creativeId
            merged.creativeName = fieldsToClear.contains(.creative) ? nil : patch.creativeName ?? merged.creativeName
            merged.keywordId = patch.keywordId ?? merged.keywordId
            merged.keyword = fieldsToClear.contains(.keyword) ? nil : patch.keyword ?? merged.keyword
            merged.network = fieldsToClear.contains(.mediaSource) ? nil : patch.network ?? merged.network
            merged.source = fieldsToClear.contains(.mediaSource) ? nil : patch.source ?? merged.source
            merged.medium = patch.medium ?? merged.medium
            merged.campaign = fieldsToClear.contains(.campaign) ? nil : patch.campaign ?? merged.campaign
            merged.adGroup = fieldsToClear.contains(.adGroup) ? nil : patch.adGroup ?? merged.adGroup
            merged.ad = fieldsToClear.contains(.ad) ? nil : patch.ad ?? merged.ad
            merged.creative = fieldsToClear.contains(.creative) ? nil : patch.creative ?? merged.creative
            merged.clickId = patch.clickId ?? merged.clickId
            merged.attributedAt = patch.attributedAt ?? merged.attributedAt
            merged.metadata.merge(patch.metadata) { _, new in new }
            customAttributionSnapshots[appUserId] = merged
            state.customAttributionSnapshots[appUserId] = merged
            trimQueuedUsers(&state, preserving: appUserId)
            saveState(state, to: storage)
            return merged
        }
    }

    func flush(appUserId: String) async throws {
        guard let client = currentClient() else { return }

        while let bucket = pendingBucket(appUserId: appUserId), !bucket.isEmpty {
            do {
                if !bucket.attributes.isEmpty {
                    _ = try await client.patchAttributes(
                        appUserId: appUserId,
                        request: AppActorSetAttributesRequest(attributes: bucket.attributes)
                    )
                    removeFlushedAttributes(appUserId: appUserId, attributes: bucket.attributes)
                }

                if !bucket.unsetAttributeKeys.isEmpty {
                    for key in bucket.unsetAttributeKeys {
                        _ = try await client.deleteAttribute(appUserId: appUserId, key: key)
                        removeFlushedUnset(appUserId: appUserId, key: key)
                    }
                }

                if !bucket.integrationIdentifiers.isEmpty {
                    for identifiers in integrationIdentifierBatches(bucket.integrationIdentifiers) {
                        _ = try await client.patchIntegrationIdentifiers(
                            appUserId: appUserId,
                            request: AppActorSetIntegrationIdentifiersRequest(
                                integrationIdentifiers: identifiers
                            )
                        )
                        removeFlushedIntegrationIdentifiers(
                            appUserId: appUserId,
                            identifiers: identifiers
                        )
                    }
                }

                if !bucket.unsetIntegrationIdentifierKeys.isEmpty {
                    for key in bucket.unsetIntegrationIdentifierKeys {
                        _ = try await client.deleteIntegrationIdentifier(appUserId: appUserId, key: key)
                        removeFlushedUnsetIntegrationIdentifier(appUserId: appUserId, key: key)
                    }
                }

                if let attribution = bucket.attribution {
                    _ = try await client.patchAttribution(
                        appUserId: appUserId,
                        request: AppActorUpdateAttributionRequest(attribution: attribution)
                    )
                    removeFlushedAttribution(appUserId: appUserId, attribution: attribution)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppActorError where error.isTransient {
                Log.customer.debug("Customer attribute flush deferred: \(error.localizedDescription)")
                return
            } catch {
                throw error
            }
        }
    }

    func pendingBucket(appUserId: String) -> PendingBucket? {
        lock.withLock {
            loadState(from: storage).buckets[appUserId]
        }
    }

    func pendingUserIds() -> [String] {
        lock.withLock {
            Array(loadState(from: storage).buckets.keys).sorted()
        }
    }

    private func removeFlushedAttributes(
        appUserId: String,
        attributes: [String: AppActorAttributeValue]
    ) {
        try? mutateState { state in
            guard var bucket = state.buckets[appUserId] else { return }
            for (key, value) in attributes where bucket.attributes[key] == value {
                bucket.attributes.removeValue(forKey: key)
            }
            state.update(bucket, for: appUserId)
        }
    }

    private func removeFlushedUnset(appUserId: String, key: String) {
        try? mutateState { state in
            guard var bucket = state.buckets[appUserId] else { return }
            bucket.unsetAttributeKeys.removeAll { $0 == key }
            state.update(bucket, for: appUserId)
        }
    }

    private func removeFlushedIntegrationIdentifiers(
        appUserId: String,
        identifiers: [String: String]
    ) {
        try? mutateState { state in
            guard var bucket = state.buckets[appUserId] else { return }
            for (key, value) in identifiers where bucket.integrationIdentifiers[key] == value {
                bucket.integrationIdentifiers.removeValue(forKey: key)
            }
            state.update(bucket, for: appUserId)
        }
    }

    private func removeFlushedUnsetIntegrationIdentifier(appUserId: String, key: String) {
        try? mutateState { state in
            guard var bucket = state.buckets[appUserId] else { return }
            bucket.unsetIntegrationIdentifierKeys.removeAll { $0 == key }
            state.update(bucket, for: appUserId)
        }
    }

    private func integrationIdentifierBatches(_ identifiers: [String: String]) -> [[String: String]] {
        var batches: [[String: String]] = []
        var current: [String: String] = [:]

        for key in identifiers.keys.sorted() {
            current[key] = identifiers[key]
            if current.count == Self.maxIntegrationIdentifiersPerRequest {
                batches.append(current)
                current = [:]
            }
        }

        if !current.isEmpty {
            batches.append(current)
        }

        return batches
    }

    private func removeFlushedAttribution(
        appUserId: String,
        attribution: AppActorAttribution
    ) {
        try? mutateState { state in
            guard var bucket = state.buckets[appUserId] else { return }
            if bucket.attribution == attribution {
                bucket.attribution = nil
            }
            state.update(bucket, for: appUserId)
        }
    }

    private func mutateState(_ mutate: (inout PendingState) throws -> Void) throws {
        try lock.withLock {
            var state = loadState(from: storage)
            try mutate(&state)
            saveState(state, to: storage)
        }
    }

    private func currentStorage() -> any AppActorPaymentStorage {
        lock.withLock { storage }
    }

    private func currentClient() -> (any AppActorPaymentClientProtocol)? {
        lock.withLock { client }
    }

    private func loadState(from storage: any AppActorPaymentStorage) -> PendingState {
        guard let raw = storage.string(forKey: AppActorPaymentStorageKey.customerAttributesQueue),
              let data = raw.data(using: .utf8),
              let state = try? Self.makeDecoder().decode(PendingState.self, from: data) else {
            return PendingState()
        }
        return state
    }

    private func saveState(_ state: PendingState, to storage: any AppActorPaymentStorage) {
        guard !state.isEmpty else {
            storage.remove(forKey: AppActorPaymentStorageKey.customerAttributesQueue)
            return
        }
        if let data = try? Self.makeEncoder().encode(state),
           let raw = String(data: data, encoding: .utf8) {
            storage.set(raw, forKey: AppActorPaymentStorageKey.customerAttributesQueue)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

enum AppActorCustomAttributionField: Hashable {
    case mediaSource
    case campaign
    case adGroup
    case ad
    case keyword
    case creative
}

private func enforceCaps(_ bucket: AppActorCustomerAttributesManager.PendingBucket) throws {
    guard bucket.attributes.count + bucket.unsetAttributeKeys.count <= AppActorCustomerAttributesManager.maxQueuedAttributesPerUser else {
        throw AppActorError.validationError("Too many queued customer attribute mutations")
    }
    guard bucket.integrationIdentifiers.count + bucket.unsetIntegrationIdentifierKeys.count <= AppActorCustomerAttributesManager.maxQueuedIntegrationIdentifiersPerUser else {
        throw AppActorError.validationError("Too many queued integration identifiers")
    }
}

private func trimQueuedUsers(
    _ state: inout AppActorCustomerAttributesManager.PendingState,
    preserving appUserId: String
) {
    guard state.buckets.count > AppActorCustomerAttributesManager.maxQueuedUsers else { return }
    let removable = state.buckets
        .filter { key, _ in key != appUserId }
        .sorted { $0.value.updatedAt < $1.value.updatedAt }
    for (key, _) in removable.prefix(state.buckets.count - AppActorCustomerAttributesManager.maxQueuedUsers) {
        state.buckets.removeValue(forKey: key)
    }
}

extension AppActorCustomerAttributesManager {
    struct PendingState: Codable, Sendable, Equatable {
        var buckets: [String: PendingBucket] = [:]
        var customAttributionSnapshots: [String: AppActorAttribution] = [:]

        var isEmpty: Bool {
            buckets.isEmpty && customAttributionSnapshots.isEmpty
        }

        mutating func update(_ bucket: PendingBucket, for appUserId: String) {
            if bucket.isEmpty {
                buckets.removeValue(forKey: appUserId)
            } else {
                buckets[appUserId] = bucket
            }
        }
    }

    struct PendingBucket: Codable, Sendable, Equatable {
        var attributes: [String: AppActorAttributeValue] = [:]
        var unsetAttributeKeys: [String] = []
        var integrationIdentifiers: [String: String] = [:]
        var unsetIntegrationIdentifierKeys: [String] = []
        var attribution: AppActorAttribution?
        var updatedAt: Date = Date()

        init(
            attributes: [String: AppActorAttributeValue] = [:],
            unsetAttributeKeys: [String] = [],
            integrationIdentifiers: [String: String] = [:],
            unsetIntegrationIdentifierKeys: [String] = [],
            attribution: AppActorAttribution? = nil,
            updatedAt: Date = Date()
        ) {
            self.attributes = attributes
            self.unsetAttributeKeys = unsetAttributeKeys
            self.integrationIdentifiers = integrationIdentifiers
            self.unsetIntegrationIdentifierKeys = unsetIntegrationIdentifierKeys
            self.attribution = attribution
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case attributes
            case unsetAttributeKeys
            case integrationIdentifiers
            case unsetIntegrationIdentifierKeys
            case attribution
            case updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attributes = try container.decodeIfPresent([String: AppActorAttributeValue].self, forKey: .attributes) ?? [:]
            unsetAttributeKeys = try container.decodeIfPresent([String].self, forKey: .unsetAttributeKeys) ?? []
            integrationIdentifiers = try container.decodeIfPresent([String: String].self, forKey: .integrationIdentifiers) ?? [:]
            unsetIntegrationIdentifierKeys = try container.decodeIfPresent([String].self, forKey: .unsetIntegrationIdentifierKeys) ?? []
            attribution = try container.decodeIfPresent(AppActorAttribution.self, forKey: .attribution)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }

        var isEmpty: Bool {
            attributes.isEmpty
                && unsetAttributeKeys.isEmpty
                && integrationIdentifiers.isEmpty
                && unsetIntegrationIdentifierKeys.isEmpty
                && attribution == nil
        }
    }
}
