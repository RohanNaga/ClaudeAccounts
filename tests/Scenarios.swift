import Foundation

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

    /// A saved login for a seat, taken through the app's own capture while Claude is closed.
    func savedLogin(_ row: String, _ seat: StandSeat) async throws {
        guard let acct = AccountStore.load().first(where: { $0.name == row }) else { throw SwitchError.inconsistent }
        claude.writeSignIn(seat)
        do { try await LoginSlot.capture(acct, as: seat.identity) }
        catch { check(false, "setup: saving \(row)'s login threw \(error)"); throw error }
    }

    /// Claude opens on its own sign-in files and holds that seat settled.
    func claudeHoldsSettled() {
        claude.start()
        clock.advance(ClaudeTiming.settle + 5)
    }

    func row(_ name: String) -> AccountRecord { store.accounts.first { $0.name == name }! }

    /// Lets the app act on what changed, then moves time a second at a time until `done` holds or
    /// `limit` seconds of virtual time pass. Nothing here waits on the real clock.
    func run(until done: () -> Bool, limit: TimeInterval = 1800) async {
        var t: TimeInterval = 0
        while !done() && t < limit {
            for _ in 0..<20 { await Task.yield() }
            clock.advance(1); t += 1
        }
        for _ in 0..<20 { await Task.yield() }
    }

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
        h.claudeHoldsSettled()
        h.store = Store()
        h.store.switchTo(h.row("Beta"))
        h.check(h.store.switching != nil, "the row shows Switching… while the switch runs")
        await h.run(until: { h.store.switching == nil && h.claude.held == B })
        h.clock.advance(ClaudeTiming.settle + 5)
        await h.run(until: { h.store.inUse == B.identity }, limit: 120)
        h.check(h.claude.held == B, "Claude holds Beta: held \(String(describing: h.claude.held)); the app said \(h.store.message ?? "nothing"); Claude saw \(h.claude.actions)")
        h.check(h.store.isInUse(h.row("Beta")), "Beta's row is In use")
        if ProcessInfo.processInfo.environment["DUMP"] != nil { print((try? String(contentsOf: h.claude.logDir.appendingPathComponent(ClaudeFiles.log), encoding: .utf8)) ?? "") }
        h.check(h.store.hasSavedLogin(h.row("Alpha")), "Alpha's saved login is intact")
    },
    Scenario(pair: "(Needs sign-in, Claude refuses (A, O))", model: "7: Refused for (A, O) only; other accounts' seats in O unaffected") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        try? await h.savedLogin("Gamma", C)
        try? await h.savedLogin("Alpha", A)
        h.claude.stale = [A]
        h.claudeHoldsSettled()
        h.store = Store()
        await h.run(until: { false }, limit: 5)
        h.check(h.store.isRefused(h.row("Alpha")), "Alpha shows Needs sign-in after its refusal")
        h.check(!h.store.isRefused(h.row("Gamma")), "Gamma, another account in the same organization, is not refused")
        h.check(h.store.hasSavedLogin(h.row("Gamma")), "Gamma keeps its saved login")
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
