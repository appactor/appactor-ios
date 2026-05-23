import Foundation
import StoreKit

/// POST body for `/v1/payment/receipts/apple`.
struct AppActorReceiptPostRequest: Encodable, Sendable {
    let appUserId: String
    let appId: String
    let environment: String
    let bundleId: String
    let storefront: String?
    let sourceIntent: String
    let signedTransactionInfo: String?
    let signedAppTransactionInfo: String?
    let transactionId: String?
    let productId: String?
    let idempotencyKey: String?
    let originalTransactionId: String?
    /// The offering that contained the purchased package (analytics attribution).
    let offeringId: String?
    /// The canonical backend package identifier for analytics attribution.
    let packageId: String?
    /// User-initiated purchase placement. `nil` for restore/sync/background updates.
    let placement: String?
    let clientPurchaseAttemptStartedAt: String?
    let clientObservedAt: String?
    let clientDeliverySource: String?
    let clientPurchaseAttemptId: String?
    let sdkOriginated: Bool?
    let sdkVersion: String?

    init(
        appUserId: String,
        appId: String,
        environment: String,
        bundleId: String,
        storefront: String?,
        sourceIntent: String,
        signedTransactionInfo: String?,
        signedAppTransactionInfo: String?,
        transactionId: String?,
        productId: String?,
        idempotencyKey: String?,
        originalTransactionId: String?,
        offeringId: String?,
        packageId: String?,
        placement: String? = nil,
        clientPurchaseAttemptStartedAt: String? = nil,
        clientObservedAt: String? = nil,
        clientDeliverySource: String? = nil,
        clientPurchaseAttemptId: String? = nil,
        sdkOriginated: Bool? = nil,
        sdkVersion: String? = nil
    ) {
        self.appUserId = appUserId
        self.appId = appId
        self.environment = environment
        self.bundleId = bundleId
        self.storefront = storefront
        self.sourceIntent = sourceIntent
        self.signedTransactionInfo = signedTransactionInfo
        self.signedAppTransactionInfo = signedAppTransactionInfo
        self.transactionId = transactionId
        self.productId = productId
        self.idempotencyKey = idempotencyKey
        self.originalTransactionId = originalTransactionId
        self.offeringId = offeringId
        self.packageId = packageId
        self.placement = AppActorClientPurchaseContext.normalizePlacement(placement)
        self.clientPurchaseAttemptStartedAt = clientPurchaseAttemptStartedAt
        self.clientObservedAt = clientObservedAt
        self.clientDeliverySource = clientDeliverySource
        self.clientPurchaseAttemptId = clientPurchaseAttemptId
        self.sdkOriginated = sdkOriginated
        self.sdkVersion = sdkVersion
    }
}

// MARK: - Response DTO

/// Server response from `POST /v1/payment/receipts/apple`.
///
/// Strict API schema:
/// - `status`: `"ok"`, `"retryable_error"`, or `"permanent_error"`.
/// - `customer`: present on `"ok"` (including duplicate-ok), contains updated entitlements.
/// - `error`: present on error statuses, with `code` from `AppleSK2ReceiptErrorCode`.
/// - `retryAfterSeconds`: optional hint for retryable errors.
/// - `requestId`: server-assigned trace identifier.
///
/// Finish policy is server-driven via `finishTransaction`:
/// - `"ok"` — `finishTransaction` (always `true` from current API).
/// - `"permanent_error"` — `finishTransaction` depends on product type (consumable = `false`).
/// - `"retryable_error"` — never finish, keep in queue with backoff (no `finishTransaction` field).
///
/// If `finishTransaction` is `nil` (older API), SDK falls back to previous behavior (always finish on ok/permanent).
///
/// Forward-compatible: unknown JSON keys from the server are silently ignored.
struct AppActorReceiptPostResponse: Decodable, Sendable {
    /// `"ok"`, `"retryable_error"`, or `"permanent_error"`.
    let status: String
    /// Updated customer DTO snapshot (present when `status == "ok"`).
    /// Uses `AppActorCustomerDTO` to match the server's JSON shape; caller converts
    /// to `AppActorCustomerInfo` via `init(dto:appUserId:requestDate:)`.
    let customer: AppActorCustomerDTO?
    /// Error details (present when `status` is an error).
    let error: AppActorReceiptErrorInfo?
    /// Server hint for retry delay in seconds (only meaningful for `retryable_error`).
    let retryAfterSeconds: Double?
    /// Server-assigned request identifier.
    let requestId: String?
    /// Server-driven finish decision. `nil` when field is absent (older API or retryable status).
    /// When `nil`, SDK falls back to previous behavior (finish on ok/permanent_error).
    let finishTransaction: Bool?
    /// Present only when a sync receipt successfully replayed the Apple original transaction chain.
    let syncedOriginalTransactionId: String?
    /// Whether this response passed SDK response-signature verification.
    let signatureVerified: Bool

