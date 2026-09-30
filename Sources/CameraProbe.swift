import CoreMediaIO
import Foundation

/// Whether any camera is currently streaming. Used to corroborate the
/// microphone signal — a live camera is a strong second vote for "in a call".
enum CameraProbe {

    static func anyCameraRunning() -> Bool {
        cameraDevices().contains { isRunning($0) }
    }

    private static let system = CMIOObjectID(kCMIOObjectSystemObject)

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        // the list can shrink between the two calls
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.stride))
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var addr = address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &value) == noErr else { return false }
        return value != 0
    }
}
