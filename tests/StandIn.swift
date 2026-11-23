import Foundation

// A stand-in Claude on a virtual clock. It keeps Claude's files in a temporary folder, writes
// Claude's log lines in the shapes app/Claude.swift names, and answers quit, launch and the
// window questions the way the model (section 6) says Claude does. Nothing here waits: sleeping
// on the clock moves time forward and runs whatever the stand-in had scheduled by then.

/// Time that moves only when someone sleeps on it or the scenario advances it.
final class VirtualClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    private var due: [(at: Date, seq: Int, run: () -> Void)] = []
    private var seq = 0
    init(start: Date) { t = start }

    func now() -> Date { lock.withLock { t } }

    /// Runs `run` once the clock reaches `seconds` from now.
    func after(_ seconds: TimeInterval, _ run: @escaping () -> Void) {
        lock.withLock { seq += 1; due.append((t.addingTimeInterval(seconds), seq, run)) }
    }

    /// Moves the clock forward, running each scheduled event at its own time, in order.
    func advance(_ seconds: TimeInterval) {
        let end = now().addingTimeInterval(max(0, seconds))
        while true {
            let next: (at: Date, seq: Int, run: () -> Void)? = lock.withLock {
                guard let i = due.indices.filter({ due[$0].at <= end }).min(by: { (due[$0].at, due[$0].seq) < (due[$1].at, due[$1].seq) }) else { return nil }
                let e = due.remove(at: i)
                t = max(t, e.at)
                return e
            }
            guard let e = next else { break }
            // A crashed app's sleeper is kept, never run: dropping it would leak its continuation.
            let isDead = lock.withLock { () -> Bool in
                guard abandoned.contains(e.seq) else { return false }
                dead.append(e.run)
                return true
            }
            if isDead { continue }
            e.run()
        }
        lock.withLock { t = max(t, end) }
    }

    /// The app sleeps until the scenario moves the clock past its deadline; only the scenario
    /// moves time, so every wait in the app lasts exactly as long as the scenario says.
    func sleep(_ seconds: TimeInterval) async {
        lock.withLock { sleepers += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            after(seconds) { [weak self] in self?.lock.withLock { self?.sleepers -= 1 }; c.resume() }
            _ = lock.withLock { sleeperSeqs.insert(seq) }
        }
    }
    /// The time of the earliest event still to run, so a run can jump straight to it.
    var nextDue: Date? {
        lock.withLock { due.filter { !abandoned.contains($0.seq) }.map(\.at).min() }
    }
    /// A count that changes whenever an event is scheduled or run, to tell when the app is still busy.
    var activity: Int { lock.withLock { seq * 1_000_003 + due.count } }
    private var sleepers = 0
    private var abandoned = Set<Int>(), sleeperSeqs = Set<Int>()
    private var dead: [() -> Void] = []
    /// The app crashed: every task asleep now never wakes. Events the stand-in scheduled still run.
    func abandonSleepers() { lock.withLock { abandoned.formUnion(sleeperSeqs); sleepers = 0 } }
    /// How many of the app's tasks are asleep on this clock.
    var asleep: Int { lock.withLock { sleepers } }
}

/// A placeholder id in the shape Claude logs ids, a 36-character UUID, so the app's own parsing
/// reads it. `kind` (a hex digit) and `n` keep it readable: a for accounts, b for organizations,
/// e for an account's personal organization.
func placeholderId(_ kind: Character, _ n: Int) -> String {
    String(repeating: kind, count: 8) + "-0000-4000-8000-" + String(format: "%012x", n)
}

/// One seat: an account in an organization. Ids are placeholders, never real ones.
struct StandSeat: Hashable, CustomStringConvertible {
    let account: String
    let org: String
    init(account: String, org: String) { self.account = account; self.org = org }
    /// Account `n` in organization `org` (0: the account's personal organization).
    init(_ n: Int, org: Int) {
        self.init(account: placeholderId("a", n), org: org == 0 ? placeholderId("e", n) : placeholderId("b", org))
    }
    var identity: Identity { Identity(account: account, org: org) }
    var tag: String { "\(account)/\(org)" }
    var description: String {
        func n(_ id: String) -> String { String(Int(id.suffix(12), radix: 16) ?? 0) }
        return "account \(n(account)) in \(org.hasPrefix("e") ? "its personal organization" : "organization \(n(org))")"
    }
}

