import Foundation
@testable import AppActor

/// Universal handler-based mock for `AppActorPaymentClientProtocol`.
///
/// Consolidates 7 nearly-identical mock client implementations across test files.
/// Each handler is optional — unset handlers return safe defaults.
/// Call tracking uses thread-safe accessors for concurrent tests.
final class MockPaymentClient: AppActorPaymentClientProtocol, @unchecked Sendable {

    // MARK: - Handlers

    var identifyHandler: ((AppActorIdentifyRequest) async throws -> AppActorIdentifyResult)?
    var loginHandler: ((AppActorLoginRequest) async throws -> AppActorLoginResult)?
    var logoutHandler: ((AppActorLogoutRequest) async throws -> AppActorPaymentResult<Bool>)?
    var getOfferingsHandler: ((String?) async throws -> AppActorOfferingsFetchResult)?
    var getCustomerHandler: ((String, String?) async throws -> AppActorCustomerFetchResult)?
    var postReceiptHandler: ((AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse)?
    var postRestoreHandler: ((AppActorRestoreRequest) async throws -> AppActorRestoreResult)?
    var getRemoteConfigsHandler: ((String?, String?, String?, String?) async throws -> AppActorRemoteConfigFetchResult)?
    var postExperimentAssignmentHandler: ((String, String, String?, String?) async throws -> AppActorExperimentFetchResult)?

    // ASA handlers
    var attributionHandler: ((AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO)?
    var purchaseEventHandler: ((AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO)?

    // MARK: - Call Tracking (thread-safe)

    private let queue = DispatchQueue(label: "mock.client.lock")

    private var _identifyCalls: [AppActorIdentifyRequest] = []
    var identifyCalls: [AppActorIdentifyRequest] { queue.sync { _identifyCalls } }

    private var _loginCalls: [AppActorLoginRequest] = []
    var loginCalls: [AppActorLoginRequest] { queue.sync { _loginCalls } }

    private var _logoutCalls: [AppActorLogoutRequest] = []
    var logoutCalls: [AppActorLogoutRequest] { queue.sync { _logoutCalls } }

    private var _getOfferingsCalls: [String?] = []
    var getOfferingsCalls: [String?] { queue.sync { _getOfferingsCalls } }
    var getOfferingsCallCount: Int { queue.sync { _getOfferingsCalls.count } }

    private var _getCustomerCalls: [(appUserId: String, eTag: String?)] = []
    var getCustomerCalls: [(appUserId: String, eTag: String?)] { queue.sync { _getCustomerCalls } }

    private var _postReceiptCalls: [AppActorReceiptPostRequest] = []
    var postReceiptCalls: [AppActorReceiptPostRequest] { queue.sync { _postReceiptCalls } }

    private var _postRestoreCalls: [AppActorRestoreRequest] = []
    var postRestoreCalls: [AppActorRestoreRequest] { queue.sync { _postRestoreCalls } }

    private var _getRemoteConfigsCalls: [(appUserId: String?, appVersion: String?, country: String?, eTag: String?)] = []
    var getRemoteConfigsCalls: [(appUserId: String?, appVersion: String?, country: String?, eTag: String?)] {
        queue.sync { _getRemoteConfigsCalls }
    }

    private var _attributionCalls: [AppActorASAAttributionRequest] = []
    var attributionCalls: [AppActorASAAttributionRequest] { queue.sync { _attributionCalls } }

    private var _purchaseEventCalls: [AppActorASAPurchaseEventRequest] = []
    var purchaseEventCalls: [AppActorASAPurchaseEventRequest] { queue.sync { _purchaseEventCalls } }


    // MARK: - Protocol Implementation

    func identify(_ request: AppActorIdentifyRequest) async throws -> AppActorIdentifyResult {
        queue.sync { _identifyCalls.append(request) }
        if let handler = identifyHandler {
            return try await handler(request)
        }
        return AppActorIdentifyResult(
            appUserId: request.appUserId,
            customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
            customerETag: "mock_hash",
            requestId: "req_mock_identify",
            signatureVerified: false
        )
    }

    func login(_ request: AppActorLoginRequest) async throws -> AppActorLoginResult {
        queue.sync { _loginCalls.append(request) }
        if let handler = loginHandler {
            return try await handler(request)
        }
        return AppActorLoginResult(
            appUserId: request.newAppUserId,
            customerInfo: AppActorCustomerInfo(appUserId: request.newAppUserId),
            customerETag: "mock_hash",
            requestId: "req_mock_login",
            signatureVerified: false
        )
    }

    func logout(_ request: AppActorLogoutRequest) async throws -> AppActorPaymentResult<Bool> {
        queue.sync { _logoutCalls.append(request) }
        if let handler = logoutHandler {
            return try await handler(request)
        }
        return AppActorPaymentResult(value: true, requestId: "req_mock_logout")
    }

    func getOfferings(eTag: String?) async throws -> AppActorOfferingsFetchResult {
        queue.sync { _getOfferingsCalls.append(eTag) }
        if let handler = getOfferingsHandler {
            return try await handler(eTag)
        }
        return .fresh(
            AppActorOfferingsResponseDTO(currentOffering: nil, offerings: []),
            eTag: nil,
            requestId: "req_mock_offerings",
            signatureVerified: false
        )
    }

    func getCustomer(appUserId: String, eTag: String?) async throws -> AppActorCustomerFetchResult {
        queue.sync { _getCustomerCalls.append((appUserId: appUserId, eTag: eTag)) }
        if let handler = getCustomerHandler {
            return try await handler(appUserId, eTag)
        }
        let info = AppActorCustomerInfo(appUserId: appUserId)
        return .fresh(info, eTag: nil, requestId: "req_mock_customer", signatureVerified: false)
    }

    func postReceipt(_ request: AppActorReceiptPostRequest) async throws -> AppActorReceiptPostResponse {
        queue.sync { _postReceiptCalls.append(request) }
        if let handler = postReceiptHandler {
            return try await handler(request)
        }
        return AppActorReceiptPostResponse(status: "ok", requestId: "req_mock_receipt")
    }

    func postRestore(_ request: AppActorRestoreRequest) async throws -> AppActorRestoreResult {
        queue.sync { _postRestoreCalls.append(request) }
        if let handler = postRestoreHandler {
            return try await handler(request)
        }
        return AppActorRestoreResult(
            customerInfo: AppActorCustomerInfo(appUserId: request.appUserId),
            restoredCount: request.transactions.count,
            transferred: false,
            requestId: "req_mock_restore",
            customerETag: "mock_etag",
            signatureVerified: false
        )
    }

    func getRemoteConfigs(appUserId: String?, appVersion: String?, country: String?, eTag: String?) async throws -> AppActorRemoteConfigFetchResult {
        queue.sync { _getRemoteConfigsCalls.append((appUserId, appVersion, country, eTag)) }
        if let handler = getRemoteConfigsHandler {
            return try await handler(appUserId, appVersion, country, eTag)
        }
        return .fresh([], eTag: nil, requestId: "req_mock_rc", signatureVerified: false)
    }

    private var _postExperimentAssignmentCalls: [(experimentKey: String, appUserId: String, appVersion: String?, country: String?)] = []
    var postExperimentAssignmentCalls: [(experimentKey: String, appUserId: String, appVersion: String?, country: String?)] {
        queue.sync { _postExperimentAssignmentCalls }
    }

    func postExperimentAssignment(experimentKey: String, appUserId: String, appVersion: String?, country: String?) async throws -> AppActorExperimentFetchResult {
        queue.sync { _postExperimentAssignmentCalls.append((experimentKey, appUserId, appVersion, country)) }
        if let handler = postExperimentAssignmentHandler {
            return try await handler(experimentKey, appUserId, appVersion, country)
        }
        return .success(
            AppActorExperimentAssignmentDTO(
                inExperiment: false,
                reason: "mock",
                experiment: nil,
                variant: nil,
                assignedAt: nil
            ),
            requestId: "req_mock_experiment",
            signatureVerified: false
        )
    }

    func postASAAttribution(_ request: AppActorASAAttributionRequest) async throws -> AppActorASAAttributionResponseDTO {
        queue.sync { _attributionCalls.append(request) }
        if let handler = attributionHandler {
            return try await handler(request)
        }
        return AppActorASAAttributionResponseDTO(
            status: "ok",
            attribution: AppActorASAAttributionResultDTO(
                attributionStatus: "attributed", appleOrgId: 1, campaignId: 100,
                campaignName: "Test", adGroupId: nil, adGroupName: nil,
                keywordId: nil, keywordName: nil, creativeSetId: nil,
                conversionType: "download", claimType: nil, region: "US",
                supplyPlacement: nil
            )
        )
    }

    func postASAPurchaseEvent(_ request: AppActorASAPurchaseEventRequest) async throws -> AppActorASAPurchaseEventResponseDTO {
        queue.sync { _purchaseEventCalls.append(request) }
        if let handler = purchaseEventHandler {
            return try await handler(request)
        }
        return AppActorASAPurchaseEventResponseDTO(status: "ok", eventId: "evt_\(UUID().uuidString.prefix(8))")
    }
}
