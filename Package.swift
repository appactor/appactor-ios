// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppActor",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AppActor",
            targets: ["AppActor"]
        ),
        .library(
            name: "AppActorPlugin",
            targets: ["AppActorPlugin"]
        )
    ],
    targets: [
        .target(
            name: "AppActor",
            path: "Sources/AppActor",
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy")
            ]
        ),
        .target(
            name: "AppActorPlugin",
            dependencies: ["AppActor"],
            path: "Sources/AppActorPlugin"
        ),
        .testTarget(
            name: "AppActorTests",
            dependencies: ["AppActor"],
            path: "Tests/AppActorTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AppActorPluginTests",
            dependencies: ["AppActorPlugin", "AppActor"],
            path: "Tests/AppActorPluginTests"
        )
    ]
)
