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

/// What quiet sync reads from a candidate transaction; a seam so tests can feed it entries.
protocol AppActorRevocableTransaction {
	var revocationDate: Date? { get }
}

extension Transaction: AppActorRevocableTransaction {}

/// Abstraction for the RevenueCat-style SK2 quiet sync candidate lookup.
protocol AppActorStoreKitSilentSyncFetcherProtocol: Sendable {
	func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction?
	func appTransaction() async -> AppActorSilentSyncAppTransaction?
}

/// Default StoreKit-backed implementation used by `syncPurchases()`.
struct AppActorStoreKitSilentSyncFetcher: AppActorStoreKitSilentSyncFetcherProtocol {
	/// `AppTransaction.shared` is one StoreKit round trip plus a JWS verification, and its
	/// value does not change for the life of the install; every enqueued receipt asks for it,
	/// so the first successful answer is kept and concurrent callers share one in-flight fetch.
	/// A `nil` answer is not kept: the next caller retries.
	private actor AppTransactionMemo {
		private var cached: AppActorSilentSyncAppTransaction?
		private var inFlight: Task<AppActorSilentSyncAppTransaction?, Never>?

		func value() async -> AppActorSilentSyncAppTransaction? {
			if let cached { return cached }
			let task = inFlight ?? Task { await AppActorStoreKitSilentSyncFetcher.fetchAppTransaction() }
			inFlight = task
			let value = await task.value
			cached = value
			if inFlight == task { inFlight = nil }
			return value
		}
	}

	private let appTransactionMemo = AppTransactionMemo()

	func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction? {
		guard let result = await Self.firstSyncCandidate(in: Transaction.all),
			  case .verified(let transaction) = result else { return nil }

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
			bundleId: Bundle.main.bundleIdentifier ?? "unknown",
			environment: environment,
			storefront: storefront,
			jwsRepresentation: jws
		)
	}

	/// The first verified entry that isn't refunded or revoked. A revoked one is no candidate:
	/// the server answers its post with REVOKED_TRANSACTION and links no owner, and while it came
	/// first the AppTransaction post, the one that links a reinstall to its owner, never ran.
	/// `Transaction.all` includes refunded consumables even when finished.
	static func firstSyncCandidate<Entries: AsyncSequence, Candidate: AppActorRevocableTransaction>(
		in entries: Entries
	) async rethrows -> Entries.Element? where Entries.Element == VerificationResult<Candidate> {
		for try await entry in entries {
			guard case .verified(let candidate) = entry, candidate.revocationDate == nil else { continue }
			return entry
		}
		return nil
	}

	func appTransaction() async -> AppActorSilentSyncAppTransaction? {
		await appTransactionMemo.value()
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
