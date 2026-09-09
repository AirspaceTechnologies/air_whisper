// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirWhisper",
    platforms: [.macOS("13.3")],
    products: [.executable(name: "AirWhisper", targets: ["AirWhisper"])],
    targets: [
        .target(name: "AirWhisperCore"),
        .target(name: "AirWhisperAudio", dependencies: ["AirWhisperCore"]),
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(name: "AirWhisperSpeech", dependencies: ["AirWhisperCore", "whisper"]),
        .executableTarget(
            name: "AirWhisper",
            dependencies: ["AirWhisperCore", "AirWhisperAudio", "AirWhisperSpeech"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "AirWhisperCoreTests", dependencies: ["AirWhisperCore"]),
        .testTarget(name: "AirWhisperAudioTests", dependencies: ["AirWhisperAudio", "AirWhisperCore"]),
        .testTarget(name: "AirWhisperSpeechTests", dependencies: ["AirWhisperSpeech", "AirWhisperCore"]),
        .testTarget(name: "AirWhisperTests", dependencies: ["AirWhisper"]),
    ],
    swiftLanguageVersions: [.v5]
)
