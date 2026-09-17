import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI
import AirWhisperCore
import AirWhisperAudio
import AirWhisperSpeech

@MainActor
final class AppController: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, listening, stopping, transcribing, cancelling
        var title: String {
            switch self {
            case .idle: return "Ready"
            case .starting: return "Opening microphone…"
            case .listening: return "Listening…"
            case .stopping: return "Finishing recording…"
            case .transcribing: return "Transcribing…"
            case .cancelling: return "Cancelling…"
            }
        }
    }

    let settings = SettingsStore()
    let devices = AudioDeviceManager()
    let models = ModelManager()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var monitoringAuthorized = false
    @Published private(set) var hotkeyActive = false
    @Published private(set) var modelReady = false
    @Published private(set) var preparingModel = false
    @Published private(set) var downloadingModel = false
    @Published private(set) var message: String?
    @Published private(set) var activeMicrophone = ""
    @Published private(set) var pendingTranscript: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var displays: [DisplayChoice] = []
    var onShowSettings: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private let keyboard = KeyboardMonitor()
    private let insertion = TextInsertion()
    private let accessibilityPreparation = AccessibilityPreparation()
    private let overlay = DictationOverlay()
    private var displayOverlays: [DictationOverlay] = []
    private var displayOverlayTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var cancellationID: UUID?
    private var modelOperationID: UUID?
    private var startedAt: Date?
    private var activeScreen: NSScreen?
    private var insertionTarget: InsertionTarget?
    private var sessionSettings = DictationSettings()
    private var startTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    private var pendingExpiryTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var guardTimer: Timer?
    private var observation = Set<AnyCancellable>()
    private var notificationTokens: [NSObjectProtocol] = []
    private var quitting = false
    private enum SuspensionReason: Hashable { case machineSleep, displaySleep, inactiveSession, locked }
    private var suspensionReasons = Set<SuspensionReason>()
    private var suspended: Bool { !suspensionReasons.isEmpty }

    var isBusy: Bool { phase != .idle }
    var setupComplete: Bool { microphoneAuthorized && accessibilityAuthorized && hotkeyActive && modelReady }
    var statusText: String {
        if isBusy { return phase.title }
        if preparingModel { return "Loading transcription model…" }
        if downloadingModel { return "Downloading transcription model…" }
        if let message { return message }
        return setupComplete ? "Hold \(settings.value.hotkey.title) to dictate" : "Complete setup to start dictating"
    }

    func launch() {
        keyboard.key = settings.value.hotkey
        keyboard.onPress = { [weak self] in self?.beginRecording() }
        keyboard.onRelease = { [weak self] in self?.finishRecording() }
        keyboard.onCancel = { [weak self] in self?.cancelSession() }
        displays = DisplayContext.displays
        refreshPermissions()
        refreshLoginStatus()
        settings.$value.dropFirst().removeDuplicates().sink { [weak self] next in
            guard let self else { return }
            if self.keyboard.key != next.hotkey {
                self.cancelSession()
                self.keyboard.key = next.hotkey
                self.updateKeyboardMonitor(restart: true)
            }
            self.onStatusChange?()
        }.store(in: &observation)
        objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.onStatusChange?() }
        }.store(in: &observation)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        guardTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.startedAt else { return }
                if Date().timeIntervalSince(start) > self.sessionSettings.maximumDuration + 90 {
                    self.cancelSession(message: "Dictation timed out. Release the key and try again.")
                }
            }
        }
        installLifecycleObservers()
        if currentModelURL != nil { prepareModel() }
        if !microphoneAuthorized || !accessibilityAuthorized || !hotkeyActive || currentModelURL == nil {
            onShowSettings?()
        }
    }

    var currentModelURL: URL? {
        settings.modelURL(for: settings.value.model) ?? models.installedURL(for: settings.value.model)
    }

    func refreshPermissions() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let hadAccessibilityAccess = accessibilityAuthorized
        accessibilityAuthorized = AXIsProcessTrusted()
        monitoringAuthorized = CGPreflightListenEventAccess()
        if accessibilityAuthorized && !hadAccessibilityAccess { prepareFocusedApplication() }
        if !microphoneAuthorized || !accessibilityAuthorized {
            if isBusy { cancelSession(message: "A required permission was removed. Open Settings to restore access.") }
        }
        updateKeyboardMonitor()
    }

    private func prepareFocusedApplication() {
        guard !quitting, !suspended else { return }
        accessibilityPreparation.prepareFrontmostApplication()
    }

    private func updateKeyboardMonitor(restart: Bool = false) {
        if restart { keyboard.stop() }
        if accessibilityAuthorized && !suspended && !quitting {
            if !keyboard.isRunning { _ = keyboard.start() }
        } else {
            keyboard.stop()
        }
        hotkeyActive = keyboard.isRunning
    }

    func requestMicrophoneAccess() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            message = "Open the packaged Air Whisper.app to grant microphone access."
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refreshPermissions()
            }
        } else { openPrivacyPane("Privacy_Microphone") }
    }

    func requestAccessibilityAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestMonitoringAccess() {
        _ = CGRequestListenEventAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { message = "Could not change launch at login: \(error.localizedDescription)" }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func selectModel(_ model: SpeechModel) {
        guard !isBusy, !downloadingModel else { return }
        settings.value.model = model
        prepareModel()
    }

    func prepareModel() {
        guard !isBusy else { return }
        modelTask?.cancel()
        transcriber.cancel()
        modelReady = false
        message = nil
        let operation = UUID()
        modelOperationID = operation
        guard let url = currentModelURL else {
            preparingModel = false
            modelTask = Task { await transcriber.unload() }
            return
        }
        preparingModel = true
        modelTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare(modelURL: url)
                guard self.modelOperationID == operation, !Task.isCancelled else { return }
                self.modelReady = true
                self.preparingModel = false
            } catch {
                guard self.modelOperationID == operation, !Task.isCancelled else { return }
                self.preparingModel = false
                self.message = "Model could not be loaded: \(error.localizedDescription)"
            }
        }
    }

    func downloadModel() {
        guard !isBusy, !downloadingModel else { return }
        modelTask?.cancel()
        transcriber.cancel()
        preparingModel = false
        modelReady = false
        message = nil
        downloadingModel = true
        let chosen = settings.value.model
        let operation = UUID()
        modelOperationID = operation
        modelTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.models.download(chosen)
                guard self.modelOperationID == operation, !Task.isCancelled else { return }
                self.settings.clearModelOverride(for: chosen)
                self.downloadingModel = false
                self.prepareModel()
            } catch {
                guard self.modelOperationID == operation, !Task.isCancelled else { return }
                self.downloadingModel = false
                if !(error is CancellationError) {
                    self.message = "Model download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelModelDownload() {
        models.cancelDownload()
        modelTask?.cancel()
        modelOperationID = nil
        downloadingModel = false
        message = "Model download cancelled."
    }

    func chooseExistingModel() {
        guard !isBusy, !downloadingModel else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a whisper.cpp English model"
        panel.message = "Select the official ggml-small.en.bin or ggml-medium.en.bin file. Air Whisper verifies it before loading."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            if url.lastPathComponent.contains("medium") { settings.value.model = .mediumEnglish }
            else if url.lastPathComponent.contains("small") { settings.value.model = .smallEnglish }
            settings.useModel(at: url, for: settings.value.model)
            prepareModel()
        }
    }

    func refreshDevicesAndDisplays() {
        devices.refresh()
        displays = DisplayContext.displays
        refreshPermissions()
        refreshLoginStatus()
    }

    func identifyDisplays() {
        displayOverlayTask?.cancel()
        displayOverlays.forEach { $0.hide() }
        displayOverlays = displays.enumerated().map { index, display in
            let badge = DictationOverlay()
            badge.show("Display \(index + 1): \(display.name)", symbol: "display", screen: display.screen)
            return badge
        }
        displayOverlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.displayOverlays.forEach { $0.hide() }
            self?.displayOverlays = []
        }
    }

    private func beginRecording() {
        guard !isBusy, !quitting, !suspended else { return }
        guard setupComplete else {
            showNotice("Open Air Whisper Settings to finish setup.", symbol: "exclamationmark.circle")
            return
        }
        let screen = DisplayContext.focused()
        guard let selected = DeviceSelection.resolve(devices: devices.devices, settings: settings.value, screenID: screen?.id) else {
            showNotice("No microphone is available. Connect one and try again.", symbol: "mic.slash")
            return
        }
        pendingExpiryTask?.cancel()
        pendingTranscript = nil
        overlayTask?.cancel()
        message = nil
        sessionSettings = settings.value
        let id = UUID()
        sessionID = id
        startedAt = Date()
        prepareFocusedApplication()
        insertionTarget = InsertionTarget.capture()
        activeScreen = screen?.screen
        activeMicrophone = DeviceDisplayName.label(for: selected.device, among: devices.devices)
        phase = .starting
        let fallback = selected.missingPreferredDevice ? " (preferred microphone unavailable)" : ""
        overlay.show("Opening \(activeMicrophone)\(fallback)…", symbol: "mic", color: .orange, screen: activeScreen)
        recorder.onFirstSamples = { [weak self] in
            guard let self, self.sessionID == id, self.phase == .starting else { return }
            self.phase = .listening
            self.overlay.show("\(self.activeMicrophone) — listening…", symbol: "waveform", color: .red, screen: self.activeScreen)
        }
        recorder.onFailure = { [weak self] problem in
            guard let self, self.sessionID == id else { return }
            self.cancelSession(message: problem)
        }
        recorder.onLimitReached = { [weak self] in
            guard let self, self.sessionID == id else { return }
            self.finishRecording()
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(deviceID: selected.device.id, maximumDuration: self.sessionSettings.maximumDuration)
            } catch {
                guard self.sessionID == id, !Task.isCancelled,
                      self.phase == .starting || self.phase == .listening else { return }
                self.cancelSession(message: "Microphone could not start: \(error.localizedDescription)")
            }
        }
    }

    private func finishRecording() {
        guard let id = sessionID, phase == .starting || phase == .listening else { return }
        if let startedAt, Date().timeIntervalSince(startedAt) < sessionSettings.minimumDuration {
            cancelSession()
            return
        }
        phase = .stopping
        overlay.show("Finishing recording…", symbol: "waveform", screen: activeScreen)
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.recorder.stop()
                guard self.sessionID == id, !Task.isCancelled else { return }
                guard audio.duration >= 0.15 else {
                    self.completeSession(id: id)
                    self.showNotice("That recording was too short. Wait for Listening, then speak.", symbol: "mic")
                    return
                }
                self.phase = .transcribing
                self.overlay.show("Transcribing…", symbol: "ellipsis.bubble", screen: self.activeScreen)
                let raw = try await self.transcriber.transcribe(audio, language: "en",
                                                               initialPrompt: self.sessionSettings.vocabulary)
                guard self.sessionID == id, !Task.isCancelled else { return }
                guard let text = TextCleaner.clean(raw) else {
                    self.completeSession(id: id)
                    self.showNotice("No speech was recognized.", symbol: "waveform")
                    return
                }
                let initialFocusUnavailable = self.insertionTarget?.focusedElement == nil
                let pasted = self.insertionTarget.map {
                    self.insertion.insert(text, target: $0, mode: self.sessionSettings.pasteMode,
                                          restoreDelay: self.sessionSettings.restoreDelay)
                } ?? false
                self.completeSession(id: id)
                if !pasted {
                    self.pendingTranscript = text
                    self.pendingExpiryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.pendingTranscript = nil
                    }
                    let notice = initialFocusUnavailable
                        ? "The text field wasn't available when dictation started. Copy from the menu; wait a moment and try again."
                        : "Focus changed or insertion was unavailable. Copy dictation from the menu."
                    self.showNotice(notice, symbol: "doc.on.clipboard")
                }
            } catch {
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.cancelSession(message: "Dictation failed: \(error.localizedDescription)")
            }
        }
    }

    private func completeSession(id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        startedAt = nil
        insertionTarget = nil
        startTask = nil
        processingTask = nil
        phase = .idle
        overlay.hide()
    }

    func cancelSession(message: String? = nil) {
        guard sessionID != nil || phase == .cancelling else {
            if let message { showNotice(message, symbol: "exclamationmark.triangle") }
            return
        }
        sessionID = nil
        startedAt = nil
        insertionTarget = nil
        startTask?.cancel()
        processingTask?.cancel()
        transcriber.cancel()
        phase = .cancelling
        overlay.hide()
        let cancellation = UUID()
        cancellationID = cancellation
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            await self.recorder.cancel()
            guard self.cancellationID == cancellation else { return }
            self.phase = .idle
            self.startTask = nil
            self.processingTask = nil
            if let message { self.showNotice(message, symbol: "exclamationmark.triangle") }
        }
    }

    func reset() {
        cancelSession()
        keyboard.resetHeldState()
        message = nil
        pendingTranscript = nil
        pendingExpiryTask?.cancel()
        refreshDevicesAndDisplays()
        if !isBusy && !modelReady && !downloadingModel { prepareModel() }
    }

    func copyPendingTranscript() {
        guard let text = pendingTranscript else { return }
        insertion.restoreClipboardNow()
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            pendingTranscript = nil
            pendingExpiryTask?.cancel()
            message = "Dictation copied. Paste it into the intended field."
        }
    }

    private func showNotice(_ text: String, symbol: String) {
        guard !quitting, !suspended else { return }
        message = text
        overlayTask?.cancel()
        overlay.show(text, symbol: symbol, color: .orange, screen: activeScreen ?? DisplayContext.focused()?.screen)
        overlayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.overlay.hide()
        }
    }

    private func installLifecycleObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareFocusedApplication() }
        })
        notificationTokens.append(workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.accessibilityPreparation.forget(processID: app.processIdentifier)
            }
        })
        for (name, reason) in [(NSWorkspace.willSleepNotification, SuspensionReason.machineSleep),
                               (NSWorkspace.screensDidSleepNotification, .displaySleep),
                               (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession)] {
            notificationTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(reason: reason) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, SuspensionReason.machineSleep),
                               (NSWorkspace.screensDidWakeNotification, .displaySleep),
                               (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)] {
            notificationTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(reason: reason) }
            })
        }
        notificationTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.suspend(reason: .locked) } })
        notificationTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.resume(reason: .locked) } })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displays = DisplayContext.displays }
        })
    }

    private func suspend(reason: SuspensionReason) {
        suspensionReasons.insert(reason)
        cancelSession()
        keyboard.stop()
        hotkeyActive = false
        overlayTask?.cancel()
        displayOverlayTask?.cancel()
        displayOverlays.forEach { $0.hide() }
        overlay.hide()
        pendingTranscript = nil
        insertion.restoreClipboardNow()
    }

    private func resume(reason: SuspensionReason) {
        suspensionReasons.remove(reason)
        guard !suspended else { return }
        refreshDevicesAndDisplays()
    }

    func shutdown() async {
        quitting = true
        sessionID = nil
        modelOperationID = nil
        keyboard.stop()
        permissionTimer?.invalidate()
        guardTimer?.invalidate()
        startTask?.cancel()
        processingTask?.cancel()
        modelTask?.cancel()
        overlayTask?.cancel()
        displayOverlayTask?.cancel()
        displayOverlays.forEach { $0.hide() }
        pendingExpiryTask?.cancel()
        models.cancelDownload()
        transcriber.cancel()
        overlay.hide()
        pendingTranscript = nil
        insertion.restoreClipboardNow()
        await recorder.cancel()
        await transcriber.unload()
    }
}
