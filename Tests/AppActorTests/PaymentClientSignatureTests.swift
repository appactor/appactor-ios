import CryptoKit
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
        // The 304 was retried; it is the unsigned retry that was rejected.
        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 2)
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
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-AppActor-Signature-Binding"))
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

    func testCustomerPathEncodesTheAppUserIdOnce() async throws {
        PaymentClientURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }

        _ = try? await makeClient().getCustomer(appUserId: "auth0|64f1 ç%", eTag: nil)

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            "/v1/customers/auth0%7C64f1%20%C3%A7%25"
        )
    }

    func testExperimentPathEncodesTheKeyOnce() async throws {
        PaymentClientURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }

        _ = try? await makeClient().postExperimentAssignment(experimentKey: "a|b/c", appUserId: "user_1", appVersion: nil, country: nil)

        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertEqual(requests.count, 1)
        let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.percentEncodedPath, "/v1/experiments/a%7Cb%2Fc/assignments")
        XCTAssertEqual(components?.percentEncodedQuery, "app_user_id=user_1")
    }

    func testRestoreReportsOnlyRecordedTransactions() async throws {
        let body = Data("""
        {"data":{"customer":{"entitlements":{},"subscriptions":{},"nonSubscriptions":{}},"restoredCount":1,"transferred":false,"hasFailures":true,"items":[
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
        let requests = PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests }
        XCTAssertNotNil(requests.first?.value(forHTTPHeaderField: "X-AppActor-Nonce"))
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-AppActor-Signature-Binding"), "request")
    }

    func testRestoreBuildsTheCustomerFromTheFullCustomerView() async throws {
        // Both views as the server sends them: `user` has no isActive on subscriptions and no
        // unsubscribeDetectedAt, periodType or isSandbox on entitlements.
        let body = Data("""
        {"data":{
          "user":{"entitlements":{"pro":{"isActive":true,"productId":"pro_monthly"}},"subscriptions":{"pro_monthly":{"productId":"pro_monthly","expiresAt":"2099-01-01T00:00:00.000Z"}},"nonSubscriptions":{}},
          "customer":{"entitlements":{"pro":{"isActive":true,"productId":"pro_monthly","periodType":"trial","isSandbox":true,"unsubscribeDetectedAt":"2026-09-20T00:00:00.000Z"}},"subscriptions":{"pro_monthly":{"productId":"pro_monthly","isActive":true,"expiresAt":"2099-01-01T00:00:00.000Z","periodType":"trial","isSandbox":true,"unsubscribeDetectedAt":"2026-09-20T00:00:00.000Z"}},"nonSubscriptions":{},"firstSeen":"2026-01-01T00:00:00.000Z","lastSeen":"2026-09-26T00:00:00.000Z"},
          "restoredCount":1,"transferred":false,"hasFailures":false,
          "items":[{"transactionId":"1001","status":"restored","replayedCount":0,"didMutate":true,"userId":"u1"}]
        },"requestId":"req_restore_views"}
        """.utf8)
        PaymentClientURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, body)
        }

        let result = try await makeClient(requireSignatures: false).postRestore(
            AppActorRestoreRequest(
                appUserId: "user_restore",
                sourceIntent: "restore",
                transactions: [AppActorRestoreTransactionItem(transactionId: "1001", jwsRepresentation: "jws_1001")],
                signedAppTransactionInfo: nil
            )
        )

        let info = result.customerInfo
        XCTAssertEqual(info.subscriptions["pro_monthly"]?.isActive, true)
        XCTAssertEqual(info.subscriptions["pro_monthly"]?.periodType, .trial)
        XCTAssertEqual(info.subscriptions["pro_monthly"]?.isSandbox, true)
        XCTAssertEqual(info.entitlements["pro"]?.isActive, true)
        XCTAssertEqual(info.entitlements["pro"]?.willRenew, false, "auto-renew was turned off")
        XCTAssertEqual(info.entitlements["pro"]?.periodType, .trial)
        XCTAssertEqual(info.entitlements["pro"]?.isSandbox, true)
        XCTAssertEqual(info.firstSeen, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(info.lastSeen, "2026-09-26T00:00:00.000Z")
    }

    // MARK: - '+' in query values (I-S2-4)

    /// What the server reads for `name`: Hono splits on '&' and '=', turns '+' into a space,
    /// then percent-decodes.
    private func serverDecodedQueryValue(_ name: String, in request: URLRequest) -> String? {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.first == name else { continue }
            return (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }

    private static let queryEdgeCaseAppUserIds = ["ana+ios@x.com", "+905551234567", "a&b=c", "100%", "two words", "a+b&c=d%e f"]

    private func sentQuery(_ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }

    func testRemoteConfigQuerySendsPlusSoTheServerReadsTheSameAppUserId() async throws {
        for appUserId in Self.queryEdgeCaseAppUserIds + ["ana+ios@x.com"] {
            PaymentClientURLProtocol.reset()
            PaymentClientURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (response, Data(#"{"data":[],"requestId":"req_rc"}"#.utf8))
            }
            _ = try await makeClient(requireSignatures: false).getRemoteConfigs(
                appUserId: appUserId, appVersion: "1.0+42", country: "TR", eTag: nil
            )
            let request = try XCTUnwrap(PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests.first })
            let query = try XCTUnwrap(sentQuery(request))
            XCTAssertFalse(query.contains("+"), "\(appUserId): a raw '+' reads as a space on the server")
            XCTAssertEqual(serverDecodedQueryValue("app_user_id", in: request), appUserId)
            XCTAssertEqual(serverDecodedQueryValue("app_version", in: request), "1.0+42")
        }
        // The last round sent "ana+ios@x.com".
        let request = try XCTUnwrap(PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests.first })
        XCTAssertEqual(sentQuery(request), "app_user_id=ana%2Bios@x.com&app_version=1.0%2B42&country=TR")
    }

    func testExperimentQuerySendsPlusSoTheServerReadsTheSameAppUserId() async throws {
        for appUserId in Self.queryEdgeCaseAppUserIds {
            PaymentClientURLProtocol.reset()
            PaymentClientURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
            }
            _ = try? await makeClient().postExperimentAssignment(
                experimentKey: "paywall", appUserId: appUserId, appVersion: nil, country: nil
            )
            let request = try XCTUnwrap(PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests.first })
            XCTAssertFalse(sentQuery(request)?.contains("+") ?? true, appUserId)
            XCTAssertEqual(serverDecodedQueryValue("app_user_id", in: request), appUserId)
        }
    }

    /// The nonce binding (#599) signs the request target as it arrived. The SDK checks against
    /// the target it reads back from the URL it sent, so the two must be the same bytes.
    func testSignatureBindingCoversTheEncodedPlusAsSent() async throws {
        PaymentClientURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }
        _ = try? await makeClient().postExperimentAssignment(
            experimentKey: "paywall", appUserId: "ana+ios@x.com", appVersion: nil, country: nil
        )
        let request = try XCTUnwrap(PaymentClientURLProtocol.lock.withLock { PaymentClientURLProtocol.requests.first })
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AppActor-Signature-Binding"), "request")
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "X-AppActor-Nonce"))

        // What the server reads back from the request line: path + '?' + raw query.
        let absolute = try XCTUnwrap(request.url?.absoluteString)
        let pathStart = try XCTUnwrap(absolute.range(of: "/v1/")).lowerBound
        let serverTarget = String(absolute[pathStart...])
        XCTAssertEqual(serverTarget, "/v1/experiments/paywall/assignments?app_user_id=ana%2Bios@x.com")
        let sdkTarget = AppActorPaymentClient.signatureRequestTarget(for: request, fallbackPath: "/")
        XCTAssertEqual(sdkTarget, serverTarget)

        let key = Curve25519.Signing.PrivateKey()
        let body = Data(#"{"data":{"inExperiment":false}}"#.utf8)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        func response(signedFor target: String) throws -> HTTPURLResponse {
            let binding = ResponseSignatureVerifier.requestBinding(method: "POST", target: target, body: nil)
            let payload = "\(nonce)\n\(timestamp)\n\(binding)\n\(String(decoding: body, as: UTF8.self))"
            let signature = try key.signature(for: Data(payload.utf8)).base64EncodedString()
            return HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "X-AppActor-Request-Nonce": nonce,
                    "X-AppActor-Signature": signature,
                    "X-AppActor-Signature-Timestamp": timestamp,
                ]
            )!
        }
        func verify(_ response: HTTPURLResponse) -> ResponseSignatureVerifier.VerificationResult {
            ResponseSignatureVerifier.verify(
                response: response, body: body, sentNonce: nonce, apiKey: "", requestPath: sdkTarget,
                method: "POST", requestBody: nil,
                v1Key: key.publicKey, rootKey: Curve25519.Signing.PrivateKey().publicKey,
                now: Date().timeIntervalSince1970
            )
        }
        XCTAssertEqual(verify(try response(signedFor: serverTarget)), .success)
        XCTAssertEqual(
            verify(try response(signedFor: "/v1/experiments/paywall/assignments?app_user_id=ana+ios@x.com")),
            .signatureInvalid,
            "the target with a raw '+' is another request"
        )
    }

    func testSignatureTargetEncodesApostrophesInTheQueryLikeTheServer() {
        // The server's WHATWG URL parser turns ' into %27 in an https query, and only there.
        let request = URLRequest(url: URL(string: "https://api.appactor.test/v1/experiments/k/assignments?app_user_id=o'brien@x.com")!)
        XCTAssertEqual(
            AppActorPaymentClient.signatureRequestTarget(for: request, fallbackPath: "/"),
            "/v1/experiments/k/assignments?app_user_id=o%27brien@x.com"
        )
        let pathRequest = URLRequest(url: URL(string: "https://api.appactor.test/v1/customers/o'brien")!)
        XCTAssertEqual(AppActorPaymentClient.signatureRequestTarget(for: pathRequest, fallbackPath: "/"), "/v1/customers/o'brien")
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
