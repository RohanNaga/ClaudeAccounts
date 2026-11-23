import AppKit
import SwiftUI

// Scenarios for named bugs, written from the model like the rest and kept with them. Each one is
// red on the commit that had its bug and green once it was fixed.

let bugScenarios: [Scenario] = [
    Scenario(pair: "(Rollback, the person declines the quit)", model: "an undo that can't quit Claude waits for Claude to close, then undoes") { h in
        await h.standard()
        h.claude.stale = [B]
        h.click("Beta")
        await h.run(until: { h.claude.actions.contains("launch") }, limit: 600)
        h.claude.quitBehaviour = .promptCancelled
        await h.run(until: { h.noticeHas("Quit Claude to undo the switch to Beta.") }, limit: 900)
        h.check(h.noticeHas("Quit Claude to undo the switch to Beta."), "the notice asks to quit Claude: \(h.notice)")
        let asked = h.quits
        await h.pass(1800)
        h.check(h.quits == asked, "no tick asks Claude to quit again: \(h.claude.actions)")
        h.check(h.noticeHas("Quit Claude to undo the switch to Beta."), "still waiting: \(h.notice)")
        h.claude.stop()
        await h.run(until: { h.claude.held == A }, limit: 900)
        h.check(h.noticeHas("Switch to Beta undone"), "the undo finished: \(h.notice)")
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "back on Alpha with its chat")
        h.check(SwitchJournal.load() == nil, "the journal is gone")
    },
    // Bug: a switch away saved S's login at quit even when Claude had not held S settled (fixed in c34dfc4).
    Scenario(pair: "(In use settling, click Switch on T)", model: "6.1: save S's login only if Claude holds S settled; 1: a saved login is taken while Claude held one seat settled") { h in
        await h.standard()
        let before = h.savedAt(A)
        h.check(before != nil, "setup: Alpha has a saved login")
        // Claude restarts on Alpha: it names Alpha again, and the click comes before that hold settles.
        h.claude.stop(); h.claude.start()
        await h.pass(h.claude.nameAfter + 10)
        h.check(h.claude.held == A, "setup: Claude names Alpha again: holds \(String(describing: h.claude.held))")
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 600)
        h.check(h.claude.held == B, "the switch to Beta went ahead: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.savedAt(A) == before, "Alpha's saved login is unchanged: saved at \(stamp(before)), now \(stamp(h.savedAt(A)))")
    },
    // Bug: the resume waited for a Send button that Claude shows only once the box holds text (fixed in cec0e4a).
    Scenario(pair: "(Resume, composer with no Send button)", model: "6.7: each moved chat stopped for usage and idle gets one \"resume\", typed through Accessibility") { h in
        guard AXIsProcessTrusted() else { h.check(false, "setup: this process needs Accessibility access to read the chat window"); return }
        guard let window = ChatWindow(h.claude) else { h.check(false, "setup: the chat window fixture did not start (CHAT_FIXTURE=<prompt-fixture binary>)"); return }
        defer { window.close() }
        do { try World.install(window, clock: h.clock) } catch { h.check(false, "setup: the world refused the chat window: \(error)"); return }
        await h.standard(chat: "local_target", onScreen: false)
        h.claude.logLimitStop("local_target")
        await h.run(until: { h.claude.held == B }, limit: 600)
        h.check(h.claude.held == B, "the automatic switch went to Beta: holds \(String(describing: h.claude.held)), \(h.notice)")
        await h.run(until: { !window.sent.isEmpty || h.noticeHas("Couldn't resume") }, limit: ClaudeTiming.settle + 35 * 60)
        h.check(window.sent == ["local_target resume"], "the stopped chat got one \"resume\" in its own box and its Send was pressed: the window saw \(window.sent), notice \(h.notice)")
        h.check(window.pressed.isEmpty, "no other control was pressed: \(window.pressed)")
    },
    // Bug: the menu grew with every row and ran past the bottom of the screen (fixed by MenuLayout, 761ee24).
    Scenario(pair: "(Menu, more seats than the screen holds)", model: "11: height at most the visible screen height minus the menu bar and a margin; the cards scroll") { h in
        _ = NSApplication.shared
        let seats = (1...30).map { StandSeat($0, org: 1) }
        try? h.rows(seats.enumerated().map { ("Seat \($0.offset + 1)", $0.element) })
        for seat in seats { h.usage.set(seat, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3 * 3600)) }
        h.claude.writeSignIn(seats[0])
        h.claudeHoldsSettled(); h.make(); await h.tick(); await h.settle()
        let screen = NSScreen.main?.visibleFrame.height ?? 0
        let menu = NSHostingView(rootView: MenuContent(store: h.store))
        menu.layoutSubtreeIfNeeded()
        let drawn = menu.fittingSize.height
        h.check(screen > 0, "setup: a screen to measure against")
        h.check(drawn >= 200, "setup: the menu drew its rows: \(drawn) pt")
        h.check(drawn <= screen, "the menu fits the screen: drawn \(drawn) pt, visible screen \(screen) pt, 30 seats")
    },
]

