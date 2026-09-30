# Studio Call Sign

A full-screen macOS wall display: a broadcast studio clock with an inset
seven-segment LED module, and an illuminated **ON A CALL / FREE** sign that
follows whether you're actually in a call.

`mock.html` is the visual reference — open it in any browser to see the target.

> **This source has never been compiled.** It was written in a Linux container
> with no Xcode, so treat the first build as a debugging session rather than a
> clean run. See *Known risks* below for where breakage is most likely.

## Build

Requires macOS 14.4 or later (the CoreAudio process API arrived in 14.4) and Xcode 15+.

### With XcodeGen (fastest)

```sh
brew install xcodegen
xcodegen generate
open StudioCallSign.xcodeproj
```

### Without XcodeGen

1. Xcode → File → New → Project → macOS → App. Name it `StudioCallSign`,
   interface SwiftUI, language Swift.
2. Delete the generated `ContentView.swift` and `StudioCallSignApp.swift`.
3. Drag everything in `Sources/` into the project.
4. Target → General → set Minimum Deployment to macOS 14.4.
5. Target → Signing & Capabilities → pick your personal team. No notarisation
   is needed for an app you only run yourself.

Then just hit Run. No TCC permission prompt should appear at launch — the
detection reads device and process *state*, it doesn't capture audio.

## How the detection works

| Layer | Signal | Notes |
|---|---|---|
| Primary | `kAudioProcessPropertyIsRunningInput` per process | Tells you *which app* has the mic, so dictation can be filtered out |
| Fallback | `kAudioDevicePropertyDeviceIsRunningSomewhere` | Used automatically if the process API returns nothing. No attribution |
| Corroborating | `kCMIODevicePropertyDeviceIsRunningSomewhere` | Camera state, shown on the bottom strip |

Both are polled once a second. Property listeners would be tidier, but polling
is far harder to get subtly wrong, and 1 Hz costs nothing.

**Debounce:** 2 s before the sign lights, 10 s before it goes dark. A wall sign
that flickers is worse than no sign. Zoom and Teams mute in software and keep
the stream open, so the sign correctly stays lit while you're muted.

**Policy** (menu bar → Detect):
- *Any app except ignored* (default) — catches meeting apps nobody has heard of
  yet. `KnownApps.ignored` in `CallDetector.swift` filters out dictation,
  Voice Memos, music and DAW apps. **Wispr Flow is in that list** — without it
  the sign would light every time you dictated.
- *Known call apps only* — stricter, fewer false positives, but a new app won't
  register until you add its bundle ID to `KnownApps.calls`.

To find an app's bundle ID: `osascript -e 'id of app "Zoom"'`

**Manual override** (menu bar → Sign): Automatic / Force ON A CALL / Force FREE.

## Known risks on first build

1. **CoreAudio process symbols.** `kAudioHardwarePropertyProcessObjectList`,
   `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` and
   `kAudioProcessPropertyIsRunningInput` are 14.4+. If any fail to resolve, the
   device-level fallback in `AudioProbe` already handles it — you'd just lose
   per-app attribution, and dictation would start lighting the sign.
2. **`CMIOObjectGetPropertyData` argument order** differs from the CoreAudio
   equivalent (it takes `dataUsed` as an inout). Worth checking against the
   headers if `CameraProbe` misbehaves.
3. **Sign text width.** `SignView` hard-codes 118 pt with `minimumScaleFactor`,
   tuned for a 912 pt panel. Fine on 16:9; check it if your monitor is wider.
4. **`MenuBarExtra` icon reactivity** — the symbol is read off the delegate and
   may not re-render on every state change. Cosmetic.

## Still to wire up

- Launch at login (`SMAppService.mainApp.register()`)
- The after-hours dim schedule — the burn-in drift is in `DisplayView`, the
  dimming isn't
- A Preferences window; everything is currently menu-bar only

## Handing this to a local Claude Code session

From the project directory:

```
claude
```

then:

> This is an uncompiled SwiftUI macOS app — read README.md. Build it with
> xcodegen + xcodebuild, fix the compile errors, run it, and screenshot the
> window so we can compare it against mock.html. Start with AudioProbe.swift,
> which is the part most likely to be wrong.
