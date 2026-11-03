import XCTest
@testable import AirWhisper

final class DisplayMicrophoneDiscoveryTests: XCTestCase {
    func testProfilerIdentityUsesManufacturerSerialAndActualDisplayID() {
        let profile = Data(#"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_spdisplays_displayID":"5","spdisplays_display-serial-number":"SCREEN-B","_spdisplays_display-serial-number":"abcdef"},{"_spdisplays_displayID":"2","spdisplays_display-serial-number":"SCREEN-A"},{"_spdisplays_displayID":"7"}]}]}"#.utf8)
        let identities = DisplayMicrophoneDiscovery.displayIdentities(profile: profile, displays: [
            .init(id: "left", number: 2), .init(id: "right", number: 5), .init(id: "unknown", number: 7)])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: identities.map { ($0.id, $0.serial) }), ["left": "SCREEN-A", "right": "SCREEN-B"])
    }

    func testUnavailableOrChangedTopologyDoesNotGuess() {
        XCTAssertTrue(DisplayMicrophoneDiscovery.displayIdentities(profile: Data(), displays: [.init(id: "left", number: 2)]).isEmpty)
        let profile = Data(#"{"SPDisplaysDataType":[{"spdisplays_ndrvs":[{"_spdisplays_displayID":"5","spdisplays_display-serial-number":"SCREEN-B"}]}]}"#.utf8)
        XCTAssertTrue(DisplayMicrophoneDiscovery.displayIdentities(profile: profile, displays: [.init(id: "left", number: 2)]).isEmpty)
    }
}
