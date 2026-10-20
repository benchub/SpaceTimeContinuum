// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpaceTimeContinuumMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../core"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpaceTimeContinuum",
            dependencies: [
                .product(name: "STCCore", package: "core"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/SpaceTimeContinuum",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
