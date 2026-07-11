// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "arta-mac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ArtaDSP", targets: ["ArtaDSP"]),
        .executable(name: "arta-mac-spike", targets: ["arta-mac-spike"]),
        .executable(name: "ArtaApp", targets: ["ArtaApp"]),
    ],
    targets: [
        // Measurement mathematics: FFT, sweep generation/deconvolution, H1
        // estimator, smoothing, gating, ETC/step/CSD, room acoustics, STI,
        // band filters and ARTA file formats. Pure — no audio I/O, no UI.
        .target(
            name: "ArtaDSP",
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        .testTarget(
            name: "ArtaDSPTests",
            dependencies: ["ArtaDSP"]
        ),

        // Phase 0 de-risking spike: CLI for device listing, sweep generation,
        // DSP self-test and full-duplex round-trip latency measurement.
        .executableTarget(
            name: "arta-mac-spike",
            swiftSettings: [
                // Keep Swift 5 semantics to avoid strict-concurrency friction
                // with the Core Audio / AVAudioEngine callback APIs.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),

        // The measurement application: SwiftUI shell over ArtaDSP + AVAudioEngine.
        .executableTarget(
            name: "ArtaApp",
            dependencies: ["ArtaDSP"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
