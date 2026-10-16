import AppKit

/*
 * The Busy Bar Sign screen saver (Saver/), which the app carries inside it
 * and keeps in ~/Library/Screen Savers, replaced with each build's own. It
 * shows the sign on every screen while you're away from the Mac — the lock
 * screen covers every display, and no app can draw over it; a screen saver
 * can. It asks the app what the sign says (LocalAPI's /status).
 */
@MainActor
final class SaverInstaller: ObservableObject {
    /// Whether this build's screen saver is in place.
    @Published private(set) var installed = false
    @Published private(set) var problem: String?

    static let name = "Busy Bar Sign.saver"

    private var bundled: URL? { Bundle.main.builtInPlugInsURL?.appendingPathComponent(Self.name) }
    private var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Screen Savers", isDirectory: true)
            .appendingPathComponent(Self.name)
    }

    /// Puts this build's screen saver in place, unless it's there already.
    func install() {
        let fm = FileManager.default
        guard let source = bundled, fm.fileExists(atPath: source.path) else {
            problem = "This build doesn't carry the screen saver."
            return
        }
        if fm.contentsEqual(atPath: source.path, andPath: destination.path) {
            installed = true
            problem = nil
            return
        }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            Self.unquarantine(destination)
            installed = true
            problem = nil
        } catch {
            installed = false
            problem = "Couldn't install the screen saver: \(error.localizedDescription)"
        }
    }

    /// System Settings where the screen saver is chosen: Wallpaper ▸ Screen
    /// Saver from macOS 26, its own Screen Saver page before.
    func openSettings() {
        if #available(macOS 26, *) {
            open("com.apple.Wallpaper-Settings.extension")
        } else {
            open("com.apple.ScreenSaver-Settings.extension")
        }
    }

    /// Lock Screen, where "Require password after screen saver begins" is.
    func openLockScreenSettings() { open("com.apple.Lock-Screen-Settings.extension") }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }

    /// A copy of an app that came in a download carries its quarantine;
    /// the screen saver's host would refuse it.
    private static func unquarantine(_ url: URL) {
        var paths = [url.path]
        if let walk = FileManager.default.enumerator(atPath: url.path) {
            while let sub = walk.nextObject() as? String { paths.append(url.appendingPathComponent(sub).path) }
        }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }
}
