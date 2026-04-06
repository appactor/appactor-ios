import Foundation
import AppActor

/// Cross-platform error type with numeric codes.
/// All SDK and plugin errors are converted to this format.
public struct AppActorPluginError: Encodable, Error, Sendable {

    public let code: Int
    public let message: String
    public let detail: String
    public let requestId: String?
    public let scope: String?
    public let retryAfterSeconds: Double?

    // MARK: - Plugin Internal Codes (1xxx)

    static let encodingFailed = 1001
    static let decodingFailed = 1002
    static let unknownMethod  = 1003

    // MARK: - SDK Codes (2xxx)

    static let sdkNotConfigured         = 2001
    static let sdkAlreadyConfigured     = 2002
    static let sdkValidation            = 2003
    static let sdkNotAvailable          = 2004
    static let sdkNetwork               = 2005
    static let sdkDecoding              = 2006
    static let sdkServer                = 2007
    static let sdkStoreProductsMissing  = 2008
    static let sdkCustomerNotFound      = 2009
    static let sdkPurchaseFailed        = 2010
    static let sdkReceiptPostFailed     = 2011
    static let sdkReceiptQueuedForRetry = 2012
    static let sdkPurchaseInProgress    = 2013
    static let sdkProductNotAvailable   = 2014
    static let sdkSignatureVerification = 2015
    static let sdkInvalidOffer          = 2016
    static let sdkPurchaseIneligible    = 2017
    static let sdkUnknown               = 2099

    // MARK: - Init

    /// Creates a plugin error envelope that can be returned from custom requests.
    public init(code: Int, message: String, detail: String = "",
                requestId: String? = nil, scope: String? = nil, retryAfterSeconds: Double? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
        self.requestId = requestId
        self.scope = scope
        self.retryAfterSeconds = retryAfterSeconds
    }

    init(from error: Error) {
        let bridgeError = AppActorBridgeError(from: error)
        self.code = Self.codeFromBridgeCode(bridgeError.code)
        self.message = bridgeError.message
        self.detail = [
            bridgeError.debugMessage,
            bridgeError.statusCode.map { "httpStatus=\($0)" },
            bridgeError.isTransient ? "transient=true" : nil
        ].compactMap { $0 }.joined(separator: ", ")

        // Extract structured fields from original error
        if let appError = error as? AppActorError {
            self.requestId = appError.requestId
            self.scope = appError.scope
            self.retryAfterSeconds = appError.retryAfterSeconds
        } else {
            self.requestId = nil
            self.scope = nil
            self.retryAfterSeconds = nil
        }
    }

    // MARK: - Bridge Code → Numeric

    private static func codeFromBridgeCode(_ code: String) -> Int {
        switch code {
        case AppActorBridgeError.CODE_NOT_CONFIGURED:               return sdkNotConfigured
        case AppActorBridgeError.CODE_ALREADY_CONFIGURED:           return sdkAlreadyConfigured
        case AppActorBridgeError.CODE_VALIDATION:                   return sdkValidation
        case AppActorBridgeError.CODE_NOT_AVAILABLE:                return sdkNotAvailable
        case AppActorBridgeError.CODE_NETWORK:                      return sdkNetwork
        case AppActorBridgeError.CODE_DECODING:                     return sdkDecoding
        case AppActorBridgeError.CODE_SERVER:                       return sdkServer
        case AppActorBridgeError.CODE_STORE_PRODUCTS_MISSING:       return sdkStoreProductsMissing
        case AppActorBridgeError.CODE_CUSTOMER_NOT_FOUND:           return sdkCustomerNotFound
        case AppActorBridgeError.CODE_PURCHASE_FAILED:              return sdkPurchaseFailed
        case AppActorBridgeError.CODE_RECEIPT_POST_FAILED:          return sdkReceiptPostFailed
        case AppActorBridgeError.CODE_RECEIPT_QUEUED_FOR_RETRY:     return sdkReceiptQueuedForRetry
        case AppActorBridgeError.CODE_PURCHASE_ALREADY_IN_PROGRESS: return sdkPurchaseInProgress
        case AppActorBridgeError.CODE_PRODUCT_NOT_AVAILABLE:        return sdkProductNotAvailable
        case AppActorBridgeError.CODE_SIGNATURE_VERIFICATION_FAILED: return sdkSignatureVerification
        case AppActorBridgeError.CODE_INVALID_OFFER:                return sdkInvalidOffer
        case AppActorBridgeError.CODE_PURCHASE_INELIGIBLE:          return sdkPurchaseIneligible
        default:                                                     return sdkUnknown
        }
    }
}
