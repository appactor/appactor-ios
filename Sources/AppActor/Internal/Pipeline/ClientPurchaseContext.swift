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

    func replacingDeliverySource(_ source: AppActorClientDeliverySource, observedAt: Date = Date()) -> Self {
        AppActorClientPurchaseContext(
            clientPurchaseAttemptStartedAt: clientPurchaseAttemptStartedAt,
            clientObservedAt: observedAt,
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
