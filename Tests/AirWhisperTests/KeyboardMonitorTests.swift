import AppKit
import XCTest
@testable import AirWhisper

@MainActor
final class KeyboardMonitorTests: XCTestCase {
    func testCreatingDisabledTapDoesNotReportReady() {
        let driver = FakeKeyboardTap()
        driver.enableOnStart = false
        let monitor = KeyboardMonitor(driver: driver)
        var availability: [Bool] = []
        monitor.onAvailabilityChange = { availability.append($0) }
        XCTAssertFalse(monitor.start())
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(availability, [false])
        XCTAssertNil(driver.receive)
    }

    func testUnrecoverableTapIsTornDownAndNextStartRecreatesIt() {
        let driver = FakeKeyboardTap()
        let monitor = KeyboardMonitor(driver: driver)
        var availability: [Bool] = []
        monitor.onAvailabilityChange = { availability.append($0) }
        XCTAssertTrue(monitor.start())
        driver.isEnabled = false
        driver.enableOnRecovery = false
        XCTAssertFalse(monitor.isRunning, "Read actual OS state rather than the last successful start.")
        monitor.checkHealth()
        XCTAssertNil(driver.receive)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(availability, [true, false])
        XCTAssertTrue(monitor.start())
        XCTAssertEqual(driver.starts, 2)
        XCTAssertEqual(availability, [true, false, true])
        monitor.stop()
    }

    func testTransientDisableCanRecoverWithoutRecreatingTap() {
        let driver = FakeKeyboardTap()
        let monitor = KeyboardMonitor(driver: driver)
        XCTAssertTrue(monitor.start())
        driver.isEnabled = false
        driver.enableOnRecovery = true
        monitor.checkHealth()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(driver.starts, 1)
        monitor.stop()
    }

    func testLostTapCancelsHeldGestureInsteadOfLeavingRecordingOpen() throws {
        let driver = FakeKeyboardTap()
        let monitor = KeyboardMonitor(driver: driver)
        var cancellations = 0
        monitor.onCancel = { cancellations += 1 }
        XCTAssertTrue(monitor.start())
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.flags = .maskSecondaryFn
        driver.receive?(.flagsChanged, event)
        XCTAssertTrue(monitor.isHeld)
        driver.isEnabled = false
        driver.enableOnRecovery = false
        monitor.checkHealth()
        XCTAssertFalse(monitor.isHeld)
        XCTAssertEqual(cancellations, 1)
        monitor.stop()
    }
}

@MainActor
private final class FakeKeyboardTap: KeyboardTapDriving {
    var isEnabled = false
    var enableOnStart = true
    var enableOnRecovery = true
    var starts = 0
    var receive: ((CGEventType, CGEvent) -> Void)?
    func start(receive: @escaping (CGEventType, CGEvent) -> Void) -> Bool {
        starts += 1
        self.receive = receive
        isEnabled = enableOnStart
        return true // A non-null tap can still be unusable.
    }
    func enable() { isEnabled = enableOnRecovery }
    func stop() { isEnabled = false; receive = nil }
}
