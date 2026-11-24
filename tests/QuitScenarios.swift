import Foundation

// Claude's quit prompt as an automatic switch meets it (the fourth review's item 8 and probes E1 to
// E3). The app looks for Quit anyway at every look for as long as the prompt can be up, never takes
// a late or slow answer for a missing button, says what the person can do while it can't press,
// asks Claude to quit once, and after a failed quit leaves the hold alone. Each scenario asserts the
// line, the notifications, the quit requests, and that a switch by hand works at once afterwards.

@MainActor extension Harness {
    /// Claude stops the chat on Alpha, which reads 100: the automatic switch asks Claude to quit.
    /// The time of that request.
    func autoQuitAsked() async -> Date? {
        claude.logLimitStop("local_one", seatReadsFull: true)
        await run(until: { !claude.at("quit").isEmpty }, limit: 10 * 60)
        guard let asked = claude.at("quit").first else { check(false, "setup: the automatic switch asked Claude to quit: \(seen)"); return nil }
        return asked
    }

    /// Claude stops the chat every 10 minutes for `minutes`: nothing asks it to quit again.
    func stopsAgain(for minutes: Int) async {
        for _ in 0..<(minutes / 10) {
            claude.logLimitStop("local_one", seatReadsFull: true)
            await pass(10 * 60)
        }
    }

    /// The person clicks Switch on `row` and answers Claude's prompt: the switch starts at once and lands.
    func handSwitchWorks(_ row: String, _ seat: StandSeat) async {
        let quits = quits, clicked = now
        claude.quitBehaviour = .promptThenQuit
        click(row)
        await run(until: { claude.held == seat && state(row) == .inUse && !switchInFlight }, limit: 10 * 60)
        check(claude.at("quit").last.map { $0.timeIntervalSince(clicked) < 5 } ?? false, "the switch by hand to \(row) starts at once: \(seen)")
        check(claude.held == seat && state(row) == .inUse && self.quits == quits + 1, "and lands on \(row): \(seen)")
    }
}

/// The notice's line and its sentence on hover after an automatic switch to Beta failed to quit Claude.
private func failedQuit(_ why: String) -> [String] {
    ["Didn't switch to Beta. Switch by hand.", "Didn't switch to Beta: \(why) \(AutoSwitch.afterQuitFailure)"]
}

