// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpaceTimeContinuumLinux",
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .executableTarget(
            name: "stcd",
            dependencies: [
                .product(name: "STCCore", package: "core"),
            ],
            path: "Sources/stcd"
        ),
    ]
)
