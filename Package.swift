// swift-tools-version: 5.9
// VOICE — Local-first meeting transcription for macOS
// ============================================================
// NOTES FOR TWEAKING:
// - Minimum macOS version: change .macOS(.v14) below
// - To swap WhisperKit for FluidAudio: replace the dependency URL
// - GRDB handles all local storage ��� swap for SwiftData if targeting macOS 14+ only
// ============================================================

import PackageDescription

let package = Package(
    name: "Voice",
    platforms: [
        // TWEAK: Minimum macOS version. v14 needed for Core Audio Process Tap.
        // Drop to v13 if you only need mic capture (no system audio).
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Voice", targets: ["Voice"])
    ],
    dependencies: [
        // TWEAK: Transcription engine — FluidAudio (Parakeet TDT 0.6B v3 on ANE).
        // Streaming via SlidingWindowAsrManager; ~150ms first-token latency.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),

        // TWEAK: Local database — GRDB for SQLite + FTS5 full-text search
        // Alternative: SwiftData (macOS 14+ only, less control over FTS)
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),

        // TWEAK: Keychain storage for API keys (Claude Haiku key, etc.)
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),

        // TWEAK: On-device LLM runtime for the polish pass.
        // MLX-Swift runs Metal-accelerated inference inline in our process
        // (no Ollama server, no subprocess). MLXLLM bundles a Qwen3 model
        // factory so we can load `mlx-community/Qwen3-0.6B-4bit` directly
        // from Hugging Face on first use.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.29.1"),
    ],
    targets: [
        .executableTarget(
            name: "Voice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "KeychainAccess",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: "Sources/Voice"
        ),
        .testTarget(
            name: "VoiceTests",
            dependencies: ["Voice"],
            path: "Tests/VoiceTests"
        ),
    ]
)
