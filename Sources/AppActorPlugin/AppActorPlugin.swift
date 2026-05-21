import Foundation
import AppActor

/// Cross-platform bridge entry point for Flutter/React Native plugins.
///
/// All communication happens via JSON strings:
/// ```swift
/// let json = await AppActorPlugin.shared.execute(method: "get_customer_info", withJson: "{}")
/// // → {"success": {"app_user_id": "...", "entitlements": {...}}}
/// ```
@objc public final class AppActorPlugin: NSObject {

    @objc public static let shared = AppActorPlugin()

    private override init() {
        super.init()
    }

    /// Delegate that receives SDK events as JSON strings.
    @objc public weak var delegate: AppActorPluginDelegate?

    /// Call after setting `delegate` to wire up SDK event streaming.
    @MainActor
    @objc public func startEventListening() {
        AppActorPluginEventBridge.shared.startListening()
    }

    /// Call to tear down SDK event streaming.
    @MainActor
    @objc public func stopEventListening() {
        AppActorPluginEventBridge.shared.stopListening()
    }
}
