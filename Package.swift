// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PiAI",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PiAI", targets: ["PiAI"]),
        .executable(name: "PiAIExamples", targets: ["PiAIExamples"])
    ],
    targets: [
        .target(name: "PiAI", path: "Sources/PiAI"),
        .executableTarget(
            name: "PiAIExamples",
            dependencies: ["PiAI"],
            path: "Examples/PiAIExamples"
        ),
        .testTarget(name: "PiAITests", dependencies: ["PiAI"], path: "Tests/PiAITests")
    ]
)
