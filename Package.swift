// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "InterviewArcLive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InterviewArcLiveCore", targets: ["InterviewArcLiveCore"]),
        .executable(name: "InterviewArcLive", targets: ["InterviewArcLive"]),
    ],
    targets: [
        .target(name: "InterviewArcLiveCore"),
        .executableTarget(
            name: "InterviewArcLive",
            dependencies: ["InterviewArcLiveCore"]
        ),
        .testTarget(
            name: "InterviewArcLiveCoreTests",
            dependencies: ["InterviewArcLiveCore"]
        ),
    ]
)
