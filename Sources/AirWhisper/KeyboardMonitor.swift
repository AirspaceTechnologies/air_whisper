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

/// A listening-only tap: ordinary shortcuts continue to reach their destination.
@MainActor
final class KeyboardMonitor {
    var key: PushToTalkKey = .fn
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var isHeld: Bool { gesture.isHeld }
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var gesture = ModifierGesture()

    func start() -> Bool {
        stop()
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is installed exclusively on the main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                        .receive(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: context
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPhysicalRelease() }
        }
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        gesture.reset()
        isRunning = false
    }

    func resetHeldState() { gesture.reset() }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            checkPhysicalRelease()
            return
        }
        if type == .keyDown {
            deliver(gesture.ordinaryKey())
            return
        }
        guard type == .flagsChanged else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        deliver(gesture.flagsChanged(key: key, code: code, flags: event.flags.rawValue))
    }

    private func checkPhysicalRelease() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        guard isHeld else { return }
        let flags = CGEventSource.flagsState(.hidSystemState).rawValue
        deliver(gesture.checkRelease(key: key, physicalFlags: flags))
    }

    private func deliver(_ action: ModifierGesture.Action) {
        switch action {
        case .none: break
        case .press: onPress?()
        case .release: onRelease?()
        case .cancel: onCancel?()
        }
    }
}
