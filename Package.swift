// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "recall",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "recall", targets: ["recall"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.15.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "a3e1bf49f6f44d0e9cba29f1c4a61576f646a1b4"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.1"),
        .package(url: "https://github.com/alexeichhorn/YouTubeKit", revision: "4140995e3485cd691fadb67b2820dbab2d3d84e9"),
    ],
    targets: [
        .executableTarget(
            name: "recall",
            dependencies: [
                "WhisperKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                "FluidAudio",
                "YouTubeKit",
            ],
            path: "recall",
            exclude: [
                "Info.plist",
                "AppIcon.icns",
                "SummarizeContent.entitlements",
            ],
            resources: [
                .process("Assets.xcassets"),
            ]
        )
    ],
    swiftLanguageModes: [
        .v5
    ]
)
