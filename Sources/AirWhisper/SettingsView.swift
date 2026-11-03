import SwiftUI
import AirWhisperCore
import AirWhisperAudio
import AirWhisperSpeech

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var devices: AudioDeviceManager
    @ObservedObject var models: ModelManager
    @ObservedObject var microphoneTester: MicrophoneTester
    @State private var showAdvancedMicrophones = false

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
                if controller.isBusy {
                    Button("Cancel Dictation") { controller.cancelSession() }
                }
            }
            if controller.latestTranscript != nil {
                HStack {
                    Text("Your last dictation is available to copy for five minutes.").font(.callout)
                    Spacer()
                    Button("Copy Dictation") { controller.copyLatestTranscript() }
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
                        permissionRow("Accessibility", detail: "Enables the push-to-talk key, detects the target field and inserts dictated text.",
                                      granted: controller.accessibilityAuthorized, action: controller.requestAccessibilityAccess)
                        if !controller.accessibilityAuthorized || !controller.hotkeyActive {
                            Text("After an update, macOS may still trust an older build. Quit Air Whisper, remove its old entry with − in Accessibility and Input Monitoring, then use + to add /Applications/Air Whisper.app again. Enable access and reopen Air Whisper.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !controller.hotkeyActive {
                            Divider()
                            permissionRow("Input Monitoring", detail: "If the hotkey is unavailable after granting Accessibility, allow Input Monitoring, then quit and reopen Air Whisper.",
                                          granted: controller.monitoringAuthorized, action: controller.requestMonitoringAccess)
                        }
                    }.padding(8)
                }
                GroupBox("Keyboard access check") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(controller.hotkeyActive ? "Keyboard listener is enabled" : "Keyboard listener is blocked",
                              systemImage: controller.hotkeyActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(controller.hotkeyActive ? Color.green : Color.orange)
                        if controller.secureInputActive {
                            Text("macOS Secure Input is active. Finish password entry in the other app before testing.")
                        }
                        Text("Hold \(settings.value.hotkey.title) here to test detection. This check does not record audio.")
                        if let detected = controller.lastHotkeyDetected {
                            Text("Shortcut received at \(detected.formatted(date: .omitted, time: .standard)).")
                                .foregroundStyle(.green)
                        }
                        Button("Recheck Keyboard Access") { controller.recheckKeyboardAccess() }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
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
                GroupBox("Microphone") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Use", selection: $settings.value.microphoneMode) {
                            Text("Automatic · follow active display").tag(MicrophoneMode.auto)
                            Text("One microphone everywhere").tag(MicrophoneMode.fixed)
                        }.disabled(microphoneTester.isRunning)
                        if settings.value.microphoneMode == .auto {
                            Text("Uses the microphone built into the display you’re working on. Matching happens automatically.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            microphonePicker("Microphone", selection: Binding(
                                get: { settings.value.fixedDeviceID ?? "" },
                                set: { settings.value.fixedDeviceID = $0.isEmpty ? nil : $0 }))
                            microphoneTestButton(screenID: nil)
                        }
                        if devices.devices.isEmpty {
                            Label("No microphones connected", systemImage: "mic.slash").foregroundStyle(.orange)
                        }
                    }.padding(10)
                }
                if settings.value.microphoneMode == .auto {
                    GroupBox("Your displays") {
                        VStack(alignment: .leading, spacing: 14) {
                            if controller.matchingMicrophones {
                                HStack { ProgressView().controlSize(.small); Text("Finding display microphones…").font(.callout) }
                            }
                            ForEach(Array(controller.displays.enumerated()), id: \.element.id) { index, display in
                                let selection = controller.microphoneSelection(screenID: display.id)
                                DisplayMicrophoneRow(
                                    title: "Display \(index + 1) · \(display.name)",
                                    detail: microphoneRouteDescription(selection),
                                    automatic: selection?.source == .matchedDisplay,
                                    testEnabled: selection != nil && controller.microphoneAuthorized && !microphoneTester.isRunning,
                                    test: { controller.identifyMicrophone(screenID: display.id) })
                                if index < controller.displays.count - 1 { Divider() }
                            }
                            HStack {
                                Button("Identify Displays") { controller.identifyDisplays() }
                                Spacer()
                                Button("Refresh") { controller.refreshDevicesAndDisplays() }
                            }
                        }.padding(10)
                    }
                }
                if microphoneTester.isRunning {
                    GroupBox("Sound check") {
                        VStack(alignment: .leading, spacing: 8) {
                            MicrophoneLevelGraph(levels: microphoneTester.levelHistory).frame(height: 100)
                            HStack {
                                Text("Speak normally to check the input.").foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop") { controller.stopMicrophoneTest() }.disabled(microphoneTester.isStopping)
                            }
                        }.padding(8)
                    }
                }
                DisclosureGroup("Advanced microphone options", isExpanded: $showAdvancedMicrophones) {
                    VStack(alignment: .leading, spacing: 14) {
                        if settings.value.microphoneMode == .auto {
                            microphonePicker("Fallback microphone", selection: Binding(
                                get: { settings.value.fixedDeviceID ?? "" },
                                set: { settings.value.fixedDeviceID = $0.isEmpty ? nil : $0 }))
                            Text("Used when a display has no matched microphone. System default avoids Bluetooth when a built-in microphone is available.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(controller.displays.enumerated()), id: \.element.id) { index, display in
                                microphonePicker("Display \(index + 1) override", selection: Binding(
                                    get: { settings.value.displayMicrophoneOverrides?[display.id] ?? "" },
                                    set: { controller.setMicrophoneOverride($0.isEmpty ? nil : $0, screenID: display.id) }
                                ), defaultTitle: "Automatic")
                            }
                            Text("Choose an override only if you prefer a different microphone for that display.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Refresh devices") { controller.refreshDevicesAndDisplays() }
                    }.padding(.top, 12)
                }.padding(8)
            }.padding(14).disabled(controller.isBusy)
        }.onDisappear { controller.stopMicrophoneTest() }
    }

    private func microphoneRouteDescription(_ selection: DeviceSelection?) -> String {
        guard let selection else { return "No microphone available" }
        switch selection.source {
        case .matchedDisplay: return "Built-in microphone · matched automatically"
        case .assignedDisplay: return "Custom · \(controller.microphoneLabel(selection.device))"
        case .fallback, .systemDefault: return "Fallback · \(controller.microphoneLabel(selection.device))"
        }
    }

    private func microphoneTestButton(screenID: String?) -> some View {
        Button("Test Microphone…") { controller.identifyMicrophone(screenID: screenID) }
            .disabled(controller.microphoneSelection(screenID: screenID) == nil || !controller.microphoneAuthorized || microphoneTester.isRunning)
    }

    private func microphonePicker(_ title: String, selection: Binding<String>, defaultTitle: String = "System default") -> some View {
        Picker(title, selection: selection) {
            Text(defaultTitle).tag("")
            ForEach(devices.devices) { device in
                Text(controller.microphoneLabel(device) + (device.isDefault ? " (system default)" : "")).tag(device.id)
            }
            if !selection.wrappedValue.isEmpty, !devices.devices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Saved microphone — disconnected").tag(selection.wrappedValue)
            }
        }
        .disabled(microphoneTester.isRunning)
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

struct DisplayMicrophoneRow: View {
    let title: String
    let detail: String
    let automatic: Bool
    let testEnabled: Bool
    let test: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "display").font(.system(size: 25)).foregroundStyle(.teal)
                .frame(width: 44, height: 44).background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if automatic { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal).accessibilityLabel("Matched automatically") }
            Button("Test…", action: test).disabled(!testEnabled)
        }
    }
}
