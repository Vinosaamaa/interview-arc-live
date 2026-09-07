// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InterviewArcLive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InterviewArcLiveCore", targets: ["InterviewArcLiveCore"]),
        .library(
            name: "InterviewArcLiveHostedClient",
            targets: ["InterviewArcLiveHostedClient"]
        ),
        .executable(name: "InterviewArcLive", targets: ["InterviewArcLive"]),
        .executable(
            name: "InterviewArcLiveCodexSmoke",
            targets: ["InterviewArcLiveCodexSmoke"]
        ),
        .executable(
            name: "InterviewArcLiveEndpointSmoke",
            targets: ["InterviewArcLiveEndpointSmoke"]
        ),
        .executable(
            name: "InterviewArcLiveSpeechSmoke",
            targets: ["InterviewArcLiveSpeechSmoke"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Vinosaamaa/interview-arc-voice.git",
            revision: "e68767d92431c1b909fc4c8771d79b0b0d3b1ea9"
        ),
        .package(
            url: "https://github.com/Vinosaamaa/mlx-audio-swift.git",
            revision: "a228dc056c6b298a2f5aff7f10e3aed537577fa0"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.8.1"
        ),
    ],
    targets: [
        .target(
            name: "InterviewArcLiveCore",
            swiftSettings: [.define("INTERVIEW_ARC_LIVE_DIAGNOSTIC_STATE_ROOT", .when(configuration: .debug))]
        ),
        .target(
            name: "InterviewArcLiveHostedClient",
            dependencies: ["InterviewArcLiveCore"]
        ),
        .target(
            name: "InterviewArcLiveVoiceAdapter",
            dependencies: [
                "InterviewArcLiveCore",
                .product(
                    name: "InterviewArcVoiceCore",
                    package: "interview-arc-voice"
                ),
            ]
        ),
        .target(
            name: "InterviewArcLiveCodexAdapter",
            dependencies: ["InterviewArcLiveCore"]
        ),
        .target(
            name: "InterviewArcLiveLocalSpeechAdapter",
            dependencies: [
                "InterviewArcLiveCore",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
            ],
            resources: [.copy("Resources")]
        ),
        .target(
            name: "InterviewArcLiveSpeechOutputAdapter",
            dependencies: ["InterviewArcLiveCore"]
        ),
        .executableTarget(
            name: "InterviewArcLive",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveHostedClient",
                "InterviewArcLiveCodexAdapter",
                "InterviewArcLiveLocalSpeechAdapter",
                "InterviewArcLiveSpeechOutputAdapter",
                "InterviewArcLiveVoiceAdapter",
            ],
            resources: [.copy("Resources/BoardEditor")],
            swiftSettings: [.define("INTERVIEW_ARC_LIVE_DIAGNOSTIC_STATE_ROOT", .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "InterviewArcLiveCodexSmoke",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveCodexAdapter",
            ]
        ),
        .executableTarget(
            name: "InterviewArcLiveEndpointSmoke",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveVoiceAdapter",
            ]
        ),
        .executableTarget(
            name: "InterviewArcLiveSpeechSmoke",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveLocalSpeechAdapter",
                "InterviewArcLiveSpeechOutputAdapter",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveCoreTests",
            dependencies: ["InterviewArcLiveCore"]
        ),
        .testTarget(
            name: "InterviewArcLiveHostedClientTests",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveHostedClient",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveVoiceAdapterTests",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveVoiceAdapter",
                .product(
                    name: "InterviewArcVoiceCore",
                    package: "interview-arc-voice"
                ),
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveCodexAdapterTests",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveCodexAdapter",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveLocalSpeechAdapterTests",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveLocalSpeechAdapter",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveSpeechOutputAdapterTests",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveSpeechOutputAdapter",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveTests",
            dependencies: [
                "InterviewArcLive",
                "InterviewArcLiveCore",
                "InterviewArcLiveCodexAdapter",
                "InterviewArcLiveLocalSpeechAdapter",
                "InterviewArcLiveSpeechOutputAdapter",
            ]
        ),
    ]
)
