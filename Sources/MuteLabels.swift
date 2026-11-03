import Foundation

/*
 * Reads a call app's mute control from what it says. Teams, Zoom, Meet,
 * Webex and Slack label the button by what pressing it would do, so
 * "Unmute mic" means you're muted now and "Mute mic" means you're live;
 * a "Mute" that keeps its name shows it's on instead — a ticked menu item,
 * a toggle switched on, a selected button. Also (LeaveLabels) which
 * controls hang up: FaceTime's "End" or "Leave Call", WhatsApp's "End
 * call". Pure, so Checks/mute can try every label it knows on any machine.
 *
 * Anything it doesn't recognise is not a reading: the sign then shows a
 * live mic, the safe way round for a room that's deciding whether to talk.
 */
enum MuteLabels {
    /// What a control says about the mic: true muted, false live, nil not a
    /// mic control. `checked`: the control shows it's on (a tick, a toggle's
    /// value, selected).
    static func reading(label raw: String, role: String, checked: Bool = false) -> Bool? {
        let label = normalise(raw)
        guard !label.isEmpty, label.count <= 40 else { return nil }
        let words = label.split(separator: " ")
        if words.contains(where: { w in excluded.contains(where: { w.hasPrefix($0) }) }) { return nil }

        // Meet: "Turn off microphone" while live; Teams in French: "Désactiver le micro"
        for (phrase, muted) in phrases where label == phrase || label.hasPrefix(phrase + " ") { return muted }

        // "Unmute", "Unmute mic", "Unmute audio" …: pressing it unmutes, so you're muted now
        if let rest = after("unmute", in: label), objects.contains(rest) { return true }
        // "Mute", "Mute mic", "Mute Audio" …: you're live — unless it shows it's on: a ticked
        // menu item, a toggle switched on, a selected button (a "Mute" that keeps its name)
        if let rest = after("mute", in: label), objects.contains(rest) { return checked }
        return nil
    }

    /// What may follow "mute" / "unmute" for it to be about your own mic.
    private static let objects: Set<String> = ["", "mic", "microphone", "audio", "my mic", "my microphone", "myself", "me"]

    private static let phrases: [(String, Bool)] = [
        ("turn off microphone", false), ("turn off mic", false), ("turn off the microphone", false),
        ("turn on microphone", true), ("turn on mic", true), ("turn on the microphone", true),
        ("désactiver le micro", false), ("couper le micro", false), ("activer le micro", true),
        ("rétablir le micro", true)
    ]

    /// Mute controls that aren't about your mic, by the start of any word in them.
    private static let excluded = ["all", "everyone", "participant", "notification", "speaker", "conversation",
                                   "channel", "chat", "video", "camera", "others", "sound", "alert", "ring"]

    /// Lower case, without the keyboard shortcut Teams and Meet add: "Mute mic (⌘+Shift+M)" → "mute mic".
    static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        t = t.replacingOccurrences(of: "\u{2026}", with: "")                 // "Mute…"
        let kept = t.unicodeScalars.map { CharacterSet.letters.contains($0) || $0 == " " ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// The words after `word` if the label starts with it as a whole word.
    private static func after(_ word: String, in label: String) -> String? {
        guard label == word || label.hasPrefix(word + " ") else { return nil }
        return String(label.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Which controls hang up a call, by what they say. A control named for the
/// call ("End call", "Leave Call", "Hang up") counts wherever it is; a lone
/// "End" or "Leave" only beside a mic control, in the call's own window — a
/// chat's "Leave" never ends anything.
enum LeaveLabels {
    enum Kind: Equatable {
        case call       // says it's about the call
        case bare       // "End", "Leave", "Close": only in FaceTime, in a window with a mic control
    }

    /// What a control's name says about hanging up, or nil when it doesn't.
    static func reading(label raw: String, role: String) -> Kind? {
        guard roles.contains(role) else { return nil }
        let label = MuteLabels.normalise(raw)
        guard !label.isEmpty, label.count <= 40 else { return nil }
        if bare.contains(label) { return .bare }
        if phrases.contains(label) { return .call }
        return nil
    }

    private static let roles: Set<String> = ["AXButton", "AXMenuItem"]
    private static let bare: Set<String> = ["end", "leave", "close"]     // FaceTime's ✕ may say any
    /// Whole names only: "End-to-end encrypted", "Leave group" and "End Chat" aren't calls.
    private static let phrases: Set<String> = [
        "end call", "end the call", "end this call", "end video call", "end voice call", "end audio call",
        "end facetime", "end facetime call", "end whatsapp call",
        "leave call", "leave the call", "leave this call", "leave facetime", "leave facetime call",
        "hang up", "hangup",
        // French, as for Teams' mute
        "raccrocher", "terminer l appel", "quitter l appel"
    ]
}
