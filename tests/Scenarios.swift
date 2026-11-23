import Foundation
import Darwin

/// Live child processes of this test (the app runs sqlite3 as one).
func childProcesses() -> Int32 { proc_listchildpids(getpid(), nil, 0) }

// End-to-end scenarios written from the model (claude-accounts-model, sections 6 to 9). Each is
// named by its (state, event) pair and asserts the outcome and the line the person sees. A pair
// with no body yet is listed as pending and counts as not passing, so the totals never overstate.

struct Scenario {
    let pair: String
    let model: String
    let body: (@MainActor (Harness) async -> Void)?
}

/// One scenario's world: the stand-in Claude, its meters, the clock, and the app's own Store.
@MainActor final class Harness {
    let clock: VirtualClock
    let claude: StandInClaude
    let usage = StandInUsage()
    var store: Store!
    private(set) var failures: [String] = []
    var checks = 0

    init() throws {
        clock = VirtualClock(start: Date())
        claude = try StandInClaude(clock: clock)
        try World.install(claude, clock: clock)
        Usage.install(usage)
    }

    func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures.append(what) }
    }

    /// Writes the person's rows (F9), one per seat, in menu order.
    func rows(_ seats: [(String, StandSeat)]) throws {
        let list = seats.enumerated().map { i, s in
            AccountRecord(id: "row\(i)", name: s.0, color: "blue", configDir: claude.root.appendingPathComponent("cli/row\(i)").path,
                          keychainService: "test-row\(i)", email: nil, accountUuid: s.1.account, orgName: "Team", orgUuid: s.1.org)
        }
        try AccountStore.save(list)
    }

    /// Claude opens on its own sign-in files and holds that seat settled.
    func claudeHoldsSettled() {
        claude.start()
        clock.advance(ClaudeTiming.settle + 5)
    }


    /// Lets the app's tasks run until each is asleep on the clock or done, waiting out any real
    /// process the app started (sqlite3) by polling for its exit.
    func settle() async {
        for _ in 0..<200 {
            for _ in 0..<20 { await Task.yield() }
            if childProcesses() == 0 { for _ in 0..<20 { await Task.yield() }; if childProcesses() == 0 { return } }
            usleep(1000)
        }
    }

    /// Moves time a second at a time, with one app tick every 15 s as the app's own timer does,
    /// until `done` holds or `limit` seconds of virtual time pass. Nothing waits on the real clock.
    func run(until done: () -> Bool, limit: TimeInterval = 1800) async {
        var t: TimeInterval = 0
        await settle()
        while !done() && t < limit {
            if Int(t) % 15 == 0 { await tick(); await settle() }
            clock.advance(1); t += 1
            await settle()
        }
    }

    /// Runs for `seconds` of virtual time.
    func pass(_ seconds: TimeInterval) async { await run(until: { false }, limit: seconds) }

    func cleanUp() { claude.cleanUp() }
}

/// The model's constants (section 5), as the scenarios assume them.
enum ClaudeTiming {
    static let settle: TimeInterval = 60
}

let A = StandSeat(1, org: 1)
let B = StandSeat(2, org: 1)
let C = StandSeat(3, org: 1)

