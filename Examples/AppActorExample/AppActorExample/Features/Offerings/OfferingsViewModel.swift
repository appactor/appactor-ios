import Foundation
import AppActor

@MainActor
final class OfferingsViewModel: ObservableObject {

    @Published var offerings: AppActorOfferings?
    @Published var isPremiumStatus: Bool?

    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func fetchOfferings() {
        guard let appState, appState.ensureConfigured() else { return }
        appState.isLoading = true
        appState.logStore.log("▶ offerings() fetch starting")
        Task {
            do {
                offerings = try await AppActor.shared.offerings()
                let count = offerings?.all.count ?? 0
                let current = offerings?.current?.id ?? "-"
                appState.logStore.log("✅ offerings() fetched \(count) offering(s) — current: \(current)")
                if let all = offerings?.all.values {
                    for offering in all.sorted(by: { $0.id < $1.id }) {
                        let pkgIds = offering.packages.map(\.productId).joined(separator: ", ")
                        appState.logStore.log("   📦 [\(offering.id)] packages: \(pkgIds)", level: .debug)
                    }
                }
                appState.refreshState()
            } catch {
                appState.showError(error)
            }
            appState.isLoading = false
        }
    }

    func purchasePackage(_ package: AppActorPackage) {
        guard let appState, appState.ensureConfigured() else { return }
        appState.isLoading = true
        let productId = package.productId
        appState.logStore.log("▶ [PURCHASE] Starting: \(productId)  type: \(package.packageType.rawValue)  userId: \(AppActor.shared.appUserId ?? "-")")
        Task {
            do {
                let result = try await AppActor.shared.purchase(package: package)
                switch result {
                case .success(let customerInfo, let purchaseInfo):
                    let txId = purchaseInfo?.transactionId ?? "-"
                    let originalId = purchaseInfo?.originalTransactionId ?? "-"
                    let env: String
                    switch purchaseInfo?.isSandbox {
                    case true:
                        env = "sandbox"
                    case false:
                        env = "production"
                    case nil:
                        env = "unknown"
                    }
                    let entitlements = customerInfo.entitlements.filter(\.value.isActive).keys.sorted().joined(separator: ", ")
                    appState.logStore.log("✅ [PURCHASE] Success: \(productId)")
                    appState.logStore.log("   txId: \(txId)  origId: \(originalId)  env: \(env)")
                    appState.logStore.log("   active entitlements: [\(entitlements.isEmpty ? "none" : entitlements)]")
                    appState.logStore.log("   offline: \(customerInfo.isComputedOffline ? "YES (server pending)" : "no")")
                    appState.errorMessage = nil
                case .cancelled:
                    appState.logStore.log("⚠️ [PURCHASE] Cancelled by user: \(productId)", level: .warning)
                case .pending:
                    appState.logStore.log("⏳ [PURCHASE] Pending approval (Ask to Buy): \(productId)", level: .warning)
                    appState.errorMessage = "Waiting for approval (Ask to Buy)"
                }
                appState.refreshState()
            } catch let error as AppActorError {
                switch error.kind {
                case .purchaseFailed:
                    appState.logStore.log("❌ [PURCHASE] StoreKit failed: \(productId)  — \(error.localizedDescription)", level: .error)
                case .receiptPostFailed:
                    appState.logStore.log("❌ [PURCHASE] Receipt POST failed: \(productId)  code: \(error.code ?? "-")  msg: \(error.message ?? "-")", level: .error)
                case .receiptQueuedForRetry:
                    appState.logStore.log("⏳ [PURCHASE] Receipt queued for retry: \(productId)  — will retry in background", level: .warning)
                case .purchaseAlreadyInProgress:
                    appState.logStore.log("⚠️ [PURCHASE] Already in progress — wait for it to finish", level: .warning)
                default:
                    appState.logStore.log("❌ [PURCHASE] Error (\(error.kind.rawValue)): \(error.localizedDescription)", level: .error)
                }
                appState.errorMessage = error.localizedDescription
                appState.refreshState()
            } catch {
                appState.showError(error)
            }
            appState.isLoading = false
        }
    }

    func checkPremium() {
        guard let appState, appState.ensureConfigured() else { return }
        appState.isLoading = true
        appState.logStore.log("▶ getCustomerInfo() — checking premium")
        Task {
            if let info = try? await AppActor.shared.getCustomerInfo() {
                isPremiumStatus = info.hasActiveEntitlement("premium")
                let active = info.entitlements.filter(\.value.isActive).keys.sorted().joined(separator: ", ")
                appState.logStore.log("✅ getCustomerInfo() — premium: \(isPremiumStatus == true)  active: [\(active.isEmpty ? "none" : active)]")
            } else {
                let keys = await AppActor.shared.activeEntitlementKeysOffline()
                isPremiumStatus = keys.contains("premium")
                appState.logStore.log("⚠️ getCustomerInfo() failed — offline fallback  active: [\(keys.sorted().joined(separator: ", "))]", level: .warning)
            }
            appState.refreshState()
            appState.isLoading = false
        }
    }
}
