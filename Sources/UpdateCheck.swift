import Foundation

/*
 * Where updates come from, and which is newer: the part of the updater that
 * isn't the Mac (Updater does the downloading and the swap). Each build CI
 * publishes carries BusyBarSign.json beside the app:
 *
 *   {"build": 41, "version": "2.0", "commit": "d477305", "channel": "latest", "plugin": "1.2.0.0"}
 *
 * `build` is the CI run's number, the app's CFBundleVersion: higher is newer.
 * Main's builds go to the "latest" release; a pull request's to "preview".
 * An app built from main follows "latest"; a preview build follows both, so a
 * tester gets the next preview, and then main once it's merged.
 */
enum Updates {
    static let repository = "woody438/busy-bar-sign"

    struct Release: Decodable, Equatable {
        var build: Int
        var version: String
        var commit: String
        var channel: String          // the release it's in: "latest" or "preview"
        var plugin: String?          // the Stream Deck plugin's version alongside it
    }

    /// A file in a release.
    static func url(_ channel: String, _ file: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(channel)/\(file)")!
    }

    /// The releases an app built for `channel` follows.
    static func channels(following channel: String) -> [String] {
        channel == "preview" ? ["preview", "latest"] : ["latest"]
    }

    static func decode(_ data: Data) -> Release? {
        try? JSONDecoder().decode(Release.self, from: data)
    }

    /// The newest release built after `build`, if any.
    static func newest(_ releases: [Release], after build: Int) -> Release? {
        releases.filter { $0.build > build }.max { $0.build < $1.build }
    }

    /// The newest plugin among `releases`, if it's newer than the one installed
    /// and the app is already the newest build: a plugin goes with its app, so
    /// the app updates first and the plugin is offered after.
    static func newerPlugin(_ releases: [Release], than installed: String, app build: Int) -> String? {
        guard newest(releases, after: build) == nil else { return nil }
        let best = releases.compactMap(\.plugin).max { isNewer($1, than: $0) }
        guard let best, isNewer(best, than: installed) else { return nil }
        return best
    }

    /// The version the plugin's code was built as, from the first line of its
    /// bin/plugin.js: "/* com.woodall.busybarsign 1.4.1.0 */"
    /// (streamdeck/rollup.config.mjs). Nil for code that doesn't say: before 1.4.1.
    static func pluginCodeVersion(_ head: String) -> String? {
        let line = head.prefix { !$0.isNewline }
        let parts = line.split(separator: " ")
        guard parts.count == 4, parts[0] == "/*", parts[1] == "com.woodall.busybarsign", parts[3] == "*/" else { return nil }
        return String(parts[2])
    }

    /// The first plugin whose code says its version.
    static let firstStampedPlugin = "1.4.1.0"

    /// Whether Stream Deck has a plugin's manifest over other code: an install
    /// that stopped part way, so the keys run an older plugin than Settings
    /// would say. Code too old to say its version is only caught under a
    /// manifest that's new enough to have said it.
    static func pluginIncomplete(manifest: String, code: String?) -> Bool {
        guard let code else { return !isNewer(firstStampedPlugin, than: manifest) }
        return isNewer(code, than: manifest) || isNewer(manifest, than: code)
    }

    /// Whether dotted version `a` is newer than `b`: "1.2.0.0" over "1.1.0.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
