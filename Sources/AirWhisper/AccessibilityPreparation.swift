import AppKit
import ApplicationServices

/// Ask supported Electron apps and Chromium browsers to expose their focused field.
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

    enum Attribute: String {
        case manualAccessibility = "AXManualAccessibility"
        case enhancedUserInterface = "AXEnhancedUserInterface"
    }

    // AppKit exposes AXEnhancedUserInterface to other apps too. Restrict this
    // fallback to browsers whose Chromium application handles it as a web AX opt-in.
    private static let chromiumBundleIdentifiers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary", "org.chromium.Chromium"
    ]
    private let isTrusted: () -> Bool
    private let capability: (pid_t, Attribute) -> Capability
    private let enable: (pid_t, Attribute) -> Bool
    private var prepared: Set<ProcessIdentity> = []

    init(isTrusted: @escaping () -> Bool,
         capability: @escaping (pid_t, Attribute) -> Capability,
         enable: @escaping (pid_t, Attribute) -> Bool) {
        self.isTrusted = isTrusted
        self.capability = capability
        self.enable = enable
    }

    convenience init() {
        self.init(isTrusted: { AXIsProcessTrusted() }, capability: { processID, attribute in
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            var value: CFTypeRef?
            let name = attribute.rawValue as CFString
            let result = AXUIElementCopyAttributeValue(application, name, &value)
            if result == .attributeUnsupported {
                // Some implementations may expose a setter without a getter.
                var settable = DarwinBoolean(false)
                let query = AXUIElementIsAttributeSettable(application, name, &settable)
                if query == .success { return settable.boolValue ? .disabled : .unsupported }
                return query == .attributeUnsupported ? .unsupported : .unavailable
            }
            guard result == .success, let value,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return .unavailable }
            return CFEqual(value, kCFBooleanTrue) ? .enabled : .disabled
        }, enable: { processID, attribute in
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            return AXUIElementSetAttributeValue(application, attribute.rawValue as CFString, kCFBooleanTrue) == .success
        })
    }

    func prepareFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        prepare(ProcessIdentity(processID: app.processIdentifier, launchDate: app.launchDate),
                bundleIdentifier: app.bundleIdentifier)
    }

    func prepare(_ process: ProcessIdentity, bundleIdentifier: String? = nil) {
        guard isTrusted(), !prepared.contains(process) else { return }
        var attributes: [Attribute] = [.manualAccessibility]
        if let bundleIdentifier, Self.chromiumBundleIdentifiers.contains(bundleIdentifier) {
            attributes.append(.enhancedUserInterface)
        }
        for attribute in attributes {
            switch capability(process.processID, attribute) {
            case .enabled where attribute == .manualAccessibility:
                prepared.insert(process)
                return
            case .enabled, .disabled:
                // Chromium's enhanced UI getter is inherited from AppKit; its value
                // does not describe Chromium's separate web accessibility mode. Send
                // our opt-in once even when that getter already reports true.
                // Both implementations may debounce requests for two seconds. Cache
                // success immediately so activation cannot restart the countdown.
                // https://github.com/electron/electron/blob/v37.3.1/shell/browser/mac/electron_application.mm#L300-L332
                // https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm
                if enable(process.processID, attribute) { prepared.insert(process) }
                return
            case .unsupported:
                continue
            case .unavailable:
                return // Retry transient failures without choosing another opt-in.
            }
        }
        prepared.insert(process)
    }

    func forget(processID: pid_t) {
        prepared = prepared.filter { $0.processID != processID }
    }
}
