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
import UserNotifications

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

enum AccountStore {
    /// The rows on disk. A row saved before organizations were tracked takes its organization from its
    /// saved Claude login, else from its Claude Code login, and a label that shows an email gets its
    /// default label; this only reads, so --dry-run stays read-only, and the next save keeps it.
    static func load() -> [AccountRecord] {
        guard let data = try? Data(contentsOf: Paths.accountsFile),
              var accounts = AccountsFile.decode(data) else { return [] }
        for i in accounts.indices where accounts[i].orgUuid == nil {
            let profile = LoginFlow.profile(in: accounts[i].configURL)
            accounts[i].orgUuid = LoginSlot.meta(accounts[i])?.orgFolder ?? profile["organizationUuid"] as? String
            if accounts[i].orgName == nil { accounts[i].orgName = profile["organizationName"] as? String }
        }
        return accounts.labelled()
    }

    static func save(_ accounts: [AccountRecord]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try AccountsFile.encode(accounts).write(to: Paths.accountsFile, options: .atomic)
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

extension AppSettings {
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

    /// Ids of Claude's on-screen windows. Reading ids needs no screen-recording permission.
    static func windowIDs(_ owners: [pid_t]) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owners.contains(owner) else { return nil }
            return w[kCGWindowNumber as String] as? Int
        })
    }

    /// Quit the way ⌘Q does, then wait until the process is gone, so Claude has flushed its
    /// cookies and settings. With a chat mid-reply Claude first asks, in a native alert: Quit
    /// anyway, Wait for Claude (it quits once its chats finish) or Cancel. `QuitWatch` decides
    /// from what is on screen and in Claude's log; it never walks away while the prompt is open.
    ///
    /// `unattended` answers the prompt with Quit anyway through Accessibility, the answer a person
    /// switching by hand gives; Claude then marks each cut-off chat to resume at its next launch.
    /// Without Accessibility access an unattended quit waits for a person like any other.
    static func quit(unattended: Bool = false,
                     progress: @Sendable (String) -> Void = { _ in }) async -> (outcome: QuitWatch.Outcome, answered: Bool) {
        let running = pids()
        guard !running.isEmpty else { return (.quit, false) }
        let mark = logMark()
        let windowsBefore = windowIDs(running)
        for pid in running {
            if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
            else { _ = await runProcess("/usr/bin/osascript", ["-e", "tell application id \"\(bundleId)\" to quit"]) }
        }
        var watch = QuitWatch(unattended: unattended, canAnswer: QuitPrompt.trusted, started: Date())
        var firstTry: Date?
        var shown: String?
        while true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let alive = !pids().isEmpty
            let text = alive ? logText(since: mark) : ""
            let veto = text.range(of: "vetoed by before-quit interceptor")
            let afterVeto = veto.map { text[$0.upperBound...] } ?? ""
            let seen = QuitObservation(
                claudeRunning: alive,
                // Accessibility finds the prompt by its Quit anyway button; a window Claude opened
                // after the request also counts, which covers a prompt without that button.
                promptOpen: alive && (QuitPrompt.isOpen(in: running) || !windowIDs(running).subtracting(windowsBefore).isEmpty),
                vetoLogged: veto != nil,
                waitLogged: afterVeto.contains("[updater-guard] restart deferred"),
                quitLoggedAfterVeto: afterVeto.contains("beforeQuit: handler fired"))
            switch watch.step(seen, now: Date()) {
            case .done(let outcome): return (outcome, watch.answeredAt != nil)
            case .wait(let what):
                if what != shown { shown = what; progress(what) }
            case .answer:
                if QuitPrompt.press(QuitPrompt.quitAnyway, in: running) {
                    watch.answered(at: Date())
                    progress("Answered Claude's prompt with \(QuitPrompt.quitAnyway)…")
                } else if Date().timeIntervalSince(firstTry ?? Date()) > QuitPrompt.findTimeout {
                    // A new window with no Quit anyway button is not a prompt this app answers:
                    // leave the answer to a person and keep waiting for it.
                    watch.canAnswer = false
                }
                firstTry = firstTry ?? Date()
            }
        }
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

    /// The log of Claude's current run (or its last one, once it has quit), across a rotation.
    static func currentRunText() -> String {
        let text = readLines(logDir.appendingPathComponent("main1.log"), from: 0).text + readLines(log, from: 0).text
        return text.range(of: "Starting app {", options: .backwards).map { String(text[$0.lowerBound...]) } ?? text
    }

    /// Claude's last two log files read in order: who it is now (or was when it last quit), since
    /// when, and the organizations whose sign-in it refused.
    static func currentLog() -> LogFollower {
        var follower = LogFollower()
        follower.read(readLines(logDir.appendingPathComponent("main1.log"), from: 0).text)
        follower.read(readLines(log, from: 0).text)
        return follower
    }

    /// Who Claude is signed in as now, or was when it last quit, from its own log.
    static func currentIdentity() -> Identity? { currentLog().identity }

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

    /// The organizations of `account` that Claude has opened, from its session folders, with how
    /// many chats each holds.
    static func organizations(of account: String) -> [(org: String, chats: Int)] {
        let dir = sessions.appendingPathComponent(account)
        let orgs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return orgs.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { ($0.lastPathComponent, ((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).filter { $0.hasPrefix("local_") }.count) }
    }

    static func record(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func lastActivity(_ url: URL) -> Double { (record(url)?["lastActivityAt"] as? Double) ?? 0 }
}

/// Follows Claude's log, reading only what is new: the account Claude reports, for the menu, and
/// the chats of that account Claude stopped for usage, for auto-switch.
final class LogWatcher {
    private var mark: ClaudeApp.LogMark?
    private(set) var log = LogFollower()

    func poll() -> Identity? {
        let now = ClaudeApp.logMark()
        if let mark, mark.inode == now.inode, mark.offset <= now.offset {
            let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: mark.offset)
            log.read(text)
            self.mark = ClaudeApp.LogMark(inode: now.inode, offset: end)
        } else {
            log = LogFollower()
            log.read(ClaudeApp.readLines(ClaudeApp.logDir.appendingPathComponent("main1.log"), from: 0).text)
            let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: 0)
            log.read(text)
            self.mark = ClaudeApp.LogMark(inode: now.inode, offset: end)
        }
        return log.identity
    }
}

/// One account's saved Claude app login: its claude.ai cookie rows (still encrypted with
/// Claude's own key, never decrypted here) and the Code tab's token cache from config.json.
enum LoginSlot {
    static let hosts = "('.claude.ai','claude.ai')"
    static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    static let cookieSchemaVersion = "24"

    static func dir(_ acct: AccountRecord) -> URL { Paths.stateDir.appendingPathComponent("slots/\(acct.id)") }

    /// The row has a saved login Claude still accepts. `refused` is when Claude last refused each
    /// organization's sign-in (LogFollower.refusedAt).
    static func exists(_ acct: AccountRecord, refused: [String: Date]) -> Bool { identity(acct, refused: refused) != nil }

    /// `orgFolder` is the organization whose sessions Claude showed when this login was saved.
    struct Meta: Codable { var account: String?; var orgFolder: String?; var config: [String: String] }

