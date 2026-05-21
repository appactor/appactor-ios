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
		/// Server echoed nonce but signature is missing — possible MITM header strip.
		case signatureMissing
		/// Server did not echo nonce — signing not enabled server-side (transitional).
		case signingNotSupported
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
		apiKey: String = "",
		requestPath: String = ""
	) -> VerificationResult {
		verify(
			response: response,
			body: body,
			sentNonce: sentNonce,
			apiKey: apiKey,
			requestPath: requestPath,
			v1Key: v1PublicKey,
			rootKey: rootPublicKey,
			now: Date().timeIntervalSince1970
		)
	}

	// MARK: - Verify (test-injectable — accepts custom keys and time)

	/// Test-injectable overload. Production `verify()` delegates to this.
	///
	/// Mode selection:
	///   - sentNonce != nil → nonce-based verification (existing, unchanged)
	///   - sentNonce == nil → salt-based verification (new, CDN-cacheable)
	static func verify(
		response: HTTPURLResponse,
		body: Data,
		sentNonce: String?,
		apiKey: String,
		requestPath: String,
		v1Key: Curve25519.Signing.PublicKey?,
		rootKey: Curve25519.Signing.PublicKey?,
		now: TimeInterval
	) -> VerificationResult {

		// ── Route 1: Nonce-based verification (existing logic) ──
		if let sentNonce {
			let echoedNonce = response.value(forHTTPHeaderField: "X-AppActor-Request-Nonce")

			guard let echoedNonce else {
				return .signingNotSupported
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

			let bodyString = String(data: body, encoding: .utf8) ?? ""
			let payload = "\(sentNonce)\n\(timestampStr)\n\(bodyString)"
			guard let payloadData = payload.data(using: .utf8) else {
				return .signatureInvalid
			}

			return verifySignature(signatureData, payloadData: payloadData, v1Key: v1Key, rootKey: rootKey, now: now)
		}

		// ── Route 2: Salt-based verification (new, CDN-cacheable) ──
		guard let saltBase64 = response.value(forHTTPHeaderField: "X-AppActor-Signature-Salt") else {
			return .signingNotSupported
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
		let bodyString = String(data: body, encoding: .utf8) ?? ""
		let payload = "\(saltBase64)\n\(apiKey)\n\(requestPath)\n\(timestampStr)\n\(eTag)\n\(bodyString)"
		guard let payloadData = payload.data(using: .utf8) else {
			return .signatureInvalid
		}

		return verifySignature(signatureData, payloadData: payloadData, v1Key: v1Key, rootKey: rootKey, now: now)
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

	static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
		let startIndex = data.startIndex.advanced(by: offset)
		var value: UInt64 = 0
		for i in 0..<8 {
			value = (value << 8) | UInt64(data[startIndex.advanced(by: i)])
		}
		return value
	}
}
