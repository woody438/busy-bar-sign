import Foundation

// Reads the mute controls of the call apps the way MuteDetector will, from
// their labels: true muted, false live, nil not a mic mute control. Then the
// controls that hang up, as the Leave key finds them in FaceTime and WhatsApp.
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
    // FaceTime: a "Mute" menu item, ticked while muted; WhatsApp's, after a left-to-right mark
    ("Mute", "AXMenuItem", true, true), ("Mute", "AXMenuItem", false, false),
    ("\u{200E}Mute Microphone", "AXMenuItem", false, false),
    // a "Mute" that keeps its name and shows it's on: a toggle switched on, a selected button
    ("Mute", "AXCheckBox", true, true), ("Mute", "AXCheckBox", false, false),
    ("Mute", "AXButton", true, true), ("Mute mic", "AXButton", true, true), ("Unmute", "AXButton", true, true),
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

// Which controls hang up: .call wherever they are, .bare only beside a mic control, nil never.
let leaves: [(String, String, LeaveLabels.Kind?)] = [
    // FaceTime: its call window's button, and Apple's guide's "Leave Call"
    ("End", "AXButton", .bare), ("Leave", "AXButton", .bare), ("Leave Call", "AXButton", .call),
    ("End Call", "AXMenuItem", .call), ("End FaceTime call", "AXButton", .call), ("Close", "AXButton", .bare),
    ("\u{200E}End Call", "AXMenuItem", .call), ("close button", "AXButton", nil),
    // WhatsApp
    ("End call", "AXButton", .call), ("End Call (⌘⇧E)", "AXButton", .call), ("Hang up", "AXButton", .call),
    ("Leave call", "AXButton", .call), ("Raccrocher", "AXButton", .call), ("Terminer l’appel", "AXButton", .call),
    // never: other things named end or leave, things that start a call, the wrong kind of element
    ("Leave group", "AXButton", nil), ("Exit group", "AXButton", nil), ("End-to-end encrypted", "AXStaticText", nil),
    ("End-to-end encrypted", "AXButton", nil), ("End chat", "AXButton", nil), ("Leave community", "AXButton", nil),
    ("Voice call", "AXButton", nil), ("Video call", "AXButton", nil), ("Call", "AXButton", nil), ("Decline", "AXButton", nil),
    ("End", "AXStaticText", nil), ("End", "AXCheckBox", nil), ("Call ended", "AXStaticText", nil), ("Call ended", "AXButton", nil),
    ("Weekend", "AXButton", nil), ("Calendar", "AXButton", nil), ("", "AXButton", nil),
    ("Leave FaceTime call and end it for everyone in this very long label", "AXButton", nil)
]
for (label, role, want) in leaves {
    let got = LeaveLabels.reading(label: label, role: role)
    if got != want {
        failures.append("leave “\(label)” (\(role)): got \(got.map { "\($0)" } ?? "nil"), want \(want.map { "\($0)" } ?? "nil")")
    }
}

let total = cases.count + leaves.count
for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "mute and leave labels read right in all \(total) cases" : "\(failures.count) of \(total) mute and leave labels misread")
exit(failures.isEmpty ? 0 : 1)
