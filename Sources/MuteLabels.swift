import Foundation

/*
 * Reads a call app's mute control from what it says. Teams, Zoom, Meet,
 * Webex and Slack label the button by what pressing it would do, so
 * "Unmute mic" means you're muted now and "Mute mic" means you're live;
 * FaceTime instead ticks a "Mute" menu item. Pure, so Checks/mute can try
 * every label it knows on any machine.
 *
 * Anything it doesn't recognise is not a reading: the sign then shows a
 * live mic, the safe way round for a room that's deciding whether to talk.
 */
enum MuteLabels {
    /// What a control says about the mic: true muted, false live, nil not a mic control.
    static func reading(label raw: String, role: String, checked: Bool = false) -> Bool? {
        let label = normalise(raw)
        guard !label.isEmpty, label.count <= 40 else { return nil }
        let words = label.split(separator: " ")
        if words.contains(where: { w in excluded.contains(where: { w.hasPrefix($0) }) }) { return nil }

        // Meet: "Turn off microphone" while live; Teams in French: "Désactiver le micro"
        for (phrase, muted) in phrases where label == phrase || label.hasPrefix(phrase + " ") { return muted }

        // "Unmute", "Unmute mic", "Unmute audio" …: pressing it unmutes, so you're muted now
        if let rest = after("unmute", in: label), objects.contains(rest) { return true }
        // "Mute", "Mute mic", "Mute Audio" …: you're live — unless it's a ticked menu item (FaceTime)
        if let rest = after("mute", in: label), objects.contains(rest) {
            return role == "AXMenuItem" ? checked : false
        }
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
