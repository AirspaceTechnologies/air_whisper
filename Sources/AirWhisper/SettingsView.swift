import SwiftUI
import AirWhisperCore
import AirWhisperAudio
import AirWhisperSpeech

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var devices: AudioDeviceManager
    @ObservedObject var models: ModelManager
    @ObservedObject private var microphoneTest: MicrophoneTestController
    @State private var selectedTab = SettingsTab.setup
    @State private var testRow: MicrophoneTestRow?
    @State private var candidateID: String?

    private enum SettingsTab: Hashable { case setup, microphones, preferences }

    init(controller: AppController, settings: SettingsStore, devices: AudioDeviceManager, models: ModelManager) {
        self.controller = controller
        self.settings = settings
        self.devices = devices
        self.models = models
        _microphoneTest = ObservedObject(wrappedValue: controller.microphoneTest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 40)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Air Whisper").font(.title2.bold())
                    Text(AppVersion.detail).font(.caption).foregroundStyle(.secondary)
                    Text(controller.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                if microphoneTest.isBusy {
                    Button("Cancel Test") { microphoneTest.cancel() }
                } else if controller.isBusy {
                    Button("Cancel Dictation") { controller.cancelSession() }
                }
            }
            if controller.pendingTranscript != nil {
                HStack {
                    Text("Dictation is waiting to be copied. It expires after five minutes.").font(.callout)
                    Spacer()
                    Button("Copy Dictation") { controller.copyPendingTranscript() }
                }.padding(10).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            TabView(selection: $selectedTab) {
                setupTab.tabItem { Label("Setup", systemImage: "checkmark.shield") }.tag(SettingsTab.setup)
                microphoneTab.tabItem { Label("Microphones", systemImage: "mic") }.tag(SettingsTab.microphones)
                preferencesTab.tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }.tag(SettingsTab.preferences)
            }
            Text("Audio and test results stay in memory on this Mac. Air Whisper saves no recording or transcript history.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 690, minHeight: 640, idealHeight: 690)
        .onAppear { controller.refreshDevicesAndDisplays() }
        .onChange(of: selectedTab) { tab in
            if tab != .microphones { clearMicrophoneTestContext() }
        }
        .onChange(of: settings.value.microphoneMode) { _ in clearMicrophoneTestContext() }
        .onDisappear { controller.microphoneTestContextChanged() }
    }

    private var setupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 14) {
                        permissionRow("Microphone", detail: "Listens while you hold push-to-talk or explicitly run a microphone test.",
                                      granted: controller.microphoneAuthorized, action: controller.requestMicrophoneAccess)
                        Divider()
                        permissionRow("Accessibility", detail: "Enables the push-to-talk key, detects the target field and inserts dictated text.",
                                      granted: controller.accessibilityAuthorized, action: controller.requestAccessibilityAccess)
                        if !controller.accessibilityAuthorized {
                            Text("If macOS already shows Air Whisper as enabled after an update, quit Air Whisper, remove its Accessibility entry with −, then use + to add the installed app again. Enable access and reopen Air Whisper.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !controller.hotkeyActive {
                            Divider()
                            permissionRow("Input Monitoring", detail: "If the hotkey is unavailable after granting Accessibility, allow Input Monitoring, then quit and reopen Air Whisper.",
                                          granted: controller.monitoringAuthorized, action: controller.requestMonitoringAccess)
                        }
                    }.padding(8)
                }
                GroupBox("Transcription model") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Model", selection: Binding(get: { settings.value.model }, set: controller.selectModel)) {
                            Text("Small English · about 488 MB").tag(SpeechModel.smallEnglish)
                            Text("Medium English · about 1.5 GB").tag(SpeechModel.mediumEnglish)
                        }.disabled(controller.isBusy || controller.downloadingModel)
                        Text("Small English is a good starting point. Medium English uses more memory and takes longer to transcribe.")
                            .font(.callout).foregroundStyle(.secondary)
                        if controller.downloadingModel {
                            if let progress = models.progress { ProgressView(value: progress) }
                            else { ProgressView().controlSize(.small) }
                            HStack {
                                Text(models.status).font(.callout)
                                Spacer()
                                Button("Cancel Download") { controller.cancelModelDownload() }
                            }
                        } else if controller.preparingModel {
                            HStack { ProgressView().controlSize(.small); Text("Verifying and loading model…") }
                        } else {
                            HStack {
                                Label(controller.modelReady ? "Model ready" : "Model required",
                                      systemImage: controller.modelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .foregroundStyle(controller.modelReady ? Color.green : Color.secondary)
                                Spacer()
                                Button(controller.currentModelURL == nil ? "Download Model" : "Download Again") { controller.downloadModel() }
                                Button("Use Existing File…") { controller.chooseExistingModel() }
                            }.disabled(controller.isBusy)
                        }
                        Text("The first download needs internet access. Dictation works offline after setup. Existing models in ~/.dictate/models are also detected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Check your microphone") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("See the input level, identify a display's microphone, and try a short transcription before dictating.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Microphone Tests") { selectedTab = .microphones }
                        Text("The level meter only needs Microphone access. A transcription test also needs a ready model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("Finish with a real dictation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Focus a text field in another app.")
                        Text("2. Hold \(settings.value.hotkey.title), wait for “Listening”, then speak.")
                        Text("3. Release the key to transcribe and insert your words.")
                        Text("Pressing another key while holding push-to-talk cancels the recording. Keep the target field focused until insertion finishes.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        Text("The microphone test checks sound and transcription. This final step also checks your hotkey and text insertion in the app you use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(14)
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(granted ? "Open Settings" : "Allow…", action: action)
        }
    }

    private var microphoneTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Microphone selection") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Choose microphone", selection: $settings.value.microphoneMode) {
                                Text("Follow focused display").tag(MicrophoneMode.auto)
                                Text("Use one microphone").tag(MicrophoneMode.fixed)
                            }
                            microphoneRouteRow(
                                settings.value.microphoneMode == .auto ? "Fallback microphone" : "Microphone",
                                selection: Binding(get: { settings.value.fixedDeviceID ?? "" }, set: {
                                    clearMicrophoneTestContext()
                                    settings.value.fixedDeviceID = $0.isEmpty ? nil : $0
                                }),
                                row: settings.value.microphoneMode == .auto ? .fallback : .fixed,
                                proxy: proxy
                            )
                            Text("Automatic selection prefers the built-in microphone when the system default is a Bluetooth headset. An explicit choice always wins.")
                                .font(.caption).foregroundStyle(.secondary)
                            if devices.devices.isEmpty {
                                Label("No microphones found. Connect a microphone, then refresh.", systemImage: "mic.slash")
                                    .foregroundStyle(.orange)
                            }
                        }.padding(8)
                    }.disabled(controller.isBusy)
                    if settings.value.microphoneMode == .auto {
                        GroupBox("Assign a microphone to each display") {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Text("Identify your displays, then test a microphone near each one before assigning it.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Identify Displays") { controller.identifyDisplays() }
                                }
                                ForEach(Array(controller.displays.enumerated()), id: \.element.id) { index, display in
                                    microphoneRouteRow("Display \(index + 1): \(display.name)", selection: Binding(
                                        get: { settings.value.screenMicrophones[display.id] ?? "" },
                                        set: {
                                            clearMicrophoneTestContext()
                                            settings.value.screenMicrophones[display.id] = $0.isEmpty ? nil : $0
                                        }
                                    ), defaultTitle: "Use fallback microphone", row: .display(display.id), proxy: proxy)
                                }
                                Text("Assignments use stable device identities. The letters beside same-named microphones distinguish devices, not their physical positions.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }.disabled(controller.isBusy)
                    }
                    Group {
                        if let testRow {
                            MicrophoneTestPanel(controller: controller, test: microphoneTest, devices: devices,
                                                row: testRow, rowTitle: title(for: testRow),
                                                savedCandidateID: savedCandidate(for: testRow),
                                                candidateID: $candidateID,
                                                showSetup: { selectedTab = .setup })
                        } else {
                            GroupBox("Test microphone") {
                                Text("Choose Test beside a microphone or display above. Check its input level, then record a short transcription test.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                    }.id("microphone-test")
                    Button("Refresh Microphones and Displays") { controller.refreshDevicesAndDisplays() }
                        .disabled(controller.isBusy)
                }.padding(14)
            }
        }
    }

    private func microphoneRouteRow(_ title: String, selection: Binding<String>, defaultTitle: String = "Automatic",
                                    row: MicrophoneTestRow, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                microphonePicker(title, selection: selection, defaultTitle: defaultTitle)
                Button("Test") {
                    controller.microphoneTestContextChanged()
                    testRow = row
                    candidateID = savedCandidate(for: row)
                    withAnimation { proxy.scrollTo("microphone-test", anchor: .top) }
                }.accessibilityLabel("Test \(title)")
            }
            if let resolved = controller.resolvedMicrophone(for: row) {
                Text("Uses \(resolved.name)").font(.caption)
                if let reason = resolved.fallbackReason {
                    Label(reason, systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("No available microphone", systemImage: "mic.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func savedCandidate(for row: MicrophoneTestRow) -> String? {
        switch row {
        case .display(let id): return settings.value.screenMicrophones[id]
        case .fallback, .fixed: return settings.value.fixedDeviceID
        }
    }

    private func title(for row: MicrophoneTestRow) -> String {
        switch row {
        case .display(let id):
            guard let index = controller.displays.firstIndex(where: { $0.id == id }) else { return "Disconnected display" }
            return "Display \(index + 1): \(controller.displays[index].name)"
        case .fallback: return "Fallback microphone"
        case .fixed: return "Fixed microphone"
        }
    }

    private func clearMicrophoneTestContext() {
        controller.microphoneTestContextChanged()
        testRow = nil
        candidateID = nil
    }

    private func microphonePicker(_ title: String, selection: Binding<String>, defaultTitle: String = "System default") -> some View {
        Picker(title, selection: selection) {
            Text(defaultTitle).tag("")
            ForEach(devices.devices) { device in
                Text(DeviceDisplayName.label(for: device, among: devices.devices) + (device.isDefault ? " (system default)" : "")).tag(device.id)
            }
            if !selection.wrappedValue.isEmpty, !devices.devices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Saved microphone — disconnected").tag(selection.wrappedValue)
            }
        }
    }

    private var preferencesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Push to talk") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Hold this key", selection: $settings.value.hotkey) {
                            ForEach(PushToTalkKey.allCases, id: \.self) { key in Text(key.title).tag(key) }
                        }.disabled(controller.isBusy)
                        if settings.value.hotkey == .fn {
                            Text("In macOS Keyboard settings, set “Press 🌐 key to” to “Do Nothing” to avoid opening emoji or system dictation. Some keyboards handle Fn internally; choose a right-side modifier if Fn is not detected.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Open Keyboard Settings") { controller.openKeyboardSettings() }
                        }
                        Text("Short taps are ignored. Recording stops automatically after \(Int(settings.value.maximumDuration)) seconds.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Text insertion") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Insert using", selection: $settings.value.pasteMode) {
                            Text("Clipboard paste").tag(PasteMode.clipboard)
                            Text("Simulated typing").tag(PasteMode.keystrokes)
                        }.disabled(controller.isBusy)
                        Text("Clipboard paste temporarily copies the text and restores previous clipboard items unless you copy something else. Simulated typing leaves the clipboard alone.")
                            .font(.caption).foregroundStyle(.secondary)
                        if settings.value.pasteMode == .clipboard {
                            HStack {
                                Text("Clipboard restore delay")
                                Slider(value: $settings.value.restoreDelay, in: 0.2...2.0, step: 0.1).frame(maxWidth: 160)
                                Text(String(format: "%.1f s", settings.value.restoreDelay)).monospacedDigit().frame(width: 45)
                            }
                            Text("Increase the delay if an app occasionally pastes the previous clipboard contents.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Launch Air Whisper at login", isOn: Binding(get: { controller.loginEnabled }, set: controller.setLaunchAtLogin))
                        if controller.loginNeedsApproval {
                            Button("Approve in Login Items Settings…") { controller.openLoginSettings() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Button("Reset Dictation and Refresh Devices") { controller.reset() }
            }.padding(14)
        }
    }
}
