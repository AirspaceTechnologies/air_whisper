import XCTest
@testable import AirWhisper

@MainActor
final class TranscriptRecoveryTests: XCTestCase {
    func testResultRemainsReadableUntilExpiry() async {
        let scheduled = expectation(description: "expiry scheduled")
        var expiration: CheckedContinuation<Void, Never>?
        let recovery = TranscriptRecovery(waitForExpiry: {
            await withCheckedContinuation { continuation in
                expiration = continuation
                scheduled.fulfill()
            }
        })
        recovery.retain("recognized fixture")
        await fulfillment(of: [scheduled], timeout: 2)
        XCTAssertEqual(recovery.text, "recognized fixture")
        XCTAssertEqual(recovery.text, "recognized fixture", "Copying must not consume the result.")
        let cleared = expectation(description: "expired result cleared")
        let observation = recovery.$text.sink { if $0 == nil { cleared.fulfill() } }
        expiration?.resume()
        await fulfillment(of: [cleared], timeout: 2)
        observation.cancel()
        XCTAssertNil(recovery.text)
    }

    func testOldExpiryCannotEraseNewResultAndClearRemovesIt() async {
        let firstScheduled = expectation(description: "first expiry scheduled")
        let secondScheduled = expectation(description: "second expiry scheduled")
        var expirations: [CheckedContinuation<Void, Never>] = []
        let recovery = TranscriptRecovery(waitForExpiry: {
            await withCheckedContinuation { continuation in
                expirations.append(continuation)
                (expirations.count == 1 ? firstScheduled : secondScheduled).fulfill()
            }
        })
        recovery.retain("first fixture")
        await fulfillment(of: [firstScheduled], timeout: 2)
        recovery.retain("second fixture")
        await fulfillment(of: [secondScheduled], timeout: 2)
        let erased = expectation(description: "old expiry must not clear new result")
        erased.isInverted = true
        let observation = recovery.$text.sink { if $0 == nil { erased.fulfill() } }
        expirations[0].resume()
        await fulfillment(of: [erased], timeout: 0.05)
        observation.cancel()
        XCTAssertEqual(recovery.text, "second fixture")
        recovery.clear()
        XCTAssertNil(recovery.text)
        expirations[1].resume()
    }
}
