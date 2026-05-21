import XCTest
@testable import AppActor

final class OfferingsDTOTests: XCTestCase {

    // MARK: - Full JSON Decode

    func testDecodeFullResponse() throws {
        let json = """
        {
            "currentOffering": {
                "id": "default",
                "lookupKey": "default_offering",
                "displayName": "Default",
                "isCurrent": true,
                "metadata": {"tier": "premium"},
                "packages": [
                    {
                        "packageType": "monthly",
                        "displayName": "Monthly",
                        "position": 0,
                        "isActive": true,
                        "products": [
                            {
                                "storeProductId": "com.app.monthly",
                                "productType": "auto_renewable",
                                "displayName": "Monthly Sub"
                            }
                        ]
                    },
                    {
                        "packageType": "annual",
                        "displayName": "Annual",
                        "position": 1,
                        "isActive": true,
                        "products": [
                            {
                                "storeProductId": "com.app.annual",
                                "productType": "auto_renewable",
                                "displayName": null
                            }
                        ]
                    }
                ]
            },
            "offerings": [
                {
                    "id": "default",
                    "lookupKey": "default_offering",
                    "displayName": "Default",
                    "isCurrent": true,
                    "metadata": {"tier": "premium"},
                    "packages": [
                        {
                            "packageType": "monthly",
                            "displayName": "Monthly",
                            "position": 0,
                            "isActive": true,
                            "products": [
                                {
                                    "storeProductId": "com.app.monthly",
                                    "productType": "auto_renewable",
                                    "displayName": "Monthly Sub"
                                }
                            ]
                        },
                        {
                            "packageType": "annual",
                            "displayName": "Annual",
                            "position": 1,
                            "isActive": true,
                            "products": [
                                {
                                    "storeProductId": "com.app.annual",
                                    "productType": "auto_renewable",
                                    "displayName": null
                                }
                            ]
                        }
                    ]
                },
                {
                    "id": "promo",
                    "lookupKey": "promo_offering",
                    "displayName": "Promo",
                    "isCurrent": false,
                    "metadata": null,
                    "packages": [
                        {
                            "packageType": "lifetime",
                            "displayName": "Lifetime",
                            "position": 0,
                            "isActive": true,
                            "products": [
                                {
                                    "storeProductId": "com.app.lifetime",
                                    "productType": "non_consumable",
                                    "displayName": "Lifetime Access"
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)

        // Current offering
        XCTAssertNotNil(dto.currentOffering)
        XCTAssertEqual(dto.currentOffering?.id, "default")
        XCTAssertEqual(dto.currentOffering?.isCurrent, true)
        XCTAssertEqual(dto.currentOffering?.metadata?["tier"], "premium")

        // Offerings count
        XCTAssertEqual(dto.offerings.count, 2)

        // First offering packages
        let defaultOffering = dto.offerings[0]
        XCTAssertEqual(defaultOffering.packages.count, 2)
        XCTAssertEqual(defaultOffering.packages[0].packageType, "monthly")
        XCTAssertEqual(defaultOffering.packages[0].products[0].storeProductId, "com.app.monthly")
        XCTAssertEqual(defaultOffering.packages[0].products[0].displayName, "Monthly Sub")

        // Null displayName
        XCTAssertNil(defaultOffering.packages[1].products[0].displayName)

        // Second offering
        let promoOffering = dto.offerings[1]
        XCTAssertEqual(promoOffering.id, "promo")
        XCTAssertEqual(promoOffering.lookupKey, "promo_offering")
        XCTAssertFalse(promoOffering.isCurrent)
        XCTAssertNil(promoOffering.metadata)
    }

    // MARK: - Null currentOffering

    func testDecodeNullCurrentOffering() throws {
        let json = """
        {
            "currentOffering": null,
            "offerings": [
                {
                    "id": "default",
                    "lookupKey": "default",
                    "displayName": "Default",
                    "isCurrent": true,
                    "metadata": null,
                    "packages": []
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)
        XCTAssertNil(dto.currentOffering)
        XCTAssertEqual(dto.offerings.count, 1)
    }

    // MARK: - Product ID Extraction

    func testAllStoreProductIds() throws {
        let dto = AppActorOfferingsResponseDTO(
            currentOffering: nil,
            offerings: [
                AppActorOfferingDTO(
                    id: "o1", lookupKey: "o1", displayName: "O1",
                    isCurrent: true, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "monthly", displayName: "Monthly",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.monthly", productType: "auto_renewable", displayName: nil),
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.monthly_promo", productType: "auto_renewable", displayName: nil)
                            ]
                        ),
                        AppActorPackageDTO(
                            id: nil, packageType: "annual", displayName: "Annual",
                            position: 1, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.annual", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                ),
                AppActorOfferingDTO(
                    id: "o2", lookupKey: "o2", displayName: "O2",
                    isCurrent: false, metadata: nil,
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "lifetime", displayName: "Lifetime",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.lifetime", productType: "non_consumable", displayName: nil),
                                // Duplicate: should be deduped in Set
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.monthly", productType: "auto_renewable", displayName: nil)
                            ]
                        )
                    ]
                )
            ]
        )

