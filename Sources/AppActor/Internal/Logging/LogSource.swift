import Foundation

/// Captures the source location of a log call.
struct AppActorLogSource: Sendable, Codable {
    /// File name (derived from `#fileID`).
    let fileName: String
    /// Function name (from `#function`).
    let functionName: String
    /// Line number (from `#line`).
    let lineNumber: UInt
}

extension AppActorLogSource: CustomStringConvertible {
    var description: String {
        "\(fileName)#\(lineNumber)"
    }
}
