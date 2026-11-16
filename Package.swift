// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Salient",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SalientCore", targets: ["SalientCore"]),
        .library(name: "SalientExperience", targets: ["Salient"]),
        .executable(name: "SalientMini", targets: ["SalientMiniLauncher"]),
        .executable(name: "SalientAudioProbe", targets: ["SalientAudioProbe"]),
        .executable(name: "SalientReadQuestionProbe", targets: ["SalientReadQuestionProbe"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        )
    ],
    targets: [
        .target(
            name: "SalientCore",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift")
            ],
            exclude: [
                "Resources/Voices"
            ],
            resources: [
                .process("Resources/safari_capture.js"),
                .process("Resources/safari_highlight.js"),
                .process("Resources/submit.js"),
                .process("Resources/two-pane.html"),
                .process("Resources/qwen_tts_helper.py"),
                .process("Resources/pocket-assets.json"),
                .process("Resources/Pocket-Notices.md")
            ]
        ),
        .target(
            name: "Salient",
            dependencies: ["SalientCore"]
        ),
        .executableTarget(name: "SalientMiniLauncher", dependencies: ["Salient"]),
        .executableTarget(
            name: "SalientAudioProbe",
            dependencies: ["SalientCore"]
        ),
        .executableTarget(
            name: "SalientReadQuestionProbe",
            dependencies: ["SalientCore"]
        ),
        .testTarget(
            name: "SalientCoreTests",
            dependencies: ["SalientCore", "Salient"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
