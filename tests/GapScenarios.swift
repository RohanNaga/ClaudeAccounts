import Foundation

// Scenarios for model rules that no pair in Scenarios.swift covered, and for decisions that were
// checked only on their happy path. Each is written from the model's words, and each check fails
// if the app does the wrong thing.

@MainActor extension Harness {
    var now: Date { clock.now() }
}

/// Seconds from `a` to `b`, for the lines a check prints.
private func secs(_ a: Date?, _ b: Date?) -> String {
    guard let a, let b else { return "never" }
    return String(format: "%.0f s", b.timeIntervalSince(a))
}

/// The model's section 5 values, as the spec states them: timing checks measure against these, not
/// the app's own constants, so a changed constant fails the timing check as well as its value check.
private enum Spec {
    static let meterOnTurnEnd: TimeInterval = 60
    static let coolDown: TimeInterval = 10 * 60
    static let autoQuitWait: TimeInterval = 3 * 60
    /// A relaunched hold settles for 60 s before the decision may act on it.
    static let settle: TimeInterval = 60
    static let confirmWait: TimeInterval = 3 * 60
    static let setUpConfirmWait: TimeInterval = 10 * 60
    /// How late past a deadline the app may act: its confirm loop looks once a second, its tick every few.
    static let slack: TimeInterval = 10
}

/// Seconds from `from` to `to`, nil if either is missing.
private func gap(_ from: Date?, _ to: Date?) -> TimeInterval? {
    guard let from, let to else { return nil }
    return to.timeIntervalSince(from)
}

/// A pair no row names: the account Claude opens on when it ignores the loaded sign-in.
private let X = StandSeat(9, org: 9)

