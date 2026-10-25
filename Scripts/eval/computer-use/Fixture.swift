import AppKit
import ApplicationServices

// A real AppKit process. stdin exposes observation and shutdown only; it cannot
// fill fields, click controls, or manufacture a successful task.
@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    let runID = UUID().uuidString
    let order = "ORDER-" + String(UUID().uuidString.prefix(6)).uppercased()
    let field = NSTextField()
    let confirm = NSButton(checkboxWithTitle: "Confirm order", target: nil, action: nil)
    let save = NSButton(title: "Save order", target: nil, action: nil)
    let receiptLabel = NSTextField(labelWithString: "Receipt: pending")
    var window: NSWindow!
    var receipt = ""
    var savedText = ""
    var saves = 0
    var attempts = 0
    var edits = 0
    var clicks = 0
    var aborted = false
    var escapeMonitor: Any?
    var layout = Int.random(in: 0...2)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) else { emit(["error": "No main display"]); NSApp.terminate(nil); return }
        window = AcceptanceWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "MCA Computer Use Acceptance"
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = true
        // Cover user content while production full-display screenshots are taken.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { self.abort(); return nil }
            return event
        }
        let x = max(60, (view.bounds.width - 650) / 2) + CGFloat(layout * 20)
        let top = view.bounds.height - max(140, view.bounds.height * 0.22)
        func label(_ text: String, _ y: CGFloat, size: CGFloat = 23) {
            let label = NSTextField(labelWithString: text)
            label.textColor = .black
            label.font = .systemFont(ofSize: size)
            label.frame = CGRect(x: x, y: y, width: 680, height: 42)
            view.addSubview(label)
        }
        label("MCA Computer Use — native acceptance", top, size: 28)
        label("Copy the order code, confirm, then save once.", top - 65)
        label("Order code: \(order)", top - 120, size: 28)
        field.frame = CGRect(x: x, y: top - 185, width: 500, height: 42)
        field.font = .systemFont(ofSize: 25)
        field.placeholderString = "Enter order code"
        field.target = self
        field.action = #selector(edited)
        NotificationCenter.default.addObserver(self, selector: #selector(edited), name: NSControl.textDidChangeNotification, object: field)
        view.addSubview(field)
        confirm.frame = CGRect(x: x, y: top - 250, width: 300, height: 40)
        confirm.font = .systemFont(ofSize: 23)
        confirm.target = self
        confirm.action = #selector(confirmed)
        view.addSubview(confirm)
        save.frame = CGRect(x: x + CGFloat(layout == 1 ? 280 : 0), y: top - 320, width: 220, height: 48)
        save.font = .systemFont(ofSize: 23)
        save.target = self
        save.action = #selector(saveOrder)
        view.addSubview(save)
        receiptLabel.frame = CGRect(x: x, y: top - 400, width: 680, height: 60)
        receiptLabel.font = .monospacedSystemFont(ofSize: 27, weight: .medium)
        receiptLabel.textColor = .black
        view.addSubview(receiptLabel)
        label("Live test in progress. Press Esc to abort.", 45, size: 18)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Borderless windows need explicit key/main support (see AcceptanceWindow).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.emit(self.status()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { NSApp.terminate(nil) }
    }

    @objc func edited() { edits += 1 }
    @objc func confirmed() { clicks += 1 }
    func abort() {
        aborted = true
        field.isEnabled = false
        confirm.isEnabled = false
        save.isEnabled = false
        window.makeFirstResponder(nil)
        receiptLabel.stringValue = "Stopping — waiting for the runner."
        // Keep the opaque window up until the runner stops its MCP process.
        // Closing it during an in-flight type could send remaining keys elsewhere.
    }
    @objc func saveOrder() {
        attempts += 1
        guard field.stringValue == order, confirm.state == .on, saves == 0 else {
            receiptLabel.stringValue = "Check the code and confirmation."
            return
        }
        savedText = field.stringValue
        saves += 1
        // Neither a prompt nor the MCP tool result knows this before the click.
        receipt = "R-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
        receiptLabel.stringValue = "Receipt: \(receipt)"
    }

    func status() -> [String: Any] {
        func center(_ control: NSView) -> [Double] {
            let r = window.convertToScreen(control.convert(control.bounds, to: nil))
            let display = CGDisplayBounds(CGMainDisplayID())
            return [r.midX, display.height - r.midY]
        }
        return ["run_id": runID, "pid": ProcessInfo.processInfo.processIdentifier,
                "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                "visible": window.isVisible, "width": window.frame.width, "height": window.frame.height,
                "covers_display": window.frame.size == CGDisplayBounds(CGMainDisplayID()).size && window.frame.origin == .zero,
                "aborted": aborted,
                "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(),
                "order": order, "text": field.stringValue, "confirmed": confirm.state == .on,
                "saved_text": savedText, "saves": saves, "attempts": attempts, "edits": edits,
                "confirmation_clicks": clicks, "receipt": receipt, "layout": layout,
                "field": center(field), "confirm": center(confirm), "save": center(save)]
    }

    func handle(_ line: String) {
        switch line {
        case "status": emit(status())
        case "quit": NSApp.terminate(nil)
        default: emit(["error": "Only status and quit are supported"])
        }
    }

    func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

// AppKit's default borderless NSWindow refuses keyboard focus.
@MainActor
final class AcceptanceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? Fixture)?.abort() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let fixture = Fixture()
app.delegate = fixture
DispatchQueue.global().async {
    while let line = readLine() { DispatchQueue.main.async { fixture.handle(line) } }
    DispatchQueue.main.async { NSApp.terminate(nil) }
}
app.run()
