import AppKit
import SwiftUI
import AirWhisperAudio

struct MicrophoneLevelGraph: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            for fraction in [0.25, 0.5, 0.75] {
                var line = Path()
                let y = size.height * fraction
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            let width = size.width / 100
            for (index, level) in levels.suffix(100).enumerated() {
                let height = max(2, size.height * CGFloat(level))
                let x = CGFloat(100 - min(100, levels.count) + index) * width
                let bar = Path(roundedRect: CGRect(x: x, y: size.height - height, width: max(1, width - 1), height: height), cornerRadius: 2)
                context.fill(bar, with: .linearGradient(Gradient(colors: [.teal, .blue]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Live microphone volume over the last ten seconds")
        .accessibilityValue("\(Int((levels.last ?? 0) * 100)) percent")
    }
}

private struct MicrophoneIdentificationView: View {
    @ObservedObject var tester: MicrophoneTester
    let displayTitle: String
    let microphoneTitle: String
    let canAssign: Bool
    let canTryNext: Bool
    let next: () -> Void
    let assign: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle).font(.title.bold())
                    Text(canAssign ? "Find the microphone in this display" : "Check how clearly this microphone hears you").foregroundStyle(.secondary)
                }
            }
            Text("Testing: \(microphoneTitle)").font(.headline)
            MicrophoneLevelGraph(levels: tester.levelHistory).frame(height: 150)
            HStack {
                Text("Quiet").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(tester.isRunning ? "LIVE · last 10 seconds" : "Test finished")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(tester.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if canTryNext { Button("Try Next Microphone", action: next).disabled(tester.isStopping) }
                Spacer()
                Button("Close", action: stop)
                if canAssign {
                    Button("Use for This Display", action: assign)
                        .buttonStyle(.borderedProminent).disabled(tester.isStopping || tester.levelHistory.isEmpty)
                }
            }
            Text("Audio from this sound check is never saved or transcribed.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540)
    }
}

@MainActor
final class MicrophoneTestOverlay: NSObject, NSWindowDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 588, height: 460),
                                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    var onClose: (() -> Void)?

    override init() {
        super.init()
        panel.title = "Identify Microphone"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
    }

    func show(tester: MicrophoneTester, screen: NSScreen?, displayTitle: String, microphoneTitle: String,
              canAssign: Bool, canTryNext: Bool, next: @escaping () -> Void, assign: @escaping () -> Void,
              stop: @escaping () -> Void) {
        let host = NSHostingView(rootView: MicrophoneIdentificationView(
            tester: tester, displayTitle: displayTitle, microphoneTitle: microphoneTitle,
            canAssign: canAssign, canTryNext: canTryNext, next: next, assign: assign, stop: stop))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
