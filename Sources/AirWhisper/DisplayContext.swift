import AppKit
import ApplicationServices
import AirWhisperCore

enum DeviceDisplayName {
    static func label(for device: AudioInputDevice, among devices: [AudioInputDevice]) -> String {
        guard devices.filter({ $0.name == device.name }).count > 1 else { return device.name }
        // Stable across enumeration order and reconnects; Swift's randomized Hasher is unsuitable.
        let digest = device.id.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let suffix = String(format: "%06llX", digest & 0xFFFFFF)
        return "\(device.name) — \(suffix)"
    }
}

struct DisplayChoice: Identifiable {
    let id: String
    let name: String
    let screen: NSScreen
}

@MainActor
enum DisplayContext {
    static var displays: [DisplayChoice] {
        NSScreen.screens.sorted { a, b in
            a.frame.minX == b.frame.minX ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX
        }.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            else { return nil }
            let id = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            return DisplayChoice(id: id, name: screen.localizedName, screen: screen)
        }
    }

    static func focused() -> DisplayChoice? {
        let all = displays
        if let app = NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let focusedWindow = unsafeBitCast(window, to: AXUIElement.self)
                var position: CFTypeRef?
                var size: CFTypeRef?
                if AXUIElementCopyAttributeValue(focusedWindow, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(focusedWindow, kAXSizeAttribute as CFString, &size) == .success,
                   let position, let size,
                   CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    var dimensions = CGSize.zero
                    AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
                    AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
                    let cocoaTop = NSScreen.screens.first?.frame.maxY ?? 0
                    let rect = CGRect(x: point.x, y: cocoaTop - point.y - dimensions.height,
                                      width: dimensions.width, height: dimensions.height)
                    if let best = all.max(by: { area($0.screen.frame.intersection(rect)) < area($1.screen.frame.intersection(rect)) }),
                       area(best.screen.frame.intersection(rect)) > 0 { return best }
                }
            }
        }
        let cursor = NSEvent.mouseLocation
        return all.first(where: { $0.screen.frame.contains(cursor) }) ?? all.first
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
    }
}

/// Capture the target before dictation and refuse automatic insertion if it changed.
struct InsertionTarget {
    let processID: pid_t
    let focusedElement: AXUIElement?

    @MainActor
    static func capture() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        var focused: AXUIElement?
        if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            focused = unsafeBitCast(value, to: AXUIElement.self)
        }
        return InsertionTarget(processID: app.processIdentifier, focusedElement: focused)
    }

    @MainActor
    func isStillFocused() -> Bool {
        matches(Self.capture())
    }

    func matches(_ current: InsertionTarget?) -> Bool {
        guard let current, current.processID == processID else { return false }
        // Unknown focus is intentionally not treated as permission to type into a new field.
        guard let original = focusedElement, let now = current.focusedElement else { return false }
        return CFEqual(original, now)
    }
}