let scenarios: [Scenario] = [
    Scenario(pair: "(Ready, click Switch on T)", model: "7: the switch; Switching… then T In use") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        try? await h.savedLogin("Beta", B)
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled()
        h.make()
        await h.tick()
        h.check(h.state("Beta") == .ready && h.action("Beta") == .switchTo, "Beta is Ready with Switch: \(String(describing: h.state("Beta")))")
        h.click("Beta")
        await h.settle()
        h.check(h.state("Beta") == .switching || !h.notice.filter { $0.hasPrefix("Switching") }.isEmpty, "Beta shows Switching… while the switch runs")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse }, limit: 300)
        h.check(h.claude.held == B, "Claude holds Beta: holds \(String(describing: h.claude.held)); notice \(h.notice)")
        h.check(h.state("Beta") == .inUse, "Beta's row is In use")
        h.check(h.claude.chats(in: B).contains("local_one"), "the chat moved to Beta's folder")
        h.check(h.state("Alpha") == .ready, "Alpha keeps its saved login and is Ready: \(String(describing: h.state("Alpha")))")
    },
    Scenario(pair: "(Needs sign-in, Claude refuses (A, O))", model: "7: Refused for (A, O) only; other accounts' seats in O unaffected") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        try? await h.savedLogin("Gamma", C)
        try? await h.savedLogin("Alpha", A)
        h.claude.stale = [A]
        h.make()
        h.claude.start()
        await h.pass(ClaudeTiming.settle + 30)
        h.check(h.state("Alpha") == .needsSignIn && h.action("Alpha") == .setUp, "Alpha shows Needs sign-in with Set Up: \(String(describing: h.state("Alpha")))")
        h.check(h.state("Gamma") == .ready && h.action("Gamma") == .switchTo, "Gamma, another account in the same organization, stays Ready with Switch: \(String(describing: h.state("Gamma")))")
    },
    // Section 7 rows still to build (each asserts the outcome and the line in quotes).
    Scenario(pair: "(Needs sign-in, click Set Up on T)", model: "\"Sign in to <T> in Claude.\" then In use, or \"Claude signed in as <X>, not <T>. Back on <S>.\"", body: nil),
    Scenario(pair: "(In use, click the row in use)", model: "nothing", body: nil),
    Scenario(pair: "(In use settled, limit stop, target exists)", model: "\"Switched to <T>: <S> is out. N chats resumed.\"", body: nil),
    Scenario(pair: "(In use settling, limit stop before settle)", model: "not counted against S; chat still resumed; nothing shown", body: nil),
    Scenario(pair: "(In use, wrap-up: turn ended then 100% read)", model: "same as a limit stop", body: nil),
    Scenario(pair: "(Every seat out, out signal)", model: "\"Every seat is out. Chats resume when <seat> resets at <time>.\"", body: nil),
    Scenario(pair: "(Waiting, reset time passes)", model: "read the meter, then resume in place or switch", body: nil),
    Scenario(pair: "(Not waiting, reset time passes)", model: "meter re-read, row changes", body: nil),
    Scenario(pair: "(In use, meter reads 100% with no turn ended)", model: "Out on the row, no switch", body: nil),
    Scenario(pair: "(Refused, Claude falls back to personal)", model: "personal row: In use", body: nil),
    Scenario(pair: "(No switch, Claude quits or crashes)", model: "\"Claude isn't running.\" Switch still works and opens Claude", body: nil),
    Scenario(pair: "(Quit wait, the person quits Claude)", model: "the quit succeeded, go on", body: nil),
    Scenario(pair: "(After launch before confirm, the person quits Claude)", model: "\"Open Claude to finish switching to <T>.\" no rollback while closed", body: nil),
    Scenario(pair: "(Between quit and launch, the person opens Claude)", model: "quit once more; a second time rolls back; \"Switching…\"", body: nil),
    Scenario(pair: "(Confirm, Claude restarts by itself)", model: "NewRun then Named: confirm as usual", body: nil),
    Scenario(pair: "(Any step, the app is quit, crashed or updated)", model: "\"Finished switching to <T>\" or \"Switch to <T> undone\"", body: nil),
    Scenario(pair: "(Any, sleep then wake)", model: "meters stale then re-read; no automatic decision until a fresh read", body: nil),
    Scenario(pair: "(Lock held before resume, second switch)", model: "\"Already switching to <T>.\"", body: nil),
    Scenario(pair: "(During resume, second switch)", model: "resume cancelled, chats carried over", body: nil),
    Scenario(pair: "(Resume, message box not on screen)", model: "\"Couldn't resume 1 chat: send it a message.\" after 30 min", body: nil),
    Scenario(pair: "(Any, Accessibility not granted)", model: "\"Allow Accessibility so Claude Accounts can switch on its own and resume chats.\"", body: nil),
    Scenario(pair: "(Any, Claude not installed)", model: "\"Claude isn't installed.\" Switch hidden", body: nil),
    Scenario(pair: "(Any, Claude never signed in or signed out)", model: "every seat Needs sign-in; Set Up on each row", body: nil),
    Scenario(pair: "(Any, unknown Claude version or shape mismatch)", model: "\"Claude updated to a version this app hasn't checked. Switching on its own is paused.\"", body: nil),
    Scenario(pair: "(Any, row renamed or reordered)", model: "display and automatic order only", body: nil),
    Scenario(pair: "(Not in use, row removed)", model: "saved login and row deleted; chats stay", body: nil),
    Scenario(pair: "(In use, row removed)", model: "\"Claude is on an account not in the list.\"", body: nil),
    Scenario(pair: "(Any, two rows with the same name)", model: "\" · <organization>\", then \" (2)\"; never an email", body: nil),
    Scenario(pair: "(Any, meter stale or missing)", model: "manual switch allowed, not an automatic target; \"read N min ago\" or \"not read yet\"", body: nil),
    Scenario(pair: "(Any, more rows than fit)", model: "cards scroll; title and notice pinned; row in use visible (MenuLayout seam)", body: nil),
    // Section 6 steps, section 8 invariants and section 9 cases.
    Scenario(pair: "(Switch step 2, quit prompt cancelled)", model: "\"Switch cancelled\", nothing changed", body: nil),
    Scenario(pair: "(Switch step 6, Claude names another pair)", model: "roll back; \"<seat> asked for a new sign-in. Back on <S>.\"", body: nil),
    Scenario(pair: "(Invariant A, faults at every step)", model: "kill app, kill Claude, full disk, failed read: ends signed in to S or T, every saved login intact", body: nil),
    Scenario(pair: "(Any Mac, first launch nothing saved)", model: "first-run screen, then the held seat becomes the first row once settled", body: nil),
    Scenario(pair: "(Any Mac, one account one organization)", model: "one row, no Switch, automatic stays quiet", body: nil),
    Scenario(pair: "(Any Mac, one account several organizations)", model: "a row per organization; switching moves chats", body: nil),
    Scenario(pair: "(Any Mac, twenty rows)", model: "cards scroll, compact rows; height within 900 pt and 1400 pt screens", body: nil),
]

@main
enum ScenarioRun {
    @MainActor static func main() async {
        var passed = 0, failed = 0, pending = 0
        let only = CommandLine.arguments.dropFirst().first
        for s in scenarios where only == nil || s.pair.contains(only!) {
            guard let body = s.body else { print("PEND \(s.pair): \(s.model)"); pending += 1; continue }
            guard let h = try? Harness() else { print("FAIL \(s.pair): the stand-in could not be installed"); failed += 1; continue }
            await body(h)
            if h.failures.isEmpty { print("ok   \(s.pair) (\(h.checks) checks)"); passed += 1 }
            else { print("FAIL \(s.pair): model says \(s.model)"); h.failures.forEach { print("       - \($0)") }; failed += 1 }
            h.cleanUp()
        }
        print("Scenarios: \(passed) passed, \(failed) failed, \(pending) pending")
        exit(failed + pending == 0 ? 0 : 1)
    }
}
