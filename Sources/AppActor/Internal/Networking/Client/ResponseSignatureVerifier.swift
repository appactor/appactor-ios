import Foundation
import CryptoKit

// MARK: - Response Signature Verification (Ed25519)

/// Verifies Ed25519 signatures on API responses to prevent tampering and replay attacks.
///
/// Supports two signature formats:
///   v1 (64 bytes): Direct Ed25519 signature. SDK pins the signing public key.
///   v2 (180 bytes): Intermediate key chain. SDK pins the ROOT public key.
///     Blob layout:
///       [0]       version (0x02)
///       [1]       flags (reserved)
///       [2..3]    keyId (uint16 BE)
///       [4..11]   issuedAt (uint64 BE, unix seconds)
///       [12..19]  expiresAt (uint64 BE, unix seconds)
///       [20..51]  intermediatePublicKey (32 bytes, Ed25519 raw)
///       [52..115] rootCertSignature (64 bytes)
///       [116..179] payloadSignature (64 bytes)
enum ResponseSignatureVerifier {

	// MARK: - Pinned Keys

	/// v1: Direct signing public key (base64, 32 bytes).
	static let v1PublicKeyBase64 = "ucf5p+d5KfS0hZDKe/GFsDMumPpJtwdDHQFB9ymfMlA="

	/// v2: Root public key for intermediate key chain (base64, 32 bytes).
	static let rootPublicKeyBase64 = "T7+gp+5ABLXlyTpnrWWVanJJcpuijExFBn5n/Ek/I1Q="

	/// Parsed v1 public key (cached).
	static let v1PublicKey: Curve25519.Signing.PublicKey? = {
		guard let data = Data(base64Encoded: v1PublicKeyBase64) else { return nil }
		return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
	}()

	/// Parsed root public key for v2 (cached).
	static let rootPublicKey: Curve25519.Signing.PublicKey? = {
		guard let data = Data(base64Encoded: rootPublicKeyBase64) else { return nil }
		return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
	}()

	/// Maximum allowed timestamp drift in seconds.
	static let maxTimestampDrift: TimeInterval = 300

	/// v2 cert prefix used in root certification.
	static let certPrefix = "appactor-cert-v1"

	/// v2 blob sizes.
	static let v2BlobSize = 180
	static let v1SignatureSize = 64
	static let certHeaderSize = 52

	// MARK: - Result

	enum VerificationResult {
		case success
		/// The response is marked as signed (nonce echo or salt header) but the signature or its
		/// timestamp is missing — possible MITM header strip.
		case signatureMissing
		/// The response carries no signature (no nonce echo, no salt header).
		/// `AppActorPaymentClient` rejects it when signatures are required.
		case unsigned
		case signatureInvalid
		case timestampOutOfRange
		case nonceMismatch
		case publicKeyUnavailable
		/// v2: Intermediate key's root certification is invalid.
		case intermediateCertInvalid
		/// v2: Intermediate key has expired.
		case intermediateKeyExpired
	}

	// MARK: - Verify (production — uses pinned keys and system clock)

	static func verify(
		response: HTTPURLResponse,
		body: Data,
		sentNonce: String?,
		apiKey: String,
		requestPath: String,
		method: String,
		requestBody: Data?
	) -> VerificationResult {
		verify(
			response: response,
			body: body,
			sentNonce: sentNonce,
			apiKey: apiKey,
			requestPath: requestPath,
			method: method,
			requestBody: requestBody,
			v1Key: v1PublicKey,
			rootKey: rootPublicKey,
			now: Date().timeIntervalSince1970
		)
	}

	// MARK: - Verify (test-injectable — accepts custom keys and time)

