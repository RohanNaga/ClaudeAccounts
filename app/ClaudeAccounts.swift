// Claude Accounts: menu bar usage monitor for several Claude accounts.
//
// Everything the app writes lives in ~/Library/Application Support/ClaudeAccounts,
// so the app itself can sit anywhere. Each account gets its own private Claude Code
// login in logins/<id> there, used only to read usage; its token sits in the login
// keychain, and removing the account deletes it. The app
// reads Claude's log to show which account the Claude desktop app is using, and
// writes to Claude's files only when you click Switch or Set Up, with Claude quit.

import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI

// MARK: - Paths and constants

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// Where the app keeps its state, so the app bundle can be installed anywhere.
    static let stateDir = home.appendingPathComponent("Library/Application Support/ClaudeAccounts")
    /// Before 0.3 the state sat in a `data` folder beside the app bundle.
    static let legacyStateDir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data")
    static let accountsFile = stateDir.appendingPathComponent("accounts.json")
    static let loginsDir = stateDir.appendingPathComponent("logins")
}

enum API {
    static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let oauthBeta = "oauth-2025-04-20"
    static let keychainPrefix = "Claude Code-credentials"
    /// Renew when the access token has less than this left, so a poll never races expiry.
    static let refreshMargin: TimeInterval = 10 * 60
    /// A login has a fixed deadline about four weeks out that renewals don't extend; ask
    /// for a fresh sign-in this long before it lapses.
    static let signInWarning: TimeInterval = 24 * 3600
}

