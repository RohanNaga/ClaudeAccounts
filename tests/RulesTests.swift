// Tests for app/Rules.swift: the auto-switch rule, reading Claude's log, the quit watch,
// organization matching, labels, meters, settings and the resume step. Run with ./test.sh; it needs only swiftc, like the app.

import AppKit

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
        organizations()
        labels()
        upgrade()
        meters()
        settings()
        resume()
        notices()
        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks failed.")
        exit(failures == 0 ? 0 : 1)
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
    }

    // MARK: Meters

    // MARK: Lines for holding still

    /// The brake, the seat in use reading out with no stop, a told wait and a failed automatic
    /// switch: each line is true as written, names a time on another day with its day, and fits the
    /// notice's one line with the longest seat names in the fixtures (scripts/render-menu.swift's
    /// README rows). A stop from before Claude's current hold never counts.
    static func notices() {
        let uuid = { (n: Int) in String(format: "%08x-0000-4000-8000-%012x", n, n) }
        let rows = [("Northwind Labs", 1), ("Northwind Research", 2)].map { org, n in
            AccountRecord(id: "r\(n)", name: "Work", color: "", configDir: "/nonexistent", keychainService: "none", email: nil,
                          accountUuid: uuid(1), orgName: org, orgUuid: uuid(100 + n))
        }.labelled()
        let (labs, research) = (rows[0].seat, rows[1].seat)
        // 11:55 PM, so the brake ends after midnight.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 23, minute: 55))!
        let stamp = { (d: Date) in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = ClaudeLog.timeFormat
            return f.string(from: d)
        }
        let held = "\(stamp(now.addingTimeInterval(-7200))) [info] \(ClaudeLog.identity) accountId=\(labs.account) orgId=\(labs.org)"
        let stop = "\(stamp(now.addingTimeInterval(-300))) [info] \(ClaudeLog.cycle)local_a\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit"
        func facts(labsFull: Bool, stopped: Bool) -> Facts {
            var f = Facts()
            f.rows = rows
            f.claude = ClaudeFacts(installed: true, running: true, missing: [])
            f.trusted = true
            f.log.read(held, readAt: now.addingTimeInterval(-7200))
            if stopped { f.log.read(stop, readAt: now.addingTimeInterval(-300), arrived: true) }
            f.saved = [labs, research]
            let reset = now.addingTimeInterval(3 * 3600)
            f.meters[labs] = SeatMeters(fiveHour: MeterReading(percent: labsFull ? 100 : 40, resetsAt: reset), readAt: now.addingTimeInterval(-60))
            f.meters[research] = SeatMeters(fiveHour: MeterReading(percent: 10, resetsAt: reset), readAt: now.addingTimeInterval(-60))
            return f
        }

        var braked = facts(labsFull: true, stopped: true)
        braked.lastAutoSwitch = now.addingTimeInterval(-60)
        let brake = AppState.notice(braked, now: now)
        let ends = now.addingTimeInterval(Limits.autoSwitchSpacing - 60)
        let day = ends.formatted(.dateTime.weekday(.abbreviated))
        check(AutoSwitch.decide(braked, now: now) == .brake(to: research, at: ends), "a switch inside the spacing waits for its end")
        check(brake?.text == "Switching to Work · Northwind Research at \(ClockText.time(ends, now: now)).", "the brake says where and when: \(brake?.text ?? "none")")
        check(brake?.text.contains(day) == true, "a brake that ends after midnight names the day: \(brake?.text ?? "none")")
        check(brake?.detail == "Work · Northwind Labs is out. Switching to Work · Northwind Research at \(ClockText.time(ends, now: now)): automatic switches are at least 15 minutes apart.",
              "its full sentence: \(brake?.detail ?? "none")")
        braked.lastAutoSwitch = now.addingTimeInterval(-Limits.autoSwitchSpacing)
        check(AutoSwitch.decide(braked, now: now) == .switchTo(research), "once the spacing ends, the switch")

        // Claude reopened on the seat (by hand, by a switch, or by the person): a stop from the hold
        // before never counts.
        var reopened = facts(labsFull: true, stopped: true)
        check(AutoSwitch.decide(reopened, now: now) == .switchTo(research), "setup: a stop on the full seat in use switches")
        let again = "\(stamp(now.addingTimeInterval(-120))) [info] \(ClaudeLog.appStart) }\n\(stamp(now.addingTimeInterval(-110))) [info] \(ClaudeLog.identity) accountId=\(labs.account) orgId=\(labs.org)"
        reopened.log.read(again, readAt: now.addingTimeInterval(-110), arrived: true)
        check(AutoSwitch.decide(reopened, now: now) == .none, "once Claude reopens on the seat, an earlier stop never moves it")
        // A turn that ends normally after the stop, in any chat on the seat, shows Claude served past it.
        var served = facts(labsFull: true, stopped: true)
        served.log.read("\(stamp(now.addingTimeInterval(-290))) [info] \(ClaudeLog.healthyCycle)local_b (12s, hadFirstResponse=true)",
                        readAt: now.addingTimeInterval(-290), arrived: true)
        check(AutoSwitch.decide(served, now: now) == .none, "a normal turn on the seat after the stop vetoes it")
        // A stop more than 15 minutes before the seat began reading 100 is not this seat running out.
        var early = facts(labsFull: true, stopped: false)
        early.log.read("\(stamp(now.addingTimeInterval(-3000))) [info] \(ClaudeLog.cycle)local_a\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit",
                       readAt: now.addingTimeInterval(-3000), arrived: true)
        early.meters[labs]?.since = now.addingTimeInterval(-3000 + Limits.stopBeforeFull + 60)
        check(AutoSwitch.decide(early, now: now) == .none, "a stop more than 15 minutes before the seat began reading 100 does not count")
        early.meters[labs]?.since = now.addingTimeInterval(-3000 + Limits.stopBeforeFull - 60)
        check(AutoSwitch.decide(early, now: now) == .switchTo(research), "one up to 15 minutes before it does")
        // A stop already in the log when the app first read it never counts, however its printed
        // time reads: only a stop the app saw arrive, timed by the app's own clock.
        var atLaunch = facts(labsFull: true, stopped: false)
        atLaunch.log = ClaudeEvents()
        atLaunch.log.read(held + "\n" + stop, readAt: now.addingTimeInterval(-7200))
        check(AutoSwitch.decide(atLaunch, now: now) == .none && AutoSwitch.stoppedNow(atLaunch, now: now).isEmpty,
              "a stop found in the first read of the log never counts")
        atLaunch.log.read("\(stamp(now.addingTimeInterval(3 * 3600))) [info] \(ClaudeLog.cycle)local_b\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit",
                          readAt: now.addingTimeInterval(-60), arrived: true)
        check(AutoSwitch.decide(atLaunch, now: now) == .switchTo(research), "a stop seen arriving counts by when it arrived, whatever time it prints")

        let full = AppState.notice(facts(labsFull: true, stopped: false), now: now)
        check(full?.text == "In use reads 100%. It switches when Claude stops a chat.", "the seat in use reads out and no stop counts: \(full?.text ?? "none")")
        check(full?.detail == "Work · Northwind Labs reads 100%. It switches when Claude next stops a chat there for its limit.", "its full sentence: \(full?.detail ?? "none")")
        var off = facts(labsFull: true, stopped: false)
        off.autoChosen = false
        check(AppState.notice(off, now: now) == nil, "with Auto-Switch off, no line says it switches")

        // A told wait: the line shows only for the hold and the run of full readings it was told in.
        var waiting = facts(labsFull: true, stopped: true)
        waiting.meters[research] = SeatMeters(fiveHour: MeterReading(percent: 100, resetsAt: now.addingTimeInterval(3600)), readAt: now.addingTimeInterval(-60))
        check(AutoSwitch.decide(waiting, now: now) == .wait(seat: research, resumesAt: now.addingTimeInterval(3600)), "setup: every seat is out")
        check(AppState.notice(waiting, now: now) == nil, "an untold wait shows no line yet")
        waiting.wait = AutoSwitch.Wait(hold: waiting.hold!.key, stops: AutoSwitch.stoppedNow(waiting, now: now))
        check(AppState.notice(waiting, now: now) == nil, "a wait acted on but not told shows no line")
        waiting.wait?.told = true
        let told = AppState.notice(waiting, now: now)
        check(told?.text == "Every seat is out. Chats resume at \(ClockText.time(now.addingTimeInterval(3600), now: now)).", "the told wait: \(told?.text ?? "none")")
        var served2 = waiting
        served2.log.read("\(stamp(now.addingTimeInterval(-30))) [info] \(ClaudeLog.healthyCycle)local_a (12s, hadFirstResponse=true)", readAt: now.addingTimeInterval(-30), arrived: true)
        check(AppState.notice(served2, now: now) == nil, "a told wait whose chat ran again says nothing")
        waiting.wait?.hold = "another hold"
        check(AppState.notice(waiting, now: now) == nil, "a wait told in another hold says nothing")

        // A failed automatic switch that reopened Claude on its seat.
        let failed = "Didn't switch to Work · Northwind Research. \(AutoSwitch.afterFailureShort)"

        // The notice is the panel's width less its padding and the line's own: 330 - 2 x 6 - 2 x 10.
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        for line in [brake?.text, full?.text, told?.text, failed, QuitWatch.answerPrompt].compactMap({ $0 }) {
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            check(width <= 298, "\"\(line)\" fits one line: \(Int(width)) of 298 pt")
        }
    }

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
        check(ResumeRule.readyWait == 120 && ResumeRule.resumeOnOpenWait == 10 && ResumeRule.startWait == 30,
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