	/// Test-injectable overload. Production `verify()` delegates to this.
	///
	/// Mode selection:
	///   - sentNonce != nil → nonce-based verification, bound to the request (`requestBinding`)
	///   - sentNonce == nil → salt-based verification (CDN-cacheable)
	///
	/// `requestPath` is the signed request target (path + query) in both modes.
	static func verify(
		response: HTTPURLResponse,
		body: Data,
		sentNonce: String?,
		apiKey: String,
		requestPath: String,
		method: String = "GET",
		requestBody: Data? = nil,
		v1Key: Curve25519.Signing.PublicKey?,
		rootKey: Curve25519.Signing.PublicKey?,
		now: TimeInterval
	) -> VerificationResult {

		// ── Route 1: Nonce-based verification, bound to the request ──
		if let sentNonce {
			let echoedNonce = response.value(forHTTPHeaderField: "X-AppActor-Request-Nonce")

			guard let echoedNonce else {
				return .unsigned
			}

			guard let signatureBase64 = response.value(forHTTPHeaderField: "X-AppActor-Signature") else {
				return .signatureMissing
			}

			guard let timestampStr = response.value(forHTTPHeaderField: "X-AppActor-Signature-Timestamp"),
			      let timestamp = TimeInterval(timestampStr),
			      timestamp.isFinite else {
				return .signatureMissing
			}

			if echoedNonce != sentNonce {
				return .nonceMismatch
			}

			if abs(now - timestamp) > maxTimestampDrift {
				return .timestampOutOfRange
			}

			guard let signatureData = Data(base64Encoded: signatureBase64) else {
				return .signatureInvalid
			}

			// The status and the API key as well: the client sends `X-AppActor-Signature-Status`
			// and `X-AppActor-Signature-Api-Key`. Every project is signed with the same key, so
			// without the API key another project's signed answer would pass as this app's.
			let binding = requestBinding(method: method, target: requestPath, body: requestBody)
			guard let payloadData = signedPayload(
				header: "\(sentNonce)\n\(timestampStr)\n\(response.statusCode)\n\(apiKey)\n\(binding)\n",
				statusCode: response.statusCode,
				body: body
			) else {
				return .signatureInvalid
			}

			return verifySignature(signatureData, payloadData: payloadData, v1Key: v1Key, rootKey: rootKey, now: now)
		}

		// ── Route 2: Salt-based verification (CDN-cacheable) ──
		guard let saltBase64 = response.value(forHTTPHeaderField: "X-AppActor-Signature-Salt") else {
			return .unsigned
		}

		guard let signatureBase64 = response.value(forHTTPHeaderField: "X-AppActor-Signature") else {
			return .signatureMissing
		}

		guard let timestampStr = response.value(forHTTPHeaderField: "X-AppActor-Signature-Timestamp"),
		      let timestamp = TimeInterval(timestampStr),
		      timestamp.isFinite else {
			return .signatureMissing
		}

		if abs(now - timestamp) > maxTimestampDrift {
			return .timestampOutOfRange
		}

		guard let signatureData = Data(base64Encoded: signatureBase64) else {
			return .signatureInvalid
		}

		let eTag = response.value(forHTTPHeaderField: "ETag") ?? ""
		guard let payloadData = signedPayload(
			header: "\(saltBase64)\n\(apiKey)\n\(requestPath)\n\(timestampStr)\n\(eTag)\n", statusCode: response.statusCode, body: body
		) else {
			return .signatureInvalid
		}

		return verifySignature(signatureData, payloadData: payloadData, v1Key: v1Key, rootKey: rootKey, now: now)
	}

	/// The signed bytes: `header`, then the body exactly as received (the server signs the UTF-8
	/// of its JSON). A salt signature doesn't cover the status (salt responses are shared through
	/// the CDN with SDKs that don't sign it), so a 304 must have no body and any other status one,
	/// as the server sends them: a signed 304 can't pass as a 200. `nil` otherwise.
	private static func signedPayload(header: String, statusCode: Int, body: Data) -> Data? {
		guard (statusCode == 304) == body.isEmpty else { return nil }
		return Data(header.utf8) + body
	}

