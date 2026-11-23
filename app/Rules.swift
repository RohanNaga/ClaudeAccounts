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

    /// A row saved before organizations were tracked, whose organization no saved login names
    /// (13a.4). It needs sign-in, and Set Up learns its organization from the pair Claude holds.
    var orgUnknown: Bool { org.isEmpty }

    /// The pair Claude holds stands for this seat: the same pair, or, for a seat whose
    /// organization is not known yet, the same account in any organization.
    func matches(_ held: Identity) -> Bool { held == self || (orgUnknown && held.account == account) }
}

/// One row in the menu: one Claude login for one account in one organization.
/// An account that belongs to two organizations has two rows, one per organization.
struct AccountRecord: Codable, Identifiable, Equatable {
    let id: String
    /// The account's name, the same on every row of the account.
    var name: String
    /// No longer shown (rows have no colours). Still written so an older version can read the file.
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

    /// The key of this row's seat in the menu: its pair, or, while its organization is unknown,
    /// its account with an empty organization (13a.4).
    var seat: Identity { identity ?? Identity(account: accountUuid ?? id, org: "") }

    /// This row is the account's own personal organization, which Claude names after its email.
    var isPersonal: Bool { isPersonalOrganization(orgName) }
}

/// Claude names an account's own personal organization "<email>'s Organization".
func isPersonalOrganization(_ orgName: String?) -> Bool {
    guard let orgName else { return false }
    return orgName.contains("@") || orgName.hasSuffix("'s Organization") || orgName.hasSuffix("\u{2019}s Organization")
}

/// The app calls an account's personal organization "Individual". A team organization keeps its
/// name.
func defaultOrganizationName(_ orgName: String?) -> String {
    guard let orgName, !orgName.isEmpty else { return "Organization" }
    return isPersonalOrganization(orgName) ? "Individual" : orgName
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

// MARK: - Usage

/// One usage window from Claude's usage service: how much of it is used and when it resets.
struct UsageWindow: Equatable {
    /// Percent used as the usage service reports it, unrounded; "out" is decided on this.
    let utilization: Double
    let resetsAt: Date?

    init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

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

/// Which seats the automatic switch tries first. Within each group, the menu's order decides.
enum SwitchOrder: String, Codable, CaseIterable, Identifiable {
    case topToBottom, personalFirst, organizationsFirst
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topToBottom: return "Top to Bottom"
        case .personalFirst: return "Personal First"
        case .organizationsFirst: return "Organizations First"
        }
    }
}

/// Menu preferences, kept in settings.json in the app's state folder.
struct AppSettings: Codable, Equatable {
    var display: MenuBarDisplay = .gaugeNamePercent
    var metric: UsageMetric = .fiveHour
    /// Switch by itself when the account in use runs out of usage.
    var autoSwitch = true
    var switchOrder: SwitchOrder = .topToBottom
    /// Accounts whose organizations the menu folds under the account's name. Empty at first, so
    /// every organization shows.
    var collapsed: Set<String> = []

    init() {}

    /// Each key is optional, so a settings file from an older version keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(MenuBarDisplay.self, forKey: .display) ?? .gaugeNamePercent
        metric = try c.decodeIfPresent(UsageMetric.self, forKey: .metric) ?? .fiveHour
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? true
        switchOrder = try c.decodeIfPresent(SwitchOrder.self, forKey: .switchOrder) ?? .topToBottom
        collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
    }

    /// Whether the menu shows the organizations of `account`.
    func showsOrganizations(of account: String) -> Bool { !collapsed.contains(account) }

    /// Show or fold away the organizations of `account`.
    mutating func setShowsOrganizations(of account: String, _ shown: Bool) {
        if shown { collapsed.remove(account) } else { collapsed.insert(account) }
    }
}

// MARK: - Following a quit request

/// What the switch sees each time it looks while Claude decides whether to quit: the process and
/// its windows only. Claude's log is not read here; it was once silent through a whole prompt.
struct QuitObservation: Equatable {
    var claudeRunning: Bool
    /// One of Claude's alerts or sheets is on screen, found through Accessibility or as a new window.
    var promptOpen: Bool
}

