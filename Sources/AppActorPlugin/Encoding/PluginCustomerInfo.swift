import Foundation
import AppActor

private func dateString(_ date: Date?) -> String? {
    date.map { AppActorPluginCoder.isoDateFormatter.string(from: $0) }
}

// MARK: - CustomerInfo Surrogate

/// Encodable surrogate that maps `AppActorCustomerInfo` to the wire format
/// expected by the Flutter SDK. Mirrors Android's `CustomerInfoSurrogate`.
struct PluginCustomerInfo: Encodable, Sendable {
    let entitlements: [String: PluginEntitlementInfo]
    let subscriptions: [String: PluginSubscriptionInfo]
    let nonSubscriptions: [String: [PluginNonSubscription]]
    let consumableBalances: [String: Int]?
    let tokenBalance: PluginTokenBalance?
    let snapshotDate: String?
    let appUserId: String?
    let requestId: String?
    let requestDate: String?
    let firstSeen: String?
    let lastSeen: String?
    let managementUrl: String?
    let isComputedOffline: Bool
    let verification: String
    let productEntitlements: [String: [String]]?
    let activeEntitlementKeys: Set<String>

    init(from info: AppActorCustomerInfo) {
        self.entitlements = info.entitlements.mapValues { PluginEntitlementInfo(from: $0) }
        self.subscriptions = info.subscriptions.mapValues { PluginSubscriptionInfo(from: $0) }
        self.nonSubscriptions = info.nonSubscriptions.mapValues { $0.map { PluginNonSubscription(from: $0) } }
        self.consumableBalances = info.consumableBalances
        self.tokenBalance = info.tokenBalance.map { PluginTokenBalance(from: $0) }
        self.snapshotDate = dateString(info.snapshotDate)
        self.appUserId = info.appUserId
        self.requestId = info.requestId
        self.requestDate = info.requestDate
        self.firstSeen = info.firstSeen
        self.lastSeen = info.lastSeen
        self.managementUrl = info.managementUrl
        self.isComputedOffline = info.isComputedOffline
        self.verification = info.verification.rawValue
        self.productEntitlements = info.productEntitlements
        self.activeEntitlementKeys = info.activeEntitlementKeys
    }
}

// MARK: - EntitlementInfo Surrogate

struct PluginEntitlementInfo: Encodable, Sendable {
    let identifier: String
    let isActive: Bool
    let status: String?
    let productIdentifier: String?
    let grantedBy: String?
    let ownershipType: String
    let periodType: String
    let willRenew: Bool
    let subscriptionStatus: String?
    let store: String?
    let basePlanId: String?
    let offerId: String?
    let isSandbox: Bool?
    let cancellationReason: String?
    let purchaseDate: String?
    let startsAt: String?
    let latestPurchaseDate: String?
    let originalPurchaseDate: String?
    let expirationDate: String?
    let gracePeriodExpiresAt: String?
    let billingIssueDetectedAt: String?
    let unsubscribeDetectedAt: String?
    let renewedAt: String?
    let activePromotionalOfferType: String?
    let activePromotionalOfferId: String?

    init(from e: AppActorEntitlementInfo) {
        self.identifier = e.id
        self.isActive = e.isActive
        self.status = nil // Flutter reads this; iOS model doesn't have a separate status string
        self.productIdentifier = e.productID
        self.grantedBy = e.grantedBy
        self.ownershipType = e.ownershipType.rawValue
        self.periodType = e.periodType.rawValue
        self.willRenew = e.willRenew
        self.subscriptionStatus = e.subscriptionStatus?.rawValue
        self.store = e.store?.rawValue
        self.basePlanId = e.basePlanId
        self.offerId = e.offerId
        self.isSandbox = e.isSandbox
        self.cancellationReason = e.cancellationReason?.rawValue
        self.purchaseDate = nil // iOS model doesn't have purchaseDate; uses originalPurchaseDate
        self.startsAt = dateString(e.startsAt)
        self.latestPurchaseDate = nil // iOS model doesn't have latestPurchaseDate
        self.originalPurchaseDate = dateString(e.originalPurchaseDate)
        self.expirationDate = dateString(e.expirationDate)
        self.gracePeriodExpiresAt = dateString(e.gracePeriodExpiresAt)
        self.billingIssueDetectedAt = dateString(e.billingIssueDetectedAt)
        self.unsubscribeDetectedAt = dateString(e.unsubscribeDetectedAt)
        self.renewedAt = dateString(e.renewedAt)
        self.activePromotionalOfferType = e.activePromotionalOfferType
        self.activePromotionalOfferId = e.activePromotionalOfferId
    }
}

