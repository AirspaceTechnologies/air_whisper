import Darwin
import Foundation

public enum ModelDownloadError: Error {
    case failed
}

/// URLSession owns temporary-file lifetime only during delegate callbacks. Move it before
/// returning from didFinishDownloadingTo, then validate the private staging file off main.
public final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let stagingURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var canceled = false

    public init(url: URL, stagingURL: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    public var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceled
    }

    public func cancel() {
        lock.lock()
        canceled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    public func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if canceled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                            totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, !isCanceled else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !canceled else { outcome = .failure(CancellationError()); return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            outcome = .failure(ModelDownloadError.failed)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            outcome = .success(stagingURL)
        } catch { outcome = .failure(error) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<URL, Error>
        if canceled { result = .failure(CancellationError()) }
        else if let error { result = .failure(error) }
        else { result = outcome ?? .failure(ModelDownloadError.failed) }
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

/// Shared atomic install/private-directory helpers for on-disk model files (speech or LLM).
public enum ModelInstaller {
    public static func createPrivateDirectory(_ directory: URL) throws {
        let appDirectory = directory.deletingLastPathComponent()
        for url in [appDirectory, directory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    public static func promote(_ temporary: URL, to destination: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Same-directory POSIX rename is atomic, including replacement of an older model.
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