    static func meta(_ acct: AccountRecord) -> Meta? {
        guard let data = try? Data(contentsOf: dir(acct).appendingPathComponent("slot.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Where the row's sessions go: set only when the saved login is the row's own account and
    /// organization, and was saved after Claude last refused that organization's sign-in.
    static func identity(_ acct: AccountRecord, refused: [String: Date]) -> Identity? {
        guard let id = savedIdentity(acct),
              let savedAt = (try? dir(acct).appendingPathComponent("slot.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              SaveRule.counts(savedAt: savedAt, refusedAt: refused[id.org]) else { return nil }
        return id
    }

    private static func savedIdentity(_ acct: AccountRecord) -> Identity? {
        guard let uuid = acct.accountUuid, let meta = meta(acct), let org = meta.orgFolder,
              FileManager.default.fileExists(atPath: dir(acct).appendingPathComponent("cookies.db").path),
              meta.config["lastKnownAccountUuid"] == uuid, (meta.account ?? uuid) == uuid,
              acct.orgUuid == nil || acct.orgUuid == org else { return nil }
        return Identity(account: uuid, org: org)
    }

    static func sqlite(_ db: URL, _ sql: String) async -> ProcResult {
        await runProcess("/usr/bin/sqlite3", ["-bail", db.path, sql])
    }

    static func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "''") + "'" }

    static func cookieVersion(_ db: URL) async -> String {
        await sqlite(db, "select value from meta where key='version';").out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save the login Claude holds, at switch-away with Claude quit or, `whileRunning`, once Claude
    /// has held it steadily (SaveRule). `identity` is who Claude says it is; the row must be that
    /// account and organization (or the account's one unnamed row) and Claude's settings must
    /// agree, so a login is never filed under another row. While Claude runs, its cookie file must
    /// sit still through the copy, and Claude must still hold `identity` right before the write.
    static func capture(_ acct: AccountRecord, as identity: Identity, whileRunning: Bool = false) async throws {
        guard acct.accountUuid == identity.account, acct.orgUuid == nil || acct.orgUuid == identity.org else {
            throw SwitchError.inconsistent
        }
        if !whileRunning { guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed } }
        guard ClaudeApp.savedAccount() == identity.account else { throw SwitchError.inconsistent }
        let fm = FileManager.default
        let slot = dir(acct)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = slot.appendingPathComponent("source.db")
        for f in [source, slot.appendingPathComponent("source.db-journal")] { try? fm.removeItem(at: f) }
        func stamp() -> (size: UInt64, modified: Date)? {
            guard let a = try? fm.attributesOfItem(atPath: ClaudeApp.cookies.path),
                  let size = (a[.size] as? NSNumber)?.uint64Value, let modified = a[.modificationDate] as? Date else { return nil }
            return (size, modified)
        }
        // Copied while Claude runs, the file must have sat still for 2 s and through the copy.
        let before = stamp()
        if whileRunning { guard let b = before, Date().timeIntervalSince(b.modified) >= 2 else { throw SwitchError.cookiesChanging } }
        try fm.copyItem(at: ClaudeApp.cookies, to: source)
        if fm.fileExists(atPath: ClaudeApp.cookiesJournal.path) {
            try fm.copyItem(at: ClaudeApp.cookiesJournal, to: slot.appendingPathComponent("source.db-journal"))
        }
        if whileRunning { guard let a = stamp(), let b = before, a == b else { throw SwitchError.cookiesChanging } }
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
        if whileRunning {
            guard ClaudeApp.currentIdentity() == identity, ClaudeApp.savedAccount() == identity.account else {
                throw SwitchError.inconsistent
            }
        }
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
            guard savedIdentity(acct) != nil, let meta = meta(acct) else { throw SwitchError.noSlot(acct.label) }
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
    case noSlot(String), notSignedIn, cookieSchemaChanged, sqlite(String), quitFailed, inconsistent, cookiesChanging
    var errorDescription: String? {
        switch self {
        case .noSlot(let name): return "\(name) isn't set up in Claude yet; use Set Up on its row first."
        case .notSignedIn: return "Claude isn't signed in, so there was no login to save."
        case .cookieSchemaChanged: return "Claude's cookie format changed in an update; switching is paused until this app is updated."
        case .sqlite(let err): return "Could not update Claude's cookies: \(err.prefix(160))"
        case .quitFailed: return "Claude is running again, so nothing more was changed."
        case .inconsistent: return "Claude's settings name a different account than its log. Open and quit Claude once, then try again."
        case .cookiesChanging: return "Claude was writing its cookies, so its login is saved on a later try."
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
    /// Titles of the chats a quit or a usage limit had stopped that are running again.
    var resumed: [String] = []
    /// Each stopped chat that is still waiting, as "title (why)".
    var notResumed: [String] = []
    /// The row the message tells the person how to set up in Claude.
    var setsUp: String? = nil
    /// Another switch started while this one's chats were being resumed; its outcome is the news.
    var superseded = false

    /// Fold the resume's reports into a confirmed switch's outcome.
    mutating func add(_ reports: [ChatResumer.Report], answered: Bool) {
        let running = reports.filter(\.result.runningAgain)
        resumed = running.map(\.chat.title)
        notResumed = reports.compactMap { r -> String? in
            switch r.result {
            case .notResumed(let why): return "\(r.chat.title) (\(why))"
            case .draft: return "\(r.chat.title) (it has an unsent draft)"
            case .running, .sent: return nil
            }
        }
        superseded = reports.contains { $0.result == .notResumed(ChatResumer.superseded) }
        if !reports.isEmpty {
            message += " " + ResumeRule.summary(running: running.count, of: reports.count)
        } else if answered {
            message += " No stopped chat was found; check the ones that were working."
        }
    }

    /// The message, naming the stopped chats still not running and what they need: a new message,
    /// since Retry on the failed one starts the chat over.
    var messageWithChatsLeft: String {
        guard !notResumed.isEmpty else { return message }
        let more = notResumed.count > 3 ? " and \(notResumed.count - 3) more" : ""
        return message + " Send a new message (not Retry) to: " + notResumed.prefix(3).joined(separator: ", ") + more + "."
    }
}

/// Whether a switch started from the menu has finished the switch itself and moved on to resuming.
@MainActor final class SwitchPhase { var freed = false }

/// One switch at a time across the menu and `--switch`, which are separate processes.
struct SwitchLock {
    let fd: Int32

    /// `newGeneration` false takes the lock without overtaking a resume, for a save that switches nothing.
    static func acquire(newGeneration: Bool = true) -> SwitchLock? {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        // A new generation for every switch, so a resume can tell that another one started.
        guard newGeneration else { return SwitchLock(fd: fd) }
        ftruncate(fd, 0)
        _ = Data(UUID().uuidString.utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return SwitchLock(fd: fd)
    }

    static var url: URL { Paths.stateDir.appendingPathComponent(".switch.lock") }

    /// The generation the last switch wrote when it took the lock.
    static func generation() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

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
    /// `unattended` answers Claude's quit prompt with Quit anyway, for a switch with nobody at the Mac.
    /// The lock covers the switch itself and is released before the stopped chats are resumed, so
    /// another Switch works during the resume; `switched` hears the switch's own outcome then. A
    /// resume that another switch overtakes stops and types nothing more (`ChatResumer.current`).
    static func run(to target: AccountRecord, accounts: [AccountRecord], unattended: Bool = false,
                    progress: @escaping Progress, switched: @escaping (SwitchOutcome) async -> Void = { _ in }) async -> SwitchOutcome {
        await lockedThenResume(unattended: unattended, progress: progress, switched: switched) {
            await switchLocked(to: target, accounts: accounts, unattended: unattended, progress: progress)
        }
    }

    /// Run `body` under the lock, then, with the lock released, resume the chats it leaves.
    private static func lockedThenResume(unattended: Bool, progress: @escaping Progress,
                                         switched: @escaping (SwitchOutcome) async -> Void,
                                         _ body: () async -> (outcome: SwitchOutcome, resume: PendingResume?)) async -> SwitchOutcome {
        var pending: PendingResume?
        var outcome = await locked(unattended: unattended) {
            let done = await body()
            pending = done.resume
            return done.outcome
        }
        guard let pending else { return outcome }
        await switched(outcome)
        let reports = await pending.run(progress: progress)
        outcome.add(reports, answered: pending.answered)
        return outcome
    }

    /// Chats a confirmed switch moved that were working, to resume once the lock is released.
    struct PendingResume {
        let chats: [MovedChat]
        let folder: URL
        let reopenedAt: Double
        let answered: Bool
        /// The lock's generation when this switch held it; another switch changes it.
        let generation: String

        func run(progress: @escaping Progress) async -> [ChatResumer.Report] {
            var resumer = ChatResume.resumer(in: folder, reopenedAt: reopenedAt, progress: progress)
            resumer.current = { SwitchLock.generation() == generation }
            return await resumer.run(chats)
        }
    }

    /// Get Claude onto a row with no saved login, then save it and bring over the previous row's
    /// chats the way a switch does. Another account needs a sign-in: Claude quits, the current
    /// login is saved, and Claude reopens at its sign-in page, so no account is signed out. Another
    /// organization of the account Claude is on needs only Claude's own organization switch.
    static func setUp(_ target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress,
                      switched: @escaping (SwitchOutcome) async -> Void = { _ in }) async -> SwitchOutcome {
        await lockedThenResume(unattended: false, progress: progress, switched: switched) {
            await setUpLocked(target, accounts: accounts, progress: progress)
        }
    }

    private static func locked(unattended: Bool, _ body: () async -> SwitchOutcome) async -> SwitchOutcome {
        guard let lock = SwitchLock.acquire() else { return SwitchOutcome(ok: false, message: "Another switch is already running.") }
        defer { lock.release() }
        if let journal = SwitchJournal.load() {
            let undone = await rollback(journal, unattended: unattended, progress: { _ in })
            return SwitchOutcome(ok: false, message: undone ? "The last switch was interrupted, so it was undone. Try again."
                                                           : "The last switch was interrupted, and undoing it needs Claude to quit.")
        }
        return await body()
    }

    private static func switchLocked(to target: AccountRecord, accounts: [AccountRecord], unattended: Bool,
                                     progress: @escaping Progress) async -> (outcome: SwitchOutcome, resume: PendingResume?) {
        guard let want = LoginSlot.identity(target, refused: ClaudeApp.currentLog().refusedAt) else {
            return (SwitchOutcome(ok: false, message: SwitchError.noSlot(target.label).localizedDescription), nil)
        }
        if ClaudeApp.currentIdentity() == want {
            if ClaudeApp.pids().isEmpty { await ClaudeApp.launch() }
            return (SwitchOutcome(ok: true, message: "Already using \(target.label).", confirmed: true), nil)
        }
        let current: (acct: AccountRecord, id: Identity)?
        let answered: Bool, steady: Bool
        switch await prepare(accounts: accounts, unattended: unattended, progress: progress) {
        case .failure(let e): return (e.outcome, nil)
        case .success(let p): current = p.current; answered = p.answered; steady = p.steady
        }
        // Claude has quit, so its log ends with the run that just finished: the chats it stopped
        // for usage and the ones whose turn the quit cut off are the chats that were working.
        var ended = LogFollower()
        ended.read(ClaudeApp.currentRunText())
        guard var journal = startJournal(from: current?.id, to: want) else {
            await ClaudeApp.launch()
            return (SwitchOutcome(ok: false, message: "Could not back up Claude's files, so nothing was changed."), nil)
        }
        do {
            // A login Claude hasn't held steadily may be one its organization refuses; the row keeps its last one.
            if let current, steady {
                progress("Saving \(current.acct.label)…")
                try await LoginSlot.capture(current.acct, as: current.id)
            }
            progress("Loading \(target.label)…")
            try await LoginSlot.load(target)
            if let current { try moveSessions(from: current.id, to: want, journal: &journal) }
        } catch {
            _ = await rollback(journal, unattended: unattended, progress: progress)
            return (SwitchOutcome(ok: false, message: "Switch failed and was undone: \(error.localizedDescription)"), nil)
        }
        return await reopen(as: want, label: target.label, journal: journal, ended: ended, answered: answered,
                            unattended: unattended, accounts: accounts, progress: progress) { n in
            "Switched to \(target.label), with \(n) open session\(n == 1 ? "" : "s")."
        }
    }

    /// Reopen Claude as `want` once its files are written under `journal`, and keep the result only
    /// once Claude reports it; anything else is undone. The chats that moved in and were working in
    /// the run `ended` (stopped by a usage limit or cut off by the quit) are left to resume.
    private static func reopen(as want: Identity, label: String, journal: SwitchJournal, ended: LogFollower, answered: Bool,
                               unattended: Bool, accounts: [AccountRecord], progress: @escaping Progress,
                               message: (Int) -> String) async -> (outcome: SwitchOutcome, resume: PendingResume?) {
        progress("Opening Claude as \(label)…")
        let movedRecords = journal.moves.map { URL(fileURLWithPath: $0.to) }.filter { $0.deletingLastPathComponent().path == ClaudeApp.folder(want).path }
        let chats = movedRecords.compactMap(ChatResume.chat)
        let mark = ClaudeApp.logMark()
        let reopenedAt = Date().timeIntervalSince1970 * 1000
        await ClaudeApp.launch()
        switch await confirm(want, since: mark) {
        case .confirmed:
            // Keep the record of what moved beside the backup it belongs to.
            try? FileManager.default.moveItem(at: SwitchJournal.url,
                                              to: URL(fileURLWithPath: journal.backup).appendingPathComponent("switch.json"))
            pruneBackups()
            let working = ResumeRule.toResume(chats, stoppedByLimit: ended.stoppedByLimit, cutByQuit: ended.cutByQuit)
            var outcome = SwitchOutcome(ok: true, message: message(chats.count), moved: chats.count, confirmed: true, backup: journal.backup)
            guard !working.isEmpty else {
                outcome.add([], answered: answered)
                return (outcome, nil)
            }
            return (outcome, PendingResume(chats: working, folder: ClaudeApp.folder(want), reopenedAt: reopenedAt,
                                           answered: answered, generation: SwitchLock.generation()))
        case .signedOut:
            let undone = await rollback(journal, unattended: unattended, progress: progress)
            return (SwitchOutcome(ok: false, message: "The saved login of \(label) has expired, so "
                                  + (undone ? "the switch was undone. Use Set Up on its row to sign in again."
                                            : "Claude opened signed out. Quit Claude and click Switch to undo.")), nil)
        case .other(let seen):
            let who = accounts.row(for: seen)?.label ?? (seen == nil ? "no account" : "another account")
            let what = seen?.account == want.account ? "\(label) in another organization than its saved login"
                                                     : "\(who) instead of \(label)"
            let undone = await rollback(journal, unattended: unattended, progress: progress)
            return (SwitchOutcome(ok: false, message: "Claude opened as \(what), so "
                                  + (undone ? "the switch was undone." : "the switch needs undoing: quit Claude and click Switch.")), nil)
        }
    }

    /// The instruction for an organization Claude can open without a sign-in, said the same way
    /// after Set Up and after adding the organization.
    static func setUpStep(_ row: AccountRecord, claudeAccount: String?) -> String {
        SetUpRule.step(for: row, claudeAccount: claudeAccount).capitalizedFirst + ". Claude Accounts saves it once Claude stays on it for a minute, and Switch works for it after that."
    }

    private static func setUpLocked(_ target: AccountRecord, accounts: [AccountRecord], progress: @escaping Progress)
        async -> (outcome: SwitchOutcome, resume: PendingResume?) {
        let start = ClaudeApp.currentLog()
        // The row in use before the set-up, whose chats come along once Claude holds the target.
        let previous: (acct: AccountRecord, id: Identity)?
        // The run whose chats were working, and who Claude is when the wait for the target starts.
        let ended: LogFollower, base: LogFollower
        let answered: Bool
        let mark: ClaudeApp.LogMark
        let instruction: String
        if let now = start.identity, now.account == target.accountUuid {
            // Another organization of the account Claude is signed in to needs no sign-in, only
            // Claude's own organization switch, so Claude stays open.
            previous = accounts.row(for: now).map { ($0, now) }
            ended = start
            base = start
            answered = false
            mark = ClaudeApp.logMark()
            instruction = SetUpRule.step(for: target, claudeAccount: now.account).capitalizedFirst
        } else {
            let ready: Prepared
            switch await prepare(accounts: accounts, unattended: false, progress: progress) {
            case .failure(let e): return (e.outcome, nil)
            case .success(let p): ready = p
            }
            previous = ready.current
            answered = ready.answered
            var run = LogFollower()
            run.read(ClaudeApp.currentRunText())
            ended = run
            base = LogFollower()
            guard let journal = startJournal(from: previous?.id, to: nil) else {
                await ClaudeApp.launch()
                return (SwitchOutcome(ok: false, message: "Could not back up Claude's files, so nothing was changed."), nil)
            }
            do {
                if let previous, ready.steady {
                    progress("Saving \(previous.acct.label)…")
                    try await LoginSlot.capture(previous.acct, as: previous.id)
                }
                try await LoginSlot.load(nil)
            } catch {
                _ = await rollback(journal, progress: progress)
                return (SwitchOutcome(ok: false, message: "Set up failed and was undone: \(error.localizedDescription)"), nil)
            }
            SwitchJournal.clear()
            mark = ClaudeApp.logMark()
            await ClaudeApp.launch()
            // Signed in to the account, Claude still opens its last organization, so name the one to choose.
            instruction = "Sign in to Claude as \(target.label)" + (accounts.otherOrganizations(of: target).isEmpty ? ""
                : ", then " + SetUpRule.step(for: target, claudeAccount: target.accountUuid))
        }
        let moving = previous.map { ClaudeApp.openSessionRecords(in: ClaudeApp.folder($0.id)).count } ?? 0
        let bring = previous.map { moving > 0 ? " and brings over the sessions open in \($0.acct.label)" : "" } ?? ""
        progress(instruction + ". Claude Accounts saves it once Claude stays on it for a minute\(bring).")

        let started = Date()
        var seen = base
        var verdict = SetUpRule.Verdict.waiting
        while verdict == .waiting {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            seen = base
            seen.read(ClaudeApp.logText(since: mark))
            verdict = SetUpRule.verdict(for: target, in: accounts, log: seen, started: started, now: Date())
        }
        // Not on the row: nothing is saved under it, nothing moves, and Claude is left as it is.
        guard case .confirmed(let want) = verdict else {
            return (SwitchOutcome(ok: false, message: SetUpRule.notSetUp(target, seen: seen.identity, in: accounts), setsUp: target.id), nil)
        }
        guard let previous, previous.id != want, moving > 0 else {
            // Nothing to bring over, so the login is saved with Claude left open.
            do {
                try await LoginSlot.capture(target, as: want, whileRunning: true)
                return (SwitchOutcome(ok: true, message: "Set up \(target.label).", confirmed: true), nil)
            } catch {
                return (SwitchOutcome(ok: false, message: "\(error.localizedDescription) Claude Accounts tries again while Claude stays on \(target.label).",
                                      setsUp: target.id), nil)
            }
        }
        // Bring the previous row's chats over the way a switch does: quit, save, move, reopen.
        let ready: Prepared
        switch await prepare(accounts: accounts, unattended: false, progress: progress) {
        case .failure(let e): return (e.outcome, nil)
        case .success(let p): ready = p
        }
        guard ready.current?.id == want, ready.steady else {
            await ClaudeApp.launch()
            return (SwitchOutcome(ok: false, message: SetUpRule.notSetUp(target, seen: ready.current?.id, in: accounts), setsUp: target.id), nil)
        }
        guard var journal = startJournal(from: previous.id, to: want) else {
            await ClaudeApp.launch()
            return (SwitchOutcome(ok: false, message: "Could not back up Claude's files, so the sessions open in \(previous.acct.label) stayed there."), nil)
        }
        do {
            progress("Saving \(target.label)…")
            try await LoginSlot.capture(target, as: want)
            try moveSessions(from: previous.id, to: want, journal: &journal)
        } catch {
            _ = await rollback(journal, progress: progress)
            return (SwitchOutcome(ok: false, message: "Set up failed and was undone: \(error.localizedDescription)"), nil)
        }
        return await reopen(as: want, label: target.label, journal: journal, ended: ended, answered: answered || ready.answered,
                            unattended: false, accounts: accounts, progress: progress) { n in
            "Set up \(target.label), with the \(n) open session\(n == 1 ? "" : "s") from \(previous.acct.label)."
        }
    }

    /// Who Claude was when it quit, and whether its quit prompt was answered for nobody.
    struct Prepared {
        var current: (acct: AccountRecord, id: Identity)?
        var answered = false
        /// Claude had held `current` steadily when it quit (SaveRule), so its login may be saved.
        var steady = false
    }

    /// Resolve who Claude is, quit it, and check again once it has gone. Nothing is written here.
    private static func prepare(accounts: [AccountRecord], unattended: Bool, progress: @escaping Progress)
        async -> Result<Prepared, OutcomeError> {
        let before = ClaudeApp.currentIdentity()
        if before != nil, accounts.row(for: before) == nil {
            return .failure(OutcomeError("Claude is using an account or organization this app doesn't know. Add it first."))
        }
        progress("Quitting Claude…")
        let (quit, answered) = await ClaudeApp.quit(unattended: unattended, progress: progress)
        // Nothing has been written yet; make sure Claude is left running whatever the answer was.
        if quit != .quit, ClaudeApp.pids().isEmpty { await ClaudeApp.launch() }
        switch quit {
        case .quit: break
        case .declined: return .failure(OutcomeError("Claude stayed open, so nothing was changed."))
        case .failed: return .failure(OutcomeError("Claude didn't quit, so nothing was changed."))
        }
        // Read again after the quit: this is the state Claude's files were flushed in.
        let log = ClaudeApp.currentLog()
        guard let id = log.identity else { return .success(Prepared(current: nil, answered: answered)) }
        guard id == before, ClaudeApp.savedAccount() == id.account, let acct = accounts.row(for: id) else {
            await ClaudeApp.launch()
            return .failure(OutcomeError(SwitchError.inconsistent.localizedDescription))
        }
        return .success(Prepared(current: (acct, id), answered: answered, steady: log.steady(at: Date()) == id))
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
            if run.split(separator: "\n").contains(where: LogFollower.signsOut) { return .signedOut }
            let now = LogFollower.identity(after: String(run), from: nil)
            if now != seen { seen = now; seenSince = Date() }
            let held = Date().timeIntervalSince(seenSince)
            if now == want, held >= 4 { return .confirmed }
            if now != nil, now != want, held >= 10 { return .other(now) }
        }
        return .other(seen)
    }

    /// Put Claude's files back as they were before the switch and reopen it. Returns false,
    /// keeping the journal for a later try, if Claude can't be quit first.
    static func rollback(_ journal: SwitchJournal, unattended: Bool = false, progress: @escaping Progress) async -> Bool {
        progress("Undoing the switch…")
        guard await ClaudeApp.quit(unattended: unattended, progress: progress).outcome == .quit else { return false }
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

// MARK: - After a switch

/// Gets the chats that were working, which a usage limit or the quit stopped, running again after
/// a switch, through ChatResumer: Claude resumes the ones it marked as cut off by the quit by
/// itself, and each chat still idle gets a new message, "resume", typed into its own message
/// box; a chat that isn't running yet is tried again every minute for half an hour. Never Retry:
/// retrying the failed message rewinds the chat and starts its transcript over without its
/// subagents. Each step goes to resume.log in the app's state folder.
enum ChatResume {
    static let logURL = Paths.stateDir.appendingPathComponent("resume.log")

    /// A moved session record as the resume step needs it.
    static func chat(_ record: URL) -> MovedChat? {
        guard let obj = ClaudeApp.record(record), let id = obj["sessionId"] as? String else { return nil }
        return MovedChat(id: id, title: (obj["title"] as? String) ?? id,
                         interrupted: obj["interruptedByQuitAt"] is NSNumber,
                         lastActivity: (obj["lastActivityAt"] as? Double) ?? 0)
    }

    /// The resume step for chats whose records are in `folder`, Claude having reopened at
    /// `reopenedAt` (ms). `retrying` keeps trying on ResumeRule's schedule; `echo` also hears each step.
    static func resumer(in folder: URL, reopenedAt: Double, retrying: Bool = true,
                        progress: @escaping SwitchEngine.Progress, echo: @escaping (String) -> Void = { _ in }) -> ChatResumer {
        try? Data().write(to: logURL, options: .atomic)
        let log = try? FileHandle(forWritingTo: logURL)
        let stamp = ISO8601DateFormatter()
        return ChatResumer(
            open: { id in _ = await runProcess("/usr/bin/open", ["claude://code/continue?session=\(id)"]) },
            pids: ClaudeApp.pids,
            running: { chat in
                let obj = ClaudeApp.record(folder.appendingPathComponent(chat.id + ".json"))
                let lastActivity = (obj?["lastActivityAt"] as? Double) ?? 0
                // A chat without Claude's mark has nothing to clear; only new activity shows it ran.
                return chat.interrupted
                    ? ResumeRule.resumed(markStillSet: obj?["interruptedByQuitAt"] is NSNumber, lastActivity: lastActivity, reopenedAt: reopenedAt)
                    : lastActivity > reopenedAt
            },
            progress: progress,
            trace: { step in
                log?.write(Data("\(stamp.string(from: Date())) \(step)\n".utf8))
                echo(step)
            },
            retrying: retrying)
    }

}

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

    /// The outcome of an unattended switch, after `reason` when auto-switch started it, naming the
    /// stopped chats it couldn't get running. The message they need has to be a new one: Retry on
    /// the failed message starts the chat over.
    static func outcome(_ outcome: SwitchOutcome, reason: String? = nil) {
        let body = [reason, outcome.messageWithChatsLeft].compactMap { $0 }.joined(separator: " ")
        post(outcome.ok ? "Claude Accounts switched" : "Claude Accounts didn't switch", body)
    }
}

// MARK: - Usage cache and auto-switch state

/// The last good reading per account, kept so a relaunch shows numbers without asking again
/// and so `--auto-switch` on the command line decides from what the menu last read.
enum UsageCache {
    struct Entry: Codable {
        var polledAt: Date
        var retryAt: Date?
        var plan: String?
        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var loginExpiresAt: Date?
        /// When the reading shown was taken; a later rate-limited ask doesn't move it.
        var readAt: Date?
    }

    static var url: URL { Paths.stateDir.appendingPathComponent("usage-cache.json") }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The auto-switch rule's view of each row, from cached readings.
    static func candidates(_ accounts: [AccountRecord], _ entries: [String: Entry], refused: [String: Date]) -> [SwitchCandidate] {
        let outUntil = AutoSwitchLog.outUntil()
        return accounts.map { acct in
            let e = entries[acct.id]
            let hasReading = e?.fiveHour != nil || e?.weekly != nil || e?.plan != nil
            return SwitchCandidate(acct, fiveHour: e?.fiveHour, weekly: e?.weekly,
                                   readAt: hasReading ? (e?.readAt ?? e?.polledAt) : nil,
                                   needsSignIn: e?.loginExpiresAt.map { $0.timeIntervalSinceNow < API.signInWarning } ?? false,
                                   hasSavedLogin: LoginSlot.exists(acct, refused: refused), outUntil: outUntil[acct.id])
        }
    }
}

extension SwitchCandidate {
    /// A row with its unrounded meters and their resets.
    init(_ acct: AccountRecord, fiveHour: UsageWindow?, weekly: UsageWindow?, readAt: Date?, needsSignIn: Bool,
         hasSavedLogin: Bool, outUntil: Date?) {
        self.init(id: acct.id, name: acct.label, fiveHour: fiveHour?.utilization, weekly: weekly?.utilization,
                  readAt: readAt, needsSignIn: needsSignIn, hasSavedLogin: hasSavedLogin,
                  fiveHourResetsAt: fiveHour?.resetsAt, weeklyResetsAt: weekly?.resetsAt, outUntil: outUntil)
    }
}

/// When auto-switch last tried and which rows it left out of usage, shared by the menu and the
/// command line so the cool-down and that memory hold across both and across relaunches.
enum AutoSwitchLog {
    private struct File: Codable {
        var lastAttempt: Date
        var outcome: String?
        /// Rows a switch left because Claude stopped a chat at their limit, each until its reset.
        var outUntil: [String: Date]?
    }
    private static var url: URL { Paths.stateDir.appendingPathComponent("auto-switch.json") }

    private static func load() -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    private static func save(_ file: File) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func lastAttempt() -> Date? { load()?.lastAttempt }

    /// Rows still counted as out, by id.
    static func outUntil(now: Date = Date()) -> [String: Date] { (load()?.outUntil ?? [:]).filter { $0.value > now } }

    /// An automatic switch starts at `date`, leaving `row` out of usage until `until`.
    static func started(_ date: Date, leaving row: String, outUntil until: Date) {
        var out = outUntil(now: date)
        out[row] = until
        save(File(lastAttempt: date, outcome: nil, outUntil: out))
    }

    /// The automatic switch that started last ended with `outcome`.
    static func finished(_ outcome: String) {
        guard var file = load() else { return }
        file.outcome = outcome
        save(file)
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountRecord] = AccountStore.load()
    @Published var states: [String: AccountState] = [:]
    /// Who Claude reports it is signed in as, from its own log.
    @Published var inUse: Identity? { didSet { endSetUpMessageIfDone() } }
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var message: String?
    /// The message stays until closed instead of clearing itself.
    @Published var messageStays = false
    /// The row whose set up the message asks for; the message goes once that row is set up.
    private(set) var messageEndsWithSetUp: String?
    /// The account the sign-in window re-authenticates; nil means it adds a new one.
    @Published var signInTarget: AccountRecord?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settings = AppSettings.load() { didSet { settings.save() } }
    /// Progress text while a switch runs; nil when idle.
    @Published var switching: String?

    /// When the usage service lets each rate-limited account be asked again.
    @Published var retryAt: [String: Date] = [:]

    /// Whether this app may press Claude's quit prompt, which an unattended switch needs.
    @Published var accessibilityGranted = QuitPrompt.trusted

    private var timer: Timer?
    private let logWatcher = LogWatcher()
    private var polledAt: [String: Date] = [:]
    /// When each row's shown reading was taken.
    private var readAt: [String: Date] = [:]
    /// The row the "no account has room" notice was last posted for, so it is posted once.
    private var toldNowhereFor: String?

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
        checkAccessibility()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibility()
                self?.refresh()
                self?.considerAutoSwitch()
                self?.saveSteadyLogin()
            }
        }
    }

    func isInUse(_ acct: AccountRecord) -> Bool { accounts.row(for: inUse)?.id == acct.id }

    /// The row has a saved login Claude still accepts.
    func hasSavedLogin(_ acct: AccountRecord) -> Bool { LoginSlot.exists(acct, refused: logWatcher.log.refusedAt) }

    /// Claude has refused this row's organization's sign-in as too old.
    func isRefused(_ acct: AccountRecord) -> Bool { acct.orgUuid.map { logWatcher.log.refusedAt[$0] != nil } ?? false }

    /// The hold whose login was saved, so each steady hold is saved once.
    private var savedHold: String?

    /// Save the in-use row's login once Claude has held its account and organization steadily
    /// (SaveRule), with Claude left open, so a row is saved without a switch away from it. Never
    /// while a switch or set-up runs; the lock is taken without overtaking a resume.
    private func saveSteadyLogin() {
        let log = logWatcher.log
        guard switching == nil, let held = log.steady(at: Date()), let since = log.heldSince,
              let row = accounts.row(for: held) else { return }
        let hold = "\(row.id) \(since.timeIntervalSince1970)"
        guard savedHold != hold, SwitchJournal.load() == nil, let lock = SwitchLock.acquire(newGeneration: false) else { return }
        savedHold = hold
        Task {
            defer { lock.release() }
            do {
                try await LoginSlot.capture(row, as: held, whileRunning: true)
            } catch SwitchError.cookiesChanging {
                self.savedHold = nil  // tried again on the next tick
            } catch {}
            self.objectWillChange.send()
            self.endSetUpMessageIfDone()
        }
    }

    /// Opening the menu calls this; accounts that aren't due yet keep their cached reading.
    func refreshIfStale() { refresh() }

    /// Read usage for every account that is due: not asked in the last `minPollInterval`,
    /// and not inside a rate-limit wait. `forcing` skips the spacing for one account
    /// (a fresh sign-in) but still honours a rate-limit wait.
    func refresh(forcing forcedId: String? = nil, manual: Bool = false) {
        guard !loading else { return }
        accounts = AccountStore.load()
        inUse = logWatcher.poll()
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
            self.considerAutoSwitch()
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
        if case .ok = state { readAt[id] = Date() }
    }

    // MARK: Cache

    private func loadCache() {
        let entries = UsageCache.load()
        guard !entries.isEmpty else { return }
        for (id, e) in entries {
            polledAt[id] = e.polledAt
            if let r = e.retryAt, r > Date() { retryAt[id] = r }
            if e.fiveHour != nil || e.weekly != nil || e.plan != nil {
                states[id] = .ok(plan: e.plan, fiveHour: e.fiveHour, weekly: e.weekly, loginExpiresAt: e.loginExpiresAt)
                readAt[id] = e.readAt ?? e.polledAt
            } else if let r = retryAt[id] {
                states[id] = .rateLimited(until: r)
            }
        }
        lastUpdated = entries.values.map(\.polledAt).max()
    }

    private func saveCache() {
        var entries: [String: UsageCache.Entry] = [:]
        for (id, polled) in polledAt {
            // A rate-limit wait is saved even without a reading, so a relaunch doesn't ask again early.
            if case .ok(let plan, let fh, let wk, let exp) = states[id] {
                entries[id] = UsageCache.Entry(polledAt: polled, retryAt: retryAt[id], plan: plan, fiveHour: fh, weekly: wk,
                                               loginExpiresAt: exp, readAt: readAt[id])
            } else if let wait = retryAt[id] {
                entries[id] = UsageCache.Entry(polledAt: polled, retryAt: wait)
            }
        }
        UsageCache.save(entries)
    }

    // MARK: Auto-switch

    /// Run the auto-switch rule, and switch with nobody at the Mac when it says so. Claude's log
    /// is read first, so a chat Claude stops for usage is acted on at the next tick. The attempt
    /// is logged before it starts, so the cool-down holds even if this app quits partway.
    func considerAutoSwitch() {
        guard settings.autoSwitch, switching == nil else { return }
        inUse = logWatcher.poll()
        let now = Date()
        let all = candidates(now: now)
        let current = accounts.row(for: inUse).flatMap { row in all.first { $0.id == row.id } }
        // The log's stops belong to the account it names, which is `inUse`.
        let stopped = !logWatcher.log.stoppedByLimit.isEmpty
        // Only look for Claude's process once Claude has stopped a chat; `ps` is the reliable check.
        let decision = AutoSwitchRule.decide(current: current, rows: all, enabled: true, limitStopped: stopped,
                                             claudeRunning: stopped && !ClaudeApp.pids().isEmpty,
                                             lastAttempt: AutoSwitchLog.lastAttempt(), now: now)
        switch decision {
        case .stay:
            if !stopped { toldNowhereFor = nil }
        case .nowhere(let why):
            // Once per account running out, not on every tick while it stays out.
            guard toldNowhereFor != current?.id else { return }
            toldNowhereFor = current?.id
            keep(why)
            Notify.post("Claude Accounts didn't switch", why)
        case .switchTo(let id, let reason):
            guard let target = accounts.first(where: { $0.id == id }), let current else { return }
            toldNowhereFor = nil
            AutoSwitchLog.started(now, leaving: current.id, outUntil: AutoSwitchRule.outUntil(leaving: current, now: now))
            flash(reason, for: 10)
            runSwitch(notify: reason) { await SwitchEngine.run(to: target, accounts: $0, unattended: true, progress: $1, switched: $2) }
        }
    }

    /// Every row as the auto-switch rule sees it, from what the menu shows, in menu order.
    private func candidates(now: Date) -> [SwitchCandidate] {
        let outUntil = AutoSwitchLog.outUntil(now: now)
        return accounts.inMenuOrder.map { acct in
            var fiveHour: UsageWindow?, weekly: UsageWindow?, taken: Date?
            if case .ok(_, let fh, let wk, _) = states[acct.id] { fiveHour = fh; weekly = wk; taken = readAt[acct.id] }
            return SwitchCandidate(acct, fiveHour: fiveHour, weekly: weekly, readAt: taken,
                                   needsSignIn: states[acct.id]?.needsSignIn ?? false, hasSavedLogin: hasSavedLogin(acct),
                                   outUntil: outUntil[acct.id])
        }
    }

    /// The row the next automatic switch would go to, which the menu marks; nil while auto-switch
    /// is off or Claude uses no row this app knows.
    var nextRow: String? {
        guard settings.autoSwitch, let row = accounts.row(for: inUse) else { return nil }
        let all = candidates(now: Date())
        guard let current = all.first(where: { $0.id == row.id }) else { return nil }
        return AutoSwitchRule.next(after: current, in: all, now: Date())?.id
    }

    /// Turn auto-switch on or off. Turning it on is a click by the person at the Mac, so this is
    /// when macOS is asked to list the app under Accessibility.
    func setAutoSwitch(_ on: Bool) {
        settings.autoSwitch = on
        if on, !QuitPrompt.trusted { QuitPrompt.requestAccess() }
        checkAccessibility()
        considerAutoSwitch()
    }

    /// Read the Accessibility grant again, on every tick and each time the menu opens, so the
    /// Allow line goes as soon as it is granted. A grant is remembered: an update changes the
    /// app's signature, and macOS then stops trusting it while its old entry still shows as on.
    func checkAccessibility() {
        let trusted = QuitPrompt.trusted
        if trusted { UserDefaults.standard.set(true, forKey: Self.grantedBeforeKey) }
        if accessibilityGranted != trusted { accessibilityGranted = trusted }
    }

    private static let grantedBeforeKey = "accessibilityGrantedBefore"

    /// An earlier build had Accessibility, so its entry in System Settings is the stale one.
    var accessibilityGrantedBefore: Bool { UserDefaults.standard.bool(forKey: Self.grantedBeforeKey) }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show a short status line that clears itself.
    func flash(_ text: String, for seconds: Double = 5) {
        message = text
        messageStays = false
        messageEndsWithSetUp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.message == text, self?.messageStays == false { self?.message = nil }
        }
    }

    /// Show a status line that stays until it is closed or the next message replaces it, or, for
    /// an instruction to set up a row, until that row is set up: a failure or a step to take in
    /// Claude must still be there when the menu is next opened.
    func keep(_ text: String, untilSetUp row: String? = nil) {
        message = text
        messageStays = true
        messageEndsWithSetUp = row
    }

    /// A set-up instruction is done once its row is in use in Claude or has a saved login.
    private func endSetUpMessageIfDone() {
        guard let id = messageEndsWithSetUp else { return }
        guard let row = accounts.first(where: { $0.id == id }) else { return closeMessage() }
        if hasSavedLogin(row) { closeMessage() }
    }

    func closeMessage() {
        message = nil
        messageStays = false
        messageEndsWithSetUp = nil
    }

    /// What a switch or a set up reports: a success clears itself, a failure or an instruction stays.
    func show(_ outcome: SwitchOutcome) {
        if outcome.ok, outcome.setsUp == nil, outcome.notResumed.isEmpty { flash(outcome.message, for: 10) }
        else { keep(outcome.messageWithChatsLeft, untilSetUp: outcome.setsUp) }
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

    /// Rename the row that was clicked: an organization entry renames its organization, any
    /// other row renames its account. An empty name puts the default name back.
    func rename(_ acct: AccountRecord, to name: String, organization: Bool) {
        save(AccountStore.load().renamed(acct, to: name, organization: organization))
    }

    /// Give an account a new color, on every one of its rows; each row keeps its place in the list.
    func recolor(_ acct: AccountRecord, _ color: String) {
        var all = AccountStore.load()
        for i in all.indices where all[i].id == acct.id || (acct.accountUuid != nil && all[i].accountUuid == acct.accountUuid) {
            all[i].color = color
        }
        save(all)
    }

    /// Move a row one place up (`step` -1) or down (`step` 1) in the menu, which is the order
    /// auto-switch tries the rows in: an organization entry among its account's organizations,
    /// any other row with its whole account.
    func move(_ acct: AccountRecord, by step: Int, organization: Bool) {
        if let moved = AccountStore.load().moved(acct, by: step, organization: organization) { save(moved) }
    }

    private func save(_ all: [AccountRecord]) {
        do {
            try AccountStore.save(all)
            accounts = all.labelled()
        } catch {
            flash("Could not save: \(error.localizedDescription)")
        }
    }

    // MARK: Switching

    /// One click: quit Claude, save the current account's login, load the target's, move the
    /// open Code sessions into the target's folder, and reopen Claude as the target.
    func switchTo(_ target: AccountRecord) { runSwitch { await SwitchEngine.run(to: target, accounts: $0, progress: $1, switched: $2) } }

    /// Reopen Claude at its sign-in page for an account that has no saved Claude login yet.
    func setUp(_ target: AccountRecord) { runSwitch { await SwitchEngine.setUp(target, accounts: $0, progress: $1, switched: $2) } }

    /// `notify` posts the outcome as a notification after that reason, for a switch auto-switch
    /// started with nobody watching. Switch is free again once the switch itself is done
    /// (`switched`); the resume that follows shows its steps on the status line, and its outcome
    /// is shown unless another switch overtook it.
    private func runSwitch(notify reason: String? = nil,
                           _ body: @escaping ([AccountRecord], @escaping SwitchEngine.Progress,
                                              @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome) {
        guard switching == nil else { return }
        switching = "Starting…"
        let all = accounts
        let phase = SwitchPhase()
        Task {
            let outcome = await body(all, { step in
                Task { @MainActor in if phase.freed { self.keep(step) } else { self.switching = step } }
            }, { switched in
                await MainActor.run {
                    phase.freed = true
                    self.switching = nil
                    self.keep(switched.message)
                    self.inUse = self.logWatcher.poll()
                }
            })
            if !phase.freed { self.switching = nil }
            guard !outcome.superseded else { return }
            self.show(outcome)
            self.inUse = self.logWatcher.poll()
            if let reason {
                AutoSwitchLog.finished(outcome.message)
                Notify.outcome(outcome, reason: reason)
            }
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
                self.flash("Removed \(acct.label).")
            } catch {
                self.flash("Could not save accounts: \(error.localizedDescription)")
            }
        }
    }

    /// The in-use account's reading for the limit the menu bar follows.
    var inUseWindow: UsageWindow? {
        guard let current = accounts.first(where: isInUse),
              case .ok(_, let fh, let wk, _) = states[current.id] else { return nil }
        return MeterRule.gauge(settings.metric, fiveHour: fh, weekly: wk)
    }

    /// Show or fold away the organizations of an account in the menu; settings.json keeps it.
    func setShowsOrganizations(of account: String, _ shown: Bool) {
        settings.setShowsOrganizations(of: account, shown)
    }

    /// Gauge position, 0...1; a third before any reading so the glyph still looks like a gauge.
    var menuBarFraction: Double { inUseWindow.map { Double($0.pct) / 100 } ?? 1.0 / 3 }

    /// Text beside the gauge, per the Menu Bar Shows setting; empty means gauge only.
    var menuBarTitle: String {
        guard let window = inUseWindow, settings.display != .gauge,
              let current = accounts.first(where: isInUse) else { return "" }
        return settings.display == .gaugePercent ? "\(window.pct)%" : "\(current.label) \(window.pct)%"
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
        /// Who was added or signed in, and what is left to do, if anything.
        case done(String, next: String?)
        /// The login landed on an organization this account already has a row for.
        case otherOrganization(OtherOrganization)
        case failed(String)
    }

    /// What the sheet needs to offer the account's other organization instead of a dead end.
    struct OtherOrganization: Equatable {
        /// The row that already stands for the organization the login landed on.
        let existing: String
        let email: String?
        /// An organization of this account that Claude has opened and no row stands for yet; the
        /// next login pre-selects it. Nil when Claude hasn't opened one.
        let known: String?
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
    /// row keeps its place, name and color. Without it, add a new account; it gets its label once
    /// sign-in finishes, so the folder gets a random id now. `organization`
    /// (a target's own, or another organization of a known account) is pre-selected on the
    /// sign-in page through Claude Code's `forceLoginOrgUUID` setting in that login's folder.
    func start(reauth target: AccountRecord? = nil, organization: String? = nil, email: String? = nil) {
        guard let cli = ClaudeCLI.path else { phase = .failed("Claude Code isn't installed. Install it, then try again."); return }
        let id = target?.id ?? "acct-" + UUID().uuidString.prefix(8).lowercased()
        let dir = target?.configURL ?? Paths.loginsDir.appendingPathComponent(id)
        let org = target?.orgUuid ?? organization
        let prefill = target?.email ?? email
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
            if let org { Self.preselect(org, in: dir) }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            // Pre-filling the email steers the browser to the right Google account.
            p.arguments = ["auth", "login", "--claudeai"] + (prefill.map { ["--email", $0] } ?? [])
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
        let org = profile["organizationUuid"] as? String
        let email = profile["emailAddress"] as? String
        // One row per account and organization. Landing on one that is already added offers the
        // account's other organization instead of stopping there.
        if let uuid = profile["accountUuid"] as? String,
           let dup = accounts.first(where: { $0.accountUuid == uuid && ($0.orgUuid == nil || org == nil || $0.orgUuid == org) }) {
            _ = await ClaudeCLI.run(configDir: draft.dir, ["auth", "logout"])
            await Keychain.delete(service: service)
            try? FileManager.default.removeItem(at: draft.dir)
            let known = accounts.organizationsToAdd(account: uuid, opened: ClaudeApp.organizations(of: uuid)).first
            phase = .otherOrganization(OtherOrganization(existing: dup.label, email: email, known: known))
            self.draft = nil
            return
        }
        let orgName = profile["organizationName"] as? String
        let account = accounts.first { $0.accountUuid != nil && $0.accountUuid == profile["accountUuid"] as? String }
        let usedColors = Set(accounts.map(\.color))
        var record = AccountRecord(
            id: draft.id,
            name: "",
            // Another organization of a known account keeps that account's color.
            color: account?.color ?? presetColors.first { !usedColors.contains($0) } ?? presetColors[accounts.count % presetColors.count],
            configDir: draft.dir.path.replacingOccurrences(of: Paths.home.path, with: "~"),
            keychainService: service,
            email: email,
            accountUuid: profile["accountUuid"] as? String,
            orgName: orgName,
            orgUuid: org)
        record.name = (accounts + [record]).accountName(for: record)
        accounts = (accounts + [record]).labelled()
        if let org { Self.preselect(org, in: draft.dir) }
        do {
            try AccountStore.save(accounts)
            // Claude's own login for this organization is the one step the app can't take.
            let next = account == nil ? nil : SwitchEngine.setUpStep(record, claudeAccount: record.accountUuid)
            phase = .done(accounts.last?.label ?? record.name, next: next)
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
            phase = .done(target.label, next: nil)
            return
        }
        if let snap = rollback?.keychain { await Keychain.restore(service: target.keychainService, snap) }
        if let file = rollback?.profile { try? file.write(to: dir.appendingPathComponent(".claude.json"), options: .atomic) }
        phase = .failed("That sign-in was a different account than \(target.label), so the previous login was kept. Try again and pick the Google account \(target.name) belongs to.")
    }

    /// Pin a login folder to one organization: Claude Code pre-selects it on the sign-in page
    /// ("From any settings file, Claude Code also uses a single UUID to pre-select that
    /// organization", per its settings reference), so a second organization of the same account
    /// can be added and a sign-in again lands on the row's own organization.
    nonisolated static func preselect(_ org: String, in dir: URL) {
        let file = dir.appendingPathComponent("settings.json")
        var settings = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] ?? [:]
        guard settings["forceLoginOrgUUID"] as? String != org else { return }
        settings["forceLoginOrgUUID"] = org
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The Claude Code login's profile: account, email and organization. It holds no secret.
    nonisolated static func profile(in dir: URL) -> [String: Any] {
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

/// The capsule in the action slot of the row in use.
struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

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

/// A name that turns into a text field while it is renamed: Return saves, Escape cancels, and an
/// empty name puts the default name back.
struct RenameField: View {
    let current: String
    @Binding var renaming: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .focused($focused)
            .onAppear { draft = current; focused = true }
            .onSubmit { onCommit(draft); renaming = false }
            .onExitCommand { renaming = false }
    }
}

/// The account colors, with the current one checked.
struct ColorMenu: View {
    let current: String
    let onPick: (String) -> Void

    var body: some View {
        Menu("Color") {
            ForEach(accountColors, id: \.hex) { color in
                Button { onPick(color.hex) } label: {
                    if color.hex == current { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                }
            }
        }
    }
}

/// Move Up and Move Down in a row's menu: the menu's order is the order auto-switch tries rows in.
/// Each is nil where the row is already at that end; with neither, the menu leaves them out.
struct RowMoves {
    let up: (() -> Void)?
    let down: (() -> Void)?

    @ViewBuilder var items: some View {
        if up != nil || down != nil {
            Divider()
            Button("Move Up") { up?() }.disabled(up == nil)
            Button("Move Down") { down?() }.disabled(down == nil)
        }
    }
}

/// The mark on the row the next automatic switch goes to.
struct NextMark: View {
    var body: some View {
        Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            .help("Auto-switch goes here next when Claude stops a chat for usage. Move rows up or down from their ··· menu to change the order.")
    }
}

/// The name above an account's organizations: clicking it shows or folds them away, and its own
/// menu renames or recolors the account.
struct AccountHeader: View {
    let name: String
    let color: String
    let shown: Bool
    /// Folded away while one of the organizations is in use.
    let inUse: Bool
    /// Folded away while the next automatic switch goes to one of the organizations.
    let next: Bool
    let canReset: Bool
    let onFold: () -> Void
    let onRename: (String) -> Void
    let onRecolor: (String) -> Void
    let move: RowMoves
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 8) {
            if renaming {
                Circle().fill(Color(hex: color)).frame(width: 9, height: 9)
                RenameField(current: name, renaming: $renaming, onCommit: onRename)
            } else {
                Button(action: onFold) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: color)).frame(width: 9, height: 9)
                        Text(name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(shown ? 90 : 0))
                        if next { NextMark() }
                        Spacer()
                        if inUse { Badge(text: "In use") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shown ? "Hide this account's organizations" : "Show this account's organizations")
                .accessibilityLabel(name)
                .accessibilityValue(shown ? "Organizations shown" : "Organizations hidden")
            }
            Menu {
                Button("Rename…") { renaming = true }
                if canReset { Button("Reset Name") { onRename("") } }
                ColorMenu(current: color, onPick: onRecolor)
                move.items
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(name) options")
        }
    }
}

struct AccountRow: View {
    let account: AccountRecord
    let state: AccountState?
    let inUse: Bool
    /// The next automatic switch goes to this row.
    let next: Bool
    /// Another organization of this row's account is the one in use.
    let sameAccountInUse: Bool
    let canSwitch: Bool
    /// How to set up a row Claude has no saved login for yet; nil once it has one or is in use.
    let setUpStep: String?
    let switchBusy: Bool
    let onSwitch: () -> Void
    let onSetUp: () -> Void
    let retryAt: Date?
    let onSignIn: () -> Void
    let onRename: (String) -> Void
    /// Reset Name would change the name, so the row offers it.
    let canReset: Bool
    let onRecolor: (String) -> Void
    let onRemove: () -> Void
    let move: RowMoves
    /// Set when the row is shown under its account's name as one of that account's organizations.
    var organizationTitle: String? = nil
    private var organizationEntry: Bool { organizationTitle != nil }
    @State private var confirmingRemove = false
    @State private var renaming = false

    /// "Login expires in 5 h" inside the warning window, nil otherwise.
    private var expiryWarning: String? {
        guard case .ok(_, _, _, let expires?) = state, expires.timeIntervalSinceNow < API.signInWarning else { return nil }
        let hours = max(Int(expires.timeIntervalSinceNow / 3600), 0)
        return hours > 0 ? "Login expires in \(hours) h." : "Login expires within the hour."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // An organization entry lines up under its account's dot instead of repeating it.
                Circle().fill(organizationEntry ? Color.clear : Color(hex: account.color)).frame(width: 9, height: 9)
                if renaming {
                    RenameField(current: organizationTitle ?? account.name, renaming: $renaming, onCommit: onRename)
                } else {
                    Text(organizationTitle ?? account.name)
                        .fontWeight(organizationEntry ? .regular : .semibold).lineLimit(1).truncationMode(.middle)
                        .help(account.label)
                    if case .ok(let plan?, _, _, _) = state {
                        Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if next { NextMark() }
                }
                Spacer()
                // One fixed box for both, so "In use" and Switch share a center line and right edge.
                Group {
                    switch RowAction.pick(inUse: inUse, hasSavedLogin: canSwitch) {
                    case .inUse:
                        Badge(text: "In use")
                    case .switchTo:
                        Button("Switch", action: onSwitch).controlSize(.small).disabled(switchBusy)
                            .help(organizationEntry ? "Quit Claude, switch it to this organization, and bring your open sessions along"
                                                    : "Quit Claude, sign it in as this account, and bring your open sessions along")
                    case .setUp:
                        Button("Set Up", action: onSetUp).controlSize(.small).disabled(switchBusy)
                            .help(sameAccountInUse
                                  ? "Shows how to save this organization: choose it once in Claude's own account menu"
                                  : "Quit Claude, save the account it's using, and reopen it at the sign-in page for this account")
                    }
                }
                .frame(width: 62, height: 22, alignment: .trailing)
                Menu {
                    // An organization entry's name is its organization; the account's menu is on its name above.
                    if !organizationEntry {
                        Text(account.organization)
                        Divider()
                    }
                    Button("Rename…") { renaming = true }
                    if canReset { Button("Reset Name") { onRename("") } }
                    if !organizationEntry { ColorMenu(current: account.color, onPick: onRecolor) }
                    move.items
                    Divider()
                    Button("Sign in again…", action: onSignIn)
                    Button("Remove…") { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            switch state {
            case .ok(_, let fh, let wk, _):
                if MeterRule.showsFiveHour(fiveHour: fh, weekly: wk) { Meter(label: "5-hour", window: fh) }
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
            if let setUpStep {
                Text("Not set up: \(setUpStep).").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirmingRemove {
                HStack {
                    Text("Remove \(account.label) from this app?").font(.caption)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    Toggle("Auto-Switch When Out", isOn: Binding(get: { store.settings.autoSwitch },
                                                                set: { store.setAutoSwitch($0) }))
                        .help("When Claude stops a chat because the account in use is out of usage, quit Claude, reopen it on the next account in this menu's order that has room, and send \u{201C}resume\u{201D} to the chats that were working")
                    Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { _ in store.toggleOpenAtLogin() }))
                    Divider()
                    Button("Quit Claude Accounts") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            if let step = store.switching {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(step).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if let msg = store.message {
                // Wraps to every line it needs: a cut-off instruction can't be followed.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.messageStays {
                        Button { store.closeMessage() } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Close").accessibilityLabel("Close message")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if store.settings.autoSwitch, !store.accessibilityGranted {
                HStack {
                    if store.accessibilityGrantedBefore {
                        // macOS keeps the old entry switched on, so allowing it again does nothing until it is replaced.
                        Text("After an update, macOS needs Accessibility allowed again. Remove Claude Accounts from the Accessibility list with \u{201C}\u{2212}\u{201D}, then add it again.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Settings…") { store.openAccessibilitySettings() }.controlSize(.small)
                    } else {
                        Text("Auto-switch moves Claude to another account when Claude stops a chat at the usage limit. Allow Accessibility so it can answer Claude's quit prompt and send \u{201C}resume\u{201D} to the chats that were working.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") { store.setAutoSwitch(true) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if store.accounts.isEmpty {
                Text("No accounts yet. Add one to see its 5-hour and weekly usage here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            // One entry per account; an account in several organizations lists each beneath its
            // name, shown until its name is clicked to fold them away.
            let groups = store.accounts.groupedByAccount()
            let next = store.nextRow
            ForEach(groups, id: \.[0].id) { group in
                if group.count == 1 {
                    row(group[0], in: group, next: next)
                } else {
                    let account = group[0].accountUuid ?? group[0].id
                    let shown = store.settings.showsOrganizations(of: account)
                    VStack(alignment: .leading, spacing: 0) {
                        AccountHeader(name: group[0].name, color: group[0].color, shown: shown,
                                      inUse: !shown && group.contains(where: store.isInUse),
                                      next: !shown && group.contains { $0.id == next },
                                      canReset: store.accounts.renamed(group[0], to: "", organization: false).first { $0.id == group[0].id }?.name != group[0].name,
                                      onFold: {
                                          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { store.setShowsOrganizations(of: account, !shown) }
                                      },
                                      onRename: { store.rename(group[0], to: $0, organization: false) },
                                      onRecolor: { store.recolor(group[0], $0) },
                                      move: moves(group[0], organization: false))
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, shown ? 0 : 8)
                        if shown {
                            ForEach(group) { acct in
                                row(acct, in: group, next: next, organizationTitle: acct.organization)
                            }
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 330)
        .onAppear {
            store.checkAccessibility()
            store.refreshIfStale()
        }
    }

    private func row(_ acct: AccountRecord, in group: [AccountRecord], next: String?, organizationTitle: String? = nil) -> some View {
        AccountRow(account: acct, state: store.states[acct.id], inUse: store.isInUse(acct), next: acct.id == next,
                   sameAccountInUse: !store.isInUse(acct) && acct.accountUuid != nil && acct.accountUuid == store.inUse?.account,
                   canSwitch: store.hasSavedLogin(acct),
                   // The status line already says it once Set Up was clicked.
                   setUpStep: store.hasSavedLogin(acct) || (store.isInUse(acct) && !store.isRefused(acct))
                       || store.messageEndsWithSetUp == acct.id ? nil
                       : SetUpRule.step(for: acct, claudeAccount: store.inUse?.account, refused: store.isRefused(acct)),
                   switchBusy: store.switching != nil,
                   onSwitch: { store.switchTo(acct) }, onSetUp: { store.setUp(acct) },
                   retryAt: store.retryAt[acct.id],
                   onSignIn: { openSignIn(acct) },
                   onRename: { store.rename(acct, to: $0, organization: organizationTitle != nil) },
                   canReset: store.accounts.renamed(acct, to: "", organization: organizationTitle != nil)
                       .first { $0.id == acct.id }.map { $0.label != acct.label } ?? false,
                   // An account's color is shared by all of its organizations.
                   onRecolor: { store.recolor(acct, $0) },
                   onRemove: { store.remove(acct) },
                   move: moves(acct, organization: organizationTitle != nil),
                   organizationTitle: organizationTitle)
    }

    /// Move Up and Move Down for a row's menu, each nil where the row is already at that end.
    private func moves(_ acct: AccountRecord, organization: Bool) -> RowMoves {
        func step(_ by: Int) -> (() -> Void)? {
            store.accounts.moved(acct, by: by, organization: organization) == nil ? nil
                : { store.move(acct, by: by, organization: organization) }
        }
        return RowMoves(up: step(-1), down: step(1))
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
            Text(target.map { "Sign in again: \($0.label)" } ?? "Add a Claude account")
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

    private func restart(reauth: AccountRecord?, organization: String? = nil, email: String? = nil) {
        code = ""
        target = reauth
        flow.reset()
        flow.start(reauth: reauth, organization: organization, email: email)
    }

    private func close() { dismissWindow(id: "sign-in") }

    @ViewBuilder private var steps: some View {
        switch flow.phase {
        case .idle, .starting:
            HStack { ProgressView().controlSize(.small); Text("Opening the sign-in page in your browser…").font(.callout) }
        case .waitingForCode:
            Text(target.map { "In your browser, choose Continue with Google and pick the account \($0.label) belongs to. After you click Authorize, the page shows a code. Paste it here." }
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
        case .done(let who, let next):
            Label(target == nil ? "Added \(who)." : "Signed in again as \(who).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let next { Text(next).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if target == nil { Button("Add another") { restart(reauth: nil) } }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .onAppear { store.refresh(forcing: target?.id) }
        case .otherOrganization(let other):
            Text("That organization is already added as \(other.existing). To add this account's other organization, sign in once more"
                 + (other.known == nil ? " and choose the other organization on the page before you click Authorize."
                                       : "; the page picks the other organization for you."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { close() }
                Spacer()
                Button("Add Other Organization") { restart(reauth: nil, organization: other.known, email: other.email) }
                    .keyboardShortcut(.defaultAction)
            }
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

/// The command line, for running a switch from outside Claude:
///
/// - `--status` prints what a switch would act on.
/// - `--switch <account>` runs the menu's switch. The account can be named by id, label, email,
///   or the email's first part; none of them is printed back beyond the label.
/// - `--auto-switch` runs the menu's Auto-Switch rule once: if Claude's log shows it stopped a
///   chat of the account in use for usage, it switches to the next row in the menu's order that
///   is set up and has room, judged on the usage the menu last read.
/// - `--unattended` (implied by `--auto-switch`) answers Claude's quit prompt with Quit anyway.
/// - `--dry-run` prints every check and what would happen, and changes nothing.
/// - `--detach` starts the same command in its own session, so it outlives Claude quitting even
///   when started from a shell inside Claude, and writes its output to `--log <file>`
///   (default: last-switch.log in the app's state folder).
///
/// - `--test-resume <session id or title>` sends "resume" to that one chat of the account Claude
///   has open, by the same steps a switch takes after it reopens Claude, in one pass, and prints
///   each step. It takes the switch lock, so it never runs during a switch.
///
/// A real run prints the outcome as JSON and saves it to last-switch.json in the state folder.
@main
enum Entry {
    static func main() {
        Migration.moveLegacyState()
        let args = CommandLine.arguments
        if args.contains("--status") { printStatus() }
        if let key = value(after: "--test-resume", in: args) { TestResume.run(key) }
        let auto = args.contains("--auto-switch")
        guard auto || args.contains("--switch") else {
            ClaudeAccountsApp.main()
            return
        }
        if args.contains("--detach") { detach(args) }
        signal(SIGHUP, SIG_IGN)
        let accounts = AccountStore.load()
        let dryRun = args.contains("--dry-run")
        let unattended = auto || args.contains("--unattended")

        let target: AccountRecord
        var autoReason: String?
        if auto {
            let (decision, current) = printDecision(accounts: accounts)
            switch decision {
            case .switchTo(let id, let reason) where accounts.contains { $0.id == id }:
                target = accounts.first { $0.id == id }!
                autoReason = reason
                if !dryRun, let current {
                    AutoSwitchLog.started(Date(), leaving: current.id, outUntil: AutoSwitchRule.outUntil(leaving: current, now: Date()))
                }
            case .nowhere(let why):
                if dryRun { exit(0) }
                Notify.post("Claude Accounts didn't switch", why)
                finish(SwitchOutcome(ok: true, message: "No switch: \(why)"), save: false)
            case .stay(let why):
                if dryRun { exit(0) }
                finish(SwitchOutcome(ok: true, message: "No switch: \(why)"), save: false)
            case .switchTo:
                exit(1)
            }
        } else {
            let key = (value(after: "--switch", in: args) ?? "").lowercased()
            let matches = accounts.filter {
                [$0.id, $0.label, $0.name, $0.email ?? "", String(($0.email ?? "").prefix { $0 != "@" })]
                    .map { $0.lowercased() }.contains(key)
            }
            guard matches.count == 1, let match = matches.first else {
                finish(SwitchOutcome(ok: false, message: matches.isEmpty ? "No account is named \(key)." : "\(key) names more than one account."),
                       save: !dryRun)
            }
            target = match
        }
        if dryRun { printPlan(to: target, accounts: accounts, unattended: unattended) }
        final class Box: @unchecked Sendable { var outcome = SwitchOutcome(ok: false, message: "did not run") }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.outcome = await SwitchEngine.run(to: target, accounts: accounts, unattended: unattended) { step in
                FileHandle.standardError.write(Data("… \(step)\n".utf8))
            }
            done.signal()
        }
        done.wait()
        if auto { AutoSwitchLog.finished(box.outcome.message) }
        if unattended { Notify.outcome(box.outcome, reason: autoReason) }
        finish(box.outcome, save: true)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Start this command again without `--detach`, as the leader of a new session with its
    /// output in a log file, and return at once. Claude ends the processes it started when it
    /// quits; a process in its own session, whose parent has exited, is not one of them.
    private static func detach(_ args: [String]) -> Never {
        let log = value(after: "--log", in: args) ?? Paths.stateDir.appendingPathComponent("last-switch.log").path
        var rest = Array(args.dropFirst()).filter { $0 != "--detach" }
        if let i = rest.firstIndex(of: "--log") { rest.removeSubrange(i...min(i + 1, rest.count - 1)) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let argv = ([exe] + rest).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let status = posix_spawn(&pid, exe, &actions, &attrs, argv, environ)
        argv.forEach { free($0) }
        guard status == 0 else {
            FileHandle.standardError.write(Data("Could not start the switch: \(String(cString: strerror(status)))\n".utf8))
            exit(1)
        }
        print("Started \(rest.joined(separator: " ")) as pid \(pid); output goes to \(log)")
        exit(0)
    }

    /// `--auto-switch`: the rule's inputs and answer, from Claude's log and the usage the menu
    /// last saved. Returns the row in use too, which a switch leaves out of usage.
    private static func printDecision(accounts: [AccountRecord]) -> (AutoSwitchRule.Decision, SwitchCandidate?) {
        let log = ClaudeApp.currentLog()
        let all = UsageCache.candidates(accounts.inMenuOrder, UsageCache.load(), refused: log.refusedAt)
        let current = accounts.row(for: log.identity).flatMap { row in all.first { $0.id == row.id } }
        let now = Date()
        func describe(_ c: SwitchCandidate) -> String {
            guard let read = c.readAt else { return "no reading" }
            let age = max(Int(now.timeIntervalSince(read) / 60), 0)
            return (c.fiveHour.map { "5-hour \(AutoSwitchRule.percent($0)), " } ?? "no 5-hour limit, ")
                + "weekly \(AutoSwitchRule.percent(c.weekly ?? 0)), read \(age) min ago"
                + (c.isOut(at: now) ? ", out" : "") + setUp(c) + (c.needsSignIn ? ", needs sign-in" : "")
        }
        func setUp(_ c: SwitchCandidate) -> String {
            guard !c.hasSavedLogin, let row = accounts.first(where: { $0.id == c.id }) else { return "" }
            return ", not set up: " + SetUpRule.step(for: row, claudeAccount: log.identity?.account,
                                                     refused: row.orgUuid.map { log.refusedAt[$0] != nil } ?? false)
        }
        print("Auto-switch menu:   \(AppSettings.load().autoSwitch ? "on" : "off"); this run decides either way")
        print("In use:             \(current?.name ?? "an account this app doesn't know")")
        print("Stopped for usage:  \(log.stoppedByLimit.count) chat\(log.stoppedByLimit.count == 1 ? "" : "s") in Claude's log")
        // The menu's order is the switch order: down from the row in use, wrapping round to the top.
        let next = current.flatMap { AutoSwitchRule.next(after: $0, in: all, now: now) }
        print("Switch order, as in the menu:")
        for (n, c) in all.enumerated() {
            let mark = c.id == current?.id ? "in use, " : c.id == next?.id ? "next, " : ""
            print("  \(n + 1). \(c.name): \(mark)\(describe(c))")
        }
        print("Next switch goes to: \(next?.name ?? (current == nil ? "no row: Claude's account isn't one this app knows" : "no row: none other is set up with room"))")
        let last = AutoSwitchLog.lastAttempt()
        print("Last auto attempt:  \(last.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never")")
        let stopped = !log.stoppedByLimit.isEmpty
        let decision = AutoSwitchRule.decide(current: current, rows: all, enabled: true, limitStopped: stopped,
                                             claudeRunning: stopped && !ClaudeApp.pids().isEmpty, lastAttempt: last, now: now)
        switch decision {
        case .stay(let why): print("Decision:           stay. \(why)")
        case .nowhere(let why): print("Decision:           stay and notify. \(why)")
        case .switchTo(let id, let why): print("Decision:           switch to \(accounts.first { $0.id == id }?.label ?? id). \(why)")
        }
        return (decision, current)
    }

    /// `--status`: what a switch would act on, read-only.
    private static func printStatus() -> Never {
        let id = ClaudeApp.currentIdentity()
        let accounts = AccountStore.load()
        func name(_ uuid: String?) -> String { accounts.first { $0.accountUuid == uuid }?.name ?? (uuid ?? "none") }
        print("Claude processes: \(ClaudeApp.pids())")
        print("Claude reports:   \(id.map { "\(accounts.row(for: $0)?.label ?? "an unknown account") (organization \($0.org.prefix(8)))" } ?? "signed out")")
        print("Claude settings:  \(name(ClaudeApp.savedAccount()))")
        print("Interrupted switch: \(SwitchJournal.load() == nil ? "none" : "yes")")
        print("Auto-switch:      \(AppSettings.load().autoSwitch ? "on, when Claude stops a chat at the usage limit" : "off")")
        print("Accessibility:    \(QuitPrompt.trusted ? "granted to this process" : "not granted to this process")")
        print("Notifications:    \(Notify.permission())")
        let refused = ClaudeApp.currentLog().refusedAt
        for acct in accounts {
            print("Saved login \(acct.label): \(LoginSlot.identity(acct, refused: refused).map { "organization \($0.org.prefix(8))" } ?? "none")")
        }
        exit(0)
    }

    /// `--dry-run`: every check a switch makes before it quits Claude, and what it would then
    /// move, without quitting Claude or writing anything.
    private static func printPlan(to target: AccountRecord, accounts: [AccountRecord], unattended: Bool) -> Never {
        var problems: [String] = []
        let current = ClaudeApp.currentIdentity()
        let currentAcct = accounts.row(for: current)
        let want = LoginSlot.identity(target, refused: ClaudeApp.currentLog().refusedAt)
        print("Target:             \(target.label)")
        print("Target saved login: \(want.map { "organization \($0.org.prefix(8))" } ?? "none")")
        if want == nil { problems.append(SwitchError.noSlot(target.label).localizedDescription) }
        print("Claude reports:     \(currentAcct?.label ?? (current == nil ? "signed out" : "an account or organization this app doesn't know"))")
        if current != nil, currentAcct == nil { problems.append("Claude is using an account or organization this app doesn't know.") }
        if let want, current == want { problems.append("Claude already uses \(target.label).") }
        if let current, ClaudeApp.savedAccount() != current.account { problems.append(SwitchError.inconsistent.localizedDescription) }
        if SwitchJournal.load() != nil { problems.append("An interrupted switch would be undone first.") }
        print("Claude processes:   \(ClaudeApp.pids().count)")
        let records = current.map { ClaudeApp.openSessionRecords(in: ClaudeApp.folder($0)) } ?? []
        print("Open sessions:      \(records.count) would move to \(target.label)")
        var log = LogFollower()
        log.read(ClaudeApp.currentRunText())
        let stopped = records.compactMap(ChatResume.chat).filter { log.stoppedByLimit.contains($0.id) }.count
        print("Stopped for usage:  \(stopped) chat\(stopped == 1 ? "" : "s"), sent \u{201C}\(ResumeRule.message)\u{201D} after the switch")
        if unattended {
            print("Quit prompt:        " + (QuitPrompt.trusted
                ? "answered with \(QuitPrompt.quitAnyway) through Accessibility"
                : "waits for a person: this process has no Accessibility access"))
            print("After the switch:   each chat that was working, stopped by the limit or cut off by the quit, runs again: Claude resumes it, or it is sent \u{201C}\(ResumeRule.message)\u{201D}, tried again every minute for 30 minutes while nobody uses the Mac")
        } else {
            print("Quit prompt:        waits for a person while it is open")
        }
        print(problems.isEmpty ? "Would switch: yes" : "Would switch: no\n" + problems.map { "  - \($0)" }.joined(separator: "\n"))
        exit(problems.isEmpty ? 0 : 1)
    }

    private static func finish(_ outcome: SwitchOutcome, save: Bool) -> Never {
        let data = (try? JSONEncoder().encode(outcome)) ?? Data("{}".utf8)
        if save { try? data.write(to: Paths.stateDir.appendingPathComponent("last-switch.json"), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        exit(outcome.ok ? 0 : 1)
    }
}

struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    init() { Notify.requestPermission() }

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

/// `--test-resume`: the resume step a switch runs, once, at one chat the person names, printing
/// each step, so the path that runs with nobody at the Mac can be watched on a chat of their choice.
enum TestResume {
    static func run(_ key: String) -> Never {
        func say(_ line: String) { print(line); fflush(stdout) }
        guard !ClaudeApp.pids().isEmpty else { say("Claude isn't open."); exit(1) }
        guard let identity = ClaudeApp.currentIdentity() else { say("Claude's log doesn't name the account it has open."); exit(1) }
        let folder = ClaudeApp.folder(identity)
        let matches = ClaudeApp.openSessionRecords(in: folder).compactMap(ChatResume.chat)
            .filter { $0.id == key || $0.title.lowercased() == key.lowercased() }
        guard matches.count == 1, let chat = matches.first else {
            say(matches.isEmpty ? "No open chat of the account Claude has open has that title or session id."
                                : "\(matches.count) open chats have that title; name one by its session id:")
            for match in matches { say("  \(match.id)") }
            exit(1)
        }
        guard SwitchLock.acquire() != nil else { say("A switch is running; try again once it's done."); exit(1) }
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary) else {
            say("This process has no Accessibility access. Run it through the app, which has its own:")
            say("  open -n -W -o \"$(tty)\" --stderr \"$(tty)\" -a \"\(Bundle.main.bundlePath)\" --args --test-resume \"\(key)\"")
            exit(1)
        }
        say("Chat: \(chat.title) (\(chat.id))")
        let resumer = ChatResume.resumer(in: folder, reopenedAt: Date().timeIntervalSince1970 * 1000, retrying: false,
                                         progress: { _ in }, echo: { say("  " + $0) })
        final class Box: @unchecked Sendable { var reports: [ChatResumer.Report] = [] }
        let box = Box(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.reports = await resumer.run([chat])
            done.signal()
        }
        done.wait()
        let result = box.reports.first?.result ?? .notResumed("not tried")
        switch result {
        case .sent: say("Result: sent \u{201C}\(ResumeRule.message)\u{201D}, and the chat is running.")
        case .running: say("Result: the chat was already running, so nothing was sent.")
        case .draft: say("Result: its message box holds unsent text, so nothing was sent.")
        case .notResumed(let why): say("Result: not running: \(why).")
        }
        exit(result.runningAgain ? 0 : 1)
    }
}
