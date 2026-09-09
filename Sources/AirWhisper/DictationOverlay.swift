import AppKit
import SwiftUI

@MainActor
final class DictationOverlay {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let panel: NSPanel

    init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 70),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
    }

    func show(_ text: String, symbol: String, color: Color = .accentColor, screen: NSScreen?) {
        let view = HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium)).foregroundStyle(color)
            Text(text).font(.system(size: 14, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .frame(width: 440, height: 70)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        panel.contentView = NSHostingView(rootView: view)
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - 220, y: frame.minY + 38))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
