import Foundation

/// Store-agnostic purchase metadata returned after a successful native purchase.
public struct AppActorPurchaseInfo: Sendable, Codable, Equatable {
    public let store: AppActorStore
    public let productId: String
    public let transactionId: String?
    public let originalTransactionId: String?
    public let purchaseDate: Date?
    public let isSandbox: Bool

    public init(
        store: AppActorStore,
        productId: String,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        purchaseDate: Date? = nil,
        isSandbox: Bool = false
    ) {
        self.store = store
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.purchaseDate = purchaseDate
        self.isSandbox = isSandbox
    }
}
