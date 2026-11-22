// The decisions behind switching, kept free of AppKit, files and the network so the tests in
// tests/RulesTests.swift drive them directly: which account a Claude identity belongs to, what
// Claude's log says, when auto-switch moves and to which account, how a quit request is followed
// to its end, and which stopped chats get a new message after a switch.

import Foundation

// MARK: - Accounts and identities

/// The account Claude is signed in to and the organization whose Code sessions it shows.
struct Identity: Equatable, Codable, Sendable {
    let account: String
    let org: String
}

/// One row in the menu: one Claude login for one account in one organization.
/// An account that belongs to two organizations has two rows, one per organization.
struct AccountRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var color: String
    var configDir: String
    var keychainService: String
    let email: String?
    let accountUuid: String?
    var orgName: String?
    /// The organization this row stands for. Older rows lack it until it is filled in on load.
    var orgUuid: String?

    var configURL: URL { URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath) }

    /// The label without its domain, for the menu bar where space is tight.
    var shortName: String { name.split(separator: "@").first.map(String.init) ?? name }
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

    /// The organizations of `account` that Claude has opened (`opened`, with how many chats
    /// each holds) but no row stands for yet, most used first.
    func organizationsToAdd(account: String, opened: [(org: String, chats: Int)]) -> [String] {
        let added = Set(filter { $0.accountUuid == account }.compactMap(\.orgUuid))
        return opened.filter { !added.contains($0.org) }.sorted { $0.chats > $1.chats }.map(\.org)
    }
}

/// The label for a new row: the email, with the organization added when the account already
/// has a row, so its two organizations read apart.
func rowName(email: String?, orgName: String?, accountAlreadyAdded: Bool, fallback: String) -> String {
    [email ?? fallback, accountAlreadyAdded ? orgName : nil].compactMap { $0 }.joined(separator: " · ")
}

// MARK: - Auto-switch

/// One row as the auto-switch rule sees it.
struct SwitchCandidate: Equatable {
    let id: String
    let name: String
    /// Percent used, unrounded; nil when the window hasn't started, which counts as nothing used.
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

    /// The fuller of the two meters.
    var used: Double { Swift.max(fiveHour ?? 0, weekly ?? 0) }

