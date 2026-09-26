import Foundation
import XCTest
@testable import AppActor

private final class PaymentClientURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        do {
            guard let handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requests = []
        handler = nil
        lock.unlock()
    }
}

final class PaymentClientSignatureTests: XCTestCase {

    override func tearDown() {
        PaymentClientURLProtocol.reset()
        super.tearDown()
    }

    func testUnsigned304RetriesOfferingsWithoutETag() async throws {
        let body = Data("""
        {"data":{"currentOffering":null,"offerings":[],"productEntitlements":{}},"requestId":"req_fresh"}
        """.utf8)
        var responses: [(Int, [String: String], Data)] = [
            (304, ["ETag": "W/\"old\""], Data()),
            (200, ["Content-Type": "application/json", "ETag": "W/\"fresh\""], body)
        ]
        PaymentClientURLProtocol.handler = { request in
            let next = responses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: next.0,
                httpVersion: "HTTP/1.1",
                headerFields: next.1
            )!
            return (response, next.2)
        }

        // Signatures off: this test covers the retry mechanics, not the signature check.
        let result = try await makeClient(requireSignatures: false).getOfferings(eTag: "W/\"old\"")

        guard case .fresh(_, let eTag, let requestId, let signatureVerified) = result else {
            XCTFail("Expected unsigned 304 to retry into a fresh response")
            return
        }
        XCTAssertEqual(eTag, "W/\"fresh\"")
        XCTAssertEqual(requestId, "req_fresh")
        XCTAssertFalse(signatureVerified)

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "If-None-Match"), "W/\"old\"")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testUnsignedSaltRoute200IsRejectedWhenSignaturesAreRequired() async throws {
        PaymentClientURLProtocol.handler = { request in
            let body = request.url?.path == "/v1/remote-config"
                ? #"{"data":[],"requestId":"req_unsigned"}"#
                : #"{"data":{"currentOffering":null,"offerings":[],"productEntitlements":{}},"requestId":"req_unsigned"}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.getOfferings(eTag: nil)
            XCTFail("An unsigned offerings 200 must be rejected")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .signatureMissing)
        }
        do {
            _ = try await client.getRemoteConfigs(appUserId: "user_123", appVersion: nil, country: nil, eTag: nil)
            XCTFail("An unsigned remote-config 200 must be rejected")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .signatureMissing)
        }
    }

    func testUnsigned304RetryStillRequiresASignedResponse() async throws {
        var responses: [(Int, [String: String], Data)] = [
            (304, ["ETag": "W/\"old\""], Data()),
            (200, ["Content-Type": "application/json"], Data(#"{"data":{"currentOffering":null,"offerings":[],"productEntitlements":{}}}"#.utf8))
        ]
        PaymentClientURLProtocol.handler = { request in
            let next = responses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: next.1)!
            return (response, next.2)
        }

        do {
            _ = try await makeClient().getOfferings(eTag: "W/\"old\"")
            XCTFail("The fresh retry after an unsigned 304 must be signed too")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .signatureMissing)
        }
    }

    func testInvalid304SignatureDoesNotRetry() async throws {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        PaymentClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "ETag": "W/\"old\"",
                    "X-AppActor-Signature-Salt": "invalid-salt",
                    "X-AppActor-Signature": "not-base64",
                    "X-AppActor-Signature-Timestamp": timestamp
                ]
            )!
            return (response, Data())
        }

        do {
            _ = try await makeClient().getOfferings(eTag: "W/\"old\"")
            XCTFail("Expected invalid 304 signature to fail")
        } catch let error as AppActorError {
            XCTAssertEqual(error.kind, .signatureVerificationFailed)
        }

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 1)
    }

    func testRemoteConfigRequestsOptIntoPathQuerySignatureTarget() async throws {
        let body = Data("""
        {"data":[],"requestId":"req_remote_config"}
        """.utf8)
        PaymentClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-AppActor-Remote-Config-Requires-User-Context": "false",
                ]
            )!
            return (response, body)
        }

        let result = try await makeClient(requireSignatures: false).getRemoteConfigs(
            appUserId: "user_123",
            appVersion: "1.2.3",
            country: "TR",
            eTag: nil
        )

        guard case .fresh(let items, _, let requestId, _, let requiresUserContext) = result else {
            XCTFail("Expected fresh remote config response")
            return
        }
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(requestId, "req_remote_config")
        XCTAssertEqual(requiresUserContext, false)

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-AppActor-Signature-Target"), "path-query")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-AppActor-Nonce"))
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/v1/remote-config")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "app_user_id" })?.value, "user_123")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "app_version" })?.value, "1.2.3")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "country" })?.value, "TR")
    }

    func testAttributeMutationPathsPreserveEncodedSegments() async throws {
        PaymentClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (response, Data())
        }

        _ = try await makeClient(requireSignatures: false).deleteAttribute(
            appUserId: "user/with/slash",
            key: "$email"
        )

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 1)
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.percentEncodedPath,
            "/v1/payment/users/user%2Fwith%2Fslash/attributes/$email"
        )
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
    }

    func testRestoreReportsOnlyRecordedTransactions() async throws {
        let body = Data("""
        {"data":{"user":{"entitlements":{},"subscriptions":{},"nonSubscriptions":{}},"restoredCount":1,"transferred":false,"hasFailures":true,"items":[
          {"transactionId":"1001","status":"restored","replayedCount":0,"didMutate":true,"userId":"u1"},
          {"transactionId":"1002","status":"noop","replayedCount":0,"didMutate":false,"userId":"u1"},
          {"transactionId":"1003","status":"conflict","replayedCount":0,"didMutate":false,"userId":"u1","errorCode":"OWNERSHIP_CONFLICT"},
          {"transactionId":"1004","status":"skipped_invalid","replayedCount":0,"didMutate":false,"userId":null,"errorCode":"VALIDATION_FAILED"}
        ]},"requestId":"req_restore"}
        """.utf8)
        PaymentClientURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }

        let result = try await makeClient(requireSignatures: false).postRestore(
            AppActorRestoreRequest(
                appUserId: "user_restore",
                sourceIntent: "restore",
                transactions: ["1001", "1002", "1003", "1004"].map {
                    AppActorRestoreTransactionItem(transactionId: $0, jwsRepresentation: "jws_\($0)")
                },
                signedAppTransactionInfo: nil
            )
        )

        XCTAssertEqual(result.recordedTransactionIds, ["1001", "1002"])
        XCTAssertEqual(result.restoredCount, 1)
    }

    private func makeClient(requireSignatures: Bool = true) -> AppActorPaymentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaymentClientURLProtocol.self]
        return AppActorPaymentClient(
            baseURL: URL(string: "https://api.appactor.test")!,
            apiKey: "pk_test_signature",
            session: URLSession(configuration: config),
            maxRetries: 2,
            requireSignatures: requireSignatures
        )
    }
}
