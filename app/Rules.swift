// The decisions behind the menu and switching, kept free of AppKit, files and the network so the
// tests in tests/RulesTests.swift drive them directly: which account a Claude identity belongs to,
// how rows are labelled, which meters a row shows, the menu's settings, what Claude's log says,
// when auto-switch moves and to which account, how a quit request is followed to its end, and
// which stopped chats get a new message after a switch.

import Foundation

// MARK: - Accounts and identities

/// The account Claude is signed in to and the organization whose Code sessions it shows.
struct Identity: Hashable, Codable, Sendable {
    let account: String
    let org: String
}

/// One row in the menu: one Claude login for one account in one organization.
/// An account that belongs to two organizations has two rows, one per organization.
struct AccountRecord: Codable, Identifiable, Equatable {
    let id: String
    /// The account's name, the same on every row of the account.
    var name: String
    var color: String
    var configDir: String
    var keychainService: String
    let email: String?
    let accountUuid: String?
    var orgName: String?
    /// The organization this row stands for. Older rows lack it until it is filled in on load.
    var orgUuid: String?
    /// A name someone gave this row's organization; nil shows the organization's own name.
    var orgLabel: String? = nil
    /// What the app calls this row: the account's name, then " · " and the organization when the
    /// account has more than one row. Set on load, never saved.
    var label = ""

    private enum CodingKeys: String, CodingKey {
        case id, name, color, configDir, keychainService, email, accountUuid, orgName, orgUuid, orgLabel
    }

    var configURL: URL { URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath) }

    /// The organization's name as the app shows it: the name someone gave it, else its own name,
    /// with "Individual" for the one Claude names after the account's email.
    var organization: String { shownName(orgLabel) ?? defaultOrganizationName(orgName) }

    /// The account and organization this row stands for, once both are known.
    var identity: Identity? { accountUuid.flatMap { account in orgUuid.map { Identity(account: account, org: $0) } } }
}

/// Claude names an account's own individual organization "<email>'s Organization"; the app calls
/// it "Individual". A team organization keeps its name.
func defaultOrganizationName(_ orgName: String?) -> String {
    guard let orgName, !orgName.isEmpty else { return "Organization" }
    if orgName.contains("@") || orgName.hasSuffix("'s Organization") || orgName.hasSuffix("\u{2019}s Organization") { return "Individual" }
    return orgName
}

/// An organization name that can name an account, which a team's name can and "Individual" can't.
func teamName(_ orgName: String?) -> String? {
    let name = defaultOrganizationName(orgName)
    return name == "Individual" || name == "Organization" ? nil : name
}

/// A name the app may show, or nil when it holds an email address or part of one. Claude names a
/// personal organization after its email, so no label, row, message or notification shows a name
/// with "@" in it.
func shownName(_ name: String?) -> String? {
    guard let name, !name.isEmpty, !name.contains("@") else { return nil }
    return name
}

extension Array where Element == AccountRecord {
    /// The row a Claude identity belongs to: the row for that account and organization, else the
    /// account's only row that names no organization yet.
    func row(for id: Identity?) -> AccountRecord? {
        guard let id else { return nil }
        if let exact = first(where: { $0.accountUuid == id.account && $0.orgUuid == id.org }) { return exact }
        let unnamed = filter { $0.accountUuid == id.account && $0.orgUuid == nil }
        return unnamed.count == 1 ? unnamed[0] : nil
    }

    /// Rows for the same account in other organizations than `row`.
    func otherOrganizations(of row: AccountRecord) -> [AccountRecord] {
        filter { $0.id != row.id && $0.accountUuid != nil && $0.accountUuid == row.accountUuid }
    }