    /// Out of usage: a meter at its limit, compared unrounded, or a switch left this row and its
    /// reset hasn't come yet.
    func isOut(at now: Date) -> Bool { used >= AutoSwitchRule.limit || (outUntil.map { now < $0 } ?? false) }
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
    /// Claude's log). The meters never start a switch; they choose the target, the set-up
    /// account with the most room, and rule out any account that is out.
    static func decide(current: SwitchCandidate?, others: [SwitchCandidate], enabled: Bool, limitStopped: Bool,
                       claudeRunning: Bool, lastAttempt: Date?, now: Date) -> Decision {
        guard enabled else { return .stay("Auto-switch is off.") }
        guard let current else { return .stay("Claude isn't using an account this app knows.") }
        guard limitStopped else { return .stay("Claude hasn't stopped a chat of \(current.name) at its usage limit.") }
        guard claudeRunning else { return .stay("Claude isn't running.") }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < coolDown {
            return .stay("\(current.name) is out, but the last try was under \(Int(coolDown / 60)) minutes ago; next try after \(clock(lastAttempt.addingTimeInterval(coolDown))).")
        }
        let eligible = others.filter {
            $0.id != current.id && $0.hasSavedLogin && !$0.needsSignIn && fresh($0, now) && !$0.isOut(at: now)
        }
        guard let best = eligible.min(by: { a, b in
            if a.used != b.used { return a.used < b.used }
            if (a.weekly ?? 0) != (b.weekly ?? 0) { return (a.weekly ?? 0) < (b.weekly ?? 0) }
            return a.name < b.name
        }) else {
            return .nowhere("Claude stopped a chat at \(current.name)'s usage limit, and no other set-up account has room. Chats wait until a limit resets.")
        }
        return .switchTo(id: best.id, reason: "Claude stopped a chat at \(current.name)'s usage limit; \(best.name) is at \(percent(best.used)).")
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
    /// Chats whose turn was still running when Claude quit.
    private(set) var cutByQuit: Set<String> = []

    /// Claude's own messages for a turn refused because the account is out of usage.
    static let outOfUsage = [
        "You've hit your", "You've reached your", "You're out of usage credits", "You're out of extra usage",
        "Your org is out of usage", "Your seat type doesn't include", "Your usage allocation has been disabled",
        "Your group's usage limit is set to $0", "requires usage credits",
    ]

    init(identity: Identity? = nil) { self.identity = identity }

    mutating func read(_ text: String) {
        for line in text.split(separator: "\n") {
            if line.contains("[LocalSessionManager] Initialization succeeded"),
               let account = Self.field(line, "accountId="), let org = Self.field(line, "orgId=") {
                let named = Identity(account: account, org: org)
                if named != identity { stoppedByLimit = []; cutByQuit = [] }
                identity = named
            } else if line.contains("Starting app {") || Self.signsOut(line) {
                identity = nil
                stoppedByLimit = []
                cutByQuit = []
            } else if line.contains("[CCD CycleHealth] ") {
                if let id = Self.session(after: "[CCD CycleHealth] healthy cycle for ", in: line) {
                    stoppedByLimit.remove(id)
                    cutByQuit.remove(id)
                } else if let id = Self.session(after: "[CCD CycleHealth] unhealthy cycle for ", in: line) {
                    if line.contains("reason=app_quit") { cutByQuit.insert(id) }
                } else if let id = Self.session(after: "[CCD CycleHealth] ", in: line), line.contains(" api_error ("),
                          Self.outOfUsage.contains(where: { line.contains($0) }) {
                    stoppedByLimit.insert(id)
                }
            }
        }
    }

    /// Who Claude says it is after reading `text`, starting from `start`.
    static func identity(after text: String, from start: Identity?) -> Identity? {
        var follower = LogFollower(identity: start)
        follower.read(text)
        return follower.identity
    }

    static func signsOut<S: StringProtocol>(_ line: S) -> Bool {
        line.contains("Navigated to /logout") || line.contains("loggedOut: false \u{2192} true")
    }

    private static func field<S: StringProtocol>(_ line: S, _ key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let value = line[r.upperBound...].prefix { $0.isHexDigit || $0 == "-" }
        return value.count == 36 ? String(value) : nil
    }

    private static func session<S: StringProtocol>(after marker: String, in line: S) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        let id = line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return id.hasPrefix("local_") ? String(id) : nil
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
    /// Its composer shows Stop: a turn is running.
    var busy: Bool
    /// Its message box and its send control were both found.
    var composer: Bool
    /// Its message box holds text someone typed and hasn't sent.
    var draft: Bool
}

enum ResumeRule {
    /// The new message each stopped chat gets.
    static let message = "resume"
    /// How long Claude gets to resume the chats a quit cut off on its own before the app opens them.
    static let ownPassWait: TimeInterval = 45
    /// How long an opened chat may take to show in Claude's window with its message box.
    static let showWait: TimeInterval = 20
    /// Claude resumes a chat a quit cut off when it is opened; this long after it shows, the app
    /// sends the message itself.
    static let resumeOnOpenWait: TimeInterval = 10
    /// How long a sent message may take to show a turn running.
    static let startWait: TimeInterval = 30

    enum Result: Equatable {
        /// Running without a message from the app: Claude resumed it, or it was already running.
        case running
        /// The app sent the message and Claude showed the turn start.
        case sent
        case notResumed(String)
    }

    enum Step: Equatable {
        case wait
        case send
        case done(Result)
    }

    /// The chats to get running again: every moved chat that was working when the switch began,
    /// which is each one Claude stopped for usage (`stoppedByLimit`) and each one whose turn the
    /// quit cut off (Claude's mark, or `cutByQuit` from its log). Each once, most recently active
    /// first. A chat that was idle is left alone.
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
    /// its window first showed it. Only an idle chat with an empty message box gets the message,
    /// so a running chat, a chat whose message box has someone's unsent text, and a chat Claude
    /// didn't show are never sent to.
    static func step(_ screen: ChatScreen?, interrupted: Bool, waited: TimeInterval, shownFor: TimeInterval?) -> Step {
        guard let screen else {
            return waited >= showWait ? .done(.notResumed("Claude didn't show it")) : .wait
        }
        if screen.busy { return .done(.running) }
        guard screen.composer else {
            return waited >= showWait ? .done(.notResumed("its message box wasn't found")) : .wait
        }
        if screen.draft { return .done(.notResumed("it has an unsent draft")) }
        if interrupted, (shownFor ?? 0) < resumeOnOpenWait { return .wait }
        return .send
    }
}
