// A stand-in for Claude's quit prompt: a window with an ordinary Cancel button in its content,
// and, when told to on stdin, a native alert with Claude's three buttons, either as a sheet on
// that window or as an alert window of its own; with --other, an unrelated OK/Cancel alert.
// It prints "ready" once the window is up and "pressed: <title>" when the alert is answered,
// then exits. Used by tests/PromptTest.swift.
//
// With --chats, a stand-in for Claude's chat window instead (tests/ResumeTest.swift), laid out as
// Claude's Code tab reads through Accessibility: a window whose web area shows one chat at a
// time, by session id in its URL; a multi-line message box named Prompt with Add and a
// microphone beside it; Send only while the box holds text, Stop while a turn runs; Retry and
// Rewind in the transcript; and a decoy window showing another chat. Some chats add a side panel
// with an artifact page of its own, a next-step box of suggested replies, a box named only by
// its placeholder, or a page that loads only when told. "open <id>", "load <id>" and "state" on
// stdin answer when done. It prints "sent: <id> <text>" when a chat's Send is pressed and
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

/// One chat as the fixture holds it, and how its page is laid out.
final class Chat {
    enum Layout {
        /// Claude's Code tab as it is: the message box named Prompt, Add and the microphone
        /// beside it, and Send only once the box holds text.
        case plain
        /// A side panel beside the chat: the built-in browser's address field and an artifact,
        /// a page of its own inside the chat's page, with a Prompt box and Send button of its own.
        case sidePanel
        /// The next-step box above the message box with two suggested replies, in the same group
        /// as the box, and a Send control with no name, an icon only.
        case nextStep
        /// The message box named only by its placeholder, beside a side panel's address field.
        case placeholder
    }

    let id: String
    let title: String
    let layout: Layout
    var busy: Bool
    var draft: String
    /// The page shows, but not its message box until "load <id>".
    var loaded: Bool
    /// Pressing Send starts a turn; when false, the message goes but no turn shows.
    let startsTurn: Bool
    init(_ id: String, _ title: String, _ layout: Layout = .plain, busy: Bool = false, draft: String = "",
         loaded: Bool = true, startsTurn: Bool = true) {
        self.id = id; self.title = title; self.layout = layout; self.busy = busy; self.draft = draft
        self.loaded = loaded; self.startsTurn = startsTurn
    }
}

/// Claude's web content as Accessibility sees it: a web area whose URL names the page it shows.
final class WebArea: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXWebArea") }
}

/// A group, as Claude's composer and panels are.
final class Group: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

/// Claude's message box: a multi-line text area that tells the fixture when Accessibility sets
/// its text, as Claude's page reacts to the text by showing Send.
final class MessageBox: NSTextView {
    var changed: () -> Void = {}
    override func setAccessibilityValue(_ value: Any?) {
        super.setAccessibilityValue(value)
        changed()
    }
}

final class ChatsFixture: NSObject, NSApplicationDelegate {
    let chats: [String: Chat] = Dictionary(uniqueKeysWithValues: [
        Chat("local_other", "Something else"),
        Chat("local_target", "Fix the login bug"),
        Chat("local_second", "Write the release notes"),
        Chat("local_busy", "Still working", busy: true),
        Chat("local_draft", "Half typed", draft: "a note I haven't sent"),
        Chat("local_decoy", "Decoy chat"),
        Chat("local_panel", "Side panel open", .sidePanel),
        Chat("local_nextstep", "Next step showing", .nextStep),
        Chat("local_placeholder", "Named by placeholder", .placeholder),
        Chat("local_slow", "Slow to load", loaded: false),
        Chat("local_late", "Loads after a minute", loaded: false),
        Chat("local_never", "Never loads", loaded: false),
        Chat("local_mute", "No reply starts", startsTurn: false),
    ].map { ($0.id, $0) })
    var main: NSWindow!
    var decoy: NSWindow!
    /// What each window shows: its chat, message box, and the Send control while there is one.
    var shown: [ObjectIdentifier: (chat: Chat, box: MessageBox?, group: Group?, send: NSButton?)] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        main = window(at: NSPoint(x: 80, y: 80))
        decoy = window(at: NSPoint(x: 520, y: 80))
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

    /// "open <id>" shows a chat, "load <id>" finishes loading it, "state" prints every message
    /// box and the focus; each answers once done, so the test never waits on a guess.
    func command(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        if words.first == "open", words.count == 2, let chat = chats[words[1]] {
            show(chat, in: main)
            print("shown: \(chat.id)")
        }
        if words.first == "load", words.count == 2, let chat = chats[words[1]] {
            chat.loaded = true
            if let window = [main, decoy].first(where: { shown[ObjectIdentifier($0!)]?.chat === chat }) { show(chat, in: window!) }
            print("loaded: \(chat.id)")
        }
        if words.first == "state" {
            save()
            for chat in chats.values.sorted(by: { $0.id < $1.id }) { print("box: \(chat.id) [\(chat.draft)]") }
            print("focus: key=\(NSApp.keyWindow != nil) active=\(NSApp.isActive)")
        }
    }

