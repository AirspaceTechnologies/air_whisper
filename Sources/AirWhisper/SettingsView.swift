import SwiftUI
import AirWhisperCore
import AirWhisperAudio
import AirWhisperSpeech
import AirWhisperLLM

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var devices: AudioDeviceManager
    @ObservedObject var models: ModelManager
    @ObservedObject var cleanupModels: LLMModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 40)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Air Whisper").font(.title2.bold())
                    Text(controller.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer()
                if controller.isBusy {
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
            TabView {
                setupTab.tabItem { Label("Setup", systemImage: "checkmark.shield") }
                microphoneTab.tabItem { Label("Microphones", systemImage: "mic") }
                preferencesTab.tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }
            }
            Text("Audio stays in memory and is transcribed on this Mac. Air Whisper keeps no recording or transcript history.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 690, minHeight: 640, idealHeight: 690)
        .onAppear { controller.refreshDevicesAndDisplays() }
    }

    private var setupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 14) {
                        permissionRow("Microphone", detail: "Records only while you hold the push-to-talk key.",
                                      granted: controller.microphoneAuthorized, action: controller.requestMicrophoneAccess)
                        Divider()
                        permissionRow("Accessibility", detail: "Detects the target field and inserts dictated text.",
                                      granted: controller.accessibilityAuthorized, action: controller.requestAccessibilityAccess)
                        if !controller.hotkeyActive {
                            Divider()
                            permissionRow("Keyboard monitoring", detail: "If the hotkey is unavailable after granting Accessibility, allow Input Monitoring and reopen Air Whisper.",
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
                GroupBox("Start dictating") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Focus a text field in another app.")
                        Text("2. Hold \(settings.value.hotkey.title), wait for “Listening”, then speak.")
                        Text("3. Release the key to transcribe and insert your words.")
                        Text("Pressing another key while holding push-to-talk cancels the recording. Keep the target field focused until insertion finishes.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Microphone selection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Choose microphone", selection: $settings.value.microphoneMode) {
                            Text("Follow focused display").tag(MicrophoneMode.auto)
                            Text("Use one microphone").tag(MicrophoneMode.fixed)
                        }
                        microphonePicker(settings.value.microphoneMode == .auto ? "Fallback microphone" : "Microphone",
                                         selection: Binding(get: { settings.value.fixedDeviceID ?? "" }, set: { settings.value.fixedDeviceID = $0.isEmpty ? nil : $0 }))
                        Text("System default automatically prefers the built-in microphone when the default is a Bluetooth headset. An explicit choice always wins.")
                            .font(.caption).foregroundStyle(.secondary)
                        if devices.devices.isEmpty {
                            Label("No microphones found. Connect a microphone, then refresh.", systemImage: "mic.slash")
                                .foregroundStyle(.orange)
                        }
                    }.padding(8)
                }
                if settings.value.microphoneMode == .auto {
                    GroupBox("Assign a microphone to each display") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Choose once for each display. Air Whisper remembers the device identity even when connection order changes.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(Array(controller.displays.enumerated()), id: \.element.id) { index, display in
                                microphonePicker("Display \(index + 1): \(display.name)", selection: Binding(
                                    get: { settings.value.screenMicrophones[display.id] ?? "" },
                                    set: { settings.value.screenMicrophones[display.id] = $0.isEmpty ? nil : $0 }
                                ), defaultTitle: "Use fallback microphone")
                            }
                            Button("Identify Displays") { controller.identifyDisplays() }
                            Text("A missing assigned microphone falls back to your choice above. Identical displays need an explicit assignment; old numbered microphone labels are not imported.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                }
                Button("Refresh Microphones and Displays") { controller.refreshDevicesAndDisplays() }
            }.padding(14).disabled(controller.isBusy)
        }
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
                GroupBox("AI cleanup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Clean up dictated text with a local AI model", isOn: Binding(
                            get: { settings.value.cleanupEnabled },
                            set: { settings.value.cleanupEnabled = $0 }
                        )).disabled(controller.isBusy)
                        Text("Adjusts punctuation and capitalization and removes hesitation sounds after transcription. Runs entirely on this Mac using a small local model; nothing is sent anywhere.")
                            .font(.callout).foregroundStyle(.secondary)
                        if settings.value.cleanupEnabled {
                            if controller.downloadingCleanupModel {
                                if let progress = cleanupModels.progress { ProgressView(value: progress) }
                                else { ProgressView().controlSize(.small) }
                                HStack {
                                    Text(cleanupModels.status).font(.callout)
                                    Spacer()
                                    Button("Cancel Download") { controller.cancelCleanupModelDownload() }
                                }
                            } else if controller.preparingCleanupModel {
                                HStack { ProgressView().controlSize(.small); Text("Verifying and loading cleanup model…") }
                            } else {
                                HStack {
                                    Label(controller.cleanupModelReady ? "Cleanup model ready" : "Cleanup model required",
                                          systemImage: controller.cleanupModelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                                        .foregroundStyle(controller.cleanupModelReady ? Color.green : Color.secondary)
                                    Spacer()
                                    Button(controller.currentCleanupModelURL == nil ? "Download Cleanup Model" : "Download Again") { controller.downloadCleanupModel() }
                                }.disabled(controller.isBusy)
                            }
                            Text("Qwen2.5 1.5B Instruct · about 1 GB. Edits that change words or exceed the time or length limit are rejected. The original transcript is used if cleanup is unavailable or fails.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                Button("Reset Dictation and Refresh Devices") { controller.reset() }
            }.padding(14)
        }
    }
}