// MARK: - Process helpers

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
/// pipe and deadlock, and terminates the process if it outlives the timeout.
private func runProcessBlocking(_ path: String, _ args: [String], env: [String: String]?,
                                cwd: URL?, timeout: TimeInterval) -> ProcResult {
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

enum ClaudeCLI {
    /// The CLI isn't on a menu bar app's PATH, so look in the usual install locations.
    static var path: String? {
        let candidates = [
            Paths.home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Environment pinned to one account's config directory, built from scratch so
    /// nothing from the launching process changes how the CLI authenticates.
    static func env(configDir: URL) -> [String: String] {
        [
            "HOME": Paths.home.path,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:" + Paths.home.appendingPathComponent(".local/bin").path,
            "LANG": "en_US.UTF-8",
            "CLAUDE_CONFIG_DIR": configDir.path,
        ]
    }

    /// Runs from inside the account's own config dir, so anything the CLI writes stays there.
    static func run(configDir: URL, _ args: [String], timeout: TimeInterval = 30) async -> ProcResult {
        guard let path else { return ProcResult(status: -1, out: "", err: "Claude Code CLI not found") }
        return await runProcess(path, args, env: env(configDir: configDir), cwd: configDir, timeout: timeout)
    }
}

// MARK: - Keychain

struct Credential: Decodable {
    let accessToken: String
    let expiresAt: Double
    let refreshTokenExpiresAt: Double?
    let subscriptionType: String?
}

enum Keychain {
    /// Names of every Claude Code credential item in the login keychain.
    static func services() async -> Set<String> {
        let res = await runProcess("/usr/bin/security", ["dump-keychain"])
        var names = Set<String>()
        let marker = "\"svce\"<blob>=\""
        for line in res.out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(marker + API.keychainPrefix) else { continue }
            names.insert(String(trimmed.dropFirst(marker.count).dropLast()))
        }
        return names
    }

    /// Read one login through /usr/bin/security, the tool Claude Code itself stores
    /// it with, so the item's existing access list applies and no prompt appears.
    static func credential(service: String) async -> Credential? {
        let res = await runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard res.status == 0 else { return nil }
        struct Wrapper: Decodable { let claudeAiOauth: Credential? }
        return (try? JSONDecoder().decode(Wrapper.self, from: Data(res.out.utf8)))?.claudeAiOauth
    }

    static func delete(service: String) async {
        _ = await runProcess("/usr/bin/security", ["delete-generic-password", "-s", service])
    }

    /// The item's account attribute and raw secret, kept so a sign-in can be rolled back.
    static func snapshot(service: String) async -> (account: String, secret: String)? {
        let meta = await runProcess("/usr/bin/security", ["find-generic-password", "-s", service])
        let secret = await runProcess("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard meta.status == 0, secret.status == 0,
              let line = meta.out.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=") }),
              let value = line.split(separator: "=", maxSplits: 1).last else { return nil }
        let account = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return (account, secret.out.trimmingCharacters(in: .newlines))
    }

    /// The item name Claude Code uses for a login folder: a hash of the folder's path.
    static func service(forConfigDir dir: URL) -> String {
        let digest = SHA256.hash(data: Data(dir.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(API.keychainPrefix)-\(digest.prefix(8))"
    }

    static func restore(service: String, _ snap: (account: String, secret: String)) async {
        _ = await runProcess("/usr/bin/security",
                             ["add-generic-password", "-U", "-s", service, "-a", snap.account, "-w", snap.secret])
    }
}

// MARK: - Accounts on disk

struct AccountRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var color: String
    var configDir: String
    var keychainService: String
    let email: String?
    let accountUuid: String?
    let orgName: String?

    var configURL: URL { URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath) }

    /// The label without its domain, for the menu bar where space is tight.
    var shortName: String { name.split(separator: "@").first.map(String.init) ?? name }
}

enum AccountStore {
    private struct File: Codable { var accounts: [AccountRecord] }

    static func load() -> [AccountRecord] {
        guard let data = try? Data(contentsOf: Paths.accountsFile) else { return [] }
        return (try? JSONDecoder().decode(File.self, from: data))?.accounts ?? []
    }

    static func save(_ accounts: [AccountRecord]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(File(accounts: accounts)).write(to: Paths.accountsFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.accountsFile.path)
    }
}

// MARK: - Moving state out of the app's folder

enum Migration {
    /// Move a pre-0.3 `data` folder beside the app into Application Support. A login's keychain
    /// item is named after its folder's path, so each one is copied to the name its new path
    /// hashes to, checked, and only then removed under the old name.
    static func moveLegacyState() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.legacyStateDir.appendingPathComponent("accounts.json").path),
              !fm.fileExists(atPath: Paths.stateDir.path) else { return }
        do {
            try fm.createDirectory(at: Paths.stateDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: Paths.legacyStateDir, to: Paths.stateDir)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.stateDir.path)
        } catch {
            NSLog("ClaudeAccounts: could not move \(Paths.legacyStateDir.path): \(error)")
            return
        }
        var accounts = AccountStore.load()
        for i in accounts.indices {
            let dir = Paths.loginsDir.appendingPathComponent(accounts[i].id)
            let old = accounts[i].keychainService, new = Keychain.service(forConfigDir: dir)
            if old != new, copyItem(from: old, to: new) {
                _ = runProcessBlocking("/usr/bin/security", ["delete-generic-password", "-s", old], env: nil, cwd: nil, timeout: 10)
            }
            accounts[i].configDir = dir.path.replacingOccurrences(of: Paths.home.path, with: "~")
            accounts[i].keychainService = new
        }
        try? AccountStore.save(accounts)
    }

    /// Copy one login to a new item name and read it back; the old item stays until this succeeds.
    private static func copyItem(from old: String, to new: String) -> Bool {
        let meta = runProcessBlocking("/usr/bin/security", ["find-generic-password", "-s", old], env: nil, cwd: nil, timeout: 10)
        let secret = runProcessBlocking("/usr/bin/security", ["find-generic-password", "-s", old, "-w"], env: nil, cwd: nil, timeout: 10)
        guard meta.status == 0, secret.status == 0,
              let line = meta.out.split(separator: "\n").first(where: { $0.contains("\"acct\"<blob>=") }),
              let value = line.split(separator: "=", maxSplits: 1).last else { return false }
        let account = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let stored = secret.out.trimmingCharacters(in: .newlines)
        _ = runProcessBlocking("/usr/bin/security", ["add-generic-password", "-U", "-s", new, "-a", account, "-w", stored],
                               env: nil, cwd: nil, timeout: 10)
        let check = runProcessBlocking("/usr/bin/security", ["find-generic-password", "-s", new, "-w"], env: nil, cwd: nil, timeout: 10)
        return check.status == 0 && check.out.trimmingCharacters(in: .newlines) == stored
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

/// Menu bar preferences, kept in settings.json in the app's state folder.
struct AppSettings: Codable, Equatable {
    var display: MenuBarDisplay = .gaugeNamePercent
    var metric: UsageMetric = .fiveHour

    private static var url: URL { Paths.stateDir.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

// MARK: - Usage

struct UsageWindow: Equatable, Codable {
    let pct: Int
    let resetsAt: Date?

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

    init?(_ raw: Any?) {
        guard let dict = raw as? [String: Any], let util = dict["utilization"] as? Double else { return nil }
        pct = Int(util.rounded())
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

enum AccountState: Equatable {
    case loading
    case ok(plan: String?, fiveHour: UsageWindow?, weekly: UsageWindow?, loginExpiresAt: Date?)
    case needsLogin(String)
    case error(String)
    /// The usage service asked us to wait; nothing has been read for this account yet.
    case rateLimited(until: Date)

    /// Signed out, or within a day of the login's fixed deadline.
    var needsSignIn: Bool {
        switch self {
        case .needsLogin: return true
        case .ok(_, _, _, let expires?): return expires.timeIntervalSinceNow < API.signInWarning
        default: return false
        }
    }
}

enum Usage {
    /// Return a login with time left on its access token, renewing through the CLI if needed.
    static func freshCredential(_ acct: AccountRecord) async -> Credential? {
        if let cred = await Keychain.credential(service: acct.keychainService),
           cred.expiresAt / 1000 - Date().timeIntervalSince1970 > API.refreshMargin {
            return cred
        }
        // `auth status` only reads the stored login; `/usage` calls the API, which makes the CLI
        // renew the token and write the rotated refresh token back itself. It spends no model usage.
        _ = await ClaudeCLI.run(configDir: acct.configURL, ["-p", "/usage", "--no-session-persistence"],
                                timeout: 90)
        return await Keychain.credential(service: acct.keychainService)
    }

    /// Usage snapshot for one account. Never throws, so one bad login can't blank the others.
    static func state(for acct: AccountRecord) async -> AccountState {
        // Past the fixed deadline no renewal can succeed, so skip straight to asking.
        if let stored = await Keychain.credential(service: acct.keychainService),
           let deadline = stored.refreshTokenExpiresAt, deadline / 1000 < Date().timeIntervalSince1970 {
            return .needsLogin("Login expired.")
        }
        guard let cred = await freshCredential(acct) else {
            return .needsLogin("No stored login.")
        }
        var req = URLRequest(url: API.usage, timeoutInterval: 15)
        req.setValue("Bearer " + cred.accessToken, forHTTPHeaderField: "Authorization")
        req.setValue(API.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .needsLogin("Login was rejected.") }
            if code == 429 {
                let wait = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 300
                return .rateLimited(until: Date().addingTimeInterval(wait))
            }
            guard code == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Usage service answered HTTP \(code).")
            }
            return .ok(plan: cred.subscriptionType,
                       fiveHour: UsageWindow(body["five_hour"]),
                       weekly: UsageWindow(body["seven_day"]),
                       loginExpiresAt: cred.refreshTokenExpiresAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

// MARK: - Switching the Claude app's account

/// The account Claude is signed in to and the organization whose Code sessions it shows.
struct Identity: Equatable, Codable, Sendable {
    let account: String
    let org: String
}

/// The Claude desktop app's files that make up "which account is signed in". Switching
/// swaps exactly these while Claude is closed, and moves open Code sessions' owner
/// records to the target account's folder so the same sessions appear after the switch.
enum ClaudeApp {
    static let bundleId = "com.anthropic.claudefordesktop"
    static let dataDir = Paths.home.appendingPathComponent("Library/Application Support/Claude")
    static let cookies = dataDir.appendingPathComponent("Cookies")
    static let cookiesJournal = dataDir.appendingPathComponent("Cookies-journal")
    static let config = dataDir.appendingPathComponent("config.json")
    static let sessions = dataDir.appendingPathComponent("claude-code-sessions")
    static let logDir = Paths.home.appendingPathComponent("Library/Logs/Claude")
    static let log = logDir.appendingPathComponent("main.log")

    static var executable: String {
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path ?? "/Applications/Claude.app"
        return bundle + "/Contents/MacOS/Claude"
    }

    /// Claude's main process ids, read from `ps`. Asked from a command-line process, LaunchServices
    /// once reported a live Claude as not running, and a switch went on to write under it.
    static func pids() -> [pid_t] {
        let exe = executable
        return runProcessBlocking("/bin/ps", ["-axo", "pid=,comm="], env: nil, cwd: nil, timeout: 10).out
            .split(separator: "\n").compactMap { line in
                let fields = line.trimmingCharacters(in: .whitespaces)
                guard let gap = fields.firstIndex(of: " "),
                      fields[gap...].trimmingCharacters(in: .whitespaces) == exe else { return nil }
                return pid_t(fields[..<gap])
            }
    }

    enum QuitResult { case quit, declined, failed }

    /// Ids of Claude's on-screen windows. Reading ids needs no screen-recording permission.
    static func windowIDs(_ owners: [pid_t]) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(owner) else { return nil }
            return w[kCGWindowNumber as String] as? Int
        })
    }

    /// Quit the way ⌘Q does, then wait until the process is gone, so Claude has flushed its
    /// cookies and settings. With a chat mid-reply Claude first asks whether to quit, in a
    /// window of its own. Claude logs nothing when that prompt is cancelled, so the answer is
    /// read from the prompt closing: a Quit makes Claude try to quit again, which it logs, and
    /// a Cancel leaves it running. The timeout covers a prompt that isn't a separate window.
    static func quit(timeout: TimeInterval = 90, progress: @Sendable (String) -> Void = { _ in }) async -> QuitResult {
        let running = pids()
        guard !running.isEmpty else { return .quit }
        let mark = logMark()
        let windowsBefore = windowIDs(running)
        for pid in running {
            if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
            else { _ = await runProcess("/usr/bin/osascript", ["-e", "tell application id \"\(bundleId)\" to quit"]) }
        }
        var asked = false
        var promptSeen = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if pids().isEmpty { return .quit }
            guard logText(since: mark).contains("vetoed by before-quit interceptor") else { continue }
            if !asked {
                asked = true
                progress("Claude is asking whether to quit while a chat runs…")
            }
            if !windowIDs(running).subtracting(windowsBefore).isEmpty { promptSeen = true; continue }
            guard promptSeen else { continue }
            // The prompt has closed. Give a Quit a moment to show up in the log.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if pids().isEmpty { return .quit }
            let later = logText(since: mark)
            let afterVeto = later.range(of: "vetoed by before-quit interceptor").map { later[$0.upperBound...] } ?? ""
            if !afterVeto.contains("beforeQuit: handler fired") { return .declined }
        }
        return asked ? .declined : .failed
    }

    static func launch() async {
        _ = await runProcess("/usr/bin/open", ["-b", bundleId])
    }

    /// The account in Claude's settings, which Claude rewrites whenever its account changes.
    static func savedAccount() -> String? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lastKnownAccountUuid"] as? String
    }

    // MARK: Log

    /// A place in Claude's log that survives rotation, which renames main.log to main1.log.
    struct LogMark: Equatable { let inode: UInt64; let offset: UInt64 }

    static func logMark(_ url: URL = log) -> LogMark {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LogMark(inode: (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                       offset: (attrs?[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Whole lines from `offset` on, and the offset just past the last one read.
    static func readLines(_ url: URL, from offset: UInt64) -> (text: String, end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", offset) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ("", offset) }
        let whole = data[data.startIndex...last]
        return (String(decoding: whole, as: UTF8.self), offset + UInt64(whole.count))
    }

    /// Everything Claude logged after `mark`, following main.log across a rotation.
    static func logText(since mark: LogMark) -> String {
        if logMark().inode == mark.inode { return readLines(log, from: mark.offset).text }
        let rotated = (1...4).map { logDir.appendingPathComponent("main\($0).log") }
            .first { logMark($0).inode == mark.inode }
        return (rotated.map { readLines($0, from: mark.offset).text } ?? "") + readLines(log, from: 0).text
    }

    /// Who Claude says it is after reading `text`, starting from `start`. The Code tab's session
    /// manager logs the account and organization whose sessions it loads at every launch and
    /// every account change; a sign-out or a restart clears it until the next such line.
    static func identity(after text: String, from start: Identity?) -> Identity? {
        var current = start
        for line in text.split(separator: "\n") {
            if line.contains("[LocalSessionManager] Initialization succeeded"),
               let account = field(line, "accountId="), let org = field(line, "orgId=") {
                current = Identity(account: account, org: org)
            } else if line.contains("Starting app {") || signsOut(line) {
                current = nil
            }
        }
        return current
    }

    static func signsOut<S: StringProtocol>(_ line: S) -> Bool {
        line.contains("Navigated to /logout") || line.contains("loggedOut: false → true")
    }

    private static func field<S: StringProtocol>(_ line: S, _ key: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let value = line[r.upperBound...].prefix { $0.isHexDigit || $0 == "-" }
        return value.count == 36 ? String(value) : nil
    }

    /// Who Claude is signed in as now, or was when it last quit, from its own log.
    static func currentIdentity() -> Identity? {
        let older = readLines(logDir.appendingPathComponent("main1.log"), from: 0).text
        return identity(after: readLines(log, from: 0).text, from: identity(after: older, from: nil))
    }

    // MARK: Sessions

    static func folder(_ id: Identity) -> URL {
        sessions.appendingPathComponent(id.account).appendingPathComponent(id.org)
    }

    /// Records of the sessions shown in the sidebar: not archived, not a scheduled-task run.
    static func openSessionRecords(in orgFolder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: orgFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { url in
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                  let obj = record(url) else { return false }
            return (obj["isArchived"] as? Bool) != true && obj["scheduledTaskId"] == nil
        }
    }

    static func record(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func lastActivity(_ url: URL) -> Double { (record(url)?["lastActivityAt"] as? Double) ?? 0 }
}

/// Follows Claude's log, reading only what is new, so the menu shows the account Claude reports.
final class IdentityWatcher {
    private var mark: ClaudeApp.LogMark?
    private(set) var identity: Identity?

    func poll() -> Identity? {
        let now = ClaudeApp.logMark()
        if let mark, mark.inode == now.inode, mark.offset <= now.offset {
            let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: mark.offset)
            identity = ClaudeApp.identity(after: text, from: identity)
            self.mark = ClaudeApp.LogMark(inode: now.inode, offset: end)
        } else {
            identity = ClaudeApp.currentIdentity()
            self.mark = ClaudeApp.LogMark(inode: now.inode, offset: ClaudeApp.readLines(ClaudeApp.log, from: 0).end)
        }
        return identity
    }
}

/// One account's saved Claude app login: its claude.ai cookie rows (still encrypted with
/// Claude's own key, never decrypted here) and the Code tab's token cache from config.json.
enum LoginSlot {
    static let hosts = "('.claude.ai','claude.ai')"
    static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    static let cookieSchemaVersion = "24"

    static func dir(_ acct: AccountRecord) -> URL { Paths.stateDir.appendingPathComponent("slots/\(acct.id)") }
    static func exists(_ acct: AccountRecord) -> Bool {
        FileManager.default.fileExists(atPath: dir(acct).appendingPathComponent("cookies.db").path)
            && identity(acct) != nil
    }

    /// `orgFolder` is the organization whose sessions Claude showed when this login was saved.
    struct Meta: Codable { var account: String?; var orgFolder: String?; var config: [String: String] }

    static func meta(_ acct: AccountRecord) -> Meta? {
        guard let data = try? Data(contentsOf: dir(acct).appendingPathComponent("slot.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Where the account's sessions go: set only when the saved login is the account's own.
    static func identity(_ acct: AccountRecord) -> Identity? {
        guard let uuid = acct.accountUuid, let meta = meta(acct), let org = meta.orgFolder,
              meta.config["lastKnownAccountUuid"] == uuid, (meta.account ?? uuid) == uuid else { return nil }
        return Identity(account: uuid, org: org)
    }

    static func sqlite(_ db: URL, _ sql: String) async -> ProcResult {
        await runProcess("/usr/bin/sqlite3", ["-bail", db.path, sql])
    }

    static func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "''") + "'" }

    static func cookieVersion(_ db: URL) async -> String {
        await sqlite(db, "select value from meta where key='version';").out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save the login Claude just quit with. `identity` is who Claude said it was, and the
    /// settings must agree, so a login is never saved under the wrong account.
    static func capture(_ acct: AccountRecord, as identity: Identity) async throws {
        guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
        guard ClaudeApp.savedAccount() == identity.account else { throw SwitchError.inconsistent }
        let fm = FileManager.default
        let slot = dir(acct)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = slot.appendingPathComponent("source.db")
        for f in [source, slot.appendingPathComponent("source.db-journal")] { try? fm.removeItem(at: f) }
        try fm.copyItem(at: ClaudeApp.cookies, to: source)
        if fm.fileExists(atPath: ClaudeApp.cookiesJournal.path) {
            try fm.copyItem(at: ClaudeApp.cookiesJournal, to: slot.appendingPathComponent("source.db-journal"))
        }
        defer { for f in [source, slot.appendingPathComponent("source.db-journal")] { try? fm.removeItem(at: f) } }
        guard await sqlite(source, "pragma quick_check;").out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw SwitchError.sqlite("Claude's cookie database failed its integrity check")
        }
        guard await cookieVersion(source) == cookieSchemaVersion else { throw SwitchError.cookieSchemaChanged }

        let fresh = slot.appendingPathComponent("cookies.new.db")
        try? fm.removeItem(at: fresh)
        let res = await sqlite(fresh, "ATTACH \(quoted(source)) AS c; CREATE TABLE cookies AS SELECT * FROM c.cookies WHERE host_key IN \(hosts);")
        guard res.status == 0 else { throw SwitchError.sqlite(res.err) }
        let count = await sqlite(fresh, "select count(*) from cookies where name='sessionKey';").out
        guard count.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { throw SwitchError.notSignedIn }

        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeApp.config)) as? [String: Any] ?? [:]
        var keys: [String: String] = [:]
        for k in configKeys { if let v = config[k] as? String { keys[k] = v } }
        let meta = try JSONEncoder().encode(Meta(account: identity.account, orgFolder: identity.org, config: keys))
        _ = try fm.replaceItemAt(slot.appendingPathComponent("cookies.db"), withItemAt: fresh)
        try meta.write(to: slot.appendingPathComponent("slot.json"), options: .atomic)
        for f in ["cookies.db", "slot.json"] { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: slot.appendingPathComponent(f).path) }
    }

    /// Put a saved login into Claude's files, or with nil clear them so Claude opens at its
    /// sign-in page. Claude must be closed.
    static func load(_ acct: AccountRecord?) async throws {
        guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
        var values: [String: String] = [:]
        var insert = ""
        if let acct {
            guard identity(acct) != nil, let meta = meta(acct) else { throw SwitchError.noSlot(acct.name) }
            values = meta.config
            insert = "ATTACH \(quoted(dir(acct).appendingPathComponent("cookies.db"))) AS s; "
        }
        guard await cookieVersion(ClaudeApp.cookies) == cookieSchemaVersion else { throw SwitchError.cookieSchemaChanged }
        let sql = insert + "BEGIN; DELETE FROM main.cookies WHERE host_key IN \(hosts); "
            + (acct == nil ? "" : "INSERT INTO main.cookies SELECT * FROM s.cookies; ") + "COMMIT;"
        let res = await sqlite(ClaudeApp.cookies, sql)
        guard res.status == 0 else { throw SwitchError.sqlite(res.err) }

        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeApp.config)) as? [String: Any] ?? [:]
        for k in configKeys { config[k] = values[k] }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try data.write(to: ClaudeApp.config, options: .atomic)
    }
}

enum SwitchError: LocalizedError {
    case noSlot(String), notSignedIn, cookieSchemaChanged, sqlite(String), quitFailed, inconsistent
    var errorDescription: String? {
        switch self {
        case .noSlot(let name): return "\(name) isn't set up in Claude yet; use Set Up on its row first."
        case .notSignedIn: return "Claude isn't signed in, so there was no login to save."
        case .cookieSchemaChanged: return "Claude's cookie format changed in an update; switching is paused until this app is updated."
        case .sqlite(let err): return "Could not update Claude's cookies: \(err.prefix(160))"
        case .quitFailed: return "Claude is running again, so nothing more was changed."
        case .inconsistent: return "Claude's settings name a different account than its log. Open and quit Claude once, then try again."
        }
    }
}

/// The result of one switch, for the menu or for `--switch` on the command line.
struct SwitchOutcome: Codable {
    var ok: Bool
    var message: String
    var moved = 0
    var confirmed = false
    var backup: String? = nil
}

/// One switch at a time across the menu and `--switch`, which are separate processes.
struct SwitchLock {
    let fd: Int32

    static func acquire() -> SwitchLock? {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let fd = open(Paths.stateDir.appendingPathComponent(".switch.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return SwitchLock(fd: fd)
    }

    func release() { flock(fd, LOCK_UN); close(fd) }
}

/// Written before a switch changes anything and removed once Claude confirms the result, so
/// an interrupted switch can always be undone: the backup plus every file move made so far.
struct SwitchJournal: Codable {
    struct Move: Codable { var from: String; var to: String }
    var backup: String
    var from: Identity?
    var to: Identity?
    var moves: [Move] = []

    static let url = Paths.stateDir.appendingPathComponent("switch-journal.json")
    static func load() -> SwitchJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SwitchJournal.self, from: data)
    }
    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// Switching, free of any UI so the menu's button and `ClaudeAccounts --switch` run one code path.
enum SwitchEngine {
    typealias Progress = @Sendable (String) -> Void

    /// Quit Claude, save the current account's login, load the target's, move the open Code
    /// sessions into the target's folder, reopen Claude, and keep the result only once Claude
    /// reports the target account; anything else is undone.
    static func run(to target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress) async -> SwitchOutcome {
        await locked { await switchLocked(to: target, accounts: accounts, progress: progress) }
    }

    /// Quit Claude, save the current account's login, and reopen Claude at its sign-in page, so
    /// another account can sign in without signing the current one out.
    static func setUp(_ target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress) async -> SwitchOutcome {
        await locked { await setUpLocked(target, accounts: accounts, progress: progress) }
    }

    private static func locked(_ body: () async -> SwitchOutcome) async -> SwitchOutcome {
        guard let lock = SwitchLock.acquire() else { return SwitchOutcome(ok: false, message: "Another switch is already running.") }
        defer { lock.release() }
        if let journal = SwitchJournal.load() {
            let undone = await rollback(journal, progress: { _ in })
            return SwitchOutcome(ok: false, message: undone ? "The last switch was interrupted, so it was undone. Try again."
                                                           : "The last switch was interrupted, and undoing it needs Claude to quit.")
        }
        return await body()
    }

    private static func switchLocked(to target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress) async -> SwitchOutcome {
        guard let want = LoginSlot.identity(target) else {
            return SwitchOutcome(ok: false, message: SwitchError.noSlot(target.name).localizedDescription)
        }
        let before = ClaudeApp.currentIdentity()
        if before?.account == want.account {
            if ClaudeApp.pids().isEmpty { await ClaudeApp.launch() }
            return SwitchOutcome(ok: true, message: "Already using \(target.name).", confirmed: true)
        }

        let current: (acct: AccountRecord, id: Identity)?
        switch await prepare(accounts: accounts, progress: progress) {
        case .failure(let e): return e.outcome
        case .success(let c): current = c
        }
        guard var journal = startJournal(from: current?.id, to: want) else {
            await ClaudeApp.launch()
            return SwitchOutcome(ok: false, message: "Could not back up Claude's files, so nothing was changed.")
        }
        do {
            if let current {
                progress("Saving \(current.acct.name)…")
                try await LoginSlot.capture(current.acct, as: current.id)
            }
            progress("Loading \(target.name)…")
            try await LoginSlot.load(target)
            if let current { try moveSessions(from: current.id, to: want, journal: &journal) }
        } catch {
            _ = await rollback(journal, progress: progress)
            return SwitchOutcome(ok: false, message: "Switch failed and was undone: \(error.localizedDescription)")
        }

        progress("Opening Claude as \(target.name)…")
        let mark = ClaudeApp.logMark()
        await ClaudeApp.launch()
        let moved = journal.moves.filter { !$0.to.contains("/quarantine/") }.count
        switch await confirm(want, since: mark) {
        case .confirmed:
            // Keep the record of what moved beside the backup it belongs to.
            try? FileManager.default.moveItem(at: SwitchJournal.url,
                                              to: URL(fileURLWithPath: journal.backup).appendingPathComponent("switch.json"))
            pruneBackups()
            let sessions = "\(moved) open session\(moved == 1 ? "" : "s")"
            return SwitchOutcome(ok: true, message: "Switched to \(target.name), with \(sessions).",
                                 moved: moved, confirmed: true, backup: journal.backup)
        case .signedOut:
            let undone = await rollback(journal, progress: progress)
            return SwitchOutcome(ok: false, message: "\(target.name)'s saved login has expired, so "
                                 + (undone ? "the switch was undone. Use Set Up on its row to sign in again."
                                           : "Claude opened signed out. Quit Claude and click Switch to undo."))
        case .other(let seen):
            let who = accounts.first { $0.accountUuid == seen?.account }?.name ?? (seen == nil ? "no account" : "another account")
            let what = seen?.account == want.account ? "\(target.name) in a different organization than its saved login"
                                                     : "\(who) instead of \(target.name)"
            let undone = await rollback(journal, progress: progress)
            return SwitchOutcome(ok: false, message: "Claude opened as \(what), so "
                                 + (undone ? "the switch was undone." : "the switch needs undoing: quit Claude and click Switch."))
        }
    }

    private static func setUpLocked(_ target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress) async -> SwitchOutcome {
        let current: (acct: AccountRecord, id: Identity)?
        switch await prepare(accounts: accounts, progress: progress) {
        case .failure(let e): return e.outcome
        case .success(let c): current = c
        }
        guard let journal = startJournal(from: current?.id, to: nil) else {
            await ClaudeApp.launch()
            return SwitchOutcome(ok: false, message: "Could not back up Claude's files, so nothing was changed.")
        }
        do {
            if let current {
                progress("Saving \(current.acct.name)…")
                try await LoginSlot.capture(current.acct, as: current.id)
            }
            try await LoginSlot.load(nil)
        } catch {
            _ = await rollback(journal, progress: progress)
            return SwitchOutcome(ok: false, message: "Set up failed and was undone: \(error.localizedDescription)")
        }
        // The sign-in itself happens in Claude; the next switch away from it saves the login.
        SwitchJournal.clear()
        await ClaudeApp.launch()
        return SwitchOutcome(ok: true, message: "Sign in to Claude as \(target.email ?? target.name). Your open sessions stay with "
                             + (current?.acct.name ?? "the previous account") + "; Switch brings them over.")
    }

    /// Resolve who Claude is, quit it, and check again once it has gone. Nothing is written here.
    private static func prepare(accounts: [AccountRecord], progress: @escaping Progress)
        async -> Result<(acct: AccountRecord, id: Identity)?, OutcomeError> {
        let before = ClaudeApp.currentIdentity()
        if let before, !accounts.contains(where: { $0.accountUuid == before.account }) {
            return .failure(OutcomeError("Claude is signed in to an account this app doesn't know. Add it first."))
        }
        progress("Quitting Claude…")
        switch await ClaudeApp.quit(progress: progress) {
        case .quit: break
        case .declined: return .failure(OutcomeError("Claude stayed open because a chat is still running. Nothing was changed."))
        case .failed: return .failure(OutcomeError("Claude didn't quit, so nothing was changed."))
        }
        // Read again after the quit: this is the state Claude's files were flushed in.
        guard let id = ClaudeApp.currentIdentity() else { return .success(nil) }
        guard id == before, ClaudeApp.savedAccount() == id.account,
              let acct = accounts.first(where: { $0.accountUuid == id.account }) else {
            await ClaudeApp.launch()
            return .failure(OutcomeError(SwitchError.inconsistent.localizedDescription))
        }
        return .success((acct, id))
    }

    struct OutcomeError: Error {
        let outcome: SwitchOutcome
        init(_ message: String) { outcome = SwitchOutcome(ok: false, message: message) }
    }

    /// Back up Claude's files and record the intent before the first write.
    private static func startJournal(from: Identity?, to: Identity?) -> SwitchJournal? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = Paths.stateDir.appendingPathComponent("backups/\(stamp)")
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: ClaudeApp.cookies, to: backup.appendingPathComponent("Cookies"))
            if fm.fileExists(atPath: ClaudeApp.cookiesJournal.path) {
                try fm.copyItem(at: ClaudeApp.cookiesJournal, to: backup.appendingPathComponent("Cookies-journal"))
            }
            try fm.copyItem(at: ClaudeApp.config, to: backup.appendingPathComponent("config.json"))
            let journal = SwitchJournal(backup: backup.path, from: from, to: to)
            try journal.save()
            return journal
        } catch {
            return nil
        }
    }

    /// Move each open session's record, keeping its id, so its transcript and worktree lease
    /// still match. If the target already holds a copy (from an earlier interrupted switch),
    /// the newer copy wins and the older is set aside in the backup, never deleted.
    private static func moveSessions(from: Identity, to: Identity, journal: inout SwitchJournal) throws {
        let fm = FileManager.default
        let dst = ClaudeApp.folder(to)
        let quarantine = URL(fileURLWithPath: journal.backup).appendingPathComponent("quarantine")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        func move(_ a: URL, _ b: URL) throws {
            guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
            try fm.moveItem(at: a, to: b)
            journal.moves.append(.init(from: a.path, to: b.path))
            try journal.save()
        }
        for record in ClaudeApp.openSessionRecords(in: ClaudeApp.folder(from)) {
            let dest = dst.appendingPathComponent(record.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let aside = quarantine.appendingPathComponent(record.lastPathComponent)
                if ClaudeApp.lastActivity(dest) > ClaudeApp.lastActivity(record) { try move(record, aside); continue }
                try move(dest, aside)
            }
            try move(record, dest)
        }
    }

    enum Verdict { case confirmed, signedOut, other(Identity?) }

    /// Watch the reopened Claude until it reports `want` and holds it for a few seconds.
    private static func confirm(_ want: Identity, since mark: ClaudeApp.LogMark) async -> Verdict {
        let deadline = Date().addingTimeInterval(60)
        var seen: Identity?
        var seenSince = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let text = ClaudeApp.logText(since: mark)
            guard let start = text.range(of: "Starting app {") else { continue }
            let run = text[start.upperBound...]
            if run.split(separator: "\n").contains(where: ClaudeApp.signsOut) { return .signedOut }
            let now = ClaudeApp.identity(after: String(run), from: nil)
            if now != seen { seen = now; seenSince = Date() }
            let held = Date().timeIntervalSince(seenSince)
            if now == want, held >= 4 { return .confirmed }
            if now != nil, now != want, held >= 10 { return .other(now) }
        }
        return .other(seen)
    }

    /// Put Claude's files back as they were before the switch and reopen it. Returns false,
    /// keeping the journal for a later try, if Claude can't be quit first.
    static func rollback(_ journal: SwitchJournal, progress: @escaping Progress) async -> Bool {
        progress("Undoing the switch…")
        guard await ClaudeApp.quit(progress: progress) == .quit else { return false }
        let fm = FileManager.default
        for m in journal.moves.reversed() where fm.fileExists(atPath: m.to) && !fm.fileExists(atPath: m.from) {
            try? fm.moveItem(atPath: m.to, toPath: m.from)
        }
        let backup = URL(fileURLWithPath: journal.backup)
        try? fm.removeItem(at: ClaudeApp.cookiesJournal)
        for (name, live) in [("Cookies", ClaudeApp.cookies), ("Cookies-journal", ClaudeApp.cookiesJournal), ("config.json", ClaudeApp.config)] {
            let saved = backup.appendingPathComponent(name)
            guard fm.fileExists(atPath: saved.path) else { continue }
            let staged = ClaudeApp.dataDir.appendingPathComponent(".\(name).restore")
            try? fm.removeItem(at: staged)
            guard (try? fm.copyItem(at: saved, to: staged)) != nil else { continue }
            if fm.fileExists(atPath: live.path) { _ = try? fm.replaceItemAt(live, withItemAt: staged) }
            else { try? fm.moveItem(at: staged, to: live) }
        }
        SwitchJournal.clear()
        await ClaudeApp.launch()
        return true
    }

    /// Keep the ten most recent backups.
    static func pruneBackups() {
        let dir = Paths.stateDir.appendingPathComponent("backups")
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for name in all.dropLast(10) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountRecord] = AccountStore.load()
    @Published var states: [String: AccountState] = [:]
    /// Who Claude reports it is signed in as, from its own log.
    @Published var inUse: Identity?
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var message: String?
    /// The account the sign-in window re-authenticates; nil means it adds a new one.
    @Published var signInTarget: AccountRecord?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settings = AppSettings.load() { didSet { settings.save() } }
    /// Progress text while a switch runs; nil when idle.
    @Published var switching: String?

    /// When the usage service lets each rate-limited account be asked again.
    @Published var retryAt: [String: Date] = [:]

    private var timer: Timer?
    private let identityWatcher = IdentityWatcher()
    private var polledAt: [String: Date] = [:]

    /// The Claude app's own usage reader reuses a good reading for 60 s; asking faster than
    /// that earns a 429 with a multi-minute Retry-After, so no account is asked more often.
    static let minPollInterval: TimeInterval = 60
    /// A click on Refresh may re-read sooner, at the 20 s spacing the Claude app uses for retries.
    static let manualPollInterval: TimeInterval = 20

    /// True when any account needs a sign-in; the menu bar icon turns into a warning.
    var needsAttention: Bool { states.values.contains { $0.needsSignIn } }

    init() {
        loadCache()
        refresh()
        // Tick often so each account is read as soon as it is due; the interval above sets the pace.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func isInUse(_ acct: AccountRecord) -> Bool { acct.accountUuid != nil && acct.accountUuid == inUse?.account }

    /// Opening the menu calls this; accounts that aren't due yet keep their cached reading.
    func refreshIfStale() { refresh() }

    /// Read usage for every account that is due: not asked in the last `minPollInterval`,
    /// and not inside a rate-limit wait. `forcing` skips the spacing for one account
    /// (a fresh sign-in) but still honours a rate-limit wait.
    func refresh(forcing forcedId: String? = nil, manual: Bool = false) {
        guard !loading else { return }
        accounts = AccountStore.load()
        inUse = identityWatcher.poll()
        let now = Date()
        let due = accounts.filter { acct in
            if let until = retryAt[acct.id], until > now { return false }
            if acct.id == forcedId { return true }
            guard let last = polledAt[acct.id] else { return true }
            if manual { return now.timeIntervalSince(last) >= Self.manualPollInterval }
            // Claude reads the account it is signed in to once a minute too, and the two readers
            // share that account's rate limit, so ours backs off to every other minute there.
            let pace = isInUse(acct) ? Self.minPollInterval * 2 : Self.minPollInterval
            return now.timeIntervalSince(last) >= pace
        }
        guard !due.isEmpty else { return }
        loading = true
        Task {
            await withTaskGroup(of: (String, AccountState).self) { group in
                for acct in due { group.addTask { (acct.id, await Usage.state(for: acct)) } }
                for await (id, state) in group { self.record(state, for: id) }
            }
            self.lastUpdated = Date()
            self.loading = false
            self.saveCache()
        }
    }

    /// A rate-limit answer keeps the last good reading on screen instead of blanking the row.
    private func record(_ state: AccountState, for id: String) {
        polledAt[id] = Date()
        if case .rateLimited(let until) = state {
            retryAt[id] = until
            if states[id] == nil || states[id] == .loading { states[id] = state }
            return
        }
        retryAt[id] = nil
        states[id] = state
    }

    // MARK: Cache

    /// The last good reading per account, so a relaunch shows numbers without asking again.
    private struct CacheEntry: Codable {
        var polledAt: Date
        var retryAt: Date?
        var plan: String?
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var loginExpiresAt: Date?
    }

    private var cacheURL: URL { Paths.stateDir.appendingPathComponent("usage-cache.json") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([String: CacheEntry].self, from: data) else { return }
        for (id, e) in entries {
            polledAt[id] = e.polledAt
            if let r = e.retryAt, r > Date() { retryAt[id] = r }
            if e.fiveHour != nil || e.weekly != nil || e.plan != nil {
                states[id] = .ok(plan: e.plan, fiveHour: e.fiveHour, weekly: e.weekly, loginExpiresAt: e.loginExpiresAt)
            } else if let r = retryAt[id] {
                states[id] = .rateLimited(until: r)
            }
        }
        lastUpdated = entries.values.map(\.polledAt).max()
    }

    private func saveCache() {
        var entries: [String: CacheEntry] = [:]
        for (id, polled) in polledAt {
            // A rate-limit wait is saved even without a reading, so a relaunch doesn't ask again early.
            if case .ok(let plan, let fh, let wk, let exp) = states[id] {
                entries[id] = CacheEntry(polledAt: polled, retryAt: retryAt[id], plan: plan, fiveHour: fh, weekly: wk, loginExpiresAt: exp)
            } else if let wait = retryAt[id] {
                entries[id] = CacheEntry(polledAt: polled, retryAt: wait)
            }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Show a short status line that clears itself.
    func flash(_ text: String, for seconds: Double = 5) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    /// Register or unregister as a macOS login item; it appears in System Settings > Login Items.
    func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            flash("Could not change Open at Login: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval {
            flash("Allow Claude Accounts in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
        openAtLogin = service.status == .enabled
    }

    /// Save a new label or color for one account; the row keeps its place in the list.
    func update(_ acct: AccountRecord, name: String? = nil, color: String? = nil) {
        var all = AccountStore.load()
        guard let i = all.firstIndex(where: { $0.id == acct.id }) else { return }
        if let name { all[i].name = name }
        if let color { all[i].color = color }
        do {
            try AccountStore.save(all)
            accounts = all
        } catch {
            flash("Could not save: \(error.localizedDescription)")
        }
    }

    // MARK: Switching

    /// One click: quit Claude, save the current account's login, load the target's, move the
    /// open Code sessions into the target's folder, and reopen Claude as the target.
    func switchTo(_ target: AccountRecord) { runSwitch { await SwitchEngine.run(to: target, accounts: $0, progress: $1) } }

    /// Reopen Claude at its sign-in page for an account that has no saved Claude login yet.
    func setUp(_ target: AccountRecord) { runSwitch { await SwitchEngine.setUp(target, accounts: $0, progress: $1) } }

    private func runSwitch(_ body: @escaping ([AccountRecord], @escaping SwitchEngine.Progress) async -> SwitchOutcome) {
        guard switching == nil else { return }
        switching = "Starting…"
        let all = accounts
        Task {
            let outcome = await body(all) { step in Task { @MainActor in self.switching = step } }
            self.switching = nil
            self.flash(outcome.message, for: 10)
            self.inUse = self.identityWatcher.poll()
        }
    }

    /// Sign the account's private login out, forget it, and delete its folder.
    func remove(_ acct: AccountRecord) {
        Task {
            _ = await ClaudeCLI.run(configDir: acct.configURL, ["auth", "logout"])
            if await Keychain.credential(service: acct.keychainService) != nil {
                await Keychain.delete(service: acct.keychainService)
            }
            try? FileManager.default.removeItem(at: acct.configURL)
            try? FileManager.default.removeItem(at: LoginSlot.dir(acct))
            let remaining = AccountStore.load().filter { $0.id != acct.id }
            do {
                try AccountStore.save(remaining)
                self.accounts = remaining
                self.states[acct.id] = nil
                self.flash("Removed \(acct.name).")
            } catch {
                self.flash("Could not save accounts: \(error.localizedDescription)")
            }
        }
    }

    /// The in-use account's reading for the limit the menu bar follows.
    var inUseWindow: UsageWindow? {
        guard let current = accounts.first(where: isInUse),
              case .ok(_, let fh, let wk, _) = states[current.id] else { return nil }
        return settings.metric == .fiveHour ? fh : wk
    }

    /// Gauge position, 0...1; a third before any reading so the glyph still looks like a gauge.
    var menuBarFraction: Double { inUseWindow.map { Double($0.pct) / 100 } ?? 1.0 / 3 }

    /// Text beside the gauge, per the Menu Bar Shows setting; empty means gauge only.
    var menuBarTitle: String {
        guard let window = inUseWindow, settings.display != .gauge,
              let current = accounts.first(where: isInUse) else { return "" }
        return settings.display == .gaugePercent ? "\(window.pct)%" : "\(current.shortName) \(window.pct)%"
    }
}

// MARK: - Adding an account

/// Drives `claude auth login` for a new private config dir: starts it, lets the CLI
/// open the browser, takes the pasted code, then records the new login.
@MainActor
final class LoginFlow: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waitingForCode
        case verifying
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var loginURL: URL?

    private var proc: Process?
    private var stdin: FileHandle?
    private var output = ""
    private var draft: (id: String, dir: URL)?
    private var servicesBefore: Set<String> = []
    /// Set when signing an existing account in again: its record and what to put back if
    /// the browser login lands on a different Google account.
    private var reauth: AccountRecord?
    private var rollback: (keychain: (account: String, secret: String)?, profile: Data?)?

    /// Start a login. With `target`, sign that account in again in its own folder, so its
    /// row keeps its place, name and color. Without it, add a new account; its email becomes
    /// the label once sign-in finishes, so the folder gets a random id now.
    func start(reauth target: AccountRecord? = nil) {
        guard let cli = ClaudeCLI.path else { phase = .failed("Claude Code isn't installed. Install it, then try again."); return }
        let id = target?.id ?? "acct-" + UUID().uuidString.prefix(8).lowercased()
        let dir = target?.configURL ?? Paths.loginsDir.appendingPathComponent(id)
        reauth = target
        phase = .starting
        output = ""
        loginURL = nil

        Task {
            if let target {
                rollback = (await Keychain.snapshot(service: target.keychainService),
                            try? Data(contentsOf: dir.appendingPathComponent(".claude.json")))
            } else {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                } catch {
                    phase = .failed("Could not create \(dir.path): \(error.localizedDescription)"); return
                }
                servicesBefore = await Keychain.services()
            }
            draft = (id, dir)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            // Pre-filling the email steers the browser to the right Google account.
            p.arguments = ["auth", "login", "--claudeai"] + (target?.email.map { ["--email", $0] } ?? [])
            p.environment = ClaudeCLI.env(configDir: dir)
            let inPipe = Pipe(), outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = String(decoding: handle.availableData, as: UTF8.self)
                guard !chunk.isEmpty else { return }
                Task { @MainActor in self?.consume(chunk) }
            }
            p.terminationHandler = { [weak self] proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in await self?.finished(status: proc.terminationStatus) }
            }
            do { try p.run() } catch {
                phase = .failed("Could not start the login: \(error.localizedDescription)"); return
            }
            proc = p
            stdin = inPipe.fileHandleForWriting
        }
    }

    func submit(code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let stdin else { return }
        phase = .verifying
        stdin.write(Data((clean + "\n").utf8))
    }

    func openLoginPage() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }

    func cancel() {
        if let proc, proc.isRunning { proc.terminate() }
        // A new account's folder is scratch until sign-in succeeds; an existing one's never is.
        if reauth == nil, let dir = draft?.dir { try? FileManager.default.removeItem(at: dir) }
        reset()
    }

    func reset() {
        proc = nil
        stdin = nil
        draft = nil
        reauth = nil
        rollback = nil
        loginURL = nil
        phase = .idle
    }

    private func consume(_ chunk: String) {
        output += chunk
        if loginURL == nil, let range = output.range(of: "visit: ") {
            let rest = output[range.upperBound...]
            let urlText = rest.prefix { !$0.isWhitespace }
            loginURL = URL(string: String(urlText))
        }
        if phase == .starting, output.contains("Paste code") || loginURL != nil {
            phase = .waitingForCode
        }
    }

    private func finished(status: Int32) async {
        guard let draft else { return }  // cancelled
        guard status == 0 else {
            let last = output.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            phase = .failed(last.contains("400")
                ? "That code didn't work. Codes are single-use; start again and paste the newest one."
                : "Login failed: \(last)")
            if reauth == nil { try? FileManager.default.removeItem(at: draft.dir) }
            self.draft = nil
            return
        }
        if let target = reauth {
            await finishReauth(target, dir: draft.dir)
            self.draft = nil
            return
        }
        // The CLI names the keychain item after the config dir; diffing avoids re-deriving that rule.
        let added = await Keychain.services().subtracting(servicesBefore)
        guard added.count == 1, let service = added.first else {
            phase = .failed("Signed in, but found \(added.count) new keychain items instead of 1.")
            return
        }
        let profile = Self.profile(in: draft.dir)
        var accounts = AccountStore.load()
        if let uuid = profile["accountUuid"] as? String,
           let dup = accounts.first(where: { $0.accountUuid == uuid }) {
            _ = await ClaudeCLI.run(configDir: draft.dir, ["auth", "logout"])
            await Keychain.delete(service: service)
            try? FileManager.default.removeItem(at: draft.dir)
            phase = .failed("That Google account is already added as \(dup.name).")
            self.draft = nil
            return
        }
        let email = profile["emailAddress"] as? String
        let usedColors = Set(accounts.map(\.color))
        let record = AccountRecord(
            id: draft.id,
            name: email ?? "Account \(accounts.count + 1)",
            color: presetColors.first { !usedColors.contains($0) } ?? presetColors[accounts.count % presetColors.count],
            configDir: draft.dir.path.replacingOccurrences(of: Paths.home.path, with: "~"),
            keychainService: service,
            email: email,
            accountUuid: profile["accountUuid"] as? String,
            orgName: profile["organizationName"] as? String)
        accounts.append(record)
        do {
            try AccountStore.save(accounts)
            phase = .done(record.email ?? record.name)
        } catch {
            phase = .failed("Signed in, but could not save: \(error.localizedDescription)")
        }
        self.draft = nil
    }

    /// Keep the new login only if it is the same account the row belongs to. Otherwise
    /// put the previous login back, so a row can never silently switch accounts.
    private func finishReauth(_ target: AccountRecord, dir: URL) async {
        let signedIn = Self.profile(in: dir)
        if let uuid = target.accountUuid, signedIn["accountUuid"] as? String == uuid {
            phase = .done(target.email ?? target.name)
            return
        }
        if let snap = rollback?.keychain { await Keychain.restore(service: target.keychainService, snap) }
        if let file = rollback?.profile { try? file.write(to: dir.appendingPathComponent(".claude.json"), options: .atomic) }
        let other = signedIn["emailAddress"] as? String ?? "a different account"
        phase = .failed("You signed in as \(other), but this row is \(target.email ?? target.name). The previous login was kept; try again and pick \(target.email ?? "the right account").")
    }

    private static func profile(in dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".claude.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj["oauthAccount"] as? [String: Any] ?? [:]
    }
}