        let ids = dto.allStoreProductIds
        XCTAssertEqual(ids.count, 4) // monthly, monthly_promo, annual, lifetime (monthly deduped)
        XCTAssertTrue(ids.contains("com.app.monthly"))
        XCTAssertTrue(ids.contains("com.app.monthly_promo"))
        XCTAssertTrue(ids.contains("com.app.annual"))
        XCTAssertTrue(ids.contains("com.app.lifetime"))
    }

    func testEmptyOfferingsProductIds() {
        let dto = AppActorOfferingsResponseDTO(currentOffering: nil, offerings: [])
        XCTAssertTrue(dto.allStoreProductIds.isEmpty)
    }

    // MARK: - Codable Roundtrip

    func testCodableRoundtrip() throws {
        let original = AppActorOfferingsResponseDTO(
            currentOffering: AppActorOfferingDTO(
                id: "main", lookupKey: "main_key", displayName: "Main",
                isCurrent: true, metadata: ["key": "val"],
                packages: [
                    AppActorPackageDTO(
                        id: nil, packageType: "weekly", displayName: "Weekly",
                        position: 0, isActive: true, metadata: nil,
                        products: [
                            AppActorProductRefDTO(id: nil, storeProductId: "com.app.weekly", productType: "auto_renewable", displayName: "Weekly Sub")
                        ]
                    )
                ]
            ),
            offerings: [
                AppActorOfferingDTO(
                    id: "main", lookupKey: "main_key", displayName: "Main",
                    isCurrent: true, metadata: ["key": "val"],
                    packages: [
                        AppActorPackageDTO(
                            id: nil, packageType: "weekly", displayName: "Weekly",
                            position: 0, isActive: true, metadata: nil,
                            products: [
                                AppActorProductRefDTO(id: nil, storeProductId: "com.app.weekly", productType: "auto_renewable", displayName: "Weekly Sub")
                            ]
                        )
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: data)

        XCTAssertEqual(decoded.currentOffering?.id, "main")
        XCTAssertEqual(decoded.offerings.count, 1)
        XCTAssertEqual(decoded.offerings[0].packages[0].products[0].storeProductId, "com.app.weekly")
        XCTAssertEqual(decoded.offerings[0].packages[0].products[0].displayName, "Weekly Sub")
    }

    func testDecodePackageTokenAmount() throws {
        let json = """
        {
            "currentOffering": null,
            "offerings": [
                {
                    "id": "default",
                    "lookupKey": "default",
                    "displayName": "Default",
                    "isCurrent": true,
                    "metadata": null,
                    "packages": [
                        {
                            "id": "pkg_1",
                            "packageType": "monthly",
                            "displayName": "Monthly",
                            "position": 0,
                            "isActive": true,
                            "metadata": {},
                            "tokenAmount": 250,
                            "products": [
                                {
                                    "storeProductId": "com.app.monthly",
                                    "productType": "auto_renewable",
                                    "displayName": "Monthly Sub"
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)
        XCTAssertEqual(dto.offerings[0].packages[0].tokenAmount, 250)
    }

    // MARK: - productEntitlements

    func testDecodeWithProductEntitlements() throws {
        let json = """
        {
            "currentOffering": null,
            "offerings": [],
            "productEntitlements": {
                "com.app.monthly": ["premium"],
                "com.app.annual": ["premium", "vip"]
            }
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)
        XCTAssertNotNil(dto.productEntitlements)
        XCTAssertEqual(dto.productEntitlements?["com.app.monthly"], ["premium"])
        XCTAssertEqual(dto.productEntitlements?["com.app.annual"], ["premium", "vip"])
    }

    func testDecodeWithoutProductEntitlements() throws {
        let json = """
        {
            "currentOffering": null,
            "offerings": []
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)
        XCTAssertNil(dto.productEntitlements)
    }

    // MARK: - Inactive Package Filtering

    func testInactivePackagesInDTO() throws {
        let json = """
        {
            "currentOffering": null,
            "offerings": [
                {
                    "id": "default",
                    "lookupKey": "default",
                    "displayName": "Default",
                    "isCurrent": true,
                    "metadata": null,
                    "packages": [
                        {
                            "packageType": "monthly",
                            "displayName": "Monthly",
                            "position": 0,
                            "isActive": true,
                            "products": [
                                {"storeProductId": "com.app.monthly", "productType": "auto_renewable", "displayName": null}
                            ]
                        },
                        {
                            "packageType": "legacy",
                            "displayName": "Legacy",
                            "position": 1,
                            "isActive": false,
                            "products": [
                                {"storeProductId": "com.app.legacy", "productType": "auto_renewable", "displayName": null}
                            ]
                        }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(AppActorOfferingsResponseDTO.self, from: json)
        let offering = dto.offerings[0]

        // Both packages decoded (filtering happens during enrichment, not decode)
        XCTAssertEqual(offering.packages.count, 2)
        XCTAssertTrue(offering.packages[0].isActive)
        XCTAssertFalse(offering.packages[1].isActive)

        // allStoreProductIds includes all (even inactive) — filtering is at enrichment
        let ids = dto.allStoreProductIds
        XCTAssertEqual(ids.count, 2)
    }
}
