// The decisions behind switching, kept free of AppKit, files and the network so the tests in
// tests/RulesTests.swift drive them directly: which account a Claude identity belongs to, when
// auto-switch moves and to which account, how a quit request is followed to its end, and which
// stopped chats get a new message after a switch.

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
    /// Percent used; nil when the window hasn't started, which counts as nothing used.
    let fiveHour: Int?
    let weekly: Int?
    /// When this reading was taken; nil when there is no reading at all.
    let readAt: Date?
    let needsSignIn: Bool
    let hasSavedLogin: Bool

    /// The fuller of the two meters: whichever runs out first stops the chats.
    var used: Int { Swift.max(fiveHour ?? 0, weekly ?? 0) }

    /// At its limit on either meter: Claude stops every chat on this account until it resets.
    var out: Bool { used >= AutoSwitchRule.limit }
}

enum AutoSwitchRule {
    /// On without touching anything; the header menu turns it off.
    static let onByDefault = true
    /// A meter at 100 percent is the limit: the account is out of usage.
    static let limit = 100
    /// No second automatic try this soon after the last one, whatever its outcome, so a failed
    /// switch never quits Claude over and over. Switching back can't flap: the account left
    /// behind is out, and an account that is out is never a target.
    static let coolDown: TimeInterval = 10 * 60
    /// A reading older than this is not trusted to start or choose a switch.
    static let freshness: TimeInterval = 15 * 60

    enum Decision: Equatable {
        case stay(String)
        case switchTo(id: String, reason: String)
        /// The account in use is out and no other account has room; worth telling the person once.
        case nowhere(String)
    }

    /// Whether to switch now, and to which row: once the account in use is out of usage, to the
    /// set-up account with the most room left.
    static func decide(current: SwitchCandidate?, others: [SwitchCandidate], enabled: Bool,
                       claudeRunning: Bool, lastAttempt: Date?, now: Date) -> Decision {
        guard enabled else { return .stay("Auto-switch is off.") }
        guard claudeRunning else { return .stay("Claude isn't running.") }
        guard let current else { return .stay("Claude isn't using an account this app knows.") }
        guard fresh(current, now) else { return .stay("No recent usage reading for \(current.name).") }
        guard current.out else { return .stay("\(current.name) is at \(current.used)%; it switches when it runs out.") }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < coolDown {
            return .stay("\(current.name) is out, but the last try was under \(Int(coolDown / 60)) minutes ago; next try after \(clock(lastAttempt.addingTimeInterval(coolDown))).")
        }
        let eligible = others.filter {
            $0.id != current.id && $0.hasSavedLogin && !$0.needsSignIn && fresh($0, now) && !$0.out
        }
        guard let best = eligible.min(by: { a, b in
            if a.used != b.used { return a.used < b.used }
            if (a.weekly ?? 0) != (b.weekly ?? 0) { return (a.weekly ?? 0) < (b.weekly ?? 0) }
            return a.name < b.name
        }) else {
            return .nowhere("\(current.name) is out of usage, and no other set-up account has room. Chats wait until a limit resets.")
        }
        return .switchTo(id: best.id, reason: "\(current.name) is out of usage; \(best.name) is at \(best.used)%.")
    }

    private static func fresh(_ c: SwitchCandidate, _ now: Date) -> Bool {
        c.readAt.map { now.timeIntervalSince($0) <= freshness } ?? false
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// Which chats Claude stopped at a usage limit, read from its log. Such a chat's turn already
/// ended with the limit error, so no quit cuts it off and Claude doesn't resume it at its next
/// launch; it waits for a new message. Retrying the failed message instead rewinds the chat
/// and starts its transcript over under a new id, without its subagents.
enum LimitLog {
    /// Sessions whose last outcome in `text` (one run of Claude's log) is a usage-limit error.
    static func stoppedSessions(in text: String) -> Set<String> {
        var stopped = Set<String>()
        for line in text.split(separator: "\n") where line.contains("[CCD CycleHealth]") {
            if let id = session(after: "[CCD CycleHealth] ", in: line), line.contains(" api_error ("),
               line.contains("You've hit your"), line.contains("limit") {
                stopped.insert(id)
            } else if let id = session(after: "[CCD CycleHealth] healthy cycle for ", in: line) {
                stopped.remove(id)
            }
        }
        return stopped
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

    /// The chats to get running again: every moved chat a quit cut off or a usage limit stopped,
    /// each once, most recently active first. A chat neither stopped is left alone.
    static func toResume(_ chats: [MovedChat], limited: Set<String>) -> [MovedChat] {
        var seen = Set<String>()
        return chats.filter { ($0.interrupted || limited.contains($0.id)) && seen.insert($0.id).inserted }
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
