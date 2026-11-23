// The guard in app/Claude.swift: a test world can never reach the real Claude, the real home
// folder or the keychain. Every later test that installs a stand-in Claude relies on it.

import AppKit

/// A world made only of paths, so each test can point one of them somewhere it must not go.
struct PathWorld: ClaudeWorld {
    var home: URL
    var stateDir: URL
    var bundleId = "test.claude-accounts.stand-in"
    var dataDir: URL
    var logDir: URL
    var exe: String
    var reported: [pid_t] = []

    init(root: URL) {
        home = root
        stateDir = root.appendingPathComponent("state")
        dataDir = root.appendingPathComponent("claude")
        logDir = root.appendingPathComponent("logs")
        exe = root.appendingPathComponent("Claude").path
    }

    func executable() -> String { exe }
    func pids() -> [pid_t] { reported }
    func windowIDs(_ owners: [pid_t]) -> Set<Int> { [] }
    func requestQuit(_ pid: pid_t) async {}
    func launch() async {}
    func open(link: String) async {}
    var trusted: Bool { false }
    func quitPromptOpen(in owners: [pid_t]) -> Bool { false }
    func pressQuitPrompt(_ title: String, in owners: [pid_t]) -> Bool { false }
    func exposeWebContent(of owners: [pid_t]) {}
    func chatScreen(session: String, in owners: [pid_t]) -> ChatScreen? { nil }
    func send(_ text: String, session: String, in owners: [pid_t], trace: (String) -> Void) -> ChatComposer.Sent { .refused("test") }
    func idleSeconds() -> TimeInterval { 0 }
}

struct StillClock: AppClock {
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(_ seconds: TimeInterval) async {}
}

@main
enum WorldGuardTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func refused(_ world: any ClaudeWorld) -> Bool {
        do { try World.install(world, clock: StillClock()); return false } catch { return true }
    }

    static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("world-guard-\(getpid())")
        let realHome = World.realHome
        let safe = PathWorld(root: root)

        check(World.claude is RealClaudeWorld && !World.isTest, "the app starts on the real Claude")
        check(World.refusal(RealClaudeWorld()) == .realWorld && refused(RealClaudeWorld()), "a test cannot install the real Claude")

        var w = safe
        w.bundleId = RealClaudeWorld.realBundleId
        check(refused(w), "a test world cannot use Claude's bundle id")

        let inHome = realHome.appendingPathComponent("Library/Application Support/Claude")
        for (name, edit) in [("home", { (w: inout PathWorld) in w.home = realHome }),
                             ("state folder", { (w: inout PathWorld) in w.stateDir = realHome.appendingPathComponent("Library/Application Support/ClaudeAccounts") }),
                             ("data folder", { (w: inout PathWorld) in w.dataDir = inHome }),
                             ("log folder", { (w: inout PathWorld) in w.logDir = realHome.appendingPathComponent("Library/Logs/Claude") }),
                             ("executable", { (w: inout PathWorld) in w.exe = "/Applications/Claude.app/Contents/MacOS/Claude" })] {
            var w = safe
            edit(&w)
            check(refused(w), "a test world's \(name) cannot be the real one")
        }
        // A link inside the temporary folder that points into the real home is followed, not trusted.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: realHome)
        var linked = safe
        linked.dataDir = link.appendingPathComponent("Library")
        check(refused(linked), "a path that resolves into the real home through a link is refused")
        try? FileManager.default.removeItem(at: link)
        check(World.claude is RealClaudeWorld && !World.isTest, "a refused world installs nothing")
        check(World.permits("/bin/ps", []), "the real world runs every program")

        check(!refused(safe), "a world under a temporary folder installs")
        check(World.isTest && World.claude is PathWorld, "the test world is the one in use")
        check(World.now() == Date(timeIntervalSince1970: 0), "the app reads the test clock")
        check(refused(RealClaudeWorld()) && World.claude is PathWorld, "once in a test, the real Claude cannot come back")
        for program in ["/usr/bin/security", "/usr/bin/osascript", "/usr/bin/open", "/bin/ps", realHome.appendingPathComponent(".local/bin/claude").path] {
            let res = runProcessBlocking(program, [], env: nil, cwd: nil, timeout: 5)
            let name = program.hasSuffix("/claude") ? "the Claude Code CLI" : program
            check(res.status == -1 && res.err.contains("not run in a test world"), "a test world never runs \(name)")
        }
        let res = runProcessBlocking("/usr/bin/sqlite3", [realHome.appendingPathComponent("x.db").path, "select 1;"], env: nil, cwd: nil, timeout: 5)
        check(res.status == -1, "a test world never hands a program a path in the real home")
        let ok = runProcessBlocking("/usr/bin/sqlite3", [":memory:", "select 1;"], env: nil, cwd: nil, timeout: 5)
        check(ok.status == 0 && ok.out == "1\n", "a test world still runs sqlite3 on its own files")

        let me = getpid()
        check(World.checked([me]) == [me], "a test world's own process ids pass")
        if let claude = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == RealClaudeWorld.realBundleId }) {
            check(World.checked([claude.processIdentifier, me]) == [me], "the real Claude's process id never reaches a test world's caller")
        } else {
            print("skip the real Claude isn't running, so its process id can't be offered")
        }

        print(failures == 0 ? "World guard: ok" : "World guard: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
