// Sending a new message into one of Claude's chats through Accessibility, the way a person does:
// put the text in that chat's message box and press its send control. Kept apart from the app so
// tests/ResumeTest.swift drives the same code against a fixture window.

import ApplicationServices
import Foundation

/// Claude's window shows one chat in a web area whose URL ends in that chat's session id, so a
/// chat is found by its id, never by window order or position. Its message box is the text area
/// named Prompt, and its send control is the Send button beside it; a running turn shows Stop
/// there instead. Only that one button is ever pressed: never Retry, Rewind, Stop or a control in
/// another chat, and no key events are posted, so nothing depends on keyboard focus.
enum ChatComposer {
    static let promptName = "Prompt"
    static let sendNames: Set<String> = ["Send message", "Send"]
    static let stopName = "Stop"

    /// The message box and the controls beside it of the chat `session`, when exactly one window shows it.
    struct Found {
        let prompt: AXUIElement
        let send: AXUIElement?
        let stop: AXUIElement?
        var text: String { (attribute(prompt, kAXValueAttribute) as? String) ?? "" }
    }

    enum Sent: Equatable {
        case pressed
        case refused(String)
    }

    /// Ask Claude to expose its web content to Accessibility. Electron builds that tree only for
    /// assistive apps that set this; it changes nothing on screen.
    static func exposeWebContent(of pids: [pid_t]) {
        for pid in pids {
            AXUIElementSetAttributeValue(application(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// The chat as the resume rule sees it, or nil when no single window shows it.
    static func screen(session: String, in pids: [pid_t]) -> ChatScreen? {
        let areas = webAreas(showing: session, in: pids)
        guard areas.count == 1 else { return nil }
        guard let found = composer(in: areas[0]) else { return ChatScreen(busy: false, composer: false, draft: false) }
        return ChatScreen(busy: found.stop != nil, composer: found.send != nil,
                          draft: !found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Put `text` in the message box of the chat `session` and press its send control, once.
    /// Refuses, leaving the chat as it was, unless exactly one window shows that chat idle with an
    /// empty message box.
    static func send(_ text: String, session: String, in pids: [pid_t]) -> Sent {
        let areas = webAreas(showing: session, in: pids)
        guard areas.count == 1 else { return .refused("Claude didn't show it") }
        guard let found = composer(in: areas[0]), found.send != nil else { return .refused("its message box wasn't found") }
        guard found.stop == nil else { return .refused("it was already running") }
        guard found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .refused("it has an unsent draft") }
        guard AXUIElementSetAttributeValue(found.prompt, kAXValueAttribute as CFString, text as CFString) == .success,
              found.text == text else {
            return .refused("Claude didn't take the text")
        }
        // The send control turns on once the page has seen the text; look it up again for that.
        var button: AXUIElement?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let again = webAreas(showing: session, in: pids).first.flatMap(composer(in:)), let send = again.send,
               attribute(send, kAXEnabledAttribute) as? Bool != false {
                button = send
                break
            }
            usleep(100_000)
        } while Date() < deadline
        guard let button else {
            AXUIElementSetAttributeValue(found.prompt, kAXValueAttribute as CFString, "" as CFString)
            return .refused("its send button stayed off")
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else {
            AXUIElementSetAttributeValue(found.prompt, kAXValueAttribute as CFString, "" as CFString)
            return .refused("its send button didn't respond")
        }
        return .pressed
    }

    // MARK: Finding things

    private static func webAreas(showing session: String, in pids: [pid_t]) -> [AXUIElement] {
        pids.flatMap { pid -> [AXUIElement] in
            let windows = attribute(application(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
            return windows.flatMap { window -> [AXUIElement] in
                var found: [AXUIElement] = []
                var budget = 5000
                collect(window, depth: 0, budget: &budget) { element in
                    guard attribute(element, kAXRoleAttribute) as? String == "AXWebArea",
                          let url = attribute(element, kAXURLAttribute) as? URL else { return false }
                    if url.lastPathComponent == session { found.append(element) }
                    return true
                }
                return found
            }
        }
    }

    /// The message box in a chat's web area and the send and stop controls in the nearest group
    /// around it. The transcript's buttons (Retry, Rewind to here, Fork from here) are outside it.
    private static func composer(in area: AXUIElement) -> Found? {
        var prompts: [AXUIElement] = []
        var budget = 20000
        collect(area, depth: 0, budget: &budget) { element in
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == kAXTextAreaRole || role == kAXTextFieldRole, name(element) == promptName { prompts.append(element) }
            return false
        }
        guard prompts.count == 1 else { return nil }
        var container: AXUIElement = prompts[0]
        for _ in 0..<8 {
            guard let parent = attribute(container, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            container = parent as! AXUIElement
            if CFEqual(container, area) { break }
            let buttons = controls(in: container)
            if buttons.send != nil || buttons.stop != nil {
                return Found(prompt: prompts[0], send: buttons.send, stop: buttons.stop)
            }
        }
        return Found(prompt: prompts[0], send: nil, stop: nil)
    }

    private static func controls(in container: AXUIElement) -> (send: AXUIElement?, stop: AXUIElement?) {
        var send: AXUIElement?, stop: AXUIElement?
        var budget = 400
        collect(container, depth: 0, budget: &budget, maxDepth: 8) { element in
            guard attribute(element, kAXRoleAttribute) as? String == kAXButtonRole else { return false }
            let label = name(element)
            if sendNames.contains(label) { send = send ?? element }
            if label == stopName { stop = stop ?? element }
            return true
        }
        return (send, stop)
    }

    /// Visit `element` and its descendants; `visit` returns true to skip an element's children.
    private static func collect(_ element: AXUIElement, depth: Int, budget: inout Int, maxDepth: Int = 60,
                                _ visit: (AXUIElement) -> Bool) {
        budget -= 1
        guard budget > 0 else { return }
        if visit(element) { return }
        guard depth < maxDepth else { return }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            collect(child, depth: depth + 1, budget: &budget, maxDepth: maxDepth, visit)
        }
    }

    /// An element's accessible name: its title, else its description.
    private static func name(_ element: AXUIElement) -> String {
        if let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty { return title }
        return (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        return app
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// Gets every chat a quit cut off or a usage limit stopped running again after a switch: lets
/// Claude resume the ones it marked, then opens each chat still idle, one at a time, and sends it
/// the message once, waiting for the turn to start before the next. What it touches in Claude is
/// passed in, so the fixture test drives the same loop.
struct ChatResumer {
    /// Show the chat in Claude's window (claude://code/continue?session=<id>).
    var open: (String) async -> Void
    /// Claude's process ids, whose windows are searched.
    var pids: () -> [pid_t]
    /// Claude's own record shows the chat ran after the switch.
    var running: (MovedChat) -> Bool
    var progress: (String) -> Void = { _ in }
    var trusted: () -> Bool = { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) }

    struct Report: Equatable {
        let chat: MovedChat
        let result: ResumeRule.Result
    }

    /// One report per chat in `wanted` (from ResumeRule.toResume), in order.
    func run(_ wanted: [MovedChat]) async -> [Report] {
        guard !wanted.isEmpty else { return [] }
        if wanted.contains(where: \.interrupted) {
            progress("Waiting for Claude to resume chats…")
            await poll(ResumeRule.ownPassWait, every: 3) { wanted.filter(\.interrupted).allSatisfy(running) }
        }
        guard trusted() else {
            return wanted.map { Report(chat: $0, result: running($0) ? .running : .notResumed("Claude Accounts has no Accessibility access")) }
        }
        ChatComposer.exposeWebContent(of: pids())
        var reports: [Report] = []
        var sent = Set<String>()
        for chat in wanted where sent.insert(chat.id).inserted {
            if running(chat) {
                reports.append(Report(chat: chat, result: .running))
                continue
            }
            progress("Resuming \(chat.title)…")
            reports.append(Report(chat: chat, result: await resume(chat)))
        }
        return reports
    }

    private func resume(_ chat: MovedChat) async -> ResumeRule.Result {
        await open(chat.id)
        let opened = Date()
        var shownAt: Date?
        while true {
            let screen = ChatComposer.screen(session: chat.id, in: pids())
            if screen != nil, shownAt == nil { shownAt = Date() }
            switch ResumeRule.step(screen, interrupted: chat.interrupted, waited: Date().timeIntervalSince(opened),
                                   shownFor: shownAt.map { Date().timeIntervalSince($0) }) {
            case .wait:
                try? await Task.sleep(nanoseconds: 250_000_000)
            case .done(let result):
                return result
            case .send:
                switch ChatComposer.send(ResumeRule.message, session: chat.id, in: pids()) {
                case .refused(let why): return .notResumed(why)
                case .pressed:
                    let started = await poll(ResumeRule.startWait, every: 0.25) {
                        ChatComposer.screen(session: chat.id, in: pids())?.busy == true || running(chat)
                    }
                    return started ? .sent : .notResumed("it was sent \u{201C}\(ResumeRule.message)\u{201D}, but no reply started")
                }
            }
        }
    }

    /// Check `done` every `interval` seconds until it holds or `timeout` passes; returns whether it held.
    @discardableResult
    private func poll(_ timeout: TimeInterval, every interval: TimeInterval, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return true
    }
}