/// Follows one quit request to its end (model, section 6, step 2). A manual switch waits for the
/// person to answer Claude's prompt. An automatic one presses Quit anyway, and after
/// `Limits.autoQuitWait` cancels the prompt and stops. A prompt that closed while Claude still runs
/// is the person's Cancel.
struct QuitWatch {
    enum Outcome: Equatable { case quit, declined, failed }
    enum Step: Equatable {
        case wait(String)
        /// Press Quit anyway on the open prompt.
        case answer
        /// Press Cancel on the open prompt: an automatic switch gives up.
        case cancel
        case done(Outcome)
    }

    /// Answer the prompt with Quit anyway instead of waiting for a person.
    let unattended: Bool
    /// Accessibility access, needed to press the prompt's button.
    var canAnswer: Bool
    let started: Date

    /// With no prompt, Claude has ignored the request after this long.
    static let noPromptTimeout: TimeInterval = 90
    /// A prompt that closed with Claude still running this long was cancelled. Quit anyway ends
    /// the process within a few seconds, so this leaves it room.
    static let cancelSettle: TimeInterval = 10

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
        if unattended, now.timeIntervalSince(started) >= Limits.autoQuitWait {
            return o.promptOpen ? .cancel : .done(.failed)
        }
        if o.promptOpen {
            promptSeen = true
            promptClosedAt = nil
            // Still open after a press means the press didn't land: press again.
            if unattended && canAnswer { return .answer }
            return .wait("Claude is asking whether to quit while a chat runs…")
        }
        if answeredAt != nil { return .wait("Claude is quitting…") }
        if promptSeen {
            let closed = promptClosedAt ?? now
            promptClosedAt = closed
            return now.timeIntervalSince(closed) >= Self.cancelSettle ? .done(.declined) : .wait("Claude is quitting…")
        }
        return now.timeIntervalSince(started) >= Self.noPromptTimeout ? .done(.failed) : .wait("Waiting for Claude to quit…")
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
    static let retryEvery = Limits.resumeEvery
    /// for this long after the switch; then the notification names it.
    static let retryFor = Limits.resumeFor

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

// MARK: - The model
//
// One seat is one Claude account in one organization, keyed by the pair (Identity). Every state
// the menu shows comes from `seatState` and `AppState`, which read the facts below fresh and
// store no guesses. The only stored memories are facts: saved logins, meter readings, the time
// Claude stopped a chat for usage on a seat, a target whose switch failed, and the switch journal.

/// Every time and length the model waits on, each with its reason.
enum Limits {
    /// Claude refuses a too-old sign-in 4 to 21 s after naming the organization, then falls back
    /// to the personal one; three times the slowest fall-back seen. A hold this old is settled:
    /// its login may be saved, and a stop or a wrap-up counts against it.
    static let settle: TimeInterval = 60
    /// An older reading can't choose an automatic target.
    static let freshness: TimeInterval = 15 * 60
    /// At most one usage read per seat per minute for the wrap-up check.
    static let meterOnTurnEnd: TimeInterval = 60
    /// Background meter refresh.
    static let meterEvery: TimeInterval = 5 * 60
    /// Every reset time schedules a read this long after it.
    static let meterAfterReset: TimeInterval = 60
    /// A target whose switch failed is skipped this long, so a failure never repeats in a loop.
    static let coolDown: TimeInterval = 10 * 60
    /// A stop with no reset ahead counts the seat out this long: the shorter usage window.
    static let outWithoutReset: TimeInterval = 5 * 3600
    /// An unattended switch that can't get Claude to quit this long cancels and stops. A manual
    /// switch has no limit: the person answers Claude's prompt.
    static let autoQuitWait: TimeInterval = 3 * 60
    /// Time for a relaunched Claude to name and settle on the target.
    static let confirmWait: TimeInterval = 3 * 60
    /// Set Up waits for a person to sign in.
    static let setUpConfirmWait: TimeInterval = 10 * 60
    /// A chat not on screen, or still running, is retried this often for this long, then named.
    static let resumeEvery: TimeInterval = 60
    static let resumeFor: TimeInterval = 30 * 60
    /// A meter at or above this is out.
    static let full: Double = 100
}

/// One usage meter as read from the usage service.
struct MeterReading: Equatable, Codable {
    var percent: Double
    var resetsAt: Date?
}

/// A seat's meters; nil readAt means not read yet.
struct SeatMeters: Equatable, Codable {
    var fiveHour: MeterReading?
    var weekly: MeterReading?
    var readAt: Date?
    /// Set when the Mac wakes: the reading stays on the row but is no longer fresh, so it can't
    /// choose or rule out an automatic target until the next reading replaces it.
    var wokeSince: Date?