	/// Routes signature verification to v1 or v2 based on blob size.
	private static func verifySignature(
		_ signatureData: Data,
		payloadData: Data,
		v1Key: Curve25519.Signing.PublicKey?,
		rootKey: Curve25519.Signing.PublicKey?,
		now: TimeInterval
	) -> VerificationResult {
		if signatureData.count == v2BlobSize {
			return verifyV2(blob: signatureData, payloadData: payloadData, rootKey: rootKey, now: now)
		} else if signatureData.count == v1SignatureSize {
			return verifyV1(signature: signatureData, payloadData: payloadData, v1Key: v1Key)
		} else {
			return .signatureInvalid
		}
	}

	// MARK: - v1 Direct Verification

	private static func verifyV1(
		signature: Data,
		payloadData: Data,
		v1Key: Curve25519.Signing.PublicKey?
	) -> VerificationResult {
		guard let key = v1Key else {
			return .publicKeyUnavailable
		}
		return key.isValidSignature(signature, for: payloadData) ? .success : .signatureInvalid
	}

	// MARK: - v2 Intermediate Chain Verification

	private static func verifyV2(
		blob: Data,
		payloadData: Data,
		rootKey: Curve25519.Signing.PublicKey?,
		now: TimeInterval
	) -> VerificationResult {
		guard let rootKey else {
			return .publicKeyUnavailable
		}

		// Parse blob fields — use startIndex-relative offsets for safety
		let base = blob.startIndex
		let certHeader = blob[base..<base.advanced(by: certHeaderSize)]   // [0..51]
		let rootCertSig = blob[base.advanced(by: 52)..<base.advanced(by: 116)]  // [52..115]
		let payloadSig = blob[base.advanced(by: 116)..<base.advanced(by: 180)]  // [116..179]

		// Verify version and flags
		guard certHeader[certHeader.startIndex] == 0x02 else {
			return .signatureInvalid
		}
		// Reject unknown flags — fail closed for forward compatibility
		guard certHeader[certHeader.startIndex.advanced(by: 1)] == 0x00 else {
			return .signatureInvalid
		}

		// Extract issuedAt (uint64 BE at offset 4) and expiresAt (offset 12)
		let issuedAt = readUInt64BE(certHeader, offset: 4)
		let expiresAt = readUInt64BE(certHeader, offset: 12)

		// Check intermediate key validity window
		let nowUInt = UInt64(max(0, now))
		if nowUInt < issuedAt {
			// Certificate is from the future — reject (clock skew or pre-leaked key)
			return .intermediateCertInvalid
		}
		if nowUInt >= expiresAt {
			return .intermediateKeyExpired
		}

		// Verify root certification: rootPublicKey.verify("appactor-cert-v1" + certHeader)
		var certPayload = Data(certPrefix.utf8)
		certPayload.append(certHeader)

		guard rootKey.isValidSignature(rootCertSig, for: certPayload) else {
			return .intermediateCertInvalid
		}

		// Extract intermediate public key (32 bytes at offset 20 within certHeader)
		let pubStart = certHeader.startIndex.advanced(by: 20)
		let intermediatePubRaw = certHeader[pubStart..<pubStart.advanced(by: 32)]
		guard let intermediateKey = try? Curve25519.Signing.PublicKey(rawRepresentation: intermediatePubRaw) else {
			return .signatureInvalid
		}

		return intermediateKey.isValidSignature(payloadSig, for: payloadData) ? .success : .signatureInvalid
	}

	// MARK: - Helpers

	static func generateNonce() -> String {
		UUID().uuidString
	}

	/// What the server signs next to the nonce for a client that sends
	/// `X-AppActor-Signature-Binding: request`: method, path + query, and the lowercase hex
	/// SHA-256 of the request body (of no bytes when there is none). A response to a rewritten
	/// request (another user's path or body) then fails verification.
	static func requestBinding(method: String, target: String, body: Data?) -> String {
		"\(method)\n\(target)\n\(Data(SHA256.hash(data: body ?? Data())).lowercaseHexString)"
	}

	static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
		let startIndex = data.startIndex.advanced(by: offset)
		var value: UInt64 = 0
		for i in 0..<8 {
			value = (value << 8) | UInt64(data[startIndex.advanced(by: i)])
		}
		return value
	}
}
