// A stand-in for Claude's quit prompt: a window with an ordinary Cancel button in its content,
// and, when told to on stdin, a native alert with Claude's three buttons, either as a sheet on
// that window or as an alert window of its own; with --other, an unrelated OK/Cancel alert.
// It prints "ready" once the window is up and "pressed: <title>" when the alert is answered,
// then exits. Used by tests/PromptTest.swift.
//
// With --chats, a stand-in for Claude's chat window instead (tests/ResumeTest.swift): a window
// whose web area shows one chat at a time, by session id in its URL as Claude's does, with a
// Prompt message box, a Send message control (Stop while a turn runs) and Retry and Rewind
// buttons in the transcript; and a decoy window showing another chat with the same controls.
// "open <id>" on stdin shows that chat; "state" prints each chat's message box and whether the
// fixture has keyboard focus. It prints "sent: <id> <text>" when a Send control is pressed and
// "pressed: <title> <id>" for any other button. No window is ever made key or activated.

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
        if asSheet {
            alert.beginSheetModal(for: window) { response in
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                self.report(titles.indices.contains(index) ? titles[index] : "unknown")
            }
        } else {
            // The alert's own window, shown without a modal session so the fixture never takes
            // keyboard focus from whatever else is running.
            for button in alert.buttons {
                button.target = self
                button.action = #selector(pressed(_:))
            }
            alert.layout()
            alert.window.orderFrontRegardless()
        }
        print("alert shown")
    }

    @objc func pressed(_ sender: NSButton) { report(sender.title) }

    func report(_ title: String) {
        print("pressed: \(title)")
        exit(0)
    }
}

/// One chat as the fixture holds it.
final class Chat {
    let id: String
    let title: String
    var busy: Bool
    var draft: String
    init(_ id: String, _ title: String, busy: Bool = false, draft: String = "") {
        self.id = id; self.title = title; self.busy = busy; self.draft = draft
    }
}

/// Claude's web content as Accessibility sees it: a web area whose URL names the chat it shows.
final class WebArea: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXWebArea") }
}

/// The group around the message box, as Claude's composer is.
final class Group: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

final class ChatsFixture: NSObject, NSApplicationDelegate {
    let chats: [String: Chat] = Dictionary(uniqueKeysWithValues: [
        Chat("local_other", "Something else"),
        Chat("local_target", "Fix the login bug"),
        Chat("local_second", "Write the release notes"),
        Chat("local_busy", "Still working", busy: true),
        Chat("local_draft", "Half typed", draft: "a note I haven't sent"),
        Chat("local_decoy", "Decoy chat"),
    ].map { ($0.id, $0) })
    var main: NSWindow!
    var decoy: NSWindow!
    var shown: [ObjectIdentifier: (chat: Chat, prompt: NSTextField)] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        main = window(at: NSPoint(x: 80, y: 80))
        decoy = window(at: NSPoint(x: 480, y: 80))
        show(chats["local_other"]!, in: main)
        show(chats["local_decoy"]!, in: decoy)
        print("ready")
        var pending = ""
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { exit(0) }
            pending += String(decoding: data, as: UTF8.self)
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending = String(pending[pending.index(after: newline)...])
                DispatchQueue.main.async { self.command(line) }
            }
        }
    }

    func command(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        if words.first == "open", words.count == 2, let chat = chats[words[1]] { show(chat, in: main) }
        if words.first == "state" {
            save()
            for chat in chats.values.sorted(by: { $0.id < $1.id }) { print("box: \(chat.id) [\(chat.draft)]") }
            print("focus: key=\(NSApp.keyWindow != nil) active=\(NSApp.isActive)")
        }
    }

    func window(at origin: NSPoint) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 380, height: 200)),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Claude"
        w.orderFrontRegardless()
        return w
    }

    /// Keep what each shown message box holds, as Claude keeps a chat's draft when another is opened.
    func save() {
        for (_, entry) in shown { entry.chat.draft = entry.prompt.stringValue }
    }

    func show(_ chat: Chat, in window: NSWindow) {
        save()
        let area = WebArea(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        area.setAccessibilityURL(URL(string: "https://claude.ai/epitaxy/\(chat.id)"))
        area.setAccessibilityTitle("\(chat.title) - Claude Code")
        // The transcript's buttons, which the resume step must never press.
        area.addSubview(button("Retry", chat, at: NSPoint(x: 10, y: 150)))
        area.addSubview(button("Rewind to here", chat, at: NSPoint(x: 120, y: 150)))
        let composer = Group(frame: NSRect(x: 0, y: 0, width: 380, height: 60))
        let prompt = NSTextField(frame: NSRect(x: 10, y: 15, width: 240, height: 24))
        prompt.stringValue = chat.draft
        prompt.setAccessibilityLabel("Prompt")
        composer.addSubview(prompt)
        composer.addSubview(button(chat.busy ? "Stop" : "Send message", chat, at: NSPoint(x: 260, y: 12)))
        area.addSubview(composer)
        window.contentView = area
        window.title = "\(chat.title) - Claude Code"
        shown[ObjectIdentifier(window)] = (chat, prompt)
    }

    func button(_ title: String, _ chat: Chat, at origin: NSPoint) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        b.frame = NSRect(origin: origin, size: NSSize(width: 110, height: 30))
        b.identifier = NSUserInterfaceItemIdentifier(chat.id)
        return b
    }

    @objc func pressed(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "?"
        guard sender.title == "Send message", let chat = chats[id],
              let window = sender.window, let entry = shown[ObjectIdentifier(window)], entry.chat === chat else {
            print("pressed: \(sender.title) \(id)")
            return
        }
        print("sent: \(id) \(entry.prompt.stringValue)")
        entry.prompt.stringValue = ""
        // The turn starts: Claude shows Stop in place of Send.
        chat.busy = true
        show(chat, in: window)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--chats")
    ? ChatsFixture()
    : Fixture(asSheet: CommandLine.arguments.contains("--sheet"), other: CommandLine.arguments.contains("--other"))
app.delegate = delegate
app.run()
