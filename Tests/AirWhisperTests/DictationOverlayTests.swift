import AppKit
import SwiftUI
import XCTest
@testable import AirWhisper

@MainActor
final class DictationOverlayTests: XCTestCase {
    func testWaveformUsesBoundedLiveLevelsAndStopsWithSession() {
        let model = DictationOverlayModel()
        model.append(level: 1)
        XCTAssertTrue(model.levels.allSatisfy { $0 == 0 })
        model.present(.listening, title: "Listening", detail: "Release Fn to transcribe")
        for _ in 0..<100 { model.append(level: 0.7) }
        XCTAssertEqual(model.levels.count, 36)
        XCTAssertTrue(model.levels.allSatisfy { $0 == 0.7 })
        model.append(level: .nan)
        XCTAssertEqual(model.levels.last, 0)
        model.append(level: 2)
        XCTAssertEqual(model.levels.last, 1)
        model.present(.working, title: "Transcribing…", detail: "Turning your voice into words")
        model.append(level: 1)
        XCTAssertTrue(model.levels.allSatisfy { $0 == 0 })
        XCTAssertNil(model.listeningSince)
        model.clear()
        XCTAssertEqual(model.style, .notice)
    }

    func testRenderOverlayStatesAndAutomaticMicrophoneRows() throws {
        let listening = DictationOverlayModel()
        listening.present(.listening, title: "Listening", detail: "Release Fn / Globe to transcribe")
        for index in 0..<36 {
            listening.append(level: Float(abs(sin(Double(index) * 0.41)) * (index > 8 && index < 30 ? 0.85 : 0.18)))
        }
        let working = DictationOverlayModel()
        working.present(.working, title: "Transcribing…", detail: "Turning your voice into words")
        let recovery = DictationOverlayModel()
        recovery.present(.notice, title: "Your dictation is ready", detail: "The destination changed. Your words are available under Copy Dictation in the menu.", symbol: "doc.on.clipboard", color: .orange)
        let preview = VStack(spacing: 20) {
            Text("Air Whisper · dictation overlays").font(.title2.bold()).foregroundStyle(.white)
            HStack(alignment: .center, spacing: 12) {
                DictationOverlayView(model: listening)
                DictationOverlayView(model: working)
                DictationOverlayView(model: recovery)
            }
            VStack(spacing: 16) {
                Text("Your displays").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                DisplayMicrophoneRow(title: "Display 1 · Studio Display", detail: "Built-in microphone · matched automatically", automatic: true, testEnabled: true, test: {})
                Divider()
                DisplayMicrophoneRow(title: "Display 2 · Studio Display", detail: "Built-in microphone · matched automatically", automatic: true, testEnabled: true, test: {})
            }.padding(20).frame(width: 570).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.padding(32).background(LinearGradient(colors: [Color(red: 0.08, green: 0.15, blue: 0.19), Color(red: 0.14, green: 0.22, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: preview.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AirWhisper-overlay-preview.png")
        try data.write(to: url)
        print("Overlay preview: \(url.path)")
    }
}