/// How Claude answers a request to quit.
enum QuitBehaviour { case quits, promptThenQuit, promptCancelled, promptUnanswered, ignores }

final class StandInClaude: ClaudeWorld, @unchecked Sendable {
    let root: URL
    let clock: VirtualClock
    private let lock = NSLock()

    var home: URL { root.appendingPathComponent("home") }
    var stateDir: URL { root.appendingPathComponent("state") }
    var bundleId: String { "test.stand-in.claude" }
    var dataDir: URL { root.appendingPathComponent("claude-data") }
    var logDir: URL { root.appendingPathComponent("claude-logs") }
    func executable() -> String { root.appendingPathComponent("Claude.app/Contents/MacOS/Claude").path }

    // What the scenario sets.
    var installed = true
    var trustedAX = true
    var quitBehaviour: QuitBehaviour = .quits
    /// Seats whose saved sign-in Claude now calls too old: it names them, then refuses and falls back.
    var stale: Set<StandSeat> = []
    /// Each account's personal organization, where Claude falls back after a refusal.
    var personal: [String: String] = [:]
    /// Seconds from launch to the Named line, and from Named to a refusal (4 to 21 s seen).
    var nameAfter: TimeInterval = 3
    var refuseAfter: TimeInterval = 12
    /// Claude names the seat it holds in a line the app has not seen: the Named shape is missing.
    var namedLineChanged = false
    /// Claude's quit prompt has no Quit anyway button: Accessibility finds no prompt, only a new window.
    var promptHasQuitButton = true
    /// Set Up: who the person signs in as once Claude asks (nil: nobody signs in).
    var signsInAs: StandSeat?
    /// Every notification the app posted, as "<title>: <body>".
    private(set) var notifications: [String] = []
    /// Runs as each switch step begins, on the switch's own task: a fault scenario strikes here.
    var onStep: (@Sendable (String) async -> Void)?
    /// Times the person opens Claude again after a switch quit it, between the quit and the launch:
    /// on the app's first look at Claude once the chats left the folder of the seat it quit on.
    var reopensAfterQuit = 0
    private var quitOn: StandSeat?
    /// Chats on screen, by session id, and what their composer shows.
    var screens: [String: ChatScreen] = [:]
    /// Every "resume" typed, as "<session> <text>".
    private(set) var sent: [String] = []
    /// Every quit request and launch, in order.
    private(set) var actions: [String] = []

    // What Claude is doing.
    private(set) var pid: pid_t?
    private(set) var held: StandSeat?
    private(set) var promptOpen = false
    private var nextPid: pid_t = 90_000

    init(clock: VirtualClock) throws {
        self.clock = clock
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stand-in-\(getpid())-\(UUID().uuidString.prefix(8))")
        for d in [home, stateDir, dataDir, logDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: executable()).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logDir.appendingPathComponent(ClaudeFiles.log).path, contents: Data())
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    // MARK: Claude's files

    /// The cookie schema version Claude writes: the recorded one unless a scenario changes it.
    var cookieSchema = ClaudeFiles.cookieSchemaVersion

    var cookies: URL { dataDir.appendingPathComponent(ClaudeFiles.cookies) }
    var config: URL { dataDir.appendingPathComponent(ClaudeFiles.config) }

    /// Writes Claude's sign-in as `seat` (nil: signed out), the way Claude does after a sign-in.
    func writeSignIn(_ seat: StandSeat?) {
        try? FileManager.default.removeItem(at: cookies)
        let value = seat?.tag ?? ""
        // Chromium's cookie database shape: a meta table carrying the schema version, and cookie
        // rows keyed by host. Placeholder values only; the stand-in's tag stands for the sign-in.
        let sql = "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR); "
            + "INSERT INTO meta VALUES('version','\(cookieSchema)');"
            + "CREATE TABLE cookies(host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL); "
            + "INSERT INTO cookies VALUES('.example.org','other','x'); "
            + (seat == nil ? "" : "INSERT INTO cookies VALUES('.claude.ai','\(ClaudeFiles.signInCookie)','\(value)');")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [cookies.path, sql]
        try? p.run(); p.waitUntilExit()
        // The app judges "sat still" from the file's real modification time. Virtual time runs far
        // ahead of real time, so the write is dated a minute back: by the time the app looks, the
        // stand-in Claude has held the sign-in well past the 2 s the app waits for.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: cookies.path)
        var cfg: [String: Any] = [:]
        if let seat { cfg[ClaudeFiles.lastKnownAccount] = seat.account; cfg["oauth:tokenCache"] = "placeholder" }
        try? JSONSerialization.data(withJSONObject: cfg).write(to: config)
    }

