import Foundation

/// Unsigned stand-ins for StoreKit transaction JWS strings: only the payload segment is real,
/// which is all the SDK decodes itself.
enum StoreKitJWSFixture {
    /// Transaction `transactionId`; `revoked` adds the `revocationDate` that a refund or a
    /// Family Sharing revoke sets.
    static func transaction(id transactionId: String = "12345", revoked: Bool) -> String {
        var payload: [String: Any] = ["transactionId": transactionId, "productId": "com.test.monthly"]
        if revoked { payload["revocationDate"] = 1_758_000_000_000 }
        let encoded = (try! JSONSerialization.data(withJSONObject: payload)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFUzI1NiJ9.\(encoded).c2ln"
    }
}
