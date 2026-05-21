import Foundation

/// All errors that AppActor can throw.
///
/// This is a rich error type with structured metadata. Use `kind` to categorize
/// the error and metadata fields (`httpStatus`, `code`, `message`, etc.) for details.
public struct AppActorError: Error, Sendable, LocalizedError {

    /// Category of the error.
    public enum Kind: String, Sendable {
        /// SDK not configured. Call AppActor.configure() first.
        case notConfigured
        /// configure() was called more than once.
        case alreadyConfigured
        /// Client-side validation failure.
        case validation
        /// A feature is not available on the current platform.
        case notAvailable
        /// Network connectivity or timeout.
        case network
        /// Failed to decode server response.
        case decoding
        /// Server returned a non-2xx response.
        case server
        /// All StoreKit products for offerings were missing from the App Store.
        case storeKitProductsMissing
        /// Customer not found (404 from server).
        case customerNotFound
        /// StoreKit purchase call itself failed (user-facing StoreKit error).
        case purchaseFailed
        /// Receipt post to server permanently failed (server rejected or no customer info).
        case receiptPostFailed
        /// Purchase succeeded at StoreKit level but server validation is pending.
        /// The receipt is queued for automatic retry. This is a transient condition.
        case receiptQueuedForRetry
        /// A purchase is already in progress.
        case purchaseAlreadyInProgress
        /// The product is not available in the user's storefront.
        case productNotAvailableInStorefront
        /// Response signature verification failed (tampered or forged response).
        case signatureVerificationFailed
        /// Response signature timestamp is outside the acceptable drift window.
        case signatureTimestampOutOfRange
        /// Server did not include a response signature when one was expected.
        case signatureMissing
        /// The nonce echoed by the server does not match the one sent in the request.
        case nonceMismatch
        /// v2: Intermediate key's root certification is invalid.
        case intermediateCertInvalid
        /// v2: Intermediate signing key has expired.
        case intermediateKeyExpired
        /// An offer parameter was invalid (identifier, price, signature, or missing).
        case invalidOffer
        /// The user is not eligible for the specified offer.
        case purchaseIneligible
    }

    public let kind: Kind
    public let httpStatus: Int?
    public let code: String?
    public let message: String?
    public let details: String?
    public let requestId: String?
    public let underlying: Error?
    /// Which rate-limit layer triggered the error (e.g. "ip", "app", "route"). Nil for non-rate-limit errors.
    public let scope: String?
    /// Server-suggested retry delay in seconds. Nil when the server doesn't provide one.
    public let retryAfterSeconds: Double?

    public var errorDescription: String? {
        switch kind {
        case .notConfigured:
            return "[AppActor] SDK is not configured. Call AppActor.configure() first."
        case .alreadyConfigured:
            return "[AppActor] SDK is already configured. configure() can only be called once."
        case .validation:
            return "[AppActor] Validation: \(message ?? "invalid input")"
        case .notAvailable:
            return "[AppActor] Feature not available: \(message ?? "unknown")"
        case .network:
            let detail = underlying?.localizedDescription ?? "unknown"
            return "[AppActor] Network error: \(detail)"
        case .decoding:
            let detail = underlying?.localizedDescription ?? "unknown"
            return "[AppActor] Decoding error: \(detail)"
        case .server:
            let status = httpStatus.map { "\($0)" } ?? "?"
            let serverCode = code ?? "UNKNOWN"
            let msg = message ?? "no details"
            return "[AppActor] Server error \(status) (\(serverCode)): \(msg)"
        case .storeKitProductsMissing:
            let msg = message ?? "none of the configured product IDs were found in the App Store"
            return "[AppActor] StoreKit products missing: \(msg)"
        case .customerNotFound:
            let userId = message ?? "unknown"
            return "[AppActor] Customer not found: \(userId)"
        case .purchaseFailed:
            let detail = underlying?.localizedDescription ?? message ?? "unknown error"
            return "[AppActor] Purchase failed: \(detail)"
        case .receiptPostFailed:
            var desc = "[AppActor] Receipt post failed"
            if let code { desc += " (\(code))" }
            desc += ": \(message ?? "unknown error")"
            if let requestId { desc += " [ref: \(requestId)]" }
            return desc
        case .receiptQueuedForRetry:
            return "[AppActor] Purchase succeeded but server validation is pending. Receipt is queued for automatic retry."
        case .purchaseAlreadyInProgress:
            return "[AppActor] A purchase is already in progress. Wait for it to complete before starting another."
        case .productNotAvailableInStorefront:
            return "[AppActor] Product is not available in the current storefront."
        case .signatureVerificationFailed:
            return "[AppActor] Response signature verification failed — response may have been tampered with."
        case .signatureTimestampOutOfRange:
            return "[AppActor] Response signature timestamp is outside the acceptable window."
        case .signatureMissing:
            return "[AppActor] Server did not include an expected response signature."
        case .nonceMismatch:
            return "[AppActor] Response nonce does not match the sent request nonce."
        case .intermediateCertInvalid:
            return "[AppActor] Intermediate signing key certification is invalid — possible key compromise."
        case .intermediateKeyExpired:
            return "[AppActor] Intermediate signing key has expired — server may need key rotation."
        case .invalidOffer:
            return "[AppActor] Purchase failed: invalid offer parameters."
        case .purchaseIneligible:
            return "[AppActor] Purchase failed: user is not eligible for this offer."
        }
    }

