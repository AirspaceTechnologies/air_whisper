import AppKit
import SwiftUI
import XCTest
@testable import AirWhisper

@MainActor
final class MicrophoneGraphTests: XCTestCase {
    func testGraphRendersLevelHistory() throws {
        let levels = (0..<100).map { index in
            Float(index < 20 ? 0.03 : abs(sin(Double(index) / 7)) * 0.8 + 0.05)
        }
        let preview = VStack(alignment: .leading, spacing: 14) {
            Text("Display 1 · Microphone test").font(.title.bold())
            Text("Speak near this display and compare the peaks.").foregroundStyle(.secondary)
            MicrophoneLevelGraph(levels: levels).frame(width: 540, height: 180)
            Text("LIVE · last 10 seconds").font(.caption)
        }.padding(24).background(Color(NSColor.windowBackgroundColor))
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(image.width, 1000)
        let representation = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("AirWhisper-microphone-graph-preview.png")
        try png.write(to: path)
        print("Microphone graph preview: \(path.path)")
    }
}
