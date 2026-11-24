import CoreAudio
import Foundation

/// Reads CoreAudio hardware status to detect whether any microphone input device
/// on this Mac is currently active (Zoom, Google Meet, Teams, Slack, FaceTime, etc.).
/// Does NOT capture audio and does NOT require microphone recording permission.
public protocol CallActivitySource: Sendable {
    func isMicrophoneActive() -> Bool
}

public struct CoreAudioMicrophoneMonitor: CallActivitySource, Sendable {
    public init() {}

    public func isMicrophoneActive() -> Bool {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return false
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &devices
        ) == noErr else {
            return false
        }

        for device in devices where hasInputStreams(device) {
            if isRunningSomewhere(device) {
                return true
            }
        }
        return false
    }

    private func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &size)
        return status == noErr && size > 0
    }

    private func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}
