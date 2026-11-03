import AppKit
import AirWhisperCore

/// State is independent of an event tap so missed releases and modifier chords are testable.
struct ModifierGesture {
    enum Action: Equatable { case none, press, release, cancel }
    private(set) var isHeld = false

    mutating func flagsChanged(key: PushToTalkKey, code: UInt16, flags: UInt64) -> Action {
        guard code == key.keyCode else { return isHeld ? .cancel : .none }
        let down = flags & key.rawMask != 0
        if down && !isHeld {
            isHeld = true
            var forbidden: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
            var oppositeSideMask: UInt64 = 0
            switch key {
            case .rightalt: forbidden.remove(.maskAlternate); oppositeSideMask = 0x20
            case .rightcmd: forbidden.remove(.maskCommand); oppositeSideMask = 0x8
            case .rightctrl: forbidden.remove(.maskControl); oppositeSideMask = 0x1
            case .fn: forbidden.remove(.maskSecondaryFn)
            }
            return flags & (forbidden.rawValue | oppositeSideMask) == 0 ? .press : .none
        }
        if !down && isHeld { isHeld = false; return .release }
        return .none
    }

    mutating func checkRelease(key: PushToTalkKey, physicalFlags: UInt64) -> Action {
        guard isHeld, physicalFlags & key.rawMask == 0 else { return .none }
        isHeld = false
        return .release
    }

    func ordinaryKey() -> Action { isHeld ? .cancel : .none }
    mutating func reset() { isHeld = false }
}

@MainActor
protocol KeyboardTapDriving: AnyObject {
    var isEnabled: Bool { get }
    func start(receive: @escaping (CGEventType, CGEvent) -> Void) -> Bool
    func enable()
    func stop()
}

/// Owns the OS resource independently of the gesture and recovery state.
@MainActor
private final class SystemKeyboardTap: KeyboardTapDriving {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var receive: ((CGEventType, CGEvent) -> Void)?
    var isEnabled: Bool {
        guard let tap, CFMachPortIsValid(tap) else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func start(receive: @escaping (CGEventType, CGEvent) -> Void) -> Bool {
        stop()
        self.receive = receive
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                MainActor.assumeIsolated {
                    Unmanaged<SystemKeyboardTap>.fromOpaque(context).takeUnretainedValue().receive?(type, event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { self.receive = nil; return false }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        enable()
        return isEnabled
    }

    func enable() {
        if let tap, CFMachPortIsValid(tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        receive = nil
    }
}

/// A listening-only tap: ordinary shortcuts continue to reach their destination.
@MainActor
final class KeyboardMonitor {
    var key: PushToTalkKey = .fn
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    var isHeld: Bool { gesture.isHeld }
    var isRunning: Bool { driver.isEnabled }
    private let driver: KeyboardTapDriving
    private var watchdog: Timer?
    private var gesture = ModifierGesture()
    private var reportedStartFailure = false

    convenience init() { self.init(driver: SystemKeyboardTap()) }
    init(driver: KeyboardTapDriving) { self.driver = driver }

    func start() -> Bool {
        stop()
        guard driver.start(receive: { [weak self] type, event in self?.receive(type: type, event: event) }),
              driver.isEnabled else {
            driver.stop()
            if !reportedStartFailure {
                DictationDiagnostics.keyboard.error("monitor_unavailable accessibility=\(AXIsProcessTrusted()) input_monitoring=\(CGPreflightListenEventAccess())")
                reportedStartFailure = true
            }
            onAvailabilityChange?(false)
            return false
        }
        reportedStartFailure = false
        DictationDiagnostics.keyboard.notice("monitor_started hotkey=\(self.key.rawValue)")
        onAvailabilityChange?(true)
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        driver.stop()
        gesture.reset()
    }

    func resetHeldState() { gesture.reset() }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DictationDiagnostics.keyboard.notice("tap_disabled timeout=\(type == .tapDisabledByTimeout)")
            driver.enable()
            // The watchdog tears down failed resources outside the tap callback.
            return
        }
        if type == .keyDown {
            deliver(gesture.ordinaryKey())
            return
        }
        guard type == .flagsChanged else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let action = gesture.flagsChanged(key: key, code: code, flags: event.flags.rawValue)
        if code == key.keyCode {
            DictationDiagnostics.keyboard.notice("hotkey_event flags=\(event.flags.rawValue) action=\(String(describing: action))")
        }
        deliver(action)
    }

    func checkHealth() {
        if !driver.isEnabled {
            driver.enable()
            guard driver.isEnabled else {
                let wasHeld = isHeld
                stop()
                DictationDiagnostics.keyboard.error("monitor_lost recreating_on_next_permission_check")
                onAvailabilityChange?(false)
                if wasHeld { onCancel?() }
                return
            }
            DictationDiagnostics.keyboard.notice("monitor_reenabled")
        }
        guard isHeld else { return }
        let flags = CGEventSource.flagsState(.hidSystemState).rawValue
        let action = gesture.checkRelease(key: key, physicalFlags: flags)
        if action == .release { DictationDiagnostics.keyboard.notice("watchdog_recovered_release") }
        deliver(action)
    }

    private func deliver(_ action: ModifierGesture.Action) {
        switch action {
        case .none: break
        case .press: onPress?()
        case .release: onRelease?()
        case .cancel:
            DictationDiagnostics.keyboard.notice("gesture_cancelled_by_chord")
            onCancel?()
        }
    }
}
