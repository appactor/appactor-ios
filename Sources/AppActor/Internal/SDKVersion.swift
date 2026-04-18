/// Single source of truth for the AppActor SDK version.
///
/// Keep this in sync with package releases.
/// Prefer `scripts/sync_sdk_version.sh` over editing it manually.
enum AppActorSDK {
    static let version = "0.0.6"
}

// MARK: - Public SDK Version Access

public extension AppActor {
    /// The current version of the AppActor SDK.
    nonisolated static var sdkVersion: String { AppActorSDK.version }
}
