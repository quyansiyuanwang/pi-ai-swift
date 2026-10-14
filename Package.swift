// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PiAI",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PiAI", targets: ["PiAI"])
    ],
    targets: [
        .target(name: "PiAI", path: "Sources/PiAI"),
        .testTarget(name: "PiAITests", dependencies: ["PiAI"], path: "Tests/PiAITests")
    ]
)
