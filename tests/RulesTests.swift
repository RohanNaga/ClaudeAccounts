// Tests for app/Rules.swift: the auto-switch rule, reading Claude's log, the quit watch,
// organization matching, labels, meters, settings and the resume step. Run with ./test.sh; it needs only swiftc, like the app.

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
        labels()
        upgrade()
        meters()
        settings()
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

    /// `rows` are in menu order; the row in use is put first when the list leaves it out.
    static func decide(_ current: SwitchCandidate?, _ rows: [SwitchCandidate], stopped: Bool = true, enabled: Bool = true,
                       running: Bool = true, lastAttemptMinutesAgo: Double? = nil) -> AutoSwitchRule.Decision {
        let all = current.map { c in rows.contains { $0.id == c.id } ? rows : [c] + rows } ?? rows
        return AutoSwitchRule.decide(current: current, rows: all, enabled: enabled, limitStopped: stopped, claudeRunning: running,
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
        check(picked(decide(busy, [busy, roomy, work])) == "roomy", "Claude stopped a chat: switch to the next row in the menu")
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
        check(picked(decide(busy, [row("a", nil, 30), work])) == "a", "an account without a 5-hour limit is judged on its weekly meter")
        let never = SwitchCandidate(id: "x", name: "x", fiveHour: nil, weekly: nil, readAt: nil, needsSignIn: false, hasSavedLogin: true)
        check(picked(decide(busy, [never])) == nil, "an account never read is not a target")

        // The menu's order is the switch order: down from the row in use, wrapping round to the top.
        let a = row("a", 90, 90), b = row("b", 50, 50), c = row("c", 1, 1), d = row("d", 10, 10)
        check(picked(decide(a, [a, b, c, d])) == "b", "the first row below the one in use, not the one with the most room")
        check(picked(decide(a, [a, d, c, b])) == "d", "reordering the rows changes the target")
        check(picked(decide(a, [a, row("b", 0, 100), row("c", 0, 0, saved: false), d])) == "d",
              "skips rows that are out or not set up, in order")
        check(picked(decide(b, [a, b, c, d])) == "c", "starts below the row in use, never above it while a lower row has room")
        check(picked(decide(c, [a, b, c, row("d", 100, 0)])) == "a", "wraps round to the top when every lower row is out")
        check(picked(decide(d, [a, b, c, d])) == "a", "the last row's next is the first")
        check(picked(decide(c, [c])) == nil && nowhere(decide(c, [c])), "never the row just left: alone, it stays and says so")
        let none = decide(b, [row("a", 100, 0), b, row("c", 0, 0, needsSignIn: true), row("d", 0, 0, readMinutesAgo: 30)])
        check(picked(none) == nil && nowhere(none), "no other row with room: no switch, one notice")
        check(AutoSwitchRule.next(after: a, in: [a, b, c], now: now)?.id == "b" && AutoSwitchRule.next(after: c, in: [c], now: now) == nil,
              "the row the menu marks next is the one a switch would choose")

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
        check(rows.inMenuOrder.map(\.id) == ["a", "b", "c"], "one sequence: each account's organizations in turn, then the next account")

        // Move Up and Move Down: an organization among its account's, any other row with its whole account.
        let three = [personal, team, other, record("d", account: "solo", org: "org-d")]
        check(three.moved(team, by: -1, organization: true)?.map(\.id) == ["b", "a", "c", "d"], "an organization moves up within its account")
        check(three.moved(personal, by: -1, organization: true) == nil && three.moved(team, by: 1, organization: true) == nil,
              "an organization never leaves its account")
        check(three.moved(personal, by: 1, organization: false)?.map(\.id) == ["c", "a", "b", "d"], "an account moves down past the next account")
        check(three.moved(other, by: -1, organization: false)?.map(\.id) == ["c", "a", "b", "d"], "and a one-row account moves up past it")
        check(three.moved(three[3], by: 1, organization: false) == nil && three.moved(personal, by: -1, organization: false) == nil,
              "nothing moves past either end")
        let named = [record("a", account: "acct", org: "org-a", name: "Work", orgName: "Labs"),
                     record("b", account: "acct", org: "org-b", name: "Team name", orgName: "Research")].labelled()
        let swapped = named.moved(named[1], by: -1, organization: true)
        check(swapped?.map(\.label) == ["Work · Team name", "Work · Labs"],
              "the account keeps its name whichever organization comes first, and each organization its own")

        // Adding the other organization: the one Claude has opened that no row stands for, most used first.
        let opened = [(org: "org-a", chats: 50), (org: "org-c", chats: 2), (org: "org-b", chats: 9)]
        check([personal].organizationsToAdd(account: "acct", opened: opened) == ["org-b", "org-c"],
              "offers the organizations not added yet, most used first")
        check(rows.organizationsToAdd(account: "acct", opened: opened) == ["org-c"], "never one already added")
        check(rows.organizationsToAdd(account: "acct", opened: []).isEmpty, "nothing known when Claude opened no other")

        // Auto-switch treats each account-and-organization pair as its own target.
        let outPersonal = row("a", 10, 60)
        check(picked(decide(outPersonal, [outPersonal, row("b", 30, 40), row("c", 5, 5)])) == "b",
              "the account's other organization is a target, by the same order")
        check(picked(decide(outPersonal, [outPersonal, row("c", 5, 5), row("b", 30, 40)])) == "c",
              "and another account comes first when the menu lists it first")
        check(picked(decide(outPersonal, [outPersonal, row("b", 0, 100), row("c", 60, 60)])) == "c",
              "the other organization is skipped when it is out too")

        let old = ##"{"accounts":[{"id":"x","name":"n","color":"#fff","configDir":"~/d","keychainService":"s","email":null,"accountUuid":"u","orgName":"Org"}]}"##
        struct File: Decodable { var accounts: [AccountRecord] }
        let decoded = try? JSONDecoder().decode(File.self, from: Data(old.utf8))
        check(decoded?.accounts.first?.orgUuid == nil && decoded?.accounts.first?.accountUuid == "u",
              "an accounts file from before organizations still loads")
    }

    // MARK: Labels

    static func labels() {
        func named(_ id: String, _ name: String, account: String?, orgName: String?) -> AccountRecord {
            AccountRecord(id: id, name: name, color: "#000000", configDir: "~/x", keychainService: "k", email: "me@example.com",
                          accountUuid: account, orgName: orgName, orgUuid: id)
        }
        // Names used to default to the email; on load an account gets its team's name or Account N.
        let old = [named("a", "me@example.com", account: "acct", orgName: "Northwind Labs"),
                   named("b", "me@example.com · Northwind Research", account: "acct", orgName: "Northwind Research"),
                   named("c", "you@example.com", account: "other", orgName: "you@example.com's Organization")]
        check(old.labelled().map(\.label) == ["Northwind Labs · Northwind Labs", "Northwind Labs · Northwind Research", "Account 2"],
              "an email name becomes the team's name or Account N, and each row of an account with several reads <account> · <organization>")
        let work = [named("a", "Work", account: "acct", orgName: "Northwind Labs"),
                    named("b", "me@example.com · Northwind Research", account: "acct", orgName: "Northwind Research"),
                    named("c", "Side", account: "other", orgName: "you@example.com\u{2019}s Organization")]
        check(work.labelled().map(\.label) == ["Work · Northwind Labs", "Work · Northwind Research", "Side"],
              "a name someone chose is kept, and an account with one organization is called by its name alone")
        check(work[2].organization == "Individual" && work[0].organization == "Northwind Labs",
              "Claude's name for an account's own organization shows as Individual; a team keeps its name")

        // Renaming acts on the row that was clicked.
        let org = work.labelled().renamed(work[0], to: "Labs", organization: true)
        check(org.map(\.label) == ["Work · Labs", "Work · Northwind Research", "Side"] && org.map(\.name) == ["Work", "Work", "Side"],
              "renaming an organization row names that organization and leaves the account's name alone")
        let acct = org.renamed(org[1], to: "Day job", organization: false)
        check(acct.map(\.label) == ["Day job · Labs", "Day job · Northwind Research", "Side"],
              "renaming the account renames it on every row and keeps the organizations' names")
        check(acct.renamed(acct[0], to: "", organization: true)[0].label == "Day job · Northwind Labs",
              "Reset Name gives an organization its own name back")
        check(acct.renamed(acct[0], to: " ", organization: false).map(\.label) == ["Northwind Labs · Labs", "Northwind Labs · Northwind Research", "Side"],
              "Reset Name gives an account its default name back")
        check(acct.renamed(acct[2], to: "me@example.com", organization: false)[2].label == "Account 2", "a name with an email is never kept")
        check(acct.renamed(acct[0], to: "Northwind Labs", organization: true)[0].orgLabel == nil, "naming an organization its own name saves nothing")

        // A new row: a known account keeps its name; a new one gets its team's name or Account N.
        let added = named("d", "", account: "acct", orgName: "Northwind Support")
        check((acct + [added]).accountName(for: added) == "Day job", "a new organization of a known account joins it under its name")
        let single = (work + [named("e", "", account: "new", orgName: "them@example.com's Organization")])
        check(single.accountName(for: single[3]) == "Account 3", "a new account with only an individual organization is Account N")
        let gained = (work + [named("f", "", account: "other", orgName: "Northwind Labs")]).labelled()
        check(gained.map(\.label)[2...] == ["Side · Individual", "Side · Northwind Labs"], "an account that gains an organization shows both, by pair")
        check([old, work, acct].allSatisfy { $0.labelled().allSatisfy { !$0.label.contains("@") && !$0.name.contains("@") } }, "no label shows an email or part of one")
        check(shownName("me@example.com") == nil && shownName("Work") == "Work" && shownName("") == nil, "only a name without an email is shown")

        // A row with no saved login says how to set it up.
        check(SetUpRule.step(for: old[1], claudeAccount: "acct")
              == "choose Northwind Research once in Claude, from your name at the bottom of its sidebar",
              "an organization of the account Claude is signed in to is chosen once from Claude's sidebar")
        check(SetUpRule.step(for: old[2], claudeAccount: "other") == "choose your individual organization once in Claude, from your name at the bottom of its sidebar",
              "an organization Claude named after the email is named without it")
        check(SetUpRule.step(for: old[1], claudeAccount: "other") == "click Set Up, then sign in to it in Claude",
              "another account is signed in to first")
        check("choose it".capitalizedFirst == "Choose it", "a phrase starts a sentence")
    }

    // MARK: Upgrade

    /// The files as the previous release saved them, read from a copy on disk the way the app loads
    /// them: every row, every name someone chose and every setting comes back as saved, and only a
    /// label that shows an email gets its default label.
    static func upgrade() {
        let saved = ##"""
        {
          "accounts" : [
            { "accountUuid" : "acct-1", "color" : "#3B82F6", "configDir" : "~/logins/a", "email" : "me@example.com",
              "id" : "a", "keychainService" : "kc-a", "name" : "Work", "orgName" : "Northwind Labs", "orgUuid" : "org-1" },
            { "accountUuid" : "acct-1", "color" : "#3B82F6", "configDir" : "~/logins/b", "email" : "me@example.com",
              "id" : "b", "keychainService" : "kc-b", "name" : "Research team", "orgName" : "Northwind Research", "orgUuid" : "org-2" },
            { "accountUuid" : "acct-1", "color" : "#3B82F6", "configDir" : "~/logins/c", "email" : "me@example.com",
              "id" : "c", "keychainService" : "kc-c", "name" : "me@example.com · Northwind Support", "orgName" : "Northwind Support", "orgUuid" : "org-3" },
            { "accountUuid" : "acct-2", "color" : "#10B981", "configDir" : "~/logins/d", "email" : "you@example.com",
              "id" : "d", "keychainService" : "kc-d", "name" : "Side project", "orgName" : "you@example.com's Organization", "orgUuid" : "org-4" },
            { "accountUuid" : "acct-3", "color" : "#F59E0B", "configDir" : "~/logins/e", "email" : "them@example.com",
              "id" : "e", "keychainService" : "kc-e", "name" : "them@example.com", "orgName" : "them@example.com's Organization", "orgUuid" : "org-5" }
          ]
        }
        """##
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-upgrade-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: copy) }
        func rows(_ data: Data) -> [[String: String]] {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["accounts"] as? [[String: String]] ?? []
        }
        guard (try? Data(saved.utf8).write(to: copy)) != nil, let onDisk = try? Data(contentsOf: copy),
              let loaded = AccountsFile.decode(onDisk)?.labelled(), let resaved = try? AccountsFile.encode(loaded) else {
            return check(false, "the previous release's accounts file loads and saves")
        }
        let before = rows(onDisk), after = rows(resaved)
        check(after.count == 5 && after.map { $0["id"] } == before.map { $0["id"] }, "every row loads, in the saved order")
        check(zip(before, after).allSatisfy { old, new in old.allSatisfy { $0.key == "name" || new[$0.key] == $0.value } },
              "every login folder, keychain item, organization and color is kept as saved")
        check(zip(before, after).allSatisfy { Set($1.keys).subtracting($0.keys).isSubset(of: ["orgLabel"]) && Set($0.keys).isSubset(of: $1.keys) }
              && after.compactMap { $0["orgLabel"] } == ["Research team"],
              "no saved field is dropped; a name chosen for a further organization row is kept as that organization's name")
        check(after.map { $0["name"] ?? "" } == ["Work", "Research team", "Work", "Side project", "Account 3"],
              "every name someone chose is kept; only names that show an email change")
        check(loaded.map(\.label) == ["Work · Northwind Labs", "Work · Research team", "Work · Northwind Support", "Side project", "Account 3"],
              "and the menu names each row by them")
        check(AccountsFile.decode(resaved)?.labelled() == loaded, "saving again changes nothing further")

        // The switch order is the menu's order, kept in this file: an upgrade starts from the order
        // the menu already showed, and a new order is saved and read back as a relaunch reads it.
        check(loaded.inMenuOrder.map(\.id) == ["a", "b", "c", "d", "e"], "after an upgrade the switch order is the order the menu showed")
        guard let reordered = loaded.moved(loaded[2], by: -1, organization: true)?.moved(loaded[3], by: -1, organization: false),
              let reorderedData = try? AccountsFile.encode(reordered), (try? reorderedData.write(to: copy)) != nil,
              let reread = (try? Data(contentsOf: copy)).flatMap(AccountsFile.decode)?.labelled() else {
            return check(false, "a new order saves and loads")
        }
        check(reread.inMenuOrder.map(\.id) == ["d", "a", "c", "b", "e"], "a new order is saved and comes back after a relaunch")
        let afterMove = Dictionary(uniqueKeysWithValues: rows(reorderedData).map { ($0["id"] ?? "", $0) })
        check(after.allSatisfy { old in old.allSatisfy { $0.key == "name" || afterMove[old["id"] ?? ""]?[$0.key] == $0.value } },
              "moving rows keeps every login folder, keychain item, organization, color and chosen name")
        check(Set(reread.map(\.label)) == Set(loaded.map(\.label)), "and every row is still called what it was")

        var settings = AppSettings()
        settings.display = .gaugePercent
        settings.autoSwitch = false
        var old = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any]) ?? [:]
        old["collapsed"] = nil
        let oldSettings = (try? JSONSerialization.data(withJSONObject: old)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        check(oldSettings == settings && oldSettings?.collapsed.isEmpty == true,
              "a settings file from the previous release keeps its choices and shows every organization")
    }

    // MARK: Meters

    static func meters() {
        func body(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        // The usage service's answer for a plan without a 5-hour limit, and for one whose window hasn't started.
        let noFiveHour = body(#"{"five_hour": null, "seven_day": {"utilization": 41.5, "resets_at": "2026-11-25T17:00:00Z"}}"#)
        let notStarted = body(#"{"five_hour": {"utilization": 0, "resets_at": null}, "seven_day": {"utilization": 3, "resets_at": null}}"#)
        let nullUse = body(#"{"five_hour": {"utilization": null, "resets_at": null}, "seven_day": {"utilization": 3, "resets_at": null}}"#)
        check(UsageWindow(noFiveHour["five_hour"]) == nil && UsageWindow(body("{}")["five_hour"]) == nil && UsageWindow(nullUse["five_hour"]) == nil,
              "a missing, null, or null-utilization window is no window")
        check(UsageWindow(notStarted["five_hour"])?.utilization == 0 && UsageWindow(noFiveHour["seven_day"])?.utilization == 41.5,
              "a window at 0 with no reset is still a window")
        let wk = UsageWindow(noFiveHour["seven_day"]), fh = UsageWindow(utilization: 20, resetsAt: nil)
        check(!MeterRule.showsFiveHour(fiveHour: nil, weekly: wk), "no 5-hour meter for an account without a 5-hour window")
        check(MeterRule.showsFiveHour(fiveHour: UsageWindow(notStarted["five_hour"]), weekly: wk), "a 5-hour window not started yet still shows")
        check(MeterRule.showsFiveHour(fiveHour: nil, weekly: nil), "a reading with no window at all hides nothing")
        check(MeterRule.gauge(.fiveHour, fiveHour: nil, weekly: wk) == wk, "the gauge follows the weekly meter when there is no 5-hour window")
        check(MeterRule.gauge(.fiveHour, fiveHour: fh, weekly: wk) == fh && MeterRule.gauge(.weekly, fiveHour: fh, weekly: wk) == wk,
              "otherwise it follows the chosen limit")

        // Out: an account without a 5-hour window is judged on its weekly meter alone.
        check(picked(decide(row("busy", 40, 70), [row("ultra", nil, 30), row("max", 35, 5)])) == "ultra",
              "no 5-hour window: a weekly meter with room makes it a target")
        check(row("ultra", nil, 100).isOut(at: now) && !row("ultra", nil, 99.6).isOut(at: now), "and its weekly meter alone makes it out")
        check(picked(decide(row("busy", 40, 70), [row("ultra", nil, 100), row("max", 35, 5)])) == "max", "never to it when its weekly is full")

        // A row at its limit still offers Switch: the manual switch is the person's call, and only
        // auto-switch skips it.
        let full = row("full", 100, 100.2)
        check(full.isOut(at: now) && RowAction.pick(inUse: false, hasSavedLogin: full.hasSavedLogin) == .switchTo,
              "a row at 100 percent offers Switch, not a badge")
        check(RowAction.pick(inUse: false, hasSavedLogin: row("left", 10, 10, outUntil: now.addingTimeInterval(3600)).hasSavedLogin) == .switchTo,
              "so does a row a switch just left")
        check(RowAction.pick(inUse: true, hasSavedLogin: true) == .inUse && RowAction.pick(inUse: false, hasSavedLogin: false) == .setUp
              && RowAction.pick(inUse: true, hasSavedLogin: false) == .inUse,
              "the row in use says In use; a row with no saved login offers Set Up")
        check(picked(decide(row("busy", 40, 100), [row("busy", 40, 100), full, row("room", 5, 5)])) == "room",
              "auto-switch still skips the full row it would otherwise reach first")
        check(nowhere(decide(row("busy", 40, 100), [row("busy", 40, 100), full])), "and with only full rows left it stays and says so")
    }

    // MARK: Settings

    static func settings() {
        func decode(_ json: String) -> AppSettings? { try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        let old = decode(#"{"display":"gauge","metric":"weekly","autoSwitch":false}"#)
        check(old?.showsOrganizations(of: "acct") == true && old?.display == .gauge && old?.autoSwitch == false,
              "a settings file from before shows every organization and keeps its other choices")
        check(AppSettings().showsOrganizations(of: "acct") && AppSettings().autoSwitch, "organizations show by default")
        var folded = AppSettings()
        folded.setShowsOrganizations(of: "acct", false)
        let reread = (try? JSONEncoder().encode(folded)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        check(reread?.showsOrganizations(of: "acct") == false && reread?.showsOrganizations(of: "other") == true,
              "folding one account's organizations is remembered across launches, for that account only")
        folded.setShowsOrganizations(of: "acct", true)
        check(folded.showsOrganizations(of: "acct") && folded.collapsed.isEmpty, "and showing them again clears it")
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
        check(step(idle) == .send, "an idle chat with an empty message box gets the message, though Claude shows no Send until it has text")
        check(step(ChatScreen(busy: true, composer: true, draft: false)) == .done(.running), "a running chat is never sent to")
        check(step(ChatScreen(loading: true, busy: true, composer: true, draft: false)) == .done(.running), "a running chat counts as running while its page is busy")
        check(step(ChatScreen(busy: false, composer: true, draft: true)) == .done(.draft), "a chat with someone's unsent text is never sent to")
        check(step(nil, waited: 5, shownFor: nil) == .wait, "it waits for Claude to show the chat")
        check(step(nil, waited: ResumeRule.readyWait, shownFor: nil) == .done(.notResumed("Claude didn't show it")),
              "a chat Claude never shows is reported, not sent to")
        check(step(ChatScreen(loading: true, busy: false, composer: true, draft: false), waited: 60) == .wait,
              "it waits while the chat's page is still loading")
        check(step(ChatScreen(loading: true, busy: false, composer: true, draft: false), waited: ResumeRule.readyWait)
              == .done(.notResumed("it was still loading")), "a page that never finishes loading is reported")
        check(step(ChatScreen(busy: false, composer: false, draft: false), waited: 60) == .wait,
              "it waits a minute and more for the message box to load")
        check(step(ChatScreen(busy: false, composer: false, draft: false), waited: ResumeRule.readyWait)
              == .done(.notResumed("its message box wasn't found")), "a chat whose message box never shows is reported")
        check(step(idle, interrupted: true, shownFor: 2) == .wait, "a chat a quit cut off gets time to resume by itself on open")
        check(step(idle, interrupted: true, shownFor: ResumeRule.resumeOnOpenWait) == .send, "then it gets the message")
        check(ResumeRule.readyWait == 120 && ResumeRule.resumeOnOpenWait == 10 && ResumeRule.startWait == 30 && ResumeRule.ownPassWait == 45,
              "the waits are 120 s to show and load, 10 s for Claude's own resume on open, 30 s for the turn to start, 45 s for Claude's launch pass")

        // The retry schedule.
        check(ResumeRule.retryEvery == 60 && ResumeRule.retryFor == 30 * 60, "a chat not running is tried every minute for 30 minutes")
        check(ResumeRule.tryAgain(left: 1, elapsed: 0) && ResumeRule.tryAgain(left: 1, elapsed: ResumeRule.retryFor - ResumeRule.retryEvery),
              "another pass while one is left and it starts within the 30 minutes")
        check(!ResumeRule.tryAgain(left: 0, elapsed: 0), "no pass once every chat runs or is left to someone")
        check(!ResumeRule.tryAgain(left: 1, elapsed: ResumeRule.retryFor - ResumeRule.retryEvery + 1), "and none past the 30 minutes")
        check(ResumeRule.mayRetry(secondsSinceInput: ResumeRule.retryEvery) && !ResumeRule.mayRetry(secondsSinceInput: 5),
              "a retry opens a chat only after a minute with nobody using the Mac")
        check(ResumeRule.Result.draft.settled && ResumeRule.Result.running.settled && ResumeRule.Result.sent.settled
              && !ResumeRule.Result.notResumed("x").settled, "running, sent and someone's draft end the tries; anything else is tried again")
        check(ResumeRule.summary(running: 0, of: 1) == "Running again: 0 of 1 stopped chat."
              && ResumeRule.summary(running: 2, of: 3) == "Running again: 2 of 3 stopped chats.", "the summary says how many run again")

        // Telling the message box apart.
        typealias Box = ComposerRule.Box
        let prompt = Box(named: true, multiline: true, focused: false)
        let address = Box(named: false, multiline: false, focused: false)
        let unnamed = Box(named: false, multiline: true, focused: false)
        check(ComposerRule.pick([address, prompt])! == (1, .name), "the box named Prompt, past a side panel's address field")
        check(ComposerRule.pick([address, unnamed])! == (1, .multiline), "a box named only by its placeholder: the only multi-line one")
        check(ComposerRule.pick([address]) == nil, "an address field alone is never the message box")
        check(ComposerRule.pick([unnamed, unnamed]) == nil, "two unnamed boxes and neither focused: no guess")
        check(ComposerRule.pick([unnamed, Box(named: false, multiline: true, focused: true)])! == (1, .focus),
              "two unnamed boxes: the one with keyboard focus")
        check(ComposerRule.pick([prompt, Box(named: true, multiline: true, focused: true)])! == (1, .focus),
              "two Prompt boxes, as in a split view: the focused one")
        check(ComposerRule.pick([]) == nil, "no box: none")
    }
}
