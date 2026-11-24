import AppKit
import SwiftUI

// Scenarios for named bugs, written from the model like the rest and kept with them. Each one is
// red on the commit that had its bug and green once it was fixed.

/// The rows Alpha, Beta and Gamma with saved logins, chats local_one and local_two in Alpha's
/// folder, and Claude holding Alpha settled, with no app running yet.
@MainActor private func upgradeStart(_ h: Harness) async {
    try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
    for (n, seat) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await h.savedLogin(n, seat) }
    for chat in ["local_one", "local_two"] {
        h.claude.addChat(chat, in: A, lastActivity: h.clock.now())
        h.claude.screens[chat] = ChatScreen(busy: false, composer: true, draft: false)
    }
    h.claudeHoldsSettled()
}

let bugScenarios: [Scenario] = [
    // Bug: on the first launch over build 10, a usage stop from hours earlier became a five-hour
    // "out" on the seat in use, which read 40%; the notice said every seat was out while the others
    // were not read yet, and once they read the app switched away and typed "resume" (638ae63).
    Scenario(pair: "(First launch over the previous build, an old usage stop, the seat in use has room, the others answer with a wait)",
             model: "4: out only on a reading; a stop from an earlier hold marks nothing; 11: the notice says only what is known") { h in
        await upgradeStart(h)
        // Claude stopped local_one on Alpha for a limit its meters don't show, two hours ago.
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        h.clock.advance(2 * 3600)
        // The person came back to Alpha: Claude reopened on it, and a turn ended there.
        h.claude.stop(); h.claude.start()
        h.clock.advance(ClaudeTiming.settle + 5)
        h.claude.logTurnEnded("local_two")
        h.usage.set(A, fiveHour: 40, weekly: 6, resetsAt: h.clock.now().addingTimeInterval(160 * 60))
        for s in [B, C] {
            h.usage.set(s, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3 * 3600))
            h.usage.busy(s, until: h.clock.now().addingTimeInterval(4 * 60))
        }
        h.make(); await h.tick(); await h.settle()
        h.check(h.state("Alpha") == .inUse && h.meterText("Alpha") == nil, "Alpha In use with a fresh reading: \(String(describing: h.state("Alpha"))), \(String(describing: h.meterText("Alpha")))")
        h.check(h.meterText("Beta") == "not read yet" && h.state("Beta") == .ready, "Beta is not read yet, and not out: \(String(describing: h.meterText("Beta"))), \(String(describing: h.state("Beta")))")
        h.check(!h.noticeHas("out"), "no line calls any seat out: \(h.notice)")
        await h.run(until: { !h.claude.actions.isEmpty }, limit: 20 * 60)
        h.check(h.claude.actions.isEmpty && h.claude.held == A, "no automatic switch away from a seat with room: \(h.claude.actions), holds \(String(describing: h.claude.held))")
        h.check(h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing typed and nothing posted: \(h.claude.sent), \(h.claude.notifications)")
        h.check(h.meterText("Beta") == nil && h.meterText("Gamma") == nil, "Beta and Gamma read once the service's wait ends: \(String(describing: h.meterText("Beta"))), \(String(describing: h.meterText("Gamma")))")
        h.check(!h.noticeHas("out") && h.state("Alpha") == .inUse, "still no out claim, Alpha In use: \(h.notice)")
    },
    // Bug: the first launch over build 10 dropped its readings and asked every seat at once, so the
    // seats it had just read came back with a wait and showed "Not read yet" (638ae63).
    Scenario(pair: "(First launch over the previous build, its readings on disk)",
             model: "5: the previous build's readings carry over with their age; a seat read within meterEvery is not asked again at once") { h in
        await upgradeStart(h)
        let readAt = h.clock.now().addingTimeInterval(-30)
        let reset = h.clock.now().addingTimeInterval(3 * 3600)
        var cache: [String: [String: Any]] = [:]
        for (i, pct) in [40.0, 20.0, 100.0].enumerated() {
            cache["row\(i)"] = ["polledAt": readAt.timeIntervalSinceReferenceDate, "readAt": readAt.timeIntervalSinceReferenceDate,
                                "fiveHour": ["utilization": pct, "pct": Int(pct), "resetsAt": reset.timeIntervalSinceReferenceDate],
                                "weekly": ["utilization": 6.0, "pct": 6]]
        }
        let file = h.claude.stateDir.appendingPathComponent("usage-cache.json")
        try? JSONSerialization.data(withJSONObject: cache).write(to: file)
        for s in [A, B, C] { h.usage.set(s, fiveHour: 20, resetsAt: reset) }
        h.make()
        h.check(["Alpha", "Beta", "Gamma"].allSatisfy { h.meterText($0) == nil }, "every seat shows the previous build's reading, fresh: \(["Alpha", "Beta", "Gamma"].map { String(describing: h.meterText($0)) })")
        h.check(h.state("Gamma") == .out, "Gamma's carried reading at 100 reads out until its own reset: \(String(describing: h.state("Gamma")))")
        await h.tick(); await h.pass(60)
        h.check(h.usage.reads.isEmpty, "no seat read 30 s ago is asked again within the minute: \(h.usage.reads)")
        await h.pass(ClaudeTiming.meterEvery)
        h.check(Set(h.usage.reads) == Set([A, B, C].map(\.tag)), "each seat is read again on its schedule: \(h.usage.reads)")
        h.check(FileManager.default.fileExists(atPath: file.path), "the previous build's file stays, for a return to it")
    },
    // Bug: with the seat in use read out and one other seat not read yet, the notice said every seat
    // was out (638ae63).
    Scenario(pair: "(In use settled, limit stop, another seat not read yet)",
             model: "4 and 11: a wait claims every seat is out only when every other seat reads out or needs sign-in") { h in
        // The usage service keeps Beta waiting for 20 min from the start, so Beta is never read before then.
        h.usage.busy(B, until: h.clock.now().addingTimeInterval(20 * 60))
        await h.standard()
        let reset = h.clock.now().addingTimeInterval(2 * 3600)
        h.usage.set(C, fiveHour: 100, resetsAt: reset)
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.check(h.meterText("Beta") == "not read yet", "setup: Beta not read yet: \(String(describing: h.meterText("Beta")))")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(120)
        h.check(h.state("Alpha") == .inUse && h.claude.actions.isEmpty, "setup: Alpha reads out, nothing switched yet: \(h.claude.actions)")
        h.check(!h.noticeHas("Every seat is out") && !h.claude.notifications.contains { $0.hasPrefix("Every seat is out") },
                "no claim that every seat is out while Beta is not read yet: \(h.notice), \(h.claude.notifications)")
        await h.run(until: { h.claude.held == B }, limit: 25 * 60)
        h.check(h.claude.held == B, "once Beta reads with room, the automatic switch moves there: \(String(describing: h.claude.held)), \(h.notice)")
        await h.run(until: { h.resumed("local_one") }, limit: 300)
        h.check(h.resumed("local_one"), "the stopped chat gets one resume on Beta: \(h.claude.sent)")
    },

    // Bug: a turn that ended normally counted as a stop. Half an hour later the seat read 100 (use
    // of the same account elsewhere), and the app quit Claude and switched with no chat stopped
    // (3f5a7cbe and every build before it).
    Scenario(pair: "(In use settled, an ordinary turn ends, the seat reads 100 half an hour later, no chat stopped)",
             model: "4: only a chat Claude stopped for a limit after the seat last read with room starts a switch; a full meter alone quits nothing, and the switch comes once Claude stops a chat") { h in
        await h.standard()
        h.claude.logTurnEnded("local_one")
        await h.pass(30 * 60)
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(2 * ClaudeTiming.meterEvery)
        h.check(h.seat("Alpha")?.meters.fuller?.percent == 100 && h.meterText("Alpha") == nil,
                "setup: Alpha's fresh reading is 100: \(String(describing: h.seat("Alpha")?.meters.fuller))")
        h.check(h.claude.actions.isEmpty && h.claude.held == A, "Claude is not quit and stays on Alpha: \(h.claude.actions), holds \(String(describing: h.claude.held))")
        h.check(h.state("Alpha") == .inUse, "Alpha stays In use, its row showing the full meter: \(String(describing: h.state("Alpha")))")
        h.check(h.claude.sent.isEmpty && h.claude.notifications.isEmpty && !h.noticeHas("out"),
                "nothing typed, posted or said: typed \(h.claude.sent), posted \(h.claude.notifications), notice \(h.notice)")
        // The person sends a message; Claude stops the chat for the limit.
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 5 * 60)
        h.check(h.claude.held == B, "once Claude stops the chat, the automatic switch moves to Beta: \(String(describing: h.claude.held)), \(h.claude.actions)")
        await h.run(until: { h.resumed("local_one") }, limit: 300)
        h.check(h.claude.sent == ["local_one resume"], "the stopped chat gets one resume on Beta: \(h.claude.sent)")
    },
    // Bug: when the usage service stalled past the 15 min freshness during a real wait, the wait's
    // line disappeared and "Every seat is out" was posted a second time once reads came back (3f5a7cbe).
    Scenario(pair: "(Every seat out, the usage service stalls past freshness)",
             model: "7 and 11: one notification per wait; its line stays while the readings are stale, until a fresh reading ends the wait") { h in
        await h.standard()
        let reset = h.now.addingTimeInterval(4 * 3600)
        for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(5 * 60)
        let posted = { h.claude.notifications.filter { $0.hasPrefix("Every seat is out") }.count }
        h.check(h.noticeHas("Every seat is out. Chats resume") && posted() == 1, "setup: the wait is told once: \(h.notice), \(h.claude.notifications)")
        for s in [A, B, C] { h.usage.busy(s, until: h.now.addingTimeInterval(40 * 60)) }
        var staleSeen = false, lineLost: [String]? = nil
        await h.run(until: {
            if h.meterText("Alpha") != nil { staleSeen = true }
            if lineLost == nil, !h.noticeHas("Every seat is out. Chats resume") { lineLost = h.notice }
            return false
        }, limit: 50 * 60)
        h.check(staleSeen, "setup: Alpha's reading went stale during the stall: \(String(describing: h.meterText("Alpha")))")
        h.check(lineLost == nil, "the wait's line stays through the stall: lost as \(String(describing: lineLost))")
        h.check(posted() == 1, "\"Every seat is out\" is posted once for the whole wait: \(h.claude.notifications)")
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty, "nothing quit or typed: \(h.claude.actions), typed \(h.claude.sent)")
        // A fresh reading ends the wait: Beta has room again.
        h.usage.set(B, fiveHour: 20, resetsAt: reset)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 15 * 60)
        h.check(h.claude.held == B && h.claude.sent == ["local_one resume"], "once Beta reads with room the wait ends in a switch and one resume: holds \(String(describing: h.claude.held)), typed \(h.claude.sent)")
        h.check(posted() == 1, "still one wait notification: \(h.claude.notifications)")
    },
    // Bug: a stop in a hold's first minute was resumed once while the seat read with room, so
    // "resume" was typed into a chat Claude had just refused (3f5a7cbe and before).
    Scenario(pair: "(Claude reopens on the seat in use and stops a chat in its first minute, the seat reads with room)",
             model: "4 and 7: a stop before the hold settles counts against no seat; nothing is typed into a chat Claude refused while the seat reads with room") { h in
        await h.standard()
        h.usage.set(A, fiveHour: 40, resetsAt: h.now.addingTimeInterval(3 * 3600))
        h.claude.stop(); h.claude.start()
        h.clock.advance(10)
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(15 * 60)
        h.check(h.claude.sent.isEmpty && !h.claude.actions.contains { $0.hasPrefix("open ") },
                "nothing opened or typed while Alpha reads with room: typed \(h.claude.sent), \(h.claude.actions)")
        h.check(h.claude.actions.isEmpty && h.claude.held == A && h.state("Alpha") == .inUse, "Alpha stays In use, nothing quit: \(h.claude.actions)")
        h.check(h.claude.notifications.isEmpty && !h.noticeHas("out"), "nothing posted or said: \(h.claude.notifications), \(h.notice)")
    },
    // Hardening: the only brake on automatic switches was the failed-target cool-down, so switches
    // that succeeded could follow each other as fast as seats read out (3f5a7cbe).
    Scenario(pair: "(Automatic switch, the new seat runs out minutes later)",
             model: "4: the next automatic switch waits autoSwitchSpacing (15 min) after one that didn't fail; the chats wait meanwhile") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        guard let first = h.claude.at("quit").first else { h.check(false, "setup: the first switch ran: \(h.claude.actions)"); return }
        h.check(h.claude.held == B, "setup: the first switch moved to Beta: \(String(describing: h.claude.held))")
        await h.pass(2 * 60)
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        let quits = h.quits
        await h.run(until: { h.quits > quits }, limit: 30 * 60)
        let second = h.claude.at("quit").dropFirst(quits).first
        h.check(second.map { $0 >= first.addingTimeInterval(Limits.autoSwitchSpacing - 5) } ?? false,
                "no second automatic switch within 15 min of the first: second quit \(second.map { "\(Int($0.timeIntervalSince(first))) s" } ?? "never") after the first")
        h.check(second.map { $0 <= first.addingTimeInterval(Limits.autoSwitchSpacing + 30) } ?? false,
                "and it comes once the 15 min are up: second quit \(second.map { "\(Int($0.timeIntervalSince(first))) s" } ?? "never") after the first")
        await h.run(until: { h.claude.held == C && !h.switchInFlight }, limit: 10 * 60)
        h.check(h.claude.held == C, "the second switch moves to Gamma: \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(Limits.autoSwitchSpacing == 15 * 60, "autoSwitchSpacing is 15 min: \(Limits.autoSwitchSpacing)")
    },

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
        h.claude.logLimitStop("local_target", seatReadsFull: true)
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
        // A 13-inch laptop's visible height (section 11), not the host's screen: on a tall display
        // an unbounded menu of 30 seats would fit and pass.
        let screen: CGFloat = 900
        let menu = NSHostingView(rootView: MenuPanel(seats: h.store.seats, notice: h.store.notice, firstRun: h.store.firstRun,
                                                     visibleScreenHeight: screen))
        menu.layoutSubtreeIfNeeded()
        let drawn = menu.fittingSize.height
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
