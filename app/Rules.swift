// The decisions behind switching, kept free of AppKit, files and the network so the tests in
// tests/RulesTests.swift drive them directly: which account a Claude identity belongs to, when
// auto-switch moves and to which account, how a quit request is followed to its end, and which
// interrupted chats get reopened after a switch.

import Foundation

// MARK: - Accounts and identities

/// The account Claude is signed in to and the organization whose Code sessions it shows.
struct Identity: Equatable, Codable, Sendable {
    let account: String
    let org: String
}

/// One row in the menu: one Claude login for one account in one organization (workspace).
/// An account that belongs to two organizations has two rows, one per workspace.
struct AccountRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var color: String
    var configDir: String
    var keychainService: String
    let email: String?
    let accountUuid: String?
    var orgName: String?
    /// The workspace this row stands for. Older rows lack it until it is filled in on load.
    var orgUuid: String?

    var configURL: URL { URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath) }

    /// The label without its domain, for the menu bar where space is tight.
    var shortName: String { name.split(separator: "@").first.map(String.init) ?? name }
}

extension Array where Element == AccountRecord {
    /// The row a Claude identity belongs to: the row for that account and workspace, else the
    /// account's only row that names no workspace yet.
    func row(for id: Identity?) -> AccountRecord? {
        guard let id else { return nil }
        if let exact = first(where: { $0.accountUuid == id.account && $0.orgUuid == id.org }) { return exact }
        let unnamed = filter { $0.accountUuid == id.account && $0.orgUuid == nil }
        return unnamed.count == 1 ? unnamed[0] : nil
    }

    /// Rows for the same account in other workspaces than `row`.
    func otherWorkspaces(of row: AccountRecord) -> [AccountRecord] {
        filter { $0.id != row.id && $0.accountUuid != nil && $0.accountUuid == row.accountUuid }
    }
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
}

enum AutoSwitchRule {
    /// Switch before the meter reaches 100 %: a chat that hits the limit fails its turn, and
    /// Claude's retry of a failed turn forks the chat's transcript and leaves its subagents behind.
    static let defaultThreshold = 90
    static let thresholds = [80, 90, 95]
    /// No second automatic switch this soon after the last attempt, whatever its outcome, so a
    /// failed or bouncing switch never quits Claude over and over.
    static let coolDown: TimeInterval = 30 * 60
    /// A reading older than this is not trusted to start or choose a switch.
    static let freshness: TimeInterval = 15 * 60

    enum Decision: Equatable {
        case stay(String)
        case switchTo(id: String, reason: String)
    }

    /// Whether to switch now, and to which row. `threshold` nil means auto-switch is off.
    static func decide(current: SwitchCandidate?, others: [SwitchCandidate], threshold: Int?,
                       claudeRunning: Bool, lastAttempt: Date?, now: Date) -> Decision {
        guard let threshold else { return .stay("Auto-switch is off.") }
        guard claudeRunning else { return .stay("Claude isn't running.") }
        guard let current else { return .stay("Claude isn't using an account this app knows.") }
        guard fresh(current, now) else { return .stay("No recent usage reading for \(current.name).") }
        guard current.used >= threshold else {
            return .stay("\(current.name) is at \(current.used)%, under \(threshold)%.")
        }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < coolDown {
            let until = lastAttempt.addingTimeInterval(coolDown)
            return .stay("\(current.name) is at \(current.used)%, but the last switch was under \(Int(coolDown / 60)) minutes ago; next try after \(clock(until)).")
        }
        let eligible = others.filter {
            $0.id != current.id && $0.hasSavedLogin && !$0.needsSignIn && fresh($0, now) && $0.used < threshold
        }
        guard let best = eligible.min(by: { a, b in
            if a.used != b.used { return a.used < b.used }
            if (a.weekly ?? 0) != (b.weekly ?? 0) { return (a.weekly ?? 0) < (b.weekly ?? 0) }
            return a.name < b.name
        }) else {
            return .stay("\(current.name) is at \(current.used)%, and no other set-up account is under \(threshold)%.")
        }
        return .switchTo(id: best.id, reason: "\(current.name) reached \(current.used)%; \(best.name) is at \(best.used)%.")
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
/// after the switch has walked away. Claude's log can go silent (it did for a day on one Mac),
/// so the prompt is also watched on screen and a silent log is never read as a Cancel at once.
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

/// A moved chat as the resume step sees it: Claude marks a chat whose reply was cut off by a
/// quit (`interruptedByQuitAt`) and resumes it itself, a few at once at launch and the rest
/// when each is opened.
struct MovedChat: Equatable {
    let id: String
    let title: String
    let interrupted: Bool
    let lastActivity: Double
}

enum ResumeRule {
    /// How long Claude gets to resume chats on its own before the app opens the rest.
    static let ownPassWait: TimeInterval = 45
    /// How long each opened chat gets to show it resumed before the next one is opened.
    static let perChatWait: TimeInterval = 45

    /// The interrupted chats, most recently active first, which is the order Claude uses too.
    static func toResume(_ chats: [MovedChat]) -> [MovedChat] {
        chats.filter(\.interrupted).sorted { $0.lastActivity > $1.lastActivity }
    }

    /// A chat has resumed once Claude cleared its mark or it ran after Claude reopened.
    static func resumed(markStillSet: Bool, lastActivity: Double, reopenedAt: Double) -> Bool {
        !markStillSet || lastActivity > reopenedAt
    }
}
