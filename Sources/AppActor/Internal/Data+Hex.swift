import Foundation

extension Data {
    /// The bytes as lowercase hex, e.g. for a SHA-256 digest (the same form as Node's `digest('hex')`).
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
