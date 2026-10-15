import Foundation

/*
 * What MeetingEngine needs from macOS Accessibility, and a walk of an
 * app's window as a tree. AXMeetingBackend is the real thing; Checks/meeting
 * scripts a fake Teams and Zoom. Elements are opaque objects: an
 * AXUIElement in the app, anything at all in a check.
 */

/// An element's attributes, read in one round trip.
struct MeetingAttrs: Equatable {
    var role = ""
    var subrole = ""
    var id = ""             // AXDOMIdentifier: the HTML id Teams gives its controls
    var desc = ""           // AXDescription: aria-label
    var title = ""          // AXTitle
    var help = ""           // AXHelp: the tooltip
    var value = ""          // AXValue, when it's text
    var number: Double?     // AXValue, when it's a number or a switch
    var enabled: Bool?      // AXEnabled; nil when not reported
    var mark = ""           // AXMenuItemMarkChar: a menu item's tick

    /// The name a screen reader would read.
    var label: String { !desc.isEmpty ? desc : !title.isEmpty ? title : help }
    /// Not reported counts as enabled.
    var isEnabled: Bool { enabled ?? true }
}

enum MeetingAXError: Error, Equatable {
    case invalid            // the element's gone
    case busy               // the app didn't answer in time
    case untrusted          // no Accessibility permission
    case failed(Int32)
}

/// Everything the engine asks of the operating system.
protocol MeetingBackend: AnyObject {
    func trusted() -> Bool
    /// The process running a meeting app, or 0.
    func findApp(_ app: MeetingApp) -> Int32
    func alive(_ pid: Int32) -> Bool
    func application(_ pid: Int32) -> AnyObject
    /// Asks a Chromium app to build its accessibility tree; `full` also flips
    /// AXEnhancedUserInterface, what VoiceOver sets.
    func enable(_ app: AnyObject, full: Bool)
    func windows(_ app: AnyObject) throws -> [AnyObject]
    func node(_ e: AnyObject) throws -> (MeetingAttrs, [AnyObject])
    func read(_ e: AnyObject) throws -> MeetingAttrs
    func actions(_ e: AnyObject) -> [String]
    func perform(_ e: AnyObject, _ action: String) throws
    func closeButton(_ window: AnyObject) -> AnyObject?
    func menuBar(_ app: AnyObject) -> AnyObject?
    /// Escape, sent to that process only.
    func postEscape(_ pid: Int32) -> Bool
    func frontmostPID() -> Int32
    func activate(_ pid: Int32)
}

/// One element of a walked subtree.
final class MeetingNode {
    let element: AnyObject
    var attrs = MeetingAttrs()
    let depth: Int
    private(set) weak var parent: MeetingNode?
    var children: [MeetingNode] = []
    /// Whether its attributes and children were read.
    var expanded = false

    init(_ element: AnyObject, depth: Int, parent: MeetingNode?) {
        self.element = element
        self.depth = depth
        self.parent = parent
    }

    /// Reads the subtree under `root` depth-first, in document order, until
    /// `stop` says so, the node budget runs out, or the app stops answering.
    static func walk(_ b: MeetingBackend, _ root: AnyObject, maxNodes: Int = 4000, maxDepth: Int = 80,
                     stop: ((MeetingNode) -> Bool)? = nil) -> (tree: MeetingNode, read: Int, truncated: Bool) {
        let top = MeetingNode(root, depth: 0, parent: nil)
        var stack = [top]
        var read = 0
        var truncated = false
        while let n = stack.popLast() {
            if read >= maxNodes { truncated = true; break }
            read += 1
            let got: (MeetingAttrs, [AnyObject])
            do { got = try b.node(n.element) } catch MeetingAXError.busy {
                truncated = true            // every further node would wait out the timeout
                break
            } catch { continue }
            n.attrs = got.0
            n.expanded = true
            n.children = got.1.map { MeetingNode($0, depth: n.depth + 1, parent: n) }
            if let stop, stop(n) { break }
            if n.depth + 1 > maxDepth { continue }
            stack.append(contentsOf: n.children.reversed())
        }
        return (top, read, truncated)
    }

    /// Visits the subtree in document order until `fn` returns false.
    func each(_ fn: (MeetingNode) -> Bool) {
        var stack = [self]
        while let n = stack.popLast() {
            if !fn(n) { return }
            stack.append(contentsOf: n.children.reversed())
        }
    }

    /// The first read node with this DOM id.
    func find(id: String) -> MeetingNode? {
        var found: MeetingNode?
        each { n in
            if n.expanded && n.attrs.id == id { found = n; return false }
            return true
        }
        return found
    }

    func contains(_ n: MeetingNode) -> Bool {
        var p: MeetingNode? = n
        while let x = p {
            if x === self { return true }
            p = x.parent
        }
        return false
    }

    /// The readable strings in the subtree: names, titles, text.
    func texts(limit: Int) -> [String] {
        var out: [String] = []
        each { n in
            if out.count >= limit { return false }
            guard n.expanded else { return true }
            let a = n.attrs
            for s in [a.desc, a.title, a.value, a.help] {
                let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, out.last != s { out.append(s) }
            }
            return true
        }
        return out
    }

    /// A dialog as Chromium shows it on the Mac (role="dialog" is an AXGroup
    /// with subrole AXApplicationDialog), or a sheet.
    var isDialog: Bool {
        ["AXApplicationDialog", "AXApplicationAlertDialog", "AXDialog", "AXSystemDialog"].contains(attrs.subrole)
            || attrs.role == "AXSheet"
    }

    /// Whether it sits in a popover, sheet or dialog.
    var inPopup: Bool {
        var p = parent
        while let x = p {
            if x.attrs.role == "AXPopover" || x.isDialog { return true }
            p = x.parent
        }
        return false
    }

    private var interesting: Bool {
        let a = attrs
        if !a.id.isEmpty || !a.label.isEmpty || !a.value.isEmpty { return true }
        if ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextArea", "AXTextField", "AXWindow", "AXSheet"].contains(a.role) {
            return true
        }
        return isDialog
    }

    /// The subtree as indented lines, for the diagnostics in the settings.
    func summary(maxLines: Int) -> String {
        var out = ""
        var lines = 0
        each { n in
            if lines >= maxLines { return false }
            guard n.expanded, n.interesting else { return true }
            out += String(repeating: "  ", count: min(n.depth - depth, 12)) + n.attrs.line + "\n"
            lines += 1
            return true
        }
        if lines >= maxLines { out += "… (cut short)\n" }
        return out
    }
}

extension MeetingAttrs {
    /// One line: role/subrole #id "name" =value [disabled].
    var line: String {
        var s = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        if !subrole.isEmpty { s += "/" + (subrole.hasPrefix("AX") ? String(subrole.dropFirst(2)) : subrole) }
        if !id.isEmpty { s += " #" + id }
        if !label.isEmpty { s += " “\(label.clipped(to: 90))”" }
        if !value.isEmpty, value != label { s += " =“\(value.clipped(to: 90))”" }
        if let number { s += " =\(number == number.rounded() ? String(Int(number)) : String(number))" }
        if enabled == false { s += " [disabled]" }
        return s
    }
}

extension String {
    /// At most `n` characters, with an ellipsis when cut.
    func clipped(to n: Int) -> String { count <= n ? self : String(prefix(n)) + "…" }
}
