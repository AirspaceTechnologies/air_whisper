import AppKit
import ApplicationServices
import XCTest
@testable import AirWhisper

final class AccessibilityPreparationTests: XCTestCase {
    private let process = AccessibilityPreparation.ProcessIdentity(
        processID: 42, launchDate: Date(timeIntervalSince1970: 1_000)
    )

    @MainActor
    func testDisabledAccessibilityIsEnabledOnlyOncePerLaunch() {
        var reads: [pid_t] = []
        var writes: [pid_t] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { reads.append($0); return .disabled },
            enable: { writes.append($0); return true }
        )

        preparation.prepare(process)
        preparation.prepare(process)
        preparation.prepare(.init(processID: process.processID, launchDate: process.launchDate))

        XCTAssertEqual(reads, [process.processID])
        XCTAssertEqual(writes, [process.processID], "Repeated activation must not rebuild an app's accessibility tree.")
    }

    @MainActor
    func testInitiallyEnabledAccessibilityIsRememberedWithoutWriting() {
        var reads = 0
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in reads += 1; return .enabled },
            enable: { _ in writes += 1; return true }
        )

        preparation.prepare(process)
        preparation.prepare(process)

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testPermissionDenialDoesNotConsumePreparationAttempt() {
        var trusted = false
        var reads = 0
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { trusted },
            capability: { _ in reads += 1; return .disabled },
            enable: { _ in writes += 1; return true }
        )

        preparation.prepare(process)
        preparation.prepare(process)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(writes, 0)

        trusted = true
        preparation.prepare(process)
        preparation.prepare(process)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testUnsupportedApplicationIsLeftAloneAndRemembered() {
        var reads = 0
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in reads += 1; return .unsupported },
            enable: { _ in writes += 1; return true }
        )

        preparation.prepare(process)
        preparation.prepare(process)

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testTemporarilyUnavailableCapabilityCanBeRetried() {
        var available = false
        var reads = 0
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in reads += 1; return available ? .disabled : .unavailable },
            enable: { _ in writes += 1; return true }
        )

        preparation.prepare(process)
        XCTAssertEqual(writes, 0)
        available = true
        preparation.prepare(process)
        preparation.prepare(process)

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testFailedEnableCanBeRetriedWithoutRepeatingSuccessfulWrite() {
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in .disabled },
            enable: { _ in writes += 1; return writes > 1 }
        )

        preparation.prepare(process)
        preparation.prepare(process)
        preparation.prepare(process)

        XCTAssertEqual(writes, 2)
    }

    @MainActor
    func testNewLaunchWithReusedProcessIDCanBePrepared() {
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in .disabled },
            enable: { _ in writes += 1; return true }
        )
        let relaunched = AccessibilityPreparation.ProcessIdentity(
            processID: process.processID, launchDate: Date(timeIntervalSince1970: 2_000)
        )

        preparation.prepare(process)
        preparation.prepare(relaunched)
        preparation.prepare(relaunched)

        XCTAssertEqual(writes, 2)
    }

    @MainActor
    func testTerminationForgetsOnlyTheTerminatedProcess() {
        var writes: [pid_t] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in .disabled },
            enable: { writes.append($0); return true }
        )
        let other = AccessibilityPreparation.ProcessIdentity(processID: 43, launchDate: nil)

        preparation.prepare(process)
        preparation.prepare(other)
        preparation.forget(processID: process.processID)
        preparation.prepare(other)
        preparation.prepare(process)

        XCTAssertEqual(writes, [process.processID, other.processID, process.processID])
    }

    func testExactOriginalFocusStillMatches() {
        // These constructors create local references only; no test reads an AX attribute or TCC state.
        let element = AXUIElementCreateApplication(424_242)
        let original = InsertionTarget(processID: process.processID, focusedElement: element)

        XCTAssertTrue(original.matches(InsertionTarget(processID: process.processID, focusedElement: element)))
        XCTAssertTrue(original.matches(InsertionTarget(
            processID: process.processID, focusedElement: AXUIElementCreateApplication(424_242)
        )), "Focus comparison must use AX identity (CFEqual), not Swift object identity.")
    }

    func testDifferentFocusedElementInSameProcessIsRejected() {
        let original = InsertionTarget(
            processID: process.processID, focusedElement: AXUIElementCreateApplication(424_242)
        )
        let changed = InsertionTarget(
            processID: process.processID, focusedElement: AXUIElementCreateApplication(424_243)
        )

        XCTAssertFalse(original.matches(changed))
    }

    func testChangedProcessIsRejectedEvenWithSameElement() {
        let element = AXUIElementCreateApplication(424_242)
        let original = InsertionTarget(processID: process.processID, focusedElement: element)

        XCTAssertFalse(original.matches(InsertionTarget(processID: 43, focusedElement: element)))
    }

    func testMissingCurrentFocusIsRejected() {
        let original = InsertionTarget(
            processID: process.processID, focusedElement: AXUIElementCreateApplication(424_242)
        )

        XCTAssertFalse(original.matches(nil))
        XCTAssertFalse(original.matches(InsertionTarget(processID: process.processID, focusedElement: nil)))
    }

    @MainActor
    func testPreparationCannotAdoptAFocusThatAppearedAfterOriginalCapture() {
        let original = InsertionTarget(processID: process.processID, focusedElement: nil)
        var current = original
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _ in .disabled },
            enable: { processID in
                current = InsertionTarget(processID: processID, focusedElement: AXUIElementCreateApplication(424_242))
                return true
            }
        )

        XCTAssertFalse(original.matches(current), "Two unknown focus values are not proof of a safe target.")
        preparation.prepare(process)
        XCTAssertNotNil(current.focusedElement)
        XCTAssertNil(original.focusedElement)
        XCTAssertFalse(original.matches(current), "Enabling accessibility must never authorize a later field for an existing dictation.")
    }
}
