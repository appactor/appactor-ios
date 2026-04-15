import Foundation
import StoreKit

/// Minimal SK2 transaction snapshot used by quiet `syncPurchases()`.
struct AppActorSilentSyncTransaction: Sendable, Equatable {
	let transactionId: String
	let originalTransactionId: String?
	let productId: String
	let bundleId: String
	let environment: String
	let storefront: String?
	let jwsRepresentation: String
}

/// Abstraction for the RevenueCat-style SK2 quiet sync candidate lookup.
protocol AppActorStoreKitSilentSyncFetcherProtocol: Sendable {
	func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction?
	func appTransactionJWS() async -> String?
}

/// Default StoreKit-backed implementation used by `syncPurchases()`.
struct AppActorStoreKitSilentSyncFetcher: AppActorStoreKitSilentSyncFetcherProtocol {
	func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction? {
		let bundleId = Bundle.main.bundleIdentifier ?? "unknown"

		for await result in Transaction.all {
			guard case .verified(let transaction) = result else { continue }

			let jws = result.jwsRepresentation
			let jwsPayload = AppActorASATransactionSupport.decodeJWSPayload(jws)
			let environment = AppActorASATransactionSupport.resolveEnvironment(
				for: transaction,
				jwsPayload: jwsPayload
			).rawValue

			var storefront: String? = nil
			if #available(iOS 17.0, macOS 14.0, *) {
				storefront = transaction.storefrontCountryCode
			}

			return AppActorSilentSyncTransaction(
				transactionId: String(transaction.id),
				originalTransactionId: String(transaction.originalID),
				productId: transaction.productID,
				bundleId: bundleId,
				environment: environment,
				storefront: storefront,
				jwsRepresentation: jws
			)
		}

		return nil
	}

	func appTransactionJWS() async -> String? {
		if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
			return try? await AppTransaction.shared.jwsRepresentation
		}

		return nil
	}
}
