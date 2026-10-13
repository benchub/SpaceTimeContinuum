// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "STCCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "STCCore", targets: ["STCCore"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(name: "STCCore", dependencies: ["CSQLite"]),
        .testTarget(name: "STCCoreTests", dependencies: ["STCCore"]),
    ]
)