// MARK: - Views

extension Color {
    init(hex: String?) {
        var s = (hex ?? "#2C5B4E").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x2C5B4E
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Good below 60 %, warning from 60 %, critical from 80 %; kept separate from the per-account colors.
func severity(_ pct: Int) -> Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

/// Named account colors, offered in each row's Color menu; new accounts take the first unused one.
let accountColors: [(name: String, hex: String)] = [
    ("Blue", "#3567CF"), ("Orange", "#B96E22"), ("Pink", "#B3405F"), ("Green", "#2C8A5E"),
    ("Purple", "#6B5BD2"), ("Teal", "#1F8A9A"), ("Red", "#C8412F"), ("Gray", "#7A8088"),
]
let presetColors = accountColors.map(\.hex)

struct Meter: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(window.map { "\($0.pct)%" } ?? "n/a").monospacedDigit().fontWeight(.semibold)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    if let w = window {
                        Capsule().fill(severity(w.pct))
                            .frame(width: geo.size.width * CGFloat(min(max(w.pct, 0), 100)) / 100)
                    }
                }
            }
            .frame(height: 5)
            if let w = window {
                Text(w.resetText).font(.caption2)
                    .foregroundStyle(w.resetsSoon ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .fontWeight(w.resetsSoon ? .semibold : .regular)
            }
        }
        .font(.caption)
    }
}

