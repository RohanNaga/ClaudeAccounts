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
    static var home: URL { World.claude.home }
    /// Where the app keeps its state, so the app bundle can be installed anywhere.
    static var stateDir: URL { World.claude.stateDir }
    /// Before 0.3 the state sat in a `data` folder beside the app bundle.
    static let legacyStateDir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data")
    static var accountsFile: URL { stateDir.appendingPathComponent("accounts.json") }
    static var loginsDir: URL { stateDir.appendingPathComponent("logins") }
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

/// Reads one account's usage. Production asks the usage service with the account's own login;
/// a test scripts the meter instead.
protocol UsageReader: Sendable {
    func state(for acct: AccountRecord) async -> AccountState
}

struct ServiceUsageReader: UsageReader {
    func state(for acct: AccountRecord) async -> AccountState { await Usage.state(for: acct) }
}

enum Usage {
    nonisolated(unsafe) private(set) static var reader: any UsageReader = ServiceUsageReader()

    /// Script the meter for a test. Only after `World.install`, so a test never mixes scripted
    /// usage with the real Claude.
    static func install(_ reader: any UsageReader) {
        precondition(World.isTest, "install a test world before scripting usage")
        self.reader = reader
    }

    /// Return a login with time left on its access token, renewing through the CLI if needed.
    static func freshCredential(_ acct: AccountRecord) async -> Credential? {
        if let cred = await Keychain.credential(service: acct.keychainService),
           cred.expiresAt / 1000 - World.now().timeIntervalSince1970 > API.refreshMargin {
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
           let deadline = stored.refreshTokenExpiresAt, deadline / 1000 < World.now().timeIntervalSince1970 {
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
                return .rateLimited(until: World.now().addingTimeInterval(wait))
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
    static var bundleId: String { World.claude.bundleId }
    static var dataDir: URL { World.claude.dataDir }
    static var cookies: URL { dataDir.appendingPathComponent(ClaudeFiles.cookies) }
    static var cookiesJournal: URL { dataDir.appendingPathComponent(ClaudeFiles.cookiesJournal) }
    static var config: URL { dataDir.appendingPathComponent(ClaudeFiles.config) }
    static var sessions: URL { dataDir.appendingPathComponent(ClaudeFiles.sessions) }
    static var logDir: URL { World.claude.logDir }
    static var log: URL { logDir.appendingPathComponent(ClaudeFiles.log) }

    static var executable: String { World.claude.executable() }

    static func pids() -> [pid_t] { World.checked(World.claude.pids()) }

    static func windowIDs(_ owners: [pid_t]) -> Set<Int> { World.claude.windowIDs(owners) }

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
        for pid in running { await World.claude.requestQuit(pid) }
        var watch = QuitWatch(unattended: unattended, canAnswer: World.claude.trusted, started: World.now())
        var firstTry: Date?
        var shown: String?
        while true {
            await World.sleep(0.5)
            let alive = !pids().isEmpty
            let text = alive ? logText(since: mark) : ""
            let veto = text.range(of: ClaudeLog.quitVetoed)
            let afterVeto = veto.map { text[$0.upperBound...] } ?? ""
            let seen = QuitObservation(
                claudeRunning: alive,
                // Accessibility finds the prompt by its Quit anyway button; a window Claude opened
                // after the request also counts, which covers a prompt without that button.
                promptOpen: alive && (World.claude.quitPromptOpen(in: running) || !windowIDs(running).subtracting(windowsBefore).isEmpty),
                vetoLogged: veto != nil,
                waitLogged: afterVeto.contains(ClaudeLog.quitDeferred),
                quitLoggedAfterVeto: afterVeto.contains(ClaudeLog.quitHandler))
            switch watch.step(seen, now: World.now()) {
            case .done(let outcome): return (outcome, watch.answeredAt != nil)
            case .wait(let what):
                if what != shown { shown = what; progress(what) }
            case .answer:
                if World.claude.pressQuitPrompt(ClaudeUI.quitAnyway, in: running) {
                    watch.answered(at: World.now())
                    progress("Answered Claude's prompt with \(ClaudeUI.quitAnyway)…")
                } else if World.now().timeIntervalSince(firstTry ?? World.now()) > QuitPrompt.findTimeout {
                    // A new window with no Quit anyway button is not a prompt this app answers:
                    // leave the answer to a person and keep waiting for it.
                    watch.canAnswer = false
                }
                firstTry = firstTry ?? World.now()
            }
        }
    }

    static func launch() async { await World.claude.launch() }

    /// The account in Claude's settings, which Claude rewrites whenever its account changes.
    static func savedAccount() -> String? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[ClaudeFiles.lastKnownAccount] as? String
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
        let rotated = ClaudeFiles.rotations.map { logDir.appendingPathComponent(ClaudeFiles.rotatedLog($0)) }
            .first { logMark($0).inode == mark.inode }
        return (rotated.map { readLines($0, from: mark.offset).text } ?? "") + readLines(log, from: 0).text
    }

    /// The log of Claude's current run (or its last one, once it has quit), across a rotation.
    static func currentRunText() -> String {
        let text = readLines(logDir.appendingPathComponent(ClaudeFiles.rotatedLog(1)), from: 0).text + readLines(log, from: 0).text
        return text.range(of: ClaudeLog.appStart, options: .backwards).map { String(text[$0.lowerBound...]) } ?? text
    }

    /// Claude's last two log files read in order: who it is now (or was when it last quit), since
    /// when, and the organizations whose sign-in it refused.
    static func currentLog() -> LogFollower {
        var follower = LogFollower()
        follower.read(readLines(logDir.appendingPathComponent(ClaudeFiles.rotatedLog(1)), from: 0).text)
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
            return (obj[ClaudeFiles.isArchived] as? Bool) != true && obj[ClaudeFiles.scheduledTaskId] == nil
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

    static func lastActivity(_ url: URL) -> Double { (record(url)?[ClaudeFiles.lastActivityAt] as? Double) ?? 0 }
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
            log.read(ClaudeApp.readLines(ClaudeApp.logDir.appendingPathComponent(ClaudeFiles.rotatedLog(1)), from: 0).text)
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
    static let configKeys = ClaudeFiles.loginConfigKeys
    static let cookieSchemaVersion = "24"

    static func dir(_ acct: AccountRecord) -> URL { Paths.stateDir.appendingPathComponent("slots/\(acct.id)") }

    /// `orgFolder` is the organization whose sessions Claude showed when this login was saved.
    struct Meta: Codable { var account: String?; var orgFolder: String?; var config: [String: String] }

    static func meta(_ acct: AccountRecord) -> Meta? {
        guard let data = try? Data(contentsOf: dir(acct).appendingPathComponent("slot.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func sqlite(_ db: URL, _ sql: String) async -> ProcResult {
        await runProcess("/usr/bin/sqlite3", ["-bail", db.path, sql])
    }

    static func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "''") + "'" }

    static func cookieVersion(_ db: URL) async -> String {
        await sqlite(db, "select value from meta where key='version';").out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// The app's copy of Claude's sign-in for each seat (F4), filed under the seat's pair in
/// `saved/<account>_<org>/current`. A save builds `new`, checks it, moves `current` to `prev`,
/// moves `new` to `current`, reads it back, and only then deletes `prev`: a copy is never lost,
/// and a save that stops partway leaves `prev`, which still counts (invariant A).
enum SavedLogins {
    struct Meta: Codable, Equatable {
        var account: String
        var org: String
        /// When the copy was proven, on the app's clock.
        var savedAt: Date
        var config: [String: String]
    }

    static var root: URL { Paths.stateDir.appendingPathComponent("saved") }
    static func dir(_ seat: Identity) -> URL { root.appendingPathComponent("\(seat.account)_\(seat.org)") }
    private static func folder(_ seat: Identity, _ name: String) -> URL { dir(seat).appendingPathComponent(name) }

    /// The copy's metadata when the folder holds a copy that matches the seat's pair.
    private static func check(_ folder: URL, _ seat: Identity) -> Meta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("login.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.account == seat.account, meta.org == seat.org, meta.config[ClaudeFiles.lastKnownAccount] == seat.account,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("cookies.db").path) else { return nil }
        return meta
    }

    /// The folder with the seat's proven copy: `current`, else the `prev` an interrupted save left.
    private static func proven(_ seat: Identity) -> (folder: URL, meta: Meta)? {
        for name in ["current", "prev"] {
            let f = folder(seat, name)
            if let meta = check(f, seat) { return (f, meta) }
        }
        return nil
    }

    /// When the seat's login was saved, if it has one.
    static func savedAt(_ seat: Identity) -> Date? { proven(seat)?.meta.savedAt }

    /// Save the login Claude holds as `seat`: with Claude quit, or `whileRunning` once Claude has
    /// held the seat settled. Claude's settings must name the seat's account, and while Claude runs
    /// its cookie file must sit still through the copy and Claude must still hold the seat.
    static func save(_ seat: Identity, whileRunning: Bool = false) async throws {
        if !whileRunning { guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed } }
        guard ClaudeApp.savedAccount() == seat.account else { throw SwitchError.inconsistent }
        let fm = FileManager.default
        try fm.createDirectory(at: dir(seat), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let new = folder(seat, "new"), current = folder(seat, "current"), prev = folder(seat, "prev")
        try? fm.removeItem(at: new)
        try fm.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: new) }
        let source = new.appendingPathComponent("source.db"), sourceJournal = new.appendingPathComponent("source.db-journal")
        func stamp() -> (size: UInt64, modified: Date)? {
            guard let a = try? fm.attributesOfItem(atPath: ClaudeApp.cookies.path),
                  let size = (a[.size] as? NSNumber)?.uint64Value, let modified = a[.modificationDate] as? Date else { return nil }
            return (size, modified)
        }
        // Copied while Claude runs, the file must have sat still for 2 s and through the copy.
        let before = stamp()
        if whileRunning { guard let b = before, Date().timeIntervalSince(b.modified) >= 2 else { throw SwitchError.cookiesChanging } }
        try fm.copyItem(at: ClaudeApp.cookies, to: source)
        if fm.fileExists(atPath: ClaudeApp.cookiesJournal.path) { try fm.copyItem(at: ClaudeApp.cookiesJournal, to: sourceJournal) }
        if whileRunning { guard let a = stamp(), let b = before, a == b else { throw SwitchError.cookiesChanging } }
        guard await LoginSlot.sqlite(source, "pragma quick_check;").out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw SwitchError.sqlite("Claude's cookie database failed its integrity check")
        }
        guard await LoginSlot.cookieVersion(source) == LoginSlot.cookieSchemaVersion else { throw SwitchError.cookieSchemaChanged }
        let cookies = new.appendingPathComponent("cookies.db")
        let res = await LoginSlot.sqlite(cookies, "ATTACH \(LoginSlot.quoted(source)) AS c; CREATE TABLE cookies AS SELECT * FROM c.cookies WHERE host_key IN \(LoginSlot.hosts);")
        guard res.status == 0 else { throw SwitchError.sqlite(res.err) }
        for f in [source, sourceJournal] { try? fm.removeItem(at: f) }
        guard await signInCount(cookies) == 1 else { throw SwitchError.notSignedIn }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeApp.config)) as? [String: Any] ?? [:]
        var keys: [String: String] = [:]
        for k in LoginSlot.configKeys { if let v = config[k] as? String { keys[k] = v } }
        let meta = Meta(account: seat.account, org: seat.org, savedAt: World.now(), config: keys)
        try JSONEncoder().encode(meta).write(to: new.appendingPathComponent("login.json"), options: .atomic)
        guard check(new, seat) == meta else { throw SwitchError.inconsistent }
        if whileRunning {
            guard ClaudeApp.currentIdentity() == seat, ClaudeApp.savedAccount() == seat.account else { throw SwitchError.inconsistent }
        }
        // The proven copy moves aside, never away, until the new one reads back.
        if check(current, seat) != nil {
            try? fm.removeItem(at: prev)
            try fm.moveItem(at: current, to: prev)
        } else {
            try? fm.removeItem(at: current)
        }
        try fm.moveItem(at: new, to: current)
        guard check(current, seat) == meta, await signInCount(current.appendingPathComponent("cookies.db")) == 1 else {
            try? fm.removeItem(at: current)
            if fm.fileExists(atPath: prev.path) { try? fm.moveItem(at: prev, to: current) }
            throw SwitchError.inconsistent
        }
        try? fm.removeItem(at: prev)
    }

    private static func signInCount(_ db: URL) async -> Int {
        Int(await LoginSlot.sqlite(db, "select count(*) from cookies where name='\(ClaudeFiles.signInCookie)';").out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Put a seat's saved login into Claude's files, or with nil clear them so Claude opens at its
    /// sign-in page. Claude must be closed.
    static func load(_ seat: Identity?) async throws {
        guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
        var values: [String: String] = [:]
        var insert = ""
        if let seat {
            guard let copy = proven(seat) else { throw SwitchError.noSlot("that seat") }
            values = copy.meta.config
            insert = "ATTACH \(LoginSlot.quoted(copy.folder.appendingPathComponent("cookies.db"))) AS s; "
        }
        guard await LoginSlot.cookieVersion(ClaudeApp.cookies) == LoginSlot.cookieSchemaVersion else { throw SwitchError.cookieSchemaChanged }
        let sql = insert + "BEGIN; DELETE FROM main.cookies WHERE host_key IN \(LoginSlot.hosts); "
            + (seat == nil ? "" : "INSERT INTO main.cookies SELECT * FROM s.cookies; ") + "COMMIT;"
        let res = await LoginSlot.sqlite(ClaudeApp.cookies, sql)
        guard res.status == 0 else { throw SwitchError.sqlite(res.err) }
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: ClaudeApp.config)) as? [String: Any] ?? [:]
        for k in LoginSlot.configKeys { config[k] = values[k] }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: ClaudeApp.config, options: .atomic)
    }

    static func remove(_ seat: Identity) { try? FileManager.default.removeItem(at: dir(seat)) }

    /// A row's saved login Claude still accepts: saved, and not refused since (model, section 3).
    static func usable(_ row: AccountRecord, refusedAt: (Identity) -> Date?) -> Identity? {
        guard let seat = row.identity, let at = savedAt(seat), !(refusedAt(seat).map { $0 > at } ?? false) else { return nil }
        return seat
    }

    /// Bring each row's login from the old per-row slot into its pair's folder, once.
    static func adopt(_ rows: [AccountRecord]) {
        let fm = FileManager.default
        for row in rows {
            guard let seat = row.identity, proven(seat) == nil, let old = LoginSlot.meta(row), old.orgFolder == seat.org,
                  old.config[ClaudeFiles.lastKnownAccount] == seat.account else { continue }
            let slot = LoginSlot.dir(row), current = folder(seat, "current")
            let at = (try? slot.appendingPathComponent("slot.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            try? fm.createDirectory(at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try? fm.copyItem(at: slot.appendingPathComponent("cookies.db"), to: current.appendingPathComponent("cookies.db"))) != nil,
                  let data = try? JSONEncoder().encode(Meta(account: seat.account, org: seat.org, savedAt: at, config: old.config)),
                  (try? data.write(to: current.appendingPathComponent("login.json"), options: .atomic)) != nil else {
                try? fm.removeItem(at: current)
                continue
            }
            try? fm.removeItem(at: slot)
        }
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

    static var url: URL { Paths.stateDir.appendingPathComponent("switch-journal.json") }
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
        guard let want = SavedLogins.usable(target, refusedAt: { ClaudeApp.currentLog().refusal(of: $0, at: World.now()) }) else {
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
                try await SavedLogins.save(current.id)
            }
            progress("Loading \(target.label)…")
            try await SavedLogins.load(want)
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
        let reopenedAt = World.now().timeIntervalSince1970 * 1000
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
                    try await SavedLogins.save(previous.id)
                }
                try await SavedLogins.load(nil)
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

        let started = World.now()
        var seen = base
        var verdict = SetUpRule.Verdict.waiting
        while verdict == .waiting {
            await World.sleep(2)
            seen = base
            seen.read(ClaudeApp.logText(since: mark))
            verdict = SetUpRule.verdict(for: target, in: accounts, log: seen, started: started, now: World.now())
        }
        // Not on the row: nothing is saved under it, nothing moves, and Claude is left as it is.
        guard case .confirmed(let want) = verdict else {
            return (SwitchOutcome(ok: false, message: SetUpRule.notSetUp(target, seen: seen.identity, in: accounts), setsUp: target.id), nil)
        }
        guard let previous, previous.id != want, moving > 0 else {
            // Nothing to bring over, so the login is saved with Claude left open.
            do {
                try await SavedLogins.save(want, whileRunning: true)
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
            try await SavedLogins.save(want)
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
        return .success(Prepared(current: (acct, id), answered: answered, steady: log.steady(at: World.now()) == id))
    }

    struct OutcomeError: Error {
        let outcome: SwitchOutcome
        init(_ message: String) { outcome = SwitchOutcome(ok: false, message: message) }
    }

    /// Back up Claude's files and record the intent before the first write.
    private static func startJournal(from: Identity?, to: Identity?) -> SwitchJournal? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: World.now()).replacingOccurrences(of: ":", with: "-")
        let backup = Paths.stateDir.appendingPathComponent("backups/\(stamp)")
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: ClaudeApp.cookies, to: backup.appendingPathComponent(ClaudeFiles.cookies))
            if fm.fileExists(atPath: ClaudeApp.cookiesJournal.path) {
                try fm.copyItem(at: ClaudeApp.cookiesJournal, to: backup.appendingPathComponent(ClaudeFiles.cookiesJournal))
            }
            try fm.copyItem(at: ClaudeApp.config, to: backup.appendingPathComponent(ClaudeFiles.config))
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
        let deadline = World.now().addingTimeInterval(60)
        var seen: Identity?
        var seenSince = World.now()
        while World.now() < deadline {
            await World.sleep(1)
            let text = ClaudeApp.logText(since: mark)
            guard let start = text.range(of: ClaudeLog.appStart) else { continue }
            let run = text[start.upperBound...]
            if run.split(separator: "\n").contains(where: LogFollower.signsOut) { return .signedOut }
            let now = LogFollower.identity(after: String(run), from: nil)
            if now != seen { seen = now; seenSince = World.now() }
            let held = World.now().timeIntervalSince(seenSince)
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
        for (name, live) in [(ClaudeFiles.cookies, ClaudeApp.cookies), (ClaudeFiles.cookiesJournal, ClaudeApp.cookiesJournal), (ClaudeFiles.config, ClaudeApp.config)] {
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
    static var logURL: URL { Paths.stateDir.appendingPathComponent("resume.log") }

    /// A moved session record as the resume step needs it.
    static func chat(_ record: URL) -> MovedChat? {
        guard let obj = ClaudeApp.record(record), let id = obj[ClaudeFiles.sessionId] as? String else { return nil }
        return MovedChat(id: id, title: (obj[ClaudeFiles.title] as? String) ?? id,
                         interrupted: obj[ClaudeFiles.interruptedByQuitAt] is NSNumber,
                         lastActivity: (obj[ClaudeFiles.lastActivityAt] as? Double) ?? 0)
    }

    /// The resume step for chats whose records are in `folder`, Claude having reopened at
    /// `reopenedAt` (ms). `retrying` keeps trying on ResumeRule's schedule; `echo` also hears each step.
    static func resumer(in folder: URL, reopenedAt: Double, retrying: Bool = true,
                        progress: @escaping SwitchEngine.Progress, echo: @escaping (String) -> Void = { _ in }) -> ChatResumer {
        try? Data().write(to: logURL, options: .atomic)
        let log = try? FileHandle(forWritingTo: logURL)
        let stamp = ISO8601DateFormatter()
        return ChatResumer(
            open: { id in await World.claude.open(link: ClaudeFiles.continueLink(id)) },
            pids: ClaudeApp.pids,
            running: { chat in
                let obj = ClaudeApp.record(folder.appendingPathComponent(chat.id + ".json"))
                let lastActivity = (obj?[ClaudeFiles.lastActivityAt] as? Double) ?? 0
                // A chat without Claude's mark has nothing to clear; only new activity shows it ran.
                return chat.interrupted
                    ? ResumeRule.resumed(markStillSet: obj?[ClaudeFiles.interruptedByQuitAt] is NSNumber, lastActivity: lastActivity, reopenedAt: reopenedAt)
                    : lastActivity > reopenedAt
            },
            progress: progress,
            trace: { step in
                log?.write(Data("\(stamp.string(from: World.now())) \(step)\n".utf8))
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
    static func candidates(_ accounts: [AccountRecord], _ entries: [String: Entry], log: LogFollower) -> [SwitchCandidate] {
        let outUntil = AutoSwitchLog.outUntil()
        return accounts.map { acct in
            let e = entries[acct.id]
            let hasReading = e?.fiveHour != nil || e?.weekly != nil || e?.plan != nil
            return SwitchCandidate(acct, fiveHour: e?.fiveHour, weekly: e?.weekly,
                                   readAt: hasReading ? (e?.readAt ?? e?.polledAt) : nil,
                                   needsSignIn: e?.loginExpiresAt.map { $0.timeIntervalSinceNow < API.signInWarning } ?? false,
                                   hasSavedLogin: SavedLogins.usable(acct, refusedAt: { log.refusal(of: $0, at: World.now()) }) != nil, outUntil: outUntil[acct.id])
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
    static func outUntil(now: Date = World.now()) -> [String: Date] { (load()?.outUntil ?? [:]).filter { $0.value > now } }

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

/// A small JSON file of values keyed by seat pair, in the app's state folder.
struct PairFile<Value: Codable> {
    let name: String
    private var url: URL { Paths.stateDir.appendingPathComponent(name) }

    static func key(_ id: Identity) -> String { "\(id.account)_\(id.org)" }

    func load() -> [Identity: Value] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Value].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (Identity(account: parts[0], org: parts[1]), value) : nil
        })
    }

    func save(_ values: [Identity: Value]) {
        let raw = Dictionary(uniqueKeysWithValues: values.map { (Self.key($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Claude's log read in order into `ClaudeEvents`, reading only what is new and following
/// main.log across a rotation. A log it can't follow is read again from main1.log.
struct LogReader {
    private(set) var events = ClaudeEvents()
    private var mark: ClaudeApp.LogMark?

    mutating func poll() {
        let now = ClaudeApp.logMark()
        if let mark, mark.inode == now.inode, mark.offset <= now.offset {
            let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: mark.offset)
            events.read(text)
            self.mark = ClaudeApp.LogMark(inode: now.inode, offset: end)
            return
        }
        let rotated = ClaudeFiles.rotations.map { ClaudeApp.logDir.appendingPathComponent(ClaudeFiles.rotatedLog($0)) }
        if let mark, let older = rotated.first(where: { ClaudeApp.logMark($0).inode == mark.inode }) {
            events.read(ClaudeApp.readLines(older, from: mark.offset).text)
        } else {
            events = ClaudeEvents()
            events.read(ClaudeApp.readLines(rotated[0], from: 0).text)
        }
        let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: 0)
        events.read(text)
        self.mark = ClaudeApp.LogMark(inode: now.inode, offset: end)
    }
}

/// The menu's one source: it gathers the facts (model, section 2), publishes each seat's state
/// and the one notice from them, keeps the meters on their schedule, and runs the automatic
/// switch. All of its timing is measured on `World`'s clock: `tick()` does whatever is due at
/// that clock's now, the app calls it every few seconds, and a test calls it after moving its clock.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var seats: [Seat] = []
    @Published private(set) var notice: Notice?
    @Published private(set) var accounts: [AccountRecord] = AccountStore.load().labelled()
    @Published var lastUpdated: Date?
    @Published var loading = false
    /// The seat the sign-in window signs in again; nil adds a new one.
    @Published var signInTarget: Seat?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settings = AppSettings.load() { didSet { settings.save() } }

    /// How often the app runs `tick()`. Each step it runs has its own schedule; this only sets
    /// how soon a due step is noticed.
    static let tickEvery: TimeInterval = 5
    /// A click on Refresh re-reads a seat no sooner than this after its last read, the spacing
    /// Claude itself uses for retries.
    static let manualReadSpacing: TimeInterval = 20
    /// How long a success stays in the notice.
    static let successFor: TimeInterval = 10

    private var log = LogReader()
    private var running = false
    private var trusted = World.claude.trusted
    private var meters = PairFile<SeatMeters>(name: "meters.json").load()
    private var stops = PairFile<StopMark>(name: "stops.json").load()
    private var failedTargets: [Identity: Date] = [:]
    /// When each seat's meters were last asked for, and when the service lets it be asked again.
    private var askedAt: [Identity: Date] = [:]
    private var retryAt: [Identity: Date] = [:]
    private var forced: Set<Identity> = []
    /// The hold whose login was saved, so each settled hold is saved once.
    private var savedHold: Hold?
    /// Chats already resumed in place, so a wait resumes each stopped chat once.
    private var resumed: Set<String> = []
    private var switchingTo: SwitchFacts?
    private var failure: String?
    private var success: (text: String, until: Date)?
    private var ticking = false
    private var timer: Timer?
    private(set) var switchTask: Task<Void, Never>?

    init() {
        SavedLogins.adopt(accounts)
        publish()
    }

    /// Start the app's own ticking. Tests never call this: they call `tick()` themselves.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    // MARK: The facts

    /// Everything the model reads, as of `now` (model, section 2).
    func facts(now: Date = World.now()) -> Facts {
        var f = Facts()
        f.rows = accounts.inMenuOrder
        f.claude = ClaudeFacts(installed: World.claude.installed, running: running, recognised: true)
        f.log = log.events
        f.saved = Dictionary(accounts.compactMap { r in r.identity.flatMap { s in SavedLogins.savedAt(s).map { (s, $0) } } }, uniquingKeysWith: max)
        f.meters = meters
        f.stops = stops
        f.failedTargets = failedTargets
        f.switching = switchingTo
        f.trusted = trusted
        f.autoChosen = settings.autoSwitch
        f.waitingChats = waitingChats(f).count
        return f
    }

    /// Chats of the current run that Claude stopped for usage and that were not resumed yet.
    private func waitingChats(_ f: Facts) -> Set<String> {
        guard f.hold != nil else { return [] }
        return f.log.stoppedChats.byLimit.subtracting(resumed)
    }

    /// Rebuild the rows and the notice from the facts.
    private func publish(now: Date = World.now()) {
        let f = facts(now: now)
        if let s = success, s.until <= now { success = nil }
        seats = Seats.build(f, now: now)
        notice = AppState.notice(f, now: now, failure: failure, success: success?.text)
    }

    var firstRun: Bool { accounts.isEmpty }

    /// The fuller meter of the seat in use: the menu bar's gauge.
    var titleMeter: MeterReading? { seats.first { $0.state == .inUse }?.meters.fuller }

    // MARK: Tick

    /// Do everything due at the clock's now: read the new log lines and Claude's process, record
    /// new usage stops, save a newly settled hold's login, read the meters that are due, then run
    /// the automatic decision. An automatic switch it starts is awaited.
    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        observe()
        await saveSettledHold()
        await readDueMeters()
        publish()
        await decide()
        publish()
    }

    /// Read the facts that cost nothing: rows, Claude's process, its new log lines, Accessibility.
    private func observe() {
        accounts = AccountStore.load().labelled()
        running = !ClaudeApp.pids().isEmpty
        trusted = World.claude.trusted
        log.poll()
        recordStops()
    }

    /// Each settled usage stop becomes the seat's stop mark, with the reset of the reading taken
    /// at the stop (model, section 4). A meter read follows the stop and completes the mark.
    private func recordStops() {
        var changed = false
        for e in log.events.events where e.settled {
            guard case .limitStop = e.event, let seat = e.held, e.at > (stops[seat]?.at ?? .distantPast) else { continue }
            stops[seat] = StopMark(at: e.at, resetsAt: meters[seat]?.fullUntil(at: e.at) ?? meters[seat]?.fuller?.resetsAt)
            forced.insert(seat)
            changed = true
        }
        if changed { PairFile<StopMark>(name: "stops.json").save(stops) }
    }

    /// Save the login of a hold once it settles while Claude runs, so the seat Claude is on gets
    /// one without a switch (13a.2). With no rows yet, the held seat becomes the first row (13a.6).
    private func saveSettledHold() async {
        let now = World.now()
        guard running, switchingTo == nil, let hold = log.events.hold, hold.settled(at: now), savedHold != hold else { return }
        if accounts.isEmpty { addSeat(hold.seat) }
        guard let row = accounts.first(where: { $0.identity == hold.seat }),
              SwitchJournal.load() == nil, let lock = SwitchLock.acquire(newGeneration: false) else { return }
        defer { lock.release() }
        do {
            try await SavedLogins.save(hold.seat, whileRunning: true)
            savedHold = hold
        } catch SwitchError.cookiesChanging {
            // Tried again on the next tick.
        } catch {
            savedHold = hold
        }
    }

    // MARK: Meters

    /// The seats whose meters are due (model, section 5): never read, older than meterEvery, a
    /// reset passed since the reading, a settled turn ended since it (at most once per
    /// meterOnTurnEnd), a stop since it, or asked for. A rate-limit wait is always honoured.
    private func dueSeats(now: Date) -> [AccountRecord] {
        accounts.filter { row in
            guard let seat = row.identity else { return false }
            if let until = retryAt[seat], until > now { return false }
            if forced.contains(seat) { return true }
            guard let asked = askedAt[seat] else { return true }
            let since = now.timeIntervalSince(asked)
            if since >= Limits.meterEvery { return true }
            let readAt = meters[seat]?.readAt ?? .distantPast
            let resets = [meters[seat]?.fiveHour?.resetsAt, meters[seat]?.weekly?.resetsAt].compactMap { $0 }
            if resets.contains(where: { readAt < $0 + Limits.meterAfterReset && $0 + Limits.meterAfterReset <= now }) { return true }
            if let ended = log.events.lastTurnEnd(on: seat), ended >= readAt, since >= Limits.meterOnTurnEnd { return true }
            return false
        }
    }

    private func readDueMeters() async {
        let now = World.now()
        let due = dueSeats(now: now)
        guard !due.isEmpty else { return }
        loading = true
        defer { loading = false }
        for row in due { if let seat = row.identity { askedAt[seat] = now; forced.remove(seat) } }
        let results = await withTaskGroup(of: (Identity, AccountState).self) { group in
            for row in due { if let seat = row.identity { group.addTask { (seat, await Usage.reader.state(for: row)) } } }
            var all: [(Identity, AccountState)] = []
            for await r in group { all.append(r) }
            return all
        }
        let readAt = World.now()
        for (seat, state) in results { record(state, for: seat, at: readAt) }
        lastUpdated = readAt
        PairFile<SeatMeters>(name: "meters.json").save(meters)
    }

    /// A reading replaces the seat's meters; a rate limit or a failed read keeps the last one,
    /// which goes stale on its own. The first reading after a stop sets that stop's reset.
    private func record(_ state: AccountState, for seat: Identity, at readAt: Date) {
        switch state {
        case .ok(_, let fh, let wk, _):
            let before = meters[seat]?.readAt ?? .distantPast
            let reading = SeatMeters(fiveHour: fh.map { MeterReading(percent: $0.utilization, resetsAt: $0.resetsAt) },
                                     weekly: wk.map { MeterReading(percent: $0.utilization, resetsAt: $0.resetsAt) },
                                     readAt: readAt)
            meters[seat] = reading
            retryAt[seat] = nil
            if var mark = stops[seat], before < mark.at, readAt >= mark.at, let reset = reading.fullUntil(at: mark.at) {
                mark.resetsAt = reset
                stops[seat] = mark
                PairFile<StopMark>(name: "stops.json").save(stops)
            }
        case .rateLimited(let until):
            retryAt[seat] = until
        case .loading, .needsLogin, .error:
            break
        }
    }

    /// Opening the menu re-reads the seats that are due.
    func refreshIfStale() { Task { await tick() } }

    /// Read every seat now (Refresh), or one seat (`forcing`, after it signed in), at most once per
    /// manualReadSpacing.
    func refresh(forcing id: String? = nil, manual: Bool = false) {
        let now = World.now()
        for row in accounts where manual || row.id == id {
            guard let seat = row.identity else { continue }
            if now.timeIntervalSince(askedAt[seat] ?? .distantPast) >= Self.manualReadSpacing { forced.insert(seat) }
        }
        Task { await tick() }
    }

    // MARK: The automatic switch

    /// Run the model's decision (section 4) and act on it.
    private func decide() async {
        let now = World.now()
        let f = facts(now: now)
        switch AutoSwitch.decide(f, now: now) {
        case .none, .wait:
            break
        case .resumeInPlace:
            guard let seat = f.hold?.seat else { return }
            resumeInPlace(waitingChats(f), on: seat, now: now)
        case .switchTo(let target):
            guard let from = f.hold?.seat, let row = accounts.first(where: { $0.identity == target }) else { return }
            let name = seats.first { $0.id == from }?.name ?? "The seat in use"
            await run(to: row, kind: .auto(reason: "\(name) is out.")).value
            // A failed target is skipped for coolDown, so deciding again tries the next one.
            if failedTargets[target] != nil, failedTargets[target]! >= now { await decide() }
        }
    }

    /// Type "resume" into the chats a wait stopped, now that the seat in use has room again.
    private func resumeInPlace(_ chats: Set<String>, on seat: Identity, now: Date) {
        guard !chats.isEmpty else { return }
        resumed.formUnion(chats)
        let folder = ClaudeApp.folder(seat)
        let moved = chats.compactMap { ChatResume.chat(folder.appendingPathComponent($0 + ".json")) }
        let resumer = ChatResume.resumer(in: folder, reopenedAt: now.timeIntervalSince1970 * 1000, progress: { _ in })
        Task { _ = await resumer.run(moved) }
    }

    /// Turn Auto-Switch on or off. Turning it on is a click by the person at the Mac, so this is
    /// when macOS is asked to list the app under Accessibility.
    func setAutoSwitch(_ on: Bool) {
        settings.autoSwitch = on
        if on, !World.claude.trusted { QuitPrompt.requestAccess() }
        checkAccessibility()
        Task { await tick() }
    }

    /// Read the Accessibility grant again each time the menu opens, so its notice goes as soon
    /// as it is granted.
    func checkAccessibility() {
        let now = World.claude.trusted
        guard now != trusted else { return }
        trusted = now
        publish()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: The notice

    func noticeAction(_ action: NoticeAction) {
        switch action {
        case .openAccessibility:
            QuitPrompt.requestAccess()
            openAccessibilitySettings()
        case .addSeat:
            if running, let hold = log.events.hold { addSeat(hold.seat) }
        }
        publish()
    }

    func closeNotice() {
        failure = nil
        success = nil
        publish()
    }

    // MARK: Rows

    /// Add the seat Claude holds as a row. Its name is its account's, when another row has that
    /// account; the person can rename it. Its meters need a Claude Code sign-in, from Sign In.
    private func addSeat(_ seat: Identity) {
        guard !accounts.contains(where: { $0.identity == seat }) else { return }
        let id = UUID().uuidString
        let sibling = accounts.first { $0.accountUuid == seat.account }
        var record = AccountRecord(id: id, name: "", color: "",
                                   configDir: Paths.loginsDir.appendingPathComponent(id).path
                                       .replacingOccurrences(of: Paths.home.path, with: "~"),
                                   keychainService: Keychain.service(forConfigDir: Paths.loginsDir.appendingPathComponent(id)),
                                   email: nil, accountUuid: seat.account, orgName: nil, orgUuid: seat.org)
        record.name = sibling.map { accounts.accountName(for: $0) } ?? "Seat \(accounts.count + 1)"
        save(accounts + [record])
    }

    private func record(for seat: Seat) -> AccountRecord? { accounts.first { $0.identity == seat.id } }

    /// The row the sign-in window signs in again.
    var signInRecord: AccountRecord? { signInTarget.flatMap(record(for:)) }

    /// Rename a seat, or its organization; an empty name puts the default back.
    func rename(_ seat: Seat, to name: String, organization: Bool) {
        guard let row = record(for: seat) else { return }
        save(AccountStore.load().renamed(row, to: name, organization: organization))
    }

    /// Move a seat one place up (-1) or down (1): an organization among its account's, any other
    /// seat with its whole account. The order is the automatic switch's order.
    func move(_ seat: Seat, by step: Int, organization: Bool) {
        guard let row = record(for: seat), let moved = AccountStore.load().moved(row, by: step, organization: organization) else { return }
        save(moved)
    }

    func canMove(_ seat: Seat, by step: Int, organization: Bool) -> Bool {
        guard let row = record(for: seat) else { return false }
        return accounts.moved(row, by: step, organization: organization) != nil
    }

    /// Sign the seat's Claude Code login out, delete it and its saved login, and drop the row.
    /// Its chats stay in Claude's folder for that pair.
    func remove(_ seat: Seat) {
        guard let row = record(for: seat) else { return }
        Task {
            _ = await ClaudeCLI.run(configDir: row.configURL, ["auth", "logout"])
            if await Keychain.credential(service: row.keychainService) != nil { await Keychain.delete(service: row.keychainService) }
            try? FileManager.default.removeItem(at: row.configURL)
            SavedLogins.remove(seat.id)
            self.meters[seat.id] = nil
            self.save(AccountStore.load().filter { $0.id != row.id })
        }
    }

    private func save(_ all: [AccountRecord]) {
        do {
            try AccountStore.save(all)
            accounts = all.labelled()
        } catch {
            failure = "Couldn't save the seats: \(error.localizedDescription)"
        }
        publish()
    }

    /// Register or unregister as a macOS login item; it appears in System Settings > Login Items.
    func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            failure = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        openAtLogin = service.status == .enabled
        publish()
    }

    // MARK: Switching

    enum SwitchKind { case manual, setUp, auto(reason: String) }

    /// Switch Claude to a seat. A manual switch never checks room: it is the person's call.
    func switchTo(_ seat: Seat) {
        guard let row = record(for: seat) else { return }
        _ = run(to: row, kind: .manual)
    }

    /// Switch Claude to a seat with no saved login, at its sign-in page.
    func setUp(_ seat: Seat) {
        guard let row = record(for: seat) else { return }
        _ = run(to: row, kind: .setUp)
    }

    /// Wait for the switch in progress, if any, to end.
    func finishSwitch() async { await switchTask?.value }

    /// Run one switch; a second request while one runs is refused with a notice.
    @discardableResult
    private func run(to row: AccountRecord, kind: SwitchKind) -> Task<Void, Never> {
        if let busy = switchTask, let to = switchingTo {
            failure = "Already switching to \(seats.first { $0.id == to.target }?.name ?? "a seat")."
            publish()
            return busy
        }
        guard let target = row.identity else { return Task {} }
        failure = nil
        success = nil
        switchingTo = SwitchFacts(target: target, step: "Starting…")
        publish()
        let all = accounts
        let progress: SwitchEngine.Progress = { step in
            Task { @MainActor in
                guard self.switchingTo?.target == target else { return }
                self.switchingTo?.step = step
                self.publish()
            }
        }
        let switched: (SwitchOutcome) async -> Void = { _ in
            await MainActor.run {
                self.switchingTo = nil
                self.log.poll()
                self.publish()
            }
        }
        let task = Task {
            let outcome: SwitchOutcome
            switch kind {
            case .setUp: outcome = await SwitchEngine.setUp(row, accounts: all, progress: progress, switched: switched)
            case .manual: outcome = await SwitchEngine.run(to: row, accounts: all, progress: progress, switched: switched)
            case .auto: outcome = await SwitchEngine.run(to: row, accounts: all, unattended: true, progress: progress, switched: switched)
            }
            self.finished(outcome, target: target, kind: kind)
        }
        switchTask = task
        return task
    }

    private func finished(_ outcome: SwitchOutcome, target: Identity, kind: SwitchKind) {
        let now = World.now()
        switchingTo = nil
        switchTask = nil
        observe()
        if outcome.ok, outcome.setsUp == nil, outcome.notResumed.isEmpty {
            success = (outcome.message, now + Self.successFor)
        } else if !outcome.superseded {
            failure = outcome.messageWithChatsLeft
        }
        if case .auto(let reason) = kind {
            if !outcome.ok { failedTargets[target] = now }
            Notify.outcome(outcome, reason: reason)
        }
        publish()
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
                            try? Data(contentsOf: dir.appendingPathComponent(ClaudeFiles.cliProfile)))
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
        var record = AccountRecord(
            id: draft.id,
            name: "",
            color: account?.color ?? "",
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
        if let file = rollback?.profile { try? file.write(to: dir.appendingPathComponent(ClaudeFiles.cliProfile), options: .atomic) }
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
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(ClaudeFiles.cliProfile)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj[ClaudeFiles.cliAccount] as? [String: Any] ?? [:]
    }
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
                    AutoSwitchLog.started(World.now(), leaving: current.id, outUntil: AutoSwitchRule.outUntil(leaving: current, now: World.now()))
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
        let all = UsageCache.candidates(accounts.inMenuOrder, UsageCache.load(), log: log)
        let current = accounts.row(for: log.identity).flatMap { row in all.first { $0.id == row.id } }
        let now = World.now()
        func describe(_ c: SwitchCandidate) -> String {
            let row = accounts.first { $0.id == c.id }
            return c.summary(at: now, setUpStep: row.map {
                SetUpRule.step(for: $0, claudeAccount: log.identity?.account, refused: log.refusal(of: $0.identity, at: now) != nil)
            } ?? "")
        }
        print("Auto-switch menu:   \(AppSettings.load().autoSwitch ? "on" : "off"); this run decides either way")
        print("In use:             \(current?.name ?? "an account this app doesn't know")")
        let settledStops = log.stoppedWhileSettled.count
        print("Stopped for usage:  \(settledStops) chat\(settledStops == 1 ? "" : "s") in Claude's log since it settled on this row")
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
        let stopped = settledStops > 0
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
        print("Accessibility:    \(World.claude.trusted ? "granted to this process" : "not granted to this process")")
        print("Notifications:    \(Notify.permission())")
        let log = ClaudeApp.currentLog()
        for acct in accounts {
            print("Saved login \(acct.label): \(SavedLogins.usable(acct, refusedAt: { log.refusal(of: $0, at: World.now()) }).map { "organization \($0.org.prefix(8))" } ?? "none")")
        }
        exit(0)
    }

    /// `--dry-run`: every check a switch makes before it quits Claude, and what it would then
    /// move, without quitting Claude or writing anything.
    private static func printPlan(to target: AccountRecord, accounts: [AccountRecord], unattended: Bool) -> Never {
        var problems: [String] = []
        let current = ClaudeApp.currentIdentity()
        let currentAcct = accounts.row(for: current)
        let want = SavedLogins.usable(target, refusedAt: { ClaudeApp.currentLog().refusal(of: $0, at: World.now()) })
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
            print("Quit prompt:        " + (World.claude.trusted
                ? "answered with \(ClaudeUI.quitAnyway) through Accessibility"
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
    @StateObject private var store: Store

    init() {
        Notify.requestPermission()
        let store = Store()
        store.start()
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(nsImage: menuBarImage(title: store.titleMeter.map { "\(Int($0.percent.rounded()))%" } ?? "",
                                        fraction: store.titleMeter.map { $0.percent / 100 } ?? 1.0 / 3,
                                        warning: store.notice?.kind == .failure))
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
        guard World.claude.trusted else {
            say("This process has no Accessibility access. Run it through the app, which has its own:")
            say("  open -n -W -o \"$(tty)\" --stderr \"$(tty)\" -a \"\(Bundle.main.bundlePath)\" --args --test-resume \"\(key)\"")
            exit(1)
        }
        say("Chat: \(chat.title) (\(chat.id))")
        let resumer = ChatResume.resumer(in: folder, reopenedAt: World.now().timeIntervalSince1970 * 1000, retrying: false,
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
