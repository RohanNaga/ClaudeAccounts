// Tests for app/Rules.swift: the auto-switch rule, the quit watch, workspace matching and the
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
        quitWatch()
        workspaces()
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

    static func decide(_ current: SwitchCandidate?, _ others: [SwitchCandidate], threshold: Int? = 90,
                       running: Bool = true, lastAttemptMinutesAgo: Double? = nil) -> AutoSwitchRule.Decision {
        AutoSwitchRule.decide(current: current, others: others, threshold: threshold, claudeRunning: running,
                              lastAttempt: lastAttemptMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }, now: now)
    }

    static func picked(_ d: AutoSwitchRule.Decision) -> String? {
        if case .switchTo(let id, _) = d { return id }
        return nil
    }

    static func autoSwitch() {
        let busy = row("busy", 40, 92)
        let roomy = row("roomy", 5, 20)
        let work = row("work", 30, 10)

        check(picked(decide(busy, [busy, roomy, work], threshold: nil)) == nil, "off never switches")
        check(picked(decide(busy, [busy, roomy], running: false)) == nil, "no switch while Claude isn't running")
        check(picked(decide(nil, [roomy])) == nil, "no switch when Claude's account is unknown")
        check(picked(decide(row("busy", 40, 70), [roomy])) == nil, "no switch under the threshold")
        check(picked(decide(busy, [busy, roomy, work])) == "roomy", "weekly past the threshold switches, to the most room")
        check(picked(decide(row("busy", 95, 10), [work])) == "work", "the 5-hour meter alone also triggers")
        check(picked(decide(row("busy", 100, 100), [roomy])) == "roomy", "an account that ran out switches")
        check(picked(decide(busy, [busy, busy])) == nil, "never switches to the account in use")

        // A target that has itself run out of its weekly limit.
        check(picked(decide(busy, [row("roomy", 0, 100)])) == nil, "never switches to an account that is out")
        check(picked(decide(busy, [row("a", 10, 91), row("b", 95, 0)])) == nil, "never to an account past the threshold")
        check(picked(decide(busy, [row("a", 10, 89)])) == "a", "just under the threshold is room")

        check(picked(decide(busy, [row("a", 0, 0, needsSignIn: true), work])) == "work", "skips a login at its deadline")
        check(picked(decide(busy, [row("a", 0, 0, saved: false), work])) == "work", "skips an account that isn't set up")
        check(picked(decide(busy, [row("a", 0, 0, readMinutesAgo: 20), work])) == "work", "skips a stale reading")
        check(picked(decide(row("busy", 40, 92, readMinutesAgo: 20), [work])) == nil, "a stale reading never starts a switch")
        check(picked(decide(busy, [row("a", nil, nil), row("b", 1, 1)])) == "a", "a window not started yet counts as nothing used")
        let never = SwitchCandidate(id: "x", name: "x", fiveHour: nil, weekly: nil, readAt: nil, needsSignIn: false, hasSavedLogin: true)
        check(picked(decide(busy, [never])) == nil, "an account never read is not a target")

        check(picked(decide(busy, [row("b", 20, 20), row("a", 20, 5)])) == "a", "a tie goes to less weekly use")
        check(picked(decide(busy, [row("b", 20, 20), row("a", 20, 20)])) == "a", "then to the name")

        check(picked(decide(busy, [roomy], lastAttemptMinutesAgo: 10)) == nil, "no second switch inside the cool-down")
        check(picked(decide(busy, [roomy], lastAttemptMinutesAgo: 31)) == "roomy", "switches again after the cool-down")
        // Flapping: just after a switch, the new account passing the threshold must not bounce back at once.
        check(picked(decide(row("roomy", 91, 20), [row("busy", 10, 10)], lastAttemptMinutesAgo: 2)) == nil,
              "no flap back inside the cool-down")
        check(AutoSwitchRule.thresholds.contains(AutoSwitchRule.defaultThreshold), "the default threshold is on the menu")
        check(AutoSwitchRule.thresholds.allSatisfy { $0 < 100 }, "every threshold switches before the limit")
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

    // MARK: Workspaces

    static func record(_ id: String, account: String?, org: String?) -> AccountRecord {
        AccountRecord(id: id, name: id, color: "#000000", configDir: "~/x", keychainService: "k", email: nil,
                      accountUuid: account, orgName: nil, orgUuid: org)
    }

    static func workspaces() {
        let teamA = record("a", account: "acct", org: "org-a")
        let teamB = record("b", account: "acct", org: "org-b")
        let other = record("c", account: "other", org: nil)
        let rows = [teamA, teamB, other]
        check(rows.row(for: Identity(account: "acct", org: "org-b"))?.id == "b", "each workspace of one account has its own row")
        check(rows.row(for: Identity(account: "acct", org: "org-a"))?.id == "a", "and the other workspace finds its row")
        check(rows.row(for: Identity(account: "acct", org: "org-z")) == nil, "an unknown workspace matches no row")
        check(rows.row(for: Identity(account: "other", org: "any"))?.id == "c", "a row saved before workspaces still matches")
        check(rows.row(for: nil) == nil, "no identity, no row")
        check(rows.otherWorkspaces(of: teamA).map(\.id) == ["b"], "the other workspace of an account")

        let old = ##"{"accounts":[{"id":"x","name":"n","color":"#fff","configDir":"~/d","keychainService":"s","email":null,"accountUuid":"u","orgName":"Org"}]}"##
        struct File: Decodable { var accounts: [AccountRecord] }
        let decoded = try? JSONDecoder().decode(File.self, from: Data(old.utf8))
        check(decoded?.accounts.first?.orgUuid == nil && decoded?.accounts.first?.accountUuid == "u",
              "an accounts file from before workspaces still loads")
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
