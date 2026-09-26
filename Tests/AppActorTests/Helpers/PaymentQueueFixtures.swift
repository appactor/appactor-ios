import Foundation
@testable import AppActor

extension AppActorPaymentQueueItem {
    /// A `.needsPost` item for one transaction; `transactionId` defaults to `key`.
    static func fixture(
        key: String = "apple:12345",
        transactionId: String? = nil,
        jws: String = "jws_payload",
        appUserId: String = "user_123",
        source: Source = .purchase
    ) -> AppActorPaymentQueueItem {
        let now = Date()
        return AppActorPaymentQueueItem(
            key: key,
            bundleId: "com.test",
            environment: "sandbox",
            transactionId: transactionId ?? key,
            jws: jws,
            signedAppTransactionInfo: nil,
            appUserId: appUserId,
            productId: "com.test.monthly",
            originalTransactionId: transactionId ?? key,
            storefront: "USA",
            offeringId: nil,
            packageId: nil,
            phase: .needsPost,
            attemptCount: 0,
            nextRetryAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            lastError: nil,
            sources: [source],
            claimedAt: nil
        )
    }
}

extension AppActorReceiptPostResponse {
    /// The server's answer to a revoked receipt (`permanentErrorResult('REVOKED_TRANSACTION', …)`).
    static let revokedTransaction = AppActorReceiptPostResponse(
        status: "permanent_error",
        error: AppActorReceiptErrorInfo(code: "REVOKED_TRANSACTION", message: "Transaction has been revoked by Apple"),
        requestId: "req_revoked",
        finishTransaction: true
    )
}
