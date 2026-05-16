import Foundation

struct AppActorSetAttributesRequest: Encodable, Sendable, Equatable {
    let attributes: [String: AppActorAttributeValue]
}

struct AppActorSetIntegrationIdentifiersRequest: Encodable, Sendable, Equatable {
    let integrationIdentifiers: [String: String]
}

struct AppActorUpdateAttributionRequest: Encodable, Sendable, Equatable {
    let attribution: AppActorAttribution
}

struct AppActorMutationResult: Sendable, Equatable {
    let requestId: String?
}