    /// The fuller of the two meters: the one a compact row and the menu bar show.
    var fuller: MeterReading? { [fiveHour, weekly].compactMap { $0 }.max { $0.percent < $1.percent } }
    func isFresh(at now: Date) -> Bool { wokeSince == nil && (readAt.map { now.timeIntervalSince($0) < Limits.freshness } ?? false) }
    func isStale(at now: Date) -> Bool { readAt != nil && !isFresh(at: now) }

    /// Fresh, and no reset of its own has passed since it was read: the only reading the automatic
    /// switch acts on. Once a reset passes, the seat is read again before anything is decided on it
    /// (model, section 7: reset time passes, read the meter, then resume in place or switch).
    func isCurrent(at now: Date) -> Bool {
        guard isFresh(at: now), let readAt else { return false }
        return ![fiveHour, weekly].contains { m in m?.resetsAt.map { $0 > readAt && $0 <= now } ?? false }
    }

    /// "not read yet", "read 40 min ago", or nil while fresh.
    func readText(at now: Date) -> String? {
        guard let readAt else { return "not read yet" }
        guard !isFresh(at: now) else { return nil }
        let minutes = Int(now.timeIntervalSince(readAt) / 60)
        return minutes < 120 ? "read \(minutes) min ago" : "read \(minutes / 60) h ago"
    }

    /// A fresh reading with a full meter whose reset is still ahead: out until that reset.
    func fullUntil(at now: Date) -> Date? {
        guard isFresh(at: now) else { return nil }
        return [fiveHour, weekly].compactMap { $0 }
            .filter { $0.percent >= Limits.full }
            .compactMap { m in m.resetsAt.flatMap { $0 > now ? $0 : nil } }.max()
    }

    /// Any meter at or above full on this reading, fresh or not.
    var showsFull: Bool { [fiveHour, weekly].contains { ($0?.percent ?? 0) >= Limits.full } }
}

/// Claude stopped a chat for usage while holding a seat settled; `resetsAt` is from the reading
/// taken at that stop. The one stored memory of section 4, a fact per pair.
struct StopMark: Equatable, Codable {
    var at: Date
    var resetsAt: Date?
    var until: Date { resetsAt.flatMap { $0 > at ? $0 : nil } ?? at.addingTimeInterval(Limits.outWithoutReset) }
}

// MARK: Claude's log as events

/// The facts Claude's main.log states, in order, each line by its own time.
enum LogEvent: Equatable {
    case named(Identity), refused(Identity), newRun, signedOut
    case turnEnded(chat: String), limitStop(chat: String), cutByQuit(chat: String)
}

/// One event with the seat Claude held when it was logged and how long it had held it.
struct StampedEvent: Equatable {
    let event: LogEvent
    let at: Date
    let held: Identity?
    let heldFor: TimeInterval
    /// Logged on a settled hold: a stop or a wrap-up here counts against `held`.
    var settled: Bool { held != nil && heldFor >= Limits.settle }
}

/// Claude holds a seat from the time its log names that pair; a refusal of the pair starts the
/// hold over.
struct Hold: Equatable {
    let seat: Identity
    let since: Date
    func settled(at now: Date) -> Bool { now.timeIntervalSince(since) >= Limits.settle }
}

/// Claude's log read in order into events, the seat it holds, and the last refusal per pair.
struct ClaudeEvents {
    private(set) var events: [StampedEvent] = []
    private(set) var hold: Hold?
    private(set) var refusedAt: [Identity: Date] = [:]

    mutating func read(_ text: String) {
        for line in text.split(separator: "\n") {
            guard let at = Self.time(line), let event = Self.event(line, held: hold?.seat) else { continue }
            events.append(StampedEvent(event: event, at: at, held: hold?.seat,
                                       heldFor: hold.map { at.timeIntervalSince($0.since) } ?? 0))
            switch event {
            case .named(let seat): if hold?.seat != seat { hold = Hold(seat: seat, since: at) }
            case .refused(let seat):
                refusedAt[seat] = at
                if hold?.seat == seat { hold = Hold(seat: seat, since: at) }
            case .newRun, .signedOut: hold = nil
            case .turnEnded, .limitStop, .cutByQuit: break
            }
        }
    }

