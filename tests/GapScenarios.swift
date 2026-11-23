import Foundation

// Scenarios for model rules the scenario review (ca-reviewer-a, 2026-11-23) found with no pair.
// Each is written from the model's words, and each check fails if the app does the wrong thing.

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
        h.check(next.map { $0.timeIntervalSince(failed) <= Limits.settle + 15 } ?? false,
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
]