    /// The rows grouped by account, in the order each account first appears, so the menu shows
    /// one entry per account with its organizations beneath. A row with no account id stands alone.
    func groupedByAccount() -> [[AccountRecord]] {
        var groups: [[AccountRecord]] = []
        for row in self {
            if let uuid = row.accountUuid, let i = groups.firstIndex(where: { $0.first?.accountUuid == uuid }) {
                groups[i].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups
    }

    /// The rows as the menu lists them: each account where it first appears, its organizations
    /// beneath it. This is also the order auto-switch tries them in.
    var inMenuOrder: [AccountRecord] { groupedByAccount().flatMap { $0 } }

    /// The rows after moving `row` one place up (`step` -1) or down (`step` 1) in the menu, or nil
    /// when it is already at that end. An organization entry moves among its account's
    /// organizations; any other row moves its whole account past the neighbouring account. The
    /// account keeps its name whichever organization comes first.
    func moved(_ row: AccountRecord, by step: Int, organization: Bool) -> [AccountRecord]? {
        var groups = groupedByAccount()
        guard let g = groups.firstIndex(where: { $0.contains { $0.id == row.id } }) else { return nil }
        if organization {
            guard let i = groups[g].firstIndex(where: { $0.id == row.id }), groups[g].indices.contains(i + step) else { return nil }
            let account = accountName(for: row)
            for k in groups[g].indices { groups[g][k].name = account }
            groups[g].swapAt(i, i + step)
        } else {
            guard groups.indices.contains(g + step) else { return nil }
            groups.swapAt(g, g + step)
        }
        return groups.flatMap { $0 }.labelled()
    }

    /// The organizations of `account` that Claude has opened (`opened`, with how many chats
    /// each holds) but no row stands for yet, most used first.
    func organizationsToAdd(account: String, opened: [(org: String, chats: Int)]) -> [String] {
        let added = Set(filter { $0.accountUuid == account }.compactMap(\.orgUuid))
        return opened.filter { !added.contains($0.org) }.sorted { $0.chats > $1.chats }.map(\.org)
    }

    /// The name of the account `row` belongs to, never an email: the name its first row was
    /// given, else its first organization's team name, else "Account N".
    func accountName(for row: AccountRecord) -> String {
        let groups = groupedByAccount()
        guard let g = groups.firstIndex(where: { $0.contains { $0.id == row.id } }) else {
            return shownName(row.name) ?? teamName(row.orgName) ?? "Account \(groups.count + 1)"
        }
        let first = groups[g][0]
        return shownName(first.name) ?? teamName(first.orgName) ?? "Account \(g + 1)"
    }

    /// The rows with their labels set: an account with one row is called by its name, and each
    /// row of an account with several is "<account> · <organization>". Names used to default to
    /// the email, so a name with one becomes the account's name; every other saved name is kept.
    func labelled() -> [AccountRecord] {
        var rows = self
        for group in groupedByAccount() {
            let account = rows.accountName(for: group[0])
            for (k, member) in group.enumerated() {
                guard let i = rows.firstIndex(where: { $0.id == member.id }) else { continue }
                // Before organizations had names of their own, a further row's name was its whole label;
                // one that isn't the old "<account> · <organization>" default was chosen for that organization.
                if k > 0, rows[i].orgLabel == nil, let saved = shownName(rows[i].name), saved != account,
                   !saved.hasSuffix(" · " + (rows[i].orgName ?? "")) { rows[i].orgLabel = saved }
                if shownName(rows[i].name) == nil { rows[i].name = account }
                rows[i].label = group.count > 1 ? "\(account) · \(rows[i].organization)" : account
            }
        }
        return rows
    }

    /// The rows after renaming `row`: an organization entry renames only its organization, and
    /// anything else renames the account on every one of its rows. An empty name, or one with an
    /// email in it, puts the default name back.
    func renamed(_ row: AccountRecord, to text: String, organization: Bool) -> [AccountRecord] {
        var rows = self
        let name = shownName(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if organization {
            guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return rows }
            rows[i].orgLabel = name == defaultOrganizationName(rows[i].orgName) ? nil : name
            rows[i].name = rows.accountName(for: rows[i])
        } else {
            let ids = Set(rows.filter { $0.id == row.id || ($0.accountUuid != nil && $0.accountUuid == row.accountUuid) }.map(\.id))
            for i in rows.indices where ids.contains(rows[i].id) { rows[i].name = "" }
            let fallback = rows.accountName(for: row)
            for i in rows.indices where ids.contains(rows[i].id) { rows[i].name = name ?? fallback }
        }
        return rows.labelled()
    }
}

/// The app's accounts.json, the rows in menu order. Its format has not changed since rows gained
/// organizations, so a file an earlier version saved reads back as it was saved.
enum AccountsFile {
    private struct File: Codable { var accounts: [AccountRecord] }

    static func decode(_ data: Data) -> [AccountRecord]? { (try? JSONDecoder().decode(File.self, from: data))?.accounts }

    static func encode(_ accounts: [AccountRecord]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(File(accounts: accounts))
    }
}

extension String {
    /// The text with its first letter in upper case, to start a sentence with a phrase.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// How a row with no saved Claude login gets one, said the same way in the row and in --dry-run.
/// The app saves a row's login once Claude has held that account and organization steadily
/// (SaveRule), so the one-time step is to open it in Claude: choose the organization from your name
/// at the bottom of Claude's sidebar when Claude is already signed in to the account, else sign in
/// to it first. An organization Claude refused needs a new sign-in there.
enum SetUpRule {
    /// How long a set-up waits for the person to sign in to Claude and hold the row's account.
    static let signInWait: TimeInterval = 10 * 60

    static func step(for row: AccountRecord, claudeAccount: String?, refused: Bool = false) -> String {
        if refused {
            return "Claude asked for a new sign-in to this organization. Choose it in Claude, sign in, "
                + "and stay on it for a minute to save it"
        }
        let signedIn = row.accountUuid != nil && row.accountUuid == claudeAccount
        let org = row.orgName == nil && row.orgLabel == nil ? "this organization"
            : row.organization == "Individual" ? "your individual organization" : row.organization
        return signedIn ? "choose \(org) once in Claude, from your name at the bottom of its sidebar"
                        : "click Set Up, then sign in to it in Claude"
    }

    enum Verdict: Equatable { case waiting, confirmed(Identity), other(Identity?) }

    /// Where a set-up of `row` stands, from Claude's log since it reopened at `started`: confirmed
    /// once Claude has held the row's own account and organization steadily; ended without it once
    /// Claude holds another account steadily or the wait runs out. Another organization of the same
    /// account is a step on the way (the person still chooses the organization), not an end.
    static func verdict(for row: AccountRecord, in rows: [AccountRecord], log: LogFollower, started: Date, now: Date) -> Verdict {
        if let held = log.steady(at: now) {
            if rows.row(for: held)?.id == row.id { return .confirmed(held) }
            if held.account != row.accountUuid { return .other(held) }
        }
        return now.timeIntervalSince(started) >= signInWait ? .other(log.identity) : .waiting
    }

    /// The one sentence for a set-up that ended without Claude on the row: which account Claude is
    /// on, and that the row is still not set up. Nothing was saved or moved.
    static func notSetUp(_ row: AccountRecord, seen: Identity?, in rows: [AccountRecord]) -> String {
        let on: String
        if let seen, let known = rows.row(for: seen), known.id != row.id { on = "is signed in as \(known.label)" }
        else if let seen, seen.account == row.accountUuid { on = "is on another organization of \(row.name)" }
        else if seen != nil { on = "is signed in to an account this app doesn't know" }
        else { on = "isn't signed in" }
        return "Claude \(on), so \(row.label) is still not set up."
    }
}

/// When the in-use row's Claude login is saved. Claude names an organization as soon as it opens
/// it; an organization that wants a fresh sign-in is then refused (session_stale_relogin) and
/// Claude falls back to the account's individual organization, 4 to 21 s later in Claude's log. A
/// login saved inside that window is one the organization refuses, so a login is saved only once
/// Claude has held its account and organization steadily, while it runs and again at switch-away.
enum SaveRule {
    /// Three times the slowest fall-back seen (21 s).
    static let steadyHold: TimeInterval = 60

    /// A saved login counts unless Claude refused that sign-in after it was saved
    /// (LogFollower.refusal): the older one is the sign-in Claude now calls too old.
    static func counts(savedAt: Date, refusedAt: Date?) -> Bool { refusedAt.map { savedAt > $0 } ?? true }
}

// MARK: - Usage

/// One usage window from Claude's usage service: how much of it is used and when it resets.
struct UsageWindow: Equatable, Codable {
    /// Percent used as the usage service reports it, unrounded; "out" is decided on this.
    let utilization: Double
    let resetsAt: Date?

    /// Rounded, for display only.
    var pct: Int { Int(utilization.rounded()) }

    private enum CodingKeys: String, CodingKey { case utilization, pct, resetsAt }

    init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// A cache written before the unrounded value was kept has only `pct`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try c.decodeIfPresent(Double.self, forKey: .utilization) ?? Double(c.decode(Int.self, forKey: .pct))
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(utilization, forKey: .utilization)
        try c.encode(pct, forKey: .pct)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }

    /// Relative and absolute together: "in 2 h 05 m · 13:10" today, "in 2 days · Sep 27, 13:00"
    /// further out, and "No reset pending" for a window that hasn't started.
    var resetText: String {
        guard let date = resetsAt else { return "No reset pending" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "Resetting now" }
        let f = DateFormatter()
        let relative: String
        if secs < 24 * 3600 {
            let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
            relative = h > 0 ? "in \(h) h \(String(format: "%02d", m)) m" : "in \(max(m, 1)) min"
            f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        } else {
            let days = Int((secs / 86400).rounded())
            relative = "in \(days) day\(days == 1 ? "" : "s")"
            f.dateFormat = "MMM d, HH:mm"
        }
        return "\(relative) · \(f.string(from: date))"
    }

    /// A reset this close means the account frees up soon, which is when switching to it pays off.
    var resetsSoon: Bool { resetsAt.map { $0.timeIntervalSinceNow > 0 && $0.timeIntervalSinceNow <= 15 * 60 } ?? false }

    /// One window of the usage response, such as its `five_hour` object. Nil when the response has
    /// no such window: the object is missing or null, or its utilization is null. Claude's own
    /// usage panels leave such a window out in exactly this case.
    init?(_ raw: Any?) {
        guard let dict = raw as? [String: Any], let util = dict["utilization"] as? Double else { return nil }
        utilization = util
        resetsAt = (dict["resets_at"] as? String).flatMap(Self.parseDate)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// What a row's meters and the menu bar gauge show.
enum MeterRule {
    /// The 5-hour meter shows unless a reading says the account has no 5-hour window: Claude's
    /// usage service leaves that window out for a plan without the limit, and Claude's own usage
    /// panels then show no 5-hour row. A reading with no weekly window either carries no such
    /// signal, so the meter still shows rather than hide a real limit.
    static func showsFiveHour(fiveHour: UsageWindow?, weekly: UsageWindow?) -> Bool { fiveHour != nil || weekly == nil }

    /// The window the menu bar gauge follows: the chosen limit, or the weekly one for an account
    /// without a 5-hour window.
    static func gauge(_ metric: UsageMetric, fiveHour: UsageWindow?, weekly: UsageWindow?) -> UsageWindow? {
        metric == .fiveHour ? fiveHour ?? weekly : weekly
    }
}

// MARK: - Settings

/// What the menu bar item shows next to its gauge.
enum MenuBarDisplay: String, Codable, CaseIterable, Identifiable {
    case gauge, gaugePercent, gaugeNamePercent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gauge: return "Gauge Only"
        case .gaugePercent: return "Gauge and Percentage"
        case .gaugeNamePercent: return "Gauge, Name and Percentage"
        }
    }
}

/// Which limit the gauge and percentage follow.
enum UsageMetric: String, Codable, CaseIterable, Identifiable {
    case fiveHour, weekly
    var id: String { rawValue }
    var title: String { self == .fiveHour ? "5-Hour Limit" : "Weekly Limit" }
}

/// Menu preferences, kept in settings.json in the app's state folder.
struct AppSettings: Codable, Equatable {
    var display: MenuBarDisplay = .gaugeNamePercent
    var metric: UsageMetric = .fiveHour
    /// Switch by itself when the account in use runs out of usage.
    var autoSwitch = AutoSwitchRule.onByDefault
    /// Accounts whose organizations the menu folds under the account's name. Empty at first, so
    /// every organization shows.
    var collapsed: Set<String> = []

    init() {}

    /// Each key is optional, so a settings file from an older version keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(MenuBarDisplay.self, forKey: .display) ?? .gaugeNamePercent
        metric = try c.decodeIfPresent(UsageMetric.self, forKey: .metric) ?? .fiveHour
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? AutoSwitchRule.onByDefault
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
    }

    /// Whether the menu shows the organizations of `account`.
    func showsOrganizations(of account: String) -> Bool { !collapsed.contains(account) }

    /// Show or fold away the organizations of `account`.
    mutating func setShowsOrganizations(of account: String, _ shown: Bool) {
        if shown { collapsed.remove(account) } else { collapsed.insert(account) }
    }
}

// MARK: - Auto-switch

/// One row as the auto-switch rule sees it.
struct SwitchCandidate: Equatable {
    let id: String
    let name: String
    /// Percent used, unrounded; nil when the account has no such window, so an account without a
    /// 5-hour limit is judged on its weekly meter alone.
    let fiveHour: Double?
    let weekly: Double?
    /// When this reading was taken; nil when there is no reading at all.
    let readAt: Date?
    let needsSignIn: Bool
    let hasSavedLogin: Bool
    /// When each meter of this reading resets.
    var fiveHourResetsAt: Date? = nil
    var weeklyResetsAt: Date? = nil
    /// Until when a switch away from this row counts it as out, whatever its meters read.
    var outUntil: Date? = nil