    /// Chats in the current run (since the last NewRun) whose last word was a usage stop or a cut
    /// by quit: the chats a switch resumes. A healthy turn after either clears it.
    var stoppedChats: (byLimit: Set<String>, byQuit: Set<String>) {
        var limit = Set<String>(), quit = Set<String>()
        for e in events {
            switch e.event {
            case .newRun, .signedOut: limit = []; quit = []
            case .named(let s) where e.held != s: limit = []; quit = []
            case .limitStop(let c): limit.insert(c)
            case .cutByQuit(let c): quit.insert(c)
            case .turnEnded(let c): limit.remove(c); quit.remove(c)
            default: break
            }
        }
        return (limit, quit)
    }

    /// The last settled TurnEnded on `seat`: a reading after it at 100 means the seat wrapped up.
    /// Log lines carry whole seconds: an event stamped S happened within [S, S+1), so a reading
    /// is after it only from S+1 on.
    static func readAfter(_ logged: Date, readAt: Date) -> Bool { readAt >= logged.addingTimeInterval(1) }

    /// Chats whose turn ended, settled, on `seat` and not before `since`: the turns a wrap-up ended.
    func turnsEnded(on seat: Identity, since: Date) -> Set<String> {
        Set(events.compactMap { e in
            guard case .turnEnded(let chat) = e.event, e.held == seat, e.settled, !Self.readAfter(e.at, readAt: since) else { return nil }
            return chat
        })
    }

    /// Chats whose last word in the log is a usage stop logged while Claude held `seat`. Unlike
    /// `stoppedChats`, a restart of Claude, or a switch undone back to `seat`, does not clear them.
    func stoppedForUsage(on seat: Identity) -> Set<String> {
        var last: [String: StampedEvent] = [:]
        for e in events {
            switch e.event {
            case .limitStop(let c), .turnEnded(let c), .cutByQuit(let c): last[c] = e
            default: break
            }
        }
        return Set(last.compactMap { chat, e in
            if case .limitStop = e.event, e.held == seat { return chat } else { return nil }
        })
    }

    /// When the log last said anything of `chat`: a turn that ended, a usage stop or a cut by quit.
    func lastWord(of chat: String) -> Date? {
        events.last { e in
            switch e.event {
            case .turnEnded(let c), .limitStop(let c), .cutByQuit(let c): return c == chat
            default: return false
            }
        }?.at
    }

    func lastTurnEnd(on seat: Identity) -> Date? {
        events.last { e in if case .turnEnded = e.event { return e.held == seat && e.settled }; return false }?.at
    }

    static func event<S: StringProtocol>(_ line: S, held: Identity?) -> LogEvent? {
        if line.contains(ClaudeLog.identity), let a = field(line, ClaudeLog.accountField), let o = field(line, ClaudeLog.orgField) {
            return .named(Identity(account: a, org: o))
        }
        if line.contains(ClaudeLog.refusal), let held {
            let org = field(line, ClaudeLog.orgField) ?? held.org
            return .refused(Identity(account: held.account, org: org))
        }
        if line.contains(ClaudeLog.appStart) { return .newRun }
        if ClaudeLog.signOut.contains(where: { line.contains($0) }) { return .signedOut }
        guard line.contains(ClaudeLog.cycle) else { return nil }
        if let c = session(after: ClaudeLog.healthyCycle, in: line) { return .turnEnded(chat: c) }
        if let c = session(after: ClaudeLog.unhealthyCycle, in: line), line.contains(ClaudeLog.quitReason) { return .cutByQuit(chat: c) }
        if let c = session(after: ClaudeLog.cycle, in: line), line.contains(ClaudeLog.apiError),
           ClaudeLog.limitTexts.contains(where: { line.contains($0) }) { return .limitStop(chat: c) }
        return nil
    }

    static func time<S: StringProtocol>(_ line: S) -> Date? { timeFormat.date(from: String(line.prefix(19))) }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = ClaudeLog.timeFormat
        return f
    }()

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

// MARK: Facts

/// A shape of Claude's that the app checks each time it relies on it (model, section 8). A missing
/// shape is never acted on, and switching on its own pauses until that shape is seen whole again.
/// Claude's version plays no part: an update that changes nothing the app reads changes nothing.
enum ClaudeShape: String, Codable, CaseIterable, Comparable {
    /// A Named line in Claude's log after a launch the app made.
    case namedLine
    /// The Quit anyway button on Claude's quit prompt.
    case quitButton
    /// The schema of Claude's cookie database.
    case cookieSchema

