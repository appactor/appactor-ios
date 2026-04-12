import XCTest
import CryptoKit
@testable import AppActor

final class ResponseSignatureVerifierTests: XCTestCase {

    // MARK: - Test Key Pairs

    /// Generate a fresh Ed25519 key pair for each test run.
    private var v1Key: Curve25519.Signing.PrivateKey!
    private var rootKey: Curve25519.Signing.PrivateKey!
    private let nonce = "test-nonce-12345"
    private var now: TimeInterval!

    override func setUp() {
        super.setUp()
        v1Key = Curve25519.Signing.PrivateKey()
        rootKey = Curve25519.Signing.PrivateKey()
        now = Date().timeIntervalSince1970
    }

    // MARK: - Helpers

    /// Creates a mock HTTPURLResponse with the given headers.
    private func makeResponse(headers: [String: String], statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.appactor.com/v1/test")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    /// Signs a v1 payload with the test key and returns the base64 signature.
    private func signV1(body: Data, nonce: String, timestamp: String) -> String {
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        let payload = "\(nonce)\n\(timestamp)\n\(bodyString)"
        let payloadData = payload.data(using: .utf8)!
        let signature = try! v1Key.signature(for: payloadData)
        return Data(signature).base64EncodedString()
    }

    /// Builds a v2 blob: certHeader(52) + rootCertSig(64) + payloadSig(64) = 180 bytes.
    private func buildV2Blob(
        payloadString: String,
        issuedAt: UInt64,
        expiresAt: UInt64,
        intermediateKey: Curve25519.Signing.PrivateKey? = nil,
        rootSigningKey: Curve25519.Signing.PrivateKey? = nil
    ) -> Data {
        let intermediate = intermediateKey ?? Curve25519.Signing.PrivateKey()
        let rootSigner = rootSigningKey ?? rootKey!

        var certHeader = Data(count: 52)
        certHeader[0] = 0x02
        certHeader[1] = 0x00
        writeUInt64BE(&certHeader, offset: 4, value: issuedAt)
        writeUInt64BE(&certHeader, offset: 12, value: expiresAt)
        certHeader.replaceSubrange(20..<52, with: intermediate.publicKey.rawRepresentation)

        var certPayload = Data("appactor-cert-v1".utf8)
        certPayload.append(certHeader)
        let rootCertSig = try! rootSigner.signature(for: certPayload)

        let payloadData = payloadString.data(using: .utf8)!
        let payloadSig = try! intermediate.signature(for: payloadData)

        var blob = Data()
        blob.append(certHeader)
        blob.append(Data(rootCertSig))
        blob.append(Data(payloadSig))
        assert(blob.count == 180)
        return blob
    }

    /// Convenience: builds a nonce-based v2 blob.
    private func buildV2Blob(
        body: Data, nonce: String, timestamp: String,
        issuedAt: UInt64, expiresAt: UInt64,
        intermediateKey: Curve25519.Signing.PrivateKey? = nil,
        rootSigningKey: Curve25519.Signing.PrivateKey? = nil
    ) -> Data {
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        return buildV2Blob(
            payloadString: "\(nonce)\n\(timestamp)\n\(bodyString)",
            issuedAt: issuedAt, expiresAt: expiresAt,
            intermediateKey: intermediateKey, rootSigningKey: rootSigningKey
        )
    }

    private func writeUInt64BE(_ data: inout Data, offset: Int, value: UInt64) {
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (56 - i * 8)) & 0xFF)
        }
    }

    // MARK: - v1 Tests

    func testV1ValidSignature() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))
        let sig = signV1(body: body, nonce: nonce, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .success)
    }

    func testV1TamperedBody() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))
        let sig = signV1(body: body, nonce: nonce, timestamp: timestampStr)

        let tamperedBody = Data("{\"ok\":false}".utf8)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: tamperedBody, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    // MARK: - v2 Tests

    func testV2ValidChain() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        let blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .success)
    }

    func testV2ExpiredIntermediate() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        // Expired: expiresAt in the past
        let issuedAt = UInt64(now) - 7200
        let expiresAt = UInt64(now) - 3600

        let blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .intermediateKeyExpired)
    }

    func testV2WrongRootSignature() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        // Sign with a DIFFERENT root key than we pass to verify
        let wrongRootKey = Curve25519.Signing.PrivateKey()
        let blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt,
            rootSigningKey: wrongRootKey
        )

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .intermediateCertInvalid)
    }

    // MARK: - Header Tests

    func testNoNonceEcho() {
        let body = Data("{\"ok\":true}".utf8)

        let response = makeResponse(headers: [:])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signingNotSupported)
    }

    func testNonceEchoedButNoSignature() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureMissing)
    }

    func testNonceMismatch() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))
        let sig = signV1(body: body, nonce: nonce, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": "wrong-nonce",
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .nonceMismatch)
    }

    func testTimestampDriftBeyondThreshold() {
        let body = Data("{\"ok\":true}".utf8)
        // Timestamp 600 seconds in the past (beyond 300s drift tolerance)
        let oldTimestamp = now - 600
        let timestampStr = String(Int(oldTimestamp))
        let sig = signV1(body: body, nonce: nonce, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .timestampOutOfRange)
    }

    // MARK: - v2 Edge Cases

    func testV2WrongVersionByte() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        // Build a valid blob then corrupt the version byte
        var blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )
        blob[0] = 0x01  // wrong version (should be 0x02)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testV2NonZeroFlags() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        var blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )
        blob[1] = 0x01  // non-zero flags — should be rejected

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testV2FutureIssuedAt() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        // issuedAt in the future — should be rejected as intermediateCertInvalid
        let issuedAt = UInt64(now) + 3600
        let expiresAt = UInt64(now) + 7200

        let blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .intermediateCertInvalid)
    }

    func testV2TamperedBodyWithValidCert() {
        let body = Data("{\"data\":\"hello\"}".utf8)
        let timestampStr = String(Int(now))
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        let blob = buildV2Blob(
            body: body, nonce: nonce, timestamp: timestampStr,
            issuedAt: issuedAt, expiresAt: expiresAt
        )

        // Pass different body to verify — cert chain is valid, payload sig won't match
        let tamperedBody = Data("{\"data\":\"tampered\"}".utf8)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: tamperedBody, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testInvalidBase64Signature() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": "not-valid-base64!!!",
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testUnexpectedBlobSize() {
        let body = Data("{\"ok\":true}".utf8)
        let timestampStr = String(Int(now))
        // 100 bytes — neither v1 (64) nor v2 (180)
        let weirdBlob = Data(repeating: 0xAA, count: 100)

        let response = makeResponse(headers: [
            "X-AppActor-Request-Nonce": nonce,
            "X-AppActor-Signature": weirdBlob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nonce,
            apiKey: "", requestPath: "",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    // MARK: - Salt-Based Verification

    private let testApiKey = "pk_test_abc123"
    private let testPath = "/v1/payment/offerings"

    private func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private func saltPayloadString(body: Data, salt: String, apiKey: String, path: String, timestamp: String, eTag: String = "") -> String {
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        return "\(salt)\n\(apiKey)\n\(path)\n\(timestamp)\n\(eTag)\n\(bodyString)"
    }

    /// Signs a salt-based payload with the v1 test key.
    private func signSaltV1(body: Data, salt: String, apiKey: String, path: String, timestamp: String, eTag: String = "") -> String {
        let payload = saltPayloadString(body: body, salt: salt, apiKey: apiKey, path: path, timestamp: timestamp, eTag: eTag)
        let payloadData = payload.data(using: .utf8)!
        let signature = try! v1Key.signature(for: payloadData)
        return Data(signature).base64EncodedString()
    }

    /// Builds a v2 blob signed with a salt-based payload.
    private func buildSaltV2Blob(
        body: Data, salt: String, apiKey: String, path: String,
        timestamp: String, eTag: String = "",
        issuedAt: UInt64, expiresAt: UInt64
    ) -> Data {
        let payload = saltPayloadString(body: body, salt: salt, apiKey: apiKey, path: path, timestamp: timestamp, eTag: eTag)
        return buildV2Blob(payloadString: payload, issuedAt: issuedAt, expiresAt: expiresAt)
    }

    func testSaltBasedV1ValidSignature() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .success)
    }

    func testSaltBasedV2ValidChain() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let issuedAt = UInt64(now) - 3600
        let expiresAt = UInt64(now) + 3600

        let blob = buildSaltV2Blob(
            body: body, salt: salt, apiKey: testApiKey, path: testPath,
            timestamp: timestampStr, issuedAt: issuedAt, expiresAt: expiresAt
        )

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": blob.base64EncodedString(),
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .success)
    }

    func testSaltBasedMissingSaltHeader() {
        let body = Data("{\"offerings\":[]}".utf8)

        let response = makeResponse(headers: [:])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signingNotSupported)
    }

    func testSaltBasedMissingSignatureHeader() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": randomSalt(),
            "X-AppActor-Signature-Timestamp": timestampStr
            // No X-AppActor-Signature header
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureMissing)
    }

    func testSaltBasedWrongApiKey() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: "pk_wrong_key", requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testSaltBasedWrongPath() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: "/v1/wrong-path",
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testSaltBasedWrongETag() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr, eTag: "W/\"abc\"")

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr,
            "ETag": "W/\"different\""
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testSaltBasedTimestampDrift() {
        let body = Data("{\"offerings\":[]}".utf8)
        let oldTimestamp = now - 600
        let timestampStr = String(Int(oldTimestamp))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .timestampOutOfRange)
    }

    func testSaltBasedTamperedBody() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: Data("{\"tampered\":true}".utf8), sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .signatureInvalid)
    }

    func testSaltBasedWithETagInPayload() {
        let body = Data("{\"offerings\":[]}".utf8)
        let timestampStr = String(Int(now))
        let salt = randomSalt()
        let eTag = "W/\"abc123\""
        let sig = signSaltV1(body: body, salt: salt, apiKey: testApiKey, path: testPath, timestamp: timestampStr, eTag: eTag)

        let response = makeResponse(headers: [
            "X-AppActor-Signature-Salt": salt,
            "X-AppActor-Signature": sig,
            "X-AppActor-Signature-Timestamp": timestampStr,
            "ETag": eTag
        ])

        let result = ResponseSignatureVerifier.verify(
            response: response, body: body, sentNonce: nil,
            apiKey: testApiKey, requestPath: testPath,
            v1Key: v1Key.publicKey, rootKey: rootKey.publicKey, now: now
        )
        XCTAssertEqual(result, .success)
    }

    // MARK: - Nonce Generation

    func testGenerateNonceReturnsValidUUID() {
        let nonce = ResponseSignatureVerifier.generateNonce()
        XCTAssertNotNil(UUID(uuidString: nonce), "generateNonce() should return a valid UUID string")
    }

    func testGenerateNonceIsUnique() {
        let nonces = (0..<100).map { _ in ResponseSignatureVerifier.generateNonce() }
        let unique = Set(nonces)
        XCTAssertEqual(nonces.count, unique.count, "All generated nonces should be unique")
    }
}
