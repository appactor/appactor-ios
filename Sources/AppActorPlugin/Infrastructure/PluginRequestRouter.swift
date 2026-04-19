import Foundation

/// Routes method names to their corresponding request handlers.
enum AppActorPluginRequestRouter {

    @MainActor
    static var registry: [String: any AppActorPluginRequest.Type] = {
        var requests: [any AppActorPluginRequest.Type] = [
            ConfigureRequest.self,
            LogInRequest.self,
            LogOutRequest.self,
            PurchasePackageRequest.self,
            RestorePurchasesRequest.self,
            SyncPurchasesRequest.self,
            QuietSyncPurchasesRequest.self,
            DrainReceiptQueueAndRefreshCustomerRequest.self,
            GetCustomerInfoRequest.self,
            ActiveEntitlementsOfflineRequest.self,
            GetOfferingsRequest.self,
            GetRemoteConfigsRequest.self,
            GetExperimentAssignmentRequest.self,
            EnableAppleSearchAdsTrackingRequest.self,
            GetASADiagnosticsRequest.self,
            GetPendingASAPurchaseEventCountRequest.self,
            GetASAFirstInstallOnDeviceRequest.self,
            GetASAFirstInstallOnAccountRequest.self,
            ResetRequest.self,
            PresentOfferCodeRequest.self,
            SetLogLevelRequest.self,
            GetSDKVersionRequest.self,
            GetAppUserIdRequest.self,
            GetIsAnonymousRequest.self,
            GetCachedOfferingsRequest.self,
            GetCachedRemoteConfigsRequest.self,
            GetCachedCustomerInfoRequest.self,
            GetRemoteConfigRequest.self,
            SetFallbackOfferingsRequest.self,
        ]
        if #available(iOS 16.4, macOS 14.4, tvOS 16.4, watchOS 9.4, *) {
            requests.append(PurchaseFromIntentRequest.self)
        }
        return Dictionary(uniqueKeysWithValues: requests.map { ($0.method, $0) })
    }()

    /// All registered method names.
    @MainActor
    static var availableMethods: [String] { registry.keys.sorted() }

    /// Decodes and executes a request for the given method.
    @MainActor
    static func route(method: String, jsonData: Data) async -> AppActorPluginResult {
        guard let requestType = registry[method] else {
            return .error(AppActorPluginError(
                code: AppActorPluginError.unknownMethod,
                message: "Unknown method: '\(method)'",
                detail: "Available: \(availableMethods.joined(separator: ", "))"
            ))
        }

        let request: any AppActorPluginRequest
        do {
            request = try AppActorPluginCoder.decoder.decode(requestType, from: jsonData)
        } catch {
            return .error(AppActorPluginError(
                code: AppActorPluginError.decodingFailed,
                message: "Failed to decode params for '\(method)'",
                detail: error.localizedDescription
            ))
        }

        do {
            return try await request.execute()
        } catch let pluginError as AppActorPluginError {
            return .error(pluginError)
        } catch {
            return .error(AppActorPluginError(from: error))
        }
    }
}

// MARK: - Dynamic Registration

extension AppActorPlugin {

    /// Registers additional request handlers at runtime.
    ///
    /// This is the official extension point for host apps that need to expose
    /// custom JSON-RPC methods through the AppActor plugin bridge.
    @MainActor
    public func register(requests: [any AppActorPluginRequest.Type]) {
        for request in requests {
            AppActorPluginRequestRouter.registry[request.method] = request
        }
    }

    /// Remove request handlers by method name.
    @MainActor
    public func remove(methods: [String]) {
        for method in methods {
            AppActorPluginRequestRouter.registry.removeValue(forKey: method)
        }
    }

    /// All currently registered method names.
    @MainActor
    public var registeredMethods: [String] {
        AppActorPluginRequestRouter.availableMethods
    }
}