    /// Why switching on its own is paused, as the person reads it.
    var why: String {
        switch self {
        case .namedLine: return "Claude opened without saying which account it's on"
        case .quitButton: return "Claude's quit prompt has no Quit anyway button"
        case .cookieSchema: return "Claude's sign-in file is in a format this app doesn't know"
        }
    }

    static func < (a: ClaudeShape, b: ClaudeShape) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Claude as a process: installed (F1), running (F1), and the shapes the app found missing and
/// has not seen whole since.
struct ClaudeFacts: Equatable {
    var installed = true
    var running = false
    var missing: Set<ClaudeShape> = []
}

/// The switch in progress, from its journal (F7).
struct SwitchFacts: Equatable {
    var target: Identity
    var step: String
    /// A line that replaces the step for a moment, such as a second request refused.
    var note: String? = nil
}

/// Everything the model reads, read fresh. Nothing in here is inferred.
struct Facts {
    /// F9: the seats, in the person's order.
    var rows: [AccountRecord] = []
    var claude = ClaudeFacts()
    /// F3.
    var log = ClaudeEvents()
    /// F4: when each pair's saved login was proven.
    var saved: [Identity: Date] = [:]
    /// F5, per seat: each seat reads usage through its own Claude Code sign-in.
    var meters: [Identity: SeatMeters] = [:]
    var stops: [Identity: StopMark] = [:]
    /// When an automatic switch to each pair last failed.
    var failedTargets: [Identity: Date] = [:]
    /// F7.
    var switching: SwitchFacts?
    /// F8.
    var trusted = false
    /// The person's Auto-Switch choice.
    var autoChosen = true
    /// The person's order for the automatic switch.
    var order: SwitchOrder = .topToBottom
    /// Chats stopped for usage or wrapped up that wait for a seat with room.
    var waitingChats = 0

    /// The seat Claude holds, while it runs.
    var hold: Hold? { claude.running ? log.hold : nil }
}

// MARK: One function: state of a seat

enum SeatState: Equatable {
    case switching(step: String), inUse, needsSignIn, out(resetsAt: Date?), ready
}

/// The one function that decides what a row shows and does (model, section 3).
func seatState(_ seat: Identity, _ f: Facts, now: Date) -> SeatState {
    if let s = f.switching, s.target == seat { return .switching(step: s.step) }
    if f.hold?.seat == seat { return .inUse }
    guard let savedAt = f.saved[seat], !(f.log.refusedAt[seat].map { $0 > savedAt } ?? false) else { return .needsSignIn }
    if let until = OutRule.until(seat, f, now: now) { return .out(resetsAt: until) }
    return .ready
}

/// Section 4: a seat is out on a fresh full meter whose reset is ahead, or after a settled usage
/// stop until the reset of the reading taken at that stop.
enum OutRule {
    static func until(_ seat: Identity, _ f: Facts, now: Date) -> Date? {
        let byMeter = f.meters[seat]?.fullUntil(at: now)
        let byStop = f.stops[seat].map(\.until).flatMap { $0 > now ? $0 : nil }
        return [byMeter, byStop].compactMap { $0 }.max()
    }
}

// MARK: The automatic switch

enum AutoSwitch {
    enum Status: Equatable { case on, offAccessibility, offShapeMissing(ClaudeShape), offByPerson }

    static func status(_ f: Facts) -> Status {
        if !f.autoChosen { return .offByPerson }
        if let shape = f.claude.missing.min() { return .offShapeMissing(shape) }
        if !f.trusted { return .offAccessibility }
        return .on
    }

    enum Decision: Equatable {
        case none
        case switchTo(Identity)
        /// Every seat is out; `resumesAt` is the earliest known reset, at `seat`.
        case wait(seat: Identity?, resumesAt: Date?)
        case resumeInPlace
    }

    /// Claude itself showed the settled seat in use is done: a settled limit stop (recorded as a
    /// StopMark), or a settled turn end followed by a later, current reading at 100. A meter alone never is.
    static func isDone(_ seat: Identity, _ f: Facts, now: Date) -> Bool {
        if let mark = f.stops[seat], mark.until > now { return true }
        guard let ended = f.log.lastTurnEnd(on: seat), let m = f.meters[seat], let readAt = m.readAt,
              ClaudeEvents.readAfter(ended, readAt: readAt), m.isCurrent(at: now), m.showsFull else { return false }
        return true
    }