let quitScenarios: [Scenario] = [
    Scenario(pair: "(Automatic switch, Accessibility lists Claude's quit prompt 45 s after it opens)",
             model: "a prompt not listed yet is looked for again at every look, and pressed once it shows; the line says what to do meanwhile; one quit, no pause (review E1; the 10 s notification is the EM ruling of round 5)") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.promptListedAfter = 45
        guard let asked = await h.autoQuitAsked() else { return }
        await h.pass(20)
        h.check(h.notice == [QuitWatch.answerPrompt, "Switching to Beta. \(QuitWatch.answerPromptDetail)"], "while it can't press, the line says what the person can do: \(h.seen)")
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        let pressed = h.claude.at("pressed \(ClaudeUI.quitAnyway)")
        h.check(pressed.count == 1 && pressed.first.map { $0.timeIntervalSince(asked) >= 45 } ?? false, "Quit anyway pressed once, once it showed: \(h.seen)")
        h.check(h.claude.held == B && h.quits == 1 && h.resumes("local_one") == 1, "on Beta after one quit, \"resume\" typed once: \(h.seen)")
        h.check(h.claude.notifications == ["Switching to Beta: \(QuitWatch.answerPrompt)", "Switched to Beta: Alpha is out. 1 chat resumed."],
                "one notification at 10 s unpressed, then the switch's: \(h.claude.notifications)")
        h.check(ShapeMisses.load().isEmpty && !h.noticeHas(pausedLine), "no missing shape is recorded: \(h.seen)")
        await h.handSwitchWorks("Gamma", C)
    },

    Scenario(pair: "(Automatic switch, Accessibility answers slowly while Claude's quit prompt is up)",
             model: "a look that takes past the old 2 s cap, or returns nothing, is never read as a prompt without its button: the app looks again, presses once it can, and records each slow look (review item 8)") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.accessibilitySlowFor = 100
        guard let asked = await h.autoQuitAsked() else { return }
        await h.pass(30)
        h.check(h.notice.first == QuitWatch.answerPrompt, "while it can't press, the line says what the person can do: \(h.seen)")
        await h.run(until: { h.claude.held == B && !h.switchInFlight && h.resumed("local_one") }, limit: 10 * 60)
        let pressed = h.claude.at("pressed \(ClaudeUI.quitAnyway)")
        h.check(pressed.count == 1 && pressed.first.map { $0.timeIntervalSince(asked) >= 100 } ?? false, "Quit anyway pressed once Accessibility answered: \(h.seen)")
        h.check(h.claude.held == B && h.quits == 1 && h.resumes("local_one") == 1, "on Beta after one quit, \"resume\" typed once: \(h.seen)")
        h.check(h.claude.notifications == ["Switching to Beta: \(QuitWatch.answerPrompt)", "Switched to Beta: Alpha is out. 1 chat resumed."],
                "one notification at 10 s unpressed, then the switch's: \(h.claude.notifications)")
        h.check(ShapeMisses.load().isEmpty && !h.noticeHas(pausedLine), "no missing shape is recorded: \(h.seen)")
        let looks = ((try? String(contentsOf: Diagnostics.url, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { $0["kind"] as? String == "quitLook" }
        h.check(looks.contains { ($0["ms"] as? Int ?? 0) >= 2000 }, "the slow look is in the diagnostics file with its time: \(looks.map { $0["ms"] ?? "?" })")
        await h.handSwitchWorks("Gamma", C)
    },

    Scenario(pair: "(Automatic switch, Claude's quit prompt is never listed to Accessibility)",
             model: "the app can't press a prompt it can't see: the line says what to do, at 3 min it gives up saying the prompt is still open, asks no second quit, and a switch by hand works (review E2)") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.promptListedAfter = .infinity
        guard await h.autoQuitAsked() != nil else { return }
        await h.pass(60)
        h.check(h.notice == [QuitWatch.answerPrompt, "Switching to Beta. \(QuitWatch.answerPromptDetail)"], "while it waits, the line says what the person can do: \(h.seen)")
        await h.run(until: { !h.switchInFlight }, limit: 5 * 60)
        let why = "Claude didn't quit, so nothing changed. Its prompt is still open: Cancel keeps Claude as it is."
        h.check(h.notice == failedQuit(why), "the line says what didn't happen and that the prompt is still open: \(h.seen)")
        h.check(h.claude.notifications == ["Switching to Beta: \(QuitWatch.answerPrompt)", "Didn't switch to Beta: \(why) \(AutoSwitch.afterQuitFailure)"],
                "the 10 s notification, then one that says the same: \(h.claude.notifications)")
        h.check(!h.claude.actions.contains { $0.hasPrefix("pressed") } && h.claude.promptOpen, "the prompt is left to the person: \(h.seen)")
        h.check(ShapeMisses.load().isEmpty, "no missing shape is recorded for a prompt it never saw: \(ShapeMisses.load())")
        await h.stopsAgain(for: 40)
        h.check(h.quits == 1 && h.claude.notifications.count == 2 && h.claude.held == A, "no second quit, further notification or other seat in 40 min of stops: \(h.seen)")
        h.claude.personAnswers(ClaudeUI.cancel)
        await h.handSwitchWorks("Gamma", C)
    },

    Scenario(pair: "(Automatic switch, Claude shows no quit prompt and keeps running)",
             model: "a quit Claude ignores fails once at 90 s; the app never tries the next seat or asks again by itself, and a switch by hand works (review E3)") { h in
        await h.standard()
        h.claude.quitBehaviour = .ignores
        guard await h.autoQuitAsked() != nil else { return }
        await h.pass(30)
        h.check(h.notice.first == "Switching to Beta… Waiting for Claude to quit…", "while it waits, the line says so: \(h.seen)")
        await h.run(until: { !h.switchInFlight }, limit: 5 * 60)
        let why = "Claude didn't quit, so nothing changed."
        h.check(h.notice == failedQuit(why), "the line says what didn't happen and what still works: \(h.seen)")
        h.check(h.claude.notifications == ["Didn't switch to Beta: \(why) \(AutoSwitch.afterQuitFailure)"], "one notification says the same: \(h.claude.notifications)")
        await h.stopsAgain(for: 40)
        h.check(h.quits == 1 && h.claude.notifications.count == 1 && h.claude.held == A, "one quit request in 40 min, no retry to Gamma: \(h.seen)")
        h.check(h.nextRow == nil, "no seat is marked Next while it won't switch by itself: \(String(describing: h.nextRow))")
        await h.handSwitchWorks("Gamma", C)
    },
]
