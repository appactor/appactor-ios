import Foundation

/// Protocol for receiving SDK events as JSON strings.
///
/// Flutter/RN plugins implement this to forward events via platform channels.
@objc public protocol AppActorPluginDelegate: AnyObject {
    /// Called when the SDK emits an event.
    /// - Parameters:
    ///   - plugin: The plugin instance.
    ///   - eventName: Event type (e.g. "customer_info_updated", "receipt_pipeline_event").
    ///   - jsonString: The event payload as a JSON string.
    @objc func appActorPlugin(
        _ plugin: AppActorPlugin,
        didReceiveEvent eventName: String,
        withJson jsonString: String
    )
}
