import Foundation

// MARK: - Public Experiment Models

/// The result of an A/B test assignment.
///
/// Contains the experiment and variant details, including the typed payload
/// that can be used to drive UI or feature variations.
///
/// Use ``AppActor/getExperimentAssignment(experimentKey:)`` to fetch an assignment.
/// Returns `nil` if the user is not in the experiment. Prefer ``AppActor/experiment(_:)``,
/// which wraps this in an ``AppActorExperiment`` that is never `nil`.
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

/// A user's standing in one experiment — always returned, also when the user is not in it,
/// so callers never unwrap. Use ``AppActor/experiment(_:)`` to get one (examples there).
public struct AppActorExperiment: Sendable {
    /// The developer-defined experiment key this was resolved for.
    public let experimentKey: String
    /// The raw assignment; `nil` when the user is not in the experiment (not targeted, not running, …).
    public let assignment: AppActorExperimentAssignment?

    public init(experimentKey: String, assignment: AppActorExperimentAssignment?) {
        self.experimentKey = experimentKey
        self.assignment = assignment
    }

    /// `true` when the user has a variant in this experiment.
    public var isEnrolled: Bool { assignment != nil }
    /// The assigned variant's key (e.g. `"control"`), or `nil` when not enrolled.
    public var variantKey: String? { assignment?.variantKey }
    /// The variant's payload; `.null` when not enrolled.
    public var payload: AppActorConfigValue { assignment?.payload ?? .null }

    /// `true` when the user is enrolled in the variant with this key.
    public func isVariant(_ variantKey: String) -> Bool { assignment?.variantKey == variantKey }

    /// The payload as a `Bool`, or `defaultValue` when not enrolled or not a boolean.
    public func boolValue(default defaultValue: Bool) -> Bool { payload.boolValue ?? defaultValue }
    /// The payload as a `String`, or `defaultValue` when not enrolled or not a string.
    public func stringValue(default defaultValue: String) -> String { payload.stringValue ?? defaultValue }
    /// The payload as an `Int`, or `defaultValue` when not enrolled or not a whole number.
    public func intValue(default defaultValue: Int) -> Int { payload.intValue ?? defaultValue }
    /// The payload as a `Double`, or `defaultValue` when not enrolled or not a number.
    public func doubleValue(default defaultValue: Double) -> Double { payload.doubleValue ?? defaultValue }
    /// A key of a JSON payload: `experiment["title"]?.stringValue`.
    public subscript(key: String) -> AppActorConfigValue? { payload[key] }
}
