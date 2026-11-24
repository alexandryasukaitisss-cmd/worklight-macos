// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkLight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkLightCore", targets: ["WorkLightCore"]),
        .executable(name: "WorkLight", targets: ["WorkLight"]),
    ],
    targets: [
        .target(name: "WorkLightCore"),
        .executableTarget(
            name: "WorkLight",
            dependencies: ["WorkLightCore"]
        ),
        .testTarget(
            name: "WorkLightTests",
            dependencies: ["WorkLightCore", "WorkLight"]
        ),
    ]
)