// MARK: - SubscriptionInfo Surrogate

struct PluginSubscriptionInfo: Encodable, Sendable {
    let subscriptionKey: String
    let productIdentifier: String
    let store: String?
    let basePlanId: String?
    let offerId: String?
    let isActive: Bool
    let expiresDate: String?
    let purchaseDate: String?
    let startsAt: String?
    let periodType: String?
    let status: String?
    let autoRenew: Bool?
    let isSandbox: Bool?
    let gracePeriodExpiresAt: String?
    let unsubscribeDetectedAt: String?
    let cancellationReason: String?
    let renewedAt: String?
    let originalTransactionId: String?
    let latestTransactionId: String?
    let activePromotionalOfferType: String?
    let activePromotionalOfferId: String?

    init(from s: AppActorSubscriptionInfo) {
        self.subscriptionKey = s.subscriptionKey
        self.productIdentifier = s.productIdentifier
        self.store = s.store?.rawValue
        self.basePlanId = s.basePlanId
        self.offerId = s.offerId
        self.isActive = s.isActive
        self.expiresDate = s.expiresDate
        self.purchaseDate = s.purchaseDate
        self.startsAt = s.startsAt
        self.periodType = s.periodType?.rawValue
        self.status = s.status
        self.autoRenew = s.autoRenew
        self.isSandbox = s.isSandbox
        self.gracePeriodExpiresAt = s.gracePeriodExpiresAt
        self.unsubscribeDetectedAt = s.unsubscribeDetectedAt
        self.cancellationReason = s.cancellationReason?.rawValue
        self.renewedAt = s.renewedAt
        self.originalTransactionId = s.originalTransactionId
        self.latestTransactionId = s.latestTransactionId
        self.activePromotionalOfferType = s.activePromotionalOfferType
        self.activePromotionalOfferId = s.activePromotionalOfferId
    }
}

// MARK: - NonSubscription Surrogate

struct PluginNonSubscription: Encodable, Sendable {
    let productIdentifier: String
    let offerId: String?
    let store: String?
    let purchaseDate: String?
    let storeTransactionIdentifier: String?
    let isSandbox: Bool?
    let isConsumable: Bool?
    let isRefund: Bool?

    init(from n: AppActorNonSubscription) {
        self.productIdentifier = n.productIdentifier
        self.offerId = n.offerId
        self.store = n.store?.rawValue
        self.purchaseDate = n.purchaseDate
        self.storeTransactionIdentifier = n.storeTransactionIdentifier
        self.isSandbox = n.isSandbox
        self.isConsumable = n.isConsumable
        self.isRefund = n.isRefund
    }
}

// MARK: - TokenBalance Surrogate

struct PluginTokenBalance: Encodable, Sendable {
    let renewable: Int
    let nonRenewable: Int
    let total: Int

    init(from t: AppActorTokenBalance) {
        self.renewable = t.renewable
        self.nonRenewable = t.nonRenewable
        self.total = t.total
    }
}

// MARK: - PurchaseInfo Surrogate

struct PluginPurchaseInfo: Encodable, Sendable {
    let store: String
    let productId: String
    let transactionId: String?
    let originalTransactionId: String?
    let purchaseDate: String?
    let isSandbox: Bool

    init(from p: AppActorPurchaseInfo) {
        self.store = p.store.rawValue
        self.productId = p.productId
        self.transactionId = p.transactionId
        self.originalTransactionId = p.originalTransactionId
        self.purchaseDate = dateString(p.purchaseDate)
        self.isSandbox = p.isSandbox
    }
}
