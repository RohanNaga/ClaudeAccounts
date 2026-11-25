import Foundation

// The seventh review's gaps, kept (reviewer-ca-27-7, finding 1 and probe R7-5): a switch the app
// recovers from its journal never quits a running Claude and never types, whatever Claude is doing
// when the app comes back, and a seat whose last word is a refusal, as the only other seat, gets a
// line while the chat waits. Each fails on 1a8e55e. The last is the eighth review's probe R8-2,
// which fails on 043a7cd: Claude opened during the recovery itself is read the same way.

/// Alpha's chat stops at its limit and the automatic switch to Beta starts; the app is killed as
/// the switch's `hook` step begins and stays down.
@MainActor func autoSwitchKilled(_ h: Harness, at hook: String) async -> Lines {
    let lines = await autoStart(h)
    let strike = autoStrike(h, at: hook, .killApp)
    await startAuto(h)
    await h.run(until: { strike.parked || !h.switchInFlight }, limit: 1800)
    h.check(strike.parked, "setup: the app was killed at \(hook)")
    h.killApp()
    return lines
}

/// The person opens Claude while the app is down; the app then starts and runs until it is done.
@MainActor func personOpensClaudeThenAppStarts(_ h: Harness, _ lines: Lines) async {
    h.claude.start()
    await h.pass(h.claude.nameAfter + 5)
    h.make(); await h.tick(); await h.settle()
    await runToEnd(h, lines)
}

/// After the recovery: nothing typed through the resume's whole window, and one post about the chat.
@MainActor func recoveredTypesNothing(_ h: Harness, _ lines: Lines, quits: Int, launches: Int) async {
    await h.pass(ClaudeTiming.resumeFor + 5 * 60)
    lines.note(h)
    h.check(h.claude.sent.isEmpty, "nothing stored types: typed \(h.claude.sent)")
    h.check(h.quits == quits && h.launches == launches, "the recovery quits no running Claude: \(h.claude.actions)")
    h.check(h.claude.notifications.filter { $0.contains("Chats were not resumed") }.count == 1, "one post says the chat was not resumed: \(h.claude.notifications)")
    checkActs(h)
}

let reviewSevenScenarios: [Scenario] = [
    Scenario(pair: "(Automatic switch killed at load; the person opens Claude, on Alpha, before the app starts again)",
             model: "review seven finding 1: Claude running on the seat the switch left means it did not happen; the journal goes, the chat goes back, nothing is quit or typed") { h in
        let lines = await autoSwitchKilled(h, at: "load")
        await personOpensClaudeThenAppStarts(h, lines)
        checkEnds(h, [("Alpha", A)], chats: ["local_one"], lines: lines.seen)
        h.check(lines.has("Claude opened as Alpha, not Beta. Chats were not resumed."), "one line says what happened: \(lines.seen)")
        await recoveredTypesNothing(h, lines, quits: 1, launches: 0)
    },

    Scenario(pair: "(Automatic switch killed at launch; the person opens Claude, on Beta, before the app starts again)",
             model: "review seven finding 1: Claude running on the target confirms the switch from its log; nothing is quit or typed") { h in
        let lines = await autoSwitchKilled(h, at: "launch")
        await personOpensClaudeThenAppStarts(h, lines)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(lines.has("Finished switching to Beta. Chats were not resumed."), "one line says what happened: \(lines.seen)")
        await recoveredTypesNothing(h, lines, quits: 1, launches: 0)
    },

    Scenario(pair: "(Automatic switch killed at load; Claude stays closed until the app starts again)",
             model: "review seven finding 1: with Claude closed the recovery finishes the files, opens Claude on Beta, and types nothing") { h in
        let lines = await autoSwitchKilled(h, at: "load")
        h.make(); await h.tick(); await h.settle()
        await runToEnd(h, lines)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(lines.has("Finished switching to Beta. Chats were not resumed."), "one line says what happened: \(lines.seen)")
        await recoveredTypesNothing(h, lines, quits: 1, launches: 1)
    },

    Scenario(pair: "(Claude refused Beta's login while the app was quit; Beta is the only other seat and Alpha runs out)",
             model: "review seven R7-5: the chat waits, and one line says Beta asked for a new sign-in, with how to try it on hover; nothing is posted") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        for (n, s) in [("Beta", B), ("Alpha", A)] { try? await h.savedLogin(n, s) }
        for s in [A, B] { h.usage.set(s, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: A, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claude.stale = [B]
        h.claude.writeSignIn(B)
        h.claude.start(); h.clock.advance(60)
        h.claude.stop()
        h.claude.writeSignIn(A)
        h.claudeHoldsSettled()
        h.make(); await h.tick(); await h.settle()
        await h.pass(2 * 60)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        let line = "Beta asked for a new sign-in."
        await h.run(until: { h.noticeHas(line) }, limit: 20 * 60)
        h.check(h.notice == [line, "It isn't switched to by itself. Switch by hand to try it."] && h.nextRow == nil,
                "the waiting chat gets one line, why on hover, and no seat is Next: \(h.seen)")
        h.check(h.quits == 0 && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing quits, types or posts: \(h.seen)")
        let clicked = h.now
        h.click("Beta")
        await h.run(until: { h.quits > 0 }, limit: 60)
        h.check(h.claude.at("quit").first.map { $0.timeIntervalSince(clicked) <= Double(Store.tickEvery) } ?? false,
                "a hand Switch to Beta starts at once: \(h.claude.actions)")
    },

    Scenario(pair: "(Automatic switch killed at load; the person opens Claude, on Beta, just after the recovery loads Beta)",
             model: "review eight R8-2: a recovery that finds Claude running at any step from the load on confirms from the log, as at its start; nothing is quit or typed") { h in
        let lines = await autoSwitchKilled(h, at: "load")
        let claude = h.claude
        var opened = false
        claude.onStep = { name in
            if name == "journal", !opened, claude.signInOnDisk() == B, claude.pids().isEmpty { opened = true; claude.start() }
        }
        h.make(); await h.tick(); await h.settle()
        await runToEnd(h, lines)
        h.check(opened, "setup: the person opened Claude during the recovery, after its load")
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(lines.has("Finished switching to Beta. Chats were not resumed."), "one line names the seat Claude is on: \(lines.seen)")
        await recoveredTypesNothing(h, lines, quits: 1, launches: 0)
    },
]
