import AirWhisperCore
import Combine
import Foundation

/// A single in-memory result. Starting or cancelling a recording does not consume it.
@MainActor
final class TranscriptRecovery: ObservableObject {
    @Published private(set) var text: String?
    private let waitForExpiry: () async -> Void
    private var expiryTask: Task<Void, Never>?

    init(waitForExpiry: @escaping () async -> Void = {
        try? await Task.sleep(nanoseconds: 300_000_000_000)
    }) {
        self.waitForExpiry = waitForExpiry
    }

    deinit { expiryTask?.cancel() }

    func retain(_ text: String) {
        expiryTask?.cancel()
        self.text = text
        expiryTask = Task { [weak self, waitForExpiry] in
            await waitForExpiry()
            guard !Task.isCancelled else { return }
            self?.clear()
            DictationDiagnostics.session.notice("recovery_expired")
        }
    }

    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        text = nil
    }
}