    /// The fuller of the meters it has.
    var used: Double { Swift.max(fiveHour ?? 0, weekly ?? 0) }

    /// A meter it has is at its limit, compared unrounded. Auto-switch skips such a row; the menu
    /// still offers Switch on it.
    var atLimit: Bool { used >= AutoSwitchRule.limit }

    /// Out of usage: a meter at its limit, or a switch left this row and its reset hasn't come yet.
    func isOut(at now: Date) -> Bool { atLimit || (outUntil.map { now < $0 } ?? false) }

    /// How --dry-run describes the row: its meters and the reading's age, then whether it is out,
    /// how to set it up when it has no saved login, and whether it needs a sign-in. `setUpStep` is
    /// SetUpRule's step for the row.
    func summary(at now: Date, setUpStep: String) -> String {
        let setUp = hasSavedLogin ? "" : ", not set up: " + setUpStep
        guard let read = readAt else { return "no reading" + setUp }
        let age = Swift.max(Int(now.timeIntervalSince(read) / 60), 0)
        return (fiveHour.map { "5-hour \(AutoSwitchRule.percent($0)), " } ?? "no 5-hour limit, ")
            + "weekly \(AutoSwitchRule.percent(weekly ?? 0)), read \(age) min ago"
            + (isOut(at: now) ? ", out" : "") + setUp + (needsSignIn ? ", needs sign-in" : "")
    }
}

/// What a menu row offers on its right. The row in use says so; every other row with a saved
/// login offers Switch, whatever its meters read, because a manual switch is the person's call;
/// a row without one offers Set Up.
enum RowAction: Equatable {
    case inUse, switchTo, setUp

