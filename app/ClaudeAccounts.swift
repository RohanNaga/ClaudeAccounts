// Claude Accounts: menu bar usage monitor for several Claude accounts.
//
// Self-contained: everything the app writes lives in a `data` folder beside the
// app bundle, so the project folder is the whole footprint. Each account gets its
// own private Claude Code login in data/logins/<id>, used only to read usage; its
// token sits in the login keychain, and removing the account deletes it. The app
// reads the Claude desktop app's settings to show which account it is using, and
// never writes to them.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Paths and constants

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// The folder holding the app bundle. Moving that folder moves everything, but the
    /// logins are tied to their path, so accounts need adding again after a move.
    static let stateDir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("data")
    static let accountsFile = stateDir.appendingPathComponent("accounts.json")
    static let loginsDir = stateDir.appendingPathComponent("logins")
    static let desktopConfig = home.appendingPathComponent("Library/Application Support/Claude/config.json")
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
    let configDir: String
    let keychainService: String
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

    /// Account the Claude desktop app is signed in to (read-only).
    static func desktopAccountUuid() -> String? {
        guard let data = try? Data(contentsOf: Paths.desktopConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lastKnownAccountUuid"] as? String
    }
}

// MARK: - Usage

struct UsageWindow: Equatable {
    let pct: Int
    let resetsAt: Date?

    /// "resets in 2 h 05 m" within a day, otherwise "resets Mon 09:00".
    var resetText: String {
        guard let date = resetsAt else { return "" }
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "resetting now" }
        if secs < 24 * 3600 {
            let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
            return h > 0 ? "resets in \(h) h \(String(format: "%02d", m)) m" : "resets in \(m) m"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: date))"
    }

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

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [AccountRecord] = AccountStore.load()
    @Published var states: [String: AccountState] = [:]
    @Published var inUseUuid: String? = AccountStore.desktopAccountUuid()
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var message: String?
    /// The account the sign-in window re-authenticates; nil means it adds a new one.
    @Published var signInTarget: AccountRecord?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    /// True when any account needs a sign-in; the menu bar icon turns into a warning.
    var needsAttention: Bool { states.values.contains { $0.needsSignIn } }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func isInUse(_ acct: AccountRecord) -> Bool { acct.accountUuid != nil && acct.accountUuid == inUseUuid }

    /// Refresh unless a poll ran in the last minute; opening the menu calls this.
    func refreshIfStale() {
        if let last = lastUpdated, Date().timeIntervalSince(last) < 60 { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        accounts = AccountStore.load()
        inUseUuid = AccountStore.desktopAccountUuid()
        let snapshot = accounts
        Task {
            await withTaskGroup(of: (String, AccountState).self) { group in
                for acct in snapshot { group.addTask { (acct.id, await Usage.state(for: acct)) } }
                for await (id, state) in group { self.states[id] = state }
            }
            self.lastUpdated = Date()
            self.loading = false
        }
    }

    /// Show a short status line that clears itself.
    func flash(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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

    /// Sign the account's private login out, forget it, and delete its folder.
    func remove(_ acct: AccountRecord) {
        Task {
            _ = await ClaudeCLI.run(configDir: acct.configURL, ["auth", "logout"])
            if await Keychain.credential(service: acct.keychainService) != nil {
                await Keychain.delete(service: acct.keychainService)
            }
            try? FileManager.default.removeItem(at: acct.configURL)
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

    var menuBarTitle: String { menuBarSummary(self) }
}

/// Condense every account into the few characters the menu bar has room for.
///
/// Policy: show the account the desktop app is using and its 5-hour usage, since that
/// is the limit you hit first. Show only the icon until something has loaded.
@MainActor
func menuBarSummary(_ store: Store) -> String {
    guard let current = store.accounts.first(where: store.isInUse),
          case .ok(_, let fh?, _, _) = store.states[current.id] else { return "" }
    return "\(current.shortName) \(fh.pct)%"
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

/// Good / warning / critical, kept separate from the per-account colors.
func severity(_ pct: Int) -> Color { pct >= 85 ? .red : pct >= 60 ? .orange : .green }

let presetColors = ["#3567CF", "#B96E22", "#B3405F", "#2C8A5E", "#6B5BD2"]

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
            if let w = window, !w.resetText.isEmpty {
                Text(w.resetText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
    }
}

struct AccountRow: View {
    let account: AccountRecord
    let state: AccountState?
    let inUse: Bool
    let onSignIn: () -> Void
    let onRemove: () -> Void
    @State private var confirmingRemove = false

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
                Text(account.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                if case .ok(let plan?, _, _, _) = state {
                    Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if inUse {
                    Text("In use").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Menu {
                    if let org = account.orgName { Text(org) }
                    Button("Sign in again…", action: onSignIn)
                    Button("Remove \(account.name)…") { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            switch state {
            case .ok(_, let fh, let wk, _):
                Meter(label: "5-hour", window: fh)
                Meter(label: "Weekly", window: wk)
                if let warning = expiryWarning { signInPrompt(warning) }
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
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Accounts").font(.headline)
                Spacer()
                if store.loading {
                    ProgressView().controlSize(.mini)
                } else if let t = store.lastUpdated {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

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
                           onSignIn: { openSignIn(acct) },
                           onRemove: { store.remove(acct) })
            }

            Divider().padding(.horizontal, 4).padding(.vertical, 5)
            MenuRow(icon: "plus", title: "Add Account…") { openSignIn(nil) }
            MenuRow(icon: "arrow.clockwise", title: "Refresh", shortcut: "⌘R") { store.refresh() }
                .keyboardShortcut("r")
            MenuRow(icon: store.openAtLogin ? "checkmark" : "", title: "Open at Login") { store.toggleOpenAtLogin() }
            Divider().padding(.horizontal, 4).padding(.vertical, 5)
            MenuRow(icon: "power", title: "Quit Claude Accounts", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
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

/// A full-width row drawn like a native menu item: icon, title, optional shortcut, and the
/// accent-colored highlight on hover.
struct MenuRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon.isEmpty ? "circle" : icon)
                    .opacity(icon.isEmpty ? 0 : 1)
                    .frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
            .onAppear { store.refresh() }
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

@main
struct ClaudeAccountsApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.needsAttention ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                if !store.menuBarTitle.isEmpty { Text(store.menuBarTitle).monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sign in", id: "sign-in") {
            SignInView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
