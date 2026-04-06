import Foundation

// MARK: - Protocol

/// Abstraction for payment HTTP calls. Enables testing with mocks.
protocol AppActorPaymentClientProtocol: Sendable {
    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult
    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult
    func logout(_ request: AppActorLogoutRequest) async throws -> AppActorPaymentResult<Bool>
    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult
    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult
    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult
    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse
    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult

    // Experiments
    func postExperimentAssignment(experimentKey: String, appUserId: String, appVersion: String?, country: String?) async throws -> AppActorExperimentFetchResult

    // ASA (Apple Search Ads)
    func postASAAttribution(_ request: AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO
    func postASAPurchaseEvent(_ request: AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO
    func postASAUpdateUserId(_ request: AppActorASAUpdateUserIdRequest) async throws -> AppActorASAUpdateUserIdResponseDTO
}

// MARK: - Live Client

/// URLSession-based payment API client with retry support.
final class AppActorPaymentClient: AppActorPaymentClientProtocol, Sendable {

    private let baseURL: URL
    private let apiKey: String
    private let headerMode: AppActorPaymentConfiguration.HeaderMode
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxRetries: Int
    private let verifySignatures: Bool
    private let requireSignatures: Bool
    private let responseLogger: (@Sendable (_ path: String, _ status: Int, _ body: Data) -> Void)?

    init(
        baseURL: URL,
        apiKey: String,
        headerMode: AppActorPaymentConfiguration.HeaderMode = .bearer,
        session: URLSession? = nil,
        maxRetries: Int = 3,
        verifySignatures: Bool = true,
        requireSignatures: Bool = true,
        responseLogger: (@Sendable (_ path: String, _ status: Int, _ body: Data) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.headerMode = headerMode
        // Use an ephemeral session by default so URLSession's HTTP cache does NOT
        // transparently convert 304→200 (which would strip response-signing headers).
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
        self.maxRetries = maxRetries
        // requireSignatures implies verifySignatures — prevent silent bypass
        self.verifySignatures = verifySignatures || requireSignatures
        self.requireSignatures = requireSignatures
        self.responseLogger = responseLogger

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .useDefaultKeys
        self.encoder = enc

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .useDefaultKeys
        self.decoder = dec
    }

    // MARK: - Public API

    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult {
        let path = "/v1/payment/identify"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 30

        Log.network.debug("identify request → \(path)")

        return try await performRetryableRequest(urlRequest, path: path) { data, http, signatureVerified, requestId in
            guard (200..<300).contains(http.statusCode) else {
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
            let dto: AppActorIdentifyResponseDTO
            do {
                dto = try self.decoder.decode(AppActorIdentifyResponseDTO.self, from: data)
            } catch {
                Log.network.error("Decode failed for \(path): \(error)")
                throw AppActorError.decodingError(error, requestId: requestId)
            }
            let customerInfo = AppActorCustomerInfo(
                dto: dto.customer,
                appUserId: dto.appUserId,
                requestDate: dto.requestDate,
                requestId: dto.requestId
            )
            let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
            return AppActorIdentifyResult(
                appUserId: dto.appUserId,
                customerInfo: customerInfo,
                customerETag: responseETag,
                requestId: dto.requestId ?? requestId,
                signatureVerified: signatureVerified
            )
        }
    }

    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult {
        let path = "/v1/payment/login"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 30

        Log.network.debug("login request → \(path)")

        return try await performRetryableRequest(urlRequest, path: path) { data, http, signatureVerified, requestId in
            guard (200..<300).contains(http.statusCode) else {
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
            let dto: AppActorLoginResponseDTO
            do {
                dto = try self.decoder.decode(AppActorLoginResponseDTO.self, from: data)
            } catch {
                Log.network.error("Decode failed for \(path): \(error)")
                throw AppActorError.decodingError(error, requestId: requestId)
            }
            let customerInfo = AppActorCustomerInfo(
                dto: dto.customer,
                appUserId: dto.appUserId,
                requestDate: dto.requestDate,
                requestId: dto.requestId
            )
            let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
            return AppActorLoginResult(
                appUserId: dto.appUserId,
                serverUserId: dto.serverUserId,
                customerInfo: customerInfo,
                customerETag: responseETag,
                requestId: dto.requestId ?? requestId,
                signatureVerified: signatureVerified
            )
        }
    }

    func logout(_ request: AppActorLogoutRequest) async throws -> AppActorPaymentResult<Bool> {
        let response: AppActorPaymentResponse<AppActorLogoutData> = try await post(
            path: "/v1/payment/logout",
            body: request
        )
        return AppActorPaymentResult(value: response.data.success ?? true, requestId: response.requestId)
    }

    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult {
        let path = "/v1/payment/offerings"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &urlRequest)
        urlRequest.timeoutInterval = 30

        return try await performRetryableRequest(urlRequest, path: path, eTag: eTag) { data, http, signatureVerified, requestId in
            switch http.statusCode {
            case 200:
                let dto: AppActorOfferingsResponseDTO
                do {
                    let envelope = try self.decoder.decode(AppActorPaymentResponse<AppActorOfferingsResponseDTO>.self, from: data)
                    dto = envelope.data
                } catch {
                    Log.network.error("Decode failed for \(path): \(error)")
                    throw AppActorError.decodingError(error, requestId: requestId)
                }
                let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                return .fresh(dto, eTag: responseETag, requestId: requestId, signatureVerified: signatureVerified)

            case 304:
                let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                return .notModified(eTag: responseETag, requestId: requestId)

            default:
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
        }
    }

    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult {
        // Encode for a single path segment: exclude '/' so IDs containing slashes
        // don't alter path structure (e.g. "foo/bar" → "foo%2Fbar").
        var pathSegmentAllowed = CharacterSet.urlPathAllowed
        pathSegmentAllowed.remove("/")
        let encodedId = appUserId.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? appUserId
        let path = "/v1/customers/\(encodedId)"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &urlRequest)
        urlRequest.timeoutInterval = 30

        return try await performRetryableRequest(
            urlRequest,
            path: path,
            eTag: eTag,
            additionalNonRetryHandler: { statusCode, data, requestId in
                guard statusCode == 404 else { return nil }
                Log.network.error("404 \(path): customer not found")
                throw AppActorError.customerNotFound(appUserId: appUserId, requestId: requestId)
            },
            onSuccess: { data, http, signatureVerified, requestId in
                switch http.statusCode {
                case 200:
                    let dto: AppActorCustomerResponseDTO
                    do {
                        dto = try self.decoder.decode(AppActorCustomerResponseDTO.self, from: data)
                    } catch {
                        Log.network.error("Decode failed for \(path): \(error)")
                        if let bodySnippet = String(data: data.prefix(200), encoding: .utf8) {
                            Log.network.debug("Response snippet: \(bodySnippet)")
                        }
                        throw AppActorError.decodingError(error, requestId: requestId)
                    }
                    let info = AppActorCustomerInfo(dto: dto.customer, appUserId: appUserId, requestDate: dto.requestDate, requestId: dto.requestId)
                    let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                    return .fresh(info, eTag: responseETag, requestId: dto.requestId ?? requestId, signatureVerified: signatureVerified)

                case 304:
                    let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                    return .notModified(eTag: responseETag, requestId: requestId)

                default:
                    throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
                }
            }
        )
    }

    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult {
        let path = "/v1/remote-config"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AppActorError.networkError(URLError(.badURL))
        }
        var queryItems: [URLQueryItem] = []
        if let appUserId { queryItems.append(URLQueryItem(name: "app_user_id", value: appUserId)) }
        if let appVersion { queryItems.append(URLQueryItem(name: "app_version", value: appVersion)) }
        if let country { queryItems.append(URLQueryItem(name: "country", value: country)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        guard let url = components.url else {
            throw AppActorError.networkError(URLError(.badURL))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &urlRequest)
        urlRequest.timeoutInterval = 30

        return try await performRetryableRequest(urlRequest, path: path, eTag: eTag) { data, http, signatureVerified, requestId in
            switch http.statusCode {
            case 200:
                let items: [AppActorRemoteConfigItemDTO]
                do {
                    let envelope = try self.decoder.decode(AppActorPaymentResponse<[AppActorRemoteConfigItemDTO]>.self, from: data)
                    items = envelope.data
                } catch {
                    Log.network.error("Decode failed for \(path): \(error)")
                    throw AppActorError.decodingError(error, requestId: requestId)
                }
                let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                return .fresh(items, eTag: responseETag, requestId: requestId, signatureVerified: signatureVerified)

            case 304:
                let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
                return .notModified(eTag: responseETag, requestId: requestId)

            default:
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
        }
    }

    // MARK: - Experiments

    func postExperimentAssignment(
        experimentKey: String,
        appUserId: String,
        appVersion: String?,
        country: String?
    ) async throws -> AppActorExperimentFetchResult {
        let encodedKey = experimentKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? experimentKey
        let path = "/v1/experiments/\(encodedKey)/assignments"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AppActorError.networkError(URLError(.badURL))
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "app_user_id", value: appUserId)
        ]
        if let appVersion { queryItems.append(URLQueryItem(name: "app_version", value: appVersion)) }
        if let country { queryItems.append(URLQueryItem(name: "country", value: country)) }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AppActorError.networkError(URLError(.badURL))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &urlRequest)
        urlRequest.timeoutInterval = 30

        Log.network.debug("experiment assignment → \(path)")

        return try await performRetryableRequest(urlRequest, path: path) { data, http, signatureVerified, requestId in
            guard (200..<300).contains(http.statusCode) else {
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
            let dto: AppActorExperimentAssignmentDTO
            do {
                let envelope = try self.decoder.decode(
                    AppActorPaymentResponse<AppActorExperimentAssignmentDTO>.self, from: data
                )
                dto = envelope.data
            } catch {
                Log.network.error("Decode failed for \(path): \(error)")
                throw AppActorError.decodingError(error, requestId: requestId)
            }
            return .success(dto, requestId: requestId, signatureVerified: signatureVerified)
        }
    }

    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse {
        let path = "/v1/payment/receipts/apple"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 30

        // Single attempt — no HTTP-level retry. Retry is handled by ReceiptProcessor queue.
        do {
            let (data, http, _) = try await performRawRequest(urlRequest, path: path)
            let requestId = extractRequestId(from: data)

            switch http.statusCode {
            case 200..<300:
                do {
                    return try decoder.decode(AppActorReceiptPostResponse.self, from: data)
                } catch {
                    Log.network.error("Decode failed for \(path): \(error)")
                    throw AppActorError.decodingError(error, requestId: requestId)
                }

            case 400..<500:
                let errorInfo = parseErrorEnvelope(from: data)
                Log.network.error("\(http.statusCode) \(path): code=\(errorInfo?.code ?? "nil") message=\(errorInfo?.message ?? "nil")")
                throw AppActorError.serverError(
                    httpStatus: http.statusCode,
                    code: errorInfo?.code,
                    message: errorInfo?.message,
                    details: errorInfo?.details,
                    requestId: requestId,
                    scope: errorInfo?.scope,
                    retryAfterSeconds: errorInfo?.retryAfterSeconds
                )

            default:
                let errorInfo = parseErrorEnvelope(from: data)
                throw AppActorError.serverError(
                    httpStatus: http.statusCode,
                    code: errorInfo?.code ?? "INTERNAL_ERROR",
                    message: errorInfo?.message,
                    details: errorInfo?.details,
                    requestId: requestId
                )
            }
        } catch let error as AppActorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AppActorError.networkError(error)
        }
    }

    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult {
        let path = "/v1/payment/restore/apple"
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        urlRequest.timeoutInterval = 30

        Log.network.debug("restore request → \(path)")

        return try await performRetryableRequest(urlRequest, path: path) { data, http, signatureVerified, requestId in
            guard (200..<300).contains(http.statusCode) else {
                throw AppActorError.serverError(httpStatus: http.statusCode, code: "UNEXPECTED_STATUS", message: nil, details: nil, requestId: requestId)
            }
            let envelope: AppActorPaymentResponse<AppActorRestoreResponseData>
            do {
                envelope = try self.decoder.decode(AppActorPaymentResponse<AppActorRestoreResponseData>.self, from: data)
            } catch {
                Log.network.error("Decode failed for \(path): \(error)")
                throw AppActorError.decodingError(error, requestId: requestId)
            }
            let customerInfo = AppActorCustomerInfo(
                dto: envelope.data.user,
                appUserId: request.appUserId,
                requestDate: nil,
                requestId: envelope.requestId
            )
            let responseETag = self.normalizeETag(http.value(forHTTPHeaderField: "ETag"))
            return AppActorRestoreResult(
                customerInfo: customerInfo,
                restoredCount: envelope.data.restoredCount,
                transferred: envelope.data.transferred,
                requestId: envelope.requestId ?? requestId,
                customerETag: responseETag,
                signatureVerified: signatureVerified
            )
        }
    }

    // MARK: - ASA Endpoints

    func postASAAttribution(
        _ request: AppActorASAAttributionRequest
    ) async throws -> AppActorASAAttributionResponseDTO {
        try await postASA(path: "/v1/asa/attribution", body: request)
    }

    func postASAPurchaseEvent(
        _ request: AppActorASAPurchaseEventRequest
    ) async throws -> AppActorASAPurchaseEventResponseDTO {
        try await postASA(path: "/v1/asa/purchase-event", body: request)
    }

    func postASAUpdateUserId(
        _ request: AppActorASAUpdateUserIdRequest
    ) async throws -> AppActorASAUpdateUserIdResponseDTO {
        try await postASA(path: "/v1/asa/update-user-id", body: request)
    }

    /// Fire-and-forget style POST for ASA endpoints.
    /// Single attempt — retry is managed by ASAManager persistence queue.
    /// ASA responses use flat `{ status, ... }` format (not the standard `{ data, requestId }` envelope).
    private func postASA<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(body)
        urlRequest.timeoutInterval = 30

        do {
            let (data, http, _) = try await performRawRequest(urlRequest, path: path)
            let requestId = extractRequestId(from: data)

            switch http.statusCode {
            case 200..<300:
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch {
                    Log.network.error("Decode failed for \(path): \(error)")
                    throw AppActorError.decodingError(error, requestId: requestId)
                }

            case 429:
                let errorInfo = parseErrorEnvelope(from: data)
                let retryAfter = parseRetryAfterHeader(http.value(forHTTPHeaderField: "Retry-After"))
                    ?? errorInfo?.retryAfterSeconds
                Log.network.warn("Rate limited on \(path), retryAfter=\(retryAfter.map { "\($0)s" } ?? "–")")
                throw AppActorError.serverError(
                    httpStatus: 429,
                    code: errorInfo?.code ?? "RATE_LIMIT_EXCEEDED",
                    message: errorInfo?.message ?? "Rate limited",
                    details: errorInfo?.details,
                    requestId: requestId,
                    scope: errorInfo?.scope,
                    retryAfterSeconds: retryAfter
                )

            case 400..<500:
                let errorInfo = parseErrorEnvelope(from: data)
                Log.network.error("\(http.statusCode) \(path): code=\(errorInfo?.code ?? "nil") message=\(errorInfo?.message ?? "nil")")
                throw AppActorError.serverError(
                    httpStatus: http.statusCode,
                    code: errorInfo?.code,
                    message: errorInfo?.message,
                    details: errorInfo?.details,
                    requestId: requestId,
                    scope: errorInfo?.scope,
                    retryAfterSeconds: errorInfo?.retryAfterSeconds
                )

            default:
                let errorInfo = parseErrorEnvelope(from: data)
                throw AppActorError.serverError(
                    httpStatus: http.statusCode,
                    code: errorInfo?.code ?? "INTERNAL_ERROR",
                    message: errorInfo?.message,
                    details: errorInfo?.details,
                    requestId: requestId
                )
            }
        } catch let error as AppActorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AppActorError.networkError(error)
        }
    }

    // MARK: - Internal Networking

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &urlRequest)
        urlRequest.httpBody = try encoder.encode(body)
        urlRequest.timeoutInterval = 30