    static func pick(inUse: Bool, hasSavedLogin: Bool) -> RowAction {
        inUse ? .inUse : hasSavedLogin ? .switchTo : .setUp
    }
}

enum AutoSwitchRule {
    /// On without touching anything; the header menu turns it off.
    static let onByDefault = true
    /// A meter at 100 percent is the limit.
    static let limit: Double = 100
    /// No second automatic try this soon after the last one, whatever its outcome, so a failed
    /// switch never quits Claude over and over.
    static let coolDown: TimeInterval = 10 * 60
    /// A reading older than this is not trusted to choose a target.
    static let freshness: TimeInterval = 15 * 60
    /// How long the row a switch leaves counts as out when its reading shows no reset ahead: the
    /// length of the shorter usage window.
    static let outWithoutReset: TimeInterval = 5 * 3600

    enum Decision: Equatable {
        case stay(String)
        case switchTo(id: String, reason: String)
        /// The account in use is out and no other account has room; worth telling the person once.
        case nowhere(String)
    }

    /// Whether to switch now, and to which row. The one trigger is Claude itself: it stopped a
    /// chat of the account in use because that account is out of usage (`limitStopped`, from
    /// Claude's log). The meters never start a switch; the target is `next(after:in:now:)`.
    /// `rows` are every row in menu order.
    static func decide(current: SwitchCandidate?, rows: [SwitchCandidate], enabled: Bool, limitStopped: Bool,
                       claudeRunning: Bool, lastAttempt: Date?, now: Date) -> Decision {
        guard enabled else { return .stay("Auto-switch is off.") }
        guard let current else { return .stay("Claude isn't using an account this app knows.") }
        guard limitStopped else { return .stay("Claude hasn't stopped a chat of \(current.name) at its usage limit.") }
        guard claudeRunning else { return .stay("Claude isn't running.") }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < coolDown {
            return .stay("\(current.name) is out, but the last try was under \(Int(coolDown / 60)) minutes ago; next try after \(clock(lastAttempt.addingTimeInterval(coolDown))).")
        }
        guard let target = next(after: current, in: rows, now: now) else {
            return .nowhere("Claude stopped a chat because \(current.name) is out of usage, and no other set-up account has room. Chats wait until a limit resets.")
        }
        return .switchTo(id: target.id, reason: "Claude stopped a chat because \(current.name) is out of usage; \(target.name) is next in the menu with room.")
    }

