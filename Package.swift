// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SophaxChat",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SophaxChatCore", targets: ["SophaxChatCore"]),
    ],
    targets: [
        .target(
            name: "SophaxChatCore",
            dependencies: [],
            path: "Sources/SophaxChatCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SophaxChatCoreTests",
            dependencies: ["SophaxChatCore"],
            path: "Tests/SophaxChatCoreTests"
        )
    ]
)
