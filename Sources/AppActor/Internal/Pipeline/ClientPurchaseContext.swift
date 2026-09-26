import Foundation

enum AppActorClientDeliverySource: String, Codable, Sendable, Equatable {
    case purchaseFlow = "purchase_flow"
    case transactionUpdates = "transaction_updates"
    case unfinished
    case currentEntitlements = "current_entitlements"
    case restoreFlow = "restore_flow"
    case queueRetry = "queue_retry"
    case foregroundSync = "foreground_sync"
}

struct AppActorClientPurchaseContext: Codable, Sendable, Equatable {
    var clientPurchaseAttemptStartedAt: Date?
    var clientObservedAt: Date
    var clientDeliverySource: AppActorClientDeliverySource
    var clientPurchaseAttemptId: String?
    var placement: String?
    var sdkOriginated: Bool
    var sdkVersion: String

    init(
        clientPurchaseAttemptStartedAt: Date? = nil,
        clientObservedAt: Date = Date(),
        clientDeliverySource: AppActorClientDeliverySource,
        clientPurchaseAttemptId: String? = nil,
        placement: String? = nil,
        sdkOriginated: Bool = true,
        sdkVersion: String = AppActorSDK.version
    ) {
        self.clientPurchaseAttemptStartedAt = clientPurchaseAttemptStartedAt
        self.clientObservedAt = clientObservedAt
        self.clientDeliverySource = clientDeliverySource
        self.clientPurchaseAttemptId = clientPurchaseAttemptId
        self.placement = Self.normalizePlacement(placement)
        self.sdkOriginated = sdkOriginated
        self.sdkVersion = sdkVersion
    }

    var hasPurchaseAttempt: Bool {
        clientPurchaseAttemptStartedAt != nil && clientPurchaseAttemptId != nil
    }

    var clientPurchaseAttemptStartedAtString: String? {
        clientPurchaseAttemptStartedAt.map(Self.iso8601String)
    }

    var clientObservedAtString: String {
        Self.iso8601String(clientObservedAt)
    }

    func replacingDeliverySource(_ source: AppActorClientDeliverySource, observedAt: Date? = nil) -> Self {
        AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: clientPurchaseAttemptStartedAt,
            clientObservedAt: observedAt ?? clientObservedAt,
            clientDeliverySource: source,
            clientPurchaseAttemptId: clientPurchaseAttemptId,
            placement: placement,
            sdkOriginated: sdkOriginated,
            sdkVersion: sdkVersion
        )
    }

    static func purchaseAttempt(
        startedAt: Date = Date(),
        attemptId: UUID = UUID(),
        placement: String? = nil
    ) -> AppActorClientPurchaseContext {
        AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: attemptId.uuidString.lowercased(),
            placement: placement
        )
    }

    static func forQueueSource(
        _ source: AppActorPaymentQueueItem.Source,
        observedAt: Date = Date()
    ) -> AppActorClientPurchaseContext {
        AppActorClientPurchaseContext(
            clientObservedAt: observedAt,
            clientDeliverySource: source.defaultClientDeliverySource
        )
    }

    static func restoreFlow(observedAt: Date = Date()) -> AppActorClientPurchaseContext {
        AppActorClientPurchaseContext(clientObservedAt: observedAt, clientDeliverySource: .restoreFlow)
    }

    static func foregroundSync(observedAt: Date = Date()) -> AppActorClientPurchaseContext {
        AppActorClientPurchaseContext(clientObservedAt: observedAt, clientDeliverySource: .foregroundSync)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func normalizePlacement(_ placement: String?) -> String? {
        let normalized = placement?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty, normalized.count <= 255 else { return nil }
        return normalized
    }
}

struct AppActorPendingPurchaseContextMatch: Sendable, Equatable {
    let appUserId: String?
    let context: AppActorClientPurchaseContext
}

struct AppActorPendingPurchaseContextBuffer: Sendable {
    private struct StoredEntry: Codable, Sendable, Equatable {
        let recordedAt: Date
        let appUserId: String?
        /// The appAccountToken the purchase was made with. StoreKit returns it unchanged on
        /// the resulting transaction. The token is per identity, so a transaction carrying it
        /// belongs to this identity's attempts, never to another identity's.
        let appAccountToken: UUID
        let context: AppActorClientPurchaseContext
    }

