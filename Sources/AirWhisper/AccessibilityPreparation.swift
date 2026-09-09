import AppKit
import ApplicationServices

/// Ask apps that support Electron's accessibility opt-in to expose their focused field.
/// This does not capture a target or relax the insertion target's focus checks.
@MainActor
final class AccessibilityPreparation {
    struct ProcessIdentity: Hashable {
        let processID: pid_t
        let launchDate: Date?
    }

    enum Capability {
        case enabled, disabled, unsupported, unavailable
    }

    private static let manualAccessibility = "AXManualAccessibility" as CFString
    private let isTrusted: () -> Bool
    private let capability: (pid_t) -> Capability
    private let enable: (pid_t) -> Bool
    private var prepared: Set<ProcessIdentity> = []

    init(isTrusted: @escaping () -> Bool,
         capability: @escaping (pid_t) -> Capability,
         enable: @escaping (pid_t) -> Bool) {
        self.isTrusted = isTrusted
        self.capability = capability
        self.enable = enable
    }

    convenience init() {
        self.init(isTrusted: { AXIsProcessTrusted() }, capability: { processID in
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, Self.manualAccessibility, &value)
            if result == .attributeUnsupported {
                // Some implementations may expose a setter without a getter.
                var settable = DarwinBoolean(false)
                let query = AXUIElementIsAttributeSettable(application, Self.manualAccessibility, &settable)
                if query == .success { return settable.boolValue ? .disabled : .unsupported }
                return query == .attributeUnsupported ? .unsupported : .unavailable
            }
            guard result == .success, let value,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unavailable }
            return CFEqual(value, kCFBooleanTrue) ? .enabled : .disabled
        }, enable: { processID in
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            return AXUIElementSetAttributeValue(application, Self.manualAccessibility, kCFBooleanTrue) == .success
        })
    }

    func prepareFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        prepare(ProcessIdentity(processID: app.processIdentifier, launchDate: app.launchDate))
    }

    func prepare(_ process: ProcessIdentity) {
        guard isTrusted(), !prepared.contains(process) else { return }
        switch capability(process.processID) {
        case .enabled, .unsupported:
            prepared.insert(process)
        case .disabled:
            // Electron may debounce this request for two seconds. Repeated writes would
            // restart that delay, so remember a successful request before it takes effect.
            // https://github.com/electron/electron/blob/v37.3.1/shell/browser/mac/electron_application.mm#L300-L332
            if enable(process.processID) { prepared.insert(process) }
        case .unavailable:
            break // A transient AX failure can be retried on activation or the next recording.
        }
    }

    func forget(processID: pid_t) {
        prepared = prepared.filter { $0.processID != processID }
    }
}
