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

/// Minimal AppTransaction snapshot used by quiet `syncPurchases()`.
struct AppActorSilentSyncAppTransaction: Sendable, Equatable {
	let bundleId: String
	let environment: String
	let jwsRepresentation: String
}

/// Abstraction for the RevenueCat-style SK2 quiet sync candidate lookup.
protocol AppActorStoreKitSilentSyncFetcherProtocol: Sendable {
	func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction?
	func appTransaction() async -> AppActorSilentSyncAppTransaction?
}

/// Default StoreKit-backed implementation used by `syncPurchases()`.
struct AppActorStoreKitSilentSyncFetcher: AppActorStoreKitSilentSyncFetcherProtocol {
	/// `AppTransaction.shared` is one StoreKit round trip plus a JWS verification, and its
	/// value does not change for the life of the install; every enqueued receipt asks for it,
	/// so the first successful answer is kept. A `nil` answer is not kept: the next caller retries.
	private actor AppTransactionMemo {
		private var cached: AppActorSilentSyncAppTransaction?

		func value(
			or fetch: @Sendable () async -> AppActorSilentSyncAppTransaction?
		) async -> AppActorSilentSyncAppTransaction? {
			if let cached { return cached }
			let fetched = await fetch()
			cached = fetched
			return fetched
		}
	}

	private let appTransactionMemo = AppTransactionMemo()

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

	func appTransaction() async -> AppActorSilentSyncAppTransaction? {
		await appTransactionMemo.value(or: Self.fetchAppTransaction)
	}

	private static func fetchAppTransaction() async -> AppActorSilentSyncAppTransaction? {
		if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
			do {
				let result = try await AppTransaction.shared
				guard case let .verified(appTransaction) = result else {
					return nil
				}

				let jws = result.jwsRepresentation
				let jwsPayload = AppActorASATransactionSupport.decodeJWSPayload(jws)
				let environment = AppActorASATransactionSupport.resolveEnvironment(
					storeKitEnvironmentRaw: appTransaction.environment.rawValue,
					jwsPayload: jwsPayload,
					receiptFileName: Bundle.main.appStoreReceiptURL?.lastPathComponent
				).rawValue

				return AppActorSilentSyncAppTransaction(
					bundleId: appTransaction.bundleID,
					environment: environment,
					jwsRepresentation: jws
				)
			} catch {
				return nil
			}
		}

		return nil
	}
}
