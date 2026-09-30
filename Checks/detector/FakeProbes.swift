import Foundation

// Scripted stand-ins for AudioProbe and CameraProbe, so CallDetector's real
// decision logic can run anywhere. The fakes return processes already
// resolved to their owning app, as AudioProbe does on the Mac.

struct MicUser: Equatable, Hashable {
    let pid: pid_t
    let rawBundleID: String?
    let appBundleID: String?
    let executablePath: String?
    let name: String
}

struct Span {
    let from: Double, to: Double
    let user: MicUser
}

enum Script {
    static var start = Date()
    static var elapsed: Double { Date().timeIntervalSince(start) }
    static var spans: [Span] = []
    static func users() -> [MicUser] {
        let t = elapsed
        return spans.filter { t >= $0.from && t < $0.to }.map(\.user)
    }
}

enum AudioProbe {
    static func activeInputProcesses() -> [MicUser]? { Script.users() }
    static func anyInputRunning() -> Bool { !Script.users().isEmpty }
}

enum CameraProbe {
    static func anyCameraRunning() -> Bool { false }
}
