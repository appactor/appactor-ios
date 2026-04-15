import Foundation
@testable import AppActor

struct MockStoreKitSilentSyncFetcher: AppActorStoreKitSilentSyncFetcherProtocol {
    var firstVerifiedTransactionHandler: (@Sendable () async -> AppActorSilentSyncTransaction?)?
    var appTransactionHandler: (@Sendable () async -> AppActorSilentSyncAppTransaction?)?

    func firstVerifiedTransaction() async -> AppActorSilentSyncTransaction? {
        if let handler = firstVerifiedTransactionHandler {
            return await handler()
        }
        return nil
    }

    func appTransaction() async -> AppActorSilentSyncAppTransaction? {
        if let handler = appTransactionHandler {
            return await handler()
        }
        return nil
    }
}