    /// The row the next automatic switch goes to: going down the menu from the row in use, the
    /// first one that is set up, signed in, freshly read and not out, wrapping round to the top.
    /// Never the row in use. `rows` are every row in menu order, so the person's order decides.
    static func next(after current: SwitchCandidate, in rows: [SwitchCandidate], now: Date) -> SwitchCandidate? {
        let start = rows.firstIndex { $0.id == current.id }.map { $0 + 1 } ?? 0
        return (rows[start...] + rows[..<start]).first {
            $0.id != current.id && $0.hasSavedLogin && !$0.needsSignIn && fresh($0, now) && !$0.isOut(at: now)
        }
    }

    /// Until when the row a switch leaves counts as out: the reset of its fuller meter, else of
    /// the other one, else `outWithoutReset` from now. A reading that hasn't caught up with the
    /// limit can't send a later switch back to it before then.
    static func outUntil(leaving row: SwitchCandidate, now: Date) -> Date {
        let ahead = [(row.fiveHour ?? 0, row.fiveHourResetsAt), (row.weekly ?? 0, row.weeklyResetsAt)]
            .compactMap { used, reset in reset.flatMap { $0 > now ? (used, $0) : nil } }
        return ahead.max { $0.0 < $1.0 }?.1 ?? now.addingTimeInterval(outWithoutReset)
    }

    private static func fresh(_ c: SwitchCandidate, _ now: Date) -> Bool {
        c.readAt.map { now.timeIntervalSince($0) <= freshness } ?? false
    }

    /// Rounded down, so an account short of its limit never reads as 100 percent.
    static func percent(_ used: Double) -> String { "\(Int(used.rounded(.down)))%" }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Claude's log

/// Claude's own log, read in order as it grows: the account and organization whose chats Claude
/// shows, and which of those chats it stopped for usage or cut off by quitting. A new run, a
/// sign-out or another account starts both sets over, so each entry belongs to the account
/// Claude named above it.
struct LogFollower {
    /// Who Claude says it is: the Code tab logs the account and organization whose chats it loads
    /// at every launch and every account change; a restart or a sign-out clears it until then.
    private(set) var identity: Identity?
    /// Chats whose last turn Claude ended because the account is out of usage. Such a chat is
    /// idle and Claude doesn't resume it; it waits for a new message. Retrying the failed message
    /// instead rewinds the chat and starts its transcript over under a new id, without its subagents.
    private(set) var stoppedByLimit: Set<String> = []
    /// When Claude stopped each chat in `stoppedByLimit`, from the line's time.
    private var stoppedAt: [String: Date] = [:]
    /// Chats whose turn was still running when Claude quit.
    private(set) var cutByQuit: Set<String> = []
    /// When Claude named the identity it holds, from the line's time; named again after a refusal
    /// of its organization, the hold starts over. Nil while it holds none.
    private(set) var heldSince: Date?
    /// When Claude last refused each account's sign-in to an organization as too old. An
    /// organization is shared by every account in it, and Claude refuses one account's sign-in, so
    /// a refusal is kept by account and organization. Kept across runs and sign-outs until Claude
    /// next holds that account and organization steadily (refusal(of:at:)).
    private var refusedAt: [Identity: Date] = [:]

    /// Claude's own messages for a turn refused because the account is out of usage.
    static let outOfUsage = ClaudeLog.limitTexts

    init(identity: Identity? = nil) { self.identity = identity }

