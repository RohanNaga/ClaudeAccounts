import Foundation

// The fifth review's gaps, kept (reviewer-ca-27-5, probes F1, F6a, F6c, F8 and F9): the spacing
// outlives a failed automatic switch, a hand Switch early in the app's run keeps the login it
// leaves, a relaunch after two log rotations keeps Claude's hold, a refusal logged before the app
// ran holds a switch back, and an automatic switch that can't press Claude's prompt says so once.
// Each fails on 2140a83.

/// Claude rotates main.log the way it does: main.log becomes main1.log, main1 becomes main2 and so on.
func rotate(_ c: StandInClaude) {
    let fm = FileManager.default, d = c.logDir
    for n in stride(from: 3, through: 1, by: -1) {
        let from = d.appendingPathComponent(ClaudeFiles.rotatedLog(n)), to = d.appendingPathComponent(ClaudeFiles.rotatedLog(n + 1))
        if fm.fileExists(atPath: from.path) { try? fm.removeItem(at: to); try? fm.moveItem(at: from, to: to) }
    }
    try? fm.moveItem(at: d.appendingPathComponent(ClaudeFiles.log), to: d.appendingPathComponent(ClaudeFiles.rotatedLog(1)))
    fm.createFile(atPath: d.appendingPathComponent(ClaudeFiles.log).path, contents: Data())
}

@MainActor extension Harness {
    /// Claude has run on Alpha for a while and its log goes on: the app relaunches 20 s before a hand
    /// Switch to Beta, so the app's own clock has not seen the hold settle.
    func handSwitchEarlyInTheAppsRun() async {
        claude.log("[heartbeat] still running")
        make(); await tick(); await settle()
        await pass(20)
        check(store.facts().hold.map { !$0.settled(at: now) } ?? false, "setup: the app's clock has not seen Alpha's hold settle, so nothing automatic may act on it yet")
        click("Beta")
        await run(until: { claude.held == B && !switchInFlight }, limit: 10 * 60)
    }
}

