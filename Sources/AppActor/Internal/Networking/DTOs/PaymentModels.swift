import Foundation

/// Optional device metadata the caller can provide to identify.
struct AppActorPaymentDeviceInfo: Sendable {
    let platform: String?
    let appVersion: String?
    let sdkVersion: String?
    let deviceLocale: String?
    let deviceModel: String?
    let osVersion: String?

    init(
        platform: String? = nil,
        appVersion: String? = nil,
        sdkVersion: String? = nil,
        deviceLocale: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.deviceLocale = deviceLocale
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }
}

// MARK: - Request Bodies

/// POST /v1/payment/identify
struct AppActorIdentifyRequest: Encodable {
    let appUserId: String
    let platform: String?
    let appVersion: String?
    let sdkVersion: String?
    let deviceLocale: String?
    let deviceModel: String?
    let osVersion: String?
    let platformFlavor: String?
    let platformVersion: String?
}

/// POST /v1/payment/login
struct AppActorLoginRequest: Encodable {
    let currentAppUserId: String
    let newAppUserId: String
}

// MARK: - Identify Result

/// Result type for `POST /v1/payment/identify`.
///
/// The contract returns a flat body with identity + customer snapshot.
/// The `customerETag` comes from the `ETag` response header.
struct AppActorIdentifyResult: Sendable {
    let appUserId: String
    let customerInfo: AppActorCustomerInfo
    let customerETag: String?
    let requestId: String?
    /// Whether the response was cryptographically verified via Ed25519 signature.
    let signatureVerified: Bool
}

/// Flat response DTO for `POST /v1/payment/identify`.
///
/// Supports both the legacy flat payload
/// `{ requestDate, requestDateMs, requestId, appUserId, customer }`
/// and the newer `{ data: { user: ... }, requestId? }` contract.
struct AppActorIdentifyResponseDTO: Decodable, Sendable {
    let requestDate: String?
    let requestDateMs: Int64?
    let requestId: String?
    let appUserId: String
    let customer: AppActorCustomerDTO

    private enum CodingKeys: String, CodingKey {
        case requestDate, requestDateMs, requestId, appUserId, serverUserId, customer, data
    }

    private enum DataCodingKeys: String, CodingKey {
        case appUserId, serverUserId, customer, user, requestDate, requestDateMs, requestId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let appUserId = try? container.decode(String.self, forKey: .appUserId),
           let customer = try? container.decode(AppActorCustomerDTO.self, forKey: .customer) {
            self.requestDate = try? container.decodeIfPresent(String.self, forKey: .requestDate)
            self.requestDateMs = try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs)
            self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
            self.appUserId = appUserId
            self.customer = customer
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        if let appUserId = try? data.decode(String.self, forKey: .appUserId),
           let customer = try? data.decode(AppActorCustomerDTO.self, forKey: .customer) {
            self.requestDate = (try? container.decodeIfPresent(String.self, forKey: .requestDate))
                ?? (try? data.decodeIfPresent(String.self, forKey: .requestDate))
            self.requestDateMs = (try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs))
                ?? (try? data.decodeIfPresent(Int64.self, forKey: .requestDateMs))
            self.requestId = (try? container.decodeIfPresent(String.self, forKey: .requestId))
                ?? (try? data.decodeIfPresent(String.self, forKey: .requestId))
            self.appUserId = appUserId
            self.customer = customer
            return
        }

        let user = try data.decode(AppActorPaymentUserDTO.self, forKey: .user)
        self.requestDate = (try? container.decodeIfPresent(String.self, forKey: .requestDate))
            ?? (try? data.decodeIfPresent(String.self, forKey: .requestDate))
        self.requestDateMs = (try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs))
            ?? (try? data.decodeIfPresent(Int64.self, forKey: .requestDateMs))
        self.requestId = (try? container.decodeIfPresent(String.self, forKey: .requestId))
            ?? (try? data.decodeIfPresent(String.self, forKey: .requestId))
        self.appUserId = user.appUserId
        self.customer = user.customerDTO
    }
}

// MARK: - Login Result

/// Result type for `POST /v1/payment/login`.
///
/// Login now returns the same flat format as identify:
/// `{ requestDate, requestDateMs, requestId, appUserId, serverUserId, customer }`.
struct AppActorLoginResult: Sendable {
    let appUserId: String
    let customerInfo: AppActorCustomerInfo
    let customerETag: String?
    let requestId: String?
    let signatureVerified: Bool
}

/// Flat response DTO for `POST /v1/payment/login`.
struct AppActorLoginResponseDTO: Decodable, Sendable {
    let requestDate: String?
    let requestDateMs: Int64?
    let requestId: String?
    let appUserId: String
    let customer: AppActorCustomerDTO

