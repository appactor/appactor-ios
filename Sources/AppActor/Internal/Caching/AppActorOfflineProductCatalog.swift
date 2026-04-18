import Foundation

/// Stable offline metadata derived from offerings for entitlement recovery and
/// one-time product classification.
struct AppActorOfflineProductCatalog: Codable, Sendable {
    enum OneTimeProductKind: String, Codable, Sendable {
        case consumable
        case nonConsumable
    }

    let productEntitlements: [String: [String]]
    let oneTimeProductKinds: [String: OneTimeProductKind]

    func oneTimeProductKind(productId: String) -> OneTimeProductKind? {
        oneTimeProductKinds[Self.oneTimeKey(productId: productId)]
    }

    static func oneTimeKey(productId: String) -> String {
        "ios:\(productId)"
    }
}

extension AppActorOfferingsResponseDTO {
    func toOfflineProductCatalog() -> AppActorOfflineProductCatalog {
        var oneTimeKinds: [String: AppActorOfflineProductCatalog.OneTimeProductKind] = [:]

        for offering in offerings {
            for package in offering.packages {
                let packageType = AppActorPackageType(serverString: package.packageType)
                for product in package.products where product.store == .appStore {
                    let productId = product.storeProductId ?? product.productId
                    guard product.basePlanId == nil, product.offerId == nil else { continue }

                    let kind: AppActorOfflineProductCatalog.OneTimeProductKind?
                    switch packageType {
                    case .lifetime:
                        kind = .nonConsumable
                    default:
                        switch product.productType.lowercased() {
                        case "consumable":
                            kind = .consumable
                        case "non_consumable", "nonconsumable", "non-consumable":
                            kind = .nonConsumable
                        default:
                            kind = nil
                        }
                    }

                    if let kind {
                        oneTimeKinds[AppActorOfflineProductCatalog.oneTimeKey(productId: productId)] = kind
                    }
                }
            }
        }

        return AppActorOfflineProductCatalog(
            productEntitlements: productEntitlements ?? [:],
            oneTimeProductKinds: oneTimeKinds
        )
    }
}