    /// A current reading with room, taken once the seat's last stop had run out (section 4: the
    /// reset is read a minute later, then the chats resume). A stop mark running out is not room by itself.
    static func hasRoom(_ seat: Identity, _ f: Facts, now: Date) -> Bool {
        guard let m = f.meters[seat], let readAt = m.readAt, m.isCurrent(at: now), !m.showsFull else { return false }
        return readAt >= f.stops[seat]?.until ?? .distantPast
    }

    /// The order the automatic switch tries the other seats in: down the menu from `from`,
    /// wrapping round, with the personal seats or the organization seats first when the person
    /// chose so. This is the only place that order is decided.
    static func order(from: Identity, _ f: Facts) -> [Identity] {
        let rows = f.rows.filter { $0.identity != nil }
        guard let i = rows.firstIndex(where: { $0.identity == from }) else { return [] }
        let round = rows[(i + 1)...] + rows[..<i]
        let ordered: [AccountRecord]
        switch f.order {
        case .topToBottom: ordered = Array(round)
        case .personalFirst: ordered = round.filter(\.isPersonal) + round.filter { !$0.isPersonal }
        case .organizationsFirst: ordered = round.filter { !$0.isPersonal } + round.filter(\.isPersonal)
        }
        return ordered.compactMap(\.identity)
    }

    /// In that order, the first Ready seat with a current reading that has not failed as a target
    /// within coolDown.
    static func target(from: Identity, _ f: Facts, now: Date) -> Identity? {
        order(from: from, f).first { s in
            seatState(s, f, now: now) == .ready && (f.meters[s]?.isCurrent(at: now) ?? false)
                && !(f.failedTargets[s].map { now.timeIntervalSince($0) < Limits.coolDown } ?? false)
        }
    }

    /// The seat the automatic switch would move to if the seat Claude holds ran out now; the
    /// menu marks it Next. Nil while automatic switching is off or Claude holds no seat.
    static func next(_ f: Facts, now: Date) -> Identity? {
        guard status(f) == .on, f.switching == nil, let seat = f.hold?.seat else { return nil }
        return target(from: seat, f, now: now)
    }

    static func decide(_ f: Facts, now: Date) -> Decision {
        guard status(f) == .on, f.switching == nil, let hold = f.hold, hold.settled(at: now),
              f.rows.contains(where: { $0.identity == hold.seat }) else { return .none }
        guard isDone(hold.seat, f, now: now) else {
            return f.waitingChats > 0 && hasRoom(hold.seat, f, now: now) ? .resumeInPlace : .none
        }
        if let t = target(from: hold.seat, f, now: now) { return .switchTo(t) }
        let resets = f.rows.compactMap(\.identity).compactMap { s in OutRule.until(s, f, now: now).map { (s, $0) } }
        let first = resets.min { $0.1 < $1.1 }
        return .wait(seat: first?.0, resumesAt: first?.1)
    }
}

// MARK: Seats and the notice, as the menu reads them

enum SeatAction: Equatable { case switchTo, setUp }

struct Seat: Equatable, Identifiable {
    let id: Identity
    /// Unique label: the name, then " · <organization>", then " (2)".
    let name: String
    let accountName: String
    let organization: String
    let state: SeatState
    let meters: SeatMeters
    let action: SeatAction?
    /// The automatic switch would move here next (AutoSwitch.next).
    let isNext: Bool
}

enum Seats {
    static func build(_ f: Facts, now: Date) -> [Seat] {
        let rows = f.rows
        let labels = unique(rows.map { ($0.label.isEmpty ? $0.name : $0.label, $0.organization) })
        let next = AutoSwitch.next(f, now: now)
        return zip(rows, labels).map { row, label in
            let id = row.seat
            let state = seatState(id, f, now: now)
            let action: SeatAction?
            switch state {
            case .switching, .inUse: action = nil
            case .needsSignIn: action = f.claude.installed && f.switching == nil ? .setUp : nil
            case .out, .ready: action = f.claude.installed && f.switching == nil ? .switchTo : nil
            }
            return Seat(id: id, name: label, accountName: f.rows.accountName(for: row), organization: row.organization,
                        state: state, meters: f.meters[id] ?? SeatMeters(), action: action, isNext: id == next)
        }
    }

