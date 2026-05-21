import Foundation
import StoreKit

/// Resolved transaction environment used by both the receipt pipeline and ASA gating.
enum AppActorTransactionEnvironment: String, Sendable {
    case production
    case sandbox
    case unknown

    static func from(rawValue: String?) -> Self? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "production":
            return .production
        case "sandbox", "xcode", "localtesting", "local_testing":
            return .sandbox
        default:
            return nil
        }
    }
}

/// Resolved transaction reason used to distinguish initial purchases from renewals/restores.
enum AppActorTransactionReason: String, Sendable {
    case purchase
    case renewal
    case unknown

    static func from(rawValue: String?) -> Self? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "purchase":
            return .purchase
        case "renewal":
            return .renewal
        default:
            return nil
        }
    }
}

/// Shared StoreKit/JWS helpers used by the receipt pipeline and ASA attribution logic.
enum AppActorASATransactionSupport {

    static func decodeJWSPayload(_ jws: String) -> [String: Any]? {
        let segments = jws.split(separator: ".")
        guard segments.count == 3 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func resolveEnvironment(
        for transaction: Transaction,
        jwsPayload: [String: Any]?,
        receiptFileName: String? = Bundle.main.appStoreReceiptURL?.lastPathComponent
    ) -> AppActorTransactionEnvironment {
        let storeKitEnvironmentRaw: String?
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            storeKitEnvironmentRaw = transaction.environment.rawValue
        } else {
            storeKitEnvironmentRaw = nil
        }

        return resolveEnvironment(
            storeKitEnvironmentRaw: storeKitEnvironmentRaw,
            jwsPayload: jwsPayload,
            receiptFileName: receiptFileName
        )
    }

    static func resolveEnvironment(
        storeKitEnvironmentRaw: String?,
        jwsPayload: [String: Any]?,
        receiptFileName: String?
    ) -> AppActorTransactionEnvironment {
        if let environment = AppActorTransactionEnvironment.from(rawValue: storeKitEnvironmentRaw) {
            return environment
        }

        if let environment = AppActorTransactionEnvironment.from(
            rawValue: stringValue(in: jwsPayload, key: "environment")
        ) {
            return environment
        }

        if let receiptFileName, !receiptFileName.isEmpty {
            return receiptFileName == "sandboxReceipt" ? .sandbox : .production
        }

        return .unknown
    }

    static func resolveReason(
        for transaction: Transaction,
        jwsPayload: [String: Any]?
    ) -> AppActorTransactionReason {
        let storeKitReasonRaw: String?
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            storeKitReasonRaw = transaction.reason.rawValue
        } else {
            storeKitReasonRaw = nil
        }

        return resolveReason(storeKitReasonRaw: storeKitReasonRaw, jwsPayload: jwsPayload)
    }

    static func resolveReason(
        storeKitReasonRaw: String?,
        jwsPayload: [String: Any]?
    ) -> AppActorTransactionReason {
        if let reason = AppActorTransactionReason.from(rawValue: storeKitReasonRaw) {
            return reason
        }

        if let reason = AppActorTransactionReason.from(
            rawValue: stringValue(in: jwsPayload, key: "transactionReason")
        ) {
            return reason
        }

        return .unknown
    }

    static func isEligibleForASAPurchaseEvent(
        source: AppActorPaymentQueueItem.Source,
        isRevoked: Bool,
        ownershipType: Transaction.OwnershipType,
        environment: AppActorTransactionEnvironment,
        reason: AppActorTransactionReason,
        trackInSandbox: Bool
    ) -> Bool {
        guard !isRevoked else { return false }
        guard ownershipType == .purchased else { return false }

        if !trackInSandbox && (environment == .sandbox || environment == .unknown) {
            return false
        }

        switch source {
        case .purchase:
            return true
        case .restore:
            return false
        case .transactionUpdates, .sweep:
            return reason == .purchase
        }
    }

    private static func stringValue(in payload: [String: Any]?, key: String) -> String? {
        switch payload?[key] {
        case let string as String:
            return string
        case let nsString as NSString:
            return nsString as String
        default:
            return nil
        }
    }
}
