import Foundation

/// Flat error type for bridge consumers (Flutter, React Native, Unity).
///
/// Converts the rich ``AppActorError`` struct into a flat representation
/// with string codes and boolean flags, suitable for serialization across
/// FFI/channel boundaries.
public struct AppActorBridgeError: Sendable, Equatable {

    // MARK: - Code Constants

    public static let CODE_NOT_CONFIGURED = "NOT_CONFIGURED"
    public static let CODE_ALREADY_CONFIGURED = "ALREADY_CONFIGURED"
    public static let CODE_VALIDATION = "VALIDATION"
    public static let CODE_NOT_AVAILABLE = "NOT_AVAILABLE"
    public static let CODE_NETWORK = "NETWORK"
    public static let CODE_DECODING = "DECODING"
    public static let CODE_SERVER = "SERVER"
    public static let CODE_STORE_PRODUCTS_MISSING = "STORE_PRODUCTS_MISSING"
    public static let CODE_CUSTOMER_NOT_FOUND = "CUSTOMER_NOT_FOUND"
    public static let CODE_PURCHASE_FAILED = "PURCHASE_FAILED"
    public static let CODE_RECEIPT_POST_FAILED = "RECEIPT_POST_FAILED"
    public static let CODE_RECEIPT_QUEUED_FOR_RETRY = "RECEIPT_QUEUED_FOR_RETRY"
    public static let CODE_PURCHASE_ALREADY_IN_PROGRESS = "PURCHASE_ALREADY_IN_PROGRESS"
    public static let CODE_PRODUCT_NOT_AVAILABLE = "PRODUCT_NOT_AVAILABLE"
    public static let CODE_SIGNATURE_VERIFICATION_FAILED = "SIGNATURE_VERIFICATION_FAILED"
    public static let CODE_INVALID_OFFER = "INVALID_OFFER"
    public static let CODE_PURCHASE_INELIGIBLE = "PURCHASE_INELIGIBLE"
    public static let CODE_UNKNOWN = "UNKNOWN"

    // MARK: - Properties

    /// Machine-readable error code (one of the `CODE_*` constants).
    public let code: String

    /// Human-readable error message.
    public let message: String

    /// Whether this error is transient and the operation may succeed on retry.
    public let isTransient: Bool

    /// HTTP status code from the server, if applicable.
    public let statusCode: Int?

    /// Debug-level detail (server error code, request ID, etc.).
    public let debugMessage: String?

    /// Backend-specific error code when available.
    public let backendCode: String?

    /// Server-assigned trace identifier when available.
    public let requestId: String?

    /// Rate-limit or backend scope when available.
    public let scope: String?

    /// Server-suggested retry delay in seconds when available.
    public let retryAfterSeconds: Double?

    // MARK: - Init from Error

    public init(from error: Error) {
        if let appError = error as? AppActorError {
            self.code = Self.mapKind(appError.kind)
            self.message = appError.errorDescription ?? appError.message ?? "Unknown error"
            self.isTransient = appError.isTransient
            self.statusCode = appError.httpStatus
            self.backendCode = appError.code
            self.requestId = appError.requestId
            self.scope = appError.scope
            self.retryAfterSeconds = appError.retryAfterSeconds
            self.debugMessage = Self.buildDebugMessage(appError)
        } else {
            self.code = Self.CODE_UNKNOWN
            self.message = error.localizedDescription
            self.isTransient = false
            self.statusCode = nil
            self.backendCode = nil
            self.requestId = nil
            self.scope = nil
            self.retryAfterSeconds = nil
            self.debugMessage = String(describing: error)
        }
    }

    // MARK: - Memberwise Init

    public init(
        code: String,
        message: String,
        isTransient: Bool = false,
        statusCode: Int? = nil,
        debugMessage: String? = nil,
        backendCode: String? = nil,
        requestId: String? = nil,
        scope: String? = nil,
        retryAfterSeconds: Double? = nil
    ) {
        self.code = code
        self.message = message
        self.isTransient = isTransient
        self.statusCode = statusCode
        self.debugMessage = debugMessage
        self.backendCode = backendCode
        self.requestId = requestId
        self.scope = scope
        self.retryAfterSeconds = retryAfterSeconds
    }

    // MARK: - Dictionary Serialization

    /// Converts to a dictionary for FFI channel serialization.
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "code": code,
            "message": message,
            "isTransient": isTransient,
        ]
        if let statusCode { dict["statusCode"] = statusCode }
        if let debugMessage { dict["debugMessage"] = debugMessage }
        if let backendCode { dict["backendCode"] = backendCode }
        if let requestId { dict["requestId"] = requestId }
        if let scope { dict["scope"] = scope }
        if let retryAfterSeconds { dict["retryAfterSeconds"] = retryAfterSeconds }
        return dict
    }

    // MARK: - Private Helpers

    private static func mapKind(_ kind: AppActorError.Kind) -> String {
        switch kind {
        case .notConfigured:                    return CODE_NOT_CONFIGURED
        case .alreadyConfigured:                return CODE_ALREADY_CONFIGURED
        case .validation:                       return CODE_VALIDATION
        case .notAvailable:                     return CODE_NOT_AVAILABLE
        case .network:                          return CODE_NETWORK
        case .decoding:                         return CODE_DECODING
        case .server:                           return CODE_SERVER
        case .storeKitProductsMissing:          return CODE_STORE_PRODUCTS_MISSING
        case .customerNotFound:                 return CODE_CUSTOMER_NOT_FOUND
        case .purchaseFailed:                   return CODE_PURCHASE_FAILED
        case .receiptPostFailed:                return CODE_RECEIPT_POST_FAILED
        case .receiptQueuedForRetry:            return CODE_RECEIPT_QUEUED_FOR_RETRY
        case .purchaseAlreadyInProgress:        return CODE_PURCHASE_ALREADY_IN_PROGRESS
        case .productNotAvailableInStorefront:  return CODE_PRODUCT_NOT_AVAILABLE
        case .signatureVerificationFailed,
             .signatureTimestampOutOfRange,
             .signatureMissing,
             .nonceMismatch,
             .intermediateCertInvalid,
             .intermediateKeyExpired:           return CODE_SIGNATURE_VERIFICATION_FAILED
        case .invalidOffer:                     return CODE_INVALID_OFFER
        case .purchaseIneligible:               return CODE_PURCHASE_INELIGIBLE
        }
    }

    private static func buildDebugMessage(_ error: AppActorError) -> String? {
        var parts: [String] = []
        if let code = error.code { parts.append("code=\(code)") }
        if let details = error.details { parts.append("details=\(details)") }
        if let requestId = error.requestId { parts.append("requestId=\(requestId)") }
        if let scope = error.scope { parts.append("scope=\(scope)") }
        if let retry = error.retryAfterSeconds { parts.append("retryAfter=\(retry)s") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
