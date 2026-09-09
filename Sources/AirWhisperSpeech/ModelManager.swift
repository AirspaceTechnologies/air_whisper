import AirWhisperCore
import Combine
import Darwin
import Foundation

/// Downloads only on an explicit request. Model and partial files never contain user audio.
@MainActor public final class ModelManager: ObservableObject {
    @Published public private(set) var progress: Double?
    @Published public private(set) var status = "Choose a model to download, or use an existing model."
    private let directory: URL
    private let legacyDirectory: URL
    private var activeID: UUID?
    private var activeDownload: ModelDownload?
    private var validationTask: Task<Void, Error>?

    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            directory: home.appendingPathComponent("Library/Application Support/Air Whisper/models", isDirectory: true),
            legacyDirectory: home.appendingPathComponent(".dictate/models", isDirectory: true)
        )
    }

    init(directory: URL, legacyDirectory: URL) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
    }

    public func installedURL(for model: SpeechModel) -> URL? {
        let manifest = ModelManifest.forModel(model)
        return [directory, legacyDirectory]
            .map { $0.appendingPathComponent(model.fileName) }
            .first { ModelValidator.appearsInstalled($0, manifest: manifest) }
    }

    public func download(_ model: SpeechModel) async throws -> URL {
        guard activeID == nil else { throw SpeechError.downloadInProgress }
        try Task.checkCancellation()
        let id = UUID()
        activeID = id
        progress = 0
        status = "Downloading \(model.title)…"
        let stagingURL = directory.appendingPathComponent(".\(id.uuidString).download")
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
            if activeID == id {
                activeID = nil
                activeDownload = nil
                validationTask = nil
                progress = nil
            }
        }

        do {
            try Self.createPrivateDirectory(directory)
            let download = ModelDownload(url: model.downloadURL, stagingURL: stagingURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.activeID == id else { return }
                    self.progress = min(0.99, fraction)
                }
            }
            activeDownload = download
            let temporary = try await download.start()
            try Task.checkCancellation()
            guard !download.isCanceled else { throw CancellationError() }
            status = "Checking \(model.title)…"
            progress = 0.99
            let manifest = ModelManifest.forModel(model)
            let validation = Task.detached(priority: .utility) {
                try ModelValidator.validate(temporary, manifest: manifest) {
                    try Task.checkCancellation()
                    if download.isCanceled { throw CancellationError() }
                }
            }
            validationTask = validation
            try await withTaskCancellationHandler {
                try await validation.value
            } onCancel: {
                validation.cancel()
            }
            try Task.checkCancellation()
            guard !download.isCanceled else { throw CancellationError() }
            let installed = directory.appendingPathComponent(model.fileName)
            try Self.promote(temporary, to: installed)
            status = "\(model.title) is ready."
            return installed
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Model download canceled."
                throw CancellationError()
            }
            status = error.localizedDescription
            throw error
        }
    }

    public func cancelDownload() {
        activeDownload?.cancel()
        validationTask?.cancel()
    }

    private static func createPrivateDirectory(_ directory: URL) throws {
        let appDirectory = directory.deletingLastPathComponent()
        for url in [appDirectory, directory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    static func promote(_ temporary: URL, to destination: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // Same-directory POSIX rename is atomic, including replacement of an older model.
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// URLSession owns temporary-file lifetime only during delegate callbacks. Move it before
/// returning from didFinishDownloadingTo, then validate the private staging file off main.
final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let stagingURL: URL
    private let onProgress: @Sendable (Double) -> Void
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var canceled = false

    init(url: URL, stagingURL: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.url = url
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    var isCanceled: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceled
    }

    func cancel() {
        lock.lock()
        canceled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func start() async throws -> URL {
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, !isCanceled else { return }
        onProgress(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !canceled else { outcome = .failure(CancellationError()); return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            outcome = .failure(SpeechError.downloadFailed)
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            outcome = .success(stagingURL)
        } catch { outcome = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<URL, Error>
        if canceled { result = .failure(CancellationError()) }
        else if let error { result = .failure(error) }
        else { result = outcome ?? .failure(SpeechError.downloadFailed) }
        self.session = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
