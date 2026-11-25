import Foundation

// Scenarios for the app holding still: a sign-in inside Claude that ends a wait, a wait told once
// across a relaunch and Auto-Switch off and on, the spacing between automatic switches, and a stop
// the usage service's first reading after it does not show yet. Each asserts what the
// person sees: the notice, the notifications, whether Claude was quit, what was typed, and which
// seat is In use.

@MainActor extension Harness {
    /// The "Every seat is out" notifications posted so far.
    var waitPosts: Int { claude.notifications.filter { $0.hasPrefix("Every seat is out") }.count }
    /// How many times "resume" was typed into `chat`.
    func resumes(_ chat: String) -> Int { claude.sent.filter { $0 == "\(chat) resume" }.count }
    /// Every other seat reads out; Claude stops the chat on Alpha, which then reads out too: a wait.
    func everySeatOutAndAChatWaits() async {
        await standard()
        let reset = now.addingTimeInterval(4 * 3600)
        for s in [B, C] { usage.set(s, fiveHour: 100, resetsAt: reset) }
        await pass(ClaudeTiming.meterEvery + 5)
        claude.logLimitStop("local_one", seatReadsFull: true)
        await pass(3 * 60)
        check(waitPosts == 1 && noticeHas("Every seat is out. Chats resume at"), "setup: the wait is told once: \(claude.notifications), \(notice)")
    }
}

/// A fourth seat, for the hand-switch scenario: signed in, never read.
private let D = StandSeat(4, org: 1)

/// The line the notice shows while the seat in use reads out and no stop counts.
private let fullNoStop = "In use reads 100%. It switches when Claude stops a chat."

