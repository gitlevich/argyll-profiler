// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArgyllKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArgyllKit", targets: ["ArgyllKit"]),
        .executable(name: "argyllkit-cli", targets: ["argyllkit-cli"]),
    ],
    targets: [
        .target(name: "ArgyllKit"),
        .executableTarget(name: "argyllkit-cli", dependencies: ["ArgyllKit"]),
        .testTarget(name: "ArgyllKitTests", dependencies: ["ArgyllKit"]),
    ]
)
