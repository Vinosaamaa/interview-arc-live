// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "InterviewArcLive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InterviewArcLiveCore", targets: ["InterviewArcLiveCore"]),
        .executable(name: "InterviewArcLive", targets: ["InterviewArcLive"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Vinosaamaa/interview-arc-voice.git",
            revision: "e68767d92431c1b909fc4c8771d79b0b0d3b1ea9"
        ),
    ],
    targets: [
        .target(name: "InterviewArcLiveCore"),
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
        .executableTarget(
            name: "InterviewArcLive",
            dependencies: [
                "InterviewArcLiveCore",
                "InterviewArcLiveVoiceAdapter",
            ]
        ),
        .testTarget(
            name: "InterviewArcLiveCoreTests",
            dependencies: ["InterviewArcLiveCore"]
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
    ]
)
