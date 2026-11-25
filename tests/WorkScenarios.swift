import Foundation

// A chat whose own turn had ended while its background subagents kept working, at a switch's quit
// (the first automatic switch of 0.4.0, 2026-11-24 22:36). Claude records such a chat in its
// session record as it quits (`armedWorkAtQuit` with a `backgroundTaskCount`), not in its log: no
// turn was in flight, so no `reason=app_quit` line is written. The chat gets one "resume"; a chat
// idle with no work in flight gets nothing, even one still marked from an earlier quit. A chat
// counts as resumed only once Stop shows in it, never because its record's last-activity time
// moved or Claude cleared its quit mark, and the chats a resume gives up on are named, the
// instruction first. Each resume leaves count-only lines in the diagnostics file.

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
             model: "not counted as resumed; after the half hour the notice counts it and names it on hover, and the notification says to send it a message before it names it") { h in
        await h.standard(onScreen: false)
        h.claude.editChat("local_one", in: A) { $0[ClaudeFiles.title] = "Fix the importer" }
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B }, limit: 10 * 60)
        h.claude.touchActivity("local_one", in: B)
        let lines = Lines()
        await h.run(until: { lines.note(h); return !h.claude.notifications.isEmpty }, limit: ClaudeTiming.settle + 35 * 60)
        let named = "Couldn't resume 1 chat, send it a message: \u{201C}Fix the importer\u{201D}."
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
        await h.pass(ClaudeTiming.settle)
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 10 * 60)
        await h.pass(ClaudeTiming.settle + ResumeRule.readyWait)
        h.check(h.claude.held == B, "setup: the switch landed on Beta: \(h.seen)")
        h.check(h.claude.sent.isEmpty, "nothing typed: \(h.claude.sent)")
    },

    Scenario(pair: "(Switch by hand, Claude running, a chat still marked working from a quit before the switch)",
             model: "only Claude's mark from this switch's own quit counts, by its exitKind and time, not by how Claude clears its marks; the quit's diagnostics line counts the mark it refused") { h in
        await h.standard()
        // Claude wrote this at a quit an hour ago and has not cleared it, and nothing runs in the
        // chat now. This switch's quit writes no new mark.
        let before = h.now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000
        h.claude.editChat("local_one", in: A) {
            $0[ClaudeFiles.armedWorkAtQuit] = ["at": before, "exitKind": "quit", "cronCount": 0, "durableCronCount": 0, ClaudeFiles.backgroundTaskCount: 3]
        }
        await h.pass(ClaudeTiming.settle)
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 10 * 60)
        await h.pass(ClaudeTiming.settle + ResumeRule.readyWait)
        h.check(h.claude.held == B && h.quits == 1, "setup: the hand switch quit a running Claude and landed on Beta: \(h.seen)")
        h.check(h.claude.sent.isEmpty, "the chat marked at the earlier quit got nothing: \(h.claude.sent)")
        let list = diagnostics(h, "resumeList")
        h.check(list.count == 1 && list.first.map { $0["working"] as? Int == 0 && $0["workingBefore"] as? Int == 1 } == true,
                "one line at the quit counts no working chat and the one earlier mark it refused: \(list)")
    },

    Scenario(pair: "(Automatic switch, the diagnostics file after a resume)",
             model: "one count-only line at the quit, then one line per chat saying why it was on the list and how its resume ended, with no title or id") { h in
        await h.standard()
        h.claude.editChat("local_one", in: A) { $0[ClaudeFiles.title] = "Fix the importer" }
        h.claude.addChat("local_agents", in: A, lastActivity: h.now.addingTimeInterval(-120), title: "Agents at work")
        h.claude.screens["local_agents"] = idle
        h.claude.addChat("local_gone", in: A, lastActivity: h.now.addingTimeInterval(-240), title: "Never shown")
        h.claude.backgroundTasksOnQuit = ["local_agents": 7, "local_gone": 1]
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { !h.claude.notifications.isEmpty }, limit: ClaudeTiming.settle + 40 * 60)
        h.check(h.resumes("local_one") == 1 && h.resumes("local_agents") == 1, "setup: both shown chats got one \"resume\": \(h.claude.sent)")
        let list = diagnostics(h, "resumeList")
        h.check(list.count == 1 && list.first.map { $0["byLimit"] as? Int == 1 && $0["byQuit"] as? Int == 0 && $0["working"] as? Int == 2 } == true,
                "the quit's line counts one chat stopped for the limit and two working: \(list)")
        let chats = diagnostics(h, "resumeChat").map { "\($0["why"] ?? "?") \($0["result"] ?? "?")" }.sorted()
        h.check(chats == ["limit sent", "working notResumed", "working sent"], "one line per chat with why and result: \(chats)")
        let raw = (try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? ""
        h.check(!["local_one", "local_agents", "local_gone", "Fix the importer", "Agents at work", "Never shown"].contains { raw.contains($0) },
                "no chat id or title is in the diagnostics file")
    },

    Scenario(pair: "(Automatic switch, Claude clears its quit mark on two cut-off chats without running them)",
             model: "a cleared mark is not a resume: each chat is opened, the one with an idle message box gets one \"resume\" and counts once Stop shows, and the one Claude left waiting for the person, with no message box, is named") { h in
        await h.standard()
        let quitAt = h.now.timeIntervalSince1970 * 1000
        for (id, title, ago) in [("local_parked", "Parked", -120.0), ("local_asking", "Asking", -240.0)] {
            h.claude.addChat(id, in: A, lastActivity: h.now.addingTimeInterval(ago), title: title)
            h.claude.editChat(id, in: A) { $0[ClaudeFiles.interruptedByQuitAt] = quitAt }
        }
        h.claude.screens["local_parked"] = idle
        h.claude.screens["local_asking"] = ChatScreen(busy: false, composer: false, draft: false)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        // Once the first chat has its "resume", Claude parks the other two: it clears their quit
        // mark and leaves them waiting for the person, with no turn running.
        await h.run(until: { h.resumed("local_one") }, limit: 15 * 60)
        for id in ["local_parked", "local_asking"] {
            h.claude.editChat(id, in: B) { $0[ClaudeFiles.interruptedByQuitAt] = nil; $0["interruptedAwaitingPerson"] = true }
        }
        await h.run(until: { !h.claude.notifications.isEmpty }, limit: 40 * 60)
        h.check(h.resumes("local_parked") == 1 && h.claude.screens["local_parked"]?.busy == true,
                "the parked chat with an idle box got one \"resume\" and runs: \(h.claude.sent)")
        h.check(!h.resumed("local_asking"), "the chat with no message box was never typed into: \(h.claude.sent)")
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. 2 chats resumed. Couldn't resume 1 chat, send it a message: \u{201C}Asking\u{201D}."],
                "only the chats Stop showed in count, and the other is named: \(h.claude.notifications)")
    },
]

/// The diagnostics file's lines of one kind.
@MainActor private func diagnostics(_ h: Harness, _ kind: String) -> [[String: Any]] {
    ((try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .filter { $0["kind"] as? String == kind }
}