/// A saved-at time to the millisecond, since two saves in one test land within the same second.
func stamp(_ date: Date?) -> String { date.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "none" }

/// Claude's chat window as Accessibility reads it: tests/PromptFixture.swift --chats, laid out like
/// Claude's Code tab, where Send shows only once the message box holds text. The app reads and
/// types into it through its own Accessibility code (the real world's chatScreen and send); the
/// stand-in answers everything else, and a chat link opens that chat in the window.
final class ChatWindow: ClaudeWorld, @unchecked Sendable {
    let standIn: StandInClaude
    private let real = RealClaudeWorld()
    private let fixture = Process(), input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var lines: [String] = [], partial = ""

    init?(_ standIn: StandInClaude) {
        self.standIn = standIn
        guard let path = ProcessInfo.processInfo.environment["CHAT_FIXTURE"] else { return nil }
        // Started through a shell that exits at once, so the window is not a child of this test:
        // the harness counts a live child as the app still at work (it runs sqlite3) and would
        // never call the app settled. The window quits when its input closes; `<&0` keeps that
        // input, which a shell otherwise swaps for /dev/null on a job it starts in the background.
        fixture.executableURL = URL(fileURLWithPath: "/bin/sh")
        fixture.arguments = ["-c", "\"$0\" --chats <&0 & echo \"pid $!\"", path]
        fixture.standardInput = input
        fixture.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard let self, !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.withLock {
                self.partial += chunk
                while let newline = self.partial.firstIndex(of: "\n") {
                    self.lines.append(String(self.partial[..<newline]))
                    self.partial = String(self.partial[self.partial.index(after: newline)...])
                }
            }
        }
        guard (try? fixture.run()) != nil else { return nil }
        fixture.waitUntilExit()
        guard answered("ready"), let pid = printed("pid ").first.flatMap({ pid_t($0) }) else { close(); return nil }
        windowPid = pid
    }

    /// Closing the window's input quits it.
    func close() { try? input.fileHandleForWriting.close() }

    /// Every line the window printed that starts with `prefix`, without it.
    private func printed(_ prefix: String) -> [String] {
        lock.withLock { lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } }
    }
    /// Waits for the window's answer to a command; it answers as soon as it is done.
    private func answered(_ line: String) -> Bool {
        for _ in 0..<200 { if lock.withLock({ lines.contains(line) }) { return true }; usleep(50_000) }
        return false
    }
    /// What the window's Send controls sent, as "<session> <text>".
    var sent: [String] { printed("sent: ") }
    /// Any other button pressed (Retry, Rewind, Stop, a suggested reply), as "<title> <session>".
    var pressed: [String] { printed("pressed: ") }
    private var windowPid: pid_t = 0
    private var owners: [pid_t] { [windowPid] }

    // The window: the app's own Accessibility code against the fixture.
    var trusted: Bool { standIn.trusted }
    func exposeWebContent(of owners: [pid_t]) { real.exposeWebContent(of: self.owners) }
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen? { real.chatScreen(session: session, in: self.owners) }
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent {
        real.send(text, session: session, in: self.owners, trace: trace)
    }
    func open(link: String) async {
        await standIn.open(link: link)
        guard let id = link.components(separatedBy: "session=").last, link.contains("session=") else { return }
        // A window that has quit fails the write here, and the scenario's own checks say so.
        guard (try? input.fileHandleForWriting.write(contentsOf: Data("open \(id)\n".utf8))) != nil else { return }
        _ = answered("shown: \(id)")
    }

    // Everything else: the stand-in.
    var home: URL { standIn.home }
    var stateDir: URL { standIn.stateDir }
    var bundleId: String { standIn.bundleId }
    var dataDir: URL { standIn.dataDir }
    var logDir: URL { standIn.logDir }
    var installed: Bool { standIn.installed }
    func executable() -> String { standIn.executable() }
    func pids() -> [pid_t] { standIn.pids() }
    func windowIDs(_ owners: [pid_t]) -> Set<Int> { standIn.windowIDs(owners) }
    func requestQuit(_ pid: pid_t) async { await standIn.requestQuit(pid) }
    func launch() async { await standIn.launch() }
    func quitPromptOpen(in owners: [pid_t]) -> Bool { standIn.quitPromptOpen(in: owners) }
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool { standIn.pressQuitPrompt(title, in: owners) }
    func idleSeconds() -> TimeInterval { standIn.idleSeconds() }
    func notify(title: String, body: String) { standIn.notify(title: title, body: body) }
}
