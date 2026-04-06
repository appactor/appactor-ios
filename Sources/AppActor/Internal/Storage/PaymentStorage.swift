import Foundation

// MARK: - Storage Protocol

/// Abstraction for payment identity persistence.
protocol AppActorPaymentStorage: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func remove(forKey key: String)
}

// MARK: - Keys

enum AppActorPaymentStorageKey {
    static let appUserId = "appactor_billing_app_user_id"
    static let serverUserId = "appactor_billing_server_user_id"
    static let lastRequestId = "appactor_billing_last_request_id"

    // App Account Token (for StoreKit purchase → Apple transaction binding)
    static let appAccountToken = "appactor_app_account_token"

    // ASA (Apple Search Ads) keys
    static let asaAttributionCompleted = "appactor_asa_attribution_completed"
    /// [L7] Single atomic key for pending user ID change (replaces two separate keys).
    static let asaPendingUserIdChange = "appactor_asa_pending_user_id_change"
    /// JSON array of originalTransactionIds already sent to ASA backend.
    /// Provides lifetime dedup — renewals with the same originalTransactionId are skipped
    /// even after the pending event has been flushed and removed from the event store.
    static let asaSentOriginalTransactionIds = "appactor_asa_sent_original_tx_ids"
    /// ISO 8601 timestamp of first SDK initialization for this install.
    static let asaInstallDate = "appactor_asa_install_date"
    /// Number of times attribution was POSTed with token-only (Apple transient failure).
    /// Prevents infinite re-posts when Apple API is persistently unavailable.
    static let asaTokenOnlyAttempts = "appactor_asa_token_only_attempts"

    /// Set when logOut() identify fails. Cleared on next successful identify.
    static let needsReidentify = "appactor_needs_reidentify"
}

// MARK: - UserDefaults Implementation

/// Default `PaymentStorage` backed by `UserDefaults`.
final class AppActorUserDefaultsPaymentStorage: AppActorPaymentStorage, @unchecked Sendable {

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Convenience Helpers

extension AppActorPaymentStorage {

    /// Returns the stored `app_user_id`, or `nil` if none exists.
    var currentAppUserId: String? {
        string(forKey: AppActorPaymentStorageKey.appUserId)
    }

    /// Returns the stored server user UUID, if any.
    var serverUserId: String? {
        string(forKey: AppActorPaymentStorageKey.serverUserId)
    }

    /// Returns the last `request_id` received from the server.
    var lastRequestId: String? {
        get { string(forKey: AppActorPaymentStorageKey.lastRequestId) }
    }

    /// Generates and stores a new anonymous `app_user_id`.
    @discardableResult
    func generateAnonymousAppUserId() -> String {
        let id = "appactor-anon-" + UUID().uuidString.lowercased()
        set(id, forKey: AppActorPaymentStorageKey.appUserId)
        return id
    }

    /// Ensures an `app_user_id` exists, generating an anonymous one if needed.
    @discardableResult
    func ensureAppUserId() -> String {
        if let existing = currentAppUserId {
            return existing
        }
        return generateAnonymousAppUserId()
    }

    /// Overwrites the stored `app_user_id`.
    func setAppUserId(_ id: String) {
        set(id, forKey: AppActorPaymentStorageKey.appUserId)
    }

    /// Stores the server-assigned user UUID.
    func setServerUserId(_ id: String?) {
        set(id, forKey: AppActorPaymentStorageKey.serverUserId)
    }

    /// Stores the last request_id.
    func setLastRequestId(_ id: String?) {
        set(id, forKey: AppActorPaymentStorageKey.lastRequestId)
    }

    /// Clears all payment identity data.
    /// Note: customer/offerings cache is managed by `AppActorETagManager`, not here.
    func clearAll() {
        remove(forKey: AppActorPaymentStorageKey.appUserId)
        remove(forKey: AppActorPaymentStorageKey.serverUserId)
        remove(forKey: AppActorPaymentStorageKey.appAccountToken)
        // Note: lastRequestId is kept for debugging.
    }

    // MARK: - App Account Token

