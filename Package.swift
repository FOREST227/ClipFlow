// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "ClipFlowApp",
            targets: ["ClipFlowApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ClipFlowApp",
            path: "Sources/ClipFlowApp",
            resources: [.copy("Renderer")]
        ),
        .testTarget(
            name: "ClipFlowAppTests",
            dependencies: ["ClipFlowApp"]
        )
    ]
)
