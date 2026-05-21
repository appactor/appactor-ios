import Foundation
import Security

/// Lightweight Keychain helper for ASA install-state flags.
///
/// Stores two boolean flags in the Keychain:
/// - `firstInstallOnDevice` — local-only, persists across uninstall/reinstall on the same device.
/// - `firstInstallOnAccount` — synced via iCloud Keychain, persists across devices on the same Apple account.
///
/// On first launch (no Keychain entry), both return `true`.
/// After successful attribution, both are set to `false` — so reinstalls and new devices
/// see `false`, matching Apple Search Ads attribution semantics (re-download vs. download).
///
/// Conforms to `Sendable` — all methods are stateless, operating directly on the system Keychain.
enum AppActorASAKeychainHelper: Sendable {

    // MARK: - Keys

    private static let servicePrefix = "com.appactor.asa."

    /// Persists on device only (not synced to iCloud).
    /// `true` on first ever install on this device, `false` after attribution completes.
    private static let firstInstallOnDeviceKey = "first_install_on_device"

    /// Synced via iCloud Keychain across devices on the same Apple account.
    /// `true` on first ever install on this account, `false` after attribution completes.
    private static let firstInstallOnAccountKey = "first_install_on_account"

    // MARK: - Public API

    /// Whether this is the first install on this physical device.
    /// Returns `true` if no Keychain entry exists (first launch after fresh install).
    static var firstInstallOnDevice: Bool {
        get { boolValue(forKey: firstInstallOnDeviceKey, syncable: false) ?? true }
        set { storeBool(newValue, forKey: firstInstallOnDeviceKey, syncable: false) }
    }

    /// Whether this is the first install on this Apple account (iCloud Keychain synced).
    /// Returns `true` if no Keychain entry exists.
    static var firstInstallOnAccount: Bool {
        get { boolValue(forKey: firstInstallOnAccountKey, syncable: true) ?? true }
        set { storeBool(newValue, forKey: firstInstallOnAccountKey, syncable: true) }
    }

    /// Marks both flags as `false` after successful attribution.
    /// Called once after the first attribution completes (attributed or organic).
    static func markAttributionCompleted() {
        firstInstallOnDevice = false
        firstInstallOnAccount = false
    }

    // MARK: - Keychain Operations

    private static func storeBool(_ value: Bool, forKey key: String, syncable: Bool) {
        let data = Data((value ? "true" : "false").utf8)
        var query = baseQuery(forKey: key, syncable: syncable)

        // Add-first pattern: avoids check-then-act race condition.
        // If item already exists, SecItemAdd returns errSecDuplicateItem → update.
        query[kSecValueData as String] = data as AnyObject
        // Set accessibility only on add (not in base query, which is also used for reads/updates).
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock as AnyObject
        let addStatus = SecItemAdd(query as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return // Added successfully
        } else if addStatus == errSecDuplicateItem {
            // Item exists — update it. Remove add-only attributes from query.
            query.removeValue(forKey: kSecValueData as String)
            query.removeValue(forKey: kSecAttrAccessible as String)
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                Log.attribution.warn("Keychain update failed for \(key): \(updateStatus)")
            }
        } else {
            Log.attribution.warn("Keychain add failed for \(key): \(addStatus)")
        }
    }

    private static func boolValue(forKey key: String, syncable: Bool) -> Bool? {
        var query = baseQuery(forKey: key, syncable: syncable)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        switch string {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func baseQuery(forKey key: String, syncable: Bool) -> [String: AnyObject] {
        let service = servicePrefix + (Bundle.main.bundleIdentifier ?? "unknown")
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: key as AnyObject,
        ]

        if syncable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        return query
    }
}
