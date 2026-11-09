// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperCpp",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhisperCpp", targets: ["WhisperFramework"])],
    targets: [
        .binaryTarget(
            name: "WhisperFramework",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        )
    ]
)
