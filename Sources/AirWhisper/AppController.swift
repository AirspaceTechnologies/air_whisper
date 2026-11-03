import AppKit
import AVFoundation
import Combine
import Carbon
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
    let microphoneTester = MicrophoneTester()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var monitoringAuthorized = false
    @Published private(set) var hotkeyActive = false
    @Published private(set) var secureInputActive = false
    @Published private(set) var lastHotkeyDetected: Date?
    @Published private(set) var modelReady = false
    @Published private(set) var preparingModel = false
    @Published private(set) var downloadingModel = false
    @Published private(set) var message: String?
    @Published private(set) var activeMicrophone = ""
    var latestTranscript: String? { transcriptRecovery.text }
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var automaticMicrophones: [String: String] = [:]
    @Published private(set) var matchingMicrophones = false
    var onShowSettings: (() -> Void)?
    var onStatusChange: (() -> Void)?

    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private let keyboard = KeyboardMonitor()
    private let insertion = TextInsertion()
    private let accessibilityPreparation = AccessibilityPreparation()
    private let overlay = DictationOverlay()
    private let microphoneTestOverlay = MicrophoneTestOverlay()
    private var microphoneTestOperation: UUID?
    private var matchingTask: Task<Void, Never>?
    private var matchingTopology: [String] = []
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
    private let transcriptRecovery = TranscriptRecovery()
    private var permissionTimer: Timer?
    private var guardTimer: Timer?
    private var observation = Set<AnyCancellable>()
    private var notificationTokens: [NSObjectProtocol] = []
    private var quitting = false
    private enum SuspensionReason: Hashable { case machineSleep, displaySleep, inactiveSession, locked }
    private var suspensionReasons = Set<SuspensionReason>()
    private var suspended: Bool { !suspensionReasons.isEmpty }

    var isBusy: Bool { phase != .idle }
    var setupComplete: Bool { microphoneAuthorized && accessibilityAuthorized && keyboard.isRunning && !secureInputActive && modelReady }
    var statusText: String {
        if isBusy { return phase.title }
        if !accessibilityAuthorized { return "Accessibility access required — open Air Whisper Settings." }
        if !microphoneAuthorized { return "Microphone access required — open Air Whisper Settings." }
        if suspended { return "Dictation is paused while this Mac is inactive." }
        if secureInputActive { return "Keyboard access is paused by macOS Secure Input. Finish password entry in the other app, then try again." }
        if !hotkeyActive {
            return monitoringAuthorized
                ? "macOS is blocking the keyboard listener. Re-add Air Whisper in Accessibility and Input Monitoring, then reopen it."
                : "Input Monitoring access required — open Air Whisper Settings."
        }
        if preparingModel { return "Loading transcription model…" }
        if downloadingModel { return "Downloading transcription model…" }
        if let message { return message }
        if !modelReady { return "Transcription model required — open Air Whisper Settings." }
        return "Hold \(settings.value.hotkey.title) to dictate"
    }

    func launch() {
        DictationDiagnostics.enableLocalFileLogging()
        DictationDiagnostics.session.notice("launch version=\(AppVersion.appTitle)")
        transcriptRecovery.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &observation)
        keyboard.key = settings.value.hotkey
        keyboard.onPress = { [weak self] in self?.beginRecording() }
        keyboard.onAvailabilityChange = { [weak self] available in self?.hotkeyActive = available }
        keyboard.onRelease = { [weak self] in self?.finishRecording() }
        keyboard.onCancel = { [weak self] in self?.cancelSession() }
        displays = DisplayContext.displays
        refreshAutomaticMicrophones(devices: devices.devices)
        devices.$devices.dropFirst().removeDuplicates().sink { [weak self] devices in
            self?.refreshAutomaticMicrophones(devices: devices)
        }.store(in: &observation)
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
        let previous = [microphoneAuthorized, accessibilityAuthorized, monitoringAuthorized, secureInputActive]
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let hadAccessibilityAccess = accessibilityAuthorized
        accessibilityAuthorized = AXIsProcessTrusted()
        monitoringAuthorized = CGPreflightListenEventAccess()
        secureInputActive = IsSecureEventInputEnabled()
        if previous != [microphoneAuthorized, accessibilityAuthorized, monitoringAuthorized, secureInputActive] {
            DictationDiagnostics.session.notice("permissions microphone=\(self.microphoneAuthorized) accessibility=\(self.accessibilityAuthorized) input_monitoring=\(self.monitoringAuthorized) secure_input=\(self.secureInputActive)")
        }
        if accessibilityAuthorized && !hadAccessibilityAccess { prepareFocusedApplication() }
        if !microphoneAuthorized { stopMicrophoneTest() }
        if !microphoneAuthorized || !accessibilityAuthorized {
            if isBusy { cancelSession(message: "A required permission was removed. Open Settings to restore access.") }
        }
        if secureInputActive && (phase == .starting || phase == .listening) {
            cancelSession(message: "macOS Secure Input interrupted keyboard access. Finish password entry, then try again.")
        }
        updateKeyboardMonitor()
    }

    private func prepareFocusedApplication() {
        guard !quitting, !suspended else { return }
        accessibilityPreparation.prepareFrontmostApplication()
    }

    private func updateKeyboardMonitor(restart: Bool = false) {
        if restart { keyboard.stop() }
        if accessibilityAuthorized && !secureInputActive && !suspended && !quitting {
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
        refreshAutomaticMicrophones(devices: devices.devices, force: true)
        refreshPermissions()
        refreshLoginStatus()
    }

    private func refreshAutomaticMicrophones(devices candidates: [AudioInputDevice], force: Bool = false) {
        guard !quitting else { return }
        displays = DisplayContext.displays
        let snapshots = displays.compactMap { display in
            display.number.map { DisplayMicrophoneDiscovery.Display(id: display.id, number: $0) }
        }
        let topology = snapshots.map { "\($0.id):\($0.number)" }.sorted() + candidates.map(\.id).sorted()
        guard force || topology != matchingTopology else { return }
        matchingTopology = topology
        matchingTask?.cancel()
        automaticMicrophones = automaticMicrophones.filter { id, device in
            snapshots.contains(where: { $0.id == id }) && candidates.contains(where: { $0.id == device })
        }
        matchingMicrophones = true
        matchingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .utility) {
                DisplayMicrophoneDiscovery.discover(displays: snapshots, devices: candidates)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.automaticMicrophones = matches
            self.matchingMicrophones = false
            DictationDiagnostics.session.notice("display_microphones_matched count=\(matches.count) displays=\(snapshots.count)")
        }
    }

    func microphoneSelection(screenID: String?) -> DeviceSelection? {
        DeviceSelection.resolve(devices: devices.devices, settings: settings.value, screenID: screenID,
                                automaticMicrophones: automaticMicrophones)
    }

    func microphoneLabel(_ device: AudioInputDevice) -> String {
        if let index = displays.firstIndex(where: { automaticMicrophones[$0.id] == device.id }) {
            return "Display \(index + 1) microphone"
        }
        return DeviceDisplayName.label(for: device, among: devices.devices)
    }

    func setMicrophoneOverride(_ deviceID: String?, screenID: String) {
        var overrides = settings.value.displayMicrophoneOverrides ?? [:]
        overrides[screenID] = deviceID
        settings.value.displayMicrophoneOverrides = overrides
        settings.value.screenMicrophones[screenID] = nil
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

    func identifyMicrophone(screenID: String?) {
        guard !isBusy, microphoneAuthorized,
              let selected = microphoneSelection(screenID: screenID) else { return }
        testMicrophone(deviceID: selected.device.id, screenID: screenID)
    }

    private func testMicrophone(deviceID: String, screenID: String?) {
        let operation = UUID()
        microphoneTestOperation = operation
        Task { [weak self] in
            guard let self else { return }
            await self.microphoneTester.stopAndWait()
            guard self.microphoneTestOperation == operation, !self.isBusy, !self.suspended,
                  let device = self.devices.devices.first(where: { $0.id == deviceID }) else { return }
            let displayIndex = self.displays.firstIndex(where: { $0.id == screenID })
            let display = displayIndex.map { self.displays[$0] }
            let title = displayIndex.map { "Display \($0 + 1): \(self.displays[$0].name)" } ?? "Microphone test"
            self.microphoneTester.start(deviceID: deviceID)
            self.microphoneTestOverlay.onClose = { [weak self] in self?.stopMicrophoneTest() }
            self.microphoneTestOverlay.show(
                tester: self.microphoneTester, screen: display?.screen,
                displayTitle: title, microphoneTitle: self.microphoneLabel(device),
                canAssign: display != nil && screenID.flatMap { self.automaticMicrophones[$0] } == nil,
                canTryNext: screenID.flatMap { self.automaticMicrophones[$0] } == nil && self.devices.devices.count > 1,
                next: { [weak self] in
                    guard let self, let index = self.devices.devices.firstIndex(where: { $0.id == deviceID }),
                          !self.devices.devices.isEmpty else { return }
                    let nextDevice = self.devices.devices[(index + 1) % self.devices.devices.count]
                    self.testMicrophone(deviceID: nextDevice.id, screenID: screenID)
                },
                assign: { [weak self] in
                    guard let self, let screenID, self.devices.devices.contains(where: { $0.id == deviceID }),
                          self.displays.contains(where: { $0.id == screenID }) else { return }
                    self.setMicrophoneOverride(deviceID, screenID: screenID)
                    self.stopMicrophoneTest()
                    self.message = "Microphone assigned to \(title)."
                },
                stop: { [weak self] in self?.stopMicrophoneTest() }
            )
        }
    }

    func stopMicrophoneTest() {
        microphoneTestOperation = nil
        microphoneTestOverlay.hide()
        microphoneTester.stop()
    }

    private func beginRecording() {
        lastHotkeyDetected = Date()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            message = "\(settings.value.hotkey.title) detected. Focus a text field in another app to dictate."
            DictationDiagnostics.keyboard.notice("settings_hotkey_test_passed")
            return
        }
        guard !isBusy, !quitting, !suspended else {
            DictationDiagnostics.session.notice("start_ignored phase=\(self.phase.title) quitting=\(self.quitting) suspended=\(self.suspended)")
            return
        }
        guard setupComplete else {
            DictationDiagnostics.session.notice("start_blocked microphone=\(self.microphoneAuthorized) accessibility=\(self.accessibilityAuthorized) hotkey=\(self.hotkeyActive) model=\(self.modelReady)")
            showNotice("Open Air Whisper Settings to finish setup.", symbol: "exclamationmark.circle")
            return
        }
        stopMicrophoneTest()
        let screen = DisplayContext.focused()
        guard let selected = microphoneSelection(screenID: screen?.id) else {
            DictationDiagnostics.session.error("start_blocked no_microphone")
            showNotice("No microphone is available. Connect one and try again.", symbol: "mic.slash")
            return
        }
        overlayTask?.cancel()
        message = nil
        sessionSettings = settings.value
        let id = UUID()
        sessionID = id
        startedAt = Date()
        prepareFocusedApplication()
        insertionTarget = InsertionTarget.capture()
        DictationDiagnostics.session.notice("recording_start session=\(id.uuidString) target_pid=\(self.insertionTarget?.processID ?? 0) focus_available=\(self.insertionTarget?.focusedElement != nil) mode=\(self.sessionSettings.pasteMode.rawValue)")
        activeScreen = screen?.screen
        activeMicrophone = microphoneLabel(selected.device)
        DictationDiagnostics.session.notice("microphone_route source=\(String(describing: selected.source)) fallback=\(selected.missingPreferredDevice)")
        phase = .starting
        overlay.showWorking("Getting ready…", detail: "Speak when the waveform appears", screen: activeScreen)
        recorder.onFirstSamples = { [weak self] in
            guard let self, self.sessionID == id, self.phase == .starting else { return }
            DictationDiagnostics.session.notice("first_audio session=\(id.uuidString)")
            self.phase = .listening
            self.overlay.showListening(key: self.sessionSettings.hotkey.title, screen: self.activeScreen)
        }
        recorder.onLevel = { [weak self] level in
            guard let self, self.sessionID == id, self.phase == .listening else { return }
            self.overlay.updateLevel(level)
        }
        recorder.onFailure = { [weak self] problem in
            guard let self, self.sessionID == id else { return }
            DictationDiagnostics.session.error("capture_failure session=\(id.uuidString)")
            self.cancelSession(message: problem)
        }
        recorder.onLimitReached = { [weak self] in
            guard let self, self.sessionID == id else { return }
            DictationDiagnostics.session.notice("recording_limit session=\(id.uuidString)")
            self.finishRecording()
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.microphoneTester.stopAndWait()
                guard self.sessionID == id, !Task.isCancelled else { return }
                try await self.recorder.start(deviceID: selected.device.id, maximumDuration: self.sessionSettings.maximumDuration)
            } catch {
                guard self.sessionID == id, !Task.isCancelled,
                      self.phase == .starting || self.phase == .listening else { return }
                DictationDiagnostics.session.error("capture_start_failed session=\(id.uuidString) code=\((error as NSError).code)")
                self.cancelSession(message: "Microphone could not start: \(error.localizedDescription)")
            }
        }
    }

    private func finishRecording() {
        guard let id = sessionID, phase == .starting || phase == .listening else { return }
        if let startedAt, Date().timeIntervalSince(startedAt) < sessionSettings.minimumDuration {
            DictationDiagnostics.session.notice("recording_too_short session=\(id.uuidString)")
            cancelSession()
            return
        }
        DictationDiagnostics.session.notice("recording_stop session=\(id.uuidString)")
        phase = .stopping
        overlay.showWorking("Finishing up…", detail: "Preparing your recording", screen: activeScreen)
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.recorder.stop()
                guard self.sessionID == id, !Task.isCancelled else { return }
                DictationDiagnostics.session.notice("audio_captured session=\(id.uuidString) duration=\(audio.duration) samples=\(audio.samples.count)")
                guard audio.duration >= 0.15 else {
                    self.completeSession(id: id)
                    self.showNotice("That recording was too short. Wait for Listening, then speak.", symbol: "mic")
                    return
                }
                self.phase = .transcribing
                self.overlay.showWorking("Transcribing…", detail: "Turning your voice into words", screen: self.activeScreen)
                let inferenceStart = ProcessInfo.processInfo.systemUptime
                DictationDiagnostics.session.notice("transcription_start session=\(id.uuidString)")
                let raw = try await self.transcriber.transcribe(audio, language: "en")
                DictationDiagnostics.session.notice("transcription_finished session=\(id.uuidString) seconds=\(ProcessInfo.processInfo.systemUptime - inferenceStart) characters=\(raw.count)")
                guard self.sessionID == id, !Task.isCancelled else { return }
                guard let text = TextCleaner.clean(raw) else {
                    self.completeSession(id: id)
                    DictationDiagnostics.session.notice("no_speech session=\(id.uuidString)")
                    self.showNotice("No speech was recognized.", symbol: "waveform")
                    return
                }
                // Posting an event cannot acknowledge that the destination inserted it.
                // Retain every recognized result, including apparently successful pastes.
                self.transcriptRecovery.retain(text)
                let initialFocusUnavailable = self.insertionTarget?.focusedElement == nil
                let posted = self.insertionTarget.map {
                    self.insertion.insert(text, target: $0, mode: self.sessionSettings.pasteMode,
                                          restoreDelay: self.sessionSettings.restoreDelay)
                } ?? false
                DictationDiagnostics.session.notice("insertion_result session=\(id.uuidString) event_posted=\(posted) delivery_unverified=true")
                self.completeSession(id: id)
                if !posted {
                    let notice = initialFocusUnavailable
                        ? "Copy your words from the Air Whisper menu, then paste into the text field."
                        : "The destination changed. Your words are available under Copy Dictation in the menu."
                    self.showNotice(notice, symbol: "doc.on.clipboard")
                }
            } catch {
                guard self.sessionID == id, !Task.isCancelled else { return }
                DictationDiagnostics.session.error("dictation_failed session=\(id.uuidString) phase=\(self.phase.title) code=\((error as NSError).code)")
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
        DictationDiagnostics.session.notice("session_cancel phase=\(self.phase.title) session=\(self.sessionID?.uuidString ?? "none")")
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
        stopMicrophoneTest()
        keyboard.resetHeldState()
        keyboard.stop()
        message = nil
        transcriptRecovery.clear()
        refreshDevicesAndDisplays()
        if !isBusy && !modelReady && !downloadingModel { prepareModel() }
    }

    func recheckKeyboardAccess() {
        keyboard.stop()
        lastHotkeyDetected = nil
        refreshPermissions()
    }

    func copyLatestTranscript() {
        guard let text = latestTranscript else { return }
        insertion.restoreClipboardNow()
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            DictationDiagnostics.session.notice("recovery_copied")
            message = "Dictation copied. Paste it into the intended field."
        }
    }

    private func showNotice(_ text: String, symbol: String) {
        guard !quitting, !suspended else { return }
        message = text
        overlayTask?.cancel()
        let title = symbol == "doc.on.clipboard" ? "Your dictation is ready" : "Let’s try that again"
        overlay.showNotice(title: title, detail: text, symbol: symbol, screen: activeScreen ?? DisplayContext.focused()?.screen)
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshAutomaticMicrophones(devices: self.devices.devices)
            }
        })
    }

    private func suspend(reason: SuspensionReason) {
        suspensionReasons.insert(reason)
        stopMicrophoneTest()
        cancelSession()
        keyboard.stop()
        hotkeyActive = false
        overlayTask?.cancel()
        displayOverlayTask?.cancel()
        displayOverlays.forEach { $0.hide() }
        overlay.hide()
        transcriptRecovery.clear()
        insertion.restoreClipboardNow()
    }

    private func resume(reason: SuspensionReason) {
        suspensionReasons.remove(reason)
        guard !suspended else { return }
        refreshDevicesAndDisplays()
    }

    func shutdown() async {
        quitting = true
        matchingTask?.cancel()
        stopMicrophoneTest()
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
        models.cancelDownload()
        transcriber.cancel()
        overlay.hide()
        transcriptRecovery.clear()
        insertion.restoreClipboardNow()
        await recorder.cancel()
        await microphoneTester.stopAndWait()
        await transcriber.unload()
    }
}
