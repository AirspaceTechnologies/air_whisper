import AirWhisperCore
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Enumerates device metadata only. Discovery never creates a capture input or requests access.
@MainActor
public final class AudioDeviceManager: ObservableObject {
    @Published public private(set) var devices: [AudioInputDevice] = []

    private var observers: [NSObjectProtocol] = []
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    public init() {
        let center = NotificationCenter.default
        for notification in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        var address = Self.defaultInputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            defaultListener = listener
        }
        refresh()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let listener = defaultListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    public func refresh() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        var seen = Set<String>()
        devices = discovery.devices.filter { $0.isConnected && seen.insert($0.uniqueID).inserted }.map { device in
            let transport = UInt32(bitPattern: device.transportType)
            return AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