    func window(at origin: NSPoint) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 420, height: 260)),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Claude"
        w.orderFrontRegardless()
        return w
    }

    /// Keep what each shown message box holds, as Claude keeps a chat's draft when another is opened.
    func save() {
        for (_, entry) in shown { if let box = entry.box { entry.chat.draft = box.string } }
    }

    func show(_ chat: Chat, in window: NSWindow) {
        save()
        let area = WebArea(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        area.setAccessibilityURL(URL(string: "https://claude.ai/epitaxy/\(chat.id)"))
        area.setAccessibilityTitle("\(chat.title) - Claude Code")
        // The transcript's buttons, which the resume step must never press.
        area.addSubview(button("Retry", chat, at: NSPoint(x: 10, y: 220)))
        area.addSubview(button("Rewind to here", chat, at: NSPoint(x: 100, y: 220)))
        if chat.layout == .sidePanel || chat.layout == .placeholder { area.addSubview(sidePanel(chat)) }
        var box: MessageBox?, group: Group?
        if chat.loaded {
            let dock = Group(frame: NSRect(x: 0, y: 0, width: 280, height: 110))
            let composer = Group(frame: NSRect(x: 0, y: 0, width: 280, height: 50))
            let b = MessageBox(frame: NSRect(x: 40, y: 10, width: 150, height: 30))
            b.string = chat.draft
            if chat.layout == .placeholder {
                b.setAccessibilityPlaceholderValue("Type / for commands")
            } else {
                b.setAccessibilityLabel("Prompt")
            }
            b.changed = { [weak self] in self?.refresh(window) }
            composer.addSubview(b)
            let add = NSPopUpButton(frame: NSRect(x: 5, y: 10, width: 30, height: 30))
            add.setAccessibilityLabel("Add")
            composer.addSubview(add)
            let record = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            record.frame = NSRect(x: 245, y: 10, width: 30, height: 30)
            record.setAccessibilityLabel("Press and hold to record")
            composer.addSubview(record)
            if chat.busy { composer.addSubview(button("Stop", chat, at: NSPoint(x: 195, y: 10), width: 45)) }
            if chat.layout == .nextStep {
                // The suggested replies, which the resume step must never press.
                composer.addSubview(button("Yes, go ahead", chat, at: NSPoint(x: 5, y: 45), width: 130))
                composer.addSubview(button("Not now", chat, at: NSPoint(x: 140, y: 45), width: 100))
                composer.frame.size.height = 80
            }
            dock.addSubview(composer)
            area.addSubview(dock)
            box = b
            group = composer
        }
        window.contentView = area
        window.title = "\(chat.title) - Claude Code"
        shown[ObjectIdentifier(window)] = (chat, box, group, nil)
        refresh(window)
    }

    /// A side panel: the browser's address field and an artifact with its own Prompt box and Send.
    func sidePanel(_ chat: Chat) -> Group {
        let panel = Group(frame: NSRect(x: 290, y: 0, width: 130, height: 210))
        let address = NSTextField(frame: NSRect(x: 5, y: 175, width: 120, height: 24))
        address.setAccessibilityLabel("Page URL")
        panel.addSubview(address)
        if chat.layout == .sidePanel {
            let artifact = WebArea(frame: NSRect(x: 0, y: 0, width: 130, height: 160))
            artifact.setAccessibilityURL(URL(string: "https://claude.ai/code/artifact/a1"))
            let own = Group(frame: NSRect(x: 0, y: 0, width: 130, height: 80))
            let prompt = NSTextView(frame: NSRect(x: 5, y: 40, width: 120, height: 30))
            prompt.setAccessibilityLabel("Prompt")
            own.addSubview(prompt)
            own.addSubview(button("Send message", chat, at: NSPoint(x: 5, y: 5), width: 120))
            artifact.addSubview(own)
            panel.addSubview(artifact)
        }
        return panel
    }

    /// Show Send beside a box that holds text and isn't running, as Claude does, and nothing
    /// there while it's empty. The next-step layout's Send has no name, only an icon.
    func refresh(_ window: NSWindow) {
        guard var entry = shown[ObjectIdentifier(window)], let box = entry.box, let group = entry.group else { return }
        let wanted = !entry.chat.busy && !box.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if wanted, entry.send == nil {
            let send = button(entry.chat.layout == .nextStep ? "" : "Send message", entry.chat, at: NSPoint(x: 195, y: 10), width: 45)
            if entry.chat.layout == .nextStep { send.image = NSImage(named: NSImage.goForwardTemplateName) }
            group.addSubview(send)
            entry.send = send
        } else if !wanted, let send = entry.send {
            send.removeFromSuperview()
            entry.send = nil
        }
        shown[ObjectIdentifier(window)] = entry
    }

    func button(_ title: String, _ chat: Chat, at origin: NSPoint, width: CGFloat = 80) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        b.frame = NSRect(origin: origin, size: NSSize(width: width, height: 30))
        b.identifier = NSUserInterfaceItemIdentifier(chat.id)
        return b
    }

    @objc func pressed(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? "?"
        guard let window = sender.window, let entry = shown[ObjectIdentifier(window)], entry.send === sender,
              let box = entry.box else {
            print("pressed: \(sender.title.isEmpty ? "(no name)" : sender.title) \(id)")
            return
        }
        print("sent: \(id) \(box.string)")
        box.string = ""
        // The turn starts: Claude shows Stop in place of Send.
        entry.chat.busy = entry.chat.startsTurn
        entry.chat.draft = ""
        show(entry.chat, in: window)
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
