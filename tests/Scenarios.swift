import Foundation
import Darwin

/// Live child processes of this test (the app runs sqlite3 as one). Called with no buffer,
/// proc_listchildpids returns a size estimate, not a count, so it is given one to fill.
func childProcesses() -> Int32 {
    var pids = [pid_t](repeating: 0, count: 64)
    let n = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return max(0, n)
}

/// Threads of this test, other than the caller, that are running or blocked in the kernel: the
/// app's tasks off the main actor doing file work. Idle pool threads wait and are not counted.
func busyThreads() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
    defer {
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
    }
    let me = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, me) }
    var busy = 0
    for i in 0..<Int(count) where list[i] != me {
        var info = thread_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &n) } }
        if r == KERN_SUCCESS, info.run_state == TH_STATE_RUNNING || info.run_state == TH_STATE_UNINTERRUPTIBLE { busy += 1 }
    }
    return busy
}

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
    func rows(_ seats: [(String, StandSeat)], orgNames: [String]? = nil) throws {
        let list = seats.enumerated().map { i, s in
            AccountRecord(id: "row\(i)", name: s.0, color: "blue", configDir: claude.root.appendingPathComponent("cli/row\(i)").path,
                          keychainService: "test-row\(i)", email: nil, accountUuid: s.1.account, orgName: orgNames?[i] ?? "Team", orgUuid: s.1.org)
        }
        try AccountStore.save(list)
    }

    /// Claude opens on its own sign-in files and holds that seat settled.
    func claudeHoldsSettled() {
        claude.start()
        clock.advance(ClaudeTiming.settle + 5)
    }

    /// Lets the app's tasks run until each is asleep on the clock or done: no real child process, no other thread at work,
    /// (the app runs sqlite3) and no change to the clock's schedule and no switch awake, over three rounds of yields.
    /// The app's tasks off the main actor run on other threads, so a short real pause lets them in.
    func settle() async {
        var quiet = 0, last = clock.activity
        for _ in 0..<2000 {
            for _ in 0..<20 { await Task.yield() }
            let now = clock.activity
            // A switch that is not asleep on the clock is mid-step (copying, moving, sqlite3).
            let working = switchInFlight && clock.asleep == 0
            if !working && childProcesses() == 0 && busyThreads() == 0 && now == last { quiet += 1; if quiet >= 3 { return } } else { quiet = 0 }
            last = now
            usleep(200)
        }
        if Harness.trace { print("trace: settle gave up, children \(childProcesses()), busy \(busyThreads()), activity \(clock.activity) vs \(last), asleep \(clock.asleep)") }
    }

    /// HARNESS_TRACE=1 prints each jump of the clock and any settle that gave up.
    static let trace = ProcessInfo.processInfo.environment["HARNESS_TRACE"] != nil

    /// Runs virtual time until `done` holds or `limit` seconds pass. The clock jumps straight to the
    /// next thing due, an event the app or the stand-in scheduled or the app's own tick, runs only
    /// that, and lets the app settle before the next jump. Nothing waits on the real clock.
    func run(until done: () -> Bool, limit: TimeInterval = 1800) async {
        let start = clock.now(), end = start.addingTimeInterval(limit)
        var nextTick = start
        await settle()
        while !done() && clock.now() < end {
            if clock.now() >= nextTick {
                await tick(); await settle()
                nextTick = nextTick.addingTimeInterval(tickEvery)
                continue
            }
            if Harness.trace { print("trace: at +\(clock.now().timeIntervalSince(start)) s, next due \(clock.nextDue.map { $0.timeIntervalSince(clock.now()) } ?? -1) s, asleep \(clock.asleep), notice \(notice)") }
            let to = min(clock.nextDue ?? end, nextTick, end)
            clock.advance(max(0, to.timeIntervalSince(clock.now())))
            await settle()
        }
    }

    /// Runs for `seconds` of virtual time.
    func pass(_ seconds: TimeInterval) async { await run(until: { false }, limit: seconds) }

    func cleanUp() { claude.cleanUp() }

    /// The common start: Alpha (A), Beta (B), Gamma (C), each with a saved login and a fresh meter
    /// with room; one idle chat in Alpha's folder; Claude holding Alpha settled; the app running.
    func standard(chat: String? = "local_one", onScreen: Bool = true) async {
        try? rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, seat) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await savedLogin(n, seat) }
        for seat in [A, B, C] { usage.set(seat, fiveHour: 20, resetsAt: clock.now().addingTimeInterval(3 * 3600)) }
        if let chat {
            claude.addChat(chat, in: A, lastActivity: clock.now())
            if onScreen { claude.screens[chat] = ChatScreen(busy: false, composer: true, draft: false) }
        }
        claudeHoldsSettled()
        make()
        await tick(); await settle()
    }

    func noticeHas(_ text: String) -> Bool { notice.contains { $0.contains(text) } }
    var quits: Int { claude.actions.filter { $0 == "quit" }.count }
    var launches: Int { claude.actions.filter { $0 == "launch" }.count }
    func resumed(_ chat: String) -> Bool { claude.sent.contains("\(chat) resume") }
}

