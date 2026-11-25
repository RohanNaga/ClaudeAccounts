// Everything the app assumes about the Claude desktop app, and the one way the app reaches it.
//
// The rest of the app never names a Claude path, process, log line, settings key or
// Accessibility element: it asks `World.claude` and reads the shapes below. Production runs on
// `RealClaudeWorld`, which is the Mac as it is. A test installs a stand-in Claude, a temporary
// state folder and a virtual clock with `World.install`, which refuses any world that could
// reach the person's real Claude, real files or real keychain.

import AppKit
import ApplicationServices
import UserNotifications

// MARK: - The world

/// The Claude desktop app as the app sees it: where its files are, its processes and windows,
/// how it quits and launches, and what its Accessibility tree offers. Every method is a single
/// primitive; the rules that combine them (QuitWatch, ResumeRule) stay in the app.
protocol ClaudeWorld: Sendable {
    /// The home folder Claude's files and the Claude Code CLI live under.
    var home: URL { get }
    /// The app's own state folder: saved logins, accounts.json, journals and logs.
    var stateDir: URL { get }
    var bundleId: String { get }
    /// Claude's Application Support folder: Cookies, config.json, claude-code-sessions.
    var dataDir: URL { get }
    /// Claude's log folder, holding main.log and its rotations main1.log to main4.log.
    var logDir: URL { get }
    /// Claude is on this Mac.
    var installed: Bool { get }
    /// Claude's main executable, which identifies its processes.
    func executable() -> String
    /// Claude's main process ids.
    func pids() -> [pid_t]
    /// Ids of the on-screen windows the given processes own.
    func windowIDs(_ owners: [pid_t]) -> Set<Int>
    /// Ask one Claude process to quit the way ⌘Q does. It may ask first, or refuse.
    func requestQuit(_ pid: pid_t) async
    /// Open Claude.
    func launch() async
    /// Open a claude:// link, which shows a chat in Claude's window.
    func open(link: String) async
    /// This app may use Accessibility.
    var trusted: Bool { get }
    /// What Accessibility shows of Claude's windows: roles, and the buttons on alerts and sheets.
    func quitPromptSurvey(in owners: [pid_t]) -> QuitSurvey
    /// Press the button with this title in Claude's quit prompt.
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool
    /// Ask Claude to build its web content's Accessibility tree.
    func exposeWebContent(of owners: [pid_t])
    /// What one chat's message box and its controls show, if the chat is on screen.
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen?
    /// Type `text` into one chat's message box and send it.
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent
    /// Seconds since anyone used this Mac's keyboard, mouse or trackpad.
    func idleSeconds() -> TimeInterval
    /// Post a notification on this Mac: an automatic outcome the person may not be watching.
    func notify(title: String, body: String)
    /// A switch step is about to run, on the switch's own task, after the journal names it.
    /// Nothing happens on a real Mac; a test faults the step here.
    func willStep(_ step: String) async
}

extension ClaudeWorld {
    /// A stand-in Claude is installed unless its test says otherwise.
    var installed: Bool { true }
    func willStep(_ step: String) async {}
}

/// The time the app reads and waits on. Tests advance a virtual one instead of sleeping.
protocol AppClock: Sendable {
    func now() -> Date
    func sleep(_ seconds: TimeInterval) async
}

struct SystemClock: AppClock {
    func now() -> Date { Date() }
    func sleep(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
}

/// The world the app runs against. Production never changes it.
enum World {
    nonisolated(unsafe) private(set) static var claude: any ClaudeWorld = RealClaudeWorld()
    nonisolated(unsafe) private(set) static var clock: any AppClock = SystemClock()
    /// True once a test installed its own world; it never goes back.
    nonisolated(unsafe) private(set) static var isTest = false

    static func now() -> Date { clock.now() }
    static func sleep(_ seconds: TimeInterval) async { await clock.sleep(seconds) }