let waitScenarios: [Scenario] = [
    Scenario(pair: "(Click Switch inside the spacing, on a seat cooling down, not read yet, out by its weekly meter, out by its 5-hour meter)",
             model: "a switch by hand works on any signed-in seat, whatever it reads and with Auto-Switch off; the automatic switch never undoes it") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C), ("Delta", D)])
        for (n, seat) in [("Beta", B), ("Gamma", C), ("Delta", D), ("Alpha", A)] { try? await h.savedLogin(n, seat) }
        for seat in [A, B, C] { h.usage.set(seat, fiveHour: 20, resetsAt: h.now.addingTimeInterval(3 * 3600)) }   // Delta is never read
        h.claude.addChat("local_one", in: A, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claudeHoldsSettled(); h.make()
        await h.tick(); await h.settle()
        // An automatic switch to Beta starts the 15-minute spacing; Alpha now reads out, and Claude's
        // stop of the chat there stays the chat's last word.
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        // Gamma failed an automatic switch a minute ago, so it is cooling down.
        PairFile<Date>(name: "failed-targets.json").save([C.identity: h.now.addingTimeInterval(-60)])
        h.make(); await h.tick(); await h.settle()

        @MainActor func byHand(_ row: String, _ seat: StandSeat, _ what: String) async {
            let quits = h.quits
            h.check(h.action(row) == .switchTo, "\(what): \(row) offers Switch: \(String(describing: h.action(row)))")
            h.click(row)
            await h.run(until: { h.claude.held == seat && h.state(row) == .inUse && !h.switchInFlight }, limit: 10 * 60)
            h.check(h.claude.held == seat && h.state(row) == .inUse && h.quits == quits + 1,
                    "\(what): Claude reopens on \(row): held \(String(describing: h.claude.held)), \(h.claude.actions), \(h.notice)")
        }
        await byHand("Gamma", C, "inside the spacing, on a seat cooling down")
        h.store.setAutoSwitch(false)
        h.check(h.meterText("Delta") == "not read yet", "setup: Delta is not read yet: \(String(describing: h.meterText("Delta")))")
        await byHand("Delta", D, "with Auto-Switch off, on a seat not read yet")
        h.store.setAutoSwitch(true)
        h.usage.set(B, fiveHour: 30, weekly: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.check(h.state("Beta") == .out, "setup: Beta reads out by its weekly meter: \(String(describing: h.state("Beta")))")
        await byHand("Beta", B, "on a seat out by its weekly meter")
        h.check(h.state("Alpha") == .out, "setup: Alpha reads out by its 5-hour meter: \(String(describing: h.state("Alpha")))")
        await byHand("Alpha", A, "on a seat out by its 5-hour meter, with an old stop there")
        let quits = h.quits
        await h.pass(ClaudeTiming.settle + 2 * ClaudeTiming.meterEvery)
        h.check(h.claude.held == A && h.state("Alpha") == .inUse && h.quits == quits,
                "the automatic switch leaves Claude on the seat the person chose: held \(String(describing: h.claude.held)), \(h.claude.actions), \(h.notice)")
    },

    Scenario(pair: "(A chat waits on Alpha, the person signs Claude into Beta, which reads 100 with no chat stopped, then back into Alpha)",
             model: "a sign-in inside Claude starts a new hold: the wait ends, nothing is quit from Beta, and back on Alpha the old stop never counts; only Claude's next stop switches (review B4)") { h in
        await h.everySeatOutAndAChatWaits()
        // The person signs Claude into Beta inside Claude. Beta reads with room for now.
        h.usage.set(B, fiveHour: 30, resetsAt: h.now.addingTimeInterval(4 * 3600))
        h.claude.signIn(B)
        await h.pass(ClaudeTiming.settle + ClaudeTiming.meterEvery + 30)
        h.check(h.state("Beta") == .inUse && h.notice.isEmpty, "Beta is In use, and no line speaks of Alpha's chat: \(String(describing: h.state("Beta"))), \(h.notice)")
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty, "nothing quit or typed on Beta: \(h.claude.actions), \(h.claude.sent)")
        // Beta reads 100, and Claude stopped no chat on Beta. Gamma reads with room.
        h.usage.set(B, fiveHour: 100, resetsAt: h.now.addingTimeInterval(4 * 3600))
        h.usage.set(C, fiveHour: 10, resetsAt: h.now.addingTimeInterval(4 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 30)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty,
                "Claude is not quit from Beta, where it stopped no chat: \(h.claude.actions), held \(String(describing: h.claude.held)), \(h.claude.notifications)")
        h.check(h.state("Beta") == .inUse && h.nextRow == "Gamma", "Beta stays In use with Gamma Next: \(String(describing: h.state("Beta"))), \(String(describing: h.nextRow))")
        h.check(h.notice.first == fullNoStop, "the notice says why Beta stays: \(h.notice)")
        // The person signs Claude back into Alpha, still out: the stop there is from an earlier hold.
        h.claude.signIn(A)
        await h.pass(ClaudeTiming.settle + ClaudeTiming.meterEvery + 30)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.notice.first == fullNoStop,
                "back on Alpha, the old stop never counts: \(h.claude.actions), \(h.claude.sent), \(h.notice)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == C && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == C && h.state("Gamma") == .inUse, "Claude's new stop on Alpha switches to Gamma: held \(String(describing: h.claude.held)), \(h.claude.actions)")
        h.check(h.resumes("local_one") == 1, "\"resume\" typed once: \(h.claude.sent)")
        h.check(h.quits == 1 && h.waitPosts == 1, "one quit, one wait posted: \(h.claude.actions), \(h.claude.notifications)")
    },

    Scenario(pair: "(Every seat out and a chat waits, the app relaunches, then Auto-Switch goes off and on)",
             model: "a wait lives only in the running app: after a relaunch the stop from before never counts, the wait is not told again, and only Claude's next stop switches") { h in
        await h.everySeatOutAndAChatWaits()
        h.make(); await h.tick(); await h.settle()
        await h.pass(10 * 60)
        h.check(!h.noticeHas("Every seat is out") && h.waitPosts == 1, "after a relaunch no wait line, and nothing posted again: \(h.seen)")
        h.store.setAutoSwitch(false)
        await h.pass(2 * 60)
        h.store.setAutoSwitch(true)
        await h.pass(5 * 60)
        h.check(!h.noticeHas("Every seat is out") && h.waitPosts == 1, "off and on, still no wait line or second post: \(h.seen)")
        // Beta reads with room: the stop from before the relaunch never switches, and the line says what would.
        h.usage.set(B, fiveHour: 10, resetsAt: h.now.addingTimeInterval(4 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 30)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty, "nothing quit or typed for the old stop: \(h.seen)")
        h.check(h.notice.first == fullNoStop && h.nextRow == "Beta", "the line says it switches when Claude stops a chat, Beta Next: \(h.seen)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.state("Beta") == .inUse && h.resumes("local_one") == 1 && h.waitPosts == 1,
                "Claude's next stop switches to Beta, \"resume\" typed once, one wait posted in all: \(h.seen)")
    },

    Scenario(pair: "(Automatic switch, the new seat runs out minutes later, the app relaunches inside the spacing)",
             model: "the next automatic switch waits 15 minutes and says when; a relaunch keeps the spacing, and only a stop seen after it counts") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        guard let first = h.claude.at("quit").first else { h.check(false, "setup: the first switch ran: \(h.claude.actions)"); return }
        await h.pass(2 * 60)
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(3 * 60)
        // The spacing runs from the decision, a few seconds before the quit.
        // The expected times are formatted at each check, with the clock as it is then: ClockText drops the
        // weekday once the switch falls on a later day, so a line built before midnight is wrong after it.
        let switchTimes: @MainActor () -> [String] = { (0...10).map { ClockText.time(first.addingTimeInterval(Limits.autoSwitchSpacing - TimeInterval($0)), now: h.now) } }
        let switchLines: @MainActor () -> [String] = { switchTimes().map { "Switching to Gamma at \($0)." } }
        h.check(h.notice.first.map(switchLines().contains) ?? false, "the notice says when the next switch comes: \(h.notice), wanted \(switchLines()[0])")
        h.check(switchTimes().contains { h.notice.last == "Beta is out. Switching to Gamma at \($0): automatic switches are at least 15 minutes apart." },
                "its full sentence names Beta and the spacing: \(h.notice)")
        h.check(h.state("Beta") == .inUse && h.nextRow == "Gamma" && h.quits == 1, "Beta In use, Gamma Next, one quit so far: \(h.claude.actions)")
        h.make(); await h.tick(); await h.settle()
        await h.pass(ClaudeTiming.settle + 5)
        h.check(!h.noticeHas("Switching to Gamma") && h.quits == 1, "after a relaunch the stop from before never counts: \(h.seen)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(2 * 60)
        h.check(h.notice.first.map(switchLines().contains) ?? false, "Claude's stop after the relaunch waits out the same spacing: \(h.seen)")
        await h.run(until: { h.quits > 1 }, limit: 20 * 60)
        let second = h.claude.at("quit").dropFirst().first
        h.check(second.map { $0 >= first.addingTimeInterval(Limits.autoSwitchSpacing - 10) } ?? false,
                "a relaunch does not lift the spacing: second quit \(second.map { "\(Int($0.timeIntervalSince(first))) s" } ?? "never") after the first")
        await h.run(until: { h.claude.held == C && !h.switchInFlight && h.resumes("local_one") == 2 }, limit: 10 * 60)
        h.check(h.state("Gamma") == .inUse && h.resumes("local_one") == 2, "then on to Gamma, the chat resumed there: \(h.claude.actions), \(h.claude.sent)")
    },

    Scenario(pair: "(In use settled, limit stop, the next reading still shows room, then the seat reads 100)",
             model: "a stop counts when the seat's first full reading after it comes within 15 minutes, with no turn ended in between") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        let stop = h.now
        // The app reads the log a moment after Claude writes it; a reading in the stop's own second
        // can't be told apart from one before it.
        h.clock.advance(2)
        await h.pass(90)
        h.check(h.usage.readsOf(A).contains { $0 > stop }, "setup: Alpha was read after the stop, with room: \(h.usage.readsOf(A))")
        h.check(h.claude.actions.isEmpty && h.notice.isEmpty, "nothing happens while Alpha reads with room: \(h.claude.actions), \(h.notice)")
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 15 * 60)
        h.check(h.claude.held == B && h.state("Beta") == .inUse, "switched to Beta once Alpha read 100: held \(String(describing: h.claude.held)), \(h.claude.actions), \(h.notice)")
        h.check(h.quits == 1 && h.resumes("local_one") == 1, "one quit, \"resume\" typed once: \(h.claude.actions), \(h.claude.sent)")
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. 1 chat resumed."], "posted: \(h.claude.notifications)")
    },

    Scenario(pair: "(In use settled, limit stop, the next reading shows room, another chat ends a turn, then the seat reads 100)",
             model: "a turn that ended normally after a stop proves Claude served past it: the stop never counts") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        h.clock.advance(2)
        await h.pass(90)
        h.check(h.state("Alpha") == .inUse && h.claude.actions.isEmpty, "setup: Alpha read with room after the stop: \(h.claude.actions)")
        h.claude.logTurnEnded("local_two")
        await h.pass(30)
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(20 * 60)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.claude.notifications.isEmpty,
                "no quit, nothing typed or posted: \(h.claude.actions), \(h.claude.sent), \(h.claude.notifications)")
        h.check(h.state("Alpha") == .inUse && h.nextRow == "Beta", "Alpha stays In use, Beta Next")
        h.check(h.notice == [fullNoStop, "Alpha reads 100%. It switches when Claude next stops a chat there for its limit."],
                "the notice says why nothing switches: \(h.notice)")
    },

    Scenario(pair: "(In use settled, limit stop, the seat reads with room for 20 minutes, then 100)",
             model: "a full reading more than 15 minutes after a stop does not count it; the notice says what will") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        h.clock.advance(2)
        await h.pass(20 * 60)
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 30)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.claude.notifications.isEmpty,
                "no quit, nothing typed or posted: \(h.claude.actions), \(h.claude.sent), \(h.claude.notifications)")
        h.check(h.state("Alpha") == .inUse && h.nextRow == "Beta" && h.notice.first == fullNoStop,
                "Alpha In use at 100%, Beta Next, and the line says why: \(h.notice)")
        // Claude stops the chat again: the switch comes, as the line said.
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.state("Beta") == .inUse && h.quits == 1 && h.resumes("local_one") == 1,
                "switched to Beta, \"resume\" typed once: \(h.claude.actions), \(h.claude.sent)")
    },
]
