import Foundation

// Scenarios for the one rule: the app acts only on Claude's current hold of the seat in use and on
// current readings. Each is a reviewer's probe or a case the rule was written for, and each asserts
// what the person sees: the notice, the notifications, whether Claude was quit, what was typed, and
// which seat is In use.


@MainActor extension Harness {
    /// What the person has seen so far, for a failing check.
    var seen: String {
        "held \(String(describing: claude.held)), actions \(claude.actions), sent \(claude.sent), notice \(notice), posted \(claude.notifications)"
    }

    /// A wait is told on Alpha, then the person quits Claude and the app, and `hours` pass with every
    /// seat reset. Alpha then reads `alpha`; the app starts again, and later Claude opens on Alpha.
    func closedOvernight(hours: Double, alpha: Double) async {
        await everySeatOutAndAChatWaits()
        claude.stop()
        await pass(10 * 60)
        killApp()
        clock.advance(hours * 3600)
        usage.set(A, fiveHour: alpha, resetsAt: now.addingTimeInterval(3 * 3600))
        for s in [B, C] { usage.set(s, fiveHour: 3, resetsAt: now.addingTimeInterval(5 * 3600)) }
        make(); await tick(); await settle()
        await pass(6 * 60)
        claude.start()
        await pass(ClaudeTiming.settle + 5 * 60)
    }
}