    /// The real home folder from the user database, which a test cannot redirect with $HOME.
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)).standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }()

    enum Refused: Error, Equatable, CustomStringConvertible {
        case realWorld
        case realBundleId(String)
        case pathInRealHome(String, URL)
        var description: String {
            switch self {
            case .realWorld: return "a test cannot install the real Claude"
            case .realBundleId(let id): return "a test world cannot use Claude's bundle id \(id)"
            case .pathInRealHome(let name, let url): return "a test world's \(name) \(url.path) is inside the real home folder"
            }
        }
    }

    /// Why `world` could reach the person's real Claude, or nil when it is safe for a test.
    static func refusal(_ world: any ClaudeWorld) -> Refused? {
        if world is RealClaudeWorld { return .realWorld }
        if world.bundleId == RealClaudeWorld.realBundleId { return .realBundleId(world.bundleId) }
        let home = realHome.resolvingSymlinksInPath().path
        for (name, url) in [("home", world.home), ("state folder", world.stateDir), ("data folder", world.dataDir),
                            ("log folder", world.logDir), ("executable", URL(fileURLWithPath: world.executable()))] {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path == home || path.hasPrefix(home + "/") || path.hasPrefix("/Applications/") { return .pathInRealHome(name, url) }
        }
        return nil
    }

    /// Run the app against a test world. Refuses, and installs nothing, when the world could
    /// reach the real Claude; from then on the process cannot go back to the real one.
    static func install(_ world: any ClaudeWorld, clock: any AppClock) throws {
        if let why = refusal(world) { throw why }
        claude = world
        self.clock = clock
        isTest = true
    }

    /// The process ids a world reports, minus any that belong to the real Claude: a test world
    /// that names one is a broken test, and nothing it asks may reach that process.
    static func checked(_ pids: [pid_t]) -> [pid_t] {
        guard isTest else { return pids }
        return pids.filter { !isRealClaude($0) }
    }

    static func isRealClaude(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == RealClaudeWorld.realBundleId
    }

    /// Programs a test world never runs: they reach the real Claude, its CLI or the keychain.
    static let realOnlyPrograms: Set<String> = ["/usr/bin/security", "/usr/bin/osascript", "/usr/bin/open", "/bin/ps"]

    /// Whether the app may run `path` in this world. In a test only sqlite3 on test files runs.
    static func permits(_ path: String, _ args: [String]) -> Bool {
        guard isTest else { return true }
        if realOnlyPrograms.contains(path) || path.hasSuffix("/claude") { return false }
        let home = realHome.path
        return !args.contains { $0.hasPrefix(home + "/") || $0 == home }
    }
}

// MARK: - The real Claude

struct RealClaudeWorld: ClaudeWorld {
    static let realBundleId = "com.anthropic.claudefordesktop"

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var stateDir: URL { home.appendingPathComponent("Library/Application Support/ClaudeAccounts") }
    var bundleId: String { Self.realBundleId }
    var dataDir: URL { home.appendingPathComponent("Library/Application Support/Claude") }
    var logDir: URL { home.appendingPathComponent("Library/Logs/Claude") }

    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    func executable() -> String {
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path ?? "/Applications/Claude.app"
        return bundle + "/Contents/MacOS/Claude"
    }

    /// Read from `ps`: asked from a command-line process, LaunchServices once reported a live
    /// Claude as not running, and a switch went on to write under it.
    func pids() -> [pid_t] {
        let exe = executable()
        return runProcessBlocking("/bin/ps", ["-axo", "pid=,comm="], env: nil, cwd: nil, timeout: 10).out
            .split(separator: "\n").compactMap { line in
                let fields = line.trimmingCharacters(in: .whitespaces)
                guard let gap = fields.firstIndex(of: " "),
                      fields[gap...].trimmingCharacters(in: .whitespaces) == exe else { return nil }
                return pid_t(fields[..<gap])
            }
    }

