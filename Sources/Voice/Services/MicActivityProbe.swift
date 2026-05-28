// MicActivityProbe.swift
// Thin wrapper around CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`
// to check whether any process on the system is actively using the default
// input device. This is a system-wide signal — it does NOT tell us which
// process, just that *something* is reading the mic.

import Foundation
import CoreAudio

enum MicActivityProbe {

    /// Returns true iff the default input device's IOProc is running somewhere
    /// in the system (i.e., some process has it open and is reading samples).
    /// Returns false if the device can't be queried.
    static func isDefaultInputInUse() -> Bool {
        guard let deviceID = defaultInputDeviceID() else { return false }
        return isDeviceRunningSomewhere(deviceID)
    }

    // MARK: - Internals

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func isDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            &size,
            &running
        )
        guard status == noErr else { return false }
        return running != 0
    }
}
