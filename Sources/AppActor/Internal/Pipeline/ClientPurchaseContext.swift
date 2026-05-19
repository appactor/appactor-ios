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
    var sdkOriginated: Bool
    var sdkVersion: String

    init(
        clientPurchaseAttemptStartedAt: Date? = nil,
        clientObservedAt: Date = Date(),
        clientDeliverySource: AppActorClientDeliverySource,
        clientPurchaseAttemptId: String? = nil,
        sdkOriginated: Bool = true,
        sdkVersion: String = AppActorSDK.version
    ) {
        self.clientPurchaseAttemptStartedAt = clientPurchaseAttemptStartedAt
        self.clientObservedAt = clientObservedAt
        self.clientDeliverySource = clientDeliverySource
        self.clientPurchaseAttemptId = clientPurchaseAttemptId
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
            sdkOriginated: sdkOriginated,
            sdkVersion: sdkVersion
        )
    }

    static func purchaseAttempt(startedAt: Date = Date(), attemptId: UUID = UUID()) -> AppActorClientPurchaseContext {
        AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: startedAt,
            clientObservedAt: startedAt,
            clientDeliverySource: .purchaseFlow,
            clientPurchaseAttemptId: attemptId.uuidString.lowercased()
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
}

struct AppActorPendingPurchaseContextMatch: Sendable, Equatable {
    let appUserId: String?
    let context: AppActorClientPurchaseContext
}

struct AppActorPendingPurchaseContextBuffer: Sendable {
    private struct StoredEntry: Codable, Sendable, Equatable {
        let recordedAt: Date
        let appUserId: String?
        let context: AppActorClientPurchaseContext
    }

    private struct StoredState: Codable, Sendable, Equatable {
        var contextsByProductId: [String: [StoredEntry]]
    }

    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private var contextsByProductId: [String: [StoredEntry]]
    private let storage: (any AppActorPaymentStorage)?

    init(
        storage: (any AppActorPaymentStorage)? = nil,
        contextsByProductId: [String: [AppActorClientPurchaseContext]] = [:]
    ) {
        self.storage = storage
        if let storage {
            self.contextsByProductId = Self.load(from: storage)
        } else {
            self.contextsByProductId = contextsByProductId.mapValues { contexts in
                contexts.map { StoredEntry(recordedAt: $0.clientObservedAt, appUserId: nil, context: $0) }
            }
        }
        pruneExpired(now: Date())
    }

    mutating func append(
        _ context: AppActorClientPurchaseContext,
        productId: String,
        appUserId: String? = nil,
        recordedAt: Date = Date()
    ) {
        guard context.hasPurchaseAttempt, !productId.isEmpty else { return }
        pruneExpired(now: recordedAt)
        let normalizedAppUserId = appUserId?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextsByProductId[productId, default: []].append(StoredEntry(
            recordedAt: recordedAt,
            appUserId: normalizedAppUserId?.isEmpty == false ? normalizedAppUserId : nil,
            context: context
        ))
        persist()
    }

    mutating func consume(productId: String, observedAt: Date = Date()) -> AppActorPendingPurchaseContextMatch? {
        pruneExpired(now: observedAt)
        guard var entries = contextsByProductId[productId], !entries.isEmpty else {
            persist()
            return nil
        }
        let entry = entries.removeFirst()
        if entries.isEmpty {
            contextsByProductId.removeValue(forKey: productId)
        } else {
            contextsByProductId[productId] = entries
        }
        persist()
        return AppActorPendingPurchaseContextMatch(
            appUserId: entry.appUserId,
            context: entry.context.replacingDeliverySource(.transactionUpdates, observedAt: observedAt)
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
