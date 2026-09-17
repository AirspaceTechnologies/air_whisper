import AirWhisperCore
import Combine
import Foundation

/// Downloads only on an explicit request. The cleanup model never sees raw audio.
@MainActor public final class LLMModelManager: ObservableObject {
    @Published public private(set) var progress: Double?
    @Published public private(set) var status = "Choose a cleanup model to download."
    private let directory: URL
    private var activeID: UUID?
    private var activeDownload: ModelDownload?
    private var validationTask: Task<Void, Error>?

    public convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(directory: home.appendingPathComponent("Library/Application Support/Air Whisper/models", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
    }

    public func installedURL(for model: CleanupModel) -> URL? {
        let manifest = LLMModelManifest.forModel(model)
        let url = directory.appendingPathComponent(model.fileName)
        return LLMModelValidator.appearsInstalled(url, manifest: manifest) ? url : nil
    }

    public func download(_ model: CleanupModel) async throws -> URL {
        guard activeID == nil else { throw LLMError.downloadInProgress }
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
            try ModelInstaller.createPrivateDirectory(directory)
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
            let manifest = LLMModelManifest.forModel(model)
            let validation = Task.detached(priority: .utility) {
                try LLMModelValidator.validate(temporary, manifest: manifest) {
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
            try ModelInstaller.promote(temporary, to: installed)
            status = "\(model.title) is ready."
            return installed
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Cleanup model download canceled."
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
}
