import Foundation

// The fourth review's gaps, kept (reviewer-ca-27-d, probes D6, D10, D11, D12). The rule: the app acts
// by itself only on a limit stop it saw arrive while it ran, timed by its own clock, and a wait ends
// at the first current reading of its seat with room, whether or not anything was resumed. Each
// scenario fails on d4390a7.

let arrivalScenarios: [Scenario] = [
    Scenario(pair: "(A wait is told, at the reset the chat ends a turn by itself, later Claude stops another chat for a limit the meters don't show, Alpha reads 100 then 30)",
             model: "review D12, in one run of the app: the wait ended at the reset, so nothing is ever typed into the other chat") { h in
        await h.everySeatOutAndAChatWaits()
        h.claude.addChat("local_two", in: A, lastActivity: h.now)
        h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
        h.usage.set(A, fiveHour: 5, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.claude.logTurnEnded("local_one")
        await h.pass(6 * 60)
        h.check(h.store.facts().wait == nil && h.notice.isEmpty, "the wait ended at the first reading with room: \(h.seen)")
        await h.pass(3600)
        h.usage.set(A, fiveHour: 30, resetsAt: h.now.addingTimeInterval(4 * 3600))
        h.claude.logLimitStop("local_two", seatReadsFull: false)
        await h.pass(2 * 3600)
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(2 * 3600))
        await h.pass(6 * 60)
        h.usage.set(A, fiveHour: 30, resetsAt: h.now.addingTimeInterval(2 * 3600))
        await h.pass(6 * 60)
        h.check(h.claude.sent.isEmpty && h.quits == 0 && h.waitPosts == 1, "nothing typed, quit or posted again: \(h.seen)")
    },
    Scenario(pair: "(PROBE D12 the stored wait outlives its chats and later resumes a meter-invisible stop)",
             model: "review D12 as probed, with two relaunches of the app: nothing typed into a chat stopped for a limit the meters never showed") { h in
        await h.everySeatOutAndAChatWaits()
        h.claude.addChat("local_two", in: A, lastActivity: h.now)
        h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
        h.usage.set(A, fiveHour: 5, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.claude.logTurnEnded("local_one")
        await h.pass(6 * 60)
        h.killApp(); h.clock.advance(3600); h.make(); await h.tick(); await h.settle()
        h.usage.set(A, fiveHour: 30, resetsAt: h.now.addingTimeInterval(4 * 3600))
        h.claude.logLimitStop("local_two", seatReadsFull: false)
        await h.pass(6 * 60)
        h.killApp(); h.clock.advance(2 * 3600); h.make(); await h.tick(); await h.settle()
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(2 * 3600))
        await h.pass(6 * 60)
        h.check(h.noticeHas("In use reads 100%. It switches when Claude stops a chat.") || h.notice.isEmpty, "at 100, no wait is told: \(h.seen)")
        h.usage.set(A, fiveHour: 30, resetsAt: h.now.addingTimeInterval(2 * 3600))
        await h.pass(6 * 60)
        h.check(!h.resumed("local_two") && h.claude.sent.isEmpty && h.waitPosts == 1, "nothing typed: \(h.seen)")
    },
    Scenario(pair: "(Two chats wait on Alpha, at the reset the person resumes one by hand before the app reads the room)",
             model: "review D6: the wait ends at the reading with room; the other chat, still stopped, is resumed once") { h in
        await h.standard()
        h.claude.addChat("local_two", in: A, lastActivity: h.now)
        h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
        let reset = h.now.addingTimeInterval(4 * 3600)
        for s in [B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        h.clock.advance(20)
        h.claude.logLimitStop("local_two", seatReadsFull: true)
        await h.pass(3 * 60)
        h.check(h.waitPosts == 1 && h.noticeHas("Every seat is out. Chats resume at"), "setup: one wait told for both: \(h.seen)")
        h.usage.set(A, fiveHour: 1, resetsAt: h.now.addingTimeInterval(5 * 3600))
        h.claude.logTurnEnded("local_two")
        await h.pass(10 * 60)
        h.check(h.claude.sent == ["local_one resume"], "the chat still stopped is resumed once, the one the person ran is left: \(h.seen)")
        h.check(h.store.facts().wait == nil && !h.noticeHas("Every seat is out"), "the wait is over: \(h.seen)")
        await h.pass(30 * 60)
        h.check(h.claude.sent == ["local_one resume"] && h.waitPosts == 1, "and nothing more: \(h.seen)")
    },
    Scenario(pair: "(PROBE D10 Claude follows a zone change mid-hold, the app relaunches, old stop reads three hours newer)",
             model: "review D10: a stop already in the log when the app launches never switches or types, whatever zone it was printed in") { h in
        guard let east = TimeZone(identifier: "America/New_York"), let west = TimeZone(identifier: "America/Los_Angeles") else { return }
        NSTimeZone.default = east
        h.claude.printZone = east
        await h.standard()
        await h.pass(60)
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(60)
        h.killApp()
        h.clock.advance(2 * 3600 + 48 * 60)
        NSTimeZone.default = west
        h.claude.printZone = west
        h.claude.log("[heartbeat] still running")
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        for s in [B, C] { h.usage.set(s, fiveHour: 10, resetsAt: h.now.addingTimeInterval(4 * 3600)) }
        h.make(); await h.tick(); await h.settle()
        await h.pass(20 * 60)
        h.check(h.quits == 0 && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing quit, typed or posted: \(h.seen)")
        h.check(h.noticeHas("In use reads 100%. It switches when Claude stops a chat."), "the row and the line say Alpha is full: \(h.seen)")
    },
    Scenario(pair: "(The app launches during the repeated hour of a fall-back night, five minutes after Claude stopped a chat an hour earlier)",
             model: "review D11: a stop found in the log at launch never counts; no log time is set against the clock") { h in
        guard let ny = TimeZone(identifier: "America/New_York") else { return }
        NSTimeZone.default = ny
        h.claude.printZone = ny
        let iso = ISO8601DateFormatter()
        h.clock.advance(iso.date(from: "2026-11-01T05:30:00Z")!.timeIntervalSince(h.now))
        await h.standard()
        // 01:40 EDT: the first pass of the repeated hour.
        h.clock.advance(iso.date(from: "2026-11-01T05:40:00Z")!.timeIntervalSince(h.now))
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        h.killApp()
        // 01:45 EST, an hour and five minutes later: printed five minutes after the stop.
        h.clock.advance(iso.date(from: "2026-11-01T06:45:00Z")!.timeIntervalSince(h.now))
        h.claude.log("[heartbeat] still running")
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(3 * 3600))
        h.make(); await h.tick(); await h.settle()
        await h.pass(15 * 60)
        h.check(h.quits == 0 && h.claude.sent.isEmpty && h.claude.notifications.isEmpty, "nothing quit, typed or posted: \(h.seen)")
    },
    Scenario(pair: "(Every seat out and a chat waits, the Mac sleeps three hours, Alpha still reads 100, Beta reads with room)",
             model: "a run of full readings starts again after the Mac wakes: a stop from before the sleep never switches") { h in
        await h.everySeatOutAndAChatWaits()
        h.clock.sleepMac(3 * 3600)
        h.store.woke()
        h.usage.set(A, fiveHour: 100, resetsAt: h.now.addingTimeInterval(2 * 3600))
        h.usage.set(B, fiveHour: 10, resetsAt: h.now.addingTimeInterval(5 * 3600))
        await h.pass(10 * 60)
        h.check(h.quits == 0 && h.claude.sent.isEmpty && h.waitPosts == 1, "nothing quit, typed or posted: \(h.seen)")
        h.check(h.noticeHas("In use reads 100%. It switches when Claude stops a chat."), "the line says what would switch: \(h.seen)")
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.resumes("local_one") == 1, "a stop seen now switches, resume once: \(h.seen)")
    },
]