    // MARK: - Transient Classification

    /// Whether this error is transient and the operation may succeed on retry.
    /// Transient: network errors, `receiptQueuedForRetry`, 429 (rate limit), 5xx (server errors).
    /// Permanent: 4xx client errors (except 429), `receiptPostFailed`, `purchaseFailed`.
    var isTransient: Bool {
        switch kind {
        case .network, .receiptQueuedForRetry:
            return true
        case .server:
            guard let status = httpStatus else { return false }
            return status == 429 || status >= 500
        default:
            return false
        }
    }

    /// Whether this is a permanent client error (4xx excluding 429).
    /// These errors will never succeed on retry and should be treated as final.
    ///
    /// 4xx = client error per HTTP spec: the request itself is invalid.
    /// Retrying an invalid request will always fail — dead-letter immediately.
    /// 401/403 auth failures are permanent: if the API key is wrong, retrying
    /// won't fix it. A server that temporarily can't decrypt a key should return
    /// 500, not 401 — that's a server-side bug to fix server-side.
    /// 429 is excluded because it is a rate-limit signal (retry after backoff).
    var isPermanentClientError: Bool {
        kind == .server
            && httpStatus != nil
            && (400..<500).contains(httpStatus!)
            && httpStatus != 429
    }

    /// Receipt POST-specific 4xx codes that should be treated as transient until
    /// the backend has finished establishing the local identity.
    var isRetryableReceiptClientError: Bool {
        guard isPermanentClientError else { return false }
        switch code {
        case "USER_NOT_FOUND", "PROFILE_NOT_READY", "IDENTITY_NOT_PROPAGATED":
            return true
        default:
            return false
        }
    }

    // MARK: - Convenience Factories

    /// Internal helper for errors without HTTP/server metadata.
    /// Reduces 9-param init boilerplate for client-side errors.
    static func clientError(
        kind: Kind,
        code: String? = nil,
        message: String? = nil,
        requestId: String? = nil,
        underlying: Error? = nil
    ) -> AppActorError {
        AppActorError(
            kind: kind, httpStatus: nil, code: code,
            message: message, details: nil, requestId: requestId,
            underlying: underlying, scope: nil, retryAfterSeconds: nil
        )
    }

    /// SDK not configured.
    public static let notConfigured = clientError(kind: .notConfigured)

    /// Feature not available on current platform.
    public static func notAvailable(_ reason: String) -> AppActorError {
        .clientError(kind: .notAvailable, message: reason)
    }

    static func validationError(_ message: String) -> AppActorError {
        .clientError(kind: .validation, code: "VALIDATION_ERROR", message: message)
    }

    static func offeringsCacheMiss() -> AppActorError {
        .clientError(
            kind: .validation,
            code: "OFFERINGS_CACHE_MISS",
            message: "No locale-compatible cached offerings are available."
        )
    }

    static func networkError(_ error: Error) -> AppActorError {
        .clientError(kind: .network, message: error.localizedDescription, underlying: error)
    }

    static func decodingError(_ error: Error, requestId: String?) -> AppActorError {
        .clientError(kind: .decoding, message: error.localizedDescription, requestId: requestId, underlying: error)
    }

    static func serverError(
        httpStatus: Int,
        code: String?,
        message: String?,
        details: String?,
        requestId: String?,
        scope: String? = nil,
        retryAfterSeconds: Double? = nil
    ) -> AppActorError {
        AppActorError(
            kind: .server, httpStatus: httpStatus, code: code,
            message: message, details: details,
            requestId: requestId, underlying: nil,
            scope: scope, retryAfterSeconds: retryAfterSeconds
        )
    }

    static func storeKitProductsMissing(requestedIds: Set<String>) -> AppActorError {
        let ids = requestedIds.sorted().joined(separator: ", ")
        return .clientError(
            kind: .storeKitProductsMissing,
            code: "STOREKIT_PRODUCTS_MISSING",
            message: "None of the requested product IDs were found: \(ids)"
        )
    }

    static func customerNotFound(appUserId: String, requestId: String?) -> AppActorError {
        AppActorError(
            kind: .customerNotFound, httpStatus: 404,
            code: "CUSTOMER_NOT_FOUND",
            message: appUserId, details: nil,
            requestId: requestId, underlying: nil,
            scope: nil, retryAfterSeconds: nil
        )
    }

    static func receiptPostFailed(_ message: String, underlying: Error? = nil) -> AppActorError {
        .clientError(kind: .receiptPostFailed, code: "RECEIPT_POST_FAILED", message: message, underlying: underlying)
    }

    static let purchaseAlreadyInProgress = clientError(
        kind: .purchaseAlreadyInProgress,
        code: "PURCHASE_IN_PROGRESS",
        message: "A purchase is already in progress"
    )

    static func signatureError(_ kind: Kind, requestId: String? = nil) -> AppActorError {
        .clientError(kind: kind, code: "SIGNATURE_\(kind.rawValue.uppercased())", requestId: requestId)
    }
}
