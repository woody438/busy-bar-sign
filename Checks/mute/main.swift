import Foundation

// Reads the mute controls of the call apps the way MuteDetector will, from
// their labels: true muted, false live, nil not a mic mute control.
let cases: [(String, String, Bool, Bool?)] = [
    // Teams (new Teams' meeting toolbar)
    ("Mute mic (⌘+Shift+M)", "AXButton", false, false), ("Unmute mic (⌘+Shift+M)", "AXButton", false, true),
    ("Mute (⌘+Shift+M)", "AXButton", false, false), ("Unmute (⌘+Shift+M)", "AXButton", false, true),
    ("Désactiver le micro (⌘+Maj+M)", "AXButton", false, false), ("Activer le micro (⌘+Maj+M)", "AXButton", false, true),
    // Zoom: the toolbar and the Meeting menu
    ("Mute", "AXButton", false, false), ("Unmute", "AXButton", false, true),
    ("Mute Audio", "AXMenuItem", false, false), ("Unmute Audio", "AXMenuItem", false, true),
    ("Mute my microphone", "AXButton", false, false), ("Unmute my microphone", "AXButton", false, true),
    // Meet in a browser
    ("Turn off microphone (⌘ + d)", "AXButton", false, false), ("Turn on microphone (⌘ + d)", "AXButton", false, true),
    ("Turn off microphone", "AXCheckBox", false, false),
    // Slack huddles, Webex
    ("Mute mic", "AXButton", false, false), ("Unmute mic", "AXButton", false, true),
    ("Mute…", "AXButton", false, false),
    // FaceTime: a "Mute" menu item, ticked while muted
    ("Mute", "AXMenuItem", true, true), ("Mute", "AXMenuItem", false, false),
    // not about your mic
    ("Mute all", "AXButton", false, nil), ("Unmute all", "AXButton", false, nil), ("Mute All Participants", "AXMenuItem", false, nil),
    ("Mute notifications", "AXMenuItem", false, nil), ("Mute this conversation", "AXMenuItem", false, nil),
    ("Mute speaker", "AXButton", false, nil), ("Mute video", "AXButton", false, nil), ("Mute channel", "AXMenuItem", false, nil),
    ("Mute everyone", "AXButton", false, nil), ("Ask all to unmute", "AXButton", false, nil), ("Mute participant", "AXButton", false, nil),
    ("Microphone", "AXButton", false, nil), ("Audio settings", "AXButton", false, nil), ("Leave", "AXButton", false, nil),
    ("Muted", "AXStaticText", false, nil), ("", "AXButton", false, nil),
    ("Mute this long description of something that is not a mute button at all", "AXButton", false, nil)
]

var failures: [String] = []
for (label, role, checked, want) in cases {
    let got = MuteLabels.reading(label: label, role: role, checked: checked)
    if got != want {
        failures.append("“\(label)” (\(role)\(checked ? ", ticked" : "")): got \(got.map { "\($0)" } ?? "nil"), want \(want.map { "\($0)" } ?? "nil")")
    }
}
for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "mute labels read right in all \(cases.count) cases" : "\(failures.count) of \(cases.count) mute labels misread")
exit(failures.isEmpty ? 0 : 1)
