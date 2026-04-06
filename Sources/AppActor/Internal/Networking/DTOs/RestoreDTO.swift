import Foundation

// MARK: - Request

/// POST body for `/v1/payment/restore/apple`.
struct AppActorRestoreRequest: Encodable, Sendable {
    let appUserId: String
    let transactions: [AppActorRestoreTransactionItem]
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
}

// MARK: - Internal Result

/// Parsed result of a bulk restore call.
struct AppActorRestoreResult: Sendable {
    let customerInfo: AppActorCustomerInfo
    let restoredCount: Int
    let transferred: Bool
    let requestId: String?
    let customerETag: String?
    let signatureVerified: Bool
}
