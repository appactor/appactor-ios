import Foundation

// MARK: - Experiment Assignment API Response DTO

/// Server response from `POST /v1/experiments/:experimentKey/assignments`.
/// Decoded from the `data` envelope.
struct AppActorExperimentAssignmentDTO: Codable, Sendable {
    let inExperiment: Bool
    let reason: String?           // "not_targeted", "user_not_found"
    let experiment: ExperimentRef?
    let variant: VariantRef?
    let assignedAt: String?       // ISO 8601

    struct ExperimentRef: Codable, Sendable {
        let id: String
        let key: String
    }

    struct VariantRef: Codable, Sendable {
        let id: String
        let key: String
        let valueType: String     // "string", "boolean", "number", "json"
        let payload: AppActorConfigValue
    }
}

// MARK: - Fetch Result

/// Result type for experiment assignment POST.
/// POST requests have no ETag/304 — always returns fresh data.
enum AppActorExperimentFetchResult: Sendable {
    case success(AppActorExperimentAssignmentDTO, requestId: String?, signatureVerified: Bool)
}