let holdScenarios: [Scenario] = [
    Scenario(pair: "(Claude stops a chat, another chat on the seat ends a turn normally, then the seat reads 100)",
             model: "a turn that ends normally after a stop shows Claude served past it: nothing quits until Claude stops a chat again (review C2)") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        h.clock.advance(3)
        h.claude.logTurnEnded("local_two")
        await h.pass(10 * 60)
        h.check(h.quits == 0 && h.claude.sent.isEmpty, "Claude is not quit and nothing is typed: \(h.seen)")
        h.check(h.state("Alpha") == .inUse && h.notice.first == "In use reads 100%. It switches when Claude stops a chat.",
                "Alpha stays In use at 100% and the notice says why: \(h.seen)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.resumes("local_one") == 1, "Claude's next stop switches to Beta and resumes the chat once: \(h.seen)")
    },

    Scenario(pair: "(A wait is told, Claude is closed overnight, next morning it opens on Alpha with room)",
             model: "Claude reopened is a new hold: nothing from the night before is typed or posted (review C3)") { h in
        await h.closedOvernight(hours: 14, alpha: 3)
        h.check(h.state("Alpha") == .inUse, "Claude is on Alpha: \(h.seen)")
        h.check(h.claude.sent.isEmpty && h.quits == 0, "nothing typed, Claude not quit: \(h.seen)")
        h.check(h.waitPosts == 1 && h.notice.isEmpty, "no second wait posted, and no line: \(h.seen)")
    },

    Scenario(pair: "(A wait is told, Claude is closed overnight, Alpha is full again from other use, Claude opens on Alpha)",
             model: "a stop from a hold before Claude reopened never counts, so Claude is not quit; its next stop switches (review C4)") { h in
        await h.closedOvernight(hours: 14, alpha: 100)
        h.check(h.quits == 0 && h.claude.sent.isEmpty, "Claude is not quit and nothing is typed: \(h.seen)")
        h.check(h.state("Alpha") == .inUse && h.notice.first == "In use reads 100%. It switches when Claude stops a chat.",
                "Alpha In use at 100%, and the notice says why it stays: \(h.seen)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.resumes("local_one") == 1 && h.quits == 1, "today's stop switches once and resumes once: \(h.seen)")
    },

    Scenario(pair: "(Claude stops a chat on Alpha, the person signs Claude into Beta and back inside Claude, then Alpha reads 100)",
             model: "a sign-in inside Claude starts a new hold, like a switch by hand: the old stop never counts (review C1)") { h in
        await h.standard()
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(90)
        h.claude.signIn(B); await h.pass(ClaudeTiming.settle + 20)
        h.claude.signIn(A); await h.pass(ClaudeTiming.settle + 20)
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(10 * 60)
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing quit, typed or posted: \(h.seen)")
        h.check(h.notice.first == "In use reads 100%. It switches when Claude stops a chat.", "the notice says why Alpha stays: \(h.seen)")
    },

    Scenario(pair: "(Each earlier build's state file at launch, with the seat in use full and with room)",
             model: "no file on disk acts by itself: build 10's and the unreleased build's auto-switch.json and build 11's stops.json are never read, a corrupt or foreign switch-memory.json reads as empty; the next real stop still switches (reviews C5, C6, C11)") { h in
        await h.standard()
        let dir = Paths.stateDir
        let t = h.now.timeIntervalSinceReferenceDate
        // Build 10's auto-switch.json, and the shape the unreleased f58c9d3 wrote, with a wait a day old.
        let build10 = "{\"lastAttempt\":\(t - 600),\"outcome\":\"switched\",\"outUntil\":{\"row0\":\(t + 3 * 3600)}}"
        let unreleased = "{\"waiting\":{\"local_one\":{\"seat\":{\"account\":\"\(A.account)\",\"org\":\"\(A.org)\"},\"since\":\(t - 86400)}},\"resumed\":{},\"told\":{}}"
        for (i, file) in [build10, unreleased].enumerated() {
            try? Data(file.utf8).write(to: dir.appendingPathComponent("auto-switch.json"))
            // Build 11's stops.json; a switch-memory.json that is corrupt, then one d4390a7 wrote with a wait.
            try? Data("{\"\(A.account)_\(A.org)\":{\"at\":\(t - 3600)}}".utf8).write(to: dir.appendingPathComponent("stops.json"))
            let memory = i == 0 ? "{\"wait\":{\"hold\"" : "{\"wait\":{\"hold\":\"another hold\",\"fullSince\":\(t - 600)},\"handHold\":7,\"later\":true}"
            try? Data(memory.utf8).write(to: dir.appendingPathComponent("switch-memory.json"))
            h.usage.set(A, fiveHour: i == 0 ? 100 : 30, resetsAt: h.now.addingTimeInterval(3 * 3600))
            h.make(); await h.tick(); await h.settle()
            await h.pass(10 * 60)
            h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty && h.claude.notifications.isEmpty,
                    "launch \(i + 1): nothing quit, typed or posted: \(h.seen)")
        }
        h.check(h.store.facts().wait == nil, "a wait on file is never read: \(String(describing: h.store.facts().wait))")
        h.usage.set(A, fiveHour: 30, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.resumes("local_one") == 1, "the next real stop switches and resumes once: \(h.seen)")
    },

    Scenario(pair: "(switch-memory.json with one field unreadable)",
             model: "a field an earlier build wrote never costs the spacing (review C7)") { h in
        await h.standard()
        let t = h.now.timeIntervalSinceReferenceDate
        let json = "{\"lastAutoSwitch\":\(t - 60),\"wait\":\"not a wait\",\"handHold\":\"a hold\"}"
        try? Data(json.utf8).write(to: Paths.stateDir.appendingPathComponent("switch-memory.json"))
        let loaded = SwitchMemory.load()
        h.check(loaded.lastAutoSwitch != nil, "the spacing stays: \(loaded)")
        h.make(); await h.tick(); await h.settle()
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(5 * 60)
        h.check(h.quits == 0 && h.noticeHas("Switching to Beta at"), "the spacing still holds the switch: \(h.seen)")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 15 * 60)
        let first = h.claude.at("quit").first
        h.check(first.map { $0 >= h.started.addingTimeInterval(ClaudeTiming.settle + 5 + Limits.autoSwitchSpacing - 60 - 5) } ?? false,
                "the switch starts once the spacing ends: \(h.seen)")
    },

    Scenario(pair: "(A chat is stopped on Alpha, the person moves Claude to Beta inside Claude and removes Alpha's row)",
             model: "nothing waits on a seat Claude is not on: no line about it, then or two days later (review C8)") { h in
        await h.everySeatOutAndAChatWaits()
        h.claude.signIn(B); await h.pass(ClaudeTiming.settle + 20)
        try? h.rows([("Beta", B), ("Gamma", C)])
        await h.pass(10 * 60)
        let after10 = h.notice
        h.clock.advance(2 * 86400)
        await h.pass(10 * 60)
        h.check(!after10.contains { $0.contains("wait") } && !h.notice.contains { $0.contains("wait") },
                "no line says a chat waits: after 10 min \(after10), after 2 days \(h.notice)")
        h.check(h.claude.actions.isEmpty && h.claude.sent.isEmpty, "nothing quit or typed: \(h.seen)")
    },

    Scenario(pair: "(A chat is stopped on Alpha, two days on Beta, then Beta runs out and the switch lands on Alpha)",
             model: "a switch resumes only the chats it is for: the two-day-old chat on Alpha is left alone (review C9)") { h in
        await h.everySeatOutAndAChatWaits()
        h.claude.signIn(B); await h.pass(ClaudeTiming.settle + 20)
        h.check(h.notice.isEmpty, "on Beta, no line about Alpha's chat: \(h.notice)")
        h.clock.advance(2 * 86400)
        h.usage.set(A, fiveHour: 5, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.usage.set(B, fiveHour: 20, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.usage.set(C, fiveHour: 100, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.claude.addChat("local_b", in: B, lastActivity: h.now)
        h.claude.screens["local_b"] = ChatScreen(busy: false, composer: true, draft: false)
        await h.pass(6 * 60)
        h.claude.logLimitStop("local_b", seatReadsFull: true)
        await h.run(until: { h.claude.held == A && !h.switchInFlight && h.resumed("local_b") }, limit: 15 * 60)
        await h.pass(3 * 60)
        h.check(h.claude.held == A && h.resumes("local_b") == 1, "Beta's chat moves to Alpha and resumes once: \(h.seen)")
        h.check(!h.resumed("local_one"), "nothing is typed into the two-day-old chat: \(h.seen)")
    },

    Scenario(pair: "(Click Switch on a seat that reads out, then Claude stops a chat there)",
             model: "Claude's refusal after a switch by hand moves it on, like any stop (AutoSwitch.stopped; review C10)") { h in
        await h.standard()
        h.usage.set(B, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 10 * 60)
        let quits = h.quits
        await h.pass(2 * 60)
        h.check(h.claude.held == B && h.quits == quits && h.state("Beta") == .inUse, "Claude stays on the chosen Beta: \(h.seen)")
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == C && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == C && h.quits == quits + 1, "Claude's stop on Beta moves it to Gamma: \(h.seen)")
        h.check(h.resumes("local_one") == 1, "\"resume\" typed once: \(h.seen)")
        h.check(h.claude.notifications.last == "Switched to Gamma: Beta is out. 1 chat resumed.", "the person is told: \(h.seen)")
    },

    Scenario(pair: "(Click Switch back to Alpha, the Mac moves from Eastern to Pacific while Claude keeps Eastern time, the app restarts, Alpha reads 100, then Claude stops a chat)",
             model: "the app never reads Claude's printed times: the switches confirm, the hold settles on the app's clock, a stop from before the switch by hand never counts, a new stop does") { h in
        guard let east = TimeZone(identifier: "America/New_York"), let west = TimeZone(identifier: "America/Los_Angeles") else { return }
        NSTimeZone.default = east
        h.claude.printZone = east
        await h.standard()
        h.claude.addChat("local_two", in: A, lastActivity: h.now)
        h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
        // A stop on Alpha for a limit its meters don't show, then the person's own switches away and back.
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(2 * 60)
        for (row, seat) in [("Beta", B), ("Alpha", A)] {
            h.click(row)
            await h.run(until: { h.claude.held == seat && h.state(row) == .inUse && !h.switchInFlight }, limit: 10 * 60)
        }
        let quits = h.quits, sent = h.claude.sent.count
        // The Mac lands in Pacific time; Claude, still running, prints Eastern time; the app restarts.
        h.claude.printZone = east
        NSTimeZone.default = west
        h.check(NSTimeZone.default.identifier == west.identifier, "setup: the app's zone is Pacific: \(NSTimeZone.default.identifier)")
        h.killApp(); h.clock.advance(60); h.make(); await h.tick(); await h.settle()
        await h.pass(ClaudeTiming.settle + 5)
        h.check(h.state("Alpha") == .inUse && h.store.facts().hold?.settled(at: h.now) == true,
                "Alpha is In use, and its hold settles a minute after the app read it, whatever time Claude prints: \(h.seen)")
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        let reads = h.usage.readsOf(A).count
        await h.pass(10 * 60)
        h.check(h.quits == quits && h.claude.sent.count == sent, "the stop from before the switch by hand never counts: \(h.seen)")
        h.check(h.notice.first == "In use reads 100%. It switches when Claude stops a chat.", "the hold is settled and the line says why Alpha stays: \(h.seen)")
        h.check(h.usage.readsOf(A).count - reads <= 3, "Alpha is read on its schedule, not every minute: \(h.usage.readsOf(A).count - reads) reads in 10 min")
        h.claude.logLimitStop("local_two", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_two") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.quits == quits + 1, "today's stop switches to Beta: \(h.seen)")
        h.check(Array(h.claude.sent.dropFirst(sent)) == ["local_two resume"], "only the chat it is for is resumed: \(h.seen)")
    },

    Scenario(pair: "(Automatic switch fails and reopens Claude on Alpha)",
             model: "the reopen is a new hold, so nothing retries by itself; the line says what still works, and a switch by hand works at once (EM ruling, 2026-11-24)") { h in
        await h.standard()
        // Alpha's chat folder can't be read at the switch's move step, so the switch undoes itself.
        let strike = Strike()
        defer { strike.restore() }
        h.claude.onStep = { name in
            if case .strike = strike.next(name, strikeAt: "move") { strike.chmod([ClaudeApp.folder(A.identity)], files: 0o200, dirs: 0o300) }
        }
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.quits == 1 && h.claude.held == A && !h.switchInFlight }, limit: 15 * 60)
        strike.restore(); h.claude.onStep = nil
        let quits = h.quits, launches = h.launches
        h.check(strike.fired && quits == 1 && launches == 1, "setup: one quit and one reopen: \(h.seen)")
        h.check(h.claude.held == A && h.claude.signInOnDisk() == A, "Claude is back on Alpha: \(h.seen)")
        h.check(h.notice.first == "Didn't switch to Beta. Switch by hand.", "the line says what happened and what works: \(h.seen)")
        h.check(h.notice.last?.hasSuffix("Switch by hand, or it tries again when Claude next stops a chat.") ?? false, "its full sentence on hover: \(h.notice)")
        h.check(h.claude.notifications.last?.hasPrefix("Didn't switch to Beta: ") ?? false
                && h.claude.notifications.last?.hasSuffix("Switch by hand, or it tries again when Claude next stops a chat.") ?? false,
                "the notification says the same: \(h.claude.notifications)")
        await h.pass(20 * 60)
        h.check(h.quits == quits && h.launches == launches && h.claude.sent.isEmpty, "nothing retries and nothing is typed by itself: \(h.seen)")
        h.check(h.notice.first == "Didn't switch to Beta. Switch by hand.", "the line stays: \(h.seen)")
        h.check(h.percents("Alpha").contains(100), "Alpha's row still reads 100%: \(h.percents("Alpha"))")
        h.click("Gamma")
        await h.run(until: { h.claude.held == C && h.state("Gamma") == .inUse && !h.switchInFlight }, limit: 10 * 60)
        h.check(h.claude.held == C && h.quits == quits + 1 && h.claude.chats(in: C).contains("local_one"), "a switch by hand to Gamma works at once, with the chat: \(h.seen)")
    },
]