let reviewFiveScenarios: [Scenario] = [
    Scenario(pair: "(An automatic switch to Beta rolls back because Claude refuses Beta's login, then Claude stops the chat again at once)",
             model: "review F1: a failed automatic switch keeps the 15 minutes between automatic switches; the next stop shows when it goes and goes then") { h in
        await h.standard()
        h.claude.stale = [B]
        await h.pass(2 * 60)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == A && h.launches >= 2 && !h.switchInFlight }, limit: 15 * 60)
        guard let first = h.claude.at("quit").first else { h.check(false, "setup: the automatic switch to Beta ran: \(h.seen)"); return }
        h.check(h.quits == 2 && h.state("Beta") == .needsSignIn, "the switch to Beta rolled back, and Beta reads Needs sign-in: \(h.seen)")
        // Claude holds Alpha settled again before it stops the chat: a stop before that never counts.
        await h.pass(2 * 60)
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(2 * 60)
        h.check(h.quits == 2 && h.noticeHas("Switching to Gamma at"), "the next stop waits out the spacing and says when it goes: \(h.seen)")
        await h.run(until: { h.claude.held == C && !h.switchInFlight }, limit: 20 * 60)
        let third = h.claude.at("quit").dropFirst(2).first
        h.check(third.map { $0.timeIntervalSince(first) >= Limits.autoSwitchSpacing } ?? false,
                "Claude is asked to quit again only 15 minutes after the first switch began: \(h.claude.at("quit").map { Int($0.timeIntervalSince(first)) })")
        h.check(h.claude.held == C, "and lands on Gamma: \(h.seen)")
    },

    Scenario(pair: "(Claude refused Beta's login while the app was quit, then named Alpha; the app launches)",
             model: "review F1's guard: a pair whose last word in Claude's log is a refusal is never the automatic target, and its row still shows Switch: nothing quits, switches or types by itself, and a stop moves on to Gamma") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, s) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await h.savedLogin(n, s) }
        for s in [A, B, C] { h.usage.set(s, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: A, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        // Before the app ran: Claude opened on Beta, refused its sign-in and fell back; then it was
        // quit and opened again on Alpha.
        h.claude.stale = [B]
        h.claude.writeSignIn(B)
        h.claude.start(); h.clock.advance(60)
        h.claude.stop()
        h.claude.writeSignIn(A)
        h.claudeHoldsSettled()
        h.make(); await h.tick(); await h.settle()
        h.check(h.action("Beta") == .switchTo && h.nextRow == "Gamma", "Beta still shows Switch, and Next is Gamma: \(String(describing: h.state("Beta"))), next \(String(describing: h.nextRow))")
        await h.pass(2 * 60)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing quit, typed or posted by itself: \(h.seen)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == C && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == C && h.quits == 1 && h.launches == 1, "the stop moves Claude straight to Gamma, never to Beta: \(h.seen)")
    },

    Scenario(pair: "(The app relaunches; Claude, still on Alpha, wrote newer cookies; a hand Switch to Beta 20 s later)",
             model: "review F6a: a hold Claude's own log shows held a minute or more saves the seat it leaves, even before the app's clock saw it settle") { h in
        await h.standard()
        await h.pass(3 * 60)
        h.killApp()
        h.claude.writeSignIn(A)
        h.clock.advance(5 * 60)
        await h.handSwitchEarlyInTheAppsRun()
        h.check(h.savedMark(A) != nil && h.savedMark(A) == h.claude.quitMarks[A],
                "Alpha's saved login is Claude's write at quit: saved \(String(describing: h.savedMark(A))), quit \(String(describing: h.claude.quitMarks[A]))")
    },

    Scenario(pair: "(Alpha was signed in inside Claude while the app was quit, with no saved login; the app relaunches and a hand Switch to Beta comes 20 s later)",
             model: "review F6c: the seat the hand Switch leaves keeps its login") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, s) in [("Beta", B), ("Gamma", C)] { try? await h.savedLogin(n, s) }
        for s in [A, B, C] { h.usage.set(s, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.writeSignIn(A)
        h.claudeHoldsSettled(); h.clock.advance(10 * 60)
        await h.handSwitchEarlyInTheAppsRun()
        await h.pass(30)
        h.check(h.hasSavedLogin(A) && h.action("Alpha") != .setUp, "Alpha's login is kept: saved \(h.hasSavedLogin(A)), shows \(String(describing: h.state("Alpha")))")
    },

    Scenario(pair: "(Claude's log rotates twice since it named Alpha, then the app relaunches)",
             model: "review F9: the first read goes back through the rotations to the line that names the seat, so Alpha reads In use and the hold settles") { h in
        await h.standard()
        await h.pass(2 * 60)
        for _ in 0..<2 { h.claude.log("[heartbeat] still running"); rotate(h.claude); h.clock.advance(3600) }
        h.claude.log("[heartbeat] still running")
        h.killApp(); h.clock.advance(60); h.make(); await h.tick(); await h.settle()
        await h.pass(2 * 60)
        h.check(h.state("Alpha") == .inUse && h.store.facts().hold?.seat == A.identity, "Alpha reads In use after the relaunch: \(String(describing: h.state("Alpha")))")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.quits == 1, "a stop seen now switches as usual: \(h.seen)")
    },

    Scenario(pair: "(Automatic switch, Claude's quit prompt is never listed; the person presses Quit anyway at 4 minutes)",
             model: "review F8 and the EM's ruling: after 10 s of not being able to press the prompt, one notification says what to do; the failure at 3 min posts the second and last; once Claude quits, the line that says the prompt is open goes") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.promptListedAfter = .infinity
        guard let asked = await h.autoQuitAsked() else { return }
        await h.pass(9 - h.now.timeIntervalSince(asked))
        h.check(h.claude.notifications.isEmpty, "nothing posted in the first 9 s: \(h.claude.notifications)")
        await h.pass(12 - h.now.timeIntervalSince(asked))
        let ask = "Switching to Beta: \(QuitWatch.answerPrompt)"
        h.check(h.claude.notifications == [ask], "by 12 s one notification says what to do: \(h.claude.notifications)")
        await h.run(until: { !h.switchInFlight }, limit: 5 * 60)
        h.check(h.claude.notifications.count == 2 && h.claude.notifications.last?.hasPrefix("Didn't switch to Beta: ") == true,
                "the failure posts the second: \(h.claude.notifications)")
        h.check(h.noticeHas("Its prompt is still open"), "while the prompt is up, the line says so: \(h.seen)")
        await h.pass(240 - h.now.timeIntervalSince(asked))
        h.claude.personAnswers(ClaudeUI.quitAnyway)
        await h.pass(30)
        h.check(!h.noticeHas("Its prompt is still open") && !h.noticeHas("Didn't switch"), "once Claude quits, the line goes: \(h.seen)")
        await h.pass(20 * 60)
        h.check(h.quits == 1 && h.claude.notifications.count == 2, "one quit request and two notifications in all: \(h.seen)")
    },
]