    /// Returns the stored `appAccountToken` UUID, or `nil` if none exists.
    var appAccountToken: UUID? {
        guard let raw = string(forKey: AppActorPaymentStorageKey.appAccountToken) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Stores an `appAccountToken` UUID.
    func setAppAccountToken(_ token: UUID) {
        set(token.uuidString.lowercased(), forKey: AppActorPaymentStorageKey.appAccountToken)
    }

    /// Clears the stored `appAccountToken`.
    func clearAppAccountToken() {
        remove(forKey: AppActorPaymentStorageKey.appAccountToken)
    }

    /// Ensures an `appAccountToken` exists, generating one if needed.
    @discardableResult
    func ensureAppAccountToken() -> UUID {
        if let existing = appAccountToken {
            return existing
        }
        let token = UUID()
        setAppAccountToken(token)
        Log.identity.debug("Generated new appAccountToken: \(String(token.uuidString.lowercased().prefix(8)))…")
        return token
    }

    // MARK: - ASA Helpers

    /// Whether ASA attribution has been completed for this install.
    var asaAttributionCompleted: Bool {
        string(forKey: AppActorPaymentStorageKey.asaAttributionCompleted) == "true"
    }

    func setAsaAttributionCompleted(_ completed: Bool) {
        set(completed ? "true" : nil, forKey: AppActorPaymentStorageKey.asaAttributionCompleted)
    }

    /// Returns the stored install date as ISO 8601 with internet date-time format,
    /// generating and persisting one if missing.
    /// Note: Called from ASAManager actor, so actor isolation prevents races.
    /// The formatter uses `.withInternetDateTime` for a stable format contract.
    var asaInstallDate: String {
        if let existing = string(forKey: AppActorPaymentStorageKey.asaInstallDate) {
            return existing
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.string(from: Date())
        set(date, forKey: AppActorPaymentStorageKey.asaInstallDate)
        return date
    }

    /// [L7] Pending ASA user ID change (old → new), stored as a single atomic JSON value.
    var asaPendingUserIdChange: (oldUserId: String, newUserId: String)? {
        if let json = string(forKey: AppActorPaymentStorageKey.asaPendingUserIdChange) {
            if let data = json.data(using: .utf8),
               let dto = try? JSONDecoder().decode(AsaPendingUserIdChangeDTO.self, from: data) {
                return (dto.oldUserId, dto.newUserId)
            }
            // [N4] Corrupt JSON — clear it, then fall through to try legacy keys
            Log.attribution.warn("Corrupt pending user ID change JSON, clearing.")
            remove(forKey: AppActorPaymentStorageKey.asaPendingUserIdChange)
        }
        return nil
    }

    func setAsaPendingUserIdChange(oldUserId: String, newUserId: String) {
        let dto = AsaPendingUserIdChangeDTO(oldUserId: oldUserId, newUserId: newUserId)
        guard let data = try? JSONEncoder().encode(dto),
              let json = String(data: data, encoding: .utf8) else { return }
        set(json, forKey: AppActorPaymentStorageKey.asaPendingUserIdChange)
    }

    func clearAsaPendingUserIdChange() {
        remove(forKey: AppActorPaymentStorageKey.asaPendingUserIdChange)
    }

    // MARK: - ASA Sent Transaction Tracking

    /// Returns the set of originalTransactionIds already sent to the ASA backend.
    func asaSentOriginalTransactionIds() -> Set<String> {
        guard let raw = string(forKey: AppActorPaymentStorageKey.asaSentOriginalTransactionIds),
              !raw.isEmpty else { return [] }

        // JSON array format (starts with "[")
        if raw.hasPrefix("["),
           let data = raw.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return Set(array)
        }

        // Legacy comma-separated migration or corrupt JSON — filter empty tokens.
        // Will be rewritten as JSON on next markAsaSentOriginalTransactionId() call.
        let ids = raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(ids)
    }

    /// Records an originalTransactionId as sent. Future enqueues with this ID will be skipped.
    func markAsaSentOriginalTransactionId(_ id: String) {
        guard !id.isEmpty else { return }
        var ids = asaSentOriginalTransactionIds()
        ids.insert(id)
        if let data = try? JSONEncoder().encode(Array(ids)),
           let json = String(data: data, encoding: .utf8) {
            set(json, forKey: AppActorPaymentStorageKey.asaSentOriginalTransactionIds)
        }
    }

    /// Checks if an originalTransactionId has already been sent.
    func isAsaOriginalTransactionIdSent(_ id: String) -> Bool {
        asaSentOriginalTransactionIds().contains(id)
    }

    /// Clears all sent originalTransactionIds (used by reset()).
    func clearAsaSentOriginalTransactionIds() {
        remove(forKey: AppActorPaymentStorageKey.asaSentOriginalTransactionIds)
    }

    // MARK: - ASA Token-Only Attempt Tracking

    /// Number of times attribution was sent with token-only (Apple API transient failure).
    var asaTokenOnlyAttempts: Int {
        guard let raw = string(forKey: AppActorPaymentStorageKey.asaTokenOnlyAttempts),
              let value = Int(raw) else { return 0 }
        return value
    }

    func incrementAsaTokenOnlyAttempts() {
        let current = asaTokenOnlyAttempts
        set(String(current + 1), forKey: AppActorPaymentStorageKey.asaTokenOnlyAttempts)
    }

    func clearAsaTokenOnlyAttempts() {
        remove(forKey: AppActorPaymentStorageKey.asaTokenOnlyAttempts)
    }

    // MARK: - Re-identify Flag

    var needsReidentify: Bool {
        string(forKey: AppActorPaymentStorageKey.needsReidentify) == "1"
    }

    func setNeedsReidentify(_ value: Bool) {
        set(value ? "1" : nil, forKey: AppActorPaymentStorageKey.needsReidentify)
    }
}

// MARK: - Atomic Storage DTOs

/// [L7] DTO for atomic pending user ID storage (single key write/read).
private struct AsaPendingUserIdChangeDTO: Codable {
    let oldUserId: String
    let newUserId: String
}
