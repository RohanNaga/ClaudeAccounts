import Foundation

// The sixth review's gaps, kept (reviewer-ca-27-6, probes G2a and G2b, findings 4, 5 and 7): a
// hand Switch that fails or is cancelled while an automatic switch waits out the spacing keeps its
// line and stops that switch, a log rotation during the first read counts no old line as new, a
// seat whose last word is a refusal still switches by hand, and a resume left on disk never types.
// Each fails on 56fe95f.

@MainActor extension Harness {
    /// Alpha stops at 100: the automatic switch lands on Beta. Two minutes later Beta stops at 100:
    /// the next switch, to Gamma, waits out the spacing ("Switching to Gamma at ...").
    func brakeOnBeta() async -> Bool {
        await standard()
        claude.logLimitStop("local_one", seatReadsFull: true)
        await run(until: { claude.held == B && !switchInFlight }, limit: 10 * 60)
        await pass(2 * 60)
        claude.screens["local_one"]?.busy = false
        claude.logLimitStop("local_one", seatReadsFull: true)
        await run(until: { noticeHas("Switching to Gamma at") }, limit: 6 * 60)
        return noticeHas("Switching to Gamma at")
    }

    /// Claude ran on Alpha, then Beta's saved login was refused while the app was quit, and Claude
    /// fell back and opened on Alpha again.
    func betaRefusedBeforeLaunch() async {
        try? rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, s) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await savedLogin(n, s) }
        for s in [A, B, C] { usage.set(s, fiveHour: 20, resetsAt: now.addingTimeInterval(3 * 3600)) }
        claude.stale = [B]
        claude.writeSignIn(B)
        claude.start(); clock.advance(60)
        claude.stop()
        claude.writeSignIn(A)
        claudeHoldsSettled()
        make(); await tick(); await settle()
    }
}

let reviewSixScenarios: [Scenario] = [
    Scenario(pair: "(Switching to Gamma waits out the spacing, then a hand Switch to Alpha that Claude never quits for)",
             model: "review six G2a: the hand Switch's failure line stays; Claude stayed on its hold, so nothing asks it to quit again by itself") { h in
        guard await h.brakeOnBeta() else { h.check(false, "setup: no brake: \(h.seen)"); return }
        h.claude.quitBehaviour = .ignores
        let quits = h.quits
        h.click("Alpha")
        await h.run(until: { !h.switchInFlight }, limit: 5 * 60)
        let failed = h.notice
        h.check(failed.first == "Claude didn't quit, so nothing changed.", "the hand Switch says why it failed: \(h.seen)")
        await h.pass(10)
        h.check(h.notice == failed, "the failure line stays: was \(failed), now \(h.notice)")
        await h.pass(20 * 60)
        h.check(h.quits == quits + 1 && h.claude.held == B, "nothing asks Claude to quit again by itself: \(h.seen)")
    },

    Scenario(pair: "(Switching to Gamma waits out the spacing, then a hand Switch to Alpha whose prompt the person cancels)",
             model: "review six G2b: Cancel means stay; the switch waiting out the spacing does not run") { h in
        guard await h.brakeOnBeta() else { h.check(false, "setup: no brake: \(h.seen)"); return }
        h.claude.quitBehaviour = .promptCancelled
        let quits = h.quits
        h.click("Alpha")
        await h.run(until: { !h.switchInFlight }, limit: 5 * 60)
        h.check(h.noticeHas("Switch cancelled."), "the line says the switch was cancelled: \(h.seen)")
        await h.pass(20 * 60)
        h.check(h.quits == quits + 1 && h.claude.held == B, "after the person cancels, nothing asks Claude to quit again by itself: \(h.seen)")
        h.check(!h.claude.actions.contains("pressed \(ClaudeUI.quitAnyway)"), "and nothing presses Quit anyway: \(h.claude.actions)")
    },

    Scenario(pair: "(Claude stopped a chat at Alpha's limit before the app ran; its log rotates during the app's first read)",
             model: "review six finding 4: where the first read ends is taken from the file it read, so a rotation mid-read makes no old line count as arriving") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, s) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await h.savedLogin(n, s) }
        for s in [A, B, C] { h.usage.set(s, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: A, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claudeHoldsSettled()
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        h.make()
        // Claude rotates main.log the second time the app looks for its log folder: inside the first
        // read when that read looks twice, else at the next one.
        let claude = h.claude
        var looks = 0
        claude.onLogDir = { looks += 1; if looks == 2 { claude.onLogDir = nil; rotate(claude) } }
        await h.tick(); await h.settle()
        await h.pass(10 * 60)
        h.check(claude.onLogDir == nil, "setup: the log rotated")
        h.check(h.quits == 0 && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "a stop from before the app ran never switches: \(h.seen)")
    },

    Scenario(pair: "(Claude refused Beta's login while the app was quit; the person switches to Beta by hand)",
             model: "review six finding 5: the refusal guard only keeps the automatic switch off Beta; its row shows Switch, and a hand Switch to it runs at once and may roll back") { h in
        await h.betaRefusedBeforeLaunch()
        h.check(h.action("Beta") == .switchTo && h.nextRow == "Gamma", "Beta shows Switch, and Next is Gamma: \(String(describing: h.state("Beta"))), next \(String(describing: h.nextRow))")
        let clicked = h.now
        h.click("Beta")
        await h.run(until: { h.quits > 0 }, limit: 60)
        h.check(h.claude.at("quit").first.map { $0.timeIntervalSince(clicked) <= Double(Store.tickEvery) } ?? false,
                "Claude is asked to quit at once: \(h.claude.at("quit").map { Int($0.timeIntervalSince(clicked)) })")
        await h.run(until: { h.noticeHas("Back on Alpha") && h.claude.held == A && !h.switchInFlight }, limit: 5 * 60)
        h.check(h.claude.held == A && h.noticeHas("Back on Alpha"), "Claude refuses Beta again, and the switch rolls back: \(h.seen)")
    },

    Scenario(pair: "(An earlier build was stopped mid-resume and left the chat on disk; the app launches)",
             model: "review six finding 7: nothing stored types; the leftover is dropped unread") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, s) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await h.savedLogin(n, s) }
        for s in [A, B, C] { h.usage.set(s, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: A, lastActivity: h.now.addingTimeInterval(-600))
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claudeHoldsSettled()
        let dir = Paths.stateDir.appendingPathComponent("resuming")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let left: [String: Any] = ["folder": ClaudeApp.folder(A.identity).path, "chats": ["local_one"], "id": "left",
                                   "reopenedAt": h.now.addingTimeInterval(-300).timeIntervalSinceReferenceDate]
        try? JSONSerialization.data(withJSONObject: left).write(to: dir.appendingPathComponent("left.json"))
        h.make(); await h.tick(); await h.settle()
        await h.pass(ClaudeTiming.resumeFor + 5 * 60)
        h.check(h.claude.sent.isEmpty && h.claude.actions.isEmpty, "nothing is opened or typed: \(h.seen)")
        h.check(!FileManager.default.fileExists(atPath: dir.path), "the leftover is gone")
    },
]
