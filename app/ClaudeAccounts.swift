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
    /// saved Claude login, and a label that shows an email gets its default label; this only reads,
    /// and the next save keeps it.
    static func load() -> [AccountRecord] {
        guard let data = try? Data(contentsOf: Paths.accountsFile),
              var accounts = AccountsFile.decode(data) else { return [] }
        for i in accounts.indices where accounts[i].orgUuid == nil {
            let profile = LoginFlow.profile(in: accounts[i].configURL)
            // Only a saved login names the organization; without one the row needs sign-in, and
            // Set Up fills it in (13a.4).
            accounts[i].orgUuid = LoginSlot.meta(accounts[i])?.orgFolder
            if accounts[i].orgName == nil, accounts[i].orgUuid != nil, accounts[i].orgUuid == profile["organizationUuid"] as? String {
                accounts[i].orgName = profile["organizationName"] as? String
            }
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

    /// How one quit request ended, and whether Quit anyway was pressed. A prompt found by its
    /// Quit anyway button shows that shape whole; a new window without it is a missing shape.
    struct QuitResult {
        var outcome: QuitWatch.Outcome
        var answered = false
    }

    /// Quit the way ⌘Q does, then wait until the process is gone, so Claude has flushed its
    /// cookies and settings. With a chat mid-reply Claude first asks, in a native alert: Quit
    /// anyway, Wait for Claude or Cancel. `QuitWatch` decides from the process and its windows.
    ///
    /// `unattended` answers the prompt with Quit anyway through Accessibility, the answer a person
    /// switching by hand gives; Claude then marks each cut-off chat to resume at its next launch.
    static func quit(unattended: Bool = false, progress: @Sendable (String) -> Void = { _ in }) async -> QuitResult {
        let running = pids()
        guard !running.isEmpty else { return QuitResult(outcome: .quit) }
        let windowsBefore = windowIDs(running)
        for pid in running { await World.claude.requestQuit(pid) }
        var watch = QuitWatch(unattended: unattended, canAnswer: World.claude.trusted, started: World.now())
        var firstTry: Date?
        var shown: String?
        var buttonSeen = false
        while true {
            await World.sleep(0.5)
            let alive = !pids().isEmpty
            // Accessibility finds the prompt by its Quit anyway button; a window Claude opened
            // after the request also counts, which covers a prompt without that button.
            let found = alive && World.claude.quitPromptOpen(in: running)
            if found, !buttonSeen { buttonSeen = true; ShapeMisses.seen(.quitButton) }
            let seen = QuitObservation(
                claudeRunning: alive,
                promptOpen: found || (alive && !windowIDs(running).subtracting(windowsBefore).isEmpty))
            switch watch.step(seen, now: World.now()) {
            case .done(let outcome):
                return QuitResult(outcome: outcome, answered: watch.answeredAt != nil)
            case .wait(let what):
                if what != shown { shown = what; progress(what) }
            case .cancel:
                _ = World.claude.pressQuitPrompt(ClaudeUI.cancel, in: running)
                return QuitResult(outcome: .failed, answered: watch.answeredAt != nil)
            case .answer:
                if World.claude.pressQuitPrompt(ClaudeUI.quitAnyway, in: running) {
                    watch.answered(at: World.now())
                    progress("Answered Claude's prompt with \(ClaudeUI.quitAnyway)…")
                } else if World.now().timeIntervalSince(firstTry ?? World.now()) > QuitPrompt.findTimeout {
                    // A new window with no Quit anyway button is not a prompt this app answers.
                    watch.canAnswer = false
                    ShapeMisses.missed(.quitButton)
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

    /// Claude's last two log files read in order as the model's events (F3).
    static func events() -> ClaudeEvents {
        var events = ClaudeEvents()
        events.read(readLines(logDir.appendingPathComponent(ClaudeFiles.rotatedLog(1)), from: 0).text)
        events.read(readLines(log, from: 0).text)
        return events
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

/// One account's saved Claude app login: its claude.ai cookie rows (still encrypted with
/// Claude's own key, never decrypted here) and the Code tab's token cache from config.json.
enum LoginSlot {
    static let configKeys = ClaudeFiles.loginConfigKeys

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

    /// The cookie database has the schema whose rows the app copies; otherwise it is never touched.
    static func checkCookieSchema(_ db: URL) async throws {
        guard await cookieVersion(db) == ClaudeFiles.cookieSchemaVersion else {
            ShapeMisses.missed(.cookieSchema)
            throw SwitchError.cookieSchemaChanged
        }
        ShapeMisses.seen(.cookieSchema)
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
        try await LoginSlot.checkCookieSchema(source)
        let cookies = new.appendingPathComponent("cookies.db")
        let res = await LoginSlot.sqlite(cookies, "ATTACH \(LoginSlot.quoted(source)) AS c; CREATE TABLE cookies AS SELECT * FROM c.cookies WHERE host_key IN \(ClaudeFiles.cookieHosts);")
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
            guard ClaudeApp.events().hold?.seat == seat, ClaudeApp.savedAccount() == seat.account else { throw SwitchError.inconsistent }
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
        try await LoginSlot.checkCookieSchema(ClaudeApp.cookies)
        let sql = insert + "BEGIN; DELETE FROM main.cookies WHERE host_key IN \(ClaudeFiles.cookieHosts); "
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
        case .cookieSchemaChanged: return "\(ClaudeShape.cookieSchema.why)."
        case .sqlite(let err): return "Could not update Claude's cookies: \(err.prefix(160))"
        case .quitFailed: return "Claude is running again, so nothing more was changed."
        case .inconsistent: return "Claude's settings name a different account than its log. Open and quit Claude once, then try again."
        case .cookiesChanging: return "Claude was writing its cookies, so its login is saved on a later try."
        }
    }
}

/// How one switch ended, for the notice and, after an automatic one, the notification.
struct SwitchOutcome: Equatable {
    var ok: Bool
    var text: String
    var detail: String? = nil
    /// Claude was closed when the confirm wait ran out; the journal stays until it opens again.
    var parked = false
    /// The chats the switch set out to resume, and the ones it got running.
    var toResume = 0
    var resumed = 0
    /// Each stopped chat still waiting, by title.
    var notResumed: [String] = []
    /// Another switch started during the resume and carries its chats on.
    var superseded = false
}

/// One switch at a time across the whole Mac.
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

/// The switch in progress, written before each of its steps (F7). It is the only state that
/// survives the app stopping mid-switch: recovery reads it and finishes or undoes the switch.
struct SwitchJournal: Codable, Equatable {
    enum Kind: String, Codable { case manual, auto, setUp }
    /// The steps in order. Before `load` an interrupted switch is undone; from `load` on it is finished.
    enum Step: Int, Codable, Comparable {
        case quit, save, move, load, launch, confirm
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }
    struct Move: Codable, Equatable { var from: String; var to: String }

    var kind: Kind
    var from: Identity?
    var to: Identity
    var step: Step
    /// Claude held `from` settled before the quit, so its login is saved once Claude has quit (13a.2).
    var fromSettled = false
    /// Claude's sign-in files as they were after the quit; a rollback puts them back (13a.3).
    var backup: String? = nil
    var moves: [Move] = []
    /// The chats to resume once Claude holds the target: stopped for usage or cut off by the quit.
    var resume: [String] = []
    /// Times the person opened Claude again between the quit and the launch.
    var reopened = 0
    var launchedAt: Date? = nil
    /// Claude was closed when the confirm wait ran out: confirm whenever it next opens.
    var parked = false

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

/// The one switch procedure (model, section 6). Manual Switch, Set Up and the automatic switch
/// all run it. Each step writes the journal first and can be repeated safely, and `recover`
/// finishes the procedure from the journal after the app stopped mid-switch.
enum Switch {
    typealias Progress = @Sendable (String) -> Void

    struct Request: Sendable {
        let kind: SwitchJournal.Kind
        let to: Identity
        /// Each seat's row label; a pair with no row reads "another account".
        let names: [Identity: String]
        /// Chats an automatic switch resumes besides those the log shows stopped: the wrapped-up ones.
        var resume: Set<String> = []
        func name(_ id: Identity?) -> String { id.flatMap { names[$0] } ?? "another account" }
    }

    /// The lock this process holds while a switch runs.
    nonisolated(unsafe) private static var held: SwitchLock?
    /// Chats a resume left when another switch overtook it; the next switch resumes them.
    nonisolated(unsafe) private static var carried: Set<String> = []

    /// A test drops the switch it abandoned, as if the app had quit, so the next Store recovers.
    static func abandonForTest() {
        guard World.isTest else { return }
        held?.release()
        held = nil
    }

    private static func lock() -> Bool {
        guard let lock = SwitchLock.acquire() else { return false }
        held = lock
        return true
    }

    private static func unlock() {
        held?.release()
        held = nil
    }

    /// Run a switch to `r.to`. `switched` hears how the switch ended, before the chats resume.
    static func run(_ r: Request, progress: @escaping Progress,
                    switched: @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome {
        guard lock() else { return SwitchOutcome(ok: false, text: "Another switch is running.") }
        if let open = SwitchJournal.load() {
            unlock()
            return SwitchOutcome(ok: false, text: "Finishing the switch to \(r.name(open.to)) first.")
        }
        let running = !ClaudeApp.pids().isEmpty
        let events = ClaudeApp.events()
        let hold = running ? events.hold : nil
        if r.kind != .setUp, hold?.seat == r.to {
            unlock()
            let o = SwitchOutcome(ok: true, text: "Already on \(r.name(r.to)).")
            await switched(o)
            return o
        }
        // Who Claude's files belong to: the seat it holds, or held when it last quit.
        var j = SwitchJournal(kind: r.kind, from: events.hold?.seat, to: r.to, step: .quit,
                              fromSettled: hold?.settled(at: World.now()) ?? false)
        do { try j.save() } catch {
            unlock()
            return SwitchOutcome(ok: false, text: "Couldn't write the switch's journal, so nothing changed.")
        }
        progress("Quitting Claude…")
        let quit = await ClaudeApp.quit(unattended: r.kind == .auto, progress: progress)
        switch quit.outcome {
        case .quit: break
        case .declined:
            SwitchJournal.clear()
            unlock()
            return SwitchOutcome(ok: false, text: "Switch cancelled.")
        case .failed:
            SwitchJournal.clear()
            if ClaudeApp.pids().isEmpty { await ClaudeApp.launch() }
            unlock()
            return SwitchOutcome(ok: false, text: "Claude didn't quit, so nothing changed.")
        }
        // The run that just ended names the chats that were working: stopped for usage or cut by the quit.
        let ended = ClaudeApp.events().stoppedChats
        j.resume = Array(ended.byLimit.union(ended.byQuit).union(carried).union(r.resume)).sorted()
        carried = []
        let outcome = await forward(&j, r, progress: progress)
        return await finish(outcome, j, r, progress: progress, switched: switched)
    }

    /// Finish or undo a switch the app was stopped in, from its journal (section 6, Recovery).
    /// Nil when there is none, or another process holds the lock. A parked journal waits for
    /// Claude to be opened again and is left as it is while Claude is closed.
    static func recover(names: [Identity: String], progress: @escaping Progress,
                        switched: @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome? {
        guard var j = SwitchJournal.load() else { return nil }
        let r = Request(kind: j.kind, to: j.to, names: names)
        guard lock() else { return nil }
        if j.parked, ClaudeApp.pids().isEmpty {
            unlock()
            return SwitchOutcome(ok: false, text: "Open Claude to finish switching to \(r.name(j.to)).", parked: true)
        }
        let outcome: SwitchOutcome
        if j.step < .load {
            let back = await rollback(&j, r, progress: progress)
            outcome = back.ok ? SwitchOutcome(ok: false, text: "Switch to \(r.name(j.to)) undone.") : back
        } else {
            let done = await forward(&j, r, progress: progress)
            outcome = done.ok ? SwitchOutcome(ok: true, text: "Finished switching to \(r.name(j.to)).") : done
        }
        return await finish(outcome, j, r, progress: progress, switched: switched)
    }

    /// Release the lock, tell the Store, then resume the chats a confirmed switch brought over.
    private static func finish(_ outcome: SwitchOutcome, _ j: SwitchJournal, _ r: Request, progress: @escaping Progress,
                               switched: @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome {
        var outcome = outcome
        let generation = SwitchLock.generation()
        let folder = ClaudeApp.folder(j.to)
        let chats = outcome.ok && !outcome.parked
            ? ResumeRule.toResume(ClaudeApp.openSessionRecords(in: folder).compactMap(ChatResume.chat),
                                  stoppedByLimit: Set(j.resume), cutByQuit: [])
            : []
        outcome.toResume = chats.count
        unlock()
        await switched(outcome)
        guard !chats.isEmpty else { return outcome }
        var resumer = ChatResume.resumer(in: folder, reopenedAt: (j.launchedAt ?? World.now()).timeIntervalSince1970 * 1000,
                                         progress: progress)
        resumer.current = { SwitchLock.generation() == generation }
        let reports = await resumer.run(chats)
        outcome.resumed = reports.filter(\.result.runningAgain).count
        outcome.superseded = reports.contains { $0.result == .notResumed(ChatResumer.superseded) }
        carried.formUnion(reports.filter { $0.result == .notResumed(ChatResumer.superseded) }.map(\.chat.id))
        outcome.notResumed = reports.filter { !$0.result.runningAgain && $0.result != .notResumed(ChatResumer.superseded) }
            .map(\.chat.title)
        return outcome
    }

    /// Steps save to confirm, from wherever the journal stands.
    private static func forward(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        let recovering = j.step == .confirm
        do {
            if j.step < .save {
                guard await closed(&j, r, progress: progress) else { return await rollback(&j, r, progress: progress) }
                j.backup = try backUp()
                try step(&j, .save)
            }
            if j.step == .save {
                if j.fromSettled, let from = j.from {
                    progress("Saving \(r.name(from))…")
                    try await SavedLogins.save(from)
                }
                try step(&j, .move)
            }
            if j.step == .move {
                guard await closed(&j, r, progress: progress) else { return await rollback(&j, r, progress: progress) }
                // A seat whose organization is not known yet has no chat folder until Claude names it.
                if let from = j.from, from != j.to, !j.to.orgUnknown { try moveChats(from: from, to: j.to, journal: &j) }
                try step(&j, .load)
            }
        } catch {
            var back = await rollback(&j, r, progress: progress)
            if back.ok { back = SwitchOutcome(ok: false, text: "Couldn't switch to \(r.name(j.to)).", detail: error.localizedDescription) }
            return back
        }
        do {
            if j.step == .load {
                guard await closed(&j, r, progress: progress) else { return await rollback(&j, r, progress: progress) }
                progress(j.kind == .setUp ? "Opening Claude's sign-in…" : "Loading \(r.name(j.to))…")
                try await SavedLogins.load(j.kind == .setUp ? nil : j.to)
                try step(&j, .launch)
            }
            if j.step == .launch {
                // A person who opened Claude since the load gets it quit once more (section 7).
                guard await closed(&j, r, progress: progress) else { return await rollback(&j, r, progress: progress) }
                j.launchedAt = World.now()
                try step(&j, .confirm)
                await ClaudeApp.launch()
            }
        } catch {
            // Until Claude opens, its files can still be put back.
            var back = await rollback(&j, r, progress: progress)
            if back.ok { back = SwitchOutcome(ok: false, text: "Couldn't switch to \(r.name(j.to)).", detail: error.localizedDescription) }
            return back
        }
        // Recovering a confirm: the wait starts over from Claude's run, its own or one a person
        // opened while the switch was parked. A Claude that is closed is opened again.
        if recovering, j.parked || ClaudeApp.pids().isEmpty {
            j.parked = false
            if ClaudeApp.pids().isEmpty {
                j.launchedAt = World.now()
                await ClaudeApp.launch()
            } else {
                j.launchedAt = ClaudeApp.events().events.last { $0.event == .newRun }?.at ?? World.now()
            }
            try? j.save()
        }
        return await confirm(&j, r, progress: progress)
    }

    private static func step(_ j: inout SwitchJournal, _ next: SwitchJournal.Step) throws {
        j.step = next
        try j.save()
    }

    /// Claude is closed before a write. A person who opens it between the quit and the launch gets
    /// it quit once more; the second time the switch is undone (section 7).
    private static func closed(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> Bool {
        guard !ClaudeApp.pids().isEmpty else { return true }
        j.reopened += 1
        try? j.save()
        guard j.reopened < 2 else { return false }
        progress("Quitting Claude…")
        return await ClaudeApp.quit(unattended: r.kind == .auto, progress: progress).outcome == .quit
    }

    enum Verdict: Equatable { case confirmed, waiting, refused, other(Identity?) }

    /// What Claude's log says since the launch: it holds the target settled, refused it, named
    /// another pair, or hasn't decided yet. A Set Up waits through a sign-out; a switch reads one
    /// as the target's login refused.
    static func verdict(_ events: ClaudeEvents, to: Identity, kind: SwitchJournal.Kind, since launch: Date, running: Bool, now: Date) -> Verdict {
        let start = launch.addingTimeInterval(-1)
        for e in events.events where e.at >= start {
            switch e.event {
            case .refused(let s) where to.matches(s): return .refused
            case .signedOut where kind != .setUp: return .refused
            case .named(let s) where !to.matches(s):
                // A fall-back after the target's refusal is the refusal, read on the next line.
                if events.events.contains(where: { r in
                    if r.at >= e.at, case .refused(let x) = r.event { return to.matches(x) } else { return false }
                }) { return .refused }
                return .other(s)
            default: continue
            }
        }
        if running, let hold = events.hold, to.matches(hold.seat), hold.since >= start, hold.settled(at: now) { return .confirmed }
        return .waiting
    }

    /// Wait for Claude to hold the target settled (section 6, step 6). Waits are measured against
    /// the facts: an expired wait reads the log once more, and while Claude is closed it parks.
    private static func confirm(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        let launch = j.launchedAt ?? World.now()
        let deadline = launch.addingTimeInterval(j.kind == .setUp ? Limits.setUpConfirmWait : Limits.confirmWait)
        progress(j.kind == .setUp ? "Sign in to \(r.name(j.to)) in Claude." : "Waiting for Claude to open as \(r.name(j.to))…")
        while true {
            let now = World.now()
            let running = !ClaudeApp.pids().isEmpty
            let events = ClaudeApp.events()
            let named = events.hold.map { j.to.matches($0.seat) && $0.since >= launch.addingTimeInterval(-1) } ?? false
            switch verdict(events, to: j.to, kind: j.kind, since: launch, running: running, now: now) {
            case .confirmed:
                if let backup = j.backup {
                    try? FileManager.default.moveItem(at: SwitchJournal.url, to: URL(fileURLWithPath: backup).appendingPathComponent("switch.json"))
                }
                SwitchJournal.clear()
                pruneBackups()
                return SwitchOutcome(ok: true, text: j.kind == .setUp ? "Set up \(r.name(j.to))." : "Switched to \(r.name(j.to)).")
            case .refused:
                return await rolledBack(&j, r, "\(r.name(j.to)) asked for a new sign-in.", progress: progress)
            case .other(let seen):
                let what = j.kind == .setUp ? "Claude signed in as \(r.name(seen)), not \(r.name(j.to))."
                                            : "Claude opened as \(r.name(seen)), not \(r.name(j.to))."
                return await rolledBack(&j, r, what, progress: progress)
            case .waiting:
                // Once Claude names the target, it gets the time to settle on it.
                if now >= deadline, !named || !running {
                    if !running {
                        j.parked = true
                        try? j.save()
                        return SwitchOutcome(ok: false, text: "Open Claude to finish switching to \(r.name(j.to)).", parked: true)
                    }
                    // Claude ran the whole wait and named nobody: its log lacks the line the app reads.
                    // A Set Up's wait is the person's to sign in, so a silent one says nothing.
                    let since = launch.addingTimeInterval(-1)
                    if j.kind != .setUp, !events.events.contains(where: { e in
                        if case .named = e.event { return e.at >= since } else { return false }
                    }) { ShapeMisses.missed(.namedLine, since: since) }
                    return await rolledBack(&j, r, "\(r.name(j.to)) didn't open in time.", progress: progress)
                }
            }
            await World.sleep(1)
        }
    }

    private static func rolledBack(_ j: inout SwitchJournal, _ r: Request, _ why: String, progress: @escaping Progress) async -> SwitchOutcome {
        let back = await rollback(&j, r, progress: progress)
        guard back.ok else { return back }
        return SwitchOutcome(ok: false, text: why, detail: j.from.map { "Back on \(r.name($0))." })
    }

    /// Undo: quit Claude, move the chats back, put back the files backed up after the quit, and
    /// reopen Claude. `ok` says the undo finished; a Claude that won't quit keeps the journal.
    private static func rollback(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        progress("Going back to \(r.name(j.from))…")
        if !ClaudeApp.pids().isEmpty {
            guard await ClaudeApp.quit(unattended: r.kind == .auto, progress: progress).outcome == .quit else {
                return SwitchOutcome(ok: false, text: "Quit Claude to undo the switch to \(r.name(j.to)).")
            }
        }
        let fm = FileManager.default
        for m in j.moves.reversed() where fm.fileExists(atPath: m.to) && !fm.fileExists(atPath: m.from) {
            try? fm.moveItem(atPath: m.to, toPath: m.from)
        }
        if let backup = j.backup.map(URL.init(fileURLWithPath:)) {
            if !fm.fileExists(atPath: backup.appendingPathComponent(ClaudeFiles.cookiesJournal).path) {
                try? fm.removeItem(at: ClaudeApp.cookiesJournal)
            }
            for (name, live) in [(ClaudeFiles.cookies, ClaudeApp.cookies), (ClaudeFiles.cookiesJournal, ClaudeApp.cookiesJournal),
                                 (ClaudeFiles.config, ClaudeApp.config)] {
                let saved = backup.appendingPathComponent(name)
                guard fm.fileExists(atPath: saved.path) else { continue }
                let staged = ClaudeApp.dataDir.appendingPathComponent(".\(name).restore")
                try? fm.removeItem(at: staged)
                guard (try? fm.copyItem(at: saved, to: staged)) != nil else { continue }
                if fm.fileExists(atPath: live.path) { _ = try? fm.replaceItemAt(live, withItemAt: staged) }
                else { try? fm.moveItem(at: staged, to: live) }
            }
        }
        SwitchJournal.clear()
        await ClaudeApp.launch()
        return SwitchOutcome(ok: true, text: "Back on \(r.name(j.from)).")
    }

    /// Copy Claude's sign-in files as the quit left them, before the first write.
    private static func backUp() throws -> String {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: World.now()).replacingOccurrences(of: ":", with: "-")
        let backup = Paths.stateDir.appendingPathComponent("backups/\(stamp)-\(UUID().uuidString.prefix(4))")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, live) in [(ClaudeFiles.cookies, ClaudeApp.cookies), (ClaudeFiles.cookiesJournal, ClaudeApp.cookiesJournal),
                             (ClaudeFiles.config, ClaudeApp.config)] where fm.fileExists(atPath: live.path) {
            try fm.copyItem(at: live, to: backup.appendingPathComponent(name))
        }
        return backup.path
    }

    /// Move each open chat's record from one seat's folder to the other's, keeping its id, each move
    /// written to the journal. A record already at the target (from an interrupted switch) keeps
    /// the newer copy; the older is set aside in the backup, never deleted.
    private static func moveChats(from: Identity, to: Identity, journal j: inout SwitchJournal) throws {
        let fm = FileManager.default
        let dst = ClaudeApp.folder(to)
        let quarantine = URL(fileURLWithPath: j.backup ?? Paths.stateDir.path).appendingPathComponent("quarantine")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        func move(_ a: URL, _ b: URL) throws {
            guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
            try fm.moveItem(at: a, to: b)
            j.moves.append(.init(from: a.path, to: b.path))
            try j.save()
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
                        progress: @escaping Switch.Progress, echo: @escaping (String) -> Void = { _ in }) -> ChatResumer {
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

/// The Claude shapes found missing, each with the time from which seeing it clears the miss
/// (model, section 8). Kept on disk, so the pause outlasts a restart of the app and `--status`
/// reads it. Each place that relies on a shape reports it here, missing or whole.
enum ShapeMisses {
    private static var url: URL { Paths.stateDir.appendingPathComponent("shape-misses.json") }

    static func load() -> [ClaudeShape: Date] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ClaudeShape(rawValue: k).map { ($0, v) } })
    }

    private static func save(_ misses: [ClaudeShape: Date]) {
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: misses.map { ($0.key.rawValue, $0.value) })) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// When the app last relied on a shape and found it missing, in this process. A switch that
    /// met a missing shape lets the paused line, which says why, stand in for its failure line.
    nonisolated(unsafe) private(set) static var lastMet: Date?

    /// `shape` was relied on and was not there. A Named line logged from `since` on clears it.
    static func missed(_ shape: ClaudeShape, since: Date = World.now()) {
        lastMet = World.now()
        var misses = load()
        guard misses[shape] == nil else { return }
        misses[shape] = since
        save(misses)
        Diagnostics.record(.shape, ["shape": shape.rawValue, "state": "missing"])
    }

    /// `shape` was seen whole: the miss, if any, clears.
    static func seen(_ shape: ClaudeShape) {
        var misses = load()
        guard misses.removeValue(forKey: shape) != nil else { return }
        save(misses)
        Diagnostics.record(.shape, ["shape": shape.rawValue, "state": "seen"])
    }

    /// The Named miss clears once the log has a Named line from the miss's start on.
    static func clearNamed(seenIn events: ClaudeEvents) {
        guard let since = load()[.namedLine] else { return }
        if events.events.contains(where: { e in if case .named = e.event { return e.at >= since } else { return false } }) {
            seen(.namedLine)
        }
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
    private var failedTargets = PairFile<Date>(name: "failed-targets.json").load()
    /// The first tick finishes or undoes a switch the app was stopped in.
    private var recovered = false
    /// When each seat's meters were last asked for, and when the service lets it be asked again.
    private var askedAt: [Identity: Date] = [:]
    private var retryAt: [Identity: Date] = [:]
    private var forced: Set<Identity> = []
    /// The hold whose login was saved, so each settled hold is saved once.
    private var savedHold: Hold?
    /// When each seat was last read with room: turns that ended after it ended as the seat ran out.
    private var roomReadAt: [Identity: Date] = [:]
    /// Chats already resumed in place, so a wait resumes each stopped chat once.
    private var resumed: Set<String> = []
    private var switchingTo: SwitchFacts?
    private var failure: String?
    private var success: (text: String, until: Date)?
    private var ticking = false
    private var timer: Timer?
    /// The switch holding the lock, from its start until it confirms or ends. Its resume runs
    /// after, on `resumeTask`, so a second switch can overtake it (model, section 6, step 7).
    private(set) var switchTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    /// Counts switches, so an older one's end never clears a newer one's task.
    private var runs = 0
    private var noteUntil: Date?
    /// When the Mac last woke. Readings taken before it count as stale, and no automatic decision
    /// runs until every seat has been read since (model, section 7, sleep then wake).
    private var wokeAt: Date?
    /// The wait that was already posted, by the time its out signal began, so each wait is
    /// posted once.
    private var waitPosted = false
    /// When the running switch started, to tell whether it met a missing shape.
    private var startedAt: Date?
    /// What the diagnostics file last recorded, so each publish logs only what changed.
    private var logged: Diagnostics.Snapshot?

    init() {
        SavedLogins.adopt(accounts)
        publish()
    }

    /// Start the app's own ticking. Tests never call this: they call `tick()` themselves.
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.woke() }
        }
        Task { await tick() }
    }

    /// The Mac woke from sleep: every reading is stale from now, each seat is read again, and the
    /// automatic decision waits for those reads. Tests call this in place of the notification.
    func woke() {
        let now = World.now()
        wokeAt = now
        Diagnostics.record(.woke)
        for seat in meters.keys { meters[seat]?.wokeSince = now }
        for row in accounts { if let seat = row.identity { forced.insert(seat); retryAt[seat] = nil } }
        PairFile<SeatMeters>(name: "meters.json").save(meters)
        Task { await tick() }
    }

    /// Every seat has been read, or asked and refused, since the Mac woke.
    private var readSinceWake: Bool {
        guard let wokeAt else { return true }
        return accounts.compactMap(\.identity).allSatisfy { (askedAt[$0] ?? .distantPast) >= wokeAt }
    }

    // MARK: The facts

    /// Everything the model reads, as of `now` (model, section 2).
    func facts(now: Date = World.now()) -> Facts {
        var f = Facts()
        f.rows = accounts.inMenuOrder
        let installed = World.claude.installed
        f.claude = ClaudeFacts(installed: installed, running: running, missing: installed ? Set(ShapeMisses.load().keys) : [])
        f.log = log.events
        f.saved = Dictionary(accounts.compactMap { r in r.identity.flatMap { s in SavedLogins.savedAt(s).map { (s, $0) } } }, uniquingKeysWith: max)
        f.meters = meters
        f.stops = stops
        f.failedTargets = failedTargets
        f.switching = switchingTo ?? SwitchJournal.load().map { SwitchFacts(target: $0.to, step: $0.parked ? "Open Claude to finish." : "Finishing…") }
        f.trusted = trusted
        f.autoChosen = settings.autoSwitch
        f.order = settings.switchOrder
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
        if let until = noteUntil, until <= now { noteUntil = nil; switchingTo?.note = nil }
        seats = Seats.build(f, now: now)
        let snap = Diagnostics.snapshot(f, seats: seats, decision: AutoSwitch.decide(f, now: now), now: now)
        for (kind, fields) in Diagnostics.changes(from: logged, to: snap) { Diagnostics.record(kind, fields) }
        logged = snap
        let parked = SwitchJournal.load().flatMap { $0.parked && switchTask == nil ? names[$0.to] ?? "a seat" : nil }
        notice = AppState.notice(f, now: now, failure: failure, success: success?.text, finishing: parked)
    }

    var firstRun: Bool { accounts.isEmpty }

    /// The menu bar's gauge: the seat in use's meter for the chosen limit, or its weekly meter
    /// when it has no 5-hour one. The display and limit settings stay working until Rohan rules on
    /// them (model, section 10).
    var titleMeter: MeterReading? {
        guard let m = seats.first(where: { $0.state == .inUse })?.meters else { return nil }
        return settings.metric == .fiveHour ? m.fiveHour ?? m.weekly : m.weekly
    }

    /// The text beside the gauge, by the display setting.
    var menuBarTitle: String {
        guard let meter = titleMeter, settings.display != .gauge, let seat = seats.first(where: { $0.state == .inUse }) else { return "" }
        let percent = "\(Int(meter.percent.rounded()))%"
        return settings.display == .gaugePercent ? percent : "\(seat.name) \(percent)"
    }

    // MARK: Tick

    /// Do everything due at the clock's now: read the new log lines and Claude's process, record
    /// new usage stops, save a newly settled hold's login, read the meters that are due, then run
    /// the automatic decision. An automatic switch it starts is awaited.
    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        observe()
        // A missing cookie schema is looked at again each tick, so the format seen whole clears it.
        if ShapeMisses.load()[.cookieSchema] != nil, switchTask == nil { try? await LoginSlot.checkCookieSchema(ClaudeApp.cookies) }
        // At launch, and whenever Claude opens again while a switch is parked (section 6, Recovery).
        if !recovered || (running && SwitchJournal.load()?.parked == true) {
            recovered = true
            recover()
        }
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
        ShapeMisses.clearNamed(seenIn: log.events)
        recordStops()
    }

    /// Each settled usage stop becomes the seat's stop mark, with the reset of the reading taken
    /// at the stop (model, section 4). A meter read follows the stop and completes the mark.
    private func recordStops() {
        let new = Self.newStops(log.events, stops: stops, meters: meters)
        guard !new.isEmpty else { return }
        stops.merge(new) { _, b in b }
        forced.formUnion(new.keys)
        PairFile<StopMark>(name: "stops.json").save(stops)
    }

    /// The settled usage stops in `events` later than each seat's stop mark, as new marks.
    nonisolated static func newStops(_ events: ClaudeEvents, stops: [Identity: StopMark], meters: [Identity: SeatMeters]) -> [Identity: StopMark] {
        var new: [Identity: StopMark] = [:]
        for e in events.events where e.settled {
            guard case .limitStop = e.event, let seat = e.held, e.at > (new[seat]?.at ?? stops[seat]?.at ?? .distantPast) else { continue }
            new[seat] = StopMark(at: e.at, resetsAt: meters[seat]?.fullUntil(at: e.at) ?? meters[seat]?.fuller?.resetsAt)
        }
        return new
    }

    /// Save the login of a hold once it settles while Claude runs, so the seat Claude is on gets
    /// one without a switch (13a.2). With no rows yet, the held seat becomes the first row (13a.6).
    private func saveSettledHold() async {
        let now = World.now()
        guard running, switchingTo == nil, let hold = log.events.hold, hold.settled(at: now), savedHold != hold else { return }
        if accounts.isEmpty { addSeat(hold.seat) }
        guard accounts.contains(where: { $0.identity == hold.seat }),
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
            if let ended = log.events.lastTurnEnd(on: seat), !ClaudeEvents.readAfter(ended, readAt: readAt),
               since >= Limits.meterOnTurnEnd { return true }
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
            if let last = meters[seat], !last.showsFull, let at = last.readAt { roomReadAt[seat] = at }
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
        guard readSinceWake else { return }
        wokeAt = nil
        let now = World.now()
        let f = facts(now: now)
        let decision = AutoSwitch.decide(f, now: now)
        if case .wait = decision {} else { waitPosted = false }
        switch decision {
        case .none:
            break
        case .wait(let seat, let at):
            postWait(f, seat: seat, resumesAt: at)
        case .resumeInPlace:
            guard let seat = f.hold?.seat else { return }
            resumeInPlace(waitingChats(f), on: seat, now: now)
        case .switchTo(let target):
            // The switch runs on its own task; a failed target sends the decision round again.
            guard switchTask == nil, let seat = f.hold?.seat else { return }
            // With no reading with room on record, only the turn that set off the last read counts.
            let since = roomReadAt[seat] ?? log.events.lastTurnEnd(on: seat) ?? now
            // Which of Claude's two signals set it off (model, section 4), for the diagnostics file.
            let trigger = (stops[seat].map { $0.until > now } ?? false) ? "limitStop" : "wrapUp"
            run(to: target, kind: .auto, resume: log.events.turnsEnded(on: seat, since: since), trigger: trigger)
        }
    }

    /// Post a wait once (model, section 7): when chats wait and more than one seat could have
    /// taken them. The wait lasts while the decision stays a wait, so a second stop inside it
    /// posts nothing. A single seat that runs out stays quiet (13a.8).
    private func postWait(_ f: Facts, seat: Identity?, resumesAt: Date?) {
        guard f.waitingChats > 0, f.rows.compactMap(\.identity).count > 1, !waitPosted else { return }
        waitPosted = true
        let when = resumesAt.map { " at \(ClockText.time($0))" } ?? ""
        let name = seat.flatMap { names[$0] } ?? "a seat"
        World.claude.notify(title: "Every seat is out", body: "Every seat is out. Chats resume when \(name) resets\(when).")
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

    /// Set the order the automatic switch tries seats in, and decide again with it.
    func setSwitchOrder(_ order: SwitchOrder) {
        settings.switchOrder = order
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

    /// A Set Up of a row whose organization was unknown confirmed: the row takes the organization
    /// of the pair Claude holds (13a.4), unless that pair is already a row of its own.
    private func learnOrganization(of target: Identity) {
        guard let held = log.events.hold?.seat, target.matches(held), !accounts.contains(where: { $0.identity == held }),
              let i = accounts.firstIndex(where: { $0.seat == target }) else { return }
        var all = accounts
        all[i].orgUuid = held.org
        save(all)
    }

    private func record(for seat: Seat) -> AccountRecord? { accounts.first { $0.seat == seat.id } }

    /// The row the sign-in window signs in again.
    var signInRecord: AccountRecord? { signInTarget.flatMap(record(for:)) }

    /// Rename a seat, or its organization; an empty name puts the default back.
    func rename(_ seat: Seat, to name: String, organization: Bool) {
        guard let row = record(for: seat) else { return }
        save(AccountStore.load().renamed(row, to: name, organization: organization))
    }

    /// Give a seat's account a new colour, on every one of its rows; each row keeps its place.
    /// Kept working until Rohan rules on per-account colours (model, section 10).
    func recolor(_ seat: Seat, _ color: String) {
        guard let row = record(for: seat) else { return }
        var all = AccountStore.load()
        for i in all.indices where all[i].id == row.id || (row.accountUuid != nil && all[i].accountUuid == row.accountUuid) {
            all[i].color = color
        }
        save(all)
    }

    /// Show or fold away the organizations of an account in the menu; settings.json keeps it.
    /// Kept working until Rohan rules on folding (model, section 10).
    func setShowsOrganizations(of account: String, _ shown: Bool) {
        settings.setShowsOrganizations(of: account, shown)
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

    /// Drop the row and delete its saved login at once, then sign its Claude Code login out and
    /// delete it. Its chats stay in Claude's folder for that pair.
    func remove(_ seat: Seat) {
        guard let row = record(for: seat) else { return }
        SavedLogins.remove(seat.id)
        meters[seat.id] = nil
        PairFile<SeatMeters>(name: "meters.json").save(meters)
        save(AccountStore.load().filter { $0.id != row.id })
        Task {
            _ = await ClaudeCLI.run(configDir: row.configURL, ["auth", "logout"])
            if await Keychain.credential(service: row.keychainService) != nil { await Keychain.delete(service: row.keychainService) }
            try? FileManager.default.removeItem(at: row.configURL)
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

    /// Switch Claude to a seat. A manual switch never checks room: it is the person's call.
    func switchTo(_ seat: Seat) { run(to: seat.id, kind: .manual) }

    /// Switch Claude to a seat with no saved login, at its sign-in page.
    func setUp(_ seat: Seat) { run(to: seat.id, kind: .setUp) }

    /// Wait for the switch in progress, and the resume after it, to end.
    func finishSwitch() async {
        await switchTask?.value
        await resumeTask?.value
    }

    /// Each seat's row label, for the switch's lines.
    private var names: [Identity: String] { Dictionary(seats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    /// Run one switch; a second request while one runs is refused with a notice.
    @discardableResult
    private func run(to target: Identity, kind: SwitchJournal.Kind, resume: Set<String> = [], trigger: String? = nil) -> Task<Void, Never> {
        if let busy = switchTask {
            let to = switchingTo?.target ?? SwitchJournal.load()?.to
            let line = "Already switching to \(to.flatMap { names[$0] } ?? "a seat")."
            if switchingTo != nil {
                switchingTo?.note = line
                noteUntil = World.now() + Self.successFor
            } else {
                failure = line
            }
            publish()
            return busy
        }
        let from = log.events.hold?.seat
        let rows = accounts.map(\.seat)
        Diagnostics.record(.switchStarted, ["type": kind.rawValue, "from": from.map { rows.firstIndex(of: $0) ?? -1 } ?? NSNull(),
                                            "to": rows.firstIndex(of: target) ?? -1, "trigger": trigger ?? NSNull()])
        let request = Switch.Request(kind: kind, to: target, names: names, resume: resume)
        return start(target) { progress, switched in await Switch.run(request, progress: progress, switched: switched) } then: { outcome in
            if kind == .auto { self.autoFinished(outcome, from: from, to: target) }
        }
    }

    /// Finish or undo a switch the app was stopped in, or one parked until Claude opened again.
    private func recover() {
        guard switchTask == nil, let journal = SwitchJournal.load() else { return }
        let names = self.names
        start(journal.to) { progress, switched in
            await Switch.recover(names: names, progress: progress, switched: switched)
                ?? SwitchOutcome(ok: false, text: "", parked: true)
        } then: { _ in }
    }

    /// Run `body` as the switch in progress: its steps show on the target's row, and its outcome
    /// becomes the notice as soon as the switch ends, before the chats resume. From then on a new
    /// switch may start; this one's resume goes on until that switch overtakes it.
    @discardableResult
    private func start(_ target: Identity,
                       _ body: @escaping (@escaping Switch.Progress, @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome,
                       then: @escaping (SwitchOutcome) -> Void) -> Task<Void, Never> {
        failure = nil
        success = nil
        startedAt = World.now()
        runs += 1
        let run = runs
        switchingTo = SwitchFacts(target: target, step: "Starting…")
        publish()
        let progress: Switch.Progress = { step in
            Task { @MainActor in
                guard self.runs == run, self.switchingTo?.target == target else { return }
                self.switchingTo?.step = step
                self.publish()
            }
        }
        let ended = Flag()
        let switched: (SwitchOutcome) async -> Void = { outcome in
            await MainActor.run {
                ended.set = true
                self.switched(outcome, run: run)
            }
        }
        let task = Task {
            let outcome = await body(progress, switched)
            // A switch that ended before confirm (cancelled, refused, failed) reports here.
            if !ended.set { self.switched(outcome, run: run) }
            if outcome.toResume > 0 { self.resumeEnded(outcome) }
            then(outcome)
            if self.runs == run { self.resumeTask = nil }
            self.publish()
        }
        switchTask = task
        return task
    }

    /// Set once a switch has reported how it ended.
    private final class Flag: @unchecked Sendable { var set = false }

    /// The switch itself ended: its line goes in the notice.
    private func switched(_ outcome: SwitchOutcome, run: Int) {
        guard runs == run else { return }
        let target = switchingTo?.target
        resumeTask = switchTask
        switchTask = nil
        switchingTo = nil
        noteUntil = nil
        observe()
        if outcome.ok, !outcome.parked, let target, target.orgUnknown { learnOrganization(of: target) }
        Diagnostics.record(.switchEnded, ["state": Diagnostics.outcomeName(outcome),
                                          "to": target.flatMap { t in accounts.firstIndex { $0.seat == t } } ?? -1])
        if outcome.parked {
            failure = nil
        } else if outcome.ok {
            if !outcome.text.isEmpty { success = (outcome.text, World.now() + Self.successFor) }
        } else if !outcome.text.isEmpty, !(ShapeMisses.lastMet.map { $0 >= startedAt ?? .distantFuture } ?? false) {
            // A switch that met a missing shape failed because of it: the paused line says why.
            failure = outcome.detail.map { "\(outcome.text) \($0)" } ?? outcome.text
        }
        publish()
    }

    /// The chats a switch brought over were resumed: name any that still need a message.
    private func resumeEnded(_ outcome: SwitchOutcome) {
        guard !outcome.superseded, !outcome.notResumed.isEmpty else { return }
        let n = outcome.notResumed.count
        failure = "Couldn't resume \(n) chat\(n == 1 ? "" : "s"): send \(n == 1 ? "it" : "them") a message."
    }

    /// An automatic switch ended: a failed target is skipped for coolDown and the decision runs
    /// again at once; the outcome is posted, since nobody may be looking.
    private func autoFinished(_ outcome: SwitchOutcome, from: Identity?, to: Identity) {
        let name = { (s: Identity?) in s.flatMap { self.names[$0] } ?? "The seat in use" }
        if outcome.ok {
            World.claude.notify(title: "Switched to \(name(to))", body: "Switched to \(name(to)): \(name(from)) is out. \(outcome.resumed) chat\(outcome.resumed == 1 ? "" : "s") resumed.")
            return
        }
        guard !outcome.parked else { return }
        failedTargets[to] = World.now()
        PairFile<Date>(name: "failed-targets.json").save(failedTargets)
        World.claude.notify(title: "Didn't switch to \(name(to))", body: failure ?? outcome.text)
        Task { await self.tick() }
    }
}

// MARK: - Diagnostics

/// The local diagnostics file the release soak is counted from (model, section 14). Each line is
/// one event: its kind, the clock's time, state names and row indexes (0-based, in menu order;
/// -1 for a pair that is not a row). It never holds names, emails, ids or tokens, and it never
/// leaves the Mac. Only the values typed here can be written, so nothing else can slip in.
enum Diagnostics {
    enum Kind: String { case claude, hold, seat, decision, switchStarted, switchEnded, woke, shape }

    /// What the app showed at one publish: the parts whose changes are logged.
    struct Snapshot: Equatable {
        var claude = "notRunning"
        var hold: Int?
        var seats: [String] = []
        var decision = "none"
    }

    /// Past this size the file moves to diagnostics.1.jsonl, so it holds at least the last few
    /// weeks of a heavy user's events and never grows without bound.
    static let rotateAt = 4 * 1024 * 1024
    static var url: URL { Paths.stateDir.appendingPathComponent("diagnostics.jsonl") }

    /// The lines that take `before` to `after`.
    static func changes(from before: Snapshot?, to after: Snapshot) -> [(Kind, [String: Any])] {
        var out: [(Kind, [String: Any])] = []
        if before?.claude != after.claude { out.append((.claude, ["state": after.claude])) }
        if before.map({ $0.hold != after.hold }) ?? (after.hold != nil) { out.append((.hold, ["row": after.hold ?? NSNull()])) }
        for (i, state) in after.seats.enumerated() where before.map({ i >= $0.seats.count || $0.seats[i] != state }) ?? true {
            out.append((.seat, ["row": i, "state": state]))
        }
        if before?.decision != after.decision { out.append((.decision, ["state": after.decision])) }
        return out
    }

    static func snapshot(_ f: Facts, seats: [Seat], decision: AutoSwitch.Decision, now: Date) -> Snapshot {
        let rows = f.rows.map(\.seat)
        var snap = Snapshot()
        snap.claude = !f.claude.installed ? "notInstalled" : !f.claude.running ? "notRunning"
            : f.hold.map { $0.settled(at: now) ? "settled" : "settling" } ?? "holdingNothing"
        snap.hold = f.hold.map { h in rows.firstIndex(of: h.seat) ?? -1 }
        snap.seats = seats.map { stateName($0.state) }
        switch decision {
        case .none: snap.decision = "none"
        case .switchTo: snap.decision = "switch"
        case .wait: snap.decision = "wait"
        case .resumeInPlace: snap.decision = "resumeInPlace"
        }
        return snap
    }

    static func stateName(_ s: SeatState) -> String {
        switch s {
        case .switching: return "switching"
        case .inUse: return "inUse"
        case .needsSignIn: return "needsSignIn"
        case .out: return "out"
        case .ready: return "ready"
        }
    }

    /// The outcome of a switch as one state name.
    static func outcomeName(_ o: SwitchOutcome) -> String {
        o.parked ? "parked" : o.ok ? "done" : "undone"
    }

    /// Append one line. A failed write is dropped: diagnostics never stop the app.
    static func record(_ kind: Kind, _ fields: [String: Any] = [:]) {
        var line = fields
        line["kind"] = kind.rawValue
        line["at"] = ISO8601DateFormatter().string(from: World.now())
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotateAt {
            let old = Paths.stateDir.appendingPathComponent("diagnostics.1.jsonl")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
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
    /// row keeps its place and name. Without it, add a new account; it gets its label once
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
            phase = .done(accounts.last?.label ?? record.name, next: nil)
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

/// The command line switches nothing: switching has one way in, the menu, so one place decides
/// it. `--status` prints what the app reads and changes nothing. `--test-resume <session id or
/// title>` sends "resume" to that one open chat of the seat Claude holds, by the steps a switch
/// takes after it reopens Claude, once, and prints each step; it takes the switch lock.
enum Entry {
    static func main() {
        Migration.moveLegacyState()
        let args = CommandLine.arguments
        if args.contains("--status") { printStatus() }
        if let i = args.firstIndex(of: "--test-resume"), i + 1 < args.count { TestResume.run(args[i + 1]) }
        ClaudeAccountsApp.main()
    }

    /// `--status`: the state of every row and the automatic decision, read from the same facts
    /// the menu reads, by the same functions (model, section 3). It writes nothing, and it names
    /// nothing beyond the row labels.
    private static func printStatus() -> Never {
        print(StatusReport.text(StatusReport.facts(), now: World.now()), terminator: "")
        exit(0)
    }
}

/// The text `--status` prints.
enum StatusReport {
    /// The facts as the menu would read them now, from disk and Claude's log, read-only.
    static func facts() -> Facts {
        var log = LogReader()
        log.poll()
        let meters = PairFile<SeatMeters>(name: "meters.json").load()
        let stops = PairFile<StopMark>(name: "stops.json").load()
        let installed = World.claude.installed
        var f = Facts()
        f.rows = AccountStore.load().inMenuOrder
        f.claude = ClaudeFacts(installed: installed, running: !ClaudeApp.pids().isEmpty,
                               missing: installed ? Set(ShapeMisses.load().keys) : [])
        f.log = log.events
        f.saved = Dictionary(f.rows.compactMap { r in r.identity.flatMap { s in SavedLogins.savedAt(s).map { (s, $0) } } }, uniquingKeysWith: max)
        f.meters = meters
        f.stops = stops.merging(Store.newStops(log.events, stops: stops, meters: meters)) { _, b in b }
        f.failedTargets = PairFile<Date>(name: "failed-targets.json").load()
        f.switching = SwitchJournal.load().map { SwitchFacts(target: $0.to, step: $0.parked ? "parked until Claude opens" : "in progress") }
        f.trusted = World.claude.trusted
        let settings = AppSettings.load()
        f.autoChosen = settings.autoSwitch
        f.order = settings.switchOrder
        f.waitingChats = f.hold == nil ? 0 : log.events.stoppedChats.byLimit.count
        return f
    }

    static func text(_ f: Facts, now: Date) -> String {
        let seats = Seats.build(f, now: now)
        let label = { (s: Identity?) in s.flatMap { s in seats.first { $0.id == s }?.name } ?? "a pair not in the list" }
        var out = ""
        let claude: String
        if !f.claude.installed { claude = "not installed" }
        else if !f.claude.running { claude = "not running" }
        else if let hold = f.hold { claude = "on \(label(hold.seat)), \(hold.settled(at: now) ? "settled" : "settling")" }
        else { claude = "running, on no seat yet" }
        out += "Claude: \(claude)\n"
        let auto: String
        switch AutoSwitch.status(f) {
        case .on: auto = "on"
        case .offAccessibility: auto = "off, Accessibility is not granted to this process"
        case .offShapeMissing(let shape): auto = "off, because \(shape.why)"
        case .offByPerson: auto = "off, turned off in the menu"
        }
        out += "Automatic switching: \(auto)\n"
        out += "Accessibility: \(f.trusted ? "granted" : "not granted")\n"
        for (i, seat) in seats.enumerated() {
            var line = "\(i + 1). \(seat.name): \(Diagnostics.stateName(seat.state))"
            if case .out(let until?) = seat.state { line += " until \(ClockText.time(until))" }
            if case .switching(let step) = seat.state { line += " (\(step))" }
            if let read = seat.meters.readText(at: now) { line += ", meters \(read)" }
            out += line + "\n"
        }
        let decision: String
        switch AutoSwitch.decide(f, now: now) {
        case .none: decision = "nothing to do"
        case .switchTo(let t): decision = "switch to \(label(t))"
        case .resumeInPlace: decision = "resume the stopped chats in place"
        case .wait(let s, let at): decision = "wait" + (s.map { " for \(label($0))" } ?? "") + (at.map { " to reset at \(ClockText.time($0))" } ?? "")
        }
        out += "Decision: \(decision)\n"
        return out
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
            Image(nsImage: menuBarImage(title: store.menuBarTitle,
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
        guard let identity = ClaudeApp.events().hold?.seat else { say("Claude's log doesn't name the account it has open."); exit(1) }
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
