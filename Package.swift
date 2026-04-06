// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Macbot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // MLX — Apple's machine learning framework for Apple Silicon
        .package(url: "https://github.com/ml-explore/mlx-swift", "0.29.1"..<"0.30.0"),
        // Tokenizers for HuggingFace models
        .package(url: "https://github.com/huggingface/swift-transformers", "1.0.0"..<"1.1.0"),
        // MLX StableDiffusion — on-device image generation
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
    ],
    targets: [
        .executableTarget(
            name: "Macbot",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                // MLX core libraries
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                // HuggingFace tokenizers + hub download
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                // On-device image generation (SDXL-Turbo via MLX)
                .product(name: "StableDiffusion", package: "mlx-swift-examples"),
            ],
            path: "Macbot",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
            ]
        ),
    ]
)
