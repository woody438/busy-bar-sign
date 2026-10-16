import AppKit
import Network
import ScreenSaver

// Loads the built screen saver as macOS's screen saver host does — the
// bundle's principal class, made with initWithFrame:isPreview: — in a
// window on the main screen, with a stand-in for the app answering on
// 127.0.0.1:47811, and checks it shows what the app says: on the wall's
// monitor as the wall is laid out, on any other as the wide bar. Mac only,
// so it runs in CI after the build rather than in Checks/run.sh.
//
//   swiftc Checks/saver-load/main.swift -o saver-load && ./saver-load "path/to/Busy Bar Sign.saver"
setvbuf(stdout, nil, _IOLBF, 0)
var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
guard let screen = NSScreen.main,
      let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
    print("FAIL no screen to show it on")
    exit(1)
}

// the stand-in app: BACK IN for half an hour, with the wall on this screen, stacked
let back = Int64(Date().timeIntervalSince1970 * 1000) + 30 * 60_000
var wallDisplay = number
var requests: [String] = []
let listener = try NWListener(using: .tcp, on: 47811)
listener.newConnectionHandler = { connection in
    connection.start(queue: .main)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
        requests.append(String(decoding: data ?? Data(), as: UTF8.self))
        let body = Data(#"{"dnd":false,"moment":{"at":\#(back),"kind":"countdown"},"state":"backIn","wall":{"display":\#(wallDisplay),"layout":"stacked"}}"#.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
listener.start(queue: .main)

// the screen saver, made as its host makes it
let path = CommandLine.arguments[1]
guard let bundle = Bundle(path: path), bundle.load(), let principal = bundle.principalClass else {
    print("FAIL couldn't load \(path) and its principal class")
    exit(1)
}
expect(NSStringFromClass(principal) == "BusyBarSignSaverView", "principal class \(NSStringFromClass(principal))")
expect(principal is ScreenSaverView.Type, "the principal class is a ScreenSaverView")
let allocated: AnyObject = (principal as AnyObject).perform(NSSelectorFromString("alloc"))!.takeRetainedValue()
let initialiser = NSSelectorFromString("initWithFrame:isPreview:")
typealias Initialiser = @convention(c) (AnyObject, Selector, NSRect, Bool) -> AnyObject?
let make = unsafeBitCast((allocated as! NSObject).method(for: initialiser), to: Initialiser.self)
guard let view = make(allocated, initialiser, NSRect(origin: .zero, size: screen.frame.size), false) as? ScreenSaverView else {
    print("FAIL initWithFrame:isPreview: made nothing")
    exit(1)
}
let window = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                      backing: .buffered, defer: false, screen: screen)
window.contentView = view
window.orderFrontRegardless()
view.startAnimation()

wait(4)
expect(view.value(forKey: "shownState") as? String == "backIn", "shows BACK IN (shows \(view.value(forKey: "shownState") ?? "?"))")
expect(view.value(forKey: "shownLayout") as? String == "stacked", "on the wall's monitor, the wall's layout")
expect(!requests.isEmpty && requests.allSatisfy { $0.hasPrefix("GET /status HTTP/1.1\r\n") && $0.contains("\r\nHost: 127.0.0.1:47811\r\n") },
       "asks as LocalAPI expects")
expect(!requests.contains { $0.lowercased().contains("\r\norigin:") }, "without an Origin")
expect(requests.contains { $0.contains("\r\nX-Busy-Bar-Saver: display=\(number); ") }, "saying which monitor it's on")
expect((3...6).contains(requests.count), "asks once a second (\(requests.count) in 4 s)")

// the wall's on another monitor: here, the wide bar
wallDisplay = number &+ 1
wait(2.5)
expect(view.value(forKey: "shownLayout") as? String == "wide", "on any other monitor, the wide bar")

// stopped: no more asking
view.stopAnimation()
wait(1.2)
let asked = requests.count
wait(2.5)
expect(requests.count == asked, "stops asking when stopped")

for f in failures { print("FAIL", f) }
print(failures.isEmpty ? "the screen saver loads, asks the app and shows the sign as designed" : "\(failures.count) screen saver checks failed")
exit(failures.isEmpty ? 0 : 1)
