// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutopilotKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AutopilotCore", targets: ["AutopilotCore"]),
        .library(name: "AutopilotMemory", targets: ["AutopilotMemory"]),
        .library(name: "AutopilotLLM", targets: ["AutopilotLLM"]),
        .library(name: "AutopilotAgent", targets: ["AutopilotAgent"]),
        .library(name: "AutopilotPerception", targets: ["AutopilotPerception"]),
        .library(name: "AutopilotAction", targets: ["AutopilotAction"]),
        .library(name: "AutopilotMac", targets: ["AutopilotMac"]),
        .library(name: "AutopilotUI", targets: ["AutopilotUI"]),
        .executable(name: "AutopilotFixtureApp", targets: ["AutopilotFixtureApp"]),
        .executable(name: "AutopilotSmokeCLI", targets: ["AutopilotSmokeCLI"])
    ],
    targets: [
        .target(name: "AutopilotCore"),
        .target(
            name: "AutopilotMemory",
            dependencies: ["AutopilotCore"]
        ),
        .target(
            name: "AutopilotLLM",
            dependencies: ["AutopilotCore"]
        ),
        .target(
            name: "AutopilotAgent",
            dependencies: ["AutopilotCore", "AutopilotLLM", "AutopilotMemory"]
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
                "AutopilotMemory",
                "AutopilotLLM",
                "AutopilotAgent",
                "AutopilotMac"
            ]
        ),
        .executableTarget(
            name: "AutopilotFixtureApp"
        ),
        .executableTarget(
            name: "AutopilotSmokeCLI",
            dependencies: [
                "AutopilotAgent",
                "AutopilotCore",
                "AutopilotMemory",
                "AutopilotLLM",
                "AutopilotMac"
            ]
        ),
        .testTarget(
            name: "AutopilotCoreTests",
            dependencies: ["AutopilotCore"]
        ),
        .testTarget(
            name: "AutopilotMemoryTests",
            dependencies: ["AutopilotMemory"]
        ),
        .testTarget(
            name: "AutopilotLLMTests",
            dependencies: ["AutopilotLLM", "AutopilotCore"]
        ),
        .testTarget(
            name: "AutopilotAgentTests",
            dependencies: ["AutopilotAgent", "AutopilotCore", "AutopilotLLM", "AutopilotMemory"]
        )
    ]
)
