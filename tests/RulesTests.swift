// Tests for app/Rules.swift: the auto-switch rule, reading Claude's log, the quit watch,
// organization matching and the resume step. Run with ./test.sh; it needs only swiftc, like the app.

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
        claudeLog()
        quitWatch()
        organizations()
        resume()
        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks failed.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Auto-switch

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func row(_ id: String, _ fiveHour: Double?, _ weekly: Double?, readMinutesAgo: Double = 1,
                    needsSignIn: Bool = false, saved: Bool = true, outUntil: Date? = nil) -> SwitchCandidate {
        SwitchCandidate(id: id, name: id, fiveHour: fiveHour, weekly: weekly,
                        readAt: now.addingTimeInterval(-readMinutesAgo * 60), needsSignIn: needsSignIn, hasSavedLogin: saved,
                        outUntil: outUntil)
    }

    static func decide(_ current: SwitchCandidate?, _ others: [SwitchCandidate], stopped: Bool = true, enabled: Bool = true,
                       running: Bool = true, lastAttemptMinutesAgo: Double? = nil) -> AutoSwitchRule.Decision {
        AutoSwitchRule.decide(current: current, others: others, enabled: enabled, limitStopped: stopped, claudeRunning: running,
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
        let busy = row("busy", 40, 70)
        let roomy = row("roomy", 5, 20)
        let work = row("work", 30, 10)

        // The one trigger is Claude stopping a chat for usage; the meters never start a switch.
        check(AutoSwitchRule.onByDefault, "auto-switch is on without touching anything")
        check(picked(decide(busy, [busy, roomy, work])) == "roomy", "Claude stopped a chat: switch to the most room")
        check(picked(decide(busy, [roomy], stopped: false)) == nil, "no stop in Claude's log, no switch")
        check(picked(decide(row("busy", 100, 100), [roomy], stopped: false)) == nil, "both meters at 100 with no stop: no switch")
        check(picked(decide(row("busy", 103, 40), [roomy], stopped: false)) == nil, "a meter over 100 with no stop: no switch")
        check(picked(decide(row("busy", 2, 3), [roomy])) == "roomy", "a stop switches whatever the meters of the account in use read")
        check(picked(decide(busy, [roomy], enabled: false)) == nil, "off never switches")
        check(picked(decide(busy, [roomy], running: false)) == nil, "no switch while Claude isn't running")
        check(picked(decide(nil, [roomy])) == nil, "no switch when Claude's account is unknown")
        check(picked(decide(busy, [busy, busy])) == nil, "never switches to the account in use")

        // Every other account is out too: stay, and say so.
        let allOut = decide(busy, [busy, row("a", 0, 100), row("b", 100, 0)])
        check(picked(allOut) == nil && nowhere(allOut), "every other account out: no switch, and a notice")
        check(!nowhere(decide(busy, [row("a", 0, 100)], stopped: false)), "no notice before Claude stops a chat")

        // Out is decided on the unrounded meter.
        check(picked(decide(busy, [row("a", 0, 100), work])) == "work", "never to an account that is out")
        check(picked(decide(busy, [row("a", 10, 99.6)])) == "a", "99.6 percent, which shows as 100, still has room")
        check(picked(decide(busy, [row("a", 10, 100.0)])) == nil, "exactly 100 percent is out")
        check(AutoSwitchRule.percent(99.6) == "99%", "a reason never shows an account short of its limit as 100 percent")

        check(picked(decide(busy, [row("a", 0, 0, needsSignIn: true), work])) == "work", "skips a login at its deadline")
        check(picked(decide(busy, [row("a", 0, 0, saved: false), work])) == "work", "skips an account that isn't set up")
        check(picked(decide(busy, [row("a", 0, 0, readMinutesAgo: 20), work])) == "work", "skips a stale reading")
        check(nowhere(decide(busy, [row("a", 0, 0, readMinutesAgo: 20)])), "only stale targets: a notice, no switch")
        check(picked(decide(row("busy", 40, 70, readMinutesAgo: 600), [work])) == "work",
              "a stale reading of the account in use doesn't hold back a stop")
        check(picked(decide(busy, [row("a", nil, nil), row("b", 1, 1)])) == "a", "a window not started yet counts as nothing used")
        let never = SwitchCandidate(id: "x", name: "x", fiveHour: nil, weekly: nil, readAt: nil, needsSignIn: false, hasSavedLogin: true)
        check(picked(decide(busy, [never])) == nil, "an account never read is not a target")

        check(picked(decide(busy, [row("b", 20, 20), row("a", 20, 5)])) == "a", "a tie goes to less weekly use")
        check(picked(decide(busy, [row("b", 20, 20), row("a", 20, 20)])) == "a", "then to the name")

        check(picked(decide(busy, [roomy], lastAttemptMinutesAgo: 5)) == nil, "no second try inside the cool-down")
        check(picked(decide(busy, [roomy], lastAttemptMinutesAgo: 11)) == "roomy", "tries again after the cool-down")

        // No flap: the account a switch left counts as out until its reset, whatever its meters read.
        let leftAt = now.addingTimeInterval(-60)
        var left = row("left", 40, 97)
        left.fiveHourResetsAt = now.addingTimeInterval(2 * 3600)
        left.weeklyResetsAt = now.addingTimeInterval(3 * 86400)
        let until = AutoSwitchRule.outUntil(leaving: left, now: leftAt)
        check(until == left.weeklyResetsAt, "the account left is out until its fuller meter resets")
        check(picked(decide(row("roomy", 10, 10), [row("left", 40, 60, outUntil: until)])) == nil,
              "never switches back to the account it left, though its meter shows room")
        check(picked(decide(row("roomy", 10, 10), [row("left", 40, 60, outUntil: now.addingTimeInterval(-1))])) == "left",
              "after its reset it is a target again")
        var fiveHourFull = row("left", 99, 30)
        fiveHourFull.fiveHourResetsAt = now.addingTimeInterval(3600)
        fiveHourFull.weeklyResetsAt = now.addingTimeInterval(86400)
        check(AutoSwitchRule.outUntil(leaving: fiveHourFull, now: now) == fiveHourFull.fiveHourResetsAt,
              "a full 5-hour meter means out until the 5-hour reset")
        check(AutoSwitchRule.outUntil(leaving: row("left", 10, 10), now: now) == now.addingTimeInterval(AutoSwitchRule.outWithoutReset),
              "with no reset ahead, out for the configured fallback")
        check(AutoSwitchRule.outWithoutReset == 5 * 3600 && AutoSwitchRule.coolDown == 10 * 60 && AutoSwitchRule.freshness == 15 * 60,
              "the fallback is 5 hours, the cool-down 10 minutes, a reading fresh for 15 minutes")
    }

    // MARK: Claude's log

    static let accountA = "aaaaaaaa-0000-4000-8000-000000000001"
    static let accountB = "bbbbbbbb-0000-4000-8000-000000000002"
    static let orgA = "cccccccc-0000-4000-8000-000000000003"

    static func signIn(_ account: String, _ org: String) -> String {
        "2026-01-01 09:59:00 [info] [LocalSessionManager] Initialization succeeded accountId=\(account) orgId=\(org)"
    }

    static func stopped(_ id: String, _ message: String = "You've hit your weekly limit \u{00B7} resets 8pm") -> String {
        "2026-01-01 10:01:00 [warn] [CCD CycleHealth] \(id) api_error (success): \(message)"
    }

    static func follow(_ lines: [String]) -> LogFollower {
        var f = LogFollower()
        f.read(lines.joined(separator: "\n"))
        return f
    }

    static func claudeLog() {
        let start = "2026-01-01 09:58:00 [info] Starting app {"
        let a = Identity(account: accountA, org: orgA)

        // A stop logged for the account in use is the trigger.
        let inUse = follow([start, signIn(accountA, orgA), stopped("local_aaa-1")])
        check(inUse.identity == a && inUse.stoppedByLimit == ["local_aaa-1"], "a limit line for the account in use is a stop")

        // Only stops that belong to the account Claude named above them count.
        check(follow([start, stopped("local_aaa-1"), signIn(accountA, orgA)]).stoppedByLimit.isEmpty,
              "a limit line from before the account was confirmed is not a stop")
        let moved = follow([start, signIn(accountB, orgA), stopped("local_bbb-1"), signIn(accountA, orgA)])
        check(moved.identity == a && moved.stoppedByLimit.isEmpty, "a limit line for another account is not a stop")
        check(follow([start, signIn(accountA, orgA), stopped("local_aaa-1"), start]).stoppedByLimit.isEmpty,
              "a new run of Claude starts over")
        check(follow([start, signIn(accountA, orgA), stopped("local_aaa-1"), signIn(accountA, orgA)]).stoppedByLimit == ["local_aaa-1"],
              "Claude naming the same account again keeps its stops")

        // Which lines are a stop for usage.
        let mixed = follow([
            start, signIn(accountA, orgA),
            stopped("local_aaa-1"),
            "2026-01-01 10:01:00 [info] [CCD CycleHealth] unhealthy cycle for local_aaa-1 (0s, hadFirstResponse=true, reason=api_error)",
            stopped("local_bbb-2", "You've hit your 5-hour limit \u{00B7} resets 3pm"),
            "2026-01-01 10:03:00 [info] [CCD CycleHealth] healthy cycle for local_bbb-2 (12s, hadFirstResponse=true)",
            stopped("local_ccc-3", "Overloaded"),
            stopped("local_ddd-4", "Your org is out of usage \u{00B7} contact your admin"),
        ])
        check(mixed.stoppedByLimit == ["local_aaa-1", "local_ddd-4"],
              "a usage stop counts, one that ran fine since doesn't, another API error doesn't, Claude's other out-of-usage messages do")
        check(mixed.cutByQuit.isEmpty, "a usage stop is not a turn cut off by the quit")

        // The turns still running when Claude quit.
        let quit = follow([
            start, signIn(accountA, orgA),
            stopped("local_aaa-1"),
            "2026-01-01 10:09:00 [info] [CCD CycleHealth] unhealthy cycle for local_run-1 (40s, hadFirstResponse=true, reason=app_quit)",
            "2026-01-01 10:09:00 [info] [CCD CycleHealth] unhealthy cycle for local_net-2 (3s, hadFirstResponse=false, reason=no_response)",
        ])
        check(quit.cutByQuit == ["local_run-1"] && quit.stoppedByLimit == ["local_aaa-1"],
              "a turn closed by the quit is cut off; another failure is not")
        check(LogFollower.identity(after: [start, signIn(accountA, orgA), "Navigated to /logout"].joined(separator: "\n"), from: nil) == nil,
              "a sign-out clears who Claude is")
    }

    // MARK: Quit watch

    static func at(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }

    static func quitWatch() {
        let gone = QuitObservation(claudeRunning: false, promptOpen: false)
        let quiet = QuitObservation(claudeRunning: true, promptOpen: false)
        let prompt = QuitObservation(claudeRunning: true, promptOpen: true)

        var w = QuitWatch(unattended: false, canAnswer: false, started: now)
        check(w.step(gone, now: at(1)) == .done(.quit), "Claude gone means it quit")

        // Claude's log is silent and nobody answers the prompt for a long time.
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
        let outPersonal = row("a", 10, 60)
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
            MovedChat(id: "limit", title: "limit", interrupted: false, lastActivity: 7),
            MovedChat(id: "new", title: "new", interrupted: true, lastActivity: 5),
            MovedChat(id: "limit", title: "limit", interrupted: false, lastActivity: 7),
        ]
        let wanted = ResumeRule.toResume(chats, stoppedByLimit: ["limit", "gone"], cutByQuit: [])
        check(wanted.map(\.id) == ["limit", "new", "old"],
              "chats a quit cut off or a limit stopped, each once, most recent first; an idle chat is left alone")
        check(ResumeRule.toResume(chats, stoppedByLimit: [], cutByQuit: []).map(\.id) == ["new", "old"],
              "with no stop in the log, only the chats Claude marked")
        let working = [
            MovedChat(id: "limit", title: "limit", interrupted: false, lastActivity: 4),
            MovedChat(id: "running", title: "running", interrupted: false, lastActivity: 3),
            MovedChat(id: "marked", title: "marked", interrupted: true, lastActivity: 2),
            MovedChat(id: "idle", title: "idle", interrupted: false, lastActivity: 9),
        ]
        check(ResumeRule.toResume(working, stoppedByLimit: ["limit"], cutByQuit: ["running"]).map(\.id) == ["limit", "running", "marked"],
              "the chats that were working are exactly the ones stopped for usage plus the ones the quit cut off")
        check(ResumeRule.message == "resume", "the message is \"resume\"")
        check(ResumeRule.resumed(markStillSet: false, lastActivity: 0, reopenedAt: 100), "a cleared mark means it resumed")
        check(!ResumeRule.resumed(markStillSet: true, lastActivity: 50, reopenedAt: 100), "a mark and no activity means it waits")
        check(ResumeRule.resumed(markStillSet: true, lastActivity: 150, reopenedAt: 100), "activity after the reopen means it resumed")

        // One opened chat, step by step.
        let idle = ChatScreen(busy: false, composer: true, draft: false)
        func step(_ s: ChatScreen?, interrupted: Bool = false, waited: TimeInterval = 1, shownFor: TimeInterval? = 1) -> ResumeRule.Step {
            ResumeRule.step(s, interrupted: interrupted, waited: waited, shownFor: shownFor)
        }
        check(step(idle) == .send, "an idle chat with an empty message box gets the message")
        check(step(ChatScreen(busy: true, composer: true, draft: false)) == .done(.running), "a running chat is never sent to")
        check(step(ChatScreen(busy: false, composer: true, draft: true)) == .done(.notResumed("it has an unsent draft")),
              "a chat with someone's unsent text is never sent to")
        check(step(nil, waited: 5, shownFor: nil) == .wait, "it waits for Claude to show the chat")
        check(step(nil, waited: ResumeRule.showWait, shownFor: nil) == .done(.notResumed("Claude didn't show it")),
              "a chat Claude never shows is reported, not sent to")
        check(step(ChatScreen(busy: false, composer: false, draft: false), waited: 5) == .wait, "it waits for the message box to load")
        check(step(ChatScreen(busy: false, composer: false, draft: false), waited: ResumeRule.showWait)
              == .done(.notResumed("its message box wasn't found")), "a chat without a message box and send control is reported")
        check(step(idle, interrupted: true, shownFor: 2) == .wait, "a chat a quit cut off gets time to resume by itself on open")
        check(step(idle, interrupted: true, shownFor: ResumeRule.resumeOnOpenWait) == .send, "then it gets the message")
        check(ResumeRule.showWait == 20 && ResumeRule.resumeOnOpenWait == 10 && ResumeRule.startWait == 30 && ResumeRule.ownPassWait == 45,
              "the waits are 20 s to show, 10 s for Claude's own resume on open, 30 s for the turn to start, 45 s for Claude's launch pass")
    }
}
