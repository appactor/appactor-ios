import Foundation
import AppActor

/// Encodable wrapper for `AppActorRemoteConfigs`.
struct PluginRemoteConfigs: Encodable, Sendable {
    let items: [PluginRemoteConfigItem]

    init(from configs: AppActorRemoteConfigs) {
        self.items = configs.items.map { PluginRemoteConfigItem(from: $0) }
    }
}

/// Encodable wrapper for `AppActorRemoteConfigItem`.
struct PluginRemoteConfigItem: Encodable, Sendable {
    let key: String
    let value: AppActorConfigValue
    let valueType: String

    init(from item: AppActorRemoteConfigItem) {
        self.key = item.key
        self.value = item.value
        self.valueType = item.valueType.rawValue
    }
}