    private enum CodingKeys: String, CodingKey {
        case requestDate, requestDateMs, requestId, appUserId, serverUserId, customer, data
    }

    private enum DataCodingKeys: String, CodingKey {
        case requestDate, requestDateMs, requestId, appUserId, serverUserId, customer, user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let appUserId = try? container.decode(String.self, forKey: .appUserId),
           let customer = try? container.decode(AppActorCustomerDTO.self, forKey: .customer) {
            self.requestDate = try? container.decodeIfPresent(String.self, forKey: .requestDate)
            self.requestDateMs = try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs)
            self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
            self.appUserId = appUserId
            self.customer = customer
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        if let appUserId = try? data.decode(String.self, forKey: .appUserId),
           let customer = try? data.decode(AppActorCustomerDTO.self, forKey: .customer) {
            self.requestDate = (try? container.decodeIfPresent(String.self, forKey: .requestDate))
                ?? (try? data.decodeIfPresent(String.self, forKey: .requestDate))
            self.requestDateMs = (try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs))
                ?? (try? data.decodeIfPresent(Int64.self, forKey: .requestDateMs))
            self.requestId = (try? container.decodeIfPresent(String.self, forKey: .requestId))
                ?? (try? data.decodeIfPresent(String.self, forKey: .requestId))
            self.appUserId = appUserId
            self.customer = customer
            return
        }

        let user = try data.decode(AppActorPaymentUserDTO.self, forKey: .user)
        self.requestDate = (try? container.decodeIfPresent(String.self, forKey: .requestDate))
            ?? (try? data.decodeIfPresent(String.self, forKey: .requestDate))
        self.requestDateMs = (try? container.decodeIfPresent(Int64.self, forKey: .requestDateMs))
            ?? (try? data.decodeIfPresent(Int64.self, forKey: .requestDateMs))
        self.requestId = (try? container.decodeIfPresent(String.self, forKey: .requestId))
            ?? (try? data.decodeIfPresent(String.self, forKey: .requestId))
        self.appUserId = user.appUserId
        self.customer = user.customerDTO
    }
}

private struct AppActorPaymentUserDTO: Decodable, Sendable {
    let appUserId: String
    let entitlements: [String: AppActorEntitlementDTO]?
    let subscriptions: [String: AppActorSubscriptionDTO]?
    let nonSubscriptions: [String: [AppActorNonSubscriptionDTO]]?
    let tokenBalance: AppActorTokenBalanceDTO?
    let firstSeenAt: String?
    let lastSeenAt: String?

    var customerDTO: AppActorCustomerDTO {
        AppActorCustomerDTO(
            entitlements: entitlements,
            subscriptions: subscriptions,
            nonSubscriptions: nonSubscriptions,
            managementUrl: nil,
            tokenBalance: tokenBalance,
            firstSeen: firstSeenAt,
            lastSeen: lastSeenAt
        )
    }
}

// MARK: - Response Envelope

/// Success envelope: `{ "data": T, "requestId": "..." }`
struct AppActorPaymentResponse<T: Decodable>: Decodable {
    let data: T
    let requestId: String?
}

/// Error envelope: `{ "error": { "code": ..., "message": ..., "details": ... }, "requestId": "..." }`
struct AppActorErrorResponse: Decodable {
    let error: ErrorPayload
    let requestId: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case requestId
        case retryAfterSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topLevelRetryAfter = try container.decodeIfPresent(Double.self, forKey: .retryAfterSeconds)
        let decodedError = try container.decode(ErrorPayload.self, forKey: .error)
        if decodedError.retryAfterSeconds == nil, let topLevelRetryAfter {
            self.error = ErrorPayload(
                code: decodedError.code,
                message: decodedError.message,
                details: decodedError.details,
                scope: decodedError.scope,
                retryAfterSeconds: topLevelRetryAfter
            )
        } else {
            self.error = decodedError
        }
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
    }

    struct ErrorPayload: Decodable {
        let code: String?
        let message: String?
        let details: String?
        /// Which rate-limit layer triggered the error (e.g. "ip", "app", "route").
        let scope: String?
        /// Server-suggested retry delay in seconds.
        let retryAfterSeconds: Double?
    }
}

// MARK: - Validation

enum AppActorPaymentValidation {

    /// Validates an appUserId: non-empty, <=255, not "nan".
    static func validateAppUserId(_ id: String) throws {
        guard !id.isEmpty else {
            throw AppActorError.validationError("appUserId must not be empty")
        }
        guard id.count <= 255 else {
            throw AppActorError.validationError("appUserId must be at most 255 characters")
        }
        guard id.lowercased() != "nan" else {
            throw AppActorError.validationError("appUserId must not be 'nan'")
        }
    }
}