let gapScenarios: [Scenario] = [
    // 1. Section 7, row 1.
    Scenario(pair: "(Out, click Switch on T)", model: "7: T is Ready or Out: the switch; a manual switch never checks room; Switching… then T In use") { h in
        await h.standard()
        h.usage.set(B, fiveHour: 100, resetsAt: h.now.addingTimeInterval(2 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.check(h.state("Beta") == .out, "setup: Beta reads Out: \(String(describing: h.state("Beta")))")
        h.check(h.action("Beta") == .switchTo, "an Out row offers Switch: \(String(describing: h.action("Beta")))")
        h.click("Beta")
        await h.settle()
        h.check(h.state("Beta") == .switching, "Beta shows Switching… while the switch runs: \(String(describing: h.state("Beta"))), \(h.notice)")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B, "the switch went ahead to the Out seat: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.state("Beta") == .inUse, "Beta In use: \(String(describing: h.state("Beta")))")
        h.check(h.claude.chats(in: B).contains("local_one") && !h.claude.chats(in: A).contains("local_one"), "the chat moved to Beta's folder")
    },

    // 2. Section 7: between quit and launch, the second reopen rolls back.
    Scenario(pair: "(Between quit and launch, the person opens Claude a second time)", model: "7: quit it once more; a second time: roll back") { h in
        await h.standard()
        let savedA = h.savedAt(A), savedB = h.savedAt(B)
        h.claude.reopensAfterQuit = 2
        h.click("Beta")
        await h.run(until: { h.claude.at("person opened").count == 2 && !h.switchInFlight && h.claude.held != nil }, limit: 900)
        h.check(h.claude.at("person opened").count == 2, "setup: the person opened Claude twice mid-switch: \(h.claude.actions)")
        h.check(h.claude.at("quit").count == 3, "quit at the start, once more after the first reopen, and once for the undo: \(h.claude.actions)")
        h.check(h.claude.held == A && h.claude.signInOnDisk() == A, "rolled back: Claude is on Alpha again: holds \(String(describing: h.claude.held)), files \(String(describing: h.claude.signInOnDisk()))")
        h.check(h.claude.chats(in: A).contains("local_one") && !h.claude.chats(in: B).contains("local_one"), "the chat is back in Alpha's folder")
        // Alpha's login is saved again after the quit (6.1, 13a.2); Beta's is never written.
        h.check((h.savedAt(A) ?? .distantPast) >= (savedA ?? .distantFuture), "Alpha's saved login intact: saved \(stamp(savedA)), now \(stamp(h.savedAt(A)))")
        h.check(h.savedAt(B) == savedB, "Beta's saved login untouched: saved \(stamp(savedB)), now \(stamp(h.savedAt(B)))")
        h.check(!h.noticeHas("Switched to Beta") && !h.noticeHas("Finished switching"), "nothing says the switch to Beta happened: \(h.notice)")
    },
    Scenario(pair: "(Automatic switch, the person opens Claude a second time between quit and launch)", model: "7: a second reopen rolls back; 6: the switch did not happen, so it is never posted as done") { h in
        await h.standard()
        h.claude.reopensAfterQuit = 2
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.at("person opened").count == 2 && !h.switchInFlight && h.claude.held != nil }, limit: 900)
        h.check(h.claude.at("person opened").count == 2, "setup: the person opened Claude twice mid-switch: \(h.claude.actions)")
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "rolled back to Alpha with the chat: holds \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(h.claude.chats(in: B).isEmpty || h.claude.held == B, "no chat is left in a folder Claude isn't holding: holds \(String(describing: h.claude.held)), Beta's folder \(h.claude.chats(in: B))")
        h.check(!h.claude.notifications.contains { $0.hasPrefix("Switched to Beta") }, "no \"Switched to Beta\" posted for a switch that was undone: \(h.claude.notifications)")
    },

    // 3. Decision 2 and section 4: a wrap-up counts only on a settled hold; one meter read per minute per seat.
    Scenario(pair: "(In use settling, wrap-up before settle)", model: "4 and 13a decision 2: a turn ended inside the first 60 s is never blamed on the new seat; no switch") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        await h.pass(10)
        h.claude.logTurnEnded("local_one")
        let ended = h.now
        h.usage.set(B, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3600))
        await h.pass(ClaudeTiming.meterEvery + 30)
        h.check(h.usage.readsOf(B).contains { $0 >= ended.addingTimeInterval(1) }, "setup: Beta was read at 100 after the turn ended: reads \(h.usage.readsOf(B).map { secs(ended, $0) })")
        h.check(h.claude.held == B && h.claude.actions.filter { $0 == "quit" }.count == 1, "no automatic switch away from Beta: holds \(String(describing: h.claude.held)), \(h.claude.actions)")
    },
    Scenario(pair: "(In use settled, turns end often)", model: "4, 5 and 13a.1: each TurnEnded triggers a read, at most one per meterOnTurnEnd (60 s) per seat") { h in
        await h.standard()
        let first = h.now
        for _ in 0..<15 { h.claude.logTurnEnded("local_one"); await h.pass(10) }
        await h.pass(30)
        let reads = h.usage.readsOf(A).filter { $0 > first }
        let gaps = zip(reads, reads.dropFirst()).map { $1.timeIntervalSince($0) }
        h.check(reads.count >= 2, "turns ending read Alpha sooner than the 5 min refresh: reads at \(reads.map { secs(first, $0) })")
        h.check(gaps.allSatisfy { $0 >= Spec.meterOnTurnEnd }, "never more than one read of Alpha per minute: gaps \(gaps)")
        h.check(Limits.meterOnTurnEnd == Spec.meterOnTurnEnd, "meterOnTurnEnd is 60 s: \(Limits.meterOnTurnEnd)")
    },

    // 4. Sections 4 and 7: waiting, and the seat in use is the one that resets.
    Scenario(pair: "(Waiting, the seat in use resets)", model: "4 and 7: reset time passes while waiting: read the meter, then resume in place") { h in
        await h.standard()
        let start = h.now
        // Off the 5 min grid, so only the read scheduled at reset + 1 min can see it.
        let resetA = start.addingTimeInterval(5000 + 37)
        h.usage.set(A, fiveHour: 100, resetsAt: resetA)
        for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: start.addingTimeInterval(4 * 3600)) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one")
        await h.pass(60)
        h.check(h.noticeHas("Every seat is out"), "setup: waiting first: \(h.notice)")
        let usage = h.usage
        h.clock.after(resetA.timeIntervalSince(h.now) - 5) { usage.set(A, fiveHour: 0, resetsAt: resetA.addingTimeInterval(5 * 3600)) }
        await h.run(until: { h.resumed("local_one") }, limit: 3 * 3600)
        let at = h.now
        h.check(h.resumed("local_one"), "the waiting chat is resumed: \(h.claude.sent), \(h.notice)")
        h.check(h.claude.at("quit").isEmpty && h.claude.held == A, "in place: no switch, Claude still on Alpha: \(h.claude.actions)")
        h.check(at >= resetA, "not before Alpha resets: resumed \(secs(resetA, at)) after the reset")
        h.check(h.usage.readsOf(A).contains { $0 >= resetA && $0 <= at }, "Alpha's meter was read after its reset and before the resume: reads \(h.usage.readsOf(A).map { secs(resetA, $0) }), resumed \(secs(resetA, at))")
        h.check(h.claude.sent.filter { $0.hasPrefix("local_one") }.count == 1, "exactly one resume: \(h.claude.sent)")
    },

    // 5. Sections 5 and 6.6: a failed automatic switch.
    Scenario(pair: "(Automatic switch fails at confirm)", model: "6.6: the target gets failedTarget, the decision runs again at once with the next target; 5: coolDown 10 min; 6.7: the stopped chat is still resumed") { h in
        await h.standard()
        h.claude.opensAsOnce = X
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.at("launch").count >= 2 && !h.switchInFlight }, limit: 900)
        guard let failed = h.claude.at("launch").dropFirst().first else { h.check(false, "setup: the switch was undone and Claude relaunched: \(h.claude.actions), \(h.notice)"); return }
        h.check(h.claude.signInOnDisk() == A, "setup: Claude opened on another pair and the switch rolled back to Alpha: \(h.claude.actions), \(h.notice)")
        h.check(h.state("Beta") == .ready, "setup: Beta stays Ready (only its switch failed): \(String(describing: h.state("Beta")))")
        await h.run(until: { h.claude.held == C && h.state("Gamma") == .inUse && !h.switchInFlight }, limit: 900)
        let next = h.claude.at("quit").dropFirst(2).first
        h.check(h.claude.held == C, "the next target, Gamma, is tried, not Beta again: holds \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(next.map { $0.timeIntervalSince(failed) <= Spec.settle + 15 } ?? false,
                "the decision ran again at once (once the relaunched hold settled): next quit \(secs(failed, next)) after the undo")
        h.check(h.resumed("local_one"), "the chat the limit stopped is resumed on Gamma: sent \(h.claude.sent), Gamma's folder \(h.claude.chats(in: C))")
        // Gamma runs out inside the cool-down: Alpha is out and Beta failed, so nothing to switch to.
        await h.pass(ClaudeTiming.settle + 5)
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one")
        let quits = h.claude.at("quit").count
        let coolEnds = failed.addingTimeInterval(Spec.coolDown)
        await h.run(until: { h.claude.at("quit").count > quits }, limit: coolEnds.timeIntervalSince(h.now) + 120)
        let retried = h.claude.at("quit").dropFirst(quits).first
        h.check(retried.map { $0 >= coolEnds.addingTimeInterval(-1) } ?? false, "Beta is skipped for the 10 min cool-down: next quit \(secs(failed, retried)) after the failure")
        h.check(retried.map { $0 <= coolEnds.addingTimeInterval(30) } ?? false, "and tried again once it ends: next quit \(secs(failed, retried)) after the failure")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B, "the switch after the cool-down goes to Beta: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(Limits.coolDown == Spec.coolDown, "coolDown is 10 min: \(Limits.coolDown)")
        h.check(Limits.settle == Spec.settle, "a relaunched hold settles for 60 s: \(Limits.settle)")
    },

    // 6. Section 5: quitWait 3 min on an automatic switch.
    Scenario(pair: "(Automatic switch, quit prompt never answered)", model: "5: quitWait 3 min for an automatic switch: cancel the prompt and stop; nothing changed") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.quitAnywayLands = false
        h.claude.logLimitStop("local_one")
        await h.run(until: { !h.claude.at("quit").isEmpty }, limit: 300)
        let asked = h.claude.at("quit").first
        await h.run(until: { !h.claude.at("pressed \(ClaudeUI.cancel)").isEmpty }, limit: 600)
        let cancelled = h.claude.at("pressed \(ClaudeUI.cancel)").first
        guard let asked else { h.check(false, "setup: the automatic switch asked Claude to quit: \(h.claude.actions)"); return }
        h.check(!h.claude.at("pressed \(ClaudeUI.quitAnyway)").isEmpty, "setup: the app pressed Quit anyway and the prompt stayed: \(h.claude.actions.prefix(4))")
        h.check(cancelled != nil, "the app pressed Cancel on the prompt: \(h.claude.actions.suffix(3))")
        h.check(cancelled.map { $0.timeIntervalSince(asked) >= Spec.autoQuitWait - 1 } ?? false, "not before the 3 min quit wait: Cancel \(secs(asked, cancelled)) after the quit request")
        h.check(cancelled.map { $0.timeIntervalSince(asked) <= Spec.autoQuitWait + 10 } ?? false, "at the 3 min quit wait: Cancel \(secs(asked, cancelled)) after the quit request")
        h.check(Limits.autoQuitWait == Spec.autoQuitWait, "quitWait for an automatic switch is 3 min: \(Limits.autoQuitWait)")
        let quits = h.claude.at("quit").count
        await h.pass(10 * 60)
        h.check(h.claude.at("quit").count == quits && h.claude.at("launch").isEmpty, "and stops: no further quit request, no launch: \(h.claude.actions.suffix(6))")
        h.check(h.claude.held == A && h.claude.signInOnDisk() == A && h.claude.chats(in: A).contains("local_one"), "nothing changed: Claude on Alpha with its chat")
        // Stopped until a new signal: the next limit stop starts a switch again.
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.at("quit").count > quits }, limit: 300)
        h.check(h.claude.at("quit").count > quits, "a new limit stop asks Claude to quit again: \(h.claude.actions.suffix(4))")
    },

    // 7. Sections 3 and 7: a stale meter is not an automatic target.
    Scenario(pair: "(Any, meter read N min ago)", model: "3 and 7: a stale meter (\"read N min ago\") removes the seat as an automatic target; manual switch allowed") { h in
        await h.standard()
        h.usage.fail(B)
        await h.pass(Limits.freshness + 60)
        h.check(h.meterText("Beta")?.hasPrefix("read ") == true && h.meterText("Beta")?.hasSuffix(" min ago") == true, "Beta's meter reads \"read N min ago\": \(String(describing: h.meterText("Beta")))")
        h.check(h.meterText("Gamma") == nil, "setup: Gamma's meter is fresh: \(String(describing: h.meterText("Gamma")))")
        h.check(h.action("Beta") == .switchTo, "manual Switch stays on the stale row")
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held != nil && h.claude.held != A }, limit: 600)
        h.check(h.claude.held == C, "the automatic switch skips stale Beta for Gamma: holds \(String(describing: h.claude.held))")
    },

    // 8. Section 3 and decision 3: the Auto-Switch toggle off.
    Scenario(pair: "(Auto-Switch off, settled limit stop)", model: "3: automatic switching off by the person: no automatic switch; manual Switch still works") { h in
        await h.standard()
        h.store.setAutoSwitch(false)
        await h.tick(); await h.settle()
        h.check(h.nextRow == nil, "no seat is marked Next while it is off: \(String(describing: h.nextRow))")
        h.claude.logLimitStop("local_one")
        await h.pass(600)
        h.check(h.claude.actions.isEmpty, "no automatic switch: \(h.claude.actions)")
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "Claude still on Alpha with its chat")
        h.check(h.action("Beta") == .switchTo, "manual Switch is offered")
        h.click("Beta")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "manual Switch works: holds \(String(describing: h.claude.held)), \(h.notice)")
    },

    // 9. Section 7: Claude signs out while it runs.
    Scenario(pair: "(In use, Claude signs out)", model: "7: signed out: holds nothing; saved logins stay; Switch on rows with a saved login") { h in
        await h.standard()
        let savedA = h.savedAt(A)
        h.claude.writeSignIn(nil)
        h.claude.log(ClaudeLog.signOut[0])
        await h.pass(2 * ClaudeTiming.meterEvery)
        h.check(h.state("Alpha") != .inUse && !h.rowNames.contains { h.state($0) == .inUse }, "Claude holds nothing: no row In use: \(h.rowNames.map { "\($0) \(String(describing: h.state($0)))" })")
        h.check(h.savedAt(A) == savedA, "Alpha's saved login is not overwritten by the signed-out files: saved \(stamp(savedA)), now \(stamp(h.savedAt(A)))")
        h.check([("Alpha"), ("Beta"), ("Gamma")].allSatisfy { h.action($0) == .switchTo }, "Switch on every row with a saved login: \(h.rowNames.map { "\($0) \(String(describing: h.action($0)))" })")
        h.check(h.claude.actions.isEmpty, "nothing automatic happened: \(h.claude.actions)")
        h.click("Beta")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B, "Switch signs Claude in on Beta: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.savedAt(A) == savedA, "Alpha's saved login still untouched")
    },

    // 10. Section 6.7: chats cut off by the quit.
    Scenario(pair: "(Switch, a chat cut off by the quit)", model: "6.7 and F3 CutByQuit: a moved chat the quit cut off, and idle, gets one \"resume\"; one that was idle is left alone") { h in
        await h.standard()
        h.claude.addChat("local_two", in: A, lastActivity: h.now)
        h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claude.cutOnQuit = ["local_one"]
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B && h.claude.chats(in: B).isSuperset(of: ["local_one", "local_two"]), "setup: the switch to Beta moved both chats: \(h.claude.chats(in: B)), \(h.notice)")
        h.check(h.claude.sent.filter { $0 == "local_one resume" }.count == 1, "the chat the quit cut off got one \"resume\": \(h.claude.sent)")
        h.check(!h.resumed("local_two"), "the idle chat got nothing: \(h.claude.sent)")
    },

    // 11. Section 7 row 2 and section 5 confirmWait: Set Up where nobody signs in.
    Scenario(pair: "(Set Up on T, nobody signs in)", model: "7: a 10 min timeout rolls back; 5 confirmWait: 10 min for Set Up") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.now)
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.action("Beta") == .setUp, "setup: Beta has Set Up: \(String(describing: h.action("Beta")))")
        let lines = Lines()
        h.click("Beta")
        await h.run(until: { lines.note(h); return h.launches >= 1 && lines.has("Sign in to Beta in Claude.") }, limit: 300)
        h.check(lines.has("Sign in to Beta in Claude."), "the notice asks for the sign-in: \(lines.seen)")
        await h.run(until: { lines.note(h); return h.quits >= 2 }, limit: Spec.setUpConfirmWait * 2)
        let waited = gap(h.claude.at("launch").first, h.claude.at("quit").dropFirst().first)
        h.check(waited.map { $0 >= Spec.setUpConfirmWait && $0 <= Spec.setUpConfirmWait + Spec.slack } == true,
                "Set Up waits 10 min for the sign-in, then rolls back: rollback quit \(waited.map { "\(Int($0)) s" } ?? "never") after the launch")
        await runToEnd(h, lines, limit: 900)
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "back on Alpha with its chat: \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(lines.has("Back on Alpha."), "the row says it is back on Alpha: \(lines.seen)")
        h.check(h.state("Beta") == .needsSignIn && h.hasSavedLogin(A), "Beta still Needs sign-in, Alpha's saved login intact: \(String(describing: h.state("Beta")))")
        h.check(Limits.setUpConfirmWait == Spec.setUpConfirmWait, "setUpConfirmWait is 10 min: \(Limits.setUpConfirmWait) s")
    },

    // 12. Section 5 confirmWait: a switch whose target Claude does not name within 3 min.
    Scenario(pair: "(Switch, Claude names the target too late)", model: "5 confirmWait: 3 min after launch; 6.6: confirmWait passes, roll back") { h in
        await h.standard()
        // Claude would name Beta 400 s after it opens: past the wait, so the switch must roll back first.
        h.claude.nameAfter = 400
        let lines = Lines()
        h.click("Beta")
        await h.run(until: { lines.note(h); return h.quits >= 2 }, limit: 1200)
        let waited = gap(h.claude.at("launch").first, h.claude.at("quit").dropFirst().first)
        h.check(waited.map { $0 >= Spec.confirmWait && $0 <= Spec.confirmWait + Spec.slack } == true,
                "the switch waits 3 min for Claude to name Beta, then rolls back: rollback quit \(waited.map { "\(Int($0)) s" } ?? "never") after the launch")
        await runToEnd(h, lines, limit: 1200)
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "back on Alpha with its chat: \(String(describing: h.claude.held)), \(h.claude.actions)")
        // No Named line within 3 min is also section 8's shape miss; spec 11 still gives the notice
        // to the rollback's reason, a failure the person must act on.
        h.check(lines.has("Beta didn't open in time. Back on Alpha."), "the row says why it went back: \(lines.seen)")
        h.check(Limits.confirmWait == Spec.confirmWait, "confirmWait is 3 min: \(Limits.confirmWait) s")
    },

    // 13. Section 4: out is only ever read. A settled stop on a seat that reads with room leaves the
    // seat as it reads: no guessed reset, no switch, nothing typed into the refused chat. Once the
    // seat reads out, the same stop switches.
    Scenario(pair: "(In use settled, limit stop while the seat reads with room)", model: "4: out only on a current reading at or over 100 with its own reset; a stop alone marks nothing") { h in
        await h.standard()
        h.usage.set(A, fiveHour: 50, resetsAt: h.now.addingTimeInterval(4 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(30 * 60)
        h.check(h.state("Alpha") == .inUse && h.claude.actions.isEmpty, "Alpha stays In use, no switch: \(String(describing: h.state("Alpha"))), \(h.claude.actions)")
        h.check(h.claude.sent.isEmpty, "nothing typed into the refused chat: \(h.claude.sent)")
        h.check(!h.noticeHas("out"), "no line calls a seat out: \(h.notice)")
        // The seat then reads full: now it is out of a named limit with that limit's reset.
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.run(until: { h.claude.held == B }, limit: 2 * ClaudeTiming.meterEvery)
        h.check(h.claude.held == B, "once Alpha reads out after the stop, the automatic switch moves to Beta: \(String(describing: h.claude.held)), \(h.notice)")
        await h.run(until: { h.resumed("local_one") }, limit: 300)
        h.check(h.resumed("local_one"), "the stopped chat gets one resume on Beta: \(h.claude.sent)")
    },

    // 14. Section 7, sleep then wake: an expired confirm first checks the log.
    Scenario(pair: "(Confirm, the Mac sleeps past the wait)", model: "7: waits are measured against the facts; an expired confirm first checks the log") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.launches == 1 }, limit: 300)
        // Claude names Beta 3 s after it opens; the Mac sleeps 10 s in, for 20 min, past the 3 min wait.
        await h.pass(10)
        h.check(h.claude.held == B && h.switchInFlight, "setup: Claude named Beta and the confirm is waiting: \(String(describing: h.claude.held))")
        h.clock.sleepMac(20 * 60)
        h.wake()
        await h.tick(); await h.settle()
        await h.run(until: { !h.switchInFlight }, limit: 300)
        h.check(h.quits == 1 && h.launches == 1, "the log shows Beta held settled, so no rollback: \(h.claude.actions)")
        h.check(h.claude.held == B && h.state("Beta") == .inUse && h.claude.chats(in: B).contains("local_one"),
                "the switch confirms on Beta with the chat: \(String(describing: h.claude.held)), \(h.notice)")
    },

    // 15. Sections 7 and 12: Accessibility missing, then a manual switch with a stopped chat.
    Scenario(pair: "(Accessibility not granted, click Switch with a stopped chat)", model: "7: everything works except the quit prompt and typing \"resume\"; 12: the app names the chats that need a message") { h in
        h.claude.trustedAX = false
        await h.standard()
        h.claude.logLimitStop("local_one")
        await h.pass(60)
        h.check(h.claude.actions.isEmpty, "setup: no automatic switch without Accessibility: \(h.claude.actions)")
        let lines = Lines()
        h.click("Beta")
        await h.run(until: { lines.note(h); return h.claude.held == B && !h.switchInFlight && lines.has("Couldn't resume") }, limit: Spec.settle + 35 * 60)
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "the manual switch works: \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(h.claude.sent.isEmpty && h.claude.untrustedSends.isEmpty, "nothing typed, nor tried, without Accessibility: typed \(h.claude.sent), tried \(h.claude.untrustedSends)")
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "the chat is named: \(lines.seen)")
    },

    // 16. Section 5 quitWait: a manual switch has no time limit at Claude's prompt.
    Scenario(pair: "(Manual quit wait, the prompt stays open past 3 min)", model: "5 quitWait: none for a manual switch; 7: the person quits Claude, go on") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        let lines = Lines()
        h.click("Beta")
        await h.run(until: { lines.note(h); return h.claude.promptOpen }, limit: 120)
        await h.run(until: { lines.note(h); return !h.switchInFlight }, limit: 3 * Spec.autoQuitWait)
        h.check(h.switchInFlight && h.claude.promptOpen && h.claude.held == A, "9 min on, the manual switch still waits at the prompt: in flight \(h.switchInFlight), prompt \(h.claude.promptOpen), \(h.claude.actions)")
        h.check(h.quits == 1 && !h.claude.actions.contains { $0.hasPrefix("pressed") }, "it neither asked again nor pressed the prompt: \(h.claude.actions)")
        h.check(!lines.has("Switch cancelled"), "it did not give up: \(lines.seen)")
        h.claude.stop()
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "the person's quit carries the switch on to Beta: \(String(describing: h.claude.held)), \(h.notice)")
    },

    // 17. Section 10: colours and the menu-bar display and metric settings work.
    Scenario(pair: "(Menu, colour and menu-bar settings changed)", model: "10: colours and the menu-bar display and metric settings work") { h in
        await h.standard()
        h.check(h.store.menuBarTitle == "Alpha 20%", "setup: the title shows the seat in use and its 5-hour meter: \(h.store.menuBarTitle)")
        h.store.settings.metric = .weekly
        h.check(h.store.menuBarTitle == "Alpha 10%", "the metric setting moves the title to the weekly meter: \(h.store.menuBarTitle)")
        h.store.settings.display = .gaugePercent
        h.check(h.store.menuBarTitle == "10%", "the display setting drops the name: \(h.store.menuBarTitle)")
        h.store.settings.display = .gauge
        h.check(h.store.menuBarTitle == "", "gauge only shows no text: \(h.store.menuBarTitle)")
        let colour = { resolvedColors(h.store.accounts.map { ($0.seat.account, $0.color) })[A.account] }
        if let alpha = h.store.seats.first(where: { $0.name == "Alpha" }) { h.store.recolor(alpha, "#123456") } else { h.check(false, "no row named Alpha") }
        h.check(colour() == "#123456", "Alpha takes its new colour: \(String(describing: colour()))")
        h.make(); await h.tick()
        h.check(colour() == "#123456" && h.store.settings.display == .gauge && h.store.settings.metric == .weekly,
                "both are kept when the app starts again: colour \(String(describing: colour())), \(h.store.settings.display), \(h.store.settings.metric)")
    },

    // 18. Sections 4 and 6.6: the chats an automatic switch carries survive its undo and wait.
    Scenario(pair: "(Automatic switch undone, then every seat out)", model: "6.6 and 4: an undone automatic switch keeps its chats; with no other target they wait, and resume in place once the seat in use resets") { h in
        await h.standard()
        let start = h.now
        // Alpha resets off the 5 min grid, well inside Beta's 10 min cool-down; Gamma stays out.
        let resetA = start.addingTimeInterval(437)
        h.usage.set(A, fiveHour: 100, resetsAt: resetA)
        h.usage.set(C, fiveHour: 100, resetsAt: start.addingTimeInterval(4 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.opensAsOnce = X
        h.claude.logLimitStop("local_one")
        let usage = h.usage
        h.clock.after(resetA.timeIntervalSince(h.now) - 5) { usage.set(A, fiveHour: 0, resetsAt: resetA.addingTimeInterval(5 * 3600)) }
        await h.run(until: { h.claude.at("launch").count >= 2 && !h.switchInFlight && h.claude.held != nil }, limit: 300)
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "setup: the switch to Beta was undone, back on Alpha with the chat: \(String(describing: h.claude.held)), \(h.claude.actions)")
        await h.run(until: { h.resumed("local_one") }, limit: Spec.coolDown)
        // Beta reads with room through its cool-down, so no line may claim every seat is out.
        h.check(!h.claude.notifications.contains { $0.hasPrefix("Every seat is out") } && !h.noticeHas("Every seat is out"),
                "the undone switch's chat waits, with no claim that every seat is out while Beta reads with room: \(h.claude.notifications), \(h.notice)")
        h.check(h.resumed("local_one") && h.claude.held == A, "it resumes in place once Alpha resets, before Beta's cool-down ends: typed \(h.claude.sent), holds \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(h.claude.at("launch").count == 2, "no second switch, only the switch's launch and the undo's: \(h.claude.actions)")
    },

    // From here, decisions that a deliberately wrong app could pass on their happy path alone.
    // 19. Decision and 6.7: a manual switch carries every waiting chat, not only those Claude's run shows stopped.
    Scenario(pair: "(Waiting after a wrap-up, click Switch on T)", model: "decision and 6.7: a manual switch takes the waiting chats with it; the wrapped-up chat gets one resume on T") { h in
        await h.standard()
        let reset = h.now.addingTimeInterval(2 * 3600)
        for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        // A wrap-up writes no limit line, so the chat waits only on the app's own list.
        h.claude.logTurnEnded("local_one")
        h.usage.set(A, fiveHour: 100, resetsAt: reset)
        await h.pass(120)
        h.check(h.noticeHas("Every seat is out") && h.claude.actions.isEmpty, "setup: the wrap-up waits, every seat out: \(h.notice), \(h.claude.actions)")
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 600)
        await h.pass(5 * 60)
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "the person's switch went to Beta with the chat: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.claude.sent == ["local_one resume"], "the waiting chat gets exactly one resume on Beta: typed \(h.claude.sent), \(h.notice)")
    },

    // 20. Sections 8 B and 12: a wait that ends in place while a shape is missing names its chats.
    Scenario(pair: "(Shape missing, the seat in use resets while its chat waits)", model: "8 B and 12: resume is off while a shape is missing; the wait ends in place by naming the chats, as after a switch; nothing typed") { h in
        await h.standard()
        // Alpha resets off the 5 min grid, after the automatic switch has given up on Claude's prompt.
        let resetA = h.now.addingTimeInterval(737)
        h.usage.set(A, fiveHour: 100, resetsAt: resetA)
        await h.pass(ClaudeTiming.meterEvery + 5)
        // The prompt has no Quit anyway button: the automatic switch can't quit Claude, and that shape is missing.
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.promptHasQuitButton = false
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.quits > 0 && !h.switchInFlight }, limit: 600)
        h.check(h.notice == ["Claude didn't quit, so nothing changed."] && h.claude.held == A && h.claude.chats(in: A).contains("local_one"),
                "setup: the switch gave up and the chat waits on Alpha: \(h.notice), \(h.claude.actions)")
        let usage = h.usage
        h.clock.after(resetA.timeIntervalSince(h.now) - 5) { usage.set(A, fiveHour: 0, resetsAt: resetA.addingTimeInterval(5 * 3600)) }
        let lines = Lines()
        await h.run(until: { lines.note(h); return lines.has("Couldn't resume") }, limit: 30 * 60)
        let named = h.now
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "once Alpha has room again the waiting chat is named: \(lines.seen)")
        h.check(named >= resetA, "not before Alpha resets: named \(secs(resetA, named)) after the reset")
        h.check(h.claude.sent.isEmpty && h.claude.untrustedSends.isEmpty && !h.claude.actions.contains { $0.hasPrefix("open ") },
                "nothing opened or typed while the shape is missing: typed \(h.claude.sent), \(h.claude.actions)")
        h.check(h.quits == 1 && h.launches == 0 && h.claude.held == A, "in place, on Alpha: \(h.claude.actions)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas(pausedLine), "the pause shows once that line is closed: \(h.notice)")
        await h.pass(10 * 60)
        h.check(!h.noticeHas("Couldn't resume") && h.claude.sent.isEmpty, "the chat is named once, and still nothing typed: \(h.notice), typed \(h.claude.sent)")
    },

    // 21. Decision and 8 B: an automatic undo still answers Claude's prompt with Quit anyway while a shape is missing.
    Scenario(pair: "(Automatic switch, no Named line, the undo meets Claude's quit prompt)", model: "decision: the rollback's unattended quit presses Quit anyway while a shape miss stands; 6.6 and 8 A: back on Alpha with the chat; 11: the rollback's line, then the pause") { h in
        await h.standard()
        // Beta's launch logs no Named line the app knows, and every quit shows Claude's prompt with its
        // Quit anyway button, which lands.
        h.claude.namedLineChanged = true
        h.claude.quitBehaviour = .promptUnanswered
        let lines = Lines()
        await startAuto(h)
        await runToEnd(h, lines, limit: 1800)
        let presses = h.claude.at("pressed \(ClaudeUI.quitAnyway)"), launches = h.claude.at("launch")
        h.check(presses.count == 2 && launches.count == 2 && presses[1] > launches[0],
                "the switch's quit and the undo's quit each press Quit anyway, the undo's after Beta's launch: \(h.claude.actions)")
        checkEnds(h, [("Alpha", A)], chats: ["local_one"], lines: lines.seen)
        h.check(h.notice == ["Beta didn't open in time. Back on Alpha."], "the rollback's line holds the notice: \(h.notice)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas(pausedLine), "then the pause says why: \(h.notice)")
        checkActs(h)
    },

    // 22. Sections 7 and 12: a wait that ends in place gives up on a chat Claude never shows, and names it.
    Scenario(pair: "(Waiting, the seat in use resets, the chat's message box not on screen)", model: "4 and 7: the wait ends in place; 7: open the chat by its link and retry every 60 s for 30 min, then name it, as after a switch") { h in
        await h.standard(onScreen: false)
        let resetA = await waitUntilAlphaResets(h)
        let lines = Lines()
        await h.run(until: { lines.note(h); return lines.has("Couldn't resume") }, limit: resetA.timeIntervalSince(h.now) + ClaudeTiming.meterEvery + 35 * 60)
        let named = h.now
        let opened = h.claude.opened.first
        h.check(opened.map { $0 >= resetA } ?? false, "the chat was opened by its link once Alpha reset: opened \(secs(resetA, opened)) after the reset, \(h.claude.actions)")
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "the chat the resume gave up on is named: \(lines.seen)")
        let tried = gap(opened, named) ?? 0
        h.check(tried >= ClaudeTiming.resumeFor - ClaudeTiming.resumeEvery && tried <= ClaudeTiming.resumeFor + 2 * ClaudeTiming.resumeEvery,
                "it gives up 30 min after it first opened the chat, not sooner: after \(Int(tried / 60)) min")
        h.check(h.claude.sent.isEmpty && h.quits == 0 && h.claude.held == A, "in place, on Alpha, nothing typed: typed \(h.claude.sent), \(h.claude.actions)")
        h.check(Limits.resumeFor == ClaudeTiming.resumeFor, "resumeFor is 30 min: \(Limits.resumeFor) s")
        h.store.closeNotice()
        await h.pass(10 * 60)
        h.check(!h.noticeHas("Couldn't resume") && h.claude.sent.isEmpty, "the chat is named once: \(h.notice), typed \(h.claude.sent)")
    },

    // 23. Sections 7 and 12: a wait that ends in place once Accessibility is gone names its chats.
    Scenario(pair: "(Waiting, Accessibility removed, the seat in use resets)", model: "7: without Accessibility nothing is typed; 12: if typing \"resume\" can't work, the app names the chats that need a message") { h in
        await h.standard()
        let resetA = await waitUntilAlphaResets(h) { h.claude.trustedAX = false }
        let lines = Lines()
        await h.run(until: { lines.note(h); return lines.has("Couldn't resume") }, limit: resetA.timeIntervalSince(h.now) + 30 * 60)
        let named = h.now
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "once Alpha has room again the waiting chat is named: \(lines.seen)")
        h.check(named >= resetA, "not before Alpha resets: named \(secs(resetA, named)) after the reset")
        h.check(h.claude.sent.isEmpty && h.claude.untrustedSends.isEmpty && !h.claude.actions.contains { $0.hasPrefix("open ") },
                "nothing opened, typed or tried without Accessibility: typed \(h.claude.sent), tried \(h.claude.untrustedSends), \(h.claude.actions)")
        h.check(h.quits == 0 && h.claude.held == A, "in place, on Alpha: \(h.claude.actions)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas("Allow Accessibility"), "the Accessibility line shows once that line is closed: \(h.notice)")
        await h.pass(10 * 60)
        h.check(!h.noticeHas("Couldn't resume"), "the chat is named once: \(h.notice)")
    },
    // 24. Sections 6.7 and 7: a switch the person starts during an in-place resume stops that resume
    // and carries its chats. A wrap-up's chat waits only on the app's own list, so the switch can't
    // find it in Claude's run: only the carried set takes it to Beta.
    Scenario(pair: "(Resuming in place after a wrap-up, the chat not on screen, click Switch on T)", model: "7: a second switch request during a resume cancels the resume and carries its chats over; 6.7: they get one \"resume\" after the new seat's confirm") { h in
        await h.standard(onScreen: false)
        let start = h.now
        let resetA = start.addingTimeInterval(737)
        for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: start.addingTimeInterval(4 * 3600)) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logTurnEnded("local_one")
        h.usage.set(A, fiveHour: 100, resetsAt: resetA)
        await h.pass(120)
        h.check(h.noticeHas("Every seat is out") && h.claude.actions.isEmpty, "setup: the wrap-up waits, every seat out: \(h.notice), \(h.claude.actions)")
        let usage = h.usage
        h.clock.after(resetA.timeIntervalSince(h.now) - 5) { usage.set(A, fiveHour: 0, resetsAt: resetA.addingTimeInterval(5 * 3600)) }
        await h.run(until: { h.claude.actions.contains { $0.hasPrefix("open ") } }, limit: 30 * 60)
        h.check(h.claude.held == A && h.quits == 0, "setup: Alpha reset and the in-place resume opened the chat: \(h.claude.actions)")
        // The chat never shows its message box on Alpha; a few minutes into the retries the person
        // switches, and on Beta the chat shows it.
        await h.pass(2 * 60 + ClaudeTiming.resumeEvery / 2)
        h.click("Beta")
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        var sentAt: Date? = nil, namedB: Date? = nil
        await h.run(until: {
            if namedB == nil, h.claude.held == B { namedB = h.now }
            if sentAt == nil, !h.claude.sent.isEmpty { sentAt = h.now }
            return false
        }, limit: 10 * 60)
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "the switch went to Beta with the chat: \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(namedB.map { n in sentAt.map { $0 >= n.addingTimeInterval(Spec.settle - 5) } ?? false } ?? false,
                "nothing typed before Beta's confirm: typed \(secs(namedB, sentAt)) after Claude named Beta, \(h.claude.actions)")
        h.check(h.claude.sent == ["local_one resume"], "the chat gets exactly one resume: typed \(h.claude.sent)")
        await h.pass(35 * 60)
        h.check(!h.noticeHas("Couldn't resume") && h.claude.sent == ["local_one resume"], "the stopped in-place resume names nothing later: \(h.notice), typed \(h.claude.sent)")
    },
    // 25. The upgrade. The previous build kept each row's Claude login in slots/<row id>; on its first
    // start the new build files each one under its pair and leaves the slots, so a rollback to the
    // previous build still logs in, and that build reads back the rows and settings the new one saves.
    // A kept slot is a saved login too, so removing its seat deletes it with the one under saved/.
    Scenario(pair: "(Upgrade from the previous build's saved state)", model: "each seat with a saved login is Ready or In use with it filed under its pair; the old slots stay; the rows keep their order, names and labels; a manual Switch confirms with its chats; the previous build reads back what the new build saves; 7: a seat removed while not in use loses its saved login, its old slot and its row") { h in
        let work = StandSeat(1, org: 0), lab = StandSeat(1, org: 3), side = StandSeat(2, org: 0), studio = StandSeat(3, org: 5)
        let old = PreviousBuild(claude: h.claude)
        // Account 1 has two organizations; its first row and account 2's row were saved before rows
        // kept organizations. Account 3's row was added but never set up in Claude, so it has no slot.
        let rows = [
            old.row(1, "Work", "#3567CF", work, email: "one@example.com", orgName: "one@example.com's Organization", kept: false),
            old.row(2, "Work", "#3567CF", lab, email: "one@example.com", orgName: "Lab", orgLabel: "Research"),
            old.row(3, "Side", "#B96E22", side, email: "two@example.com", orgName: "two@example.com's Organization", kept: false),
            old.row(4, "Studio", "#B3405F", studio, email: "three@example.com", orgName: "Studio"),
        ]
        let settings = PreviousBuild.Settings(display: .gaugePercent, metric: .weekly, autoSwitch: false, collapsed: [side.account])
        do {
            try old.write(rows, settings)
            // Each saved at a switch away with Claude quit; Work's personal seat last, so its sign-in is
            // the one left in Claude's files.
            for (row, seat) in [(rows[1], lab), (rows[2], side), (rows[0], work)] { try old.saveSlot(row.id, as: seat) }
        } catch { h.check(false, "setup: writing the previous build's state threw \(error)"); return }
        let slots = old.slotFiles()
        let marks = [work: old.slotMark(rows[0].id), lab: old.slotMark(rows[1].id), side: old.slotMark(rows[2].id)]
        for seat in [work, lab, side, studio] { h.usage.set(seat, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: work, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claudeHoldsSettled(); h.make()
        for (seat, mark) in marks {
            let filed = h.claude.writeMark(in: h.claude.stateDir.appendingPathComponent("saved/\(seat.account)_\(seat.org)/current/cookies.db"))
            h.check(mark != nil && filed == mark, "\(seat)'s login is filed in saved/<account>_<org>/current: \(String(describing: filed)), the slot holds \(String(describing: mark))")
        }
        await h.tick(); await h.settle()
        let labels = ["Work · Individual", "Work · Research", "Side", "Studio"]
        h.check(h.rowNames == labels, "the rows keep their order and labels: \(h.rowNames)")
        h.check(h.store.accounts.map(\.name) == rows.map(\.name) && h.store.accounts.map(\.color) == rows.map(\.color), "and their names and colours: \(h.store.accounts.map(\.name)), \(h.store.accounts.map(\.color))")
        h.check(h.state("Work · Individual") == .inUse, "the seat Claude holds is In use: \(String(describing: h.state("Work · Individual")))")
        for name in ["Work · Research", "Side"] { h.check(h.state(name) == .ready, "\(name) is Ready from its adopted login: \(String(describing: h.state(name)))") }
        h.check(h.state("Studio") == .needsSignIn, "the row the previous build never set up still needs sign-in: \(String(describing: h.state("Studio")))")
        h.check(old.slotFiles() == slots, "the previous build's slots are still there, unchanged: \(old.slotFiles().keys.sorted())")

        h.click("Side")
        await h.run(until: { h.claude.held == side && h.state("Side") == .inUse && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == side && h.state("Side") == .inUse, "a manual Switch confirms on Side from its adopted login: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.claude.chats(in: side).contains("local_one") && !h.claude.chats(in: work).contains("local_one"), "the chat moved to Side's folder")
        h.check(h.rowNames == labels, "the rows are unchanged after the switch: \(h.rowNames)")

        // The person recolours an account and picks a switch order, so the new build saves both files.
        if let seat = h.store.seats.first(where: { $0.name == "Side" }) { h.store.recolor(seat, "#6B5BD2") }
        h.store.settings.switchOrder = .personalFirst
        await h.settle()
        var expected = rows
        expected[0].orgUuid = work.org; expected[0].orgName = "one@example.com's Organization"
        expected[2].orgUuid = side.org; expected[2].orgName = "two@example.com's Organization"; expected[2].color = "#6B5BD2"
        let back = old.read()
        h.check(back.rows == expected, "the previous build reads every row back from the new build's accounts.json, the old rows now naming their organizations: \(String(describing: back.rows))")
        h.check(back.settings == settings, "and every setting from its settings.json: \(String(describing: back.settings))")
        h.check(old.slotFiles() == slots, "the slots are unchanged after the switch and both saves: \(old.slotFiles().keys.sorted())")

        // The person removes Work · Research, an upgraded seat Claude does not hold.
        let others = { (files: [String: Data]) in files.filter { !$0.key.hasPrefix(rows[1].id + "/") } }
        let saved = [work, side].map { h.savedAt($0) }
        h.remove("Work · Research")
        await h.settle()
        h.check(!FileManager.default.fileExists(atPath: SavedLogins.dir(lab.identity).path), "the removed seat's saved/<account>_<org> folder is gone")
        h.check(!old.hasSlot(rows[1].id), "and its old slot, with Claude's cookie rows and token keys: \(old.slotFiles().keys.sorted())")
        h.check(h.rowNames == ["Work", "Side", "Studio"] && old.read().rows == expected.filter { $0.id != rows[1].id },
                "its row is gone from the menu and accounts.json, the others unchanged: \(h.rowNames), \(String(describing: old.read().rows?.map(\.id)))")
        h.check(others(old.slotFiles()) == others(slots) && [work, side].map { h.savedAt($0) } == saved,
                "the other rows' slots and saved logins are untouched")
    },
]

/// The state folder as the previous build (main at dd5f4f2) wrote it: accounts.json, settings.json,
/// and each row's saved Claude login in slots/<row id>. The types copy that build's keys, and each
/// file is written with that build's encoder, layout and permissions.
private struct PreviousBuild {
    /// Its AccountRecord as saved: a nil optional is left out.
    struct Row: Codable, Equatable {
        let id: String
        var name: String
        var color: String
        var configDir: String
        var keychainService: String
        let email: String?
        let accountUuid: String?
        var orgName: String?
        var orgUuid: String?
        var orgLabel: String? = nil
    }
    private struct AccountsFile: Codable { var accounts: [Row] }
    /// Its LoginSlot.Meta: the pair Claude held at the save, and Claude's sign-in keys from config.json.
    private struct Slot: Codable { var account: String?; var orgFolder: String?; var config: [String: String] }
    enum Display: String, Codable { case gauge, gaugePercent, gaugeNamePercent }
    enum Metric: String, Codable { case fiveHour, weekly }
    /// Its AppSettings. Every key is required here, so a key the new build drops fails the read.
    struct Settings: Codable, Equatable { var display: Display; var metric: Metric; var autoSwitch: Bool; var collapsed: Set<String> }
    private static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]

    let claude: StandInClaude
    private var state: URL { claude.stateDir }
    private func slot(_ id: String) -> URL { state.appendingPathComponent("slots/\(id)") }

    /// A row with its Claude Code login's profile on disk. `kept: false` is a row saved before rows
    /// kept organizations. The login folder sits in the stand-in's root, never under the real home.
    func row(_ n: Int, _ name: String, _ color: String, _ seat: StandSeat, email: String, orgName: String,
             orgLabel: String? = nil, kept: Bool = true) -> Row {
        let id = String(format: "acct-%08x", n)
        let dir = claude.root.appendingPathComponent("cli/\(id)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = [ClaudeFiles.cliAccount: ["accountUuid": seat.account, "emailAddress": email,
                                                "organizationUuid": seat.org, "organizationName": orgName]]
        try? JSONSerialization.data(withJSONObject: profile).write(to: dir.appendingPathComponent(ClaudeFiles.cliProfile))
        return Row(id: id, name: name, color: color, configDir: dir.path, keychainService: "test-\(id)", email: email,
                   accountUuid: seat.account, orgName: kept ? orgName : nil, orgUuid: kept ? seat.org : nil, orgLabel: orgLabel)
    }

    func write(_ rows: [Row], _ settings: Settings) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let accounts = state.appendingPathComponent("accounts.json")
        try enc.encode(AccountsFile(accounts: rows)).write(to: accounts, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accounts.path)
        try JSONEncoder().encode(settings).write(to: state.appendingPathComponent("settings.json"), options: .atomic)
    }

    /// Saves the sign-in Claude's files hold as `seat` into the row's slot, as that build's capture did
    /// with Claude quit: the claude.ai cookie rows into a fresh database, the sign-in keys into slot.json.
    func saveSlot(_ id: String, as seat: StandSeat) throws {
        claude.writeSignIn(seat)
        let fm = FileManager.default, dir = slot(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = "'" + claude.cookies.path.replacingOccurrences(of: "'", with: "''") + "'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-bail", dir.appendingPathComponent("cookies.db").path,
                       "ATTACH \(source) AS c; CREATE TABLE cookies AS SELECT * FROM c.cookies WHERE host_key IN ('.claude.ai','claude.ai');"]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.config)) as? [String: Any] ?? [:]
        let keys = Self.configKeys.reduce(into: [String: String]()) { keys, k in keys[k] = config[k] as? String }
        try JSONEncoder().encode(Slot(account: seat.account, orgFolder: seat.org, config: keys))
            .write(to: dir.appendingPathComponent("slot.json"), options: .atomic)
        for f in ["cookies.db", "slot.json"] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(f).path) }
    }

    /// The row's slot folder is on disk, empty or not.
    func hasSlot(_ id: String) -> Bool { FileManager.default.fileExists(atPath: slot(id).path) }

    /// The stand-in's write mark in a row's slot: which sign-in it holds.
    func slotMark(_ id: String) -> String? { claude.writeMark(in: slot(id).appendingPathComponent("cookies.db")) }

    /// Every file under slots/, by its path there, with its bytes.
    func slotFiles() -> [String: Data] {
        let root = state.appendingPathComponent("slots")
        let paths = FileManager.default.subpaths(atPath: root.path) ?? []
        return paths.reduce(into: [:]) { files, p in
            if let data = FileManager.default.contents(atPath: root.appendingPathComponent(p).path) { files[p] = data }
        }
    }

    /// accounts.json and settings.json as the previous build decodes them; nil where it can't.
    func read() -> (rows: [Row]?, settings: Settings?) {
        let accounts = (try? Data(contentsOf: state.appendingPathComponent("accounts.json")))
            .flatMap { try? JSONDecoder().decode(AccountsFile.self, from: $0) }?.accounts
        let settings = (try? Data(contentsOf: state.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        return (accounts, settings)
    }
}

/// Alpha runs out with its chat stopped while Beta and Gamma are out too, so the chat waits; then
/// `meanwhile` runs, and Alpha's meter shows room again from its reset, off the 5 min grid. Returns
/// Alpha's reset time.
@MainActor private func waitUntilAlphaResets(_ h: Harness, meanwhile: () -> Void = {}) async -> Date {
    let start = h.now
    let resetA = start.addingTimeInterval(737)
    h.usage.set(A, fiveHour: 100, resetsAt: resetA)
    for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: start.addingTimeInterval(4 * 3600)) }
    await h.pass(ClaudeTiming.meterEvery + 5)
    h.claude.logLimitStop("local_one")
    await h.pass(60)
    h.check(h.noticeHas("Every seat is out") && h.claude.actions.isEmpty, "setup: the chat waits, every seat out: \(h.notice), \(h.claude.actions)")
    meanwhile()
    let usage = h.usage
    h.clock.after(resetA.timeIntervalSince(h.now) - 5) { usage.set(A, fiveHour: 0, resetsAt: resetA.addingTimeInterval(5 * 3600)) }
    return resetA
}
