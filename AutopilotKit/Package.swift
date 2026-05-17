// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAutopilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AutopilotCore", targets: ["AutopilotCore"]),
        .library(name: "AutopilotLLM", targets: ["AutopilotLLM"]),
        .library(name: "AutopilotAgent", targets: ["AutopilotAgent"])
    ],
    targets: [
        .target(name: "AutopilotCore"),
        .target(
            name: "AutopilotLLM",
            dependencies: ["AutopilotCore"]
        ),
        .target(
            name: "AutopilotAgent",
            dependencies: ["AutopilotCore", "AutopilotLLM"]
        ),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: ["AutopilotCore"]
        ),
        .testTarget(
            name: "AutopilotLLMTests",
            dependencies: ["AutopilotLLM"]
        ),
        .testTarget(
            name: "AutopilotAgentTests",
            dependencies: ["AutopilotAgent"]
        )
    ]
)
