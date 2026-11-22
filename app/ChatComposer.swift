// Sending a new message into one of Claude's chats through Accessibility, the way a person does:
// put the text in that chat's message box and press its send control. Kept apart from the app so
// tests/ResumeTest.swift drives the same code against a fixture window.

import ApplicationServices
import Foundation

/// Claude's window shows one chat in a web area whose URL ends in that chat's session id, so a
/// chat is found by its id, never by window order or position. Its message box is found by what it
/// is, the page's own editable text box (ComposerRule), not inside another page on it such as an
/// artifact. Claude shows the Send button beside the box only once the box holds text, and Stop
/// there while a turn runs. Only the send control is ever pressed: never Retry, Rewind, Stop, a
/// suggested reply or a control in another chat, and no key events are posted, so nothing depends
/// on keyboard focus.
enum ChatComposer {
    /// What Claude calls its message box, compared without case.
    static let promptName = "prompt"
    /// What a send control is called, compared without case.
    static let sendNames: Set<String> = ["send", "send message", "send prompt", "submit"]
    /// What the control that stops a running turn is called, compared without case.
    static let stopNames: Set<String> = ["stop", "stop response", "stop generating", "interrupt"]
    /// Never pressed as the send control, by the start of their names.
    static let neverPress = ["retry", "rewind", "stop", "interrupt", "fork", "cancel", "delete", "remove",
                             "edit", "copy", "undo", "clear", "reject", "deny", "dismiss", "discard"]
    /// How long Claude may take to show Send once the text is in the box, and to take the message once it is pressed.
    static let sendWait: TimeInterval = 3

    /// The message box of one chat and the controls Claude shows beside it.
    struct Found {
        let prompt: AXUIElement
        let by: ComposerRule.FoundBy
        /// The nearest group around the box that holds other controls (Add, the microphone, and
        /// Send or Stop when Claude shows them).
        let group: AXUIElement?
        let send: AXUIElement?
        let stop: AXUIElement?
        var text: String { (ChatComposer.attribute(prompt, kAXValueAttribute) as? String) ?? "" }
        /// Claude's empty box reads as a line break.
        var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    enum Sent: Equatable {
        /// The send control, named here, was pressed.
        case pressed(String)
        /// A turn is running: nothing was typed.
        case busy
        /// The box holds someone's unsent text: nothing was typed.
        case draft
        case refused(String)
    }

    /// One control in the group around the message box.
    private struct Control {
        let element: AXUIElement
        let role: String
        let name: String
        var enabled: Bool { (ChatComposer.attribute(element, kAXEnabledAttribute) as? Bool) != false }
        var label: String { role + ":" + name }
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
        let loading = attribute(areas[0], "AXLoaded") as? Bool == false || attribute(areas[0], "AXElementBusy") as? Bool == true
        guard let found = composer(in: areas[0]) else { return ChatScreen(loading: loading, busy: false, composer: false, draft: false) }
        return ChatScreen(loading: loading, busy: found.stop != nil, composer: true, draft: !found.empty)
    }

    /// Put `text` in the message box of the chat `session` and press its send control, once.
    /// Types nothing unless exactly one window shows that chat idle with an empty message box, and
    /// empties the box again when the text can't be sent. `trace` hears each step.
    static func send(_ text: String, session: String, in pids: [pid_t], trace: (String) -> Void = { _ in }) -> Sent {
        let areas = webAreas(showing: session, in: pids)
        guard areas.count == 1 else { return .refused(areas.isEmpty ? "Claude didn't show it" : "more than one window shows it") }
        trace("Claude's window shows the chat")
        guard let found = composer(in: areas[0]) else { return .refused("its message box wasn't found") }
        trace("found its message box: \(found.by.rawValue)")
        if found.stop != nil { return .busy }
        guard found.empty else { return .draft }
        let before = Set(controls(in: found.group).map(\.label))
        guard AXUIElementSetAttributeValue(found.prompt, kAXValueAttribute as CFString, text as CFString) == .success else {
            return .refused("Claude didn't take the text")
        }
        guard found.text.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
            empty(found.prompt)
            return .refused("Claude didn't take the text")
        }
        trace("put \u{201C}\(text)\u{201D} in it and read it back")
        // Claude shows Send once its page has the text: look for it until it appears.
        var control: (element: AXUIElement, name: String)?
        let deadline = Date().addingTimeInterval(sendWait)
        repeat {
            if let again = webAreas(showing: session, in: pids).first.flatMap(composer(in:)) {
                control = sendControl(again, appearedSince: before)
            }
            if control != nil { break }
            usleep(100_000)
        } while Date() < deadline
        guard let control else {
            empty(found.prompt)
            return .refused("its send button never appeared")
        }
        // Claude swaps Send for Stop as the press lands, which can fail the press's own call, so
        // the press is judged by what the chat shows next: the text gone from the box, or Stop.
        AXUIElementPerformAction(control.element, kAXPressAction as CFString)
        trace("pressed \(control.name)")
        let pressedAt = Date()
        repeat {
            let now = webAreas(showing: session, in: pids).first.flatMap(composer(in:))
            if now?.stop != nil || now?.empty == true { return .pressed(control.name) }
            usleep(100_000)
        } while Date().timeIntervalSince(pressedAt) < sendWait
        empty(found.prompt)
        return .refused("its send button didn't take the message")
    }

