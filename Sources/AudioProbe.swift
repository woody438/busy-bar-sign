import AppKit
import CoreAudio
import Foundation

/// One process currently holding an audio input stream.
struct MicUser: Equatable, Hashable {
    let pid: pid_t
    let bundleID: String?
    let name: String
}

/// Reads CoreAudio's process objects (macOS 14.4+) to find out *which*
/// applications have the microphone open — not merely that something does.
///
/// If the process-object API returns nothing usable, callers should fall back
/// to `anyInputRunning()`, which only reports that the default input device is
/// live and cannot attribute it to an app.
enum AudioProbe {

    // MARK: - Process-level (preferred)

    static func activeInputProcesses() -> [MicUser] {
        var users: [MicUser] = []
        for object in processObjects() {
            guard boolProperty(object, kAudioProcessPropertyIsRunningInput) == true else { continue }
            let pid = int32Property(object, kAudioProcessPropertyPID) ?? -1
            let bundle = stringProperty(object, kAudioProcessPropertyBundleID)
            users.append(MicUser(pid: pid, bundleID: bundle, name: displayName(pid: pid, bundleID: bundle)))
        }
        return users
    }

    /// True when the process-object API is answering at all.
    static var supportsProcessAttribution: Bool { !processObjects().isEmpty }

    // MARK: - Device-level (fallback)

    /// Whether the default input device is running for *anyone*.
    /// No attribution — dictation looks identical to a call here.
    static func anyInputRunning() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        return boolProperty(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? false
    }

    // MARK: - CoreAudio plumbing

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDevice() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func int32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if pid > 0, let app = NSRunningApplicationShim.name(forPID: pid) { return app }
        if let bundleID { return bundleID }
        return "Unknown"
    }
}

private enum NSRunningApplicationShim {
    static func name(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}
