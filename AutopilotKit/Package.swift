// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutopilotKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AutopilotCore", targets: ["AutopilotCore"]),
        .library(name: "AutopilotLLM", targets: ["AutopilotLLM"]),
        .library(name: "AutopilotAgent", targets: ["AutopilotAgent"]),
        .library(name: "AutopilotPerception", targets: ["AutopilotPerception"]),
        .library(name: "AutopilotAction", targets: ["AutopilotAction"]),
        .library(name: "AutopilotMac", targets: ["AutopilotMac"]),
        .library(name: "AutopilotUI", targets: ["AutopilotUI"])
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
        .target(
            name: "AutopilotPerception",
            dependencies: ["AutopilotCore"]
        ),
        .target(
            name: "AutopilotAction",
            dependencies: ["AutopilotCore"]
        ),
        .target(
            name: "AutopilotMac",
            dependencies: [
                "AutopilotCore",
                "AutopilotAgent",
                "AutopilotPerception",
                "AutopilotAction"
            ]
        ),
        .target(
            name: "AutopilotUI",
            dependencies: [
                "AutopilotCore",
                "AutopilotLLM",
                "AutopilotAgent",
                "AutopilotMac"
            ]
        ),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: ["AutopilotCore"]
        ),
        .testTarget(
            name: "AutopilotLLMTests",
            dependencies: ["AutopilotLLM", "AutopilotCore"]
        ),
        .testTarget(
            name: "AutopilotAgentTests",
            dependencies: ["AutopilotAgent", "AutopilotCore", "AutopilotLLM"]
        )
    ]
)