    // MARK: Finding things

    /// The web areas whose URL ends in `session`. Looks inside web areas that show something else,
    /// since Claude may nest its pages, and stops at one that shows the chat.
    private static func webAreas(showing session: String, in pids: [pid_t]) -> [AXUIElement] {
        pids.flatMap { pid -> [AXUIElement] in
            let windows = attribute(application(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
            return windows.flatMap { window -> [AXUIElement] in
                var found: [AXUIElement] = []
                var budget = 20000
                collect(window, depth: 0, budget: &budget) { element in
                    guard attribute(element, kAXRoleAttribute) as? String == "AXWebArea",
                          let url = attribute(element, kAXURLAttribute) as? URL, url.lastPathComponent == session else { return false }
                    found.append(element)
                    return true
                }
                return found
            }
        }
    }

    /// The chat's message box in its web area, by ComposerRule over the editable text boxes on the
    /// page itself, and the Send and Stop controls around it. Pages shown inside the chat's page,
    /// such as an artifact, are not the chat and are not searched.
    private static func composer(in area: AXUIElement) -> Found? {
        var boxes: [AXUIElement] = []
        var budget = 20000
        collect(area, depth: 0, budget: &budget) { element in
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWebArea", !CFEqual(element, area) { return true }
            if role == kAXTextAreaRole || role == kAXTextFieldRole, settable(element, kAXValueAttribute) { boxes.append(element) }
            return false
        }
        let described = boxes.map { box in
            ComposerRule.Box(named: [name(box), (attribute(box, kAXPlaceholderValueAttribute) as? String) ?? ""]
                                .contains { $0.lowercased() == promptName },
                             multiline: attribute(box, kAXRoleAttribute) as? String == kAXTextAreaRole,
                             focused: attribute(box, kAXFocusedAttribute) as? Bool == true)
        }
        guard let pick = ComposerRule.pick(described) else { return nil }
        let prompt = boxes[pick.index]
        let group = controlGroup(around: prompt, in: area)
        // Send and Stop sit in that group, or in the composer card one level out.
        let scope = group.flatMap { parent(of: $0, within: area) } ?? group
        var send: AXUIElement?, stop: AXUIElement?
        for control in controls(in: scope) where control.role == kAXButtonRole {
            if sendNames.contains(control.name.lowercased()) { send = send ?? control.element }
            if stopNames.contains(control.name.lowercased()) { stop = stop ?? control.element }
        }
        return Found(prompt: prompt, by: pick.by, group: group, send: send, stop: stop)
    }

    /// The control to press once the box holds the text: the enabled one named Send; else the one
    /// enabled plain button that appeared in the box's group with the text, unless its name is
    /// one never pressed. A suggested reply above the box was there before the text and is
    /// never the one.
    private static func sendControl(_ found: Found, appearedSince before: Set<String>) -> (element: AXUIElement, name: String)? {
        if let send = found.send, attribute(send, kAXEnabledAttribute) as? Bool != false { return (send, name(send)) }
        let appeared = controls(in: found.group).filter { control in
            control.role == kAXButtonRole && control.enabled && !before.contains(control.label)
                && !neverPress.contains { control.name.lowercased().hasPrefix($0) }
        }
        guard appeared.count == 1 else { return nil }
        return (appeared[0].element, appeared[0].name.isEmpty ? "the button that appeared beside it" : appeared[0].name)
    }

    /// The nearest ancestor of the box, within six levels and inside the chat's page, that holds
    /// a control besides the box.
    private static func controlGroup(around prompt: AXUIElement, in area: AXUIElement) -> AXUIElement? {
        var node = prompt
        for _ in 0..<6 {
            guard let up = parent(of: node, within: area) else { return nil }
            if !controls(in: up).isEmpty { return up }
            node = up
        }
        return nil
    }

    private static func parent(of element: AXUIElement, within area: AXUIElement) -> AXUIElement? {
        guard let up = attribute(element, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() else { return nil }
        let parent = up as! AXUIElement
        return CFEqual(parent, area) ? nil : parent
    }

    private static func controls(in container: AXUIElement?) -> [Control] {
        guard let container else { return [] }
        var found: [Control] = []
        var budget = 400
        collect(container, depth: 0, budget: &budget, maxDepth: 8) { element in
            let role = (attribute(element, kAXRoleAttribute) as? String) ?? ""
            guard [kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, kAXMenuButtonRole].contains(role) else { return false }
            found.append(Control(element: element, role: role, name: name(element)))
            return true
        }
        return found
    }

    /// Empty a box the app typed into, when what it typed can't be sent.
    private static func empty(_ prompt: AXUIElement) {
        AXUIElementSetAttributeValue(prompt, kAXValueAttribute as CFString, "" as CFString)
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

    private static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        return app
    }

    fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// The clock the resume step's waits run on, so the fixture test advances it instead of waiting.
struct ResumeClock {
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
}

/// Gets every chat a quit cut off or a usage limit stopped running again after a switch: lets
/// Claude resume the ones it marked, then opens each chat still idle, one at a time, waits for it
/// to load, and sends it the message once, waiting for the turn to start before the next. A chat
/// that isn't running after a pass is tried again on ResumeRule's schedule while nobody is using
/// the Mac, until it runs or someone types in it. What it touches in Claude is passed in, so the
/// fixture test drives the same loop.
struct ChatResumer {
    /// Show the chat in Claude's window (claude://code/continue?session=<id>).
    var open: (String) async -> Void
    /// Claude's process ids, whose windows are searched.
    var pids: () -> [pid_t]
    /// Claude's own record shows the chat ran after the switch.
    var running: (MovedChat) -> Bool
    var progress: (String) -> Void = { _ in }
    /// Each step it takes, for the app's resume log and `--test-resume`.
    var trace: (String) -> Void = { _ in }
    var trusted: () -> Bool = { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) }
    /// Seconds since anyone used this Mac's keyboard, mouse or trackpad.
    var idleSeconds: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    var clock = ResumeClock()
    /// Try again on ResumeRule's schedule; off for a single pass.
    var retrying = true
    /// False once another switch has started: Claude may be quitting or showing another account,
    /// so this resume types nothing more and stops.
    var current: () -> Bool = { true }

    static let superseded = "another switch started"

    static let noReply = "it was sent \u{201C}\(ResumeRule.message)\u{201D}, but no reply started"

    struct Report: Equatable {
        let chat: MovedChat
        let result: ResumeRule.Result
    }

    /// One report per chat in `wanted` (from ResumeRule.toResume), in order.
    func run(_ wanted: [MovedChat]) async -> [Report] {
        var chats: [MovedChat] = []
        var seen = Set<String>()
        for chat in wanted where seen.insert(chat.id).inserted { chats.append(chat) }
        guard !chats.isEmpty else { return [] }
        let started = clock.now()
        if chats.contains(where: \.interrupted) {
            progress("Waiting for Claude to resume chats…")
            await poll(ResumeRule.ownPassWait, every: 3) { chats.filter(\.interrupted).allSatisfy(running) }
        }
        var results: [String: ResumeRule.Result] = [:]
        var sentTo = Set<String>()
        var pass = 1
        while true {
            trace(pass == 1 ? "pass 1" : "pass \(pass), \(Int(clock.now().timeIntervalSince(started) / 60)) min after the first")
            for chat in chats where results[chat.id]?.settled != true {
                guard current() else { break }
                guard let tried = await attempt(chat, pass: pass, sentBefore: sentTo.contains(chat.id)) else { continue }
                if tried.sent { sentTo.insert(chat.id) }
                results[chat.id] = tried.result
                trace("\(chat.title): \(Self.describe(tried.result))")
            }
            let left = chats.filter { results[$0.id]?.settled != true }.count
            guard current() else {
                trace("\(Self.superseded); this resume stops")
                for chat in chats where results[chat.id]?.settled != true { results[chat.id] = .notResumed(Self.superseded) }
                break
            }
            guard retrying, ResumeRule.tryAgain(left: left, elapsed: clock.now().timeIntervalSince(started)) else { break }
            progress("\(left) stopped chat\(left == 1 ? " isn't" : "s aren't") running yet; trying again in a minute…")
            await clock.sleep(ResumeRule.retryEvery)
            pass += 1
        }
        return chats.map { Report(chat: $0, result: results[$0.id] ?? .notResumed("someone was using the Mac")) }
    }

    /// One try at one chat, or nil when this pass leaves it alone because someone is using the Mac
    /// and Claude shows another chat.
    private func attempt(_ chat: MovedChat, pass: Int, sentBefore: Bool) async -> (result: ResumeRule.Result, sent: Bool)? {
        if running(chat) { return (sentBefore ? .sent : .running, false) }
        // One message per chat per run: once it was sent, only its turn starting is looked for.
        if sentBefore { return (.notResumed(Self.noReply), false) }
        guard trusted() else { return (.notResumed("Claude Accounts has no Accessibility access"), false) }
        guard !pids().isEmpty else { return (.notResumed("Claude isn't open"), false) }
        ChatComposer.exposeWebContent(of: pids())
        if pass > 1, ChatComposer.screen(session: chat.id, in: pids()) == nil,
           !ResumeRule.mayRetry(secondsSinceInput: idleSeconds()) {
            trace("\(chat.title): someone is using the Mac, so it isn't opened on this pass")
            return nil
        }
        progress(pass == 1 ? "Resuming \(chat.title)…" : "Trying \(chat.title) again…")
        return await resume(chat)
    }

    private func resume(_ chat: MovedChat) async -> (result: ResumeRule.Result, sent: Bool) {
        await open(chat.id)
        trace("opened \(chat.title)")
        let opened = clock.now()
        var readyAt: Date?
        var said = ""
        while true {
            guard current() else { return (.notResumed(Self.superseded), false) }
            let screen = ChatComposer.screen(session: chat.id, in: pids())
            let state = Self.describe(screen)
            if state != said { trace(state); said = state }
            if let screen, screen.composer, !screen.loading, readyAt == nil { readyAt = clock.now() }
            let now = clock.now()
            switch ResumeRule.step(screen, interrupted: chat.interrupted, waited: now.timeIntervalSince(opened),
                                   shownFor: readyAt.map { now.timeIntervalSince($0) }) {
            case .wait:
                await clock.sleep(0.5)
            case .done(let result):
                return (result, false)
            case .send:
                switch ChatComposer.send(ResumeRule.message, session: chat.id, in: pids(), trace: trace) {
                case .busy: return (.running, false)
                case .draft: return (.draft, false)
                case .refused(let why): return (.notResumed(why), false)
                case .pressed:
                    var how = ""
                    let started = await poll(ResumeRule.startWait, every: 0.25) {
                        if ChatComposer.screen(session: chat.id, in: pids())?.busy == true { how = "Stop appeared"; return true }
                        if running(chat) { how = "Claude recorded new activity in the chat"; return true }
                        return false
                    }
                    trace(started ? "its turn started: \(how)" : "no turn started within \(Int(ResumeRule.startWait)) s")
                    return (started ? .sent : .notResumed(Self.noReply), true)
                }
            }
        }
    }

    private static func describe(_ screen: ChatScreen?) -> String {
        guard let screen else { return "Claude's window doesn't show the chat yet" }
        if screen.busy { return "the chat is running: Stop shows" }
        if screen.loading { return "the chat is still loading" }
        if !screen.composer { return "the chat shows, but not its message box yet" }
        return screen.draft ? "its message box holds unsent text" : "the chat is idle with an empty message box"
    }

    private static func describe(_ result: ResumeRule.Result) -> String {
        switch result {
        case .running: return "running"
        case .sent: return "sent \u{201C}\(ResumeRule.message)\u{201D}; running"
        case .draft: return "left alone: someone typed in it"
        case .notResumed(let why): return "not running yet: \(why)"
        }
    }

    /// Check `done` every `interval` seconds until it holds or `timeout` passes; returns whether it held.
    @discardableResult
    private func poll(_ timeout: TimeInterval, every interval: TimeInterval, _ done: () -> Bool) async -> Bool {
        let deadline = clock.now().addingTimeInterval(timeout)
        while !done() {
            guard clock.now() < deadline else { return false }
            await clock.sleep(interval)
        }
        return true
    }
}
