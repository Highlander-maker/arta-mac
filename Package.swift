// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "arta-mac-spike",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "arta-mac-spike",
            swiftSettings: [
                // Phase 0 spike: keep Swift 5 semantics to avoid strict-concurrency
                // friction with the Core Audio / AVAudioEngine callback APIs.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        )
    ]
)