struct AccountRow: View {
    let account: AccountRecord
    let state: AccountState?
    let inUse: Bool
    let canSwitch: Bool
    let switchBusy: Bool
    let onSwitch: () -> Void
    let onSetUp: () -> Void
    let retryAt: Date?
    let onSignIn: () -> Void
    let onRename: (String) -> Void
    let onRecolor: (String) -> Void
    let onRemove: () -> Void
    @State private var confirmingRemove = false
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    /// An empty name puts the email back as the label.
    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        onRename(trimmed.isEmpty ? (account.email ?? account.name) : trimmed)
        renaming = false
    }

    /// "Login expires in 5 h" inside the warning window, nil otherwise.
    private var expiryWarning: String? {
        guard case .ok(_, _, _, let expires?) = state, expires.timeIntervalSinceNow < API.signInWarning else { return nil }
        let hours = max(Int(expires.timeIntervalSinceNow / 3600), 0)
        return hours > 0 ? "Login expires in \(hours) h." : "Login expires within the hour."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: account.color)).frame(width: 9, height: 9)
                if renaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = false }
                } else {
                    Text(account.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        .help(account.email ?? account.name)
                    if case .ok(let plan?, _, _, _) = state {
                        Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // One fixed box for both, so "In use" and Switch share a center line and right edge.
                Group {
                    if inUse {
                        Text("In use").font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    } else if canSwitch {
                        Button("Switch", action: onSwitch).controlSize(.small).disabled(switchBusy)
                            .help("Quit Claude, sign it in as this account, and bring your open sessions along")
                    } else {
                        Button("Set Up", action: onSetUp).controlSize(.small).disabled(switchBusy)
                            .help("Quit Claude, save the account it's using, and reopen it at the sign-in page for this account")
                    }
                }
                .frame(width: 62, height: 22, alignment: .trailing)
                Menu {
                    if let email = account.email { Text(email) }
                    Divider()
                    Button("Rename…") {
                        draftName = account.name
                        renaming = true
                        nameFocused = true
                    }
                    Menu("Color") {
                        ForEach(accountColors, id: \.hex) { color in
                            Button { onRecolor(color.hex) } label: {
                                if color.hex == account.color { Label(color.name, systemImage: "checkmark") }
                                else { Text(color.name) }
                            }
                        }
                    }
                    Divider()
                    Button("Sign in again…", action: onSignIn)
                    Button("Remove…") { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            switch state {
            case .ok(_, let fh, let wk, _):
                Meter(label: "5-hour", window: fh)
                Meter(label: "Weekly", window: wk)
                if let warning = expiryWarning { signInPrompt(warning) }
                if let until = retryAt, until > Date() {
                    Text("Rate-limited by the usage service · retrying at \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            case .rateLimited(let until):
                Text("Waiting for the usage service · retrying at \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            case .needsLogin(let why):
                signInPrompt(why)
            case .error(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
            case .loading, nil:
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            if confirmingRemove {
                HStack {
                    Text("Remove \(account.name) from this app?").font(.caption)
                    Spacer()
                    Button("Cancel") { confirmingRemove = false }.controlSize(.small)
                    Button("Remove", role: .destructive) { confirmingRemove = false; onRemove() }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(inUse ? Color.primary.opacity(0.06) : .clear))
    }

    private func signInPrompt(_ reason: String) -> some View {
        HStack {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Sign in again", action: onSignIn).controlSize(.small)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Usage is the point of the menu; the rare setup actions live behind the header's ···.
            HStack(spacing: 4) {
                Text("Claude Accounts").font(.headline)
                Spacer()
                RefreshButton(store: store)
                Menu {
                    Button("Add Account…") { openSignIn(nil) }
                    Divider()
                    Picker("Menu Bar Shows", selection: $store.settings.display) {
                        ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Gauge Tracks", selection: $store.settings.metric) {
                        ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { _ in store.toggleOpenAtLogin() }))
                    Divider()
                    Button("Quit Claude Accounts") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            if let step = store.switching {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(step).font(.caption) }
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if let msg = store.message {
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
            }
            if store.accounts.isEmpty {
                Text("No accounts yet. Add one to see its 5-hour and weekly usage here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            ForEach(store.accounts) { acct in
                AccountRow(account: acct, state: store.states[acct.id], inUse: store.isInUse(acct),
                           canSwitch: LoginSlot.exists(acct), switchBusy: store.switching != nil,
                           onSwitch: { store.switchTo(acct) }, onSetUp: { store.setUp(acct) },
                           retryAt: store.retryAt[acct.id],
                           onSignIn: { openSignIn(acct) },
                           onRename: { store.update(acct, name: $0) },
                           onRecolor: { store.update(acct, color: $0) },
                           onRemove: { store.remove(acct) })
            }
        }
        .padding(6)
        .frame(width: 330)
        .onAppear { store.refreshIfStale() }
    }

    /// One window serves both jobs: adding an account (nil) or signing one in again.
    private func openSignIn(_ acct: AccountRecord?) {
        store.signInTarget = acct
        openWindow(id: "sign-in")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The header's refresh control. It spins while a read runs, and for a moment on every click,
/// so a click always shows it registered even when every account was read seconds ago.
struct RefreshButton: View {
    @ObservedObject var store: Store
    @State private var clickSpin = false

    var body: some View {
        Button {
            clickSpin = true
            store.refresh(manual: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { clickSpin = false }
        } label: {
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate, options: .speed(1.5), isActive: store.loading || clickSpin)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r")
        .help((store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened)). " } ?? "")
              + "Each account updates about once a minute. Refresh (⌘R)")
    }
}

/// Adds a new account, or signs an existing one in again when `store.signInTarget` is set.
struct SignInView: View {
    @ObservedObject var store: Store
    @StateObject private var flow = LoginFlow()
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var code = ""
    @State private var target: AccountRecord?

    private var busy: Bool {
        switch flow.phase {
        case .starting, .waitingForCode, .verifying: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.map { "Sign in again: \($0.email ?? $0.name)" } ?? "Add a Claude account")
                .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            steps
        }
        .padding(20)
        .frame(width: 400)
        // Opening this window is the request, so the login starts at once.
        .onAppear {
            target = store.signInTarget
            if flow.phase == .idle { flow.start(reauth: target) }
        }
        .onDisappear {
            if busy { flow.cancel() } else { flow.reset() }
            store.signInTarget = nil
        }
    }

    private func restart(reauth: AccountRecord?) {
        code = ""
        target = reauth
        flow.reset()
        flow.start(reauth: reauth)
    }

    private func close() { dismissWindow(id: "sign-in") }

    @ViewBuilder private var steps: some View {
        switch flow.phase {
        case .idle, .starting:
            HStack { ProgressView().controlSize(.small); Text("Opening the sign-in page in your browser…").font(.callout) }
        case .waitingForCode:
            Text(target.map { "In your browser, choose Continue with Google and pick \($0.email ?? "the same account"). After you click Authorize, the page shows a code. Paste it here." }
                 ?? "In your browser, choose Continue with Google and pick the account to add. After you click Authorize, the page shows a code. Paste it here.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField("Paste the code", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { flow.submit(code: code) }
            HStack {
                Button("Open the page again") { flow.openLoginPage() }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { flow.cancel(); close() }
                Button(target == nil ? "Add account" : "Sign in") { flow.submit(code: code) }
                    .keyboardShortcut(.defaultAction).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Checking the code…").font(.callout) }
        case .done(let who):
            Label(target == nil ? "Added \(who)." : "Signed in again as \(who).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            HStack {
                if target == nil { Button("Add another") { restart(reauth: nil) } }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .onAppear { store.refresh(forcing: target?.id) }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { close() }
                Spacer()
                Button("Try again") { restart(reauth: target) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The whole menu bar item drawn as one template image, so alignment is exact by construction:
/// the text's visual middle (half its cap height above the baseline) sits at the image's middle,
/// and each glyph is centred on that same line by its drawn shape rather than its box. macOS
/// tints template images for light and dark menu bars and centres the image in the bar.
func menuBarImage(title: String, fraction: Double, warning: Bool) -> NSImage {
    let base = NSFont.menuBarFont(ofSize: 0)
    // Fixed-width digits, so the percentage doesn't shift the item as it changes.
    let font = NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
    let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.black])
    let height: CGFloat = 22, glyphWidth: CGFloat = 16, gap: CGFloat = 4
    let textWidth = title.isEmpty ? 0 : ceil(text.size().width)
    let width = glyphWidth + (title.isEmpty ? 0 : gap + textWidth)
    let middle = height / 2

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        if warning { drawWarning(centeredAt: NSPoint(x: glyphWidth / 2, y: middle)) }
        else { drawGauge(fraction, centeredAt: NSPoint(x: glyphWidth / 2, y: middle)) }
        if !title.isEmpty {
            // Baseline chosen so the midpoint of the capitals and digits lands on `middle`.
            text.draw(at: NSPoint(x: glyphWidth + gap, y: middle - font.capHeight / 2 + font.descender))
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = title.isEmpty ? "Claude Accounts" : title
    return image
}

/// A speedometer: a 270° arc filled to `fraction`, a needle at the same angle, and a hub.
/// Centred on its ink: the open-bottomed arc reaches `radius` above its centre but only
/// radius·sin45° below it, and the stroke's half-width pads both ends equally.
private func drawGauge(_ fraction: Double, centeredAt mid: NSPoint) {
    let value = CGFloat(min(max(fraction, 0), 1))
    let radius: CGFloat = 6, stroke: CGFloat = 1.7, sweep: CGFloat = 270, start: CGFloat = 225
    let center = NSPoint(x: mid.x, y: mid.y - (radius - radius * sin(.pi / 4)) / 2)
    let angle = start - sweep * value

    func arc(to end: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = stroke
        path.lineCapStyle = .round
        return path
    }
    // Template images keep only alpha, so the unused part of the arc is a fainter shade.
    NSColor.black.withAlphaComponent(0.35).setStroke()
    arc(to: start - sweep).stroke()
    NSColor.black.setStroke()
    if value > 0.01 { arc(to: angle).stroke() }

    let rad = angle * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(rad) * radius * 0.62, y: center.y + sin(rad) * radius * 0.62))
    needle.lineWidth = 1.6
    needle.lineCapStyle = .round
    needle.stroke()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
}

/// A rounded warning triangle with the exclamation mark cut out, centred on its ink.
private func drawWarning(centeredAt mid: NSPoint) {
    let w: CGFloat = 14, h: CGFloat = 12.5
    let bottom = mid.y - h / 2
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: mid.x, y: bottom + h))
    triangle.line(to: NSPoint(x: mid.x + w / 2, y: bottom))
    triangle.line(to: NSPoint(x: mid.x - w / 2, y: bottom))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = 2
    NSColor.black.set()
    triangle.fill()
    triangle.stroke()
    // Punch the mark out of the fill so the menu bar shows through it.
    NSGraphicsContext.current?.compositingOperation = .clear
    NSBezierPath(roundedRect: NSRect(x: mid.x - 0.9, y: bottom + 4.4, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
    NSBezierPath(ovalIn: NSRect(x: mid.x - 1, y: bottom + 1.6, width: 2, height: 2)).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}

/// `ClaudeAccounts --switch <account>` runs the menu's switch without the menu, prints the
/// outcome as JSON, and saves it to last-switch.json in the app's state folder. The account can be named by id,
/// label, email, or the email's first part. Run it from outside Claude: quitting Claude ends
/// every process Claude started.
@main
enum Entry {
    static func main() {
        Migration.moveLegacyState()
        let args = CommandLine.arguments
        if args.contains("--status") { printStatus() }
        guard let i = args.firstIndex(of: "--switch"), i + 1 < args.count else {
            ClaudeAccountsApp.main()
            return
        }
        signal(SIGHUP, SIG_IGN)
        let key = args[i + 1].lowercased()
        let accounts = AccountStore.load()
        let matches = accounts.filter {
            [$0.id, $0.name, $0.email ?? "", $0.shortName, String(($0.email ?? "").prefix { $0 != "@" })]
                .map { $0.lowercased() }.contains(key)
        }
        guard matches.count == 1, let target = matches.first else {
            finish(SwitchOutcome(ok: false, message: matches.isEmpty ? "No account is named \(key)." : "\(key) names more than one account."))
        }
        final class Box: @unchecked Sendable { var outcome = SwitchOutcome(ok: false, message: "did not run") }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.outcome = await SwitchEngine.run(to: target, accounts: accounts) { step in
                FileHandle.standardError.write(Data("… \(step)\n".utf8))
            }
            done.signal()
        }
        done.wait()
        finish(box.outcome)
    }

    /// `--status`: what a switch would act on, read-only.
    private static func printStatus() -> Never {
        let id = ClaudeApp.currentIdentity()
        let accounts = AccountStore.load()
        func name(_ uuid: String?) -> String { accounts.first { $0.accountUuid == uuid }?.name ?? (uuid ?? "none") }
        print("Claude processes: \(ClaudeApp.pids())")
        print("Claude reports:   \(id.map { "\(name($0.account)) (org \($0.org.prefix(8)))" } ?? "signed out")")
        print("Claude settings:  \(name(ClaudeApp.savedAccount()))")
        print("Interrupted switch: \(SwitchJournal.load() == nil ? "none" : "yes")")
        for acct in accounts {
            print("Saved login \(acct.name): \(LoginSlot.identity(acct).map { "org \($0.org.prefix(8))" } ?? "none")")
        }
        exit(0)
    }

    private static func finish(_ outcome: SwitchOutcome) -> Never {
        let data = (try? JSONEncoder().encode(outcome)) ?? Data("{}".utf8)
        try? data.write(to: Paths.stateDir.appendingPathComponent("last-switch.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        exit(outcome.ok ? 0 : 1)
    }
}

struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(nsImage: menuBarImage(title: store.menuBarTitle, fraction: store.menuBarFraction,
                                        warning: store.needsAttention))
        }
        .menuBarExtraStyle(.window)

        Window("Sign in", id: "sign-in") {
            SignInView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
