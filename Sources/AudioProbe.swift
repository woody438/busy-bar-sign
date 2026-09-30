import AppKit
import CoreAudio
import Darwin
import Foundation

/// One process currently holding an audio input stream, and the app it belongs to.
struct MicUser: Equatable, Hashable {
    let pid: pid_t
    /// As CoreAudio reports it. Often a helper: Chrome, Slack and other
    /// Electron apps capture audio in `<app>.helper` processes.
    let rawBundleID: String?
    /// The app that owns the process — the outermost .app bundle it runs from.
    let appBundleID: String?
    let executablePath: String?
    let name: String
}

/// Reads CoreAudio's process objects (macOS 14.2+) to find out *which*
/// applications have the microphone open — not merely that something does.
///
/// If the process-object API doesn't answer, `activeInputProcesses()` returns
/// nil and callers fall back to `anyInputRunning()`, which only reports that
/// the default input device is live and can't say who's using it.
enum AudioProbe {

    // MARK: - Process-level (preferred)

    /// Processes with input running, or nil when the API isn't answering.
    static func activeInputProcesses() -> [MicUser]? {
        guard let objects = processObjects() else { return nil }
        var users: [MicUser] = []
        for object in objects {
            guard boolProperty(object, kAudioProcessPropertyIsRunningInput) == true else { continue }
            let pid = int32Property(object, kAudioProcessPropertyPID) ?? -1
            let raw = stringProperty(object, kAudioProcessPropertyBundleID)
            users.append(Owner.resolve(pid: pid, rawBundleID: raw))
        }
        return users
    }

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

    private static func processObjects() -> [AudioObjectID]? {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        // the list can shrink between the two calls
        return ids.prefix(Int(size) / stride).filter { $0 != 0 }
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

    /// CoreAudio hands back a retained CFString; the caller releases it.
    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }
}

/// Works out which app a process belongs to, so a browser's or Electron
/// app's audio helper is counted — and ignored — as the app itself.
private enum Owner {
    static func resolve(pid: pid_t, rawBundleID: String?) -> MicUser {
        let path = executablePath(pid)
        if let path, let appPath = AppPath.outermostApp(path),
           let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            return MicUser(pid: pid, rawBundleID: rawBundleID, appBundleID: id, executablePath: path, name: name)
        }
        // Not inside an app bundle: a system service, an XPC service, a tool.
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? path.map { ($0 as NSString).lastPathComponent }
            ?? rawBundleID ?? "pid \(pid)"
        return MicUser(pid: pid, rawBundleID: rawBundleID, appBundleID: rawBundleID, executablePath: path, name: name)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