    /// The seat Claude's sign-in files name now (what the next launch signs in as).
    func signInOnDisk() -> StandSeat? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [cookies.path, "SELECT value FROM cookies WHERE name='\(ClaudeFiles.signInCookie)'"]
        p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = v.split(separator: "/").map(String.init)
        return parts.count == 2 ? StandSeat(account: parts[0], org: parts[1]) : nil
    }

    /// A chat record in a seat's folder.
    func addChat(_ id: String, in seat: StandSeat, lastActivity: Date) {
        let dir = dataDir.appendingPathComponent(ClaudeFiles.sessions).appendingPathComponent(seat.account).appendingPathComponent(seat.org)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec: [String: Any] = [ClaudeFiles.sessionId: id, ClaudeFiles.title: "chat", ClaudeFiles.isArchived: false,
                                  ClaudeFiles.lastActivityAt: lastActivity.timeIntervalSince1970 * 1000]
        try? JSONSerialization.data(withJSONObject: rec).write(to: dir.appendingPathComponent("\(id).json"))
    }

    /// The chat ids in a seat's folder.
    func chats(in seat: StandSeat) -> Set<String> {
        let dir = dataDir.appendingPathComponent(ClaudeFiles.sessions).appendingPathComponent(seat.account).appendingPathComponent(seat.org)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    // MARK: Claude's log

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = ClaudeLog.timeFormat; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    func log(_ body: String) {
        let line = "\(Self.stamp.string(from: clock.now())) [info] \(body)\n"
        let h = try? FileHandle(forWritingTo: logDir.appendingPathComponent(ClaudeFiles.log))
        _ = try? h?.seekToEnd(); try? h?.write(contentsOf: Data(line.utf8)); try? h?.close()
    }

    func logNamed(_ s: StandSeat) {
        if namedLineChanged { log("[identity] signed in, in a shape the app has not seen"); return }
        log("\(ClaudeLog.identity) \(ClaudeLog.accountField)\(s.account) \(ClaudeLog.orgField)\(s.org)") }
    func logRefused(_ s: StandSeat) { log("[auth] \(ClaudeLog.refusal) cacheKey=\(s.account):\(s.org) \(ClaudeLog.orgField)\(s.org)") }
    func logTurnEnded(_ chat: String) { log("\(ClaudeLog.healthyCycle)\(chat) (12s, hadFirstResponse=true)") }
    func logLimitStop(_ chat: String) {
        log("\(ClaudeLog.cycle)\(chat)\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit")
    }

    // MARK: Claude running

    /// Claude starts as it would from its own sign-in files, and names (or refuses) the seat.
    func start() {
        let p: pid_t = lock.withLock { nextPid += 1; pid = nextPid; held = nil; return nextPid }
        log("\(ClaudeLog.appStart) }")
        guard let seat = signInOnDisk() else {
            if let who = signsInAs { clock.after(60) { [weak self] in self?.signIn(who, pid: p) } }
            return
        }
        clock.after(nameAfter) { [weak self] in self?.name(seat, pid: p) }
    }

    private func name(_ seat: StandSeat, pid p: pid_t) {
        guard pid == p else { return }
        lock.withLock { held = seat }
        logNamed(seat)
        guard stale.contains(seat) else { return }
        clock.after(refuseAfter) { [weak self] in
            guard let self, self.pid == p else { return }
            self.logRefused(seat)
            let fallback = StandSeat(account: seat.account, org: self.personal[seat.account] ?? placeholderId("e", Int(seat.account.suffix(12), radix: 16) ?? 0))
            self.lock.withLock { self.held = fallback }
            self.logNamed(fallback)
        }
    }

    /// The person signs in at Claude's sign-in page.
    func signIn(_ seat: StandSeat, pid p: pid_t? = nil) {
        guard p == nil || pid == p else { return }
        writeSignIn(seat)
        name(seat, pid: pid ?? 0)
    }

    /// Claude stops: a crash, or the person quitting it.
    func stop() {
        lock.withLock { quitOn = held; pid = nil; held = nil; promptOpen = false }
    }

    func pids() -> [pid_t] {
        guard installed else { return [] }
        let seat: StandSeat? = lock.withLock { pid == nil && reopensAfterQuit > 0 ? quitOn : nil }
        if let seat, chats(in: seat).isEmpty {
            lock.withLock { reopensAfterQuit -= 1; quitOn = nil; actions.append("person opened") }
            start()
        }
        return lock.withLock { pid.map { [$0] } ?? [] }
    }
    func windowIDs(_ owners: [pid_t]) -> Set<Int> {
        lock.withLock { pid == nil ? [] : (promptOpen ? [1, 2] : [1]) }
    }

    func requestQuit(_ p: pid_t) async {
        lock.withLock { actions.append("quit") }
        switch quitBehaviour {
        case .quits: stop()
        case .ignores: break
        case .promptThenQuit, .promptCancelled, .promptUnanswered:
            lock.withLock { promptOpen = true }
            if quitBehaviour == .promptThenQuit { clock.after(5) { [weak self] in self?.stop() } }
            if quitBehaviour == .promptCancelled { clock.after(5) { [weak self] in self?.lock.withLock { self?.promptOpen = false } } }
        }
    }

    func launch() async {
        // Launching ends the gap between quit and launch, so it is not a look at Claude.
        let closed: Bool = lock.withLock { actions.append("launch"); quitOn = nil; return pid == nil }
        guard installed, closed else { return }
        start()
    }

    func open(link: String) async { lock.withLock { actions.append("open \(link)") } }

    var trusted: Bool { trustedAX }
    func quitPromptOpen(in owners: [pid_t]) -> Bool { lock.withLock { promptOpen && promptHasQuitButton } }
    /// Quit anyway quits Claude; Cancel closes the prompt and leaves Claude running.
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool {
        guard trustedAX, lock.withLock({ promptOpen }) else { return false }
        if title == ClaudeUI.quitAnyway && !promptHasQuitButton { return false }
        lock.withLock { actions.append("pressed \(title)") }
        if title == ClaudeUI.cancel { lock.withLock { promptOpen = false } } else { stop() }
        return true
    }
    func exposeWebContent(of owners: [pid_t]) {}
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen? { lock.withLock { screens[session] } }
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent {
        guard let s = lock.withLock({ screens[session] }) else { return .busy }
        if s.busy { return .busy }
        if s.draft { return .draft }
        lock.withLock { sent.append("\(session) \(text)"); screens[session]?.busy = true }
        return .pressed("Send")
    }
    func idleSeconds() -> TimeInterval { 600 }
    func notify(title: String, body: String) { lock.withLock { notifications.append("\(title): \(body)") } }
    func willStep(_ step: String) async { await onStep?(step) }
}

/// Meters the scenario sets per seat pair (13a.1), read through the app's own usage seam.
final class StandInUsage: UsageReader, @unchecked Sendable {
    private let lock = NSLock()
    private var meters: [String: AccountState] = [:]
    private(set) var reads: [String] = []
    func set(_ seat: StandSeat, fiveHour: Double, weekly: Double = 10, resetsAt: Date?) {
        lock.withLock {
            meters[seat.tag] = .ok(fiveHour: UsageWindow(utilization: fiveHour, resetsAt: resetsAt),
                                  weekly: UsageWindow(utilization: weekly, resetsAt: resetsAt?.addingTimeInterval(86_400 * 3)))
        }
    }
    func fail(_ seat: StandSeat) { lock.withLock { meters[seat.tag] = .unreadable } }
    func state(for acct: AccountRecord) async -> AccountState {
        lock.withLock {
            let tag = "\(acct.accountUuid ?? "?")/\(acct.orgUuid ?? "?")"
            reads.append(tag)
            return meters[tag] ?? .unreadable
        }
    }
}
