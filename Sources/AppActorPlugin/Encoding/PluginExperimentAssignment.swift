import Foundation
import AppActor

/// Encodable wrapper for `AppActorExperimentAssignment`.
struct PluginExperimentAssignment: Encodable, Sendable {
    let experimentId: String
    let experimentKey: String
    let variantId: String
    let variantKey: String
    let payload: AppActorConfigValue
    let valueType: String
    let assignedAt: String

    init(from assignment: AppActorExperimentAssignment) {
        self.experimentId = assignment.experimentId
        self.experimentKey = assignment.experimentKey
        self.variantId = assignment.variantId
        self.variantKey = assignment.variantKey
        self.payload = assignment.payload
        self.valueType = assignment.valueType.rawValue
        self.assignedAt = assignment.assignedAt
    }
}
