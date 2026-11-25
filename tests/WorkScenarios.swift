import Foundation

// A chat whose own turn had ended while its background subagents kept working, at a switch's quit
// (the first automatic switch of 0.4.0, 2026-11-24 22:36). Claude records such a chat in its
// session record as it quits (`armedWorkAtQuit` with a `backgroundTaskCount`), not in its log: no
// turn was in flight, so no `reason=app_quit` line is written. The chat gets one "resume"; a chat
// idle with no work in flight gets nothing, even one still marked from an earlier quit. A chat
// counts as resumed only once Stop shows in it, never because its record's last-activity time
// moved, and the chats a resume gives up on are named.

private let idle = ChatScreen(busy: false, composer: true, draft: false)

let workScenarios: [Scenario] = [
    Scenario(pair: "(Automatic switch, another chat's turn had ended with its subagents still working)",
             model: "every chat Claude's record shows working at the quit gets one \"resume\"; an idle chat with no work in flight, even one marked from an earlier quit, gets none") { h in
        await h.standard()
        h.claude.addChat("local_agents", in: A, lastActivity: h.now.addingTimeInterval(-120), title: "Agents")
        h.claude.screens["local_agents"] = idle
        h.claude.addChat("local_idle", in: A, lastActivity: h.now.addingTimeInterval(-60), title: "Idle")
        // Its work died at an earlier quit, and nobody has sent it anything since.
        h.claude.editChat("local_idle", in: A) { $0["lostWorkUntold"] = true }
        h.claude.screens["local_idle"] = idle
        h.claude.backgroundTasksOnQuit = ["local_agents": 7]
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && !h.claude.notifications.isEmpty }, limit: 15 * 60)
        h.check(h.claude.held == B && h.claude.chats(in: B).isSuperset(of: ["local_one", "local_agents", "local_idle"]),
                "setup: the automatic switch moved all three chats to Beta: \(h.seen)")
        h.check(h.resumes("local_one") == 1, "the chat stopped for the limit got one \"resume\": \(h.claude.sent)")
        h.check(h.resumes("local_agents") == 1, "the chat whose subagents were still working got one \"resume\": \(h.claude.sent)")
        h.check(!h.resumed("local_idle"), "the idle chat got nothing: \(h.claude.sent)")
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. 2 chats resumed."], "posted: \(h.claude.notifications)")
        await h.pass(ClaudeTiming.resumeFor)
        h.check(h.claude.sent.count == 2, "and nothing more is typed for the rest of the resume's half hour: \(h.claude.sent)")
    },

    Scenario(pair: "(Automatic switch, the stopped chat ran subagents and Claude moves its last activity at the relaunch)",
             model: "the incident of 2026-11-24: a last-activity time that moved without a turn is not a resume; the chat gets one \"resume\" and counts once Stop shows") { h in
        await h.standard()
        h.claude.backgroundTasksOnQuit = ["local_one": 7]
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B }, limit: 10 * 60)
        // Claude writes to the chat's record after it reopens without running a turn in it.
        h.claude.touchActivity("local_one", in: B)
        await h.run(until: { !h.claude.notifications.isEmpty }, limit: 10 * 60)
        h.check(h.resumes("local_one") == 1, "the chat got one \"resume\" though its last-activity time moved: \(h.claude.sent)")
        h.check(h.claude.screens["local_one"]?.busy == true, "and is running: Stop shows")
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. 1 chat resumed."], "posted: \(h.claude.notifications)")
    },

    Scenario(pair: "(Automatic switch, a stopped chat that never shows and whose last activity moves)",
             model: "not counted as resumed; after the half hour the notice counts it and names it on hover, and the notification names it") { h in
        await h.standard(onScreen: false)
        h.claude.editChat("local_one", in: A) { $0[ClaudeFiles.title] = "Fix the importer" }
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B }, limit: 10 * 60)
        h.claude.touchActivity("local_one", in: B)
        let lines = Lines()
        await h.run(until: { lines.note(h); return !h.claude.notifications.isEmpty }, limit: ClaudeTiming.settle + 35 * 60)
        let named = "Couldn't resume \u{201C}Fix the importer\u{201D}: send it a message."
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. \(named)"], "the notification names the chat: \(h.claude.notifications)")
        h.check(lines.has("Couldn't resume 1 chat: send it a message.") && lines.has(named),
                "the menu's line counts it and its sentence on hover names it: \(lines.seen)")
        h.check(h.claude.sent.isEmpty, "nothing was typed into a chat Claude never showed: \(h.claude.sent)")
    },

    Scenario(pair: "(Switch by hand, a chat whose turn had ended with its subagents still working)",
             model: "no chat stopped and no turn cut off: the chat Claude's record shows working at the quit gets one \"resume\"; an idle one gets none") { h in
        await h.standard()
        h.claude.addChat("local_agents", in: A, lastActivity: h.now, title: "Agents")
        h.claude.screens["local_agents"] = idle
        h.claude.backgroundTasksOnQuit = ["local_agents": 3]
        await h.pass(ClaudeTiming.settle)
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_agents") }, limit: 10 * 60)
        h.check(h.claude.held == B && h.resumes("local_agents") == 1, "the working chat got one \"resume\" on Beta: \(h.seen), typed \(h.claude.sent)")
        h.check(!h.resumed("local_one"), "the idle chat got nothing: \(h.claude.sent)")
    },

    Scenario(pair: "(Switch by hand with Claude closed, a chat marked working at a quit the person made)",
             model: "only a quit this switch made counts: a mark left by an earlier quit types nothing") { h in
        await h.standard()
        h.claude.backgroundTasksOnQuit = ["local_one": 2]
        h.claude.stop()
        await h.tick(); await h.settle()
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 10 * 60)
        await h.pass(ClaudeTiming.settle + ResumeRule.readyWait)
        h.check(h.claude.held == B, "setup: the switch landed on Beta: \(h.seen)")
        h.check(h.claude.sent.isEmpty, "nothing typed: \(h.claude.sent)")
    },
]
