import AppKit
import SwiftUI

@MainActor
final class DictationOverlayModel: ObservableObject {
    enum Style { case listening, working, notice }
    @Published private(set) var style: Style = .notice
    @Published private(set) var title = "Air Whisper"
    @Published private(set) var detail = ""
    @Published private(set) var symbol = "waveform"
    @Published private(set) var color: Color = .teal
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 36)
    @Published private(set) var listeningSince: Date?

    func present(_ style: Style, title: String, detail: String, symbol: String = "waveform", color: Color = .teal) {
        self.style = style
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.color = color
        levels = Array(repeating: 0, count: 36)
        listeningSince = style == .listening ? Date() : nil
    }

    func append(level: Float) {
        guard style == .listening else { return }
        let level = level.isFinite ? min(1, max(0, level)) : 0
        levels = Array((levels + [level]).suffix(36))
    }

    func clear() {
        levels = Array(repeating: 0, count: 36)
        listeningSince = nil
        style = .notice
    }
}

struct DictationOverlayView: View {
    @ObservedObject var model: DictationOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: model.style == .listening ? 12 : 6) {
            HStack(spacing: 10) {
                if model.style == .working {
                    OverlayActivityIndicator()
                } else if model.style == .listening {
                    Circle().fill(Color.teal).frame(width: 7, height: 7)
                } else {
                    Image(systemName: model.symbol).foregroundStyle(model.color)
                }
                Text(model.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                if let since = model.listeningSince {
                    Text(since, style: .timer).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if model.style == .listening {
                HStack(alignment: .center, spacing: 4) {
                    ForEach(model.levels.indices, id: \.self) { index in
                        Capsule().fill(LinearGradient(colors: [.mint, .teal, .cyan], startPoint: .top, endPoint: .bottom))
                            .frame(width: 5, height: 3 + 37 * CGFloat(model.levels[index]))
                    }
                }.frame(maxWidth: .infinity).frame(height: 42)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: model.levels)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live microphone volume")
                    .accessibilityValue("\(Int((model.levels.last ?? 0) * 100)) percent")
            }
            if !model.detail.isEmpty {
                Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(width: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .padding(8)
    }
}

private struct OverlayActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.teal.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: 0.7).stroke(Color.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotating && !reduceMotion ? 360 : 0))
        }.frame(width: 14, height: 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { rotating = true }
            }
            .accessibilityLabel("Processing")
    }
}

@MainActor
final class DictationOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let panel: NSPanel
    private let model = DictationOverlayModel()
    private let host: NSHostingView<DictationOverlayView>

    init() {
        host = NSHostingView(rootView: DictationOverlayView(model: model))
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = host
    }

    func show(_ text: String, symbol: String, color: Color = .teal, screen: NSScreen?) {
        model.present(.notice, title: text, detail: "", symbol: symbol, color: color)
        position(screen: screen)
    }

    func showNotice(title: String, detail: String, symbol: String, screen: NSScreen?) {
        model.present(.notice, title: title, detail: detail, symbol: symbol, color: .orange)
        position(screen: screen)
    }

    func showWorking(_ title: String, detail: String, screen: NSScreen?) {
        model.present(.working, title: title, detail: detail)
        position(screen: screen)
    }

    func showListening(key: String, screen: NSScreen?) {
        model.present(.listening, title: "Listening", detail: "Release \(key) to transcribe")
        position(screen: screen)
    }

    func updateLevel(_ level: Float) { model.append(level: level) }

    private func position(screen: NSScreen?) {
        host.rootView = DictationOverlayView(model: model)
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 28))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil); model.clear() }
}
