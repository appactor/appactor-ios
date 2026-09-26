import Foundation

// MARK: - Request

/// POST body for `/v1/payment/restore/apple`.
struct AppActorRestoreRequest: Encodable, Sendable {
    let appUserId: String
    let sourceIntent: String
    let transactions: [AppActorRestoreTransactionItem]
    let signedAppTransactionInfo: String?
    let clientPurchaseAttemptStartedAt: String?
    let clientObservedAt: String?
    let clientDeliverySource: String?
    let clientPurchaseAttemptId: String?
    let sdkOriginated: Bool?
    let sdkVersion: String?

    init(
        appUserId: String,
        sourceIntent: String,
        transactions: [AppActorRestoreTransactionItem],
        signedAppTransactionInfo: String?,
        clientPurchaseAttemptStartedAt: String? = nil,
        clientObservedAt: String? = nil,
        clientDeliverySource: String? = nil,
        clientPurchaseAttemptId: String? = nil,
        sdkOriginated: Bool? = nil,
        sdkVersion: String? = nil
    ) {
        self.appUserId = appUserId
        self.sourceIntent = sourceIntent
        self.transactions = transactions
        self.signedAppTransactionInfo = signedAppTransactionInfo
        self.clientPurchaseAttemptStartedAt = clientPurchaseAttemptStartedAt
        self.clientObservedAt = clientObservedAt
        self.clientDeliverySource = clientDeliverySource
        self.clientPurchaseAttemptId = clientPurchaseAttemptId
        self.sdkOriginated = sdkOriginated
        self.sdkVersion = sdkVersion
    }
}

/// A single transaction item within a bulk restore request.
struct AppActorRestoreTransactionItem: Encodable, Sendable {
    let transactionId: String
    let jwsRepresentation: String
}

// MARK: - Response

/// `data` payload from `POST /v1/payment/restore/apple`.
struct AppActorRestoreResponseData: Decodable, Sendable {
    let user: AppActorCustomerDTO
    let restoredCount: Int
    let transferred: Bool
    let items: [AppActorRestoreItemDTO]
}

/// Server outcome for one transaction of a bulk restore.
///
/// Only `restored` and `noop` mean the restore settled the transaction. `conflict` (not
/// written, or kept with another owner) and `skipped_invalid` come back in a 2xx too.
struct AppActorRestoreItemDTO: Decodable, Sendable {
    let transactionId: String
    let status: String

    /// Whether the restore settled this transaction (`recordedTransactionIds`).
    var isRecorded: Bool { status == "restored" || status == "noop" }
}

// MARK: - Internal Result

/// Parsed result of a bulk restore call.
struct AppActorRestoreResult: Sendable {
    let customerInfo: AppActorCustomerInfo
    let restoredCount: Int
    let transferred: Bool
    let recordedTransactionIds: Set<String>
    let requestId: String?
    let customerETag: String?
    let signatureVerified: Bool
}
