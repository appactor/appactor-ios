import Foundation
@testable import AppActor

struct MockStoreKitSilentSyncFetcher: AppActorStoreKitSilentSyncFetcherProtocol {
    var firstVerifiedTransactionHandler: (@Sendable () async -> AppActorSilentSyncTransaction?)?
    var appTransactionJWSHandler: (@Sendable () async -> String?)?

    func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction? {
        if let handler = firstVerifiedTransactionHandler {
            return await handler()
        }
        return nil
    }

    func appTransactionJWS() async -> String? {
        if let handler = appTransactionJWSHandler {
            return await handler()
        }
        return nil
    }
}
