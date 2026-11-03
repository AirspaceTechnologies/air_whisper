import Foundation
import OSLog

/// Local diagnostics contain stage names, timings, counts, and status codes only.
/// Never log audio, transcript text, clipboard contents, field values, or device IDs.
public enum DictationDiagnostics {
    public static let session = DiagnosticLogger(category: "session")
    public static let keyboard = DiagnosticLogger(category: "keyboard")
    public static let insertion = DiagnosticLogger(category: "insertion")
    private static let queue = DispatchQueue(label: "org.airspace.AirWhisper.diagnostics")
    private static var file: DiagnosticFileLog?

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Air Whisper", isDirectory: true)
    }

    /// Called only by the app, never implicitly by tests or command-line diagnostics.
    public static func enableLocalFileLogging() {
        queue.async { file = DiagnosticFileLog(directory: directory) }
    }

    fileprivate static func append(category: String, severity: String, message: String) {
        let date = Date()
        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: date)
            file?.append("\(timestamp) [\(category)] \(severity) \(message)\n")
        }
    }
}

public struct DiagnosticLogger {
    private let category: String
    private let logger: Logger

    fileprivate init(category: String) {
        self.category = category
        logger = Logger(subsystem: "org.airspace.AirWhisper", category: category)
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        DictationDiagnostics.append(category: category, severity: "notice", message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DictationDiagnostics.append(category: category, severity: "error", message: message)
    }
}

/// Accessed exclusively on the diagnostics queue. At most two 256 KiB files are kept.
final class DiagnosticFileLog {
    private let directory: URL
    private let maximumBytes: Int
    private var reportedFailure = false
    private var current: URL { directory.appendingPathComponent("diagnostics.log") }
    private var previous: URL { directory.appendingPathComponent("diagnostics.previous.log") }

    init(directory: URL, maximumBytes: Int = 262_144) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    func append(_ line: String) {
        let data = Data(line.utf8.prefix(maximumBytes))
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumBytes {
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                if manager.fileExists(atPath: current.path) { try manager.moveItem(at: current, to: previous) }
            }
            if !manager.fileExists(atPath: current.path) {
                guard manager.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Do not recursively log file failures, or expose paths/error descriptions.
            if !reportedFailure {
                Logger(subsystem: "org.airspace.AirWhisper", category: "diagnostics")
                    .error("local_diagnostic_file_unavailable")
                reportedFailure = true
            }
        }
    }
}
