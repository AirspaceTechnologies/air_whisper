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
            capability: { processID, _ in reads.append(processID); return .disabled },
            enable: { processID, _ in writes.append(processID); return true }
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
            capability: { _, _ in reads += 1; return .enabled },
            enable: { _, _ in writes += 1; return true }
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
            capability: { _, _ in reads += 1; return .disabled },
            enable: { _, _ in writes += 1; return true }
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
            capability: { _, _ in reads += 1; return .unsupported },
            enable: { _, _ in writes += 1; return true }
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
            capability: { _, _ in reads += 1; return available ? .disabled : .unavailable },
            enable: { _, _ in writes += 1; return true }
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
            capability: { _, _ in .disabled },
            enable: { _, _ in writes += 1; return writes > 1 }
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
            capability: { _, _ in .disabled },
            enable: { _, _ in writes += 1; return true }
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
            capability: { _, _ in .disabled },
            enable: { processID, _ in writes.append(processID); return true }
        )
        let other = AccessibilityPreparation.ProcessIdentity(processID: 43, launchDate: nil)

        preparation.prepare(process)
        preparation.prepare(other)
        preparation.forget(processID: process.processID)
        preparation.prepare(other)
        preparation.prepare(process)

        XCTAssertEqual(writes, [process.processID, other.processID, process.processID])
    }

    @MainActor
    func testChromeChannelsAndChromiumRequestEnhancedAccessibilityOnlyOnce() {
        for bundleIdentifier in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
                                 "com.google.Chrome.canary", "org.chromium.Chromium"] {
            var reads: [AccessibilityPreparation.Attribute] = []
            var writes: [AccessibilityPreparation.Attribute] = []
            let preparation = AccessibilityPreparation(
                isTrusted: { true },
                capability: { _, attribute in
                    reads.append(attribute)
                    return attribute == .manualAccessibility ? .unsupported : .disabled
                },
                enable: { processID, attribute in
                    XCTAssertEqual(processID, self.process.processID)
                    writes.append(attribute)
                    return true
                }
            )

            preparation.prepare(process, bundleIdentifier: bundleIdentifier)
            preparation.prepare(process, bundleIdentifier: bundleIdentifier)
            preparation.prepare(process, bundleIdentifier: bundleIdentifier)

            XCTAssertEqual(reads, [.manualAccessibility, .enhancedUserInterface], bundleIdentifier)
            XCTAssertEqual(writes, [.enhancedUserInterface], "Do not restart Chromium's debounce: \(bundleIdentifier)")
        }
    }

    @MainActor
    func testUnknownAndNativeAppsDoNotReceiveChromeFallback() {
        let bundleIdentifiers: [String?] = [nil, "com.apple.TextEdit", "com.tinyspeck.slackmacgap",
                                            "com.google.Chrome.helper", "com.google.Chrome.unrecognized"]
        for bundleIdentifier in bundleIdentifiers {
            var reads: [AccessibilityPreparation.Attribute] = []
            var writes: [AccessibilityPreparation.Attribute] = []
            let preparation = AccessibilityPreparation(
                isTrusted: { true },
                capability: { _, attribute in
                    reads.append(attribute)
                    return .unsupported
                },
                enable: { _, attribute in writes.append(attribute); return true }
            )

            preparation.prepare(process, bundleIdentifier: bundleIdentifier)
            preparation.prepare(process, bundleIdentifier: bundleIdentifier)

            XCTAssertEqual(reads, [.manualAccessibility])
            XCTAssertTrue(writes.isEmpty, "A generic AppKit enhanced UI attribute does not identify a Chromium browser.")
        }
    }

    @MainActor
    func testManualAccessibilityTakesPrecedenceOverChromeFallback() {
        for alreadyEnabled in [false, true] {
            var reads: [AccessibilityPreparation.Attribute] = []
            var writes: [AccessibilityPreparation.Attribute] = []
            let preparation = AccessibilityPreparation(
                isTrusted: { true },
                capability: { _, attribute in
                    reads.append(attribute)
                    return alreadyEnabled ? .enabled : .disabled
                },
                enable: { _, attribute in writes.append(attribute); return true }
            )

            preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
            preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

            XCTAssertEqual(reads, [.manualAccessibility])
            XCTAssertEqual(writes, alreadyEnabled ? [] : [.manualAccessibility])
        }
    }

    @MainActor
    func testEnhancedAppKitValueDoesNotSkipChromiumOptIn() {
        var writes: [AccessibilityPreparation.Attribute] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _, attribute in attribute == .manualAccessibility ? .unsupported : .enabled },
            enable: { _, attribute in writes.append(attribute); return true }
        )

        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(writes, [.enhancedUserInterface],
                       "Chrome's web AX mode is separate from its inherited AppKit attribute value.")
    }

    @MainActor
    func testTransientCapabilitiesRetryWithoutPrematureChromeFallback() {
        var attempt = 0
        var reads: [AccessibilityPreparation.Attribute] = []
        var writes: [AccessibilityPreparation.Attribute] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _, attribute in
                reads.append(attribute)
                if attempt == 0 { return .unavailable }
                if attribute == .manualAccessibility { return .unsupported }
                return attempt == 1 ? .unavailable : .disabled
            },
            enable: { _, attribute in writes.append(attribute); return true }
        )

        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        XCTAssertEqual(reads, [.manualAccessibility])
        XCTAssertTrue(writes.isEmpty)
        attempt = 1
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        XCTAssertTrue(writes.isEmpty)
        attempt = 2
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(reads, [.manualAccessibility,
                               .manualAccessibility, .enhancedUserInterface,
                               .manualAccessibility, .enhancedUserInterface])
        XCTAssertEqual(writes, [.enhancedUserInterface])
    }

    @MainActor
    func testFailedManualEnableDoesNotFallBackToAnotherOptIn() {
        var reads: [AccessibilityPreparation.Attribute] = []
        var writes: [AccessibilityPreparation.Attribute] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _, attribute in reads.append(attribute); return .disabled },
            enable: { _, attribute in writes.append(attribute); return writes.count > 1 }
        )

        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(reads, [.manualAccessibility, .manualAccessibility])
        XCTAssertEqual(writes, [.manualAccessibility, .manualAccessibility])
    }

    @MainActor
    func testFailedEnhancedEnableIsRetriedUntilOneRequestSucceeds() {
        var writes: [AccessibilityPreparation.Attribute] = []
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _, attribute in attribute == .manualAccessibility ? .unsupported : .disabled },
            enable: { _, attribute in writes.append(attribute); return writes.count > 1 }
        )

        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(writes, [.enhancedUserInterface, .enhancedUserInterface])
    }

    @MainActor
    func testChromeWithNeitherCapabilityIsRememberedWithoutWriting() {
        var reads: [AccessibilityPreparation.Attribute] = []
        var writes = 0
        let preparation = AccessibilityPreparation(
            isTrusted: { true },
            capability: { _, attribute in reads.append(attribute); return .unsupported },
            enable: { _, _ in writes += 1; return true }
        )

        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")
        preparation.prepare(process, bundleIdentifier: "com.google.Chrome")

        XCTAssertEqual(reads, [.manualAccessibility, .enhancedUserInterface])
        XCTAssertEqual(writes, 0)
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
        for useChromeFallback in [false, true] {
            let original = InsertionTarget(processID: process.processID, focusedElement: nil)
            var current = original
            let preparation = AccessibilityPreparation(
                isTrusted: { true },
                capability: { _, attribute in
                    useChromeFallback && attribute == .manualAccessibility ? .unsupported : .disabled
                },
                enable: { processID, _ in
                    current = InsertionTarget(processID: processID, focusedElement: AXUIElementCreateApplication(424_242))
                    return true
                }
            )

            XCTAssertFalse(original.matches(current), "Two unknown focus values are not proof of a safe target.")
            preparation.prepare(process, bundleIdentifier: useChromeFallback ? "com.google.Chrome" : nil)
            XCTAssertNotNil(current.focusedElement)
            XCTAssertNil(original.focusedElement)
            XCTAssertFalse(original.matches(current), "Enabling accessibility must never authorize a later field for an existing dictation.")
        }
    }
}
