import Foundation
import AppActor

@MainActor
final class AppState: ObservableObject {

    // MARK: - Configuration

    let apiKey = "pk_live_7ec893603ab8ef7196b259667062d347d472ac56a762865808b7f22c2f1a8937"

    // MARK: - Shared State

    private var didConfigure = false
    @Published var isConfigured = false
    @Published var isConfiguring = false
    @Published var currentAppUserId: String = "-"
    @Published var isAnonymous: Bool = true
    @Published var errorMessage: String?
    @Published var isLoading = false

    let logStore = LogStore()

    // MARK: - Configure

    func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        isConfiguring = true

        logStore.log("▶ configure() starting — apiKey: \(String(apiKey.prefix(12)))…")

        Task {
            await AppActor.configure(apiKey: apiKey)
            try? AppActor.shared.enableAppleSearchAdsTracking(
                options: AppActorASAOptions(debugMode: true)
            )

            isConfiguring = false
            isConfigured = true
            logStore.log("✅ configure() complete — bootstrap finished")
            refreshState()
            wireCallbacks()
        }
    }

    // MARK: - Callbacks (wired after configure)

    private func wireCallbacks() {
        // Receipt pipeline events — every POST attempt, retry, success, rejection
        AppActor.shared.onReceiptPipelineEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event.event {
                case .postedOk(let txId):
                    self.logStore.log("✅ [RECEIPT] Posted OK — txId: \(txId)")
                case .retryScheduled(let txId, let attempt, let nextAt, let code):
                    let next = Self.shortTime(nextAt)
                    self.logStore.log("⏳ [RECEIPT] Retry #\(attempt) scheduled — txId: \(txId)  code: \(code ?? "-")  next: \(next)", level: .warning)
                case .permanentlyRejected(let txId, let code):
                    self.logStore.log("❌ [RECEIPT] Permanently rejected — txId: \(txId)  code: \(code ?? "-")", level: .error)
                case .deadLettered(let txId, let attempts, let code):
                    self.logStore.log("💀 [RECEIPT] Dead-lettered after \(attempts) attempts — txId: \(txId)  code: \(code ?? "-")", level: .error)
                case .duplicateSkipped(let key):
                    self.logStore.log("⚠️ [RECEIPT] Duplicate skipped — key: \(key)", level: .warning)
                @unknown default:
                    break
                }
            }
        }

        // Customer info updated — fires after each successful receipt POST
        AppActor.shared.onCustomerInfoChanged = { [weak self] info in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let entitlements = info.entitlements.filter(\.value.isActive).keys.sorted().joined(separator: ", ")
                let offline = info.isComputedOffline ? " [OFFLINE]" : ""
                self.logStore.log("👤 [CUSTOMER] Updated\(offline) — userId: \(info.appUserId ?? "-")  active: [\(entitlements.isEmpty ? "none" : entitlements)]")
                self.refreshState()
            }
        }

        logStore.log("🔗 Pipeline event callbacks wired", level: .debug)
    }

    // MARK: - Identity

    func login(userId: String) {
        guard ensureConfigured() else { return }
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a user ID above."
            return
        }
        isLoading = true
        logStore.log("▶ logIn(\(trimmed)) starting")
        Task {
            do {
                try await AppActor.shared.logIn(newAppUserId: trimmed)
                logStore.log("✅ logIn(\(trimmed)) succeeded")
                refreshState()
            } catch {
                showError(error)
            }
            isLoading = false
        }
    }

    func logout() {
        guard ensureConfigured() else { return }
        isLoading = true
        logStore.log("▶ logOut() starting")
        Task {
            do {
                try await AppActor.shared.logOut()
                logStore.log("✅ logOut() succeeded — new userId: \(AppActor.shared.appUserId ?? "-")")
                refreshState()
            } catch {
                showError(error)
            }
            isLoading = false
        }
    }

    // MARK: - Reset

    func resetSDK() {
        logStore.log("▶ reset() called")
        Task {
            await AppActor.shared.reset()
            isConfigured = false
            didConfigure = false
            currentAppUserId = "-"
            isAnonymous = true
            logStore.log("✅ reset() complete")
        }
    }

    // MARK: - Helpers

    func ensureConfigured() -> Bool {
        guard isConfigured else {
            errorMessage = "Not configured. Tap Configure first."
            return false
        }
        return true
    }

    func refreshState() {
        currentAppUserId = AppActor.shared.appUserId ?? "-"
        isAnonymous = AppActor.shared.isAnonymous
    }

    func showError(_ error: Error) {
        refreshState()
        if let payment = error as? AppActorError {
            errorMessage = payment.localizedDescription
        } else {
            errorMessage = error.localizedDescription
        }
        logStore.log("❌ Error: \(error.localizedDescription)", level: .error)
    }

    private static let shortTimeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private static func shortTime(_ date: Date) -> String {
        shortTimeFmt.string(from: date)
    }
}