    private struct StoredState: Codable, Sendable, Equatable {
        var contextsByProductId: [String: [StoredEntry]]
    }

    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private var contextsByProductId: [String: [StoredEntry]]
    private let storage: (any AppActorPaymentStorage)?

    init(storage: (any AppActorPaymentStorage)? = nil) {
        self.storage = storage
        self.contextsByProductId = storage.map(Self.load(from:)) ?? [:]
        pruneExpired(now: Date())
    }

    mutating func append(
        _ context: AppActorClientPurchaseContext,
        productId: String,
        appUserId: String? = nil,
        appAccountToken: UUID,
        recordedAt: Date = Date()
    ) {
        guard context.hasPurchaseAttempt, !productId.isEmpty else { return }
        pruneExpired(now: recordedAt)
        let normalizedAppUserId = appUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextsByProductId[productId, default: []].append(StoredEntry(
            recordedAt: recordedAt,
            appUserId: normalizedAppUserId?.isEmpty == false ? normalizedAppUserId : nil,
            appAccountToken: appAccountToken,
            context: context
        ))
        persist()
    }

    /// Takes the oldest attempt for `productId` that was made with the transaction's
    /// `appAccountToken`, i.e. by the same identity. A transaction without that token (an
    /// offer code, an App Store purchase, another identity's purchase) matches nothing.
    mutating func consume(
        productId: String,
        appAccountToken: UUID?,
        observedAt: Date = Date(),
        deliverySource: AppActorClientDeliverySource = .transactionUpdates,
        transactionPurchaseDate: Date? = nil,
        transactionReason: AppActorTransactionReason = .unknown
    ) -> AppActorPendingPurchaseContextMatch? {
        pruneExpired(now: observedAt)
        guard let appAccountToken,
              var entries = contextsByProductId[productId],
              let index = entries.firstIndex(where: { $0.appAccountToken == appAccountToken }) else {
            return nil
        }
        let entry = entries[index]
        guard Self.shouldConsume(
            entry: entry,
            transactionPurchaseDate: transactionPurchaseDate,
            transactionReason: transactionReason
        ) else {
            return nil
        }
        entries.remove(at: index)
        if entries.isEmpty {
            contextsByProductId.removeValue(forKey: productId)
        } else {
            contextsByProductId[productId] = entries
        }
        persist()
        return AppActorPendingPurchaseContextMatch(
            appUserId: entry.appUserId,
            context: entry.context.replacingDeliverySource(deliverySource, observedAt: observedAt)
        )
    }

    mutating func pruneExpired(now: Date = Date()) {
        var pruned: [String: [StoredEntry]] = [:]
        for (productId, entries) in contextsByProductId {
            let freshEntries = entries.filter { now.timeIntervalSince($0.recordedAt) <= Self.retentionInterval }
            if !freshEntries.isEmpty {
                pruned[productId] = freshEntries
            }
        }
        contextsByProductId = pruned
        persist()
    }

    private mutating func persist() {
        guard let storage else { return }
        guard !contextsByProductId.isEmpty else {
            storage.remove(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let state = StoredState(contextsByProductId: contextsByProductId)
        if let data = try? encoder.encode(state),
           let raw = String(data: data, encoding: .utf8) {
            storage.set(raw, forKey: AppActorPaymentStorageKey.pendingPurchaseContexts)
        }
    }

    private static func shouldConsume(
        entry: StoredEntry,
        transactionPurchaseDate: Date?,
        transactionReason: AppActorTransactionReason
    ) -> Bool {
        if transactionReason == .renewal {
            return false
        }

        guard let transactionPurchaseDate,
              let attemptStartedAt = entry.context.clientPurchaseAttemptStartedAt else {
            return true
        }

        return transactionPurchaseDate >= attemptStartedAt.addingTimeInterval(-60)
    }

    private static func load(from storage: any AppActorPaymentStorage) -> [String: [StoredEntry]] {
        guard let raw = storage.string(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts),
              let data = raw.data(using: .utf8) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(StoredState.self, from: data) else {
            storage.remove(forKey: AppActorPaymentStorageKey.pendingPurchaseContexts)
            return [:]
        }
        return state.contextsByProductId
    }
}
