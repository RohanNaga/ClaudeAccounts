// Tests for app/Rules.swift: the auto-switch rule, the quit watch, organization matching and the
// resume step. Run with ./test.sh; it needs only swiftc, like the app.

import Foundation

@main
struct RulesTests {
    static var failures = 0
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
        count += 1
        if !condition() {
            failures += 1
            print("FAIL line \(line): \(what)")
        }
    }

    static func main() {
        autoSwitch()
        limitLog()
        quitWatch()
        organizations()
        resume()
        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks failed.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Auto-switch

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ id: String, _ fiveHour: Int?, _ weekly: Int?, readMinutesAgo: Double = 1,
                    needsSignIn: Bool = false, saved: Bool = true) -> SwitchCandidate {
        SwitchCandidate(id: id, name: id, fiveHour: fiveHour, weekly: weekly,
                        readAt: now.addingTimeInterval(-readMinutesAgo * 60), needsSignIn: needsSignIn, hasSavedLogin: saved)
    }

    static func decide(_ current: SwitchCandidate?, _ others: [SwitchCandidate], enabled: Bool = true,
                       running: Bool = true, lastAttemptMinutesAgo: Double? = nil) -> AutoSwitchRule.Decision {
        AutoSwitchRule.decide(current: current, others: others, enabled: enabled, claudeRunning: running,
                              lastAttempt: lastAttemptMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, now: now)
    }

    static func nowhere(_ d: AutoSwitchRule.Decision) -> Bool {
        if case .nowhere = d { return true }
        return false
    }

    static func picked(_ d: AutoSwitchRule.Decision) -> String? {
        if case .switchTo(let id, _) = d { return id }
        return nil
    }

    static func autoSwitch() {
        let out = row("out", 40, 100)
        let roomy = row("roomy", 5, 20)
        let work = row("work", 30, 10)

        // The default: switch once the account in use is out, not before.
        check(AutoSwitchRule.onByDefault, "auto-switch is on without touching anything")
        check(picked(decide(row("busy", 40, 99), [roomy])) == nil, "at 99 percent, no switch")
        check(picked(decide(row("busy", 99, 99), [roomy])) == nil, "99 on both meters is still not out")
        check(picked(decide(out, [out, roomy, work])) == "roomy", "at the weekly limit, switch to the most room")
        check(picked(decide(row("busy", 100, 10), [work])) == "work", "the 5-hour limit alone also switches")
        check(picked(decide(row("busy", 103, 10), [work])) == "work", "a reading over 100 counts as out")
        check(picked(decide(out, [out, roomy], enabled: false)) == nil, "off never switches")
        check(picked(decide(out, [roomy], running: false)) == nil, "no switch while Claude isn't running")
        check(picked(decide(nil, [roomy])) == nil, "no switch when Claude's account is unknown")
        check(picked(decide(out, [out, out])) == nil, "never switches to the account in use")

        // Every other account is out too: stay, and say so.
        let allOut = decide(out, [out, row("a", 0, 100), row("b", 100, 0)])
        check(picked(allOut) == nil && nowhere(allOut), "every other account out: no switch, and a notice")
        check(!nowhere(decide(row("busy", 40, 99), [row("a", 0, 100)])), "no notice before the account in use is out")

        check(picked(decide(out, [row("a", 0, 100), work])) == "work", "never to an account that is out")
        check(picked(decide(out, [row("a", 10, 99)])) == "a", "an account just under its limit still has room")
        check(picked(decide(out, [row("a", 0, 0, needsSignIn: true), work])) == "work", "skips a login at its deadline")
        check(picked(decide(out, [row("a", 0, 0, saved: false), work])) == "work", "skips an account that isn't set up")
        check(picked(decide(out, [row("a", 0, 0, readMinutesAgo: 20), work])) == "work", "skips a stale reading")
        check(nowhere(decide(out, [row("a", 0, 0, readMinutesAgo: 20)])), "only stale targets: a notice, no switch")
        check(picked(decide(row("busy", 40, 100, readMinutesAgo: 20), [work])) == nil, "a stale reading never starts a switch")
        check(picked(decide(out, [row("a", nil, nil), row("b", 1, 1)])) == "a", "a window not started yet counts as nothing used")
        let never = SwitchCandidate(id: "x", name: "x", fiveHour: nil, weekly: nil, readAt: nil, needsSignIn: false, hasSavedLogin: true)
        check(picked(decide(out, [never])) == nil, "an account never read is not a target")

        check(picked(decide(out, [row("b", 20, 20), row("a", 20, 5)])) == "a", "a tie goes to less weekly use")
        check(picked(decide(out, [row("b", 20, 20), row("a", 20, 20)])) == "a", "then to the name")

        check(picked(decide(out, [roomy], lastAttemptMinutesAgo: 5)) == nil, "no second try inside the cool-down")
        check(picked(decide(out, [roomy], lastAttemptMinutesAgo: 11)) == "roomy", "tries again after the cool-down")
        // No flapping: right after a switch, the account left behind is out, so it is never picked.
        check(picked(decide(row("roomy", 100, 20), [row("out", 40, 100)], lastAttemptMinutesAgo: 60)) == nil,
              "never switches back to the account it left")
    }

    // MARK: Limit log

    static func limitLog() {
        let log = """
        2026-01-01 10:00:00 [info] Starting app {
        2026-01-01 10:01:00 [warn] [CCD CycleHealth] local_aaa-1 api_error (success): You've hit your weekly limit · resets 8pm
        2026-01-01 10:01:00 [info] [CCD CycleHealth] unhealthy cycle for local_aaa-1 (0s, hadFirstResponse=true, reason=api_error)
        2026-01-01 10:02:00 [warn] [CCD CycleHealth] local_bbb-2 api_error (success): You've hit your 5-hour limit · resets 3pm
        2026-01-01 10:03:00 [info] [CCD CycleHealth] healthy cycle for local_bbb-2 (12s, hadFirstResponse=true)
        2026-01-01 10:04:00 [warn] [CCD CycleHealth] local_ccc-3 api_error (success): Overloaded
        2026-01-01 10:05:00 [info] [CCD CycleHealth] healthy cycle for local_ddd-4 (3s, hadFirstResponse=true)
        """
        let stopped = LimitLog.stoppedSessions(in: log)
        check(stopped.contains("local_aaa-1"), "a chat whose last turn hit the limit is listed")
        check(!stopped.contains("local_bbb-2"), "a chat that ran fine after its limit is not")
        check(!stopped.contains("local_ccc-3"), "another API error is not a limit")
        check(stopped.count == 1, "nothing else is listed")
    }

    // MARK: Quit watch

    static func at(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }

    static func quitWatch() {
        let gone = QuitObservation(claudeRunning: false, promptOpen: false)
        let quiet = QuitObservation(claudeRunning: true, promptOpen: false)
        let prompt = QuitObservation(claudeRunning: true, promptOpen: true)

        var w = QuitWatch(unattended: false, canAnswer: false, started: now)
        check(w.step(gone, now: at(1)) == .done(.quit), "Claude gone means it quit")

        // The failure seen on a real Mac: Claude's log was silent and nobody answered for minutes.
        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        var gaveUp = false
        for t in stride(from: 1.0, through: 3600, by: 30) where w.step(prompt, now: at(t)) != .wait("Claude is asking whether to quit while a chat runs…") {
            gaveUp = true
        }
        check(!gaveUp, "never gives up while the prompt is open, even for an hour with a silent log")
        check(w.step(gone, now: at(3700)) == .done(.quit), "a late Quit anyway still completes the switch")

        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        _ = w.step(prompt, now: at(1))
        check(w.step(quiet, now: at(2)) == .wait("Waiting for Claude to quit…"), "silent log: a closed prompt is not read as Cancel at once")
        check(w.step(quiet, now: at(2 + 599)) != .done(.declined), "silent log: waits for a late quit")
        check(w.step(quiet, now: at(2 + 601)) == .done(.declined), "silent log: gives up only after the undecided wait")

        var cancelled = quiet
        cancelled.vetoLogged = true
        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        _ = w.step(prompt, now: at(1))
        check(w.step(cancelled, now: at(2)) != .done(.declined), "a working log gets a moment before Cancel is final")
        check(w.step(cancelled, now: at(6)) == .done(.declined), "veto, prompt closed, no new quit: Cancel")

        var waiting = cancelled
        waiting.waitLogged = true
        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        _ = w.step(prompt, now: at(1))
        check(w.step(waiting, now: at(7200)) == .wait("Claude quits once its chats finish…"), "Wait for Claude is followed to the end")

        var quitting = cancelled
        quitting.quitLoggedAfterVeto = true
        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        _ = w.step(prompt, now: at(1))
        check(w.step(quitting, now: at(30)) == .wait("Claude is quitting…"), "a person's Quit anyway is followed")

        w = QuitWatch(unattended: true, canAnswer: true, started: now)
        check(w.step(prompt, now: at(1)) == .answer, "unattended with Accessibility answers the prompt")
        w.answered(at: at(1))
        check(w.step(prompt, now: at(2)) == .answer, "a prompt still open after a press is pressed again")
        check(w.step(quiet, now: at(3)) == .wait("Claude is quitting…"), "once it closes, waits for the quit")
        check(w.step(gone, now: at(20)) == .done(.quit), "and sees Claude go")
        w = QuitWatch(unattended: true, canAnswer: true, started: now)
        _ = w.step(prompt, now: at(1))
        w.answered(at: at(1))
        check(w.step(quiet, now: at(1 + 181)) == .done(.failed), "a quit that never lands after Quit anyway fails")

        w = QuitWatch(unattended: true, canAnswer: false, started: now)
        check(w.step(prompt, now: at(1)) == .wait("Claude is asking whether to quit while a chat runs…"),
              "unattended without Accessibility waits for a person instead of guessing")

        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        check(w.step(quiet, now: at(30)) == .wait("Waiting for Claude to quit…"), "no prompt yet: waits")
        check(w.step(quiet, now: at(91)) == .done(.failed), "no prompt and no quit: Claude ignored the request")
        var vetoOnly = quiet
        vetoOnly.vetoLogged = true
        w = QuitWatch(unattended: false, canAnswer: false, started: now)
        check(w.step(vetoOnly, now: at(91)) == .done(.declined), "a veto whose prompt never shows ends as declined")
    }

    // MARK: Organizations

    static func record(_ id: String, account: String?, org: String?, name: String? = nil, orgName: String? = nil) -> AccountRecord {
        AccountRecord(id: id, name: name ?? id, color: "#000000", configDir: "~/x", keychainService: "k", email: nil,
                      accountUuid: account, orgName: orgName, orgUuid: org)
    }

    static func organizations() {
        let personal = record("a", account: "acct", org: "org-a")
        let team = record("b", account: "acct", org: "org-b")
        let other = record("c", account: "other", org: nil)
        let rows = [personal, other, team]
        check(rows.row(for: Identity(account: "acct", org: "org-b"))?.id == "b", "each organization of one account has its own row")
        check(rows.row(for: Identity(account: "acct", org: "org-a"))?.id == "a", "and the other organization finds its row")
        check(rows.row(for: Identity(account: "acct", org: "org-z")) == nil, "an organization not added matches no row")
        check(rows.row(for: Identity(account: "other", org: "any"))?.id == "c", "a row saved before organizations still matches")
        check(rows.row(for: nil) == nil, "no identity, no row")
        check(rows.otherOrganizations(of: personal).map(\.id) == ["b"], "the other organization of an account")

        // The menu: one entry per account, its organizations beneath, in first-seen order.
        check(rows.groupedByAccount().map { $0.map(\.id) } == [["a", "b"], ["c"]], "organizations group under their account")
        check([record("x", account: nil, org: nil), record("y", account: nil, org: nil)].groupedByAccount().count == 2,
              "rows without an account id stand alone")

        // Adding the other organization: the one Claude has opened that no row stands for, most used first.
        let opened = [(org: "org-a", chats: 50), (org: "org-c", chats: 2), (org: "org-b", chats: 9)]
        check([personal].organizationsToAdd(account: "acct", opened: opened) == ["org-b", "org-c"],
              "offers the organizations not added yet, most used first")
        check(rows.organizationsToAdd(account: "acct", opened: opened) == ["org-c"], "never one already added")
        check(rows.organizationsToAdd(account: "acct", opened: []).isEmpty, "nothing known when Claude opened no other")
        check(rowName(email: "me@example.com", orgName: "Team", accountAlreadyAdded: true, fallback: "x") == "me@example.com · Team",
              "a second organization's row names its organization")
        check(rowName(email: "me@example.com", orgName: "Team", accountAlreadyAdded: false, fallback: "x") == "me@example.com",
              "a first row is just the email")

        // Auto-switch treats each account-and-organization pair as its own target.
        let outPersonal = row("a", 10, 100)
        check(picked(decide(outPersonal, [outPersonal, row("b", 30, 40), row("c", 60, 60)])) == "b",
              "the account's other organization is a target, by the same most-room rule")
        check(picked(decide(outPersonal, [outPersonal, row("b", 30, 40), row("c", 5, 5)])) == "c",
              "and loses to another account with more room")
        check(picked(decide(outPersonal, [outPersonal, row("b", 0, 100), row("c", 60, 60)])) == "c",
              "the other organization is skipped when it is out too")

        let old = ##"{"accounts":[{"id":"x","name":"n","color":"#fff","configDir":"~/d","keychainService":"s","email":null,"accountUuid":"u","orgName":"Org"}]}"##
        struct File: Decodable { var accounts: [AccountRecord] }
        let decoded = try? JSONDecoder().decode(File.self, from: Data(old.utf8))
        check(decoded?.accounts.first?.orgUuid == nil && decoded?.accounts.first?.accountUuid == "u",
              "an accounts file from before organizations still loads")
    }

    // MARK: Resume

    static func resume() {
        let chats = [
            MovedChat(id: "old", title: "old", interrupted: true, lastActivity: 1),
            MovedChat(id: "idle", title: "idle", interrupted: false, lastActivity: 9),
            MovedChat(id: "new", title: "new", interrupted: true, lastActivity: 5),
        ]
        check(ResumeRule.toResume(chats).map(\.id) == ["new", "old"], "only cut-off chats, most recent first")
        check(ResumeRule.resumed(markStillSet: false, lastActivity: 0, reopenedAt: 100), "a cleared mark means it resumed")
        check(!ResumeRule.resumed(markStillSet: true, lastActivity: 50, reopenedAt: 100), "a mark and no activity means it waits")
        check(ResumeRule.resumed(markStillSet: true, lastActivity: 150, reopenedAt: 100), "activity after the reopen means it resumed")
    }
}
