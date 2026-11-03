import Foundation
import XCTest
@testable import AirWhisperCore

final class DiagnosticFileLogTests: XCTestCase {
    func testLogRotatesAndKeepsOnlyTwoBoundedPrivateFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticFileLog(directory: directory, maximumBytes: 20)
        for index in 0..<10 { log.append("event_\(index)\n") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["diagnostics.log", "diagnostics.previous.log"])
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 20)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let current = try String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
        XCTAssertTrue(current.contains("event_9"))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testOversizedEventCannotExceedFileLimitAndFailedWriteDoesNotCrash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticFileLog(directory: directory, maximumBytes: 20)
        log.append(String(repeating: "x", count: 100))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("diagnostics.log")).count, 20)
        let invalid = DiagnosticFileLog(directory: directory.appendingPathComponent("diagnostics.log"))
        invalid.append("cannot write below a file\n")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("diagnostics.log")).count, 20)
    }
}
