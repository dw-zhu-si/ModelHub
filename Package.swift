// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ModelHub", targets: ["ModelHub"]),
        .executable(name: "ModelHubWidget", targets: ["ModelHubWidget"]),
        .executable(name: "ModelHubACP", targets: ["ModelHubACP"]),
        .library(name: "ModelHubCore", targets: ["ModelHubCore"]),
        .library(name: "ModelHubMobileAccess", targets: ["ModelHubMobileAccess"])
    ],
    targets: [
        .target(
            name: "ModelHubCore",
            path: "Sources/ModelHubCore"
        ),
        .target(
            name: "ModelHubMobileAccess",
            dependencies: ["ModelHubCore"],
            path: "Sources/ModelHubMobileAccess"
        ),
        .executableTarget(
            name: "ModelHub",
            dependencies: ["ModelHubCore", "ModelHubMobileAccess", "ModelHubWidgetSupport"],
            path: "Sources/ModelHub"
        ),
        .target(
            name: "ModelHubWidgetSupport",
            path: "Sources/ModelHubWidgetSupport"
        ),
        .executableTarget(
            name: "ModelHubWidget",
            dependencies: ["ModelHubWidgetSupport"],
            path: "Sources/ModelHubWidget",
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"],
                    .when(platforms: [.macOS])
                )
            ]
        ),
        .executableTarget(
            name: "ModelHubACP",
            dependencies: ["ModelHubCore"],
            path: "Sources/ModelHubACP"
        ),
        .testTarget(
            name: "ModelHubCoreTests",
            dependencies: ["ModelHubCore"],
            path: "Tests/ModelHubCoreTests"
        ),
        .testTarget(
            name: "ModelHubAppTests",
            dependencies: ["ModelHub"],
            path: "Tests/ModelHubAppTests"
        ),
        .testTarget(
            name: "ModelHubWidgetSupportTests",
            dependencies: ["ModelHubWidgetSupport"],
            path: "Tests/ModelHubWidgetSupportTests"
        ),
        .testTarget(
            name: "ModelHubMobileAccessTests",
            dependencies: ["ModelHubCore", "ModelHubMobileAccess"],
            path: "Tests/ModelHubMobileAccessTests"
        )
    ]
)
