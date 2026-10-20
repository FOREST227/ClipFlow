// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipFlow",
    platforms: [
        .macOS(.v14)
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
            path: "Sources/ClipFlowApp"
        ),
        .testTarget(
            name: "ClipFlowAppTests",
            dependencies: ["ClipFlowApp"]
        )
    ]
)