    init(
        status: String,
        customer: AppActorCustomerDTO? = nil,
        error: AppActorReceiptErrorInfo? = nil,
        retryAfterSeconds: Double? = nil,
        requestId: String? = nil,
        finishTransaction: Bool? = nil,
        syncedOriginalTransactionId: String? = nil,
        signatureVerified: Bool = false
    ) {
        self.status = status
        self.customer = customer
        self.error = error
        self.retryAfterSeconds = retryAfterSeconds
        self.requestId = requestId
        self.finishTransaction = finishTransaction
        self.syncedOriginalTransactionId = syncedOriginalTransactionId
        self.signatureVerified = signatureVerified
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case customer
        case error
        case retryAfterSeconds
        case requestId
        case finishTransaction
        case syncedOriginalTransactionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        customer = try container.decodeIfPresent(AppActorCustomerDTO.self, forKey: .customer)
        error = try container.decodeIfPresent(AppActorReceiptErrorInfo.self, forKey: .error)
        retryAfterSeconds = try container.decodeIfPresent(Double.self, forKey: .retryAfterSeconds)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        finishTransaction = try container.decodeIfPresent(Bool.self, forKey: .finishTransaction)
        syncedOriginalTransactionId = try container.decodeIfPresent(String.self, forKey: .syncedOriginalTransactionId)
        signatureVerified = false
    }
}

/// Error details from the receipt POST response.
///
/// Contains a machine-readable `code` from the `AppleSK2ReceiptErrorCode` enum
/// and an optional human-readable `message`.
///
/// Known error codes:
/// - `INVALID_JWS` — JWS signature validation failed.
/// - `BUNDLE_ID_MISMATCH` — bundle ID doesn't match app configuration.
/// - `TXID_MISMATCH` — transaction ID doesn't match the signed data.
/// - `REVOKED_TRANSACTION` — transaction was refunded or revoked.
/// - `STALE_TRANSACTION` — transaction is too old for processing.
/// - `VALIDATION_ERROR` — general payload validation failure.
/// - `APP_NOT_FOUND` — no app registered for the given bundle ID.
/// - `USER_NOT_FOUND` — app user ID not recognized.
/// - `RATE_LIMIT_EXCEEDED` — too many requests.
/// - `INTERNAL` — server-side error.
/// - `DUPLICATE_TRANSACTION` — transaction already processed.
struct AppActorReceiptErrorInfo: Decodable, Sendable, Equatable {
    /// Machine-readable error code from `AppleSK2ReceiptErrorCode`.
    let code: String
    /// Optional human-readable error message.
    let message: String?
}

// MARK: - Internal Result

/// Internal result of processing a single receipt event.
enum AppActorReceiptPostResult: Sendable {
    /// Server returned `"ok"` — transaction finished and removed from queue.
    case success(AppActorCustomerInfo?)
    /// Server returned `"permanent_error"` — removed from queue. Transaction is
    /// finished unless server sent `finishTransaction: false` (consumable protection),
    /// in which case it stays in `Transaction.unfinished` for re-delivery.
    case permanentlyRejected(errorCode: String?, message: String?, requestId: String?)
    /// Retryable error or network failure — event stays in queue for later retry.
    case queued
    /// Transaction was already in the posted ledger, but no recent runtime outcome
    /// could be recovered for it. The purchase flow should treat this as a fallback
    /// case and re-fetch state before deciding what to surface.
    case alreadyPosted
}

// MARK: - Pipeline Observability

/// Summary of a receipt event for internal diagnostics.
struct AppActorReceiptEventSummary: Sendable {
    let id: String
    let productId: String
    let status: String
    let attemptCount: Int
    let nextAttemptAt: Date
    let lastError: String?
}

/// Metadata about a purged dead-letter record.
struct AppActorPurgedDeadLetterSummary: Sendable, Equatable {
    let transactionId: String
    let productId: String
    let attemptCount: Int
    let lastError: String?

    init(transactionId: String, productId: String, attemptCount: Int, lastError: String?) {
        self.transactionId = transactionId
        self.productId = productId
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

/// Receipt pipeline event types.
///
/// Delivered via ``AppActorReceiptPipelineEventDetail`` through ``AppActor/onReceiptPipelineEvent``.
public enum AppActorReceiptPipelineEvent: Sendable {
    /// Receipt was accepted by the server. Transaction finished and removed from queue.
    case postedOk(transactionId: String)
    /// Receipt will be retried after a backoff delay.
    case retryScheduled(transactionId: String, attempt: Int, nextAttemptAt: Date, errorCode: String?)
    /// Receipt was permanently rejected by the server. Transaction finished.
    case permanentlyRejected(transactionId: String, errorCode: String?)
    /// Receipt was dead-lettered after exhausting retry attempts.
    case deadLettered(transactionId: String, attemptCount: Int, lastErrorCode: String?)
    /// Enqueue was skipped because the transaction was already in the posted ledger.
    case duplicateSkipped(key: String)
}

/// Pipeline event with product and user context.
/// Delivered via ``AppActor/onReceiptPipelineEvent``.
public struct AppActorReceiptPipelineEventDetail: Sendable {
    /// The underlying pipeline event.
    public let event: AppActorReceiptPipelineEvent
    /// The product ID associated with this receipt.
    public let productId: String
    /// The app user ID that owns this receipt.
    public let appUserId: String
}