    mutating func read(_ text: String) {
        for line in text.split(separator: "\n") {
            if line.contains(ClaudeLog.identity),
               let account = Self.field(line, ClaudeLog.accountField), let org = Self.field(line, ClaudeLog.orgField) {
                let named = Identity(account: account, org: org)
                if named != identity { endHold(at: Self.time(line)); stoppedByLimit = []; stoppedAt = [:]; cutByQuit = [] }
                let refusedSinceHeld = heldSince.flatMap { since in refusedAt[named].map { $0 >= since } } ?? false
                if named != identity || heldSince == nil || refusedSinceHeld { heldSince = Self.time(line) }
                identity = named
            } else if line.contains(ClaudeLog.refusal), let at = Self.time(line), let held = identity {
                // Claude refuses the sign-in of the account it holds, naming the organization as
                // orgId= or inside its cache key.
                if let org = Self.field(line, ClaudeLog.orgField) ?? (line.contains(held.org) ? held.org : nil) {
                    refusedAt[Identity(account: held.account, org: org)] = at
                }
            } else if line.contains(ClaudeLog.appStart) || Self.signsOut(line) {
                endHold(at: Self.time(line))
                identity = nil
                heldSince = nil
                stoppedByLimit = []
                stoppedAt = [:]
                cutByQuit = []
            } else if line.contains(ClaudeLog.cycle) {
                if let id = Self.session(after: ClaudeLog.healthyCycle, in: line) {
                    stoppedByLimit.remove(id)
                    stoppedAt[id] = nil
                    cutByQuit.remove(id)
                } else if let id = Self.session(after: ClaudeLog.unhealthyCycle, in: line) {
                    if line.contains(ClaudeLog.quitReason) { cutByQuit.insert(id) }
                } else if let id = Self.session(after: ClaudeLog.cycle, in: line), line.contains(ClaudeLog.apiError),
                          Self.outOfUsage.contains(where: { line.contains($0) }) {
                    stoppedByLimit.insert(id)
                    stoppedAt[id] = Self.time(line)
                }
            }
        }
    }

    /// Chats Claude stopped for usage once it had settled on the identity it holds, held for
    /// SaveRule.steadyHold: only these say that identity is out. A stop sooner after Claude named it
    /// ends a turn begun before, on the identity it held then, like a refusal before a steady hold.
    var stoppedWhileSettled: Set<String> {
        guard let since = heldSince else { return [] }
        return Set(stoppedAt.filter { $0.value.timeIntervalSince(since) >= SaveRule.steadyHold }.keys)
    }

    /// The identity whose login may be saved at `now`: Claude has held it for SaveRule.steadyHold
    /// and has not refused its organization since it named it.
    func steady(at now: Date) -> Identity? {
        guard let identity, let since = heldSince, now.timeIntervalSince(since) >= SaveRule.steadyHold else { return nil }
        if let refused = refusedAt[identity], refused >= since { return nil }
        return identity
    }

    /// When Claude refused `identity`'s sign-in, if that refusal still counts at `now`: a refusal
    /// counts until Claude next holds that account and organization steadily, which shows the
    /// sign-in works again.
    func refusal(of identity: Identity?, at now: Date) -> Date? {
        guard let identity, steady(at: now) != identity else { return nil }
        return refusedAt[identity]
    }

    /// The hold ends at `end` (another identity named, a new run, a sign-out); held steadily up to
    /// then, its refusal no longer counts.
    private mutating func endHold(at end: Date?) {
        if let end, let held = steady(at: end) { refusedAt[held] = nil }
    }

    /// A line's time: Claude starts each line with its local "yyyy-MM-dd HH:mm:ss".
    static func time<S: StringProtocol>(_ line: S) -> Date? {
        timeFormat.date(from: String(line.prefix(19)))
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = ClaudeLog.timeFormat
        return f
    }()

    /// Who Claude says it is after reading `text`, starting from `start`.
    static func identity(after text: String, from start: Identity?) -> Identity? {
        var follower = LogFollower(identity: start)
        follower.read(text)
        return follower.identity
    }

    static func signsOut<S: StringProtocol>(_ line: S) -> Bool {
        ClaudeLog.signOut.contains { line.contains($0) }
    }

    private static func field<S: StringProtocol>(_ line: S, _ key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let value = line[r.upperBound...].prefix { $0.isHexDigit || $0 == "-" }
        return value.count == 36 ? String(value) : nil
    }

    private static func session<S: StringProtocol>(after marker: String, in line: S) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        let id = line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return id.hasPrefix(ClaudeLog.sessionPrefix) ? String(id) : nil
    }
}

// MARK: - Following a quit request

/// What the switch sees each time it looks while Claude decides whether to quit.
struct QuitObservation: Equatable {
    var claudeRunning: Bool
    /// One of Claude's alerts or sheets is on screen, found through Accessibility or as a new window.
    var promptOpen: Bool
    /// Claude logged that its quit prompt stopped the quit.
    var vetoLogged = false
    /// Claude logged that it will quit once its chats finish (Wait for Claude).
    var waitLogged = false
    /// Claude logged a new quit after the prompt (Quit anyway).
    var quitLoggedAfterVeto = false
}

/// Follows one quit request to its end. It never gives up while Claude's quit prompt is open or
/// while Claude may still quit because of this request, so a late answer can never quit Claude
/// after the switch has walked away. Claude's log can go silent for hours, so the prompt is
/// also watched on screen and a silent log is never read as a Cancel at once.
struct QuitWatch {
    enum Outcome: Equatable { case quit, declined, failed }
    enum Step: Equatable {
        case wait(String)
        /// Press Quit anyway on the open prompt.
        case answer
        case done(Outcome)
    }

