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
}

// MARK: - Process helpers

enum ClaudeCLI {
    /// The CLI isn't on a menu bar app's PATH, so look in the usual install locations. A test
    /// world looks only under its own home, so no test can find the Mac's real CLI.
    static var path: String? {
        let own = Paths.home.appendingPathComponent(".local/bin/claude").path
        let candidates = World.isTest ? [own] : [own, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
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

/// One read of a seat's usage.
enum AccountState: Equatable {
    case ok(fiveHour: UsageWindow?, weekly: UsageWindow?)
    /// The usage service asked us to wait.
    case rateLimited(until: Date)
    /// No login, a refused login, or a failed request: the last reading stays and goes stale.
    case unreadable
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
            return .unreadable
        }
        guard let cred = await freshCredential(acct) else {
            return .unreadable
        }
        var req = URLRequest(url: API.usage, timeoutInterval: 15)
        req.setValue("Bearer " + cred.accessToken, forHTTPHeaderField: "Authorization")
        req.setValue(API.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                let wait = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 300
                return .rateLimited(until: World.now().addingTimeInterval(wait))
            }
            guard code == 200, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
            return .ok(fiveHour: UsageWindow(body["five_hour"]), weekly: UsageWindow(body["seven_day"]))
        } catch {
            return .unreadable
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

    /// How one quit request ended, and whether Quit anyway was pressed. `promptLeftOpen`: the
    /// switch gave up while a window Claude opened was still up and could not be cancelled.
    /// `promptWithoutButton`: Accessibility showed Claude's prompt without a Quit anyway button.
    struct QuitResult {
        var outcome: QuitWatch.Outcome
        var answered = false
        var promptLeftOpen = false
        var promptWithoutButton = false
    }

    /// Quit the way ⌘Q does, then wait until the process is gone, so Claude has flushed its
    /// cookies and settings. With a chat mid-reply Claude first asks, in a native alert: Quit
    /// anyway, Wait for Claude or Cancel. `QuitWatch` decides from the process and its windows.
    ///
    /// `unattended` answers the prompt with Quit anyway through Accessibility, the answer a person
    /// switching by hand gives; Claude then marks each cut-off chat to resume at its next launch.
    /// Accessibility is asked again at every look for as long as the prompt can be up: a slow
    /// answer, or a prompt Accessibility doesn't list yet, is looked for again, never taken as a
    /// prompt without the button. Each look that differs, or that took a second or more, goes in
    /// the diagnostics file.
    /// `notify`, for an automatic switch, is the title of the one notification posted once the app
    /// has not been able to press Claude's prompt for `QuitWatch.askAfter`.
    static func quit(unattended: Bool = false, notify: String? = nil, progress: @Sendable (String) -> Void = { _ in }) async -> QuitResult {
        let running = pids()
        guard !running.isEmpty else { return QuitResult(outcome: .quit) }
        let windowsBefore = windowIDs(running)
        for pid in running { await World.claude.requestQuit(pid) }
        var watch = QuitWatch(unattended: unattended, canAnswer: World.claude.trusted, started: World.now())
        var result = QuitResult(outcome: .failed)
        var shown: String?
        var buttonSeen = false
        var looks = 0
        var logged: (QuitSurvey, Int)?
        var unpressedSince: Date?, asking = notify
        while true {
            await World.sleep(0.5)
            let alive = !pids().isEmpty
            let began = Date()
            let survey = alive ? World.claude.quitPromptSurvey(in: running) : QuitSurvey()
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let newWindows = alive ? windowIDs(running).subtracting(windowsBefore).count : 0
            looks += 1
            if logged.map({ $0.0 != survey || $0.1 != newWindows }) ?? true || ms >= 1000 {
                logged = (survey, newWindows)
                Diagnostics.record(.quitLook, ["look": looks, "ms": ms, "running": alive, "newWindows": newWindows,
                                               "windows": survey.windows, "buttons": survey.prompts])
            }
            if survey.quitAnyway, !buttonSeen { buttonSeen = true; ShapeMisses.seen(.quitButton) }
            result.promptWithoutButton = result.promptWithoutButton || survey.promptWithoutQuitAnyway
            // A window Claude opened after the request counts as its prompt, found or not.
            switch watch.step(QuitObservation(claudeRunning: alive, promptOpen: survey.quitAnyway || newWindows > 0), now: World.now()) {
            case .done(let outcome):
                result.outcome = outcome
                result.answered = watch.answeredAt != nil
                if result.promptWithoutButton, !buttonSeen { ShapeMisses.missed(.quitButton) }
                return result
            case .wait(let what):
                if what != shown { shown = what; progress(what) }
            case .cancel:
                // Cancel is pressed only on a prompt found by its Quit anyway button; any other
                // window Claude opened is left to the person.
                if survey.quitAnyway { _ = World.claude.pressQuitPrompt(ClaudeUI.cancel, in: running) } else { result.promptLeftOpen = true }
                result.answered = watch.answeredAt != nil
                if result.promptWithoutButton, !buttonSeen { ShapeMisses.missed(.quitButton) }
                return result
            case .answer:
                if survey.quitAnyway, World.claude.pressQuitPrompt(ClaudeUI.quitAnyway, in: running) {
                    watch.answered(at: World.now())
                    shown = "Answered Claude's prompt with \(ClaudeUI.quitAnyway)…"
                    progress(shown!)
                } else {
                    let since = unpressedSince ?? World.now()
                    unpressedSince = since
                    if shown != QuitWatch.answerPrompt {
                        shown = QuitWatch.answerPrompt
                        progress(QuitWatch.answerPrompt)
                    }
                    if let title = asking, World.now().timeIntervalSince(since) >= QuitWatch.askAfter {
                        World.claude.notify(title: title, body: QuitWatch.answerPrompt)
                        asking = nil
                    }
                }
            }
        }
    }

    /// Press Cancel on Claude's quit prompt, found by its Quit anyway button: an automatic switch
    /// giving up. Any other window Claude opened is left to the person (section 8 B).
    static func cancelQuitPrompt(in owners: [pid_t]) {
        guard World.claude.quitPromptSurvey(in: owners).quitAnyway else { return }
        _ = World.claude.pressQuitPrompt(ClaudeUI.cancel, in: owners)
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
    struct LogMark: Equatable, Codable { let inode: UInt64; let offset: UInt64 }

    static func logMark(_ url: URL = log) -> LogMark {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LogMark(inode: (attrs?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                       offset: (attrs?[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Whole lines from `offset` on, and the place just past the last one read, in the file the
    /// handle read: a rename between finding the file and reading it can't pair one file's end with
    /// another's identity. A file that can't be opened gives nothing, at a place in no file.
    static func readLines(_ url: URL, from offset: UInt64) -> (text: String, end: LogMark) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", LogMark(inode: 0, offset: 0)) }
        defer { try? handle.close() }
        var info = stat()
        let inode = fstat(handle.fileDescriptor, &info) == 0 ? UInt64(info.st_ino) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ("", LogMark(inode: inode, offset: offset)) }
        let whole = data[data.startIndex...last]
        return (String(decoding: whole, as: UTF8.self), LogMark(inode: inode, offset: offset + UInt64(whole.count)))
    }

    /// Claude's log rotated `n` times: main1.log to main4.log.
    static func rotatedLog(_ n: Int) -> URL { logDir.appendingPathComponent(ClaudeFiles.rotatedLog(n)) }

    /// Claude's log files, newest first: main.log, then main1.log to main4.log.
    static var logFiles: [URL] { [log] + ClaudeFiles.rotations.map(rotatedLog) }

    /// Where Claude's current run began: its last "Starting app" line, in main.log or the newest
    /// rotation that has one; with none, the start of main.log.
    static func startMark() -> LogMark {
        for url in logFiles {
            guard let data = try? Data(contentsOf: url), let r = data.range(of: Data(ClaudeLog.appStart.utf8), options: .backwards) else { continue }
            let line = data[..<r.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
            return LogMark(inode: logMark(url).inode, offset: UInt64(line - data.startIndex))
        }
        return LogMark(inode: logMark().inode, offset: 0)
    }

    /// Claude's recent log read whole, oldest first: main.log, and while what is read names no seat
    /// and starts no run, older rotations back to the newest one that does, so a long run keeps its
    /// hold. With where main.log ended.
    static func recentLogs() -> (texts: [String], end: LogMark) {
        let main = readLines(log, from: 0)
        var texts = [main.text]
        for n in ClaudeFiles.rotations {
            if [ClaudeLog.identity, ClaudeLog.appStart].contains(where: texts[0].contains) { break }
            texts.insert(readLines(rotatedLog(n), from: 0).text, at: 0)
        }
        return (texts, main.end)
    }

    // MARK: Sessions

    static func folder(_ id: Identity) -> URL {
        sessions.appendingPathComponent(id.account).appendingPathComponent(id.org)
    }

    /// Records of the sessions shown in the sidebar: not archived, not a scheduled-task run. A
    /// folder that doesn't exist holds none. A folder or record that can't be read throws, so a
    /// switch never leaves behind a chat it could not see (model, section 8 B). A record that
    /// reads but isn't a session is not one Claude shows either.
    static func openSessionRecords(in orgFolder: URL) throws -> [URL] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: orgFolder, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return try files.filter { url in
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else { return false }
            let data = try Data(contentsOf: url)
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
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
        /// When the app saw Claude refuse this copy arrive, on its own clock: the seat needs a new
        /// sign-in until a newer copy replaces this one.
        var refusedAt: Date? = nil
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

    /// The seat has a saved login that the app has not seen Claude refuse since.
    static func usable(_ seat: Identity) -> Bool { proven(seat).map { $0.meta.refusedAt == nil } ?? false }

    /// The app saw Claude refuse `seat`'s sign-in arrive at `seen`: a copy saved before then is
    /// marked refused, so the seat reads Needs sign-in across relaunches until a newer copy.
    static func refused(_ seat: Identity, seen: Date) {
        guard var copy = proven(seat), copy.meta.refusedAt == nil, copy.meta.savedAt < seen else { return }
        copy.meta.refusedAt = seen
        try? JSONEncoder().encode(copy.meta).write(to: copy.folder.appendingPathComponent("login.json"), options: .atomic)
    }

    /// Save the login Claude holds as `seat`: with Claude quit, or while it runs once it has held
    /// the seat settled, with `log` reading its log as of then. Claude's settings must name the
    /// seat's account, and while Claude runs its cookie file must sit still through the copy and
    /// Claude must still hold the seat.
    static func save(_ seat: Identity, whileRunning log: Switch.LogNow? = nil) async throws {
        let whileRunning = log != nil
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
        if let log {
            guard await log().hold?.seat == seat, ClaudeApp.savedAccount() == seat.account else { throw SwitchError.inconsistent }
        }
        // The proven copy moves aside, never away, until the new one reads back.
        if check(current, seat) != nil {
            try? fm.removeItem(at: prev)
            try fm.moveItem(at: current, to: prev)
        } else {
            try? fm.removeItem(at: current)
        }
        await World.claude.willStep("save.rename")
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

    /// Bring each row's login from the old per-row slot into its pair's folder, once.
    /// The slot stays: a rollback to the previous build logs in from it, and load reads an old row's organization there.
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
    /// Claude didn't quit and its prompt was left open: the line holds only until Claude quits or reopens.
    var promptLeftOpen = false
    /// The switch stopped at its quit: the person cancelled it, or Claude didn't quit.
    var quitStopped = false
    /// The journal stays and waits on Claude: to open, to confirm the switch, or to close, to undo it.
    var parked = false
    /// The chats this switch set out to resume. One that did not confirm hands them back, so they
    /// travel on to the next try.
    var resume: Set<String> = []
    /// How the resume of the chats a confirmed switch brought over ended.
    var resumeEnd = ResumeEnd()
}

/// How one resume ended, after a switch or in place.
struct ResumeEnd: Equatable {
    var resumed = 0
    /// The chats still not running, by title: each needs a message from the person.
    var notResumed: [String] = []
    /// Another switch started and carries the chats not yet settled on.
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
    /// When the app launched Claude, on its own clock: the confirm's deadline and the resume's start.
    var launchedAt: Date? = nil
    /// Where Claude's log stood just before that launch: the confirm reads only what Claude logged
    /// after it, so no line from before the launch, whatever its printed time, can confirm it.
    var logMark: ClaudeApp.LogMark? = nil
    /// Claude was closed when the confirm wait ran out: confirm whenever it next opens.
    var parked = false
    /// An undo couldn't quit Claude: undo whenever Claude is next closed, the mirror of `parked`.
    var undoWhenClosed = false

    /// Recovery waits while Claude is not yet in the state this journal needs.
    func waiting(running: Bool) -> Bool { parked ? !running : undoWhenClosed && running }

    /// What the person does to let a waiting journal end, or nil when it needs nothing from them.
    func waitLine(_ target: String) -> String? {
        parked ? "Open Claude to finish switching to \(target)."
            : undoWhenClosed ? "Quit Claude to undo the switch to \(target)." : nil
    }

    static var url: URL { Paths.stateDir.appendingPathComponent("switch-journal.json") }
    static func load() -> SwitchJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SwitchJournal.self, from: data)
    }
    func save() async throws {
        await World.claude.willStep("journal")
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
    /// Claude's log as the app has read it, with the lines Claude appended since.
    typealias LogNow = @Sendable () async -> ClaudeEvents

    struct Request: Sendable {
        let kind: SwitchJournal.Kind
        let to: Identity
        /// Each seat's row label; a pair with no row reads "another account".
        let names: [Identity: String]
        /// The chats an automatic switch is for: those Claude stopped for the limit of the seat in
        /// use (AutoSwitch.stoppedNow). A switch by hand takes every chat its run stopped for a limit.
        var resume: Set<String> = []
        /// Claude held its seat settled (`ClaudeEvents.holdSettledForSaving`): that login is saved once Claude quits.
        var fromSettled = false
        /// Recovered from the journal: it never quits a running Claude and never types (nothing stored acts).
        var recovered = false
        func name(_ id: Identity?) -> String { id.flatMap { names[$0] } ?? "another account" }
    }

    /// The lock this process holds while a switch runs.
    nonisolated(unsafe) private static var held: SwitchLock?
    /// The chats the running resume has not settled yet, from its start. A switch that overtakes
    /// it takes them over and resumes them after its own confirm (section 6, step 7), whenever in
    /// the resume it starts.
    nonisolated(unsafe) private static var carried: Set<String> = []

    /// A test drops the switch it abandoned, as if the app had quit, so the next Store recovers.
    static func abandonForTest() {
        guard World.isTest else { return }
        held?.release()
        held = nil
        carried = []
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

    /// Run a switch to `r.to`, reading Claude's log through `log`. `switched` hears how the switch
    /// ended, before the chats resume.
    static func run(_ r: Request, log: @escaping LogNow, progress: @escaping Progress,
                    switched: @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome {
        guard lock() else { return SwitchOutcome(ok: false, text: "Another switch is running.") }
        if let open = SwitchJournal.load() {
            unlock()
            return SwitchOutcome(ok: false, text: open.waitLine(r.name(open.to)) ?? "Finishing the switch to \(r.name(open.to)) first.")
        }
        let running = !ClaudeApp.pids().isEmpty
        let events = await log()
        let hold = running ? events.hold : nil
        if r.kind != .setUp, hold?.seat == r.to {
            unlock()
            let o = SwitchOutcome(ok: true, text: "Already on \(r.name(r.to)).")
            await switched(o)
            return o
        }
        // Who Claude's files belong to: the seat it holds, or held when it last quit.
        var j = SwitchJournal(kind: r.kind, from: events.hold?.seat, to: r.to, step: .quit, fromSettled: hold != nil && r.fromSettled)
        do { try await j.save() } catch {
            unlock()
            return SwitchOutcome(ok: false, text: "Couldn't write the switch's journal, so nothing changed.")
        }
        await World.claude.willStep("quit")
        progress("Quitting Claude…")
        let quit = await ClaudeApp.quit(unattended: r.kind == .auto, notify: r.kind == .auto ? "Switching to \(r.name(r.to))" : nil,
                                        progress: progress)
        switch quit.outcome {
        case .quit: break
        case .declined:
            SwitchJournal.clear()
            unlock()
            return SwitchOutcome(ok: false, text: "Switch cancelled.", quitStopped: true, resume: r.resume)
        case .failed:
            SwitchJournal.clear()
            if ClaudeApp.pids().isEmpty { await ClaudeApp.launch() }
            unlock()
            let why = quit.promptWithoutButton ? "\(ClaudeShape.quitButton.why), so nothing changed." : "Claude didn't quit, so nothing changed."
            return SwitchOutcome(ok: false, text: why, detail: quit.promptLeftOpen ? "Its prompt is still open: Cancel keeps Claude as it is." : nil,
                                 promptLeftOpen: quit.promptLeftOpen, quitStopped: true, resume: r.resume)
        }
        // The run that just ended names the chats that were working: cut by the quit, and for a
        // switch by hand, stopped for usage. An automatic switch takes only the chats it is for.
        let ended = await log().stoppedChats
        let byLimit = r.kind == .auto ? [] : ended.byLimit
        j.resume = Array(byLimit.union(ended.byQuit).union(carried).union(r.resume)).sorted()
        carried = []
        let outcome = await forward(&j, r, progress: progress)
        return await finish(outcome, j, r, progress: progress, switched: switched)
    }

    /// Finish or undo a switch the app was stopped in, from its journal (section 6, Recovery).
    /// Nil when there is none, or another process holds the lock. A parked journal waits for
    /// Claude to be opened again, and an undo that couldn't quit Claude waits for it to close.
    /// Recovery only makes things consistent: it never quits a running Claude and types nothing.
    /// A running Claude settles it by what it holds now: the target confirms it, and anything else
    /// ends it as it stands. A closed Claude gets its files finished or put back, and is opened.
    static func recover(names: [Identity: String], progress: @escaping Progress,
                        switched: @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome? {
        guard var j = SwitchJournal.load() else { return nil }
        let r = Request(kind: j.kind, to: j.to, names: names, recovered: true)
        guard lock() else { return nil }
        if j.waiting(running: !ClaudeApp.pids().isEmpty), let line = j.waitLine(r.name(j.to)) {
            unlock()
            return SwitchOutcome(ok: false, text: line, parked: true)
        }
        if !ClaudeApp.pids().isEmpty, j.step >= .load { j.step = .confirm }
        let outcome: SwitchOutcome
        if j.step < .load || j.undoWhenClosed {
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
        outcome.resume = Set(j.resume)
        let generation = SwitchLock.generation()
        let folder = ClaudeApp.folder(j.to)
        let chats = outcome.ok && !outcome.parked && !r.recovered
            ? ResumeRule.toResume(((try? ClaudeApp.openSessionRecords(in: folder)) ?? []).compactMap(ChatResume.chat),
                                  stoppedByLimit: Set(j.resume), cutByQuit: [])
            : []
        unlock()
        await switched(outcome)
        outcome.resumeEnd = await resume(chats, in: folder, reopenedAt: j.launchedAt ?? World.now(), progress: progress, generation: generation)
        return outcome
    }

    /// The one resume step (section 6, step 7), after a switch and when a wait ends in place:
    /// `chats`, whose records are in `folder`, Claude having reopened at `reopenedAt`. When typing
    /// can't work, a Claude shape missing (8 B) or no Accessibility (7), nothing is opened, typed or
    /// pressed in Claude, and every chat is named instead (12). Otherwise each chat the resume gives
    /// up on is named. A switch that starts during it, a new `generation`, takes over the chats not
    /// yet settled and resumes them after its own confirm. A resume the app was stopped in is not
    /// taken up again: nothing stored types.
    static func resume(_ chats: [MovedChat], in folder: URL, reopenedAt: Date, progress: @escaping Progress,
                       generation: String = SwitchLock.generation()) async -> ResumeEnd {
        guard !chats.isEmpty else { return ResumeEnd() }
        guard ShapeMisses.load().isEmpty, World.claude.trusted else { return ResumeEnd(notResumed: chats.map(\.title)) }
        var resumer = ChatResume.resumer(in: folder, reopenedAt: reopenedAt.timeIntervalSince1970 * 1000, progress: progress)
        resumer.current = { SwitchLock.generation() == generation }
        let ids = Set(chats.map(\.id))
        carried.formUnion(ids)
        resumer.settled = { carried.remove($0) }
        let reports = await resumer.run(chats)
        // A resume no switch overtook leaves nothing to carry: what it gave up on is named instead.
        if resumer.current() { carried.subtract(ids) }
        let superseded = ResumeRule.Result.notResumed(ChatResumer.superseded)
        return ResumeEnd(resumed: reports.filter(\.result.runningAgain).count,
                         notResumed: reports.filter { !$0.result.runningAgain && $0.result != superseded }.map(\.chat.title),
                         superseded: reports.contains { $0.result == superseded })
    }

    /// Steps save to confirm, from wherever the journal stands.
    private static func forward(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        let recovering = j.step == .confirm
        do {
            if j.step < .save {
                guard await closed(&j, r, progress: progress) else { return await rolledBack(&j, r, "Claude was opened during the switch.", progress: progress) }
                await World.claude.willStep("backUp")
                j.backup = try backUp()
                try await step(&j, .save)
            }
            if j.step == .save {
                if j.fromSettled, let from = j.from {
                    await World.claude.willStep("save")
                    progress("Saving \(r.name(from))…")
                    try await SavedLogins.save(from)
                }
                try await step(&j, .move)
            }
            if j.step == .move {
                guard await closed(&j, r, progress: progress) else { return await rolledBack(&j, r, "Claude was opened during the switch.", progress: progress) }
                await World.claude.willStep("move")
                // A seat whose organization is not known yet has no chat folder until Claude names it.
                if let from = j.from, from != j.to, !j.to.orgUnknown { try await moveChats(from: from, to: j.to, journal: &j) }
                try await step(&j, .load)
            }
        } catch {
            var back = await rollback(&j, r, progress: progress)
            if back.ok { back = SwitchOutcome(ok: false, text: "Couldn't switch to \(r.name(j.to)).", detail: error.localizedDescription) }
            return back
        }
        do {
            if j.step == .load {
                guard await closed(&j, r, progress: progress) else { return await rolledBack(&j, r, "Claude was opened during the switch.", progress: progress) }
                await World.claude.willStep("load")
                progress(j.kind == .setUp ? "Opening Claude's sign-in…" : "Loading \(r.name(j.to))…")
                try await SavedLogins.load(j.kind == .setUp ? nil : j.to)
                try await step(&j, .launch)
            }
            if j.step == .launch {
                // A person who opened Claude since the load gets it quit once more (section 7).
                guard await closed(&j, r, progress: progress) else { return await rolledBack(&j, r, "Claude was opened during the switch.", progress: progress) }
                j.launchedAt = World.now()
                j.logMark = ClaudeApp.logMark()
                try await step(&j, .confirm)
                await World.claude.willStep("launch")
                await ClaudeApp.launch()
            }
        } catch {
            // Until Claude opens, its files can still be put back.
            var back = await rollback(&j, r, progress: progress)
            if back.ok { back = SwitchOutcome(ok: false, text: "Couldn't switch to \(r.name(j.to)).", detail: error.localizedDescription) }
            return back
        }
        // Recovering a confirm: the wait starts over from Claude's run, its own or one a person
        // opened while the switch was parked, read from where that run began. A Claude that is
        // closed is opened again.
        if recovering, j.parked || ClaudeApp.pids().isEmpty {
            j.parked = false
            j.launchedAt = World.now()
            if ClaudeApp.pids().isEmpty {
                j.logMark = ClaudeApp.logMark()
                await ClaudeApp.launch()
            } else {
                j.logMark = ClaudeApp.startMark()
            }
            try? await j.save()
        }
        return await confirm(&j, r, progress: progress)
    }

    private static func step(_ j: inout SwitchJournal, _ next: SwitchJournal.Step) async throws {
        j.step = next
        try await j.save()
    }

    /// Claude is closed before a write. A person who opens it between the quit and the launch gets
    /// it quit once more; the second time the switch is undone (section 7).
    private static func closed(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> Bool {
        guard !ClaudeApp.pids().isEmpty else { return true }
        j.reopened += 1
        try? await j.save()
        guard j.reopened < 2, !r.recovered else { return false }
        progress("Quitting Claude…")
        return await ClaudeApp.quit(unattended: r.kind == .auto, progress: progress).outcome == .quit
    }

    enum Verdict: Equatable { case confirmed, waiting, refused, other(Identity?) }

    /// What Claude logged since the launch (`events` holds only those lines): it holds the target
    /// settled, refused it, named another pair, or hasn't decided yet. A Set Up waits through a
    /// sign-out; a switch reads one as the target's login refused.
    static func verdict(_ events: ClaudeEvents, to: Identity, kind: SwitchJournal.Kind, running: Bool, now: Date) -> Verdict {
        for (i, e) in events.events.enumerated() {
            switch e.event {
            case .refused(let s) where to.matches(s): return .refused
            case .signedOut where kind != .setUp: return .refused
            case .named(let s) where !to.matches(s):
                // A fall-back after the target's refusal is the refusal, read on the next line.
                if events.events.dropFirst(i + 1).contains(where: { r in
                    if case .refused(let x) = r.event { return to.matches(x) } else { return false }
                }) { return .refused }
                return .other(s)
            default: continue
            }
        }
        if running, let hold = events.hold, to.matches(hold.seat), hold.settled(at: now) { return .confirmed }
        return .waiting
    }

    /// Wait for Claude to hold the target settled (section 6, step 6). Waits are measured against
    /// the facts: an expired wait reads the log once more, and while Claude is closed it parks.
    private static func confirm(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        await World.claude.willStep("confirm")
        let launch = j.launchedAt ?? World.now()
        let deadline = launch.addingTimeInterval(j.kind == .setUp ? Limits.setUpConfirmWait : Limits.confirmWait)
        progress(j.kind == .setUp ? "Sign in to \(r.name(j.to)) in Claude." : "Waiting for Claude to open as \(r.name(j.to))…")
        // Only what Claude logs after the launch counts, each line timed by when the app saw it.
        var log = LogReader(from: j.logMark ?? ClaudeApp.startMark())
        while true {
            let now = World.now()
            let running = !ClaudeApp.pids().isEmpty
            log.poll(now: now)
            let events = log.events
            let named = events.hold.map { j.to.matches($0.seat) } ?? false
            switch verdict(events, to: j.to, kind: j.kind, running: running, now: now) {
            case .confirmed:
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
                        try? await j.save()
                        return SwitchOutcome(ok: false, text: "Open Claude to finish switching to \(r.name(j.to)).", parked: true)
                    }
                    // Claude ran the whole wait and named nobody: its log lacks the line the app reads.
                    // A Set Up's wait is the person's to sign in, so a silent one says nothing.
                    if j.kind != .setUp, !events.events.contains(where: { e in
                        if case .named = e.event { return true } else { return false }
                    }) { ShapeMisses.missed(.namedLine, since: launch) }
                    return await rolledBack(&j, r, "\(r.name(j.to)) didn't open in time.", progress: progress)
                }
            }
            await World.sleep(1)
        }
    }

    private static func rolledBack(_ j: inout SwitchJournal, _ r: Request, _ why: String, progress: @escaping Progress) async -> SwitchOutcome {
        if r.recovered, !ClaudeApp.pids().isEmpty { return endAsItStands(j, why) }
        let back = await rollback(&j, r, progress: progress)
        guard back.ok else { return back }
        return SwitchOutcome(ok: false, text: why, detail: j.from.map { "Back on \(r.name($0))." })
    }

    /// A recovered switch with Claude running, and not on the target, ends where Claude stands: the
    /// chats go back to the seat they left, the journal goes, and nothing is quit.
    private static func endAsItStands(_ j: SwitchJournal, _ why: String) -> SwitchOutcome {
        moveBack(j)
        SwitchJournal.clear()
        return SwitchOutcome(ok: false, text: why)
    }

    private static func moveBack(_ j: SwitchJournal) {
        let fm = FileManager.default
        for m in j.moves.reversed() where fm.fileExists(atPath: m.to) && !fm.fileExists(atPath: m.from) {
            try? fm.moveItem(atPath: m.to, toPath: m.from)
        }
    }

    /// Undo: quit Claude, move the chats back, put back the files backed up after the quit, and
    /// reopen Claude. `ok` says the undo finished. A Claude that won't quit keeps the journal,
    /// marked to undo once Claude is closed, so nothing asks it to quit again meanwhile.
    private static func rollback(_ j: inout SwitchJournal, _ r: Request, progress: @escaping Progress) async -> SwitchOutcome {
        await World.claude.willStep("rollback")
        // Before load with no chat moved, Claude's files are as it left them: there is nothing to
        // put back, so Claude is not asked to quit again, only opened if it is closed. An automatic
        // switch stopped at its quit may have left Claude's prompt open with nobody to answer it.
        if j.step < .load, j.moves.isEmpty {
            SwitchJournal.clear()
            let running = ClaudeApp.pids()
            if running.isEmpty { await ClaudeApp.launch() } else if j.kind == .auto { ClaudeApp.cancelQuitPrompt(in: running) }
            return SwitchOutcome(ok: true, text: "Back on \(r.name(j.from)).")
        }
        if r.recovered, !ClaudeApp.pids().isEmpty { return endAsItStands(j, "Didn't finish the switch to \(r.name(j.to)).") }
        progress("Going back to \(r.name(j.from))…")
        if !ClaudeApp.pids().isEmpty {
            guard await ClaudeApp.quit(unattended: r.kind == .auto, progress: progress).outcome == .quit else {
                j.undoWhenClosed = true
                try? await j.save()
                return SwitchOutcome(ok: false, text: j.waitLine(r.name(j.to)) ?? "", parked: true)
            }
        }
        moveBack(j)
        let fm = FileManager.default
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
    private static func moveChats(from: Identity, to: Identity, journal j: inout SwitchJournal) async throws {
        let fm = FileManager.default
        let dst = ClaudeApp.folder(to)
        let quarantine = URL(fileURLWithPath: j.backup ?? Paths.stateDir.path).appendingPathComponent("quarantine")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        // Written before it is made: a rollback skips a move the record holds but the disk doesn't.
        func move(_ a: URL, _ b: URL) async throws {
            await World.claude.willStep("moveChat")
            guard ClaudeApp.pids().isEmpty else { throw SwitchError.quitFailed }
            j.moves.append(.init(from: a.path, to: b.path))
            try await j.save()
            try fm.moveItem(at: a, to: b)
        }
        for record in try ClaudeApp.openSessionRecords(in: ClaudeApp.folder(from)) {
            let dest = dst.appendingPathComponent(record.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let aside = quarantine.appendingPathComponent(record.lastPathComponent)
                if ClaudeApp.lastActivity(dest) > ClaudeApp.lastActivity(record) { try await move(record, aside); continue }
                try await move(dest, aside)
            }
            try await move(record, dest)
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

/// What the automatic switch keeps across launches of the app, in switch-memory.json: when the last
/// automatic switch began, so the spacing between them outlasts a relaunch. It only ever holds a
/// switch back. A missing, unreadable or foreign file reads as empty, and fields an earlier build
/// wrote there are ignored. Build 10 left an auto-switch.json of another shape, which this build
/// never reads.
struct SwitchMemory: Codable, Equatable {
    var lastAutoSwitch: Date?

    private enum CodingKeys: String, CodingKey { case lastAutoSwitch }

    init() {}

    init(from decoder: Decoder) throws {
        lastAutoSwitch = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Date.self, forKey: .lastAutoSwitch)
    }

    private static var url: URL { Paths.stateDir.appendingPathComponent("switch-memory.json") }

    /// The memory on disk. An automatic switch "later than now" is a clock set back: it reads as
    /// none, so the spacing can never hold for longer than it is.
    static func load(now: Date = World.now()) -> SwitchMemory {
        var m = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? SwitchMemory()
        if let last = m.lastAutoSwitch, last > now { m.lastAutoSwitch = nil }
        return m
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// The previous build's last readings, carried into this build's meters once, on the first launch
/// that has none of its own, so an upgrade shows every seat's meters as they were read, with their
/// age, instead of "Not read yet". The previous build's file stays, for a return to that build.
enum UsageCarry {
    /// One row's entry in the previous build's usage-cache.json, keyed there by row id.
    private struct Entry: Decodable {
        /// An older cache kept only the rounded `pct`.
        struct Window: Decodable {
            let utilization: Double?
            let pct: Int?
            let resetsAt: Date?
            var reading: MeterReading? { (utilization ?? pct.map(Double.init)).map { MeterReading(percent: $0, resetsAt: resetsAt) } }
        }
        let polledAt: Date
        let retryAt: Date?
        let fiveHour: Window?
        let weekly: Window?
        let readAt: Date?
    }

    static var url: URL { Paths.stateDir.appendingPathComponent("usage-cache.json") }

    /// The previous build's readings by seat, and its rate-limit waits still ahead; nil once this
    /// build has meters of its own or there is nothing to carry.
    static func readings(_ rows: [AccountRecord], now: Date) -> (meters: [Identity: SeatMeters], retryAt: [Identity: Date])? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Paths.stateDir.appendingPathComponent("meters.json").path),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return nil }
        var meters: [Identity: SeatMeters] = [:], waits: [Identity: Date] = [:]
        for row in rows {
            guard let seat = row.identity, let e = entries[row.id] else { continue }
            if let wait = e.retryAt, wait > now { waits[seat] = wait }
            let fiveHour = e.fiveHour?.reading, weekly = e.weekly?.reading
            guard fiveHour != nil || weekly != nil else { continue }
            meters[seat] = SeatMeters(fiveHour: fiveHour, weekly: weekly, readAt: e.readAt ?? e.polledAt)
        }
        return meters.isEmpty && waits.isEmpty ? nil : (meters, waits)
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

    /// `shape` was relied on and was not there. A Named line the app sees arrive from `since` on clears it.
    static func missed(_ shape: ClaudeShape, since: Date = World.now()) {
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

    /// The Named miss clears once the app sees a Named line arrive from the miss's start on.
    static func clearNamed(seenIn events: ClaudeEvents) {
        guard let since = load()[.namedLine] else { return }
        if events.events.contains(where: { e in if case .named = e.event { return e.seen.map { $0 >= since } ?? false } else { return false } }) {
            seen(.namedLine)
        }
    }
}

/// Claude's log read in order into `ClaudeEvents`. The first read, at the app's launch, takes
/// `ClaudeApp.recentLogs()` whole; every later read takes only the lines Claude appended since,
/// each timed by the app's clock as it arrives. A rotation is followed from the renamed file through
/// every newer one. A log that was truncated, or replaced past following, is read from its start as
/// new lines: they were all written after the last read, and the lines already read are kept, never
/// read again.
struct LogReader {
    private(set) var events = ClaudeEvents()
    private var mark: ClaudeApp.LogMark?

    /// A reader from `mark` on: every line after it reads as arriving. With none, the first read
    /// takes the log whole, as lines that were already there.
    init(from mark: ClaudeApp.LogMark? = nil) { self.mark = mark }

    mutating func poll(now: Date = World.now()) {
        guard let mark else {
            let recent = ClaudeApp.recentLogs()
            for text in recent.texts { events.read(text, readAt: now) }
            self.mark = recent.end
            return
        }
        let current = ClaudeApp.logMark()
        var from: UInt64 = 0
        if mark.inode == current.inode, mark.offset <= current.offset {
            from = mark.offset
        } else if mark.inode != 0, let n = ClaudeFiles.rotations.first(where: { ClaudeApp.logMark(ClaudeApp.rotatedLog($0)).inode == mark.inode }) {
            events.read(ClaudeApp.readLines(ClaudeApp.rotatedLog(n), from: mark.offset).text, readAt: now, arrived: true)
            for newer in stride(from: n - 1, through: 1, by: -1) {
                events.read(ClaudeApp.readLines(ClaudeApp.rotatedLog(newer), from: 0).text, readAt: now, arrived: true)
            }
        }
        let (text, end) = ClaudeApp.readLines(ClaudeApp.log, from: from)
        events.read(text, readAt: now, arrived: true)
        // A main.log that can't be opened this time is looked for again from the same place.
        if end.inode != 0 { self.mark = end }
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
    private var failedTargets = PairFile<Date>(name: "failed-targets.json").load()
    /// When each seat's meters were last asked for, and when the service lets it be asked again.
    private var askedAt: [Identity: Date] = [:]
    private var retryAt: [Identity: Date] = [:]
    private var forced: Set<Identity> = []
    /// The hold whose login was saved, so each settled hold is saved once.
    private var savedHold: Hold?
    /// The spacing between automatic switches, on disk so a relaunch of the app doesn't lift it.
    private var memory = SwitchMemory.load() {
        didSet { if memory != oldValue { memory.save() } }
    }
    /// The wait the app is in, and the hold in which an automatic switch failed with Claude still
    /// on it. In memory only: each names a hold, and nothing Claude logged before this launch
    /// counts anyway.
    private var wait: AutoSwitch.Wait?
    private var pausedHold: String?
    /// When this run of the app began: a run of readings never carries over from before it.
    private let launchedAt = World.now()
    private var switchingTo: SwitchFacts?
    private var failure: String? { didSet { failureDetail = nil; failureHold = nil } }
    /// The hold a failure that left Claude's prompt open was told in: that line goes once Claude quits or reopens.
    private var failureHold: String?
    /// The full sentence of `failure`, on hover, when its line is cut short.
    private var failureDetail: String?
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
    /// What the diagnostics file last recorded, so each publish logs only what changed.
    private var logged: Diagnostics.Snapshot?

    init() {
        SavedLogins.adopt(accounts)
        if let carried = UsageCarry.readings(accounts, now: World.now()) {
            meters = carried.meters
            retryAt = carried.retryAt
            PairFile<SeatMeters>(name: "meters.json").save(meters)
        }
        // A seat read moments ago is not asked again at once: the usage service answers a second
        // ask within a minute with a wait of several minutes, and the seat would read as not read.
        askedAt = meters.compactMapValues(\.readAt)
        publish()
        // An earlier build kept the resume it was stopped in here, to type at the next launch.
        // Stored state never types, so it goes unread.
        try? FileManager.default.removeItem(at: Paths.stateDir.appendingPathComponent("resuming"))
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
        f.saved = Set(accounts.compactMap(\.identity).filter(SavedLogins.usable))
        f.meters = meters
        f.failedTargets = failedTargets
        f.switching = switchingTo ?? SwitchJournal.load().map {
            SwitchFacts(target: $0.to, step: $0.parked ? "Open Claude to finish." : $0.undoWhenClosed ? "Quit Claude to undo." : "Finishing…")
        }
        f.trusted = trusted
        f.autoChosen = settings.autoSwitch
        f.order = settings.switchOrder
        f.lastAutoSwitch = memory.lastAutoSwitch
        f.wait = wait
        f.pausedHold = pausedHold
        return f
    }

    /// Rebuild the rows and the notice from the facts.
    private func publish(now: Date = World.now()) {
        let f = facts(now: now)
        if let s = success, s.until <= now { success = nil }
        if let until = noteUntil, until <= now { noteUntil = nil; switchingTo?.note = nil }
        seats = Seats.build(f, now: now)
        var kept = settings
        kept.keepMenuState(for: seats.map(\.id))
        if kept != settings { settings = kept }
        let snap = Diagnostics.snapshot(f, seats: seats, decision: AutoSwitch.decide(f, now: now), now: now)
        for (kind, fields) in Diagnostics.changes(from: logged, to: snap) { Diagnostics.record(kind, fields) }
        logged = snap
        let waitLine = switchTask == nil ? SwitchJournal.load().flatMap { $0.waitLine(names[$0.to] ?? "a seat") } : nil
        notice = AppState.notice(f, now: now, failure: failure, failureDetail: failureDetail, success: success?.text, finishing: waitLine)
    }

    var firstRun: Bool { accounts.isEmpty }

    /// The menu bar's gauge: the seat in use's meter for the chosen limit, or its weekly meter
    /// when it has no 5-hour one (model, section 10).
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

    /// Do everything due at the clock's now: read the new log lines and Claude's process, save a
    /// newly settled hold's login, read the meters that are due, then run
    /// the automatic decision. An automatic switch it starts is awaited.
    func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        observe()
        // A missing cookie schema is looked at again each tick, so the format seen whole clears it.
        if ShapeMisses.load()[.cookieSchema] != nil, switchTask == nil { try? await LoginSlot.checkCookieSchema(ClaudeApp.cookies) }
        // A journal no switch is running is finished (section 6, Recovery): the one the app was
        // stopped in, one a confirm couldn't clear, a parked one once Claude opens again, and an
        // undo that couldn't quit Claude once Claude is closed.
        if let journal = SwitchJournal.load(), !journal.waiting(running: running) { recover() }
        await saveSettledHold()
        await readDueMeters()
        publish()
        await decide()
        publish()
    }

    /// Claude's log with its new lines read, for a switch or a save off the main actor.
    private var logNow: Switch.LogNow { { await MainActor.run { self.observe(); return self.log.events } } }

    /// Read the facts that cost nothing: rows, Claude's process, its new log lines, Accessibility.
    private func observe() {
        accounts = AccountStore.load().labelled()
        running = !ClaudeApp.pids().isEmpty
        trusted = World.claude.trusted
        let read = log.events.events.count
        log.poll()
        if let h = failureHold, !running || log.events.hold?.key != h { failure = nil }
        ShapeMisses.clearNamed(seenIn: log.events)
        let rows = accounts.inMenuOrder.map(\.seat)
        for e in log.events.events.dropFirst(read) {
            switch e.event {
            case .refused(let seat): if let seen = e.seen { SavedLogins.refused(seat, seen: seen) }
            case .limitStop where e.seen != nil:
                Diagnostics.record(.stop, ["row": e.held.map { rows.firstIndex(of: $0) ?? -1 } ?? NSNull(), "settled": e.settled])
            default: break
            }
        }
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
            try await SavedLogins.save(hold.seat, whileRunning: logNow)
            savedHold = hold
        } catch SwitchError.cookiesChanging {
            // Tried again on the next tick.
        } catch {
            savedHold = hold
        }
    }

    // MARK: Meters

    /// The seats whose meters are due (model, section 5): never read, older than meterEvery, a
    /// reset passed since the reading, a settled usage stop or turn end since it (at most once per
    /// meterOnTurnEnd), or asked for. A rate-limit wait is always honoured.
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
            // Only a reading taken after the app saw the signal arrive is after it.
            if let seen = log.events.lastSignal(on: seat)?.seen, readAt <= seen, since >= Limits.meterOnTurnEnd { return true }
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
    /// which goes stale on its own.
    private func record(_ state: AccountState, for seat: Identity, at readAt: Date) {
        switch state {
        case .ok(let fh, let wk):
            var reading = SeatMeters(fiveHour: fh.map { MeterReading(percent: $0.utilization, resetsAt: $0.resetsAt) },
                                     weekly: wk.map { MeterReading(percent: $0.utilization, resetsAt: $0.resetsAt) },
                                     readAt: readAt)
            // A run carries on only from a reading of this run of the app since the Mac last woke:
            // after the app was quit or the Mac slept, the run starts again here.
            if let last = meters[seat], let lastAt = last.readAt, lastAt >= launchedAt, last.wokeSince == nil,
               last.showsFull == reading.showsFull { reading.since = last.runSince }
            meters[seat] = reading
            retryAt[seat] = nil
        case .rateLimited(let until):
            retryAt[seat] = until
        case .unreadable:
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

    /// Run the model's decision (section 4) and act on it. Everything it acts on is read fresh
    /// each tick from Claude's log and the readings; the wait in memory only holds back a second
    /// post or a second resume, and the spacing only a switch inside it.
    private func decide() async {
        guard readSinceWake else { return }
        wokeAt = nil
        let now = World.now()
        let f = facts(now: now)
        let decision = AutoSwitch.decide(f, now: now)
        switch decision {
        case .none:
            break
        case .brake, .wait, .switchTo:
            // The chats a switch, a brake or a wait is for: they resume in place if the seat in use
            // reads with room first (a switch that fails leaves Claude on it). Told once: a second
            // stop, a stall of the usage service or Auto-Switch off and on finds the same wait
            // already told. A single seat stays quiet (13a.8).
            guard let hold = f.hold else { return }
            let stops = AutoSwitch.stoppedNow(f, now: now)
            if wait?.hold == hold.key {
                wait?.stops.merge(stops) { old, _ in old }
            } else {
                wait = AutoSwitch.Wait(hold: hold.key, stops: stops)
                // A switch decided for later replaces the last switch's line once, as its start
                // would; a line told after it stays.
                if case .brake = decision { failure = nil }
            }
            if case .switchTo(let target) = decision, switchTask == nil {
                memory.lastAutoSwitch = now
                run(to: target, kind: .auto, resume: Set(stops.keys), trigger: "limitStop")
            }
            guard case .wait(let seat, let at) = decision, wait?.told == false else { break }
            wait?.told = true
            guard f.rows.compactMap(\.identity).count > 1 else { break }
            let when = at.map { " at \(ClockText.time($0, now: now))" } ?? ""
            World.claude.notify(title: "Every seat is out", body: "Chats resume when \(seat.flatMap { names[$0] } ?? "a seat") resets\(when).")
        case .resumeInPlace:
            if let seat = f.hold?.seat { resumeInPlace(AutoSwitch.resumable(f, now: now), on: seat, now: now) }
        }
        // A wait ends when Claude leaves its hold, or at the first current reading of its seat with
        // room, whether or not anything was resumed.
        if let w = wait, f.hold?.key != w.hold || AutoSwitch.hasRoom(f, now: now) { wait = nil }
    }

    /// The chats of a told wait get the resume step, now that the seat in use has room again; the
    /// ones it can't get running are named, as after a switch.
    private func resumeInPlace(_ chats: Set<String>, on seat: Identity, now: Date) {
        guard !chats.isEmpty else { return }
        let folder = ClaudeApp.folder(seat)
        let moved = chats.sorted().compactMap { ChatResume.chat(folder.appendingPathComponent($0 + ".json")) }
        Task {
            resumeEnded(await Switch.resume(moved, in: folder, reopenedAt: now, progress: { _ in }))
            publish()
        }
    }

    /// Turn Auto-Switch on or off. Turning it on is a click by the person at the Mac, so this is
    /// when macOS is asked to list the app under Accessibility.
    func setAutoSwitch(_ on: Bool) {
        settings.autoSwitch = on
        pausedHold = nil
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

    /// Give a seat's account a new colour, on every one of its rows; each row keeps its place
    /// (model, section 10).
    func recolor(_ seat: Seat, _ color: String) {
        guard let row = record(for: seat) else { return }
        var all = AccountStore.load()
        for i in all.indices where all[i].id == row.id || (row.accountUuid != nil && all[i].accountUuid == row.accountUuid) {
            all[i].color = color
        }
        save(all)
    }

    /// Show or fold away the organizations of an account in the menu; settings.json keeps it
    /// (model, section 10).
    func setShowsOrganizations(of account: String, _ shown: Bool) {
        settings.setShowsOrganizations(of: account, shown)
    }

    /// Open a seat's row to both meters, or close it to one line; settings.json keeps it through
    /// every refresh, every closing of the menu and every launch.
    func setShowsMeters(of seat: Seat, _ shown: Bool) {
        settings.setShowsMeters(of: seat.id, shown)
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

    /// Drop the row and delete its saved login and the previous build's slot at once, then sign its
    /// Claude Code login out and delete it. Its chats stay in Claude's folder for that pair.
    func remove(_ seat: Seat) {
        guard let row = record(for: seat) else { return }
        SavedLogins.remove(seat.id)
        try? FileManager.default.removeItem(at: LoginSlot.dir(row))
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

    /// Switch Claude to a seat. A manual switch never checks room: it is the person's call. It
    /// resumes every chat Claude stopped for a limit in its run (Switch.run).
    func switchTo(_ seat: Seat) { run(to: seat.id, kind: .manual) }

    /// Switch Claude to a seat with no saved login, at its sign-in page.
    func setUp(_ seat: Seat) { run(to: seat.id, kind: .setUp) }

    /// Each seat's row label, for the switch's lines.
    private var names: [Identity: String] { Dictionary(seats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    /// Run one switch, taking `resume`, the chats an automatic switch is for, with it; a second
    /// request while one runs is refused with a notice.
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
        let from = log.events.hold?.seat, fromHold = log.events.hold?.key
        let rows = accounts.map(\.seat)
        Diagnostics.record(.switchStarted, ["type": kind.rawValue, "from": from.map { rows.firstIndex(of: $0) ?? -1 } ?? NSNull(),
                                            "to": rows.firstIndex(of: target) ?? -1, "trigger": trigger ?? NSNull()])
        let request = Switch.Request(kind: kind, to: target, names: names, resume: resume,
                                     fromSettled: running && log.events.holdSettledForSaving(at: World.now()))
        let logNow = self.logNow
        return start(target, from: from, fromHold: fromHold, byHand: kind != .auto) { progress, switched in
            await Switch.run(request, log: logNow, progress: progress, switched: switched)
        } then: { outcome in
            if kind == .auto { self.autoFinished(outcome, from: from, fromHold: fromHold, to: target) }
        }
    }

    /// Finish or undo a switch the app was stopped in, or one that waited for Claude to open or close.
    private func recover() {
        guard switchTask == nil, let journal = SwitchJournal.load() else { return }
        let names = self.names
        start(journal.to, from: journal.from, fromHold: nil, byHand: journal.kind != .auto) { progress, switched in
            await Switch.recover(names: names, progress: progress, switched: switched)
                ?? SwitchOutcome(ok: false, text: "", parked: true)
        } then: { outcome in
            // Nothing stored types: the chats the switch was for stay as they are. The line stays
            // and is posted once, since after a restart nobody may be looking.
            guard !outcome.parked, !outcome.resume.isEmpty, let what = outcome.ok ? outcome.text : self.failure else { return }
            self.success = nil
            self.failure = "\(what) Chats were not resumed."
            World.claude.notify(title: outcome.text, body: "Chats were not resumed.")
        }
    }

    /// Run `body` as the switch in progress: its steps show on the target's row, and its outcome
    /// becomes the notice as soon as the switch ends, before the chats resume. From then on a new
    /// switch may start; this one's resume goes on until that switch overtakes it.
    @discardableResult
    private func start(_ target: Identity, from: Identity?, fromHold: String?, byHand: Bool,
                       _ body: @escaping (@escaping Switch.Progress, @escaping (SwitchOutcome) async -> Void) async -> SwitchOutcome,
                       then: @escaping (SwitchOutcome) -> Void) -> Task<Void, Never> {
        failure = nil
        success = nil
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
                self.switched(outcome, run: run, from: from, fromHold: fromHold, byHand: byHand)
            }
        }
        let task = Task {
            let outcome = await body(progress, switched)
            // A switch that ended before confirm (cancelled, refused, failed) reports here.
            if !ended.set { self.switched(outcome, run: run, from: from, fromHold: fromHold, byHand: byHand) }
            self.resumeEnded(outcome.resumeEnd)
            then(outcome)
            if outcome.promptLeftOpen, self.failure != nil { self.failureHold = self.log.events.hold?.key }
            if self.runs == run { self.resumeTask = nil }
            self.publish()
        }
        switchTask = task
        return task
    }

    /// Set once a switch has reported how it ended.
    private final class Flag: @unchecked Sendable { var set = false }

    /// The switch itself ended: its line goes in the notice.
    private func switched(_ outcome: SwitchOutcome, run: Int, from: Identity?, fromHold: String?, byHand: Bool) {
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
        // The person's own switch lands on a new hold, so nothing Claude stopped before it counts
        // and the automatic switch never undoes it. One stopped at its quit with Claude still on its
        // hold (cancelled, or Claude didn't quit) means stay: the automatic switch pauses on that
        // hold, as after a failure of its own, and the line says so. A refusal before any quit doesn't.
        let now = World.now()
        let paused = byHand && outcome.quitStopped && fromHold != nil && log.events.hold?.key == fromHold
        if paused { pausedHold = fromHold }
        if outcome.parked {
            failure = nil
        } else if outcome.ok {
            if !outcome.text.isEmpty { success = (outcome.text, now + Self.successFor) }
        } else if !outcome.text.isEmpty {
            failure = [outcome.text, outcome.detail, paused && settings.autoSwitch ? AutoSwitch.pausedUntil : nil].compactMap { $0 }.joined(separator: " ")
        }
        publish()
    }

    /// A resume ended, after a switch or in place: one line names the stopped chats the app could
    /// not get running, so the person sends them a message (sections 7 and 12). A resume another
    /// switch overtook names nothing: that switch carries its chats on.
    private func resumeEnded(_ end: ResumeEnd) {
        let n = end.notResumed.count
        guard !end.superseded, n > 0 else { return }
        failure = "Couldn't resume \(n) chat\(n == 1 ? "" : "s"): send \(n == 1 ? "it" : "them") a message."
    }

    /// An automatic switch ended, and is posted, since nobody may be looking. A failed target is
    /// skipped for coolDown, and the spacing from its start holds like any other's. A failure that
    /// reopened Claude began a new hold, so the stop it was for no longer counts. A failure that
    /// left Claude on its hold (it didn't quit, or the person cancelled) pauses automatic switching
    /// for the rest of that hold: the app never asks Claude to quit again by itself until the person
    /// switches by hand, Claude reopens, or Auto-Switch is turned off and on. Either way the line
    /// says what still works, and stays until the next switch is decided.
    private func autoFinished(_ outcome: SwitchOutcome, from: Identity?, fromHold: String?, to: Identity) {
        let name = { (s: Identity?) in s.flatMap { self.names[$0] } ?? "The seat in use" }
        if outcome.ok {
            let end = outcome.resumeEnd, chats = { (n: Int) in "\(n) chat\(n == 1 ? "" : "s")" }
            let resumed = end.resumed > 0 ? " \(chats(end.resumed)) resumed." : ""
            let named = end.notResumed.isEmpty ? "" : " Couldn't resume \(chats(end.notResumed.count)): send \(end.notResumed.count == 1 ? "it" : "them") a message."
            World.claude.notify(title: "Switched to \(name(to))", body: "\(name(from)) is out.\(resumed)\(named)")
            return
        }
        guard !outcome.parked else { return }
        failedTargets[to] = World.now()
        PairFile<Date>(name: "failed-targets.json").save(failedTargets)
        let stayed = log.events.hold?.key == fromHold
        if stayed { pausedHold = fromHold }
        let reason = "\(failure ?? outcome.text) \(stayed ? AutoSwitch.afterQuitFailure : AutoSwitch.afterFailure)"
        failure = "Didn't switch to \(name(to)). \(AutoSwitch.afterFailureShort)"
        failureDetail = "Didn't switch to \(name(to)): \(reason)"
        World.claude.notify(title: "Didn't switch to \(name(to))", body: reason)
    }
}

// MARK: - Diagnostics

/// The local diagnostics file the release soak is counted from (model, section 14). Each line is
/// one event: its kind, the clock's time, state names and row indexes (0-based, in menu order;
/// -1 for a pair that is not a row). A limit stop as it arrives (`stop`: its row, and whether its
/// hold had settled) and each new run of the held seat's readings (`meters`: full or not, since
/// when) explain a switch that didn't come. It never holds names, emails, ids or tokens, and it
/// never leaves the Mac. Only the values typed here can be written, so nothing else can slip in.
enum Diagnostics {
    enum Kind: String { case claude, hold, seat, decision, switchStarted, switchEnded, woke, shape, quitLook, stop, meters }

    /// What the app showed at one publish: the parts whose changes are logged.
    struct Snapshot: Equatable {
        var claude = "notRunning"
        var hold: Int?
        var seats: [String] = []
        var decision = "none"
        /// The held seat's run of readings: reading full or not, and since when.
        var heldRun: HeldRun?
    }
    struct HeldRun: Equatable { var full: Bool; var since: Date? }

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
        if let run = after.heldRun, before?.heldRun != run {
            out.append((.meters, ["row": after.hold ?? NSNull(), "full": run.full,
                                  "since": run.since.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()]))
        }
        return out
    }

    static func snapshot(_ f: Facts, seats: [Seat], decision: AutoSwitch.Decision, now: Date) -> Snapshot {
        let rows = f.rows.map(\.seat)
        var snap = Snapshot()
        snap.claude = !f.claude.installed ? "notInstalled" : !f.claude.running ? "notRunning"
            : f.hold.map { $0.settled(at: now) ? "settled" : "settling" } ?? "holdingNothing"
        snap.hold = f.hold.map { h in rows.firstIndex(of: h.seat) ?? -1 }
        snap.seats = seats.map { stateName($0.state) }
        snap.heldRun = f.hold.flatMap { f.meters[$0.seat] }.map { HeldRun(full: $0.showsFull, since: $0.runSince) }
        switch decision {
        case .none: snap.decision = "none"
        case .switchTo: snap.decision = "switch"
        case .wait: snap.decision = "wait"
        case .resumeInPlace: snap.decision = "resumeInPlace"
        case .brake: snap.decision = "brake"
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
        let prefill = target?.email ?? email
        // Pre-filling the email steers the browser to the right Google account.
        let args = ["auth", "login", "--claudeai"] + (prefill.map { ["--email", $0] } ?? [])
        // The one program the app starts outside runProcess, so it passes the same gate.
        guard let cli = ClaudeCLI.path, World.permits(cli, args) else { phase = .failed("Claude Code isn't installed. Install it, then try again."); return }
        let id = target?.id ?? "acct-" + UUID().uuidString.prefix(8).lowercased()
        let dir = target?.configURL ?? Paths.loginsDir.appendingPathComponent(id)
        let org = target?.orgUuid ?? organization
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
            p.arguments = args
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
        let installed = World.claude.installed
        var f = Facts()
        f.rows = AccountStore.load().inMenuOrder
        f.claude = ClaudeFacts(installed: installed, running: !ClaudeApp.pids().isEmpty,
                               missing: installed ? Set(ShapeMisses.load().keys) : [])
        f.log = log.events
        f.saved = Set(f.rows.compactMap(\.identity).filter(SavedLogins.usable))
        f.meters = meters
        f.failedTargets = PairFile<Date>(name: "failed-targets.json").load()
        f.switching = SwitchJournal.load().map { SwitchFacts(target: $0.to, step: $0.parked ? "parked until Claude opens" : $0.undoWhenClosed ? "undo waits for Claude to quit" : "in progress") }
        f.trusted = World.claude.trusted
        let settings = AppSettings.load()
        f.autoChosen = settings.autoSwitch
        f.order = settings.switchOrder
        f.lastAutoSwitch = SwitchMemory.load().lastAutoSwitch
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
            if case .out(let until?) = seat.state { line += " until \(ClockText.time(until, now: now))" }
            if case .switching(let step) = seat.state { line += " (\(step))" }
            if let read = seat.meters.readText(at: now) { line += ", meters \(read)" }
            out += line + "\n"
        }
        let decision: String
        switch AutoSwitch.decide(f, now: now) {
        case .none: decision = "nothing to do"
        case .switchTo(let t): decision = "switch to \(label(t))"
        case .resumeInPlace: decision = "resume the stopped chats in place"
        case .brake(let t, let at): decision = "switch to \(label(t)) at \(ClockText.time(at, now: now))"
        case .wait(let s, let at): decision = "wait" + (s.map { " for \(label($0))" } ?? "") + (at.map { " to reset at \(ClockText.time($0, now: now))" } ?? "")
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
        var log = LogReader()
        log.poll()
        guard let identity = log.events.hold?.seat else { say("Claude's log doesn't name the account it has open."); exit(1) }
        let folder = ClaudeApp.folder(identity)
        let matches = ((try? ClaudeApp.openSessionRecords(in: folder)) ?? []).compactMap(ChatResume.chat)
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