    /// Equal names get " · <organization>"; still equal, " (2)", " (3)". Never an email.
    static func unique(_ named: [(name: String, org: String)]) -> [String] {
        let counts = Dictionary(named.map { ($0.name, 1) }, uniquingKeysWith: +)
        var labels = named.map { counts[$0.name]! > 1 ? "\($0.name) · \($0.org)" : $0.name }
        var seen: [String: Int] = [:]
        for i in labels.indices {
            seen[labels[i], default: 0] += 1
            if seen[labels[i]]! > 1 { labels[i] += " (\(seen[labels[i]]!))" }
        }
        return labels
    }
}

enum NoticeAction: Equatable { case openAccessibility, addSeat }

struct Notice: Equatable {
    /// Lower is more important; the menu shows only the first.
    enum Kind: Int, Comparable {
        case switching, failure, waiting, accessibility, shapeMissing, claude, success
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    let kind: Kind
    let text: String
    var detail: String? = nil
    var action: NoticeAction? = nil
}

/// What the first-run screen says. Shown exactly while there are no rows.
enum FirstRun {
    static let title = "Claude Accounts"
    static let lines = [
        "Shows each of your Claude seats and how much usage it has left.",
        "Switches Claude to another seat when you ask, or on its own when the one in use runs out, then resumes your chats.",
        "It reads Claude's log and chat list, and keeps a copy of each seat's sign-in in its own folder on this Mac.",
        "Nothing leaves this Mac. Its one network call reads each seat's usage from Anthropic.",
    ]
    static let waiting = "Open Claude and sign in. Your seat appears here a minute later."
}

enum AppState {
    /// The one notice: the most important of every line that applies (model, section 11).
    /// `failure` and `success` are the last switch's outcome; `finishing` is the line of a journal
    /// that waits for Claude to open or to close.
    static func notice(_ f: Facts, now: Date, failure: String? = nil, success: String? = nil, finishing: String? = nil) -> Notice? {
        var all: [Notice] = []
        let name = { (s: Identity?) in f.rows.first { $0.seat == s && s != nil }.map { $0.label.isEmpty ? $0.name : $0.label } }
        if let s = f.switching {
            all.append(finishing.map { Notice(kind: .switching, text: $0) }
                       ?? Notice(kind: .switching, text: s.note ?? "Switching to \(name(s.target) ?? "a seat")… \(s.step)"))
        }
        if let failure { all.append(Notice(kind: .failure, text: failure)) }
        if case .wait(let seat, let at) = AutoSwitch.decide(f, now: now), f.waitingChats > 0 {
            let when = at.map { " at \(ClockText.time($0))" } ?? ""
            if f.rows.compactMap(\.identity).count == 1 {
                all.append(Notice(kind: .waiting, text: "\(name(seat) ?? "Your seat") is out. Chats resume when it resets\(when)."))
            } else {
                all.append(Notice(kind: .waiting, text: "Every seat is out. Chats resume\(when).",
                                  detail: "Every seat is out. Chats resume when \(name(seat) ?? "a seat") resets\(when)."))
            }
        }
        if !f.trusted {
            all.append(Notice(kind: .accessibility, text: "Allow Accessibility to switch on its own.",
                              detail: "Allow Accessibility so Claude Accounts can switch on its own and resume chats.",
                              action: .openAccessibility))
        }
        if let shape = f.claude.missing.min() {
            all.append(Notice(kind: .shapeMissing, text: "Switching on its own is paused. \(shape.why).",
                              detail: "Switching on its own is paused. \(shape.why). It turns back on by itself once that changes."))
        }
        if !f.claude.installed { all.append(Notice(kind: .claude, text: "Claude isn't installed.")) }
        else if !f.claude.running { all.append(Notice(kind: .claude, text: "Claude isn't running.")) }
        else if let hold = f.hold, hold.settled(at: now), !f.rows.contains(where: { $0.identity == hold.seat }), !f.rows.isEmpty {
            all.append(Notice(kind: .claude, text: "Claude is on an account not in the list.", action: .addSeat))
        }
        if let success { all.append(Notice(kind: .success, text: success)) }
        return all.min { $0.kind < $1.kind }
    }
}

/// A time as the menu says it, in the person's own format ("3:40 PM").
enum ClockText {
    static func time(_ date: Date) -> String { DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short) }
}
