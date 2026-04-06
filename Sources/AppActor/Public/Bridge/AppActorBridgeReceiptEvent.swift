import Foundation

/// Flat receipt pipeline event for bridge consumers (Flutter, React Native, Unity).
///
/// Converts the ``AppActorReceiptPipelineEvent`` enum with associated values into
/// a flat struct suitable for serialization across FFI boundaries.
public struct AppActorBridgeReceiptEvent: Sendable, Equatable {

    // MARK: - Type Constants

    public static let TYPE_POSTED_OK = "POSTED_OK"
    public static let TYPE_RETRY_SCHEDULED = "RETRY_SCHEDULED"
    public static let TYPE_PERMANENTLY_REJECTED = "PERMANENTLY_REJECTED"
    public static let TYPE_DEAD_LETTERED = "DEAD_LETTERED"
    public static let TYPE_DUPLICATE_SKIPPED = "DUPLICATE_SKIPPED"

    // MARK: - Properties

    /// Event type (one of the `TYPE_*` constants).
    public let type: String

    /// The transaction ID associated with this event.
    public let transactionId: String?

    /// The product ID associated with this receipt.
    public let productId: String

    /// The app user ID that owns this receipt.
    public let appUserId: String

    /// Number of retry attempts made (for retry/dead-letter events).
    public let retryCount: Int?

    /// ISO 8601 timestamp of when the next retry is scheduled.
    public let nextAttemptAt: String?

    /// Error code from the server, if applicable.
    public let errorCode: String?

    /// Queue key (for duplicate-skipped events).
    public let key: String?

    // MARK: - Private

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Init from Internal Type

    public init(from detail: AppActorReceiptPipelineEventDetail) {
        self.productId = detail.productId
        self.appUserId = detail.appUserId

        switch detail.event {
        case .postedOk(let txId):
            self.type = Self.TYPE_POSTED_OK
            self.transactionId = txId
            self.retryCount = nil
            self.nextAttemptAt = nil
            self.errorCode = nil
            self.key = nil

        case .retryScheduled(let txId, let attempt, let nextAt, let errCode):
            self.type = Self.TYPE_RETRY_SCHEDULED
            self.transactionId = txId
            self.retryCount = attempt
            self.nextAttemptAt = Self.iso8601Formatter.string(from: nextAt)
            self.errorCode = errCode
            self.key = nil

        case .permanentlyRejected(let txId, let errCode):
            self.type = Self.TYPE_PERMANENTLY_REJECTED
            self.transactionId = txId
            self.retryCount = nil
            self.nextAttemptAt = nil
            self.errorCode = errCode
            self.key = nil

        case .deadLettered(let txId, let attemptCount, let lastErrCode):
            self.type = Self.TYPE_DEAD_LETTERED
            self.transactionId = txId
            self.retryCount = attemptCount
            self.nextAttemptAt = nil
            self.errorCode = lastErrCode
            self.key = nil

        case .duplicateSkipped(let queueKey):
            self.type = Self.TYPE_DUPLICATE_SKIPPED
            self.transactionId = nil
            self.retryCount = nil
            self.nextAttemptAt = nil
            self.errorCode = nil
            self.key = queueKey
        }
    }

    // MARK: - Memberwise Init

    public init(
        type: String,
        transactionId: String? = nil,
        productId: String,
        appUserId: String,
        retryCount: Int? = nil,
        nextAttemptAt: String? = nil,
        errorCode: String? = nil,
        key: String? = nil
    ) {
        self.type = type
        self.transactionId = transactionId
        self.productId = productId
        self.appUserId = appUserId
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.errorCode = errorCode
        self.key = key
    }

    // MARK: - Dictionary Serialization

    /// Converts to a dictionary for FFI channel serialization.
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": type,
            "productId": productId,
            "appUserId": appUserId,
        ]
        if let transactionId { dict["transactionId"] = transactionId }
        if let retryCount { dict["retryCount"] = retryCount }
        if let nextAttemptAt { dict["nextAttemptAt"] = nextAttemptAt }
        if let errorCode { dict["errorCode"] = errorCode }
        if let key { dict["key"] = key }
        return dict
    }
}
