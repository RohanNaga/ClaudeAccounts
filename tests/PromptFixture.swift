// A stand-in for Claude's quit prompt: a window with an ordinary Cancel button in its content,
// and, when told to on stdin, a native alert with Claude's three buttons, either as a sheet on
// that window or as an alert window of its own; with --other, an unrelated OK/Cancel alert.
// It prints "ready" once the window is up and "pressed: <title>" when the alert is answered,
// then exits. Used by tests/PromptTest.swift.

import AppKit

final class Fixture: NSObject, NSApplicationDelegate {
    let asSheet: Bool
    let other: Bool
    var window: NSWindow!

    init(asSheet: Bool, other: Bool) { self.asSheet = asSheet; self.other = other }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Prompt fixture"
        // A Cancel button outside any alert, which the prompt code must never press.
        let decoy = NSButton(title: "Cancel", target: nil, action: nil)
        decoy.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
        window.contentView?.addSubview(decoy)
        window.orderFrontRegardless()
        print("ready")
        FileHandle.standardInput.readabilityHandler = { handle in
            guard String(decoding: handle.availableData, as: UTF8.self).contains("show") else { return }
            handle.readabilityHandler = nil
            DispatchQueue.main.async { self.showAlert() }
        }
    }

    func showAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claude is still working"
        alert.informativeText = "Claude is working in 2 sessions. Quitting now will interrupt that work."
        let titles = other ? ["OK", "Cancel"] : ["Quit anyway", "Wait for Claude", "Cancel"]
        for title in titles { alert.addButton(withTitle: title) }
        func report(_ response: NSApplication.ModalResponse) {
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            print("pressed: \(titles.indices.contains(index) ? titles[index] : "unknown")")
            exit(0)
        }
        if asSheet {
            alert.beginSheetModal(for: window, completionHandler: report)
        } else {
            report(alert.runModal())
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let fixture = Fixture(asSheet: CommandLine.arguments.contains("--sheet"), other: CommandLine.arguments.contains("--other"))
app.delegate = fixture
app.run()
