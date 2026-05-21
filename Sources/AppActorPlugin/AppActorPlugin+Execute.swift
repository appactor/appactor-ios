import Foundation

extension AppActorPlugin {

    /// Async entry point. Decodes method + params, executes, returns JSON string.
    @MainActor
    public func execute(method: String, withJson json: String) async -> String {
        let jsonData = Data(json.utf8)
        let result = await AppActorPluginRequestRouter.route(method: method, jsonData: jsonData)
        return result.jsonString
    }

    /// Callback-based entry point for Objective-C platform channels (Flutter/RN).
    @objc public func execute(
        method: String,
        withJsonString json: String,
        completion: @escaping @Sendable (String) -> Void
    ) {
        Task { @MainActor in
            let result = await execute(method: method, withJson: json)
            completion(result)
        }
    }
}
