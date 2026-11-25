import Foundation

/*
 * The camera, as the sign follows it. While the sign says ON A CALL (muted
 * or not) and a camera's on, the tally lights: the green light in the case's
 * sensor notch, or stacked, a green dot beside the countdown. The camera
 * coming on during a call is announced across the bar, CAMERA ON — a call
 * that starts with it already on says CAMERA ON in place of ON A CALL
 * (BarModel) — and going off mid-call is announced too, CAMERA OFF. Every
 * time, however often it changes.
 *
 * Leaving a call lets go of the camera and the mic together, but the sign
 * waits up to 10 seconds before it believes the mic's free (CallDetector).
 * Announcing on the camera alone would say CAMERA OFF as you hang up. So a
 * camera that's gone off is followed once it's been off for `offDelay`, and
 * announced only if the mic is still in use then. Coming on is followed at
 * once: you've just pressed it.
 *
 * The camera is any camera on the Mac streaming (CameraProbe), the signal
 * that lights the green light beside the lens: it doesn't matter which app
 * has it, and it's never shown outside a call (a preview before you join,
 * Photo Booth).
 *
 * Pure, so Checks/camera plays it through scripted calls anywhere Swift runs.
 */
struct CameraFollower {
    /// How long a camera must have been off before the sign follows it.
    static let offDelay: TimeInterval = 2
    /// Readings land about a second apart; this stops jitter turning 2 s into 3.
    static let slack: TimeInterval = 0.25

    enum Cue: String, Equatable { case cameraOn, cameraOff }

    /// The camera as the sign has it: on at once, off once it's held off for `offDelay`.
    private(set) var live = false
    private var offSince: TimeInterval?
    /// Whether the sign said ON A CALL (muted or not) at the last reading.
    private var wasOnCall = false

    /// One reading, on any change and at least once a second. `t`: a
    /// monotonic clock, in seconds. `camera`: whether any camera is streaming
    /// now. `mic`: whether the call's mic is in use now, not waited on.
    /// `onCall`: whether the sign says ON A CALL, muted or not. Returns the
    /// cue to announce: CAMERA ON when the camera comes on during a call
    /// that was already on; CAMERA OFF when it's been off `offDelay` during
    /// a call and the mic's still in use.
    mutating func step(at t: TimeInterval, camera: Bool, mic: Bool, onCall: Bool) -> Cue? {
        var cue: Cue?
        if camera {
            offSince = nil
            if !live {
                live = true
                if onCall && wasOnCall { cue = .cameraOn }
            }
        } else if live {
            let since = offSince ?? t
            offSince = since
            if t - since >= Self.offDelay - Self.slack {
                live = false
                offSince = nil
                if onCall && wasOnCall && mic { cue = .cameraOff }
            }
        }
        wasOnCall = onCall
        return cue
    }

    /// The tally: a camera on, during a call.
    func tally(onCall: Bool) -> Bool { live && onCall }
}