    /// Reading window ids needs no screen-recording permission.
    func windowIDs(_ owners: [pid_t]) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(owner) else { return nil }
            return w[kCGWindowNumber as String] as? Int
        })
    }

    func requestQuit(_ pid: pid_t) async {
        if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
        else { _ = await runProcess("/usr/bin/osascript", ["-e", "tell application id \"\(bundleId)\" to quit"]) }
    }

    func launch() async { _ = await runProcess("/usr/bin/open", ["-b", bundleId]) }

    func open(link: String) async { _ = await runProcess("/usr/bin/open", [link]) }

    var trusted: Bool { QuitPrompt.trusted }
    func quitPromptSurvey(in owners: [pid_t]) -> QuitSurvey { QuitPrompt.survey(in: owners) }
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool { QuitPrompt.press(title, in: owners) }
    func exposeWebContent(of owners: [pid_t]) { ChatComposer.exposeWebContent(of: owners) }
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen? { ChatComposer.screen(session: session, in: owners) }
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent {
        ChatComposer.send(text, session: session, in: owners, trace: trace)
    }
    func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
    func notify(title: String, body: String) { Notify.post(title, body) }
}

// MARK: - Notifications

/// A macOS notification, for a switch nobody watched, posted by the app itself so it shows the
/// app's name and icon. It shows on this Mac only, once macOS allows the app to post them.
enum Notify {
    /// Keeps a notification on screen while the menu is open, when macOS counts the app as in front.
    private final class Presenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .list])
        }
    }
    private static let presenter = Presenter()

    /// Only a process inside the app bundle has the app's identity to post with.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// The menu app calls this at launch. The first time, macOS asks whether Claude Accounts may
    /// post notifications; the command line posts with the answer given there.
    static func requestPermission() {
        center?.delegate = presenter
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether macOS lets the app post notifications, for --status.
    static func permission() -> String {
        guard let center else { return "unknown: not run from the app bundle" }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status = UNAuthorizationStatus.notDetermined
        center.getNotificationSettings { status = $0.authorizationStatus; done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else { return "unknown" }
        switch status {
        case .authorized, .provisional, .ephemeral: return "allowed"
        case .denied: return "not allowed (System Settings > Notifications > Claude Accounts)"
        default: return "not asked yet: the menu app asks at launch"
        }
    }

    /// Post at once, and return once macOS has the request, because the command line exits next.
    static func post(_ title: String, _ body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let done = DispatchSemaphore(value: 0)
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }
}

// MARK: - Claude's files

/// File names and settings keys of Claude's own files.
enum ClaudeFiles {
    static let cookies = "Cookies"
    static let cookiesJournal = "Cookies-journal"
    static let config = "config.json"
    static let sessions = "claude-code-sessions"
    static let log = "main.log"
    /// main.log is renamed to main1.log, main1 to main2 and so on, when it rotates.
    static func rotatedLog(_ n: Int) -> String { "main\(n).log" }
    static let rotations = 1...4
    /// The cookie that holds Claude's sign-in.
    static let signInCookie = "sessionKey"
    /// The cookie hosts that hold the sign-in, as an SQL list, and the cookie database's schema version.
    static let cookieHosts = "('.claude.ai','claude.ai')"
    static let cookieSchemaVersion = "24"
    /// config.json: the account Claude last ran as, and its cached tokens.
    static let lastKnownAccount = "lastKnownAccountUuid"
    static let loginConfigKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", lastKnownAccount]
    /// A session record's keys.
    static let sessionId = "sessionId"
    static let title = "title"
    static let isArchived = "isArchived"
    static let scheduledTaskId = "scheduledTaskId"
    static let interruptedByQuitAt = "interruptedByQuitAt"
    static let lastActivityAt = "lastActivityAt"
    /// What a chat still had running as Claude quit, written into its record at a quit that found
    /// work armed and cleared at Claude's next start: `{at, exitKind, cronCount, durableCronCount,
    /// wakeupScheduledFor, backgroundTaskCount}`. `at` is the quit's time in epoch ms, `exitKind`
    /// "quit" or "update_restart". `backgroundTaskCount` counts the background tasks the quit
    /// stopped, every kind but a remote agent: subagents, workflows, and background shells such
    /// as a dev server alike, which the record doesn't tell apart.
    static let armedWorkAtQuit = "armedWorkAtQuit"
    static let armedAt = "at"
    static let exitKind = "exitKind"
    static let exitKindQuit = "quit"
    static let backgroundTaskCount = "backgroundTaskCount"
    /// The Claude Code CLI's profile file in a login folder, and its account key.
    static let cliProfile = ".claude.json"
    static let cliAccount = "oauthAccount"
    /// The link that shows one chat in Claude's window.
    static func continueLink(_ session: String) -> String { "claude://code/continue?session=\(session)" }
}

// MARK: - Claude's log

/// The shapes of the lines in Claude's main.log the app reads. ClaudeEvents in Rules.swift reads them.
enum ClaudeLog {
    /// Every line starts with Claude's local time in this format.
    static let timeFormat = "yyyy-MM-dd HH:mm:ss"
    /// A new run of Claude.
    static let appStart = "Starting app {"
    /// Claude signed in as an account and organization, named by `accountId=` and `orgId=`.
    static let identity = "[LocalSessionManager] Initialization succeeded"
    static let accountField = "accountId="
    static let orgField = "orgId="
    /// Claude refused an organization's sign-in and falls back to another.
    static let refusal = "session_stale_relogin"
    /// Sign-out lines.
    static let signOut = ["Navigated to /logout", "loggedOut: false \u{2192} true"]
    /// Per-chat turn health, followed by the session id (`local_…`).
    static let cycle = "[CCD CycleHealth] "
    static let healthyCycle = "[CCD CycleHealth] healthy cycle for "
    static let unhealthyCycle = "[CCD CycleHealth] unhealthy cycle for "
    static let sessionPrefix = "local_"
    static let quitReason = "reason=app_quit"
    static let apiError = " api_error ("
    /// The texts of an api_error that mean a usage limit stopped the chat.
    static let limitTexts = [
        "You've hit your", "You've reached your", "You're out of usage credits", "You're out of extra usage",
        "Your org is out of usage", "Your seat type doesn't include", "Your usage allocation has been disabled",
        "Your group's usage limit is set to $0", "requires usage credits",
    ]
}

// MARK: - Claude's Accessibility elements

/// The names of the controls the app looks for in Claude's windows.
enum ClaudeUI {
    /// The quit prompt's button that quits with chats still running.
    static let quitAnyway = "Quit anyway"
    /// The quit prompt's button that keeps Claude open; an automatic switch that gives up presses it.
    static let cancel = "Cancel"
    /// The role of the element that holds one chat; its URL ends in the session id.
    static let chatRole = "AXWebArea"
    /// The message box's accessibility name.
    static let promptName = "prompt"
    /// Send controls' names, lowercased.
    static let sendNames: Set<String> = ["send", "send message", "send prompt", "submit"]
    /// Stop controls' names, lowercased: a turn is running.
    static let stopNames: Set<String> = ["stop", "stop response", "stop generating", "interrupt"]
    /// Words in a control's name that the app never presses.
    static let neverPress = ["retry", "rewind", "stop", "interrupt", "fork", "cancel", "delete", "remove",
                             "edit", "copy", "undo", "clear", "reject", "deny", "dismiss", "discard"]
}

// MARK: - Running processes

struct ProcResult {
    let status: Int32
    let out: String
    let err: String
}

/// Run a process to completion on a background thread. The work blocks, so it runs on a
/// dispatch queue rather than tying up one of Swift concurrency's few cooperative threads.
func runProcess(_ path: String, _ args: [String], env: [String: String]? = nil,
                cwd: URL? = nil, timeout: TimeInterval = 30) async -> ProcResult {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            cont.resume(returning: runProcessBlocking(path, args, env: env, cwd: cwd, timeout: timeout))
        }
    }
}

/// Drains both pipes concurrently so a large output (the keychain dump) can't fill a
/// pipe and deadlock, and terminates the process if it outlives the timeout. A test world
/// never runs a program that reaches the real Claude or the keychain.
func runProcessBlocking(_ path: String, _ args: [String], env: [String: String]?,
                        cwd: URL?, timeout: TimeInterval) -> ProcResult {
    guard World.permits(path, args) else {
        return ProcResult(status: -1, out: "", err: "\(path) is not run in a test world")
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    if let env { proc.environment = env }
    if let cwd { proc.currentDirectoryURL = cwd }
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    proc.standardInput = FileHandle.nullDevice
    do { try proc.run() } catch {
        return ProcResult(status: -1, out: "", err: error.localizedDescription)
    }
    let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    proc.waitUntilExit()
    killer.cancel()
    return ProcResult(status: proc.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
}
