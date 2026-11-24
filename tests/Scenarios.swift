import AppKit
import SwiftUI
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
    /// The menu's window and its drawing, kept between openings as the menu bar keeps them. Made
    /// only by a scenario that opens the menu, so no other scenario starts AppKit.
    lazy var menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
    var menuHost: NSHostingView<MenuContent>?
    private(set) var failures: [String] = []
    var checks = 0

    init() throws {
        clock = VirtualClock(start: Date())
        claude = try StandInClaude(clock: clock)
        try World.install(claude, clock: clock)
        usage.clock = clock
        claude.usage = usage
        Usage.install(usage)
    }

    func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures.append(what) }
    }

    /// Writes the person's rows (F9), one per seat, in menu order.
    /// Rows listed in `noOrg` are old rows saved before organizations were kept (13a.4).
    func rows(_ seats: [(String, StandSeat)], orgNames: [String]? = nil, noOrg: Set<Int> = []) throws {
        let list = seats.enumerated().map { i, s in
            AccountRecord(id: "row\(i)", name: s.0, color: "blue", configDir: claude.root.appendingPathComponent("cli/row\(i)").path,
                          keychainService: "test-row\(i)", email: nil, accountUuid: s.1.account,
                          orgName: noOrg.contains(i) ? nil : orgNames?[i] ?? "Team", orgUuid: noOrg.contains(i) ? nil : s.1.org)
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
    /// The app's file work runs on other threads and as real child processes, so this is the one wait
    /// on the product's own response: a short poll, never a sleep. The virtual clock does not move
    /// while it waits. If the app is still working after `settleRounds`, the scenario fails: a check
    /// made then (above all "nothing happened") could pass only because the app's work never ran.
    func settle() async {
        var quiet = 0, last = clock.activity
        for _ in 0..<Harness.settleRounds {
            for _ in 0..<20 { await Task.yield() }
            let now = clock.activity
            // A switch that is not asleep on the clock is mid-step (copying, moving, sqlite3).
            let working = switchInFlight && clock.asleep == 0
            if !working && childProcesses() == 0 && busyThreads() == 0 && now == last { quiet += 1; if quiet >= 3 { return } } else { quiet = 0 }
            last = now
            usleep(200)
        }
        check(false, "the app never went quiet at +\(Int(clock.now().timeIntervalSince(started))) s virtual: children \(childProcesses()), busy threads \(busyThreads()), switch awake \(switchInFlight && clock.asleep == 0), schedule changing \(clock.activity != last)")
    }
    /// Rounds of yields before settle gives up (each round a few hundred microseconds of real time).
    static let settleRounds = 20_000
    /// When the scenario began, on the virtual clock.
    var started: Date { clock.start }

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

    /// `n` rows, one account each, named "Row 1"..."Row n"; Claude holds Row `held` settled.
    func manyRows(_ n: Int, holding held: Int = 1) async {
        let seats = (1...n).map { StandSeat($0, org: 1) }
        try? rows(seats.enumerated().map { ("Row \($0.offset + 1)", $0.element) })
        try? await savedLogin("Row \(held)", seats[held - 1])
        for seat in seats { usage.set(seat, fiveHour: 20, resetsAt: clock.now().addingTimeInterval(3600)) }
        claudeHoldsSettled(); make()
        await tick(); await settle()
    }

    func noticeHas(_ text: String) -> Bool { notice.contains { $0.contains(text) } }
    var quits: Int { claude.actions.filter { $0 == "quit" }.count }
    var launches: Int { claude.actions.filter { $0 == "launch" }.count }
    func resumed(_ chat: String) -> Bool { claude.sent.contains("\(chat) resume") }

    /// A switch to Beta brings a stopped chat that Claude doesn't show, so its resume keeps trying.
    /// `wait` seconds after the chat is opened, the person switches to Gamma: the chat must carry
    /// over and be resumed there, wherever the old resume stood (section 6, step 7).
    func secondSwitchDuringResume(after wait: TimeInterval) async {
        await standard(onScreen: false)
        claude.logLimitStop("local_one", seatReadsFull: true)
        await run(until: { claude.actions.contains { $0.hasPrefix("open ") } }, limit: 900)
        await pass(wait)
        check(claude.held == B && !resumed("local_one"), "Beta's resume is still trying (the chat isn't on screen): \(claude.actions)")
        click("Gamma")
        claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        await run(until: { claude.held == C && resumed("local_one") }, limit: 600)
        check(claude.chats(in: C).contains("local_one"), "the chat carried over to Gamma: holds \(String(describing: claude.held)), \(claude.actions), \(notice)")
        check(resumed("local_one"), "and resumed after Gamma's confirm: \(claude.sent)")
    }

    /// Personal and organization seats interleaved down the menu: Home is not set up and Lab is
    /// out; the rest are Ready with fresh readings. Claude holds `held` settled with one chat.
    func mixedSeats(holding held: String, order: SwitchOrder?) async {
        try? rows(mixed.map { ($0.0, $0.1) }, orgNames: mixed.map(\.2))
        // The held seat's login is saved last, so its sign-in is the one left in Claude's files.
        for (name, seat, _) in mixed.filter({ $0.0 != held }) + mixed.filter({ $0.0 == held }) where name != "Home" {
            try? await savedLogin(name, seat)
        }
        for (name, seat, _) in mixed { usage.set(seat, fiveHour: name == "Lab" ? 100 : 20, resetsAt: clock.now().addingTimeInterval(3 * 3600)) }
        let seat = mixed.first { $0.0 == held }!.1
        claude.addChat("local_one", in: seat, lastActivity: clock.now())
        claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        claudeHoldsSettled(); make()
        if let order { store.settings.switchOrder = order }
        await tick(); await settle()
    }

    /// The row the menu marks Next.
    var nextRow: String? { store.seats.first(where: \.isNext)?.name }
}

/// Rows in menu order for the switch-order scenarios: (name, seat, organization name).
let mixed: [(String, StandSeat, String)] = [
    ("Work", StandSeat(1, org: 1), "Team"),
    ("Home", StandSeat(2, org: 0), "two@example.com's Organization"),
    ("Lab", StandSeat(3, org: 3), "Lab"),
    ("Side", StandSeat(4, org: 0), "four@example.com's Organization"),
    ("Studio", StandSeat(5, org: 5), "Studio"),
    ("Den", StandSeat(6, org: 0), "six@example.com's Organization"),
]

/// The part of section 8's one line every shape miss shares, whatever names the cause.
let pausedLine = "Switching on its own is paused."

/// The menu's measures, as the drawn menu takes them (section 11).
struct MenuMeasure { let height, content, pinned, margin, row: CGFloat }

/// The model's constants (section 5), as the scenarios assume them.
enum ClaudeTiming {
    static let settle: TimeInterval = 60
    static let meterEvery: TimeInterval = 5 * 60
    /// A read is scheduled for each reset time plus this (section 4).
    static let meterAfterReset: TimeInterval = 60
    /// Resume: retry every 60 s for 30 min, then name the chat (section 5, resumeFor).
    static let resumeFor: TimeInterval = 30 * 60
    static let resumeEvery: TimeInterval = 60
    /// "At once" for a refusal (decision 2): a fixed bound, not the app's tick. Claude refuses 4 to
    /// 21 s after it names the organization (section 5), so a refusal held back until the hold's
    /// 60 s settle shows at least 39 s late; 20 s catches that whatever the app's tick is.
    static let refusalShows: TimeInterval = 20
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
        // 13a.2: Claude writes its cookies as it quits, so the save must copy them after the quit.
        let quitMark = h.claude.quitMarks[A]
        h.check(quitMark != nil && h.savedMark(A) == quitMark, "Alpha's saved login holds the cookies Claude wrote at its quit (\(String(describing: quitMark))), not an earlier copy: \(String(describing: h.savedMark(A)))")
    },
    Scenario(pair: "(Needs sign-in, Claude refuses (A, O))", model: "7: Refused for (A, O) only; other accounts' seats in O unaffected") { h in
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        try? await h.savedLogin("Gamma", C)
        try? await h.savedLogin("Alpha", A)
        h.claude.stale = [A]
        h.make()
        h.claude.start()
        // Decision 2: a refusal counts at once; the 60 s settle is only for saving and blaming.
        await h.pass(h.claude.nameAfter + h.claude.refuseAfter + ClaudeTiming.refusalShows)
        h.check(h.state("Alpha") == .needsSignIn && h.action("Alpha") == .setUp, "Alpha shows Needs sign-in with Set Up within \(Int(ClaudeTiming.refusalShows)) s of the refusal: \(String(describing: h.state("Alpha")))")
        await h.pass(ClaudeTiming.settle)
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
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B && h.resumed("local_one") }, limit: 600)
        h.check(h.claude.held == B, "the automatic switch went to Beta, next down the menu: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.claude.chats(in: B).contains("local_one"), "the stopped chat moved to Beta")
        h.check(h.resumed("local_one"), "the stopped chat got one \"resume\": \(h.claude.sent)")
        h.check(h.claude.sent.filter { $0.hasPrefix("local_one") }.count == 1, "exactly one resume")
        h.check(h.state("Alpha") == .out, "Alpha shows Out after its settled stop: \(String(describing: h.state("Alpha")))")
        await h.run(until: { !h.claude.notifications.isEmpty }, limit: 120)
        // Recorded as "<title>: <body>": the person reads spec 7's line once, the title never repeated.
        h.check(h.claude.notifications == ["Switched to Beta: Alpha is out. 1 chat resumed."], "the one notification reads \"Switched to <T>: <S> is out. N chats resumed.\": \(h.claude.notifications)")
    },
    Scenario(pair: "(In use settling, limit stop before settle)", model: "not counted against S; nothing typed into the refused chat while S reads with room; nothing shown") { h in
        await h.standard()
        h.click("Beta")
        await h.run(until: { h.claude.held == B }, limit: 300)
        await h.pass(10)
        // A stop logged before Beta's hold settled is not Beta's: Beta's meter still reads with room.
        h.claude.logLimitStop("local_one", seatReadsFull: false)
        await h.pass(300)
        h.check(h.claude.held == B, "no automatic switch away from Beta: \(String(describing: h.claude.held))")
        h.check(h.quits == 1, "only the manual switch quit Claude: \(h.claude.actions)")
        h.check(h.state("Beta") == .inUse && h.state("Beta") != .out, "Beta In use, not counted Out")
        h.check(h.claude.sent.isEmpty, "nothing typed into the chat Claude refused while Beta reads with room: \(h.claude.sent)")
    },
    Scenario(pair: "(In use, turn ended then 100% read)", model: "4: a turn that ended is never a stop: its end asks for a reading, and a full one quits nothing") { h in
        await h.standard()
        let before = h.usage.reads.count
        // A turn ends some time after the last reading (Claude's log has whole seconds).
        await h.pass(10)
        h.claude.logTurnEnded("local_one")
        h.usage.set(A, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        await h.pass(5 * 60)
        h.check(h.usage.reads.dropFirst(before).contains(A.tag), "the turn's end triggered a read of Alpha's meter")
        h.check(h.claude.held == A && h.claude.actions.isEmpty && h.claude.sent.isEmpty, "no quit, no switch, nothing typed: \(h.claude.actions), typed \(h.claude.sent)")
    },
    Scenario(pair: "(Every seat out, out signal)", model: "\"Every seat is out. Chats resume when <seat> resets at <time>.\"") { h in
        await h.standard()
        let reset = h.clock.now().addingTimeInterval(2 * 3600)
        for s in [A, B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        // The app knows only what it has read: let its next scheduled read see every seat out.
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(120)
        h.check(h.claude.actions.isEmpty, "no switch when every seat is out: \(h.claude.actions)")
        h.check(h.noticeHas("Every seat is out. Chats resume when") && h.noticeHas(DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)), "the waiting line names the reset: \(h.notice)")
    },
    Scenario(pair: "(Every seat out, a second stop in the same wait)", model: "13a.8: one notification per wait, \"Every seat is out\"") { h in
        await h.standard()
        h.claude.addChat("local_two", in: A, lastActivity: h.clock.now())
        let reset = h.clock.now().addingTimeInterval(2 * 3600)
        for s in [A, B, C] { h.usage.set(s, fiveHour: 100, resetsAt: reset) }
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(120)
        h.claude.logLimitStop("local_two", seatReadsFull: true)
        await h.pass(3 * ClaudeTiming.meterEvery)
        let posted = h.claude.notifications.filter { $0.hasPrefix("Every seat is out") }
        h.check(posted.count == 1, "one notification for the whole wait: \(h.claude.notifications)")
        let at = DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
        h.check(posted.first.map { $0.hasPrefix("Every seat is out: Chats resume when ") && $0.hasSuffix(" resets at \(at).") } == true,
                "it reads \"Every seat is out: Chats resume when <seat> resets at <time>.\", the title once: \(posted)")
        h.check(h.claude.actions.isEmpty, "no switch: \(h.claude.actions)")
    },
    Scenario(pair: "(One seat out, out signal)", model: "13a.8: \"<seat> is out. Chats resume when it resets at <time>.\" no switch, no notification") { h in
        try? h.rows([("Alpha", A)])
        try? await h.savedLogin("Alpha", A)
        let reset = h.clock.now().addingTimeInterval(2 * 3600)
        h.usage.set(A, fiveHour: 100, resetsAt: reset)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(300)
        let at = DateFormatter.localizedString(from: reset, dateStyle: .none, timeStyle: .short)
        h.check(h.noticeHas("Alpha is out. Chats resume when it resets at \(at)."), "the one-seat waiting line: \(h.notice)")
        h.check(h.claude.notifications.isEmpty, "no notification with one seat: \(h.claude.notifications)")
        h.check(h.claude.actions.isEmpty, "no switch attempt: \(h.claude.actions)")
    },
    Scenario(pair: "(Old row with no organization, click Set Up)", model: "13a.4: shows Needs sign-in, never dropped; Set Up confirms on the account in any organization and fills it in; no chats move") { h in
        try? h.rows([("Alpha", A), ("Beta", B)], noOrg: [1])
        try? await h.savedLogin("Alpha", A)
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claudeHoldsSettled(); h.make(); await h.tick()
        h.check(h.rowNames.contains("Beta"), "the row with no organization is kept: \(h.rowNames)")
        h.check(h.state("Beta") == .needsSignIn && h.action("Beta") == .setUp, "it shows Needs sign-in with Set Up: \(String(describing: h.state("Beta")))")
        h.claude.signsInAs = B
        h.click("Beta")
        await h.run(until: { h.claude.held == B && h.hasSavedLogin(B) && !h.switchInFlight }, limit: 900)
        h.check(h.claude.held == B && h.state("Beta") == .inUse, "Set Up confirmed on Beta's account: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.hasSavedLogin(B), "the login is saved under the organization Claude named")
        h.check(h.claude.chats(in: A).contains("local_one") && !h.claude.chats(in: B).contains("local_one"), "no chats moved, since the target folder was unknown")
        h.check(h.hasSavedLogin(A), "Alpha's saved login is intact")
    },
    Scenario(pair: "(Waiting, reset time passes)", model: "read the meter, then resume in place or switch") { h in
        await h.standard()
        let now = h.clock.now()
        // Beta's reset falls off the 5 min background grid, so only the read scheduled at its
        // reset + 1 min sees the room. An app that switches on the old 100% reading once its
        // resetsAt is behind never reads Beta between the reset and the quit.
        let resetB = now.addingTimeInterval(637)
        h.usage.set(A, fiveHour: 100, resetsAt: now.addingTimeInterval(7200))
        h.usage.set(B, fiveHour: 100, resetsAt: resetB)
        h.usage.set(C, fiveHour: 100, resetsAt: now.addingTimeInterval(7200))
        await h.pass(ClaudeTiming.meterEvery + 5)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(60)
        h.check(h.noticeHas("Every seat is out"), "waiting first: \(h.notice)")
        let usage = h.usage
        h.clock.after(resetB.timeIntervalSince(h.clock.now()) - 5) { usage.set(B, fiveHour: 0, resetsAt: resetB.addingTimeInterval(5 * 3600)) }
        await h.run(until: { h.claude.held == B && h.resumed("local_one") }, limit: 1200)
        h.check(h.claude.held == B, "Beta's reset read gives it room and the app switches: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(h.resumed("local_one"), "the waiting chat is resumed")
        let at = { (d: Date?) in d.map { "+\(Int($0.timeIntervalSince(now))) s" } ?? "never" }
        let firstQuit = h.claude.at("quit").first
        h.check(firstQuit.map { $0 >= resetB } == true, "the switch starts after Beta resets: first quit \(at(firstQuit)), reset \(at(resetB))")
        h.check(firstQuit.map { q in h.usage.readsOf(B).contains { $0 >= resetB && $0 <= q } } == true,
                "Beta's meter is read after its reset and before the first quit: reads \(h.usage.readsOf(B).map { at($0) }), first quit \(at(firstQuit))")
    },
    Scenario(pair: "(Not waiting, reset time passes)", model: "meter re-read, row changes") { h in
        await h.standard()
        let now = h.clock.now()
        // The reset falls off the 5 min background grid (reads at +300, +600), and so does its read.
        let reset = now.addingTimeInterval(430), due = reset.addingTimeInterval(ClaudeTiming.meterAfterReset)
        h.usage.set(B, fiveHour: 100, resetsAt: reset)
        await h.pass(400)
        h.check(h.state("Beta") == .out, "Beta Out before its reset: \(String(describing: h.state("Beta")))")
        // After the reset the five-hour meter is empty but the weekly one is now full: only a read
        // shows that. An app that lets Out end by the clock alone shows Ready instead.
        h.usage.set(B, fiveHour: 0, weekly: 100, resetsAt: reset.addingTimeInterval(5 * 3600))
        await h.run(until: { h.usage.readsOf(B).contains { $0 >= due } }, limit: 120)
        let read = h.usage.readsOf(B).first { $0 >= due }
        h.check(read.map { $0.timeIntervalSince(due) <= Store.tickEvery } == true, "Beta is read at its reset + 1 min, not on the next background read: read at \(read.map { "+\(Int($0.timeIntervalSince(now))) s" } ?? "never"), due +\(Int(due.timeIntervalSince(now))) s")
        await h.settle()
        h.check(h.percents("Beta") == [0, 100], "the meters change to the new reading: \(h.percents("Beta"))")
        h.check(h.state("Beta") == .out, "the new reading keeps Beta Out (weekly full): \(String(describing: h.state("Beta")))")
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
        // Decision 2: the refusal and the fall-back show at once, not after a settle.
        await h.pass(h.claude.nameAfter + h.claude.refuseAfter + ClaudeTiming.refusalShows)
        h.check(h.state("Alpha · Home") == .inUse, "the personal row is In use within \(Int(ClaudeTiming.refusalShows)) s of the refusal: \(String(describing: h.state("Alpha · Home"))), rows \(h.rowNames)")
        h.check(h.state("Alpha · Team") == .needsSignIn, "the refused row Needs sign-in within \(Int(ClaudeTiming.refusalShows)) s of the refusal: \(String(describing: h.state("Alpha · Team")))")
        await h.pass(ClaudeTiming.settle)
        h.check(h.state("Alpha · Home") == .inUse && h.state("Alpha · Team") == .needsSignIn, "and both stay so once the hold settles")
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
        // A short sleep: the readings taken before it are minutes old, young enough to look fresh
        // by age alone. A settled limit stop lands while the Mac sleeps; the reads after the wake fail.
        h.check(h.meterText("Beta") == nil, "before the sleep Beta's meter is fresh: \(String(describing: h.meterText("Beta")))")
        h.clock.advance(3 * 60)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        h.usage.fail(B); h.usage.fail(C)
        h.wake()
        await h.tick(); await h.settle()
        h.check(h.meterText("Beta") != nil, "the wake marks Beta's meter stale, and a failed read leaves it so: \(String(describing: h.meterText("Beta")))")
        await h.pass(ClaudeTiming.meterEvery)
        h.check(h.claude.actions.isEmpty, "no switch on a pre-sleep reading, and none until a fresh read: \(h.claude.actions)")
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
    Scenario(pair: "(During resume, waiting for the chat, second switch)", model: "resume cancelled, chats carried over") { h in
        await h.secondSwitchDuringResume(after: ResumeRule.readyWait / 2)
    },
    Scenario(pair: "(During resume, between tries, second switch)", model: "resume cancelled, chats carried over") { h in
        await h.secondSwitchDuringResume(after: ResumeRule.readyWait + ResumeRule.retryEvery / 2)
    },
    Scenario(pair: "(Resume, message box not on screen)", model: "\"Couldn't resume 1 chat: send it a message.\" after 30 min") { h in
        await h.standard(onScreen: false)
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held == B }, limit: 600)
        // The resume starts after the confirm (a settled hold) and retries for 30 min.
        await h.run(until: { h.noticeHas("Couldn't resume") }, limit: ClaudeTiming.settle + 35 * 60)
        let gaveUp = h.clock.now()
        h.check(h.claude.actions.contains { $0.hasPrefix("open ") }, "the chat was opened by its link: \(h.claude.actions)")
        h.check(h.noticeHas("Couldn't resume 1 chat: send it a message."), "after 30 min the chat is named: \(h.notice)")
        // Not sooner: the app keeps trying for the whole 30 min (resumeFor) before it names the chat.
        let tried = h.claude.opened.first.map { gaveUp.timeIntervalSince($0) } ?? 0
        h.check(tried >= ClaudeTiming.resumeFor - ClaudeTiming.resumeEvery && tried <= ClaudeTiming.resumeFor + 2 * ClaudeTiming.resumeEvery,
                "it gives up 30 min after it first opened the chat, not sooner: after \(Int(tried / 60)) min")
        h.check(Limits.resumeFor == ClaudeTiming.resumeFor && Limits.resumeEvery == ClaudeTiming.resumeEvery,
                "resumeFor is 30 min, retried every 60 s: \(Limits.resumeFor) s, \(Limits.resumeEvery) s")
    },
    Scenario(pair: "(Any, Accessibility not granted)", model: "\"Allow Accessibility so Claude Accounts can switch on its own and resume chats.\"") { h in
        h.claude.trustedAX = false
        await h.standard()
        h.check(h.noticeHas("Allow Accessibility so Claude Accounts can switch on its own and resume chats."), "one line asks for Accessibility: \(h.notice)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
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
    // Section 8: a shape the app does not recognise. Each one turns automatic switching off with one
    // line, leaves manual Switch working where it is safe, and clears once the shape is seen whole.
    Scenario(pair: "(Shape missing, no Named line after a launch)", model: "8: automatic off with one line; manual Switch kept; clears when Claude names a seat again") { h in
        await h.standard()
        h.claude.namedLineChanged = true
        h.click("Beta")
        await h.run(until: { !h.switchInFlight }, limit: 1800)
        // Spec 11: the rollback's reason is a failure the person must act on, so it holds the one
        // notice over the pause; the paused line shows once it is closed.
        h.check(h.notice == ["Beta didn't open in time. Back on Alpha."], "the rollback's reason holds the notice: \(h.notice)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas(pausedLine), "a launch with no Named line pauses automatic switching, in one line, once the failure is closed: \(h.notice)")
        await h.run(until: { h.claude.held != nil }, limit: 60)
        h.check(h.claude.held == A && h.claude.chats(in: A).contains("local_one"), "confirm could not read the log, so it rolled back to Alpha with the chat: \(String(describing: h.claude.held))")
        h.check(h.hasSavedLogin(A) && h.hasSavedLogin(B), "every saved login intact")
        let quits = h.quits
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(300)
        h.check(h.quits == quits, "no automatic switch while the shape is missing: \(h.claude.actions)")
        h.check(h.action("Beta") == .switchTo, "manual Switch still offered")
        h.claude.namedLineChanged = false
        h.click("Beta")
        await h.run(until: { h.claude.held == B && h.state("Beta") == .inUse && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B, "manual Switch works once Claude names the seat: \(String(describing: h.claude.held)), \(h.notice)")
        h.check(!h.noticeHas(pausedLine), "the Named line seen whole clears the pause: \(h.notice)")
        await h.pass(ClaudeTiming.settle + 5)
        h.usage.set(B, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != nil && h.claude.held != B }, limit: 900)
        h.check(h.claude.held == A || h.claude.held == C, "automatic switching is back on: \(String(describing: h.claude.held)), \(h.claude.actions)")
    },
    Scenario(pair: "(Shape missing, quit prompt without Quit anyway)", model: "8: automatic off with one line, nothing changed; a person's Switch still works; clears when the prompt shows its button") { h in
        await h.standard()
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.promptHasQuitButton = false
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.quits > 0 && !h.switchInFlight }, limit: 1800)
        // Spec 11: the automatic switch's failure holds the one notice over the pause, as a manual one's does.
        h.check(h.notice == ["Claude didn't quit, so nothing changed."], "the failed quit holds the notice: \(h.notice)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas(pausedLine), "a prompt without its button pauses automatic switching, in one line, once the failure is closed: \(h.notice)")
        h.check(h.claude.held == A && !h.claude.pids().isEmpty && h.claude.chats(in: A).contains("local_one"), "nothing changed: Claude still runs on Alpha with the chat")
        h.check(!h.claude.actions.contains { $0.hasPrefix("pressed") }, "the app never pressed anything on a prompt it could not recognise: \(h.claude.actions)")
        let quits = h.quits
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(600)
        h.check(h.quits == quits, "no automatic switch while the shape is missing: \(h.claude.actions)")
        // A person answers the prompt themselves, so a manual Switch is safe.
        h.claude.quitBehaviour = .promptThenQuit
        h.click("Beta")
        await h.run(until: { h.claude.held == B && !h.switchInFlight }, limit: 600)
        h.check(h.claude.held == B, "manual Switch still works: \(String(describing: h.claude.held)), \(h.notice)")
        // Spec 11: a failure the person must act on outranks the pause for the one notice slot.
        h.check(h.notice == ["Couldn't resume 1 chat: send it a message."], "the chat the switch could not resume holds the notice: \(h.notice)")
        await h.pass(ClaudeTiming.settle + 5)
        h.usage.set(B, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        let quitsOnBeta = h.quits
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(600)
        h.check(h.quits == quitsOnBeta && h.claude.held == B, "no automatic switch while the failure line holds the slot: \(h.claude.actions)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.notice.first == "\(pausedLine) Claude's quit prompt has no Quit anyway button.", "a prompt still without its button shows the pause once that line is closed: \(h.notice)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(600)
        h.check(h.quits == quitsOnBeta && h.claude.held == B, "still no automatic switch under the paused line: \(h.claude.actions)")
        h.claude.promptHasQuitButton = true
        h.click("Alpha")
        await h.run(until: { h.claude.held == A && !h.switchInFlight }, limit: 600)
        h.check(!h.noticeHas(pausedLine), "the prompt seen with its button clears the pause: \(h.notice)")
        h.claude.quitBehaviour = .promptUnanswered
        await h.pass(ClaudeTiming.settle + 5)
        h.usage.set(A, fiveHour: 100, resetsAt: h.clock.now().addingTimeInterval(3600))
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != nil && h.claude.held != A }, limit: 900)
        h.check(h.claude.actions.contains("pressed \(ClaudeUI.quitAnyway)") && h.claude.held != A, "automatic switching is back on: \(h.claude.actions)")
    },
    Scenario(pair: "(Shape missing, cookie format changed)", model: "8: automatic off with one line; no login saved or loaded in a format the app has not seen; clears when the format is the recorded one") { h in
        await h.standard()
        h.claude.cookieSchema = "99"
        h.claude.writeSignIn(A)
        await h.pass(ClaudeTiming.meterEvery)
        let savedB = h.savedAt(B)
        h.click("Beta")
        await h.run(until: { !h.switchInFlight }, limit: 900)
        // Spec 11: the switch's failure holds the one notice over the pause until it is closed.
        h.check(h.notice == ["Couldn't switch to Beta. Claude's sign-in file is in a format this app doesn't know."], "the failed switch says why: \(h.notice)")
        h.store.closeNotice()
        await h.tick()
        h.check(h.noticeHas(pausedLine), "an unseen cookie format pauses automatic switching, in one line, once the failure is closed: \(h.notice)")
        await h.run(until: { h.claude.held != nil }, limit: 60)
        h.check(h.claude.held == A && h.claude.signInOnDisk() == A, "nothing is loaded in an unseen format, so Claude is back on Alpha: holds \(String(describing: h.claude.held)), running \(!h.claude.pids().isEmpty), \(h.claude.actions)")
        h.check(h.hasSavedLogin(A) && h.savedAt(B) == savedB, "every saved login intact, Beta's untouched")
        let quits = h.quits
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.pass(300)
        h.check(h.quits == quits, "no automatic switch while the format is unseen: \(h.claude.actions)")
        h.claude.cookieSchema = ClaudeFiles.cookieSchemaVersion
        h.claude.writeSignIn(h.claude.held)
        await h.pass(ClaudeTiming.meterEvery)
        h.check(!h.noticeHas(pausedLine), "the recorded format seen again clears the pause: \(h.notice)")
    },
    Scenario(pair: "(Any, row renamed or reordered)", model: "display and automatic order only") { h in
        await h.standard()
        h.move("Gamma", by: -1)
        h.rename("Beta", to: "Bee")
        await h.tick()
        h.check(h.rowNames == ["Alpha", "Gamma", "Bee"], "renamed and reordered rows: \(h.rowNames)")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != A && h.claude.held != nil }, limit: 600)
        h.check(h.claude.held == C, "the automatic target follows the person's order: \(String(describing: h.claude.held))")
    },
    // Switch order: the automatic target and the menu's Next mark follow the person's choice.
    // Down the menu from Work, Home is not set up, Lab is out, then Side (personal), Studio and Den.
    Scenario(pair: "(Switch order never set, seat in use out)", model: "4: the first Ready seat down the menu, wrapping round, as before the setting") { h in
        await h.mixedSeats(holding: "Work", order: nil)
        h.check(h.store.settings.switchOrder == .topToBottom, "an untouched setting is Top to Bottom")
        h.check(h.nextRow == "Side", "Next marks the first Ready seat down the menu, past Home and Lab: \(String(describing: h.nextRow))")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != nil && h.claude.held != mixed[0].1 }, limit: 600)
        h.check(h.claude.held == mixed[3].1, "the automatic switch goes to Side: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Switch order personal first, seat in use out)", model: "4: personal seats first, in menu order, wrapping round; out and not set up skipped") { h in
        await h.mixedSeats(holding: "Den", order: .personalFirst)
        h.check(h.nextRow == "Side", "Next passes Work, the first Ready seat down the menu, and Home, not set up, for Side: \(String(describing: h.nextRow))")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != nil && h.claude.held != mixed[5].1 }, limit: 600)
        h.check(h.claude.held == mixed[3].1, "the automatic switch goes where Next pointed, Side: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Switch order organizations first, seat in use out)", model: "4: organization seats first, in menu order; out and not set up skipped") { h in
        await h.mixedSeats(holding: "Work", order: .organizationsFirst)
        h.check(h.nextRow == "Studio", "Next passes Side, the first Ready seat down the menu, and Lab, out, for Studio: \(String(describing: h.nextRow))")
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != nil && h.claude.held != mixed[0].1 }, limit: 600)
        h.check(h.claude.held == mixed[4].1, "the automatic switch goes where Next pointed, Studio: \(String(describing: h.claude.held))")
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
        // The app runs on past a background read and a settle: 13a.6 adds the held seat on its own
        // only when there are no rows.
        await h.pass(ClaudeTiming.meterEvery + ClaudeTiming.settle)
        h.check(!h.rowNames.contains("Alpha"), "the held seat is not added back while other rows remain: \(h.rowNames)")
        h.check(h.claude.held == A, "Claude still holds the pair")
        h.check(h.noticeHas("Claude is on an account not in the list."), "the notice says so: \(h.notice)")
        h.check(h.store.notice?.action == .addSeat, "the notice offers Add (13a.6): \(String(describing: h.store.notice?.action))")
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
        h.claude.logLimitStop("local_one", seatReadsFull: true)
        await h.run(until: { h.claude.held != A && h.claude.held != nil }, limit: 600)
        h.check(h.claude.held == C, "Beta is skipped as an automatic target: \(String(describing: h.claude.held))")
    },
    Scenario(pair: "(Any, more rows than fit)", model: "cards scroll; title and notice pinned; row in use visible (MenuLayout seam)") { h in
        // The row in use sits low, past what the menu shows unscrolled, so "visible on open" needs the scroll.
        await h.manyRows(30, holding: 25)
        let m = h.menu(screen: 600)
        h.check(m.height <= 600 - m.margin, "the menu stays on a 600 pt screen: \(m.height)")
        h.check(m.content > m.height, "the cards scroll: they need \(m.content), the menu is \(m.height)")
        h.check(m.height - m.pinned >= 3 * m.row, "the pinned title bar and notice leave room for at least three rows")
        h.check(h.state("Row 25") == .inUse, "Row 25 is in use: \(String(describing: h.state("Row 25")))")
        let top = h.cardTop("Row 25")
        h.check(top.map { $0 > m.height - m.pinned } == true, "Row 25's card starts below the unscrolled cards: at \(String(describing: top)) of a \(m.height - m.pinned) pt viewport")
        h.check(h.openScrollCard?.contains("Row 25") == true, "the menu opens scrolled to Row 25's card: it scrolls to \(String(describing: h.openScrollCard))")
    },
    Scenario(pair: "(Menu, a row opened to both meters)", model: "10: a row's name or chevron opens it to both meters; it stays open through refreshes, closing the menu and a relaunch, until the person closes it") { h in
        let delta1 = StandSeat(4, org: 1), delta2 = StandSeat(4, org: 2)
        let all = [("Alpha", A), ("Beta", B), ("Gamma", C), ("Delta", delta1), ("Delta", delta2)]
        try? h.rows(all, orgNames: ["Team", "Team", "Team", "Studio", "Labs"])
        // Alpha's login is saved last, so Claude opens on it.
        for (n, seat) in all.dropFirst() + all.prefix(1) { try? await h.savedLogin(n, seat) }
        let reset = h.clock.now().addingTimeInterval(3 * 3600)
        for seat in [A, B, delta1, delta2] { h.usage.set(seat, fiveHour: 20, resetsAt: reset) }
        h.usage.set(C, fiveHour: 100, resetsAt: reset)
        h.claudeHoldsSettled(); h.make(); await h.tick(); await h.settle()
        h.check(h.state("Alpha") == .inUse && h.state("Gamma") == .out, "setup: Alpha in use, Gamma out: \(String(describing: h.state("Alpha"))), \(String(describing: h.state("Gamma")))")
        h.check(!h.hasChevron("Alpha"), "the row in use, which always shows its meters, has no chevron")
        h.check(["Beta", "Gamma", "Delta · Studio", "Delta · Labs"].allSatisfy(h.hasChevron), "every other read row has one: a seat alone, an out seat, and organizations in an account")

        await h.openMenu()
        h.menuShowsOpened([], "a new seat starts closed")
        h.pressName("Beta")
        h.menuShowsOpened(["Beta"], "clicking Beta's name opens it")
        await h.pass(3 * h.tickEvery)
        h.menuShowsOpened(["Beta"], "it stays open through three refresh ticks")
        h.closeMenu(); await h.openMenu()
        h.menuShowsOpened(["Beta"], "and through closing and reopening the menu")
        h.pressName("Gamma"); h.pressName("Delta · Labs")
        h.menuShowsOpened(["Beta", "Gamma", "Delta · Labs"], "several rows stay open at once, the out seat and an organization among them")
        h.pressAccount("Delta · Labs")
        h.menuShowsOpened(["Beta", "Gamma"], "folding Delta's organizations hides its opened one")

        h.closeMenu(); h.crashApp(); await h.tick(); await h.settle(); await h.openMenu()
        h.menuShowsOpened(["Beta", "Gamma"], "a relaunch keeps the opened rows and the folded account")
        h.pressAccount("Delta · Labs")
        h.menuShowsOpened(["Beta", "Gamma", "Delta · Labs"], "showing Delta again shows Labs still open")
        h.pressName("Beta")
        h.menuShowsOpened(["Gamma", "Delta · Labs"], "clicking Beta's name again closes it")

        // A seat that goes is forgotten, so the same seat added again starts closed.
        h.remove("Gamma")
        await h.run(until: { !h.rowNames.contains("Gamma") }, limit: 60)
        try? h.rows(all, orgNames: ["Team", "Team", "Team", "Studio", "Labs"])
        await h.run(until: { h.hasChevron("Gamma") }, limit: 600)
        h.menuShowsOpened(["Delta · Labs"], "Gamma, added again and read, starts closed")
    },
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
        h.claude.logLimitStop("local_one", seatReadsFull: true)
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
    Scenario(pair: "(Any Mac, twenty rows)", model: "cards scroll, compact rows; height within 900 pt and 1400 pt screens") { h in
        await h.manyRows(20)
        let short = h.menu(screen: 900), tall = h.menu(screen: 1400)
        // The cards scroll only when they need more than the screen gives; compact rows may fit.
        h.check(short.height <= 900 - short.margin && short.height == min(short.content, 900 - short.margin), "on 900 pt the menu fits, scrolling only past the screen: \(short.height) of \(short.content)")
        h.check(tall.height <= 1400 - tall.margin, "on 1400 pt the menu fits: \(tall.height)")
        // Compact: every row but the one in use is one line; the one in use adds at most three meter lines.
        h.check(tall.content <= tall.pinned + 20 * tall.row + 19 * 6 + 3 * 18 + 6, "twenty compact rows: \(tall.content)")
    },
]

@main
enum ScenarioRun {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var passed = 0, failed = 0, pending = 0
        // One pair by its exact name (each.sh), else every pair whose name contains the argument.
        let only = CommandLine.arguments.dropFirst().first
        let all = scenarios + bugScenarios + faultScenarios + gapScenarios
        if only == "--list" { all.forEach { print($0.pair) }; exit(0) }
        let exact = all.contains { $0.pair == only }
        for s in all where only == nil || (exact ? s.pair == only : s.pair.contains(only!)) {
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
