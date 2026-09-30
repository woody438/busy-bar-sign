import AppKit
import SwiftUI

/// The bar as a small floating window: just the device, on top of other
/// windows and on every Space. Drag it anywhere; pick its size from the menu
/// or by right-clicking it.
///
/// It's a non-activating panel, so dragging it never takes focus from the
/// call you're on.
@MainActor
final class FloatingWindow: NSObject, ObservableObject, NSMenuDelegate {

    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// Device width in points. At 2x these give exactly 10, 15 and 20
        /// pixels per LED, so the dots stay sharp.
        var width: CGFloat {
            switch self {
            case .small:  return 600
            case .medium: return 900
            case .large:  return 1200
            }
        }
    }

    @Published private(set) var isShown = false
    @Published var size: Size = Size(rawValue: UserDefaults.standard.string(forKey: "floatingSize") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(size.rawValue, forKey: "floatingSize")
            resize()
        }
    }

    private var panel: NSPanel?
    private let detector: CallDetector

    /// The device is 3840 x 664 in the simulator's units (case plus the
    /// controls along its top); a little headroom keeps them clear of the edge.
    private static let aspect = CGSize(width: 3840, height: 672)

    init(detector: CallDetector) {
        self.detector = detector
        super.init()
    }

    /// Whether it was showing when the app last quit.
    static var wasShown: Bool { UserDefaults.standard.bool(forKey: "floatingShown") }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        refreshShadow()
        isShown = true
        UserDefaults.standard.set(true, forKey: "floatingShown")
    }

    func hide() {
        panel?.orderOut(nil)
        isShown = false
        UserDefaults.standard.set(false, forKey: "floatingShown")
    }

    private func contentSize(for size: Size) -> NSSize {
        NSSize(width: size.width, height: (size.width * Self.aspect.height / Self.aspect.width).rounded())
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: contentSize(for: size)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false          // panels hide when their app isn't frontmost by default
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true                   // follows the device's outline
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        // The bar, with a transparent surface over it that handles the mouse:
        // drag to move, double-click for Do Not Disturb, right-click for sizes.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize(for: size)))
        let hosting = NSHostingView(rootView: BarDisplayView(detector: detector, style: .floating))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let surface = BarSurface(frame: container.bounds)
        surface.autoresizingMask = [.width, .height]
        surface.draggable = true
        surface.onDoubleClick = { [weak self] in self?.detector.toggleDND() }
        surface.menu = contextMenu()
        container.addSubview(surface)
        p.contentView = container

        // Where it was last time; otherwise the top-right of the main screen.
        if p.setFrameUsingName("FloatingBar") {
            // the size setting wins over a saved frame, keeping its top-left
            let want = contentSize(for: size), old = p.frame
            p.setFrame(NSRect(x: old.minX, y: old.maxY - want.height, width: want.width, height: want.height),
                       display: false)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame, s = p.frame.size
            p.setFrameOrigin(NSPoint(x: v.maxX - s.width - 24, y: v.maxY - s.height - 24))
        }
        p.setFrameAutosaveName("FloatingBar")
        return p
    }

    /// Changes size keeping the top-left corner where it is.
    private func resize() {
        guard let panel else { return }
        let new = contentSize(for: size)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - new.height, width: new.width, height: new.height),
                       display: true)
        refreshShadow()
    }

    /// A clear window's shadow is traced from what it has drawn, so it must be
    /// retraced once SwiftUI has drawn the device.
    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.panel?.invalidateShadow() }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let dnd = NSMenuItem(title: "Do Not Disturb", action: #selector(toggleDND(_:)), keyEquivalent: "")
        dnd.target = self
        dnd.tag = 1
        menu.addItem(dnd)
        menu.addItem(.separator())
        for s in Size.allCases {
            let item = NSMenuItem(title: s.label, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Hide Floating Window", action: #selector(close(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func pickSize(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let s = Size(rawValue: raw) { size = s }
    }

    @objc private func close(_ item: NSMenuItem) { hide() }
    @objc private func toggleDND(_ item: NSMenuItem) { detector.toggleDND() }

    /// Ticks the current size and Do Not Disturb as the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == 1 {
                item.title = detector.dndUntil == nil ? "Do Not Disturb (\(Int(detector.dndLength / 60)) min)" : "End Do Not Disturb"
            } else if let raw = item.representedObject as? String {
                item.state = raw == size.rawValue ? .on : .off
            }
        }
    }
}