    /// Answer the prompt with Quit anyway instead of waiting for a person.
    let unattended: Bool
    /// Accessibility access, needed to press the prompt's button.
    var canAnswer: Bool
    let started: Date

    /// With no prompt and nothing in the log, Claude has ignored the request after this long.
    static let noPromptTimeout: TimeInterval = 90
    /// After Quit anyway, Claude's own cleanup and watchdog finish within this long.
    static let quittingTimeout: TimeInterval = 180
    /// With a working log, a closed prompt and no new quit means Cancel after this long.
    static let cancelSettle: TimeInterval = 3
    /// With a silent log, Cancel and Wait for Claude look the same; wait this long for a quit.
    static let undecidedTimeout: TimeInterval = 10 * 60

    private(set) var promptSeen = false
    private(set) var promptClosedAt: Date?
    private(set) var answeredAt: Date?

    init(unattended: Bool, canAnswer: Bool, started: Date) {
        self.unattended = unattended
        self.canAnswer = canAnswer
        self.started = started
    }

    /// Record that Quit anyway was pressed.
    mutating func answered(at date: Date) { answeredAt = date }

    mutating func step(_ o: QuitObservation, now: Date) -> Step {
        if !o.claudeRunning { return .done(.quit) }
        if o.promptOpen {
            promptSeen = true
            promptClosedAt = nil
            // Still open after a press means the press didn't land: press again.
            if unattended && canAnswer { return .answer }
            return .wait("Claude is asking whether to quit while a chat runs…")
        }
        if let answeredAt {
            return now.timeIntervalSince(answeredAt) > Self.quittingTimeout ? .done(.failed) : .wait("Claude is quitting…")
        }
        if promptSeen {
            let closed = promptClosedAt ?? now
            promptClosedAt = closed
            let since = now.timeIntervalSince(closed)
            if o.waitLogged { return .wait("Claude quits once its chats finish…") }
            if o.quitLoggedAfterVeto {
                return since > Self.quittingTimeout ? .done(.failed) : .wait("Claude is quitting…")
            }
            if o.vetoLogged { return since >= Self.cancelSettle ? .done(.declined) : .wait("Claude is quitting…") }
            return since >= Self.undecidedTimeout ? .done(.declined) : .wait("Waiting for Claude to quit…")
        }
        let elapsed = now.timeIntervalSince(started)
        if o.vetoLogged {
            return elapsed >= Self.noPromptTimeout ? .done(.declined) : .wait("Claude is asking whether to quit while a chat runs…")
        }
        return elapsed >= Self.noPromptTimeout ? .done(.failed) : .wait("Waiting for Claude to quit…")
    }
}

// MARK: - After the switch

/// A moved chat as the resume step sees it. Claude marks a chat whose reply a quit cut off
/// (`interruptedByQuitAt`) and resumes it itself, a few at once at launch and the rest when each
/// is opened. A chat a usage limit stopped has no mark: its turn already ended, so it waits for a
/// new message.
struct MovedChat: Equatable {
    let id: String
    let title: String
    let interrupted: Bool
    let lastActivity: Double
}

/// What the resume step sees of one chat in Claude's window, through Accessibility. Nil when no
/// window shows that chat.
struct ChatScreen: Equatable {
    /// The chat's page hasn't finished loading.
    var loading = false
    /// Its composer shows Stop: a turn is running.
    var busy: Bool
    /// Its message box was found. Claude shows Send only once the box holds text, so the box,
    /// not a send control, is what has to be there before the message is typed.
    var composer: Bool
    /// Its message box holds text someone typed and hasn't sent.
    var draft: Bool
}

enum ResumeRule {
    /// The new message each stopped chat gets.
    static let message = "resume"
    /// How long Claude gets to resume the chats a quit cut off on its own before the app opens them.
    static let ownPassWait: TimeInterval = 45
    /// How long an opened chat may take to show in Claude's window, finish loading and show its
    /// message box. Claude reopening with many sessions and long transcripts can take minutes.
    static let readyWait: TimeInterval = 120
    /// Claude resumes a chat a quit cut off when it is opened; this long after it shows, the app
    /// sends the message itself.
    static let resumeOnOpenWait: TimeInterval = 10
    /// How long a sent message may take to show a turn running.
    static let startWait: TimeInterval = 30
    /// A chat that isn't running after a pass is tried again this often, while nobody is using
    /// the Mac,
    static let retryEvery: TimeInterval = 60
    /// for this long after the switch; then the notification names it.
    static let retryFor: TimeInterval = 30 * 60

