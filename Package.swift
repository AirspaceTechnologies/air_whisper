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
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(name: "AirWhisperLLM", dependencies: ["AirWhisperCore", "llama"]),
        .executableTarget(
            name: "AirWhisper",
            dependencies: ["AirWhisperCore", "AirWhisperAudio", "AirWhisperSpeech", "AirWhisperLLM"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "AirWhisperCoreTests", dependencies: ["AirWhisperCore"]),
        .testTarget(name: "AirWhisperAudioTests", dependencies: ["AirWhisperAudio", "AirWhisperCore"]),
        .testTarget(name: "AirWhisperSpeechTests", dependencies: ["AirWhisperSpeech", "AirWhisperCore"]),
        .testTarget(name: "AirWhisperLLMTests", dependencies: ["AirWhisperLLM", "AirWhisperCore"]),
        .testTarget(name: "AirWhisperTests", dependencies: ["AirWhisper"]),
    ],
    swiftLanguageVersions: [.v5]
)
