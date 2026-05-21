import Foundation
import AppActor

struct GetASADiagnosticsRequest: AppActorPluginRequest {
    static let method = "get_asa_diagnostics"

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let diagnostics = await AppActor.shared.asaDiagnostics()
        if let diagnostics {
            return .encoding(PluginASADiagnostics(from: diagnostics))
        } else {
            return .success(AppActorPluginResult.nullData)
        }
    }
}