/// The model's constants (section 5), as the scenarios assume them.
enum ClaudeTiming {
    static let settle: TimeInterval = 60
    static let meterEvery: TimeInterval = 5 * 60
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
    Scenario(pair: "(Needs sign-in, click Set Up on T)", model: "\"Sign in to <T> in Claude.\" then In use, or \"Claude signed in as <X>, not <T>. Back on <S>.\"") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.state("Beta") == .needsSignIn && h.action("Beta") == .setUp, "Beta Needs sign-in with Set Up: \(String(describing: h.state("Beta")))")
        h.claude.signsInAs = B
        h.click("Beta")
        await h.run(until: { h.noticeHas("Sign in to Beta in Claude.") }, limit: 120)
        h.check(h.noticeHas("Sign in to Beta in Claude."), "the notice asks to sign in to Beta: \(h.notice)")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse }, limit: 900)
        h.check(h.state("Beta") == .inUse, "Beta In use after the sign-in: \(String(describing: h.state("Beta"))), \(h.notice)")
        h.check(h.claude.chats(in: B).contains("local_one"), "the chat came over to Beta")
        // In use shows at the Named line; the confirm, and then the save, come once the hold settles.
        await h.run(until: { h.hasSavedLogin(B) }, limit: ClaudeTiming.settle + 60)
        h.check(h.hasSavedLogin(B), "Beta's login is saved once confirmed")
        h.check(h.hasSavedLogin(A), "Alpha's saved login is intact")
    },
    Scenario(pair: "(Set Up on T, Claude signs in as another row)", model: "7: \"Claude signed in as <X>, not <T>. Back on <S>.\"; 13.1 rolls back, chats never stranded; 1: a login is filed only under the seat Claude held") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.claude.signsInAs = C
        h.click("Beta")
        await h.run(until: { h.noticeHas("Back on Alpha") }, limit: 900)
        h.check(h.noticeHas("Claude signed in as Gamma, not Beta. Back on Alpha."), "the row says why: \(h.notice)")
        await h.run(until: { h.claude.held == A }, limit: 300)
        h.check(h.claude.held == A, "rolled back to Alpha: holds \(String(describing: h.claude.held))")
        h.check(h.claude.chats(in: A).contains("local_one") && !h.claude.chats(in: B).contains("local_one") && !h.claude.chats(in: C).contains("local_one"),
                "the chat is back in Alpha's folder")
        h.check(!h.hasSavedLogin(B), "nothing is filed under Beta: Claude never held Beta")
        h.check(h.state("Beta") == .needsSignIn, "Beta still Needs sign-in: \(String(describing: h.state("Beta")))")
        h.check(h.hasSavedLogin(A), "Alpha's saved login is intact")
    },
    Scenario(pair: "(Set Up on T, the target organization refuses the new sign-in)", model: "6: a refused target rolls back and shows Needs sign-in; 1 and 13a.2: a login is saved only under a settled hold") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.claude.signsInAs = B
        h.claude.stale = [B]
        h.click("Beta")
        await h.run(until: { h.claude.held == A && h.launches >= 2 }, limit: 900)
        await h.pass(ClaudeTiming.settle + 10)
        h.check(h.claude.held == A, "rolled back to Alpha: holds \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.claude.chats(in: A).contains("local_one"), "the chat is back in Alpha's folder")
        h.check(!h.hasSavedLogin(B), "nothing is filed under Beta: Claude never held Beta settled")
        h.check(h.state("Beta") == .needsSignIn, "Beta Needs sign-in: \(String(describing: h.state("Beta")))")
        h.check(h.hasSavedLogin(A), "Alpha's saved login is intact")
    },
    Scenario(pair: "(In use, click the row in use)", model: "nothing") { h in
        await h.standard()
        h.check(h.state("Alpha") == .inUse && h.action("Alpha") == nil, "Alpha In use with no action")
        h.click("Alpha")
        await h.pass(60)
        h.check(h.claude.actions.isEmpty, "nothing happens: \(h.claude.actions)")
        h.check(h.claude.held == A, "Claude still holds Alpha")
    },
    Scenario(pair: "(In use settled, limit stop, target exists)", model: "\"Switched to <T>: <S> is out. N chats resumed.\"") { h in
        await h.standard()
        h.claude.screens["local_one"]?.busy = false
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held == B && h.resumed("local_one") }, limit: 600)
        h.check(h.claude.held == B, "the automatic switch went to Beta, next down the menu: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.claude.chats(in: B).contains("local_one"), "the stopped chat moved to Beta")
        h.check(h.resumed("local_one"), "the stopped chat got one \"resume\": \(h.claude.sent)")
        h.check(h.claude.sent.filter { $0.hasPrefix("local_one") }.count == 1, "exactly one resume")
        h.check(h.state("Alpha") == .out, "Alpha shows Out after its settled stop: \(String(describing: h.state("Alpha")))")
        await h.run(until: { !h.claude.notifications.isEmpty }, limit: 120)
        h.check(h.claude.notifications.contains("Switched to Beta: Switched to Beta: Alpha is out. 1 chat resumed."), "the notification: \(h.claude.notifications)")
    },
    Scenario(pair: "(In use settling, limit stop before settle)", model: "not counted against S; chat still resumed; nothing shown") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        await h.pass(10)
        h.claude.logLimitStop("local_one")
        await h.pass(300)
        h.check(h.claude.held == B, "no automatic switch away from Beta: \(String(describing: h.claude.held))")
        h.check(h.quits == 1, "only the manual switch quit Claude: \(h.claude.actions)")
        h.check(h.state("Beta") == .inUse && h.state("Beta") != .out, "Beta In use, not counted Out")
        h.check(h.resumed("local_one"), "the chat is still resumed: \(h.claude.sent)")
    },
    Scenario(pair: "(In use, wrap-up: turn ended then 100% read)", model: "same as a limit stop") { h in
        await h.standard()
        let before = h.usage.reads.count
        // A turn ends some time after the last reading (Claude's log has whole seconds).
        await h.pass(10)
        h.claude.logTurnEnded("local_one")
        h.usage.set(A, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        await h.run(until: { h.claude.held == B }, limit: 300)
        h.check(h.usage.reads.dropFirst(before).contains(A.tag), "the turn's end triggered a read of Alpha's meter")
        h.check(h.claude.held == B, "a turn ended then a 100% reading switches to Beta: \(String(describing: h.claude.held)), \(h.notice)")
        await h.run(until: { h.resumed("local_one") }, limit: 120)
        h.check(h.resumed("local_one"), "the wrapped-up chat gets one resume (13.2)")
    },
    Scenario(pair: "(Every seat out, out signal)", model: "\"Every seat is out. Chats resume when <seat> resets at <time>.\"") { h in
        await h.standard()
        let reset = h.clock.now().addingTimeInterval(2 * 3600)
        for s in [A, B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        // The app knows only what it has read: let its next scheduled read see every seat out.
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one")
        await h.pass(120)
        h.check(h.claude.actions.isEmpty, "no switch when every seat is out: \(h.claude.actions)")
        h.check(h.noticeHas("Every seat is out. Chats resume when") && h.noticeHas(DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)), "the waiting line names the reset: \(h.notice)")
    },
    Scenario(pair: "(Waiting, reset time passes)", model: "read the meter, then resume in place or switch") { h in
        await h.standard()
        let now = h.clock.now()
        h.usage.set(A, fiveHour: 100, resetsAt: now.addingTimeInterval(7200))
        h.usage.set(B, fiveHour: 100, resetsAt: now.addingTimeInterval(600))
        h.usage.set(C, fiveHour: 100, resetsAt: now.addingTimeInterval(7200))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one")
        await h.pass(60)
        h.check(h.noticeHas("Every seat is out"), "waiting first: \(h.notice)")
        h.clock.after(590) { h.usage.set(B, fiveHour: 0, resetsAt: now.addingTimeInterval(600 + 5 * 3600)) }
        await h.run(until: { h.claude.held == B && h.resumed("local_one") }, limit: 1200)
        h.check(h.claude.held == B, "Beta's reset read gives it room and the app switches: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.resumed("local_one"), "the waiting chat is resumed")
    },
    Scenario(pair: "(Not waiting, reset time passes)", model: "meter re-read, row changes") { h in
        await h.standard()
        let now = h.clock.now()
        h.usage.set(B, fiveHour: 100, resetsAt: now.addingTimeInterval(600))
        await h.pass(400)
        h.check(h.state("Beta") == .out, "Beta Out before its reset: \(String(describing: h.state("Beta")))")
        h.usage.set(B, fiveHour: 0, resetsAt: now.addingTimeInterval(600 + 5 * 3600))
        await h.run(until: { h.state("Beta") == .ready }, limit: 400)
        h.check(h.state("Beta") == .ready, "the reset is re-read and Beta is Ready: \(String(describing: h.state("Beta")))")
        h.check(h.claude.actions.isEmpty, "no switch")
    },
    Scenario(pair: "(In use, meter reads 100% with no turn ended)", model: "Out on the row, no switch") { h in
        await h.standard()
        h.usage.set(A, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        h.usage.set(B, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        await h.pass(900)
        h.check(h.claude.actions.isEmpty, "a meter alone never starts a switch: \(h.claude.actions)")
        h.check(h.state("Beta") == .out, "Beta's row shows Out: \(String(describing: h.state("Beta")))")
        h.check(h.action("Beta") == .switchTo, "an Out row keeps Switch")
    },
    Scenario(pair: "(Refused, Claude falls back to personal)", model: "personal row: In use") { h in
        let P = StandSeat(1, org: 0)
        // One account in two organizations: one card, a row per organization (section 9).
        try? h.rows([("Alpha", A), ("Alpha", P)], orgNames: ["Team", "Home"])
        try? await h.savedLogin("Alpha", P)
        try? await h.savedLogin("Alpha", A)
        h.claude.stale = [A]
        h.make(); h.claude.start()
        await h.pass(ClaudeTiming.settle + 30)
        h.check(h.state("Alpha · Home") == .inUse, "the personal row is In use: \(String(describing: h.state("Alpha · Home"))), rows \(h.rowNames)")
        h.check(h.state("Alpha · Team") == .needsSignIn, "the refused row Needs sign-in: \(String(describing: h.state("Alpha · Team")))")
    },
    Scenario(pair: "(No switch, Claude quits or crashes)", model: "\"Claude isn't running.\" Switch still works and opens Claude") { h in
        await h.standard()
        h.claude.stop()
        await h.tick()
        h.check(h.noticeHas("Claude isn't running."), "the notice says so: \(h.notice)")
        h.check(h.action("Beta") == .switchTo, "Switch still shows")
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        h.check(h.claude.held == B, "Switch opens Claude on Beta: \(String(describing: h.claude.held)), \(h.notice)")
    },
    Scenario(pair: "(Quit wait, the person quits Claude)", model: "the quit succeeded, go on") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.click("Beta")
        await h.pass(20)
        h.check(h.claude.pids().count == 1, "a manual switch waits for the person at the prompt")
        h.claude.stop()
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse }, limit: 300)
        h.check(h.claude.held == B, "the person's quit counts and the switch goes on: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(!h.claude.actions.contains { $0.hasPrefix("pressed") }, "the app never pressed the prompt on a manual switch")
    },
    Scenario(pair: "(After launch before confirm, the person quits Claude)", model: "\"Open Claude to finish switching to <T>.\" no rollback while closed") { h in
        await h.standard()
        h.claude.nameAfter = 120
        h.click("Beta")
        await h.run(until: { h.launches == 1 }, limit: 120)
        await h.pass(5)
        h.claude.stop()
        await h.pass(240)
        h.check(h.noticeHas("Open Claude to finish switching to Beta."), "the notice asks to open Claude: \(h.notice)")
        h.check(h.launches == 1 && h.claude.signInOnDisk() == B, "no rollback while Claude is closed: \(h.claude.actions)")
        h.claude.nameAfter = 3
        h.claude.start()
        await h.run(until: { h.state("Beta") == .inUse }, limit: 300)
        h.check(h.state("Beta") == .inUse && h.claude.chats(in: B).contains("local_one"), "confirmed when Claude next opens: Beta \(String(describing: h.state("Beta"))), holds \(String(describing: h.claude.held)), chats in Beta \(h.claude.chats(in: B)), \(h.claude.actions), \(h.notice)")
    },
    Scenario(pair: "(Between quit and launch, the person opens Claude)", model: "quit once more; a second time rolls back; \"Switching…\"") { h in
        await h.standard()
        h.claude.reopensAfterQuit = 1
        h.click("Beta")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse }, limit: 600)
        h.check(h.claude.actions.contains("person opened"), "the stand-in reopened Claude mid-switch: \(h.claude.actions)")
        h.check(h.quits == 2, "the app quit it once more: \(h.claude.actions)")
        h.check(h.claude.held == B && h.claude.chats(in: B).contains("local_one"), "and carried on to Beta: \(String(describing: h.claude.held)), \(h.notice)")
    },
    Scenario(pair: "(Confirm, Claude restarts by itself)", model: "NewRun then Named: confirm as usual") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        await h.pass(10)
        h.claude.stop(); h.claude.start()
        await h.run(until: { h.state("Beta") == .inUse }, limit: 300)
        h.check(h.state("Beta") == .inUse && h.claude.held == B, "NewRun then Named confirms as usual")
        h.check(h.quits == 1 && h.claude.signInOnDisk() == B, "no rollback: \(h.claude.actions)")
    },
    Scenario(pair: "(Any step, the app is quit, crashed or updated)", model: "\"Finished switching to <T>\" or \"Switch to <T> undone\"") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.quits == 1 && h.claude.pids().isEmpty }, limit: 120)
        h.crashApp()
        await h.tick()
        await h.run(until: { h.claude.held != nil && h.state("Alpha") != .switching && h.state("Beta") != .switching }, limit: 600)
        h.check(h.claude.held == A || h.claude.held == B, "Claude ends signed in to Alpha or Beta: \(String(describing: h.claude.held))")
        h.check(h.noticeHas("Finished switching to Beta") || h.noticeHas("Switch to Beta undone"), "the notice says how it ended: \(h.notice)")
        h.check(h.hasSavedLogin(A) && h.hasSavedLogin(B), "every saved login intact")
        let where_ = h.claude.held == B ? B : A
        h.check(h.claude.chats(in: where_).contains("local_one"), "the chat is in the folder Claude holds")
    },
    Scenario(pair: "(Any, sleep then wake)", model: "meters stale then re-read; no automatic decision until a fresh read") { h in
        await h.standard()
        h.clock.advance(2 * 3600)
        h.usage.fail(B); h.usage.fail(C)
        h.claude.logLimitStop("local_one")
        h.check(h.meterText("Beta") != nil, "after the sleep Beta's meter reads stale before any tick: \(String(describing: h.meterText("Beta")))")
        await h.tick(); await h.settle()
        await h.pass(60)
        h.check(h.claude.actions.isEmpty, "no automatic decision without a fresh read: \(h.claude.actions)")
        h.usage.set(B, fiveHour: 10, resetsAt: h.clock.now().addingTimeInterval(3600))
        await h.run(until: { h.claude.held == B }, limit: 600)
        h.check(h.claude.held == B, "the fresh read makes Beta the target: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Lock held before resume, second switch)", model: "\"Already switching to <T>.\"") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.click("Beta")
        await h.pass(10)
        h.click("Gamma")
        await h.settle()
        h.check(h.noticeHas("Already switching to Beta."), "the second request is refused: \(h.notice)")
    },
    Scenario(pair: "(During resume, second switch)", model: "resume cancelled, chats carried over") { h in
        await h.standard(onScreen: false)
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held == B }, limit: 600)
        await h.pass(90)
        h.check(!h.resumed("local_one"), "the resume is still retrying (box not on screen)")
        h.click("Gamma")
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        await h.run(until: { h.claude.held == C && h.resumed("local_one") }, limit: 600)
        h.check(h.claude.chats(in: C).contains("local_one"), "the chat carried over to Gamma: holds \(String(describing: h.claude.held)), \(h.claude.actions), \(h.notice)")
        h.check(h.resumed("local_one"), "and resumed after Gamma's confirm: \(h.claude.sent)")
    },
    Scenario(pair: "(Resume, message box not on screen)", model: "\"Couldn't resume 1 chat: send it a message.\" after 30 min") { h in
        await h.standard(onScreen: false)
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held == B }, limit: 600)
        // The resume starts after the confirm (a settled hold) and retries for 30 min.
        await h.run(until: { h.noticeHas("Couldn't resume") }, limit: ClaudeTiming.settle + 35 * 60)
        h.check(h.claude.actions.contains { $0.hasPrefix("open ") }, "the chat was opened by its link: \(h.claude.actions)")
        h.check(h.noticeHas("Couldn't resume 1 chat: send it a message."), "after 30 min the chat is named: \(h.notice)")
    },
    Scenario(pair: "(Any, Accessibility not granted)", model: "\"Allow Accessibility so Claude Accounts can switch on its own and resume chats.\"") { h in
        h.claude.trustedAX = false
        await h.standard()
        h.check(h.noticeHas("Allow Accessibility so Claude Accounts can switch on its own and resume chats."), "one line asks for Accessibility: \(h.notice)")
        h.claude.logLimitStop("local_one")
        await h.pass(300)
        h.check(h.claude.actions.isEmpty, "automatic switching is off: \(h.claude.actions)")
        h.check(h.action("Beta") == .switchTo, "manual Switch still offered")
    },
    Scenario(pair: "(Any, Claude not installed)", model: "\"Claude isn't installed.\" Switch hidden") { h in
        await h.standard()
        h.claude.stop(); h.claude.installed = false
        await h.tick()
        h.check(h.noticeHas("Claude isn't installed."), "the notice says so: \(h.notice)")
        h.check(h.action("Beta") == nil && h.action("Gamma") == nil, "Switch is hidden")
        h.check(h.state("Beta") == .ready, "rows and meters still work")
    },
    Scenario(pair: "(Any, Claude never signed in or signed out)", model: "every seat Needs sign-in; Set Up on each row") { h in
        try? h.rows([("Alpha", A), ("Beta", B)])
        h.claude.writeSignIn(nil)
        h.claude.start(); h.make()
        await h.pass(90)
        h.check(h.state("Alpha") == .needsSignIn && h.state("Beta") == .needsSignIn, "every seat Needs sign-in")
        h.check(h.action("Alpha") == .setUp && h.action("Beta") == .setUp, "Set Up on each row")
    },
    Scenario(pair: "(Any, unknown Claude version or shape mismatch)", model: "\"Claude updated to a version this app hasn't checked. Switching on its own is paused.\"") { h in
        h.claude.claudeVersion = "99.0.0"
        await h.standard()
        h.check(h.noticeHas("Claude updated to a version this app hasn't checked. Switching on its own is paused."), "the paused line: \(h.notice)")
        h.claude.logLimitStop("local_one")
        await h.pass(300)
        h.check(h.claude.actions.isEmpty, "no automatic switch on an unrecognised Claude: \(h.claude.actions)")
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        h.check(h.claude.held == B, "manual Switch still works")
    },
    Scenario(pair: "(Any, row renamed or reordered)", model: "display and automatic order only") { h in
        await h.standard()
        h.move("Gamma", by: -1)
        h.rename("Beta", to: "Bee")
        await h.tick()
        h.check(h.rowNames == ["Alpha", "Gamma", "Bee"], "renamed and reordered rows: \(h.rowNames)")
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held != A && h.claude.held != nil }, limit: 600)
        h.check(h.claude.held == C, "the automatic target follows the person's order: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Not in use, row removed)", model: "saved login and row deleted; chats stay") { h in
        h.claude.addChat("beta_chat", in: B, lastActivity: h.clock.now())
        await h.standard()
        h.remove("Beta")
        await h.run(until: { !h.rowNames.contains("Beta") }, limit: 60)
        h.check(!h.rowNames.contains("Beta"), "the row is gone: \(h.rowNames)")
        h.check(!h.hasSavedLogin(B), "its saved login is deleted")
        h.check(h.claude.chats(in: B).contains("beta_chat"), "its chats stay in Claude's folder")
    },
    Scenario(pair: "(In use, row removed)", model: "\"Claude is on an account not in the list.\"") { h in
        await h.standard()
        h.remove("Alpha")
        await h.run(until: { !h.rowNames.contains("Alpha") }, limit: 60)
        h.check(h.claude.held == A, "Claude still holds the pair")
        h.check(h.noticeHas("Claude is on an account not in the list."), "the notice says so: \(h.notice)")
    },
    Scenario(pair: "(Any, two rows with the same name)", model: "\" · <organization>\", then \" (2)\"; never an email") { h in
        let D = StandSeat(4, org: 2)
        try? h.rows([("Work", A), ("Work", D), ("Work", B)], orgNames: ["Team", "Lab", "Team"])
        h.make(); await h.tick()
        h.check(h.rowNames == ["Work · Team", "Work · Lab", "Work · Team (2)"], "unique labels: \(h.rowNames)")
        h.check(!h.rowNames.contains { $0.contains("@") }, "never an email")
    },
    Scenario(pair: "(Any, meter stale or missing)", model: "manual switch allowed, not an automatic target; \"read N min ago\" or \"not read yet\"") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, seat) in [("Beta", B), ("Gamma", C), ("Alpha", A)] { try? await h.savedLogin(n, seat) }
        h.usage.set(A, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3 * 3600))
        h.usage.set(C, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3 * 3600))
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.meterText("Beta") == "not read yet", "Beta's meter reads not read yet: \(String(describing: h.meterText("Beta")))")
        h.check(h.action("Beta") == .switchTo, "manual Switch allowed")
        h.claude.logLimitStop("local_one")
        await h.run(until: { h.claude.held != A && h.claude.held != nil }, limit: 600)
        h.check(h.claude.held == C, "Beta is skipped as an automatic target: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Any, more rows than fit)", model: "cards scroll; title and notice pinned; row in use visible (MenuLayout seam)", body: nil),
    // Section 6 steps, section 8 invariants and section 9 cases.
    Scenario(pair: "(Switch step 2, quit prompt cancelled)", model: "\"Switch cancelled\", nothing changed") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptCancelled
        h.click("Beta")
        await h.run(until: { h.noticeHas("Switch cancelled") }, limit: 120)
        h.check(h.noticeHas("Switch cancelled"), "the notice says so: \(h.notice)")
        h.check(h.claude.held == A && h.claude.signInOnDisk() == A && h.claude.chats(in: A).contains("local_one"), "nothing changed")
    },
    Scenario(pair: "(Switch step 6, Claude names another pair)", model: "roll back; \"<seat> asked for a new sign-in. Back on <S>.\"") { h in
        await h.standard()
        h.claude.stale = [B]
        h.click("Beta")
        await h.run(until: { h.noticeHas("Back on Alpha") && h.claude.held == A }, limit: 600)
        h.check(h.noticeHas("Beta asked for a new sign-in. Back on Alpha."), "the row says why: \(h.notice)")
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "rolled back to Alpha with its chats")
        h.check(h.state("Beta") == .needsSignIn, "Beta Needs sign-in")
        h.check(h.hasSavedLogin(A), "Alpha's saved login intact")
    },
    Scenario(pair: "(Invariant A, faults at every step)", model: "kill app, kill Claude, full disk, failed read: ends signed in to S or T, every saved login intact", body: nil),
    Scenario(pair: "(Any Mac, first launch nothing saved)", model: "first-run screen, then the held seat becomes the first row once settled") { h in
        h.make(); await h.tick()
        h.check(h.firstRun, "the first-run screen shows with no rows")
        h.claude.writeSignIn(A)
        h.claude.start()
        await h.pass(ClaudeTiming.settle + 45)
        h.check(h.rowNames.count == 1 && h.state(h.rowNames.first ?? "") == .inUse, "the held seat became the first row once settled: \(h.rowNames)")
        h.check(h.hasSavedLogin(A), "and its login was saved while Claude ran (13a.2)")
    },
    Scenario(pair: "(Any Mac, one account one organization)", model: "one row, no Switch, automatic stays quiet") { h in
        try? h.rows([("Alpha", A)])
        try? await h.savedLogin("Alpha", A)
        h.usage.set(A, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3600))
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.rowNames == ["Alpha"] && h.action("Alpha") == nil, "one row, no Switch")
        h.claude.logLimitStop("local_one")
        await h.pass(300)
        h.check(h.claude.actions.isEmpty, "no target, no switch")
    },
    Scenario(pair: "(Any Mac, one account several organizations)", model: "a row per organization; switching moves chats") { h in
        let P = StandSeat(1, org: 0)
        try? h.rows([("Alpha", A), ("Alpha", P)], orgNames: ["Team", "Personal"])
        try? await h.savedLogin("Alpha", P)
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.rowNames == ["Alpha · Team", "Alpha · Personal"], "a row per organization: \(h.rowNames)")
        h.click("Alpha · Personal")
        await h.run(until: { h.claude.held == P }, limit: 300)
        h.check(h.claude.held == P && h.claude.chats(in: P).contains("local_one"), "switching moves the chats between them")
    },
    Scenario(pair: "(Any Mac, twenty rows)", model: "cards scroll, compact rows; height within 900 pt and 1400 pt screens", body: nil),
]

@main
enum ScenarioRun {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
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
