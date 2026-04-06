import Foundation
import AppActor

struct GetExperimentAssignmentRequest: AppActorPluginRequest {
    static let method = "get_experiment_assignment"

    let experimentKey: String

    @MainActor
    func execute() async throws -> AppActorPluginResult {
        let assignment = try await AppActor.shared.getExperimentAssignment(experimentKey: experimentKey)
        if let assignment {
            return .encoding(PluginExperimentAssignment(from: assignment))
        } else {
            return .success(AppActorPluginResult.nullData)
        }
    }
}
