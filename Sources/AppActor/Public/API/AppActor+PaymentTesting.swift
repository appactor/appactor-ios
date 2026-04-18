import Foundation

// MARK: - Payment Testing Configuration

extension AppActor {

    /// Configures payment with a custom client (for testing).
    func configureForTesting(
        config: AppActorPaymentConfiguration,
        client: AppActorPaymentClientProtocol,
        storage: AppActorPaymentStorage,
        etagManager: AppActorETagManager? = nil,
        offeringsManager: AppActorOfferingsManager? = nil,
        customerManager: AppActorCustomerManager? = nil,
        remoteConfigManager: AppActorRemoteConfigManager? = nil,
        experimentManager: AppActorExperimentManager? = nil,
        paymentQueueStore: AppActorPaymentQueueStoreProtocol? = nil,
        silentSyncFetcher: (any AppActorStoreKitSilentSyncFetcherProtocol)? = nil
    ) {
        paymentLifecycle = .configured
        let etagManager = etagManager ?? AppActorETagManager()
        self.paymentETagManager = etagManager

        self.paymentConfig = config
        self.paymentStorage = storage
        self.paymentClient = client
        self.paymentCurrentUser = nil
        self.offeringsManager = offeringsManager ?? AppActorOfferingsManager(client: client, etagManager: etagManager)
        self.paymentOfferings = nil
        self.remoteConfigManager = remoteConfigManager ?? AppActorRemoteConfigManager(client: client, etagManager: etagManager)
        self.paymentRemoteConfigs = nil
        self.experimentManager = experimentManager ?? AppActorExperimentManager(client: client, etagManager: etagManager)
        self.customerManager = customerManager ?? AppActorCustomerManager(
            client: client,
            etagManager: etagManager
        )

        // Payment pipeline for testing
        let queueStore = paymentQueueStore ?? AppActorAtomicJSONQueueStore()
        let processor = AppActorPaymentProcessor(store: queueStore, client: client)
        let storeKitFetcher = silentSyncFetcher ?? AppActorStoreKitSilentSyncFetcher()
        self.paymentQueueStore = queueStore
        self.paymentProcessor = processor
        self.transactionWatcher = AppActorTransactionWatcher(
            processor: processor,
            storage: storage,
            silentSyncFetcher: storeKitFetcher
        )
        self.storeKitSilentSyncFetcher = storeKitFetcher

        self.asaManager = nil

        // Tests skip bootstrap, so mark the generated local user as confirmed.
        Task { await processor.confirmIdentity(appUserId: storage.ensureAppUserId()) }
        self.isBootstrapComplete = true

        // Watcher setup and bootstrap handled by runStartupSequence().
        // Instance configureForTesting doesn't run startup — caller manages lifecycle.
    }

}
