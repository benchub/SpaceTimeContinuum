// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpaceTimeContinuumLinux",
    dependencies: [
        .package(path: "../core"),
    ],
    targets: [
        .systemLibrary(
            name: "CGtk",
            path: "Sources/CGtk",
            pkgConfig: "ayatana-appindicator3-0.1",
            providers: [.apt(["libgtk-3-dev", "libayatana-appindicator3-dev"])]
        ),
        .executableTarget(
            name: "stcd",
            dependencies: [
                "CGtk",
                .product(name: "STCCore", package: "core"),
            ],
            path: "Sources/stcd"
        ),
    ]
)
