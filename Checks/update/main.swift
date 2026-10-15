import Foundation

// Checks UpdateCheck: reading a release's BusyBarSign.json, which release an
// app follows, which is newest, and plugin versions.
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

let json = #"{"build": 41, "version": "2.0", "commit": "d477305", "channel": "preview", "plugin": "1.2.0.0"}"#
let r = Updates.decode(Data(json.utf8))
expect(r == Updates.Release(build: 41, version: "2.0", commit: "d477305", channel: "preview", plugin: "1.2.0.0"), "reads BusyBarSign.json")
expect(Updates.decode(Data(#"{"build": 7, "version": "2.0", "commit": "abc", "channel": "latest"}"#.utf8))?.plugin == nil,
       "a release without a plugin version")
expect(Updates.decode(Data("not json".utf8)) == nil, "rubbish isn't a release")

expect(Updates.url("latest", "BusyBarSign.zip").absoluteString
       == "https://github.com/woody438/busy-bar-sign/releases/download/latest/BusyBarSign.zip", "download URL")
expect(Updates.channels(following: "latest") == ["latest"], "main's builds follow main")
expect(Updates.channels(following: "preview") == ["preview", "latest"], "a preview build follows the preview, then main")

let main = Updates.Release(build: 40, version: "2.0", commit: "a", channel: "latest", plugin: nil)
let preview = Updates.Release(build: 43, version: "2.0", commit: "b", channel: "preview", plugin: nil)
expect(Updates.newest([main, preview], after: 41) == preview, "the newest of two")
expect(Updates.newest([main], after: 41) == nil, "an older build isn't an update")
expect(Updates.newest([main], after: 40) == nil, "the same build isn't an update")
expect(Updates.newest([], after: 2) == nil, "nothing found")

expect(Updates.isNewer("1.2.0.0", than: "1.1.0.0"), "1.2 over 1.1")
expect(!Updates.isNewer("1.1.0.0", than: "1.1.0.0"), "the same")
expect(Updates.isNewer("1.10", than: "1.9.9"), "numbers, not text")
expect(!Updates.isNewer("1.1", than: "1.1.0.0"), "missing parts are noughts")

// the plugin: the newest across the releases followed, if newer than Stream Deck's
let previewPlugin = Updates.Release(build: 38, version: "2.1", commit: "c", channel: "preview", plugin: "1.2.1.0")
let mainPlugin = Updates.Release(build: 37, version: "2.1", commit: "d", channel: "latest", plugin: "1.2.0.0")
expect(Updates.newerPlugin([previewPlugin, mainPlugin], than: "1.2.0.0", app: 38) == "1.2.1.0", "a newer plugin in the preview")
expect(Updates.newerPlugin([mainPlugin, previewPlugin], than: "1.2.0.0", app: 38) == "1.2.1.0", "whichever order the releases come in")
expect(Updates.newerPlugin([mainPlugin], than: "1.2.0.0", app: 38) == nil, "main's plugin is the one installed")
expect(Updates.newerPlugin([previewPlugin, mainPlugin], than: "1.2.1.0", app: 38) == nil, "the newest is installed")
expect(Updates.newerPlugin([main, preview], than: "1.0.0.0", app: 43) == nil, "releases that don't say")
// the app first: build 37 seeing build 40 offers the app, not 40's plugin
let main40 = Updates.Release(build: 40, version: "2.1", commit: "e", channel: "latest", plugin: "1.2.1.0")
expect(Updates.newerPlugin([main40], than: "1.2.0.0", app: 37) == nil, "no plugin while the app is behind")
expect(Updates.newerPlugin([main40], than: "1.2.0.0", app: 40) == "1.2.1.0", "the plugin once the app is up to date")

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "updates: releases read and compared as designed" : "\(failures.count) update checks failed")
exit(failures.isEmpty ? 0 : 1)
