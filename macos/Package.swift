// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpaceTimeContinuumMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(
            name: "SpaceTimeContinuum",
            dependencies: [.product(name: "STCCore", package: "core")],
            path: "Sources/SpaceTimeContinuum",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
