// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZCBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZCBar", targets: ["ZCBar"])],
    targets: [
        // Everything that does not draw: the CLI's JSON, running it, and what
        // needs attention. The tests cover this part.
        .target(name: "ZCBarCore"),
        .executableTarget(name: "ZCBar", dependencies: ["ZCBarCore"]),
        .testTarget(name: "ZCBarCoreTests", dependencies: ["ZCBarCore"]),
    ]
)
