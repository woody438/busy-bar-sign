import AppKit
import Security

/*
 * Keeps Busy Bar Sign up to date from its GitHub releases (UpdateCheck says
 * which): looks at launch and every four hours, and installs a newer build
 * when you're not on a call or in a meeting, so the sign never blinks out
 * mid-call. Or by hand, from Settings ▸ Status. With Get preview builds on,
 * a pull request's preview build counts too; turned off on a preview, Back to
 * Main Release installs main's build, though its number is lower.
 *
 * A download is only installed if it's signed with the same certificate as
 * the app that's running (tools/sign.sh): its signature must satisfy this
 * app's own designated requirement. An app signed ad hoc has nothing to
 * match, so it never installs anything. The swap happens after the app
 * quits — the old copy moved aside, the new one put in its place, then
 * opened — and a download made here isn't quarantined, so there's no Open
 * Anyway. Permissions carry over, as it's the same app to macOS.
 *
 * The Stream Deck plugin can't be installed quietly (Stream Deck always
 * asks), so a newer one is opened in Stream Deck, once per version, when
 * you're off calls and the app itself is up to date: Stream Deck asks to
 * install it. Or by hand, from the menu or Settings. A plugin whose code
 * isn't the version its manifest says — an install that stopped part way —
 * is offered again, from the menu and Settings, rather than called up to date.
 */
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    struct PluginUpdate: Equatable {
        var installed: String
        var available: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var available: Updates.Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var plugin: PluginUpdate?
    @Published private(set) var pluginInstalled: String?     // the plugin's version in Stream Deck, if it has it
    /// Stream Deck has the plugin's manifest over other code: it needs installing again.
    @Published private(set) var pluginIncomplete = false
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "installUpdatesAutomatically") }
    }
    /// Whether preview builds (a pull request's, before it's merged) are updates too, as main's are.
    /// Off to begin with, unless this is a preview build.
    @Published var previews = UserDefaults.standard.object(forKey: "getPreviewBuilds") as? Bool
        ?? (Bundle.main.object(forInfoDictionaryKey: "BBSUpdateChannel") as? String == "preview") {
        didSet {
            UserDefaults.standard.set(previews, forKey: "getPreviewBuilds")
            if previews != oldValue { check() }
        }
    }
    /// Main's release, while this is a preview build and previews are off: Back to Main Release installs it.
    @Published private(set) var mainRelease: Updates.Release?

    let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let channel = Bundle.main.object(forInfoDictionaryKey: "BBSUpdateChannel") as? String ?? "latest"
    /// The pull request a preview build was built from, where it says (builds from 2.4.1 on).
    let previewPR = Int(Bundle.main.object(forInfoDictionaryKey: "BBSPreviewPR") as? String ?? "")

    /// Whether you're on a call or in a meeting, when an update would interrupt.
    var isBusy: @MainActor () -> Bool = { false }

    private var timer: Timer?
    private var failedBuild: Int?           // not tried again automatically until a newer one comes
    private var found: [Updates.Release] = []

    /// The last plugin version opened in Stream Deck, so each is only offered once.
    private var pluginOffered: String? {
        get { UserDefaults.standard.string(forKey: "streamDeckPluginOffered") }
        set { UserDefaults.standard.set(newValue, forKey: "streamDeckPluginOffered") }
    }

    static let checkEvery: TimeInterval = 4 * 3600

    init() {
        automatic = UserDefaults.standard.object(forKey: "installUpdatesAutomatically") as? Bool ?? true
    }

    func start() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // a moment after launch, not during it
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastChecked ?? .distantPast) >= Self.checkEvery { check() }
        if lastChecked != nil { refreshPlugin() }        // so it goes once Stream Deck has installed it
        guard automatic, !isBusy() else { return }
        if let next = available, next.build != failedBuild, phase == .available, installProblem == nil {
            install()       // the app first: the new one then offers its plugin
        } else if let offer = plugin, offer.available != pluginOffered,
                  phase != .checking, phase != .downloading, phase != .installing {
            pluginOffered = offer.available
            updatePlugin()
        }
    }

    /// Why the app can't replace itself where it is, or nil when it can.
    var installProblem: String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "Move Busy Bar Sign to the Applications folder first."
        }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else {
            return "Busy Bar Sign can't replace itself in \(app.deletingLastPathComponent().path): download it from the release page."
        }
        return nil
    }

    /// The release page for this app's channel.
    var releasePage: URL {
        URL(string: "https://github.com/\(Updates.repository)/releases/tag/\(channel)")!
    }

    // MARK: Checking

    func check() {
        guard phase != .checking, phase != .downloading, phase != .installing else { return }
        phase = .checking
        let previews = self.previews
        Task {
            var found: [Updates.Release] = []
            for c in Updates.channels(previews: previews) {
                if let release = await fetch(c) { found.append(release) }
            }
            lastChecked = Date()
            available = Updates.newest(found, after: build)
            if found.isEmpty {
                phase = .failed("Couldn't reach GitHub")
            } else {
                phase = available == nil ? .upToDate : .available
            }
            if !found.isEmpty { self.found = found }      // GitHub out of reach: keep what it last said
            mainRelease = Updates.backToMain(self.found, running: build, channel: channel, previews: previews)
            refreshPlugin()
            if previews != self.previews { check() }      // switched while it looked: again, for what's followed now
        }
    }

    /// Installs main's release over this preview build, though its number is lower.
    func backToMain() {
        guard let release = mainRelease else { return }
        available = release
        install()
    }

    private func fetch(_ channel: String) async -> Updates.Release? {
        var request = URLRequest(url: Updates.url(channel, "BusyBarSign.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let got = try? await URLSession.shared.data(for: request),
              (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Updates.decode(got.0)
    }

    // MARK: Installing

    enum UpdateError: LocalizedError {
        case download, unzip, notTheApp, adHoc, signature(OSStatus)
        var errorDescription: String? {
            switch self {
            case .download: return "The download didn't finish"
            case .unzip: return "The download wouldn't unzip"
            case .notTheApp: return "The download isn't the build expected"
            case .adHoc: return "This copy isn't signed with the project's certificate, so it can't check an update: download it from the release page"
            case .signature(let status): return "The download isn't signed with the project's certificate (\(status)), so it wasn't installed"
            }
        }
    }

    /// Downloads the newer build, checks it, and swaps it in: the app quits and reopens.
    func install() {
        guard let release = available, phase == .available || phase == .upToDate || isFailed else { return }
        if let problem = installProblem {
            phase = .failed(problem)
            return
        }
        let target = Bundle.main.bundleURL
        phase = .downloading
        Task {
            do {
                // beside the app, on the same disk, so the swap is a rename
                let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
                let zip = dir.appendingPathComponent("BusyBarSign.zip")
                var request = URLRequest(url: Updates.url(release.channel, "BusyBarSign.zip"))
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (file, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
                try FileManager.default.moveItem(at: file, to: zip)
                guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) == 0 else { throw UpdateError.unzip }
                try? FileManager.default.removeItem(at: zip)
                let app = dir.appendingPathComponent(target.lastPathComponent)
                _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
                try Self.verify(app, build: release.build)
                phase = .installing
                try relaunch(replacing: target, with: app)
            } catch {
                failedBuild = release.build
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// The download must be this app, the build expected, and signed with the
    /// certificate this one is: it must satisfy this app's designated requirement.
    private static func verify(_ app: URL, build: Int) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(info["CFBundleVersion"] as? String ?? "") == build else { throw UpdateError.notTheApp }

        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.adHoc
        }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        // ad hoc, the requirement is this build's own hash, which no other build can meet
        guard let text, (text as String).contains("certificate") else { throw UpdateError.adHoc }

        var download: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &download)
        guard created == errSecSuccess, let download else { throw UpdateError.signature(created) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
                               | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidityWithErrors(download, flags, requirement, nil)
        guard status == errSecSuccess else { throw UpdateError.signature(status) }
    }

    /// Quits, and leaves a shell to swap the apps once it has, then open the new one.
    private func relaunch(replacing target: URL, with app: URL) throws {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        if /bin/mv "$2" "$2.old"; then
          if /bin/mv "$3" "$2"; then /bin/rm -rf "$2.old"; else /bin/mv "$2.old" "$2"; fi
        fi
        /usr/bin/open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "busybarsign-update", String(getpid()), target.path, app.path]
        try swap.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { done in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { done.resume(returning: -1) }
        }
    }

    // MARK: The Stream Deck plugin

    private static var pluginManifest: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.elgato.StreamDeck/Plugins/com.woodall.busybarsign.sdPlugin/manifest.json")
    }

    /// The plugin's version in Stream Deck, if it has it.
    private static func installedPlugin() -> String? {
        guard let data = try? Data(contentsOf: pluginManifest),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["Version"] as? String
    }

    /// The version the plugin's code in Stream Deck was built as, if it says.
    private static func installedPluginCode() -> String? {
        let code = pluginManifest.deletingLastPathComponent().appendingPathComponent("bin/plugin.js")
        guard let file = try? FileHandle(forReadingFrom: code) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: 256) else { return nil }
        return Updates.pluginCodeVersion(String(decoding: head, as: UTF8.self))
    }

    /// Reads which plugin Stream Deck has now, against the releases last checked.
    func refreshPlugin() {
        let installed = Self.installedPlugin()
        let incomplete = installed.map { Updates.pluginIncomplete(manifest: $0, code: Self.installedPluginCode()) } ?? false
        pluginInstalled = installed
        if pluginIncomplete != incomplete { pluginIncomplete = incomplete }
        plugin = installed.flatMap { have in
            // half installed: whichever plugin the releases have is worth installing again
            Updates.newerPlugin(found, than: incomplete ? "0" : have, app: build).map { PluginUpdate(installed: have, available: $0) }
        }
    }

    /// Downloads the plugin and hands it to Stream Deck, which asks to install it.
    func updatePlugin() {
        // from the release that has it: main's, or a preview's while previews are on
        let channel = available?.channel ?? found.first(where: { $0.plugin == plugin?.available })?.channel ?? "latest"
        Task {
            guard let got = try? await URLSession.shared.download(from: Updates.url(channel, "BusyBarSign.streamDeckPlugin")),
                  (got.1 as? HTTPURLResponse)?.statusCode == 200 else {
                phase = .failed("The Stream Deck plugin didn't download")
                return
            }
            let named = FileManager.default.temporaryDirectory.appendingPathComponent("BusyBarSign.streamDeckPlugin")
            try? FileManager.default.removeItem(at: named)
            do {
                try FileManager.default.moveItem(at: got.0, to: named)
                NSWorkspace.shared.open(named)     // the offer stays until Stream Deck has installed it
            } catch {
                phase = .failed("The Stream Deck plugin couldn't be opened")
            }
        }
    }

    /// One line for the settings: what's happening, or what's there.
    var statusLine: String {
        switch phase {
        case .idle: return "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date" + (lastChecked.map { " · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .available: return "Build \(available?.build ?? 0) is ready" + (automatic ? " — installs when you're off calls" : "")
        case .downloading: return "Downloading build \(available?.build ?? 0)…"
        case .installing: return "Installing; the app will reopen…"
        case .failed(let why): return why
        }
    }
}
