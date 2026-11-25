import Foundation

/*
 * What a control's name says about the camera, for the Camera key
 * (CameraKey) and for reading Teams' own camera button (MeetingEngine).
 * Foundation only, with MeetingTree's attributes: Checks/meeting and
 * Checks/camerakey try them anywhere Swift runs.
 */

/// What a control's name says about the camera: on now (pressing turns it
/// off), off now, or just "Camera", a toggle whose state is read from it.
enum CameraLabels {
    enum Reading: Equatable { case on, off, toggle }

    /// Words that mean a control is about something else: settings, effects,
    /// choosing a camera, or starting a call.
    static let never: Set<String> = [
        "setting", "settings", "option", "options", "effect", "effects", "background", "backgrounds", "blur",
        "filter", "filters", "choose", "select", "switch", "preview", "share", "sharing", "studio", "portrait",
        "center", "centre", "stage", "reaction", "reactions", "gesture", "gestures", "mirror", "resolution", "quality",
        "spotlight", "pin", "layout", "gallery", "speaker", "call", "calls", "meeting", "record", "recording",
        "capture", "screen", "photo", "snapshot", "more", "device", "devices", "source", "sources", "hd", "facetime"
    ]

    /// Named for what pressing it does: the camera's on now.
    static let turnsOff: Set<String> = [
        "turn off camera", "turn camera off", "turn off your camera", "turn your camera off", "turn off video",
        "turn video off", "stop video", "stop my video", "stop camera", "disable camera", "disable video", "hide video"
    ]
    /// ...the camera's off now.
    static let turnsOn: Set<String> = [
        "turn on camera", "turn camera on", "turn on your camera", "turn your camera on", "turn on video",
        "turn video on", "start video", "start my video", "start camera", "enable camera", "enable video", "show video"
    ]
    /// Named for the camera alone: a toggle, read by whether it shows it's on.
    static let toggles: Set<String> = [
        "camera", "video", "camera on", "camera off", "video on", "video off", "toggle camera", "toggle video"
    ]

    /// A name as compared: lower case, without a shortcut in brackets ("Turn
    /// off camera (⌘ + e)", "Turn camera off (⌘⇧O)") or after a comma, and
    /// with anything but letters as single spaces.
    static func normalise(_ label: String) -> String {
        var s = label.lowercased()
        for cut in ["(", ",", " – ", " - ", "\n"] {
            if let r = s.range(of: cut) { s = String(s[..<r.lowerBound]) }
        }
        let letters = s.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// What a control's name says, or nil if it isn't the camera's on/off control.
    static func reading(_ label: String) -> Reading? {
        let n = normalise(label)
        guard !n.isEmpty, !n.split(separator: " ").contains(where: { never.contains(String($0)) }) else { return nil }
        if turnsOff.contains(n) { return .on }
        if turnsOn.contains(n) { return .off }
        if toggles.contains(n) { return .toggle }
        return nil
    }
}

extension CameraLabels {
    /// What a control says the camera is: on, off, or nil if it doesn't say —
    /// by its name, or for a bare toggle ("Camera"), by whether it shows it's on.
    static func camera(_ a: MeetingAttrs) -> Bool? {
        for name in [a.desc, a.title, a.help] where !name.isEmpty {
            switch reading(name) {
            case .on?: return true
            case .off?: return false
            case .toggle?:
                guard a.number != nil || a.selected != nil else { return nil }
                return a.number == 1 || a.selected == true
            case nil: continue
            }
        }
        return nil
    }

    /// Whether a control is a camera's on/off button (not its options, nor anything else).
    static func isCameraButton(_ a: MeetingAttrs) -> Bool {
        guard ["AXButton", "AXCheckBox", "AXToggle"].contains(a.role), a.isEnabled else { return false }
        return [a.desc, a.title, a.help].contains { !$0.isEmpty && reading($0) != nil }
    }
}
