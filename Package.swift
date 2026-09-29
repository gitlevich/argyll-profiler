// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ArgyllKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ArgyllKit", targets: ["ArgyllKit"]),
        .executable(name: "argyllkit-cli", targets: ["argyllkit-cli"]),
        .executable(name: "ArgyllApp", targets: ["ArgyllApp"]),
    ],
    targets: [
        .target(name: "ArgyllKit"),
        .executableTarget(name: "argyllkit-cli", dependencies: ["ArgyllKit"]),
        .executableTarget(name: "ArgyllApp", dependencies: ["ArgyllKit"]),
        .testTarget(name: "ArgyllKitTests", dependencies: ["ArgyllKit"]),
        .testTarget(name: "ArgyllAppTests", dependencies: ["ArgyllApp", "ArgyllKit"]),
    ]
)
