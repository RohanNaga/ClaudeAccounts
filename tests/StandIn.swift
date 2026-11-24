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
    let start: Date
    init(start: Date) { t = start; self.start = start }

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

    /// The Mac sleeps for `seconds`: the clock jumps there at once, then everything that fell due
    /// runs at the new time, the way a woken Mac finds every timer late.
    func sleepMac(_ seconds: TimeInterval) {
        lock.withLock { t = t.addingTimeInterval(max(0, seconds)) }
        advance(0)
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
    var logDir: URL { onLogDir?(); return root.appendingPathComponent("claude-logs") }
    /// Runs each time anyone finds Claude's log folder: a scenario rotates the log mid-read here.
    var onLogDir: (() -> Void)?
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
    /// False: Claude's quit prompt shows only Wait for Claude and Cancel, as Accessibility reads it.
    var promptHasQuitButton = true
    /// Accessibility lists the open prompt only this long after it opened; until then the app sees
    /// only a new window. A prompt not yet listed, or an Accessibility call that timed out while
    /// Claude was busy, looks like this. `.infinity`: never listed (a prompt on another Space).
    var promptListedAfter: TimeInterval = 0
    private var promptOpenedAt: Date?
    /// For this long after the prompt opens, each look through Accessibility times out and returns
    /// nothing, as while Claude is busy; the first such look takes 2.1 s of real time, past the 2 s
    /// cap the app once had on each call.
    var accessibilitySlowFor: TimeInterval = 0
    private var slowLookTaken = false
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
    /// Chats Claude is running when it quits: it logs each as cut off by the quit (F3 CutByQuit).
    var cutOnQuit: Set<String> = []
    /// The next launch opens on this pair, whatever sign-in was loaded.
    var opensAsOnce: StandSeat?
    /// False: a Quit anyway press lands, but the prompt stays and Claude keeps running.
    var quitAnywayLands = true
    /// Chats on screen, by session id, and what their composer shows.
    var screens: [String: ChatScreen] = [:]
    /// Every "resume" typed, as "<session> <text>".
    private(set) var sent: [String] = []
    /// Every send the app tried without Accessibility, as "<session> <text>".
    private(set) var untrustedSends: [String] = []
    /// Every quit request, prompt press, launch and reopen, in order, with the clock's time.
    private(set) var timeline: [(what: String, at: Date)] = []
    var actions: [String] { lock.withLock { timeline.map(\.what) } }
    /// When each `what` in the timeline happened.
    func at(_ what: String) -> [Date] { lock.withLock { timeline.filter { $0.what == what }.map(\.at) } }
    private func did(_ what: String) { lock.withLock { timeline.append((what, clock.now())) } }

    // What Claude is doing.
    private(set) var pid: pid_t?
    private(set) var held: StandSeat?
    /// The seat whose sign-in files this run of Claude started from, named yet or not.
    private var runsOn: StandSeat?
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
            + (seat == nil ? "" : "INSERT INTO cookies VALUES('.claude.ai','\(ClaudeFiles.signInCookie)','\(value)');"
               + "INSERT INTO cookies VALUES('.claude.ai','\(Self.writeMark)','\(nextMark("sign-in"))');")
        sqlite(cookies, sql)
        var cfg: [String: Any] = [:]
        if let seat { cfg[ClaudeFiles.lastKnownAccount] = seat.account; cfg["oauth:tokenCache"] = "placeholder" }
        try? JSONSerialization.data(withJSONObject: cfg).write(to: config)
    }

    /// A sign-in cookie whose value changes on every write Claude makes to its cookie file, so a
    /// saved login shows which write it copied.
    static let writeMark = "stand_in_write"
    private var marks = 0
    private func nextMark(_ when: String) -> String { lock.withLock { marks += 1; return "\(when)-\(marks)" } }
    /// The mark Claude wrote as it quit holding each seat (13a.2: Claude writes its cookies at quit).
    private(set) var quitMarks: [StandSeat: String] = [:]

    private func sqlite(_ db: URL, _ sql: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        // The app judges "sat still" from the file's real modification time. Virtual time runs far
        // ahead of real time, so the write is dated a minute back: by the time the app looks, the
        // stand-in Claude has held the sign-in well past the 2 s the app waits for.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: db.path)
    }

    /// The write mark in a cookie database: Claude's own file, or a saved login's copy.
    func writeMark(in db: URL) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, "SELECT value FROM cookies WHERE name='\(Self.writeMark)'"]
        p.standardOutput = out; p.standardError = Pipe()
        guard FileManager.default.fileExists(atPath: db.path), (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
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

    /// The zone Claude prints its log in: the Mac's, unless a scenario has Claude keep an older one.
    var printZone: TimeZone?

    /// Each line is printed in Claude's zone, and the file's last write is the clock's now, as on disk.
    func log(_ body: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = ClaudeLog.timeFormat; stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = printZone ?? .current
        let line = "\(stamp.string(from: clock.now())) [info] \(body)\n"
        let url = logDir.appendingPathComponent(ClaudeFiles.log)
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd(); try? h?.write(contentsOf: Data(line.utf8)); try? h?.close()
        try? FileManager.default.setAttributes([.modificationDate: clock.now()], ofItemAtPath: url.path)
    }

    func logNamed(_ s: StandSeat) {
        if namedLineChanged { log("[identity] signed in, in a shape the app has not seen"); return }
        log("\(ClaudeLog.identity) \(ClaudeLog.accountField)\(s.account) \(ClaudeLog.orgField)\(s.org)") }
    func logRefused(_ s: StandSeat) { log("[auth] \(ClaudeLog.refusal) cacheKey=\(s.account):\(s.org) \(ClaudeLog.orgField)\(s.org)") }
    func logTurnEnded(_ chat: String) { log("\(ClaudeLog.healthyCycle)\(chat) (12s, hadFirstResponse=true)") }
    /// Claude stops `chat` for usage. Each scenario states what the seat it holds reads from then:
    /// Claude also stops chats for limits the meters don't show (Rohan's 10:41 stop came at 44%
    /// and 6%), so a stop says nothing about the meters by itself. `seatReadsFull: true` makes that
    /// seat read full from now: a meter the scenario set full stays as set, and any other reads a
    /// 5-hour meter at 100 resetting in 2 h. `false` leaves the meters as they were.
    func logLimitStop(_ chat: String, seatReadsFull: Bool) {
        if seatReadsFull, let seat = held { usage?.readsFull(seat, resetsAt: clock.now().addingTimeInterval(2 * 3600)) }
        log("\(ClaudeLog.cycle)\(chat)\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit")
    }
    /// The meters a stop makes read full (set by the harness).
    var usage: StandInUsage?

    // MARK: Claude running

    /// Claude starts as it would from its own sign-in files, and names (or refuses) the seat.
    func start() {
        let seat = signInOnDisk()
        // A newly started Claude prints the Mac's zone.
        let p: pid_t = lock.withLock { nextPid += 1; pid = nextPid; held = nil; runsOn = seat; printZone = nil; return nextPid }
        log("\(ClaudeLog.appStart) }")
        guard let seat else {
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

    /// Claude stops. A quit, the person's or the app's, writes the cookie file as Claude exits
    /// (13a.2), so only a copy taken after the quit holds the final bytes, and logs each chat the
    /// quit cut off. A crash writes nothing. The seat it quit on is the one its files named, so a
    /// Claude quit before it named a seat still counts as quit on that seat.
    func stop(crashed: Bool = false) {
        let was: (pid: pid_t?, seat: StandSeat?) = lock.withLock { (pid, held) }
        guard was.pid != nil else { return }
        if !crashed {
            for chat in cutOnQuit.sorted() { log("\(ClaudeLog.unhealthyCycle)\(chat) (40s, \(ClaudeLog.quitReason))") }
        }
        if !crashed, writeMark(in: cookies) != nil {
            let mark = nextMark("quit")
            sqlite(cookies, "UPDATE cookies SET value='\(mark)' WHERE name='\(Self.writeMark)';")
            if let seat = was.seat { lock.withLock { quitMarks[seat] = mark } }
        }
        lock.withLock { quitOn = held ?? runsOn; pid = nil; held = nil; runsOn = nil; promptOpen = false }
    }

    func pids() -> [pid_t] {
        guard installed else { return [] }
        let seat: StandSeat? = lock.withLock { pid == nil && reopensAfterQuit > 0 ? quitOn : nil }
        if let seat, chats(in: seat).isEmpty {
            lock.withLock { reopensAfterQuit -= 1; quitOn = nil }
            did("person opened")
            start()
        }
        return lock.withLock { pid.map { [$0] } ?? [] }
    }
    func windowIDs(_ owners: [pid_t]) -> Set<Int> {
        lock.withLock { pid == nil ? [] : (promptOpen ? [1, 2] : [1]) }
    }

    func requestQuit(_ p: pid_t) async {
        did("quit")
        switch quitBehaviour {
        case .quits: stop()
        case .ignores: break
        case .promptThenQuit, .promptCancelled, .promptUnanswered:
            lock.withLock { promptOpen = true; promptOpenedAt = clock.now() }
            if quitBehaviour == .promptThenQuit { clock.after(5) { [weak self] in self?.stop() } }
            if quitBehaviour == .promptCancelled { clock.after(5) { [weak self] in self?.lock.withLock { self?.promptOpen = false } } }
        }
    }

    func launch() async {
        // Launching ends the gap between quit and launch, so it is not a look at Claude.
        did("launch")
        let (closed, opensAs): (Bool, StandSeat?) = lock.withLock {
            defer { opensAsOnce = nil }
            quitOn = nil; return (pid == nil, opensAsOnce)
        }
        guard installed, closed else { return }
        if let opensAs { writeSignIn(opensAs) }
        start()
    }

    func open(link: String) async { did("open \(link)") }
    /// When each chat link was opened, on the virtual clock.
    var opened: [Date] { lock.withLock { timeline.filter { $0.what.hasPrefix("open ") }.map(\.at) } }

    var trusted: Bool { trustedAX }
    /// Claude's window, and its prompt once Accessibility lists it.
    func quitPromptSurvey(in owners: [pid_t]) -> QuitSurvey {
        guard trustedAX else { return QuitSurvey() }
        let timesOut: (Bool, Bool) = lock.withLock {
            guard promptOpen, let opened = promptOpenedAt, clock.now().timeIntervalSince(opened) < accessibilitySlowFor else { return (false, false) }
            defer { slowLookTaken = true }
            return (true, !slowLookTaken)
        }
        if timesOut.1 { usleep(2_100_000) }
        if timesOut.0 { return QuitSurvey() }
        return lock.withLock {
            guard pid != nil else { return QuitSurvey() }
            var seen = QuitSurvey(windows: ["AXWindow/AXStandardWindow"])
            guard promptListed else { return seen }
            seen.windows.append("AXWindow/AXDialog")
            seen.prompts = [promptHasQuitButton ? ["Wait for Claude", ClaudeUI.quitAnyway, ClaudeUI.cancel] : ["Wait for Claude", ClaudeUI.cancel]]
            return seen
        }
    }
    private var promptListed: Bool { promptOpen && (promptOpenedAt.map { clock.now().timeIntervalSince($0) >= promptListedAfter } ?? false) }
    /// Quit anyway quits Claude (unless `quitAnywayLands` is off); Cancel closes the prompt and leaves Claude running.
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool {
        guard trustedAX, lock.withLock({ promptListed }) else { return false }
        if title == ClaudeUI.quitAnyway && !promptHasQuitButton { return false }
        did("pressed \(title)")
        if title == ClaudeUI.quitAnyway && !quitAnywayLands { return true }
        if title == ClaudeUI.cancel { lock.withLock { promptOpen = false } } else { stop() }
        return true
    }
    /// The person presses a button on Claude's open prompt themselves, whether Accessibility lists it or not.
    func personAnswers(_ title: String) {
        guard lock.withLock({ promptOpen }) else { return }
        did("person pressed \(title)")
        if title == ClaudeUI.cancel { lock.withLock { promptOpen = false } } else { stop() }
    }
    func exposeWebContent(of owners: [pid_t]) {}
    /// Without Accessibility, Claude's window cannot be read at all.
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen? { trustedAX ? lock.withLock { screens[session] } : nil }
    /// Without Accessibility nothing can be typed: the attempt is kept, so a check can see the app tried.
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent {
        guard trustedAX else { lock.withLock { untrustedSends.append("\(session) \(text)") }; return .refused("no Accessibility") }
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
    /// When each read happened, on the clock the scenario runs (set by the harness).
    private(set) var readTimes: [(tag: String, at: Date)] = []
    var clock: VirtualClock?
    /// When `seat`'s meter was read, in order.
    func readsOf(_ seat: StandSeat) -> [Date] { lock.withLock { readTimes.filter { $0.tag == seat.tag }.map(\.at) } }
    func set(_ seat: StandSeat, fiveHour: Double, weekly: Double = 10, resetsAt: Date?) {
        lock.withLock {
            meters[seat.tag] = .ok(fiveHour: UsageWindow(utilization: fiveHour, resetsAt: resetsAt),
                                  weekly: UsageWindow(utilization: weekly, resetsAt: resetsAt?.addingTimeInterval(86_400 * 3)))
        }
    }
    func fail(_ seat: StandSeat) { lock.withLock { meters[seat.tag] = .unreadable } }
    /// `seat` reads full: unchanged if a meter is already at 100, else its 5-hour meter at 100.
    func readsFull(_ seat: StandSeat, resetsAt: Date) {
        let full: Bool = lock.withLock {
            guard case .ok(let fh, let wk)? = meters[seat.tag] else { return false }
            return [fh, wk].contains { ($0?.utilization ?? 0) >= 100 }
        }
        if !full { set(seat, fiveHour: 100, resetsAt: resetsAt) }
    }
    /// The usage service answers `seat` with a wait until `until`, as it does when asked again
    /// within a minute; after that, the meter set for it.
    func busy(_ seat: StandSeat, until: Date) { lock.withLock { waits[seat.tag] = until } }
    private var waits: [String: Date] = [:]
    func state(for acct: AccountRecord) async -> AccountState {
        lock.withLock {
            let tag = "\(acct.accountUuid ?? "?")/\(acct.orgUuid ?? "?")"
            reads.append(tag)
            if let clock { readTimes.append((tag, clock.now())) }
            if let until = waits[tag], let now = clock?.now(), now < until { return .rateLimited(until: until) }
            return meters[tag] ?? .unreadable
        }
    }
}