        return try await performRequest(urlRequest, path: path)
    }

    /// Normalize an ETag value: trim whitespace, return nil if empty.
    private func normalizeETag(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Applies authentication header and generates a nonce for response signature verification.
    /// - Returns: The generated nonce string (used later to verify the response signature).
    @discardableResult
    private func applyAuth(to request: inout URLRequest) -> String {
        switch headerMode {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let nonce = ResponseSignatureVerifier.generateNonce()
        request.setValue(nonce, forHTTPHeaderField: "X-AppActor-Nonce")
        return nonce
    }

    /// Executes a single HTTP request (no retry). Returns raw (Data, HTTPURLResponse, signatureVerified).
    /// Verifies Ed25519 response signature when enabled and the server provides one.
    /// The `signatureVerified` flag is `true` only when signature verification actually passed,
    /// `false` if verification was skipped or server didn't support signing.
    private func performRawRequest(
        _ urlRequest: URLRequest,
        path: String
    ) async throws -> (Data, HTTPURLResponse, Bool) {
        Log.network.debug("→ \(urlRequest.httpMethod ?? "?") \(path)")

        let sentNonce = urlRequest.value(forHTTPHeaderField: "X-AppActor-Nonce") ?? ""

        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw AppActorError.networkError(URLError(.badServerResponse))
        }

        let requestId = extractRequestId(from: data)
        if http.statusCode == 304 {
            Log.network.debug("← 304 \(path) (not modified)")
        } else {
            Log.network.debug("← \(http.statusCode) \(path)\(requestId.map { " [\($0)]" } ?? "")")
        }

        // Log rate-limit headers for observability
        logRateLimitHeaders(from: http, path: path)

        // Verify response signature (only for 2xx responses when enabled)
        var signatureVerified = false
        if verifySignatures && (200..<300).contains(http.statusCode) && !sentNonce.isEmpty {
            let result = ResponseSignatureVerifier.verify(
                response: http,
                body: data,
                sentNonce: sentNonce
            )

            switch result {
            case .success:
                signatureVerified = true
                Log.signing.debug("Signature verified for \(path)")
            case .signingNotSupported:
                if requireSignatures {
                    // Strict mode: reject unsigned responses even without nonce echo
                    Log.signing.error("Response signature required but server did not sign for \(path)")
                    throw AppActorError.signatureError(.signatureMissing, requestId: requestId)
                }
                // Transitional: server did not echo nonce — signing not enabled server-side
                Log.signing.debug("Response signing not active on server for \(path)")
            case .signatureMissing:
                // Server echoed nonce but signature is missing — possible MITM header strip
                Log.signing.error("Response signature missing (nonce was echoed) for \(path)")
                throw AppActorError.signatureError(.signatureMissing, requestId: requestId)
            case .signatureInvalid:
                Log.signing.error("Response signature INVALID for \(path)")
                throw AppActorError.signatureError(.signatureVerificationFailed, requestId: requestId)
            case .timestampOutOfRange:
                Log.signing.error("Response timestamp out of range for \(path)")
                throw AppActorError.signatureError(.signatureTimestampOutOfRange, requestId: requestId)
            case .nonceMismatch:
                Log.signing.error("Response nonce mismatch for \(path)")
                throw AppActorError.signatureError(.nonceMismatch, requestId: requestId)
            case .publicKeyUnavailable:
                Log.signing.error("Ed25519 public key unavailable")
                throw AppActorError.signatureError(.signatureVerificationFailed, requestId: requestId)
            case .intermediateCertInvalid:
                Log.signing.error("Intermediate key certification invalid for \(path)")
                throw AppActorError.signatureError(.intermediateCertInvalid, requestId: requestId)
            case .intermediateKeyExpired:
                Log.signing.error("Intermediate signing key expired for \(path)")
                throw AppActorError.signatureError(.intermediateKeyExpired, requestId: requestId)
            }
        }

        responseLogger?(path, http.statusCode, data)
        return (data, http, signatureVerified)
    }

    /// Simple retry wrapper that delegates to `performRetryableRequest`.
    /// Used by `post()` for login/logout — no ETag, no custom 4xx handler.
    private func performRequest<Response: Decodable>(
        _ urlRequest: URLRequest,
        path: String
    ) async throws -> Response {
        try await performRetryableRequest(urlRequest, path: path) { [decoder] data, http, _, requestId in
            guard (200..<300).contains(http.statusCode) else {
                throw AppActorError.serverError(
                    httpStatus: http.statusCode,
                    code: "UNEXPECTED_STATUS",
                    message: nil, details: nil, requestId: requestId
                )
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw AppActorError.decodingError(error, requestId: requestId)
            }
        }
    }

    // MARK: - Retry Helper

    /// Generic retry loop with exponential backoff + jitter, shared by all retryable endpoints.
    ///
    /// Handles:
    /// - Exponential backoff with jitter (base 1s, cap 30s, overall cap 120s)
    /// - ETag stripping on retry (prevents 304 loop)
    /// - Fresh nonce per attempt for unique response binding
    /// - 429 with Retry-After header parsing
    /// - 4xx → throw immediately (except 429)
    /// - 5xx → retry
    /// - Network errors (timeout, offline, connection lost) → retry
    /// - CancellationError → propagate
    ///
    /// - Parameters:
    ///   - urlRequest: The initial request. ETag is set on first attempt only.
    ///   - path: The API path for logging.
    ///   - eTag: Optional ETag for conditional request (first attempt only).
    ///   - additionalNonRetryHandler: Optional handler for custom non-retryable status codes
    ///     (e.g. 404 for customer not found). Return a value to short-circuit, or nil to fall through.
    ///   - onSuccess: Maps raw (data, http, signatureVerified, requestId) to the return type.
    private func performRetryableRequest<T>(
        _ urlRequest: URLRequest,
        path: String,
        eTag: String? = nil,
        additionalNonRetryHandler: ((_ statusCode: Int, _ data: Data, _ requestId: String?) throws -> T?)? = nil,
        onSuccess: (_ data: Data, _ http: HTTPURLResponse, _ signatureVerified: Bool, _ requestId: String?) throws -> T
    ) async throws -> T {
        var mutableRequest = urlRequest
        var lastError: Error = AppActorError.networkError(URLError(.unknown))
        var retryAfterOverride: TimeInterval?

        for attempt in 0..<maxRetries {
            if attempt > 0 {
                let base = min(pow(2.0, Double(attempt - 1)), 30.0)
                let jitter = Double.random(in: 0..<base)
                let ownDelay = base + jitter
                let delay = min(max(ownDelay, retryAfterOverride ?? 0), 120.0)
                retryAfterOverride = nil
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // Strip stale ETag on retry to avoid 304 loop
                mutableRequest.setValue(nil, forHTTPHeaderField: "If-None-Match")
                // Fresh nonce per attempt for unique response binding
                mutableRequest.setValue(ResponseSignatureVerifier.generateNonce(), forHTTPHeaderField: "X-AppActor-Nonce")
            } else if let normalized = normalizeETag(eTag) {
                mutableRequest.setValue(normalized, forHTTPHeaderField: "If-None-Match")
            }

            do {
                let (data, http, signatureVerified) = try await performRawRequest(mutableRequest, path: path)
                let requestId = extractRequestId(from: data)

                switch http.statusCode {
                case 200..<300:
                    return try onSuccess(data, http, signatureVerified, requestId)

                case 304:
                    // Let onSuccess handle 304 too (for ETag-based endpoints)
                    return try onSuccess(data, http, signatureVerified, requestId)

                case 429:
                    let errorInfo = parseErrorEnvelope(from: data)
                    retryAfterOverride = parseRetryAfterHeader(http.value(forHTTPHeaderField: "Retry-After"))
                        ?? errorInfo?.retryAfterSeconds
                    lastError = AppActorError.serverError(
                        httpStatus: 429,
                        code: errorInfo?.code ?? "RATE_LIMIT_EXCEEDED",
                        message: errorInfo?.message ?? "Rate limited",
                        details: errorInfo?.details,
                        requestId: requestId,
                        scope: errorInfo?.scope,
                        retryAfterSeconds: retryAfterOverride
                    )
                    Log.network.warn("Rate limited on \(path), retrying…")
                    continue

                case 400..<500:
                    // Check custom handler first (e.g. 404 for customer)
                    if let handler = additionalNonRetryHandler,
                       let result = try handler(http.statusCode, data, requestId) {
                        return result
                    }
                    let errorInfo = parseErrorEnvelope(from: data)
                    Log.network.error("\(http.statusCode) \(path): code=\(errorInfo?.code ?? "nil") message=\(errorInfo?.message ?? "nil")")
                    #if DEBUG
                    if let rawBody = String(data: data.prefix(200), encoding: .utf8) {
                        Log.network.debug("Response snippet: \(rawBody)")
                    }
                    #endif
                    throw AppActorError.serverError(
                        httpStatus: http.statusCode,
                        code: errorInfo?.code,
                        message: errorInfo?.message,
                        details: errorInfo?.details,
                        requestId: requestId
                    )

                default:
                    // 5xx — retry
                    let errorInfo = parseErrorEnvelope(from: data)
                    lastError = AppActorError.serverError(
                        httpStatus: http.statusCode,
                        code: errorInfo?.code ?? "INTERNAL_ERROR",
                        message: errorInfo?.message,
                        details: errorInfo?.details,
                        requestId: requestId
                    )
                    Log.network.warn("\(http.statusCode) \(path), retrying…")
                    continue
                }

            } catch let error as AppActorError {
                throw error
            } catch let error as URLError
                where error.code == .timedOut
                   || error.code == .notConnectedToInternet
                   || error.code == .networkConnectionLost {
                lastError = AppActorError.networkError(error)
                Log.network.warn("Network error on \(path): \(error.localizedDescription), retrying…")
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                Log.network.error("Network error on \(path): \(error.localizedDescription)")
                throw AppActorError.networkError(error)
            }
        }

        Log.network.error("All retries exhausted for \(path)")
        throw lastError
    }

    // MARK: - Helpers

    private func extractRequestId(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["requestId"] as? String
    }

    private func parseErrorEnvelope(from data: Data) -> AppActorErrorResponse.ErrorPayload? {
        guard let parsed = try? JSONDecoder().decode(AppActorErrorResponse.self, from: data) else {
            return nil
        }
        return parsed.error
    }

    // MARK: - Rate Limit Helpers

    /// Parses the `Retry-After` HTTP header value into seconds.
    /// Supports integer seconds (e.g. "47") and HTTP-date format (RFC 7231).
    /// Returns nil if the header is missing, unparseable, or non-positive.
    ///
    /// Values above 3600s (1 hour) are intentionally rejected as a safety cap —
    /// a malicious or misconfigured server could otherwise stall the client indefinitely.
    /// Combined with the 120s per-retry cap in the backoff loop, the effective maximum
    /// sleep is 120s regardless of the header value.
    private func parseRetryAfterHeader(_ value: String?) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        // Try integer seconds first (most common for APIs)
        if let seconds = Double(raw), seconds > 0, seconds <= 3600 {
            return seconds
        }

        // Try HTTP-date format (e.g. "Wed, 21 Oct 2015 07:28:00 GMT")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let delta = date.timeIntervalSinceNow
            if delta > 0, delta <= 3600 { return delta }
        }

        return nil
    }

    /// Logs rate-limit headers from the HTTP response for debugging.
    private func logRateLimitHeaders(from http: HTTPURLResponse, path: String) {
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
        let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit")

        if remaining != nil || reset != nil || limit != nil {
            Log.network.debug(
                "Rate-limit headers for \(path): " +
                "limit=\(limit ?? "–") remaining=\(remaining ?? "–") reset=\(reset ?? "–")"
            )
        }
    }
}
