import SwiftUI
import AirWhisperCore
import AirWhisperAudio

struct MicrophoneTestPanel: View {
    @ObservedObject var controller: AppController
    @ObservedObject var test: MicrophoneTestController
    @ObservedObject var devices: AudioDeviceManager
    let row: MicrophoneTestRow
    let rowTitle: String
    let savedCandidateID: String?
    @Binding var candidateID: String?
    let showSetup: () -> Void

    private var resolution: MicrophoneTestResolution? {
        controller.resolvedMicrophone(for: row, candidateID: candidateID)
    }

    private var candidateSelection: Binding<String> {
        Binding(get: { candidateID ?? "" }, set: { value in
            controller.microphoneTestContextChanged()
            candidateID = value.isEmpty ? nil : value
        })
    }

    private var isReceiving: Bool { test.phase == .metering || test.phase == .recording }
    private var meterValue: Double { isReceiving ? test.level.normalized : 0 }
    private var levelDescription: String {
        guard isReceiving else { return "Input meter off" }
        if test.level.isClipping { return "High input level — try speaking more softly or moving farther away" }
        return test.level.hasSignal ? "Receiving sound" : "No input signal — speak near this microphone"
    }

    private var microphoneName: String {
        if !test.actualMicrophone.isEmpty, test.isBusy || test.hasRecording || test.transcript != nil {
            return test.actualMicrophone
        }
        return resolution?.name ?? "Selected microphone is unavailable"
    }

    private var microphoneCaption: String {
        if test.hasRecording { return "Recorded with" }
        return test.isBusy ? "Using" : "Selected input"
    }

    private var assignmentTitle: String {
        switch row {
        case .display: return "Use for This Display"
        case .fallback: return "Use as Fallback"
        case .fixed: return "Use This Microphone"
        }
    }

    var body: some View {
        GroupBox("Test microphone") {
            VStack(alignment: .leading, spacing: 12) {
                Text(rowTitle).font(.headline)
                HStack {
                    Picker("Microphone to test", selection: candidateSelection) {
                        Text("Automatic for this selection").tag("")
                        ForEach(devices.devices) { device in
                            Text(DeviceDisplayName.label(for: device, among: devices.devices)).tag(device.id)
                        }
                        if let candidateID, !devices.devices.contains(where: { $0.id == candidateID }) {
                            Text("Selected microphone — disconnected").tag(candidateID)
                        }
                    }
                    Button(assignmentTitle) { controller.applyMicrophoneCandidate(candidateID, to: row) }
                        .disabled(resolution == nil || candidateID == savedCandidateID)
                }.disabled(controller.isBusy)
                Text("\(microphoneCaption): \(microphoneName)").font(.callout).fontWeight(.medium)
                    .textSelection(.enabled)
                if let reason = test.isBusy ? test.fallbackReason : resolution?.fallbackReason {
                    Label(reason, systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Try a microphone and speak near it to identify its physical location. Choosing a test device does not change your assignment until you select \(assignmentTitle).")
                    .font(.caption).foregroundStyle(.secondary)
                if resolution?.device.isBluetooth == true {
                    Text("Using a Bluetooth microphone can affect headphone playback quality while the test is running.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: meterValue)
                        .tint(test.level.isClipping ? Color.orange : Color.accentColor)
                        .animation(.linear(duration: 0.1), value: meterValue)
                        .accessibilityLabel("Microphone input level")
                        .accessibilityValue(isReceiving ? "\(Int(meterValue * 100)) percent. \(levelDescription)" : "Off")
                    Text(levelDescription).font(.caption).foregroundStyle(.secondary)
                    if isReceiving {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(test.startedAt ?? context.date))
                            Text("\(test.phase == .recording ? "Recording" : "Checking input"): \(Int(min(elapsed, test.maximumDuration))) / \(Int(test.maximumDuration)) seconds")
                                .font(.caption).monospacedDigit()
                        }
                    }
                }

                controls

                if !controller.microphoneAuthorized {
                    HStack {
                        Text("Allow Microphone access to check this input.").font(.callout)
                        Spacer()
                        Button("Allow Microphone…") { controller.requestMicrophoneAccess() }
                    }
                }
                if !controller.modelReady {
                    HStack {
                        Text(controller.preparingModel || controller.downloadingModel
                             ? "The model is getting ready. You can check the input level now."
                             : "A transcription model is needed to record and transcribe a test. The level meter works without one.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Model Setup…", action: showSetup)
                    }
                }
                if let message = test.message {
                    Label(message, systemImage: "info.circle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let transcript = test.transcript {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recognized text").font(.subheadline).fontWeight(.medium)
                        ScrollView {
                            Text(transcript).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 60, maxHeight: 130)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Record Test captures up to 10 seconds and shows the words here without pasting. Audio and results clear after five idle minutes, when you change tabs or apps, or when Settings is minimized or closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch test.phase {
        case .idle:
            HStack {
                Button("Start Level Meter") { start(record: false) }
                    .disabled(controller.isBusy || !controller.microphoneAuthorized || resolution == nil)
                Button(test.hasRecording ? "Try Again" : "Record Test") { start(record: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isBusy || !controller.microphoneAuthorized || !controller.modelReady || resolution == nil)
                if test.hasRecording {
                    Button("Play Recording") { test.play() }.disabled(controller.isBusy)
                }
                if test.hasRecording || test.transcript != nil || test.message != nil {
                    Button("Clear") { test.clear() }
                }
            }
        case .metering:
            HStack {
                Button("Stop Level Meter") { test.stop() }.buttonStyle(.borderedProminent)
                Text("The meter checks input without keeping a recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .recording:
            HStack {
                Button("Stop and Transcribe") { test.stop() }.buttonStyle(.borderedProminent)
                Button("Cancel") { test.cancel() }
            }
        case .playing:
            HStack {
                Button("Stop Playback") { test.stop() }
                Text("Playing your test recording").font(.callout)
            }
        case .starting, .stopping, .transcribing, .cancelling:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progressTitle).font(.callout)
                Spacer()
                Button("Cancel") { test.cancel() }
            }
        }
    }

    private var progressTitle: String {
        switch test.phase {
        case .starting: return "Opening microphone…"
        case .stopping: return "Closing microphone…"
        case .transcribing: return "Transcribing on this Mac…"
        case .cancelling: return "Stopping test…"
        default: return ""
        }
    }

    private func start(record: Bool) {
        controller.startMicrophoneTest(row: row, candidateID: candidateID, record: record)
    }
}
