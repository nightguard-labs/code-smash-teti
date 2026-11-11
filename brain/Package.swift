// swift-tools-version:6.0
// Code Smash TeTi ("The Perfect Brain"): 100% Swift + Metal. Designed by the owner (11/05); see ../DESIGN.md.
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
        .executable(name: "brain-server", targets: ["brain-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Shared language every organ and server speaks (messages, events, wire format).
        .target(name: "BrainCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The engine organ: runs the model on the GPU through Apple's MLX.
        .target(name: "BrainEngine", dependencies: [
            "BrainCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The mind: Si working memory, Ni knowledge bank, Te/Ti loop, safety.
        .target(name: "BrainMind", dependencies: ["BrainCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The SSD relay server: many one-way lanes, path of least resistance.
        .executableTarget(name: "brain-relay", dependencies: ["BrainCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // lay: writes the model onto the drive in the brain's own layout (hot file + 16 KB-aligned expert bank).
        .executableTarget(name: "lay", dependencies: ["BrainCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // teti: run the Te⇄Ti thinking loop from the terminal.
        .executableTarget(name: "teti", dependencies: ["BrainCore", "BrainMind"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // front-desk: Apple's on-device model understands the owner and routes to the brain or Apple's tools.
        .executableTarget(name: "front-desk", dependencies: ["BrainCore", "BrainMind"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // brain-sleep: sleep cycle when idle (consolidate, repair, dream, train on rewarded wins).
        .executableTarget(name: "brain-sleep", dependencies: [
            "BrainCore", "BrainMind", "BrainEngine",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        // expert-test: proves streamed experts give the exact same answer as Apple's in-RAM experts.
        .executableTarget(name: "expert-test", dependencies: [
            "BrainCore", "BrainEngine", "BrainMind",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        // prune: cut experts the owner's work never needs (usage evidence + held-out exam).
        .executableTarget(name: "prune", dependencies: [
            "BrainCore", "BrainEngine",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        // The main server: organs as actors + Ollama-compatible edge.
        .executableTarget(name: "brain-server", dependencies: ["BrainCore", "BrainEngine", "BrainMind"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