    enum Result: Equatable {
        /// Running without a message from the app: Claude resumed it, someone sent it a message,
        /// or it was already running.
        case running
        /// The app sent the message and Claude showed the turn start.
        case sent
        /// Someone has typed in its message box and not sent it: left to them.
        case draft
        /// Not running yet, for this reason; tried again until `retryFor` has passed.
        case notResumed(String)

        /// Running, or left to the person at the Mac: nothing more to try.
        var settled: Bool {
            if case .notResumed = self { return false }
            return true
        }

        var runningAgain: Bool { self == .running || self == .sent }
    }

    enum Step: Equatable {
        case wait
        case send
        case done(Result)
    }

    /// The chats to get running again: every moved chat that was working when the switch began,
    /// which is each one Claude stopped for usage (`stoppedByLimit`) and each one whose turn the
    /// quit cut off (Claude's mark, or `cutByQuit` from its log). Each once, most recently active
    /// first. A chat that was idle is left alone. A chat's subagents run inside it and stop with
    /// it, so the chat is the unit: its next turn starts them again.
    static func toResume(_ chats: [MovedChat], stoppedByLimit: Set<String>, cutByQuit: Set<String>) -> [MovedChat] {
        var seen = Set<String>()
        return chats.filter { chat in
            (chat.interrupted || cutByQuit.contains(chat.id) || stoppedByLimit.contains(chat.id)) && seen.insert(chat.id).inserted
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// A chat a quit cut off has resumed once Claude cleared its mark or it ran after Claude reopened.
    static func resumed(markStillSet: Bool, lastActivity: Double, reopenedAt: Double) -> Bool {
        !markStillSet || lastActivity > reopenedAt
    }

    /// What to do with one opened chat. `waited` counts from the open, `shownFor` from the moment
    /// its message box was first ready. Only an idle chat with an empty message box gets the
    /// message, so a running chat, a chat whose message box has someone's unsent text, and a chat
    /// Claude didn't show are never sent to.
    static func step(_ screen: ChatScreen?, interrupted: Bool, waited: TimeInterval, shownFor: TimeInterval?) -> Step {
        guard let screen else {
            return waited >= readyWait ? .done(.notResumed("Claude didn't show it")) : .wait
        }
        if screen.busy { return .done(.running) }
        guard screen.composer, !screen.loading else {
            let why = screen.loading ? "it was still loading" : "its message box wasn't found"
            return waited >= readyWait ? .done(.notResumed(why)) : .wait
        }
        if screen.draft { return .done(.draft) }
        if interrupted, (shownFor ?? 0) < resumeOnOpenWait { return .wait }
        return .send
    }

    /// Whether to make another pass at the chats still not running, `elapsed` after the first:
    /// while some are left and the pass would start within `retryFor`.
    static func tryAgain(left: Int, elapsed: TimeInterval) -> Bool {
        left > 0 && elapsed + retryEvery <= retryFor
    }

    /// Whether a pass after the first may open chats in Claude's window: only while nobody is
    /// using the Mac, so a person working in another chat isn't pulled away from it every minute.
    static func mayRetry(secondsSinceInput: TimeInterval) -> Bool {
        secondsSinceInput >= retryEvery
    }

    /// How many stopped chats run again, as the switch's message and notification say it.
    static func summary(running: Int, of total: Int) -> String {
        "Running again: \(running) of \(total) stopped chat\(total == 1 ? "" : "s")."
    }
}

/// Telling a chat's message box apart from the other editable text boxes on its page, such as a
/// side panel's address field. The box is found by what it is, not by one layout.
enum ComposerRule {
    /// One editable text box, as Accessibility describes it.
    struct Box: Equatable {
        /// Its name, description or placeholder is "Prompt", as Claude names its message box.
        var named: Bool
        /// A text area rather than a one-line field: a message box takes several lines.
        var multiline: Bool
        /// It has keyboard focus.
        var focused: Bool
    }

    enum FoundBy: String, Equatable {
        case name = "the text box named Prompt"
        case multiline = "the only multi-line text box"
        case focus = "the multi-line text box with keyboard focus"
    }

    /// The message box among `boxes`: the one named Prompt; else the only multi-line one; else
    /// the multi-line one with keyboard focus. When some are named Prompt, only those are
    /// weighed. A one-line field without that name, such as a side panel's address bar, is never
    /// the message box. Nil when there is none or no single one stands out, so the app never
    /// types into a box it isn't sure of.
    static func pick(_ boxes: [Box]) -> (index: Int, by: FoundBy)? {
        let named = boxes.indices.filter { boxes[$0].named }
        if named.count == 1 { return (named[0], .name) }
        let pool = (named.isEmpty ? Array(boxes.indices) : named).filter { boxes[$0].multiline }
        if pool.count == 1 { return (pool[0], named.isEmpty ? .multiline : .name) }
        let focused = pool.filter { boxes[$0].focused }
        if focused.count == 1 { return (focused[0], .focus) }
        return nil
    }
}
