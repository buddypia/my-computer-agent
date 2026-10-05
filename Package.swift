// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyComputerAgent",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "mca", targets: ["mca"]),
        .library(name: "MCAKit", targets: [
            "MCACore", "MCASensing", "MCAPerception",
            "MCAMemory", "MCAReasoning", "MCARealtime",
            "MCAInterop", "MCAPresentation",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        // Layer 0: shared value types. No dependencies, no I/O.
        .target(name: "MCACore"),

        // Layer 1: raw capture. Does not interpret.
        .target(name: "MCASensing", dependencies: ["MCACore"]),

        // Layer 2: raw -> structured observations. Fully on-device.
        .target(name: "MCAPerception", dependencies: ["MCACore", "MCASensing"]),

        // Layer 3: persistence + retrieval.
        .target(name: "MCAMemory", dependencies: ["MCACore"]),

        // Layer 4: provider-agnostic reasoning.
        .target(name: "MCAReasoning", dependencies: ["MCACore", "MCAMemory", "MCASensing", "MCAPerception"]),

        // Layer 4b: realtime voice session (Gemini Live) and cloud transcription.
        .target(name: "MCARealtime", dependencies: ["MCACore", "MCAPerception", "MCAReasoning"]),

        // Layer 5: outward MCP boundary.
        .target(
            name: "MCAInterop",
            dependencies: [
                "MCACore", "MCASensing", "MCAMemory", "MCAReasoning",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // Layer 6: presentation only.
        .target(name: "MCAPresentation", dependencies: ["MCACore"]),

        // Composition root.
        .executableTarget(
            name: "mca",
            dependencies: [
                "MCACore", "MCASensing", "MCAPerception", "MCAMemory",
                "MCAReasoning", "MCARealtime", "MCAInterop", "MCAPresentation",
            ]
        ),

        .testTarget(name: "MCACoreTests", dependencies: ["MCACore"]),
        .testTarget(name: "MCASensingTests", dependencies: ["MCASensing", "MCACore"],
                    resources: [.copy("Fixtures/WindowFocus")]),
        .testTarget(name: "MCAMemoryTests", dependencies: ["MCAMemory", "MCACore"]),
        .testTarget(name: "MCAReasoningTests", dependencies: ["MCAReasoning", "MCACore", "MCAMemory", "MCASensing", "MCAPerception"]),
        .testTarget(name: "MCAPerceptionTests", dependencies: ["MCAPerception", "MCACore"]),
        .testTarget(name: "MCARealtimeTests", dependencies: ["MCARealtime", "MCACore", "MCAPerception"]),
        .testTarget(name: "MCAPresentationTests", dependencies: ["MCAPresentation", "MCACore"]),
        .testTarget(
            name: "MCAInteropTests",
            dependencies: [
                "MCAInterop", "MCACore", "MCAMemory", "MCAReasoning", "MCASensing",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "mcaTests",
            dependencies: [
                "mca", "MCACore", "MCASensing", "MCAReasoning", "MCAPresentation",
            ]
        ),
    ]
)
