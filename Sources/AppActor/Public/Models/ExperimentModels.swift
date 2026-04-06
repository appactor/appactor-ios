import Foundation

// MARK: - Public Experiment Models

/// The result of an A/B test assignment.
///
/// Contains the experiment and variant details, including the typed payload
/// that can be used to drive UI or feature variations.
///
/// Use ``AppActor/getExperimentAssignment(experimentKey:)`` to fetch an assignment.
/// Returns `nil` if the user is not in the experiment.
public struct AppActorExperimentAssignment: Sendable {
    /// The unique identifier of the experiment.
    public let experimentId: String
    /// The developer-defined key for the experiment (e.g. "onboarding_v2").
    public let experimentKey: String
    /// The unique identifier of the assigned variant.
    public let variantId: String
    /// The developer-defined key for the variant (e.g. "new_flow").
    public let variantKey: String
    /// The variant's typed payload value.
    public let payload: AppActorConfigValue
    /// The declared value type of the payload.
    public let valueType: AppActorConfigValueType
    /// ISO 8601 timestamp of when the assignment was created.
    public let assignedAt: String
}
