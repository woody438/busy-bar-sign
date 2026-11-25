import Foundation

/*
 * The camera as the sign follows it (CameraFollower), through scripted calls:
 * CAMERA ON when it comes on during a call, never for a camera already on as
 * a call starts (that call's own announcement says it), CAMERA OFF two
 * seconds after it goes off mid-call — but not as you hang up — the tally
 * only during a call, and every change announced, however often.
 *
 *   swiftc Sources/CameraFollower.swift Checks/camera/main.swift -o camera && ./camera
 */

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

/// Plays readings a second apart (or as given): (t, camera, mic, onCall). Returns the cues by time, and the tally after each.
func play(_ readings: [(Double, Bool, Bool, Bool)]) -> (cues: [(Double, CameraFollower.Cue)], tally: [Bool]) {
    var f = CameraFollower()
    var cues: [(Double, CameraFollower.Cue)] = []
    var tally: [Bool] = []
    for (t, camera, mic, onCall) in readings {
        if let c = f.step(at: t, camera: camera, mic: mic, onCall: onCall) { cues.append((t, c)) }
        tally.append(f.tally(onCall: onCall))
    }
    return (cues, tally)
}

/// A call from 10 s to 60 s, the mic with it; `camera(t)` says when the camera's on.
func call(camera: (Double) -> Bool, micUntil: Double = 60, signUntil: Double = 60, step: Double = 1, to end: Double = 70)
    -> [(Double, Bool, Bool, Bool)] {
    stride(from: 0.0, through: end, by: step).map { t in (t, camera(t), t >= 10 && t < micUntil, t >= 10 && t < signUntil) }
}

// 1. The camera comes on mid-call, goes off mid-call
do {
    let r = play(call(camera: { $0 >= 20 && $0 < 40 }))
    check(r.cues.count == 2, "camera on at 20 s and off at 40 s mid-call: two cues (\(r.cues.map { "\($0.1.rawValue)@\(Int($0.0))" }))")
    check(r.cues.first.map { $0.0 == 20 && $0.1 == .cameraOn } ?? false, "CAMERA ON at once, at 20 s")
    check(r.cues.dropFirst().first.map { $0.0 == 42 && $0.1 == .cameraOff } ?? false, "CAMERA OFF once it's been off 2 s, at 42 s")
    check(r.tally[19] == false && r.tally[20] && r.tally[41] && !r.tally[42], "the tally: on from 20 s, off at 42 s")
}

// 2. A call that starts with the camera already on (a preview before joining): no cue of its own
do {
    let r = play(call(camera: { $0 >= 5 && $0 < 50 }, micUntil: 50, signUntil: 60))
    check(!r.cues.contains { $0.1 == .cameraOn }, "camera on before the call starts: no CAMERA ON cue (the call's own announcement says it)")
    check(!r.tally[5] && !r.tally[9] && r.tally[10], "the tally: not during the preview, on as the call starts")
    // hanging up at 50 s: camera and mic go together, the sign follows the mic 10 s later
    check(!r.cues.contains { $0.1 == .cameraOff }, "hanging up at 50 s (camera and mic let go together): no CAMERA OFF")
    check(r.tally[51] && !r.tally[52] && !r.tally[59], "the tally goes out 2 s after the camera, while the sign still says ON A CALL")
}

// 3. The camera goes off a second before you hang up: still nothing announced
do {
    let r = play(call(camera: { $0 >= 12 && $0 < 49 }, micUntil: 50, signUntil: 60))
    check(!r.cues.contains { $0.1 == .cameraOff }, "camera off at 49 s, hang up at 50 s: the mic's gone by 51 s, so no CAMERA OFF")
}

// 4. Every change announced, however often
do {
    let on: (Double) -> Bool = { t in (t >= 15 && t < 20) || (t >= 25 && t < 30) || (t >= 35 && t < 40) }
    let r = play(call(camera: on))
    let ons = r.cues.filter { $0.1 == .cameraOn }.count, offs = r.cues.filter { $0.1 == .cameraOff }.count
    check(ons == 3 && offs == 3, "on and off three times: three of each (\(ons), \(offs))")
}

// 5. A camera that drops out for under 2 s doesn't count as off
do {
    let r = play(call(camera: { $0 >= 15 && $0 != 30 }, step: 0.5))
    check(r.cues.count == 1 && r.cues[0].1 == .cameraOn, "the camera blinking off for half a second mid-call: no CAMERA OFF")
}

// 6. Outside a call: never a cue, never the tally
do {
    let r = play(stride(from: 0.0, through: 30, by: 1).map { t in (t, t >= 5 && t < 20, false, false) })
    check(r.cues.isEmpty && !r.tally.contains(true), "Photo Booth with no call: no cue and no tally")
}

// 7. The camera on as the call ends and the sign moves on at once (the Leave key): no CAMERA OFF
do {
    let r = play(call(camera: { $0 >= 12 && $0 < 31 }, micUntil: 30, signUntil: 30))
    check(!r.cues.contains { $0.1 == .cameraOff }, "left with the Leave key at 30 s, camera let go at 31 s: no CAMERA OFF")
    check(!r.tally[30], "the tally goes out with the call")
}

print(failures == 0 ? "\nall camera checks passed" : "\n\(failures) camera checks failed")
exit(failures == 0 ? 0 : 1)
