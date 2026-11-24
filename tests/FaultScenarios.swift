import Foundation
import Darwin

// Invariants A and B (model, section 8) under injected faults at every step of the journaled
// switch (section 6). Each step crossed with each fault is its own pair. The fault strikes once,
// on the switch's own task, as its step begins (World.willStep). A full disk or a failed read
// lasts until the next step begins or the undo starts, so each fault stays inside its step.
// Then faults inside a step (midStepFaultScenarios) and on the automatic switch (autoFaultScenarios).

let faultScenarios = stepFaultScenarios + midStepFaultScenarios + autoFaultScenarios

/// The faults section 8 names.
enum Fault: String, CaseIterable, Sendable {
    case killApp = "kill the app", killClaude = "kill Claude", fullDisk = "full disk", failedRead = "a failed read"
}

/// One step of the switch, by the name the app's willStep gives it.
struct FaultStep: Sendable {
    let hook: String
    let name: String
    var setUp = false
    /// Before load an interrupted switch is undone; from load on it is finished (section 6, Recovery).
    var finishes: Bool { ["load", "launch", "confirm"].contains(hook) }
    /// Claude runs during the quit and from the launch on; between them it is already closed.
    var claudeRuns: Bool { ["quit", "launch", "confirm"].contains(hook) }
}

let faultSteps = [
    FaultStep(hook: "quit", name: "quit"), FaultStep(hook: "backUp", name: "back up"),
    FaultStep(hook: "save", name: "save"), FaultStep(hook: "move", name: "move"),
    FaultStep(hook: "load", name: "load"), FaultStep(hook: "load", name: "clear", setUp: true),
    FaultStep(hook: "launch", name: "launch"), FaultStep(hook: "confirm", name: "confirm"),
]

/// Every step with every fault that can strike there. Killing Claude needs Claude running.
let stepFaultScenarios: [Scenario] = faultSteps.flatMap { step in
    Fault.allCases.filter { $0 != .killClaude || step.claudeRuns }.map { fault in
        Scenario(pair: "(\(step.setUp ? "Set Up" : "Switch") at \(step.name), \(fault.rawValue))",
                 model: "8 A: ends on the seat it left or the target, saved logins intact, chats with the seat Claude holds; 8 B: nothing acted on that it could not read") { h in
            await faultRun(h, step, fault)
        }
    }
}

/// The fault's one strike, and the permissions it changed, put back when the step is over.
final class Strike: @unchecked Sendable {
    enum Next { case strike, restore, none }
    private let lock = NSLock()
    private var struck = false, isParked = false, calls = 0
    private var changed: [(path: String, mode: mode_t)] = []
    var fired: Bool { lock.withLock { struck } }
    var parked: Bool { lock.withLock { isParked } }

    /// Hooks inside a step (a journal write, one chat's move, a saved login's rename). A fault that
    /// struck stays through them, so the write right after the strike meets it.
    static let withinStep: Set<String> = ["journal", "moveChat", "save.rename"]

    /// What to do at a willStep: strike at the hook's `nth` call once `when` holds there, put
    /// things back as the next step begins.
    func next(_ step: String, strikeAt hook: String, nth: Int = 1, when: () -> Bool = { true }) -> Next {
        lock.withLock {
            if !struck, step == hook {
                calls += 1
                if calls >= nth, when() { struck = true; return .strike }
            }
            return struck && !changed.isEmpty && !Self.withinStep.contains(step) ? .restore : .none
        }
    }
    func park() { lock.withLock { isParked = true } }

    /// Sets every file and folder under `roots` to `files` or `dirs`, remembering each old mode.
    func chmod(_ roots: [URL], files: mode_t, dirs: mode_t) {
        var paths: [String] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            paths.append(root.path)
            if let all = FileManager.default.enumerator(atPath: root.path) {
                for case let sub as String in all { paths.append(root.appendingPathComponent(sub).path) }
            }
        }
        lock.withLock {
            for p in paths {
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                changed.append((p, st.st_mode & 0o7777))
                Darwin.chmod(p, (st.st_mode & S_IFMT) == S_IFDIR ? dirs : files)
            }
        }
    }
    func restore() {
        lock.withLock {
            for c in changed.reversed() { Darwin.chmod(c.path, c.mode) }
            changed = []
        }
    }
}

/// One pair: Alpha held settled with one chat, a manual Switch to Beta (or Set Up of Gamma), the
/// fault at the step, then the app left to finish as the model says, and both invariants checked.
@MainActor func faultRun(_ h: Harness, _ step: FaultStep, _ fault: Fault) async {
    let target = step.setUp ? C : B, targetRow = step.setUp ? "Gamma" : "Beta"
    if step.setUp {
        try? h.rows([("Alpha", A), ("Beta", B), ("Gamma", C)])
        for (n, seat) in [("Beta", B), ("Alpha", A)] { try? await h.savedLogin(n, seat) }
        for seat in [A, B, C] { h.usage.set(seat, fiveHour: 20, resetsAt: h.clock.now().addingTimeInterval(3 * 3600)) }
        h.claude.addChat("local_one", in: A, lastActivity: h.clock.now())
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        h.claude.signsInAs = C
        h.claudeHoldsSettled(); h.make()
        await h.tick(); await h.settle()
    } else {
        await h.standard()
    }
    let saved = step.setUp ? [("Alpha", A), ("Beta", B)] : [("Alpha", A), ("Beta", B), ("Gamma", C)]
    let gammaAt = h.savedAt(C)
    let strike = Strike()
    defer { strike.restore() }
    let clock = h.clock, claude = h.claude
    // A full disk fails every write the app makes; a failed read fails what this step reads.
    let writes = [Paths.stateDir, claude.dataDir]
    let reads: [URL]
    switch step.hook {
    case "quit", "launch", "confirm": reads = [claude.logDir]
    case "move": reads = [ClaudeApp.folder(A.identity)]
    case "load" where !step.setUp: reads = [SavedLogins.dir(target.identity)]
    default: reads = [claude.cookies, ClaudeApp.cookiesJournal, claude.config]
    }
    claude.onStep = { name in
        switch strike.next(name, strikeAt: step.hook) {
        case .none: return
        case .restore: strike.restore()
        case .strike:
            switch fault {
            case .killApp: strike.park(); await clock.sleep(1e9)
            case .killClaude:
                // During the quit Claude dies before the request; after the launch, before it names
                // anyone, or once it has named the target and before that hold settles.
                if step.hook == "quit" { claude.stop(crashed: true) } else { clock.after(step.hook == "launch" ? 1 : claude.nameAfter + 5) { claude.stop(crashed: true) } }
            case .fullDisk: strike.chmod(writes, files: 0o444, dirs: 0o555)
            case .failedRead: strike.chmod(reads, files: 0o200, dirs: 0o300)
            }
        }
    }

    var lines: [String] = []
    func note() { for l in h.notice where !lines.contains(l) { lines.append(l) } }
    h.click(targetRow)
    if fault == .killApp {
        await h.run(until: { strike.parked || !h.switchInFlight }, limit: 1800)
        h.check(strike.parked, "the app was killed at \(step.name)")
        h.crashApp(); await h.tick(); await h.settle()
    }
    await h.run(until: { note(); return !h.switchInFlight }, limit: 3600)
    strike.restore()
    h.check(strike.fired, "the fault struck at \(step.name)")

    // Claude closed with the journal kept is the parked switch (section 7, the person quits Claude
    // after launch): the person opens Claude, and the app confirms then.
    let parked = SwitchJournal.load()?.parked == true
    if claude.pids().isEmpty {
        h.check(parked, "A: Claude is left closed only by a parked switch that keeps its journal (8 A, section 7); notice \(lines)")
        claude.start()
    }
    await h.run(until: { note(); return !h.switchInFlight && SwitchJournal.load() == nil && claude.held != nil }, limit: 1800)
    note()

    // Invariant A (section 8, with 13a.3): Claude ends on a state it was in before or on the target.
    let held = claude.held
    h.check(held == A || held == target, "A: Claude holds Alpha or \(targetRow); it holds \(held.map { "\($0)" } ?? "nothing"); notice \(lines)")
    h.check(claude.signInOnDisk() == held, "A: Claude's sign-in on disk is the seat it holds")
    h.check(SwitchJournal.load() == nil, "A: no journal is left once the switch is done (section 6)")
    if let held { h.check(claude.chats(in: held).contains("local_one"), "A: the chat is in the folder of the seat Claude holds (section 14's wrong outcomes)") }
    if !step.setUp { h.check(h.savedAt(C) == gammaAt, "A: Gamma's saved login, outside the switch, is untouched") }
    // Section 6, Recovery: before load the switch is undone, from load on it is finished.
    if fault == .killApp {
        let want = step.finishes ? "Finished switching to \(targetRow)" : "Switch to \(targetRow) undone"
        h.check(held == (step.finishes ? target : A), "recovery after the kill at \(step.name) ends on \(step.finishes ? targetRow : "Alpha") (section 6)")
        h.check(lines.contains { $0.contains(want) }, "the person sees \"\(want)\" (section 7); saw \(lines)")
        // Killed before its quit request, the switch changed nothing in Claude: the undo only clears
        // the journal, and never asks Claude to quit again or relaunches it (decision, 6 Recovery).
        if step.hook == "quit" {
            h.check(h.quits == 0 && h.launches == 0, "the undo of a switch killed before its quit asks Claude nothing: \(h.claude.actions)")
        }
    }
    if fault == .killClaude, step.hook != "quit" {
        h.check(lines.contains { $0.contains("Open Claude to finish switching to \(targetRow)") }, "the parked switch says \"Open Claude to finish switching to \(targetRow).\" (section 7); saw \(lines)")
        h.check(held == target, "the parked switch confirms \(targetRow) once Claude opens (section 7)")
    }

    checkActs(h)
    if fault == .failedRead, step.hook == "confirm" {
        h.check(held == A, "B: a confirm that can't read the log rolls back (section 8)")
        // Spec 11: the rollback's reason holds the notice over any pause.
        h.check(lines.contains { $0.contains("\(targetRow) didn't open in time. Back on Alpha.") },
                "B: one line says why the switch went back (sections 6 and 8); saw \(lines)")
    }

    await checkSavedLogins(h, saved + (step.setUp && h.savedAt(C) != nil ? [("Gamma", C)] : []))
}

/// Invariant B (section 8): nothing acted on that the app could not read. Nothing pressed but the
/// quit prompt's own answers, and nothing typed but one "resume" per chat.
@MainActor func checkActs(_ h: Harness) {
    let presses = h.claude.actions.filter { $0.hasPrefix("pressed ") }
    h.check(presses.allSatisfy { $0 == "pressed Quit anyway" || $0 == "pressed Cancel" }, "B: nothing pressed but Quit anyway or Cancel; pressed \(presses)")
    h.check(h.claude.sent.allSatisfy { $0.hasSuffix(" resume") } && Set(h.claude.sent).count == h.claude.sent.count,
            "B: nothing typed but one resume per chat; typed \(h.claude.sent)")
}

/// Invariant A (section 8): every saved login is intact, so each one, loaded, signs Claude in to
/// its own seat. It stops Claude, so it comes last.
@MainActor func checkSavedLogins(_ h: Harness, _ saved: [(String, StandSeat)]) async {
    h.claude.stop(crashed: true)
    for (row, seat) in saved {
        do {
            try await SavedLogins.load(seat.identity)
            h.check(h.claude.signInOnDisk() == seat, "A: \(row)'s saved login, loaded, signs Claude in to \(row)")
        } catch { h.check(false, "A: \(row)'s saved login loads (\(error.localizedDescription))") }
    }
}

/// Invariant A (section 8) once the switch and any recovery are over: Claude holds one of `ends`,
/// its sign-in on disk is that seat's, no journal is left, and every chat is in that seat's folder.
@MainActor func checkEnds(_ h: Harness, _ ends: [(String, StandSeat)], chats: [String], lines: [String]) {
    let held = h.claude.held
    let name = { (s: StandSeat?) in s.flatMap { s in [("Alpha", A), ("Beta", B), ("Gamma", C)].first { $0.1 == s }?.0 } ?? "nothing" }
    h.check(ends.contains { $0.1 == held }, "A: Claude holds \(ends.map(\.0).joined(separator: " or ")); it holds \(name(held)); notice \(lines) (8 A)")
    h.check(h.claude.signInOnDisk() == held, "A: Claude's sign-in on disk is the seat it holds (8 A)")
    h.check(SwitchJournal.load() == nil, "A: no journal is left once the switch is done (6); journal at \(SwitchJournal.load().map { "\($0.step)" } ?? "none")")
    guard let held else { return }
    for chat in chats {
        h.check(h.claude.chats(in: held).contains(chat),
                "A: \(chat) is in \(name(held))'s folder, the seat Claude holds (8 A, 6.3); Alpha has \(h.claude.chats(in: A).sorted()), Beta \(h.claude.chats(in: B).sorted()), Gamma \(h.claude.chats(in: C).sorted())")
    }
}

/// One more idle chat in Alpha's folder, on screen, beside the standard one.
@MainActor func secondChat(_ h: Harness) {
    h.claude.addChat("local_two", in: A, lastActivity: h.clock.now())
    h.claude.screens["local_two"] = ChatScreen(busy: false, composer: true, draft: false)
}

/// Collects every line the notice shows while a pair runs.
@MainActor final class Lines {
    private(set) var seen: [String] = []
    func note(_ h: Harness) { for l in h.notice where !seen.contains(l) { seen.append(l) } }
    func has(_ text: String) -> Bool { seen.contains { $0.contains(text) } }
}

/// Runs until the switch and any recovery are done: no switch, no journal, Claude holding a seat.
@MainActor func runToEnd(_ h: Harness, _ lines: Lines, limit: TimeInterval = 3600) async {
    await h.run(until: { lines.note(h); return !h.switchInFlight && SwitchJournal.load() == nil && h.claude.held != nil }, limit: limit)
    lines.note(h)
}

/// Waits for the parked switch task, then kills the app: a new Store recovers from the journal.
@MainActor func killAppAtStrike(_ h: Harness, _ strike: Strike, _ what: String) async {
    await h.run(until: { strike.parked || !h.switchInFlight }, limit: 1800)
    h.check(strike.parked, "the app was killed \(what)")
    h.crashApp(); await h.tick(); await h.settle()
}

// MARK: - Faults inside a step (8 A, 6.1 and 6.3)

/// A kill, or a full disk, partway through a step: between a saved login's new copy and its
/// rename, between two chat moves, and between a chat's move and the journal write that lists it
/// (a kill between the journal's temp file and its rename leaves the journal as it was). Each is a
/// manual Switch from Alpha, held settled, to Beta, with two chats, so the move is partly done.
let midStepFaultScenarios: [Scenario] = [
    Scenario(pair: "(Switch at move, kill the app between two chat moves)",
             model: "6.3 and Recovery: a kill before load is undone, each listed move put back; 8 A: chats with the seat Claude holds") { h in
        await midStep(h, "between two chat moves", hook: "moveChat", nth: 2, fault: .killApp)
    },
    Scenario(pair: "(Switch at move, kill the app before the journal lists a chat's move)",
             model: "6: each step writes the journal first; 8 A: a kill between the journal's temp file and its rename strands no chat") { h in
        // The journal still lists one move when the next journal write begins: the second chat's.
        await midStep(h, "before the journal lists the second chat's move", hook: "journal", fault: .killApp) {
            SwitchJournal.load().map { $0.step == .move && $0.moves.count == 1 } ?? false
        }
    },
    Scenario(pair: "(Switch at move, full disk between two chat moves)",
             model: "6.3 and 6.6: a move that fails partway rolls back every listed move; 8 A") { h in
        await midStep(h, "between two chat moves", hook: "moveChat", nth: 2, fault: .fullDisk)
    },
    Scenario(pair: "(Switch at save, kill the app between the new copy and its rename)",
             model: "6.1 and 8 A: write a new file, check it, rename it; the old copy is kept until the new one is proven") { h in
        await midStep(h, "between Alpha's new copy and its rename", hook: "save.rename", fault: .killApp) {
            SwitchJournal.load()?.step == .save
        }
    },
]

/// One mid-step pair: the standard start with a second chat, a manual Switch to Beta, the fault at
/// the hook's `nth` call where `when` holds, then the switch undone (every fault here strikes before load).
@MainActor func midStep(_ h: Harness, _ what: String, hook: String, nth: Int = 1, fault: Fault,
                        when: @escaping @Sendable () -> Bool = { true }) async {
    await h.standard()
    secondChat(h)
    let strike = Strike()
    defer { strike.restore() }
    let clock = h.clock, claude = h.claude
    claude.onStep = { name in
        switch strike.next(name, strikeAt: hook, nth: nth, when: when) {
        case .none: return
        case .restore: strike.restore()
        case .strike:
            switch fault {
            case .killApp: strike.park(); await clock.sleep(1e9)
            case .fullDisk: strike.chmod([Paths.stateDir, claude.dataDir], files: 0o444, dirs: 0o555)
            case .killClaude, .failedRead: break
            }
        }
    }
    let lines = Lines()
    h.click("Beta")
    if fault == .killApp { await killAppAtStrike(h, strike, what) }
    await runToEnd(h, lines)
    strike.restore()
    h.check(strike.fired, "the fault struck \(what)")
    checkEnds(h, [("Alpha", A)], chats: ["local_one", "local_two"], lines: lines.seen)
    if fault == .killApp { h.check(lines.has("Switch to Beta undone"), "the person sees \"Switch to Beta undone.\" (sections 6 and 7); saw \(lines.seen)") }
    if fault == .fullDisk { h.check(lines.has("Couldn't switch to Beta"), "the row says why: \"Couldn't switch to Beta.\" (6.6); saw \(lines.seen)") }
    checkActs(h)
    await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
}

// MARK: - Faults on the automatic switch (sections 4, 5 and 6)

/// The automatic switch runs the same procedure; these pairs strike where its path differs from a
/// manual one: the unattended quit and its 3 min wait, a failed confirm that sends the decision on
/// to the next target, and the resume. Each starts with Alpha held settled and its chat stopped by
/// a limit, so the switch goes to Beta, next down the menu.
let autoFaultScenarios: [Scenario] = [
    Scenario(pair: "(Automatic switch at quit, kill the app during the 3 min wait)",
             model: "5 quitWait: an unattended switch that can't get Claude to quit cancels and stops; Recovery: undone before load; 8 A") { h in
        let lines = await autoStart(h, promptAnswerable: false)
        await startAuto(h)
        await quitWaiting(h, lines)
        h.crashApp(); await h.tick(); await h.settle()
        await runToEnd(h, lines, limit: 1800)
        checkEnds(h, [("Alpha", A)], chats: ["local_one"], lines: lines.seen)
        h.check(!h.claude.pids().isEmpty, "Claude is left running (8 A)")
        checkActs(h)
        // The prompt has no Quit anyway button, so the app recognises no prompt: it presses nothing,
        // before the kill or in the recovery (decision, 8 B).
        h.check(!h.claude.actions.contains { $0.hasPrefix("pressed") }, "B: nothing pressed on a prompt the app cannot recognise: \(h.claude.actions)")
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at quit, kill the app while Quit anyway doesn't land)",
             model: "decision: the recovery of an automatic switch stopped at its quit presses Cancel on the prompt it recognises; Recovery: undone before load; 8 A") { h in
        let lines = await autoStart(h)
        // The prompt shows its Quit anyway button, but the press leaves it open and Claude running.
        h.claude.quitBehaviour = .promptUnanswered
        h.claude.quitAnywayLands = false
        await startAuto(h)
        await quitWaiting(h, lines)
        h.check(h.claude.actions.contains("pressed \(ClaudeUI.quitAnyway)") && h.claude.at("pressed \(ClaudeUI.cancel)").isEmpty,
                "setup: the switch pressed Quit anyway, the prompt stayed, nothing cancelled yet: \(h.claude.actions)")
        let killed = h.now
        h.crashApp(); await h.tick(); await h.settle()
        await runToEnd(h, lines, limit: 1800)
        let cancels = h.claude.at("pressed \(ClaudeUI.cancel)")
        h.check(cancels.count == 1 && cancels.allSatisfy { $0 >= killed } && !h.claude.promptOpen,
                "the recovery presses Cancel once on the prompt it recognises, so no prompt is left open: \(h.claude.actions), prompt open \(h.claude.promptOpen)")
        h.check(h.quits == 1 && h.launches == 0, "and asks Claude nothing more: \(h.claude.actions)")
        checkEnds(h, [("Alpha", A)], chats: ["local_one"], lines: lines.seen)
        h.check(!h.claude.pids().isEmpty, "Claude is left running (8 A)")
        h.check(lines.has("Switch to Beta undone"), "the person sees \"Switch to Beta undone.\" (7); saw \(lines.seen)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at quit, kill Claude during the 3 min wait)",
             model: "7: the person quits Claude during the quit wait, the quit succeeded, go on; 8 B: no resume typed while a shape is missing") { h in
        let lines = await autoStart(h, promptAnswerable: false)
        await startAuto(h)
        await quitWaiting(h, lines)
        h.claude.stop(crashed: true)
        await runToEnd(h, lines)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        // The prompt had no Quit anyway button: a missing shape turns resume off.
        h.check(h.claude.sent.isEmpty, "B: no resume typed while the quit button's shape is missing (8); typed \(h.claude.sent)")
        // Section 12: with resume off, the chats are named instead.
        await h.run(until: { lines.note(h); return lines.has("Couldn't resume") }, limit: ClaudeTiming.settle + 35 * 60)
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "the stopped chat is named while the shape miss stands (8, 12); saw \(lines.seen)")
        h.check(h.claude.sent.isEmpty, "still nothing typed: \(h.claude.sent)")
        // Spec 11: that failure holds the one notice; the paused line says why once it is closed.
        h.store.closeNotice()
        await h.tick()
        lines.note(h)
        h.check(h.noticeHas(pausedLine), "B: one line says switching on its own is paused (8) once the failure is closed: \(h.notice)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at quit, a failed read)",
             model: "6.7: the chat a limit stopped, on screen and idle, gets one resume; 8 B: never acts on an unread log") { h in
        let lines = await autoStart(h)
        let strike = autoStrike(h, at: "quit", .failedRead)
        await startAuto(h)
        defer { strike.restore() }
        await runToEnd(h, lines)
        strike.restore()
        h.check(strike.fired, "the log was unreadable at the quit")
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        await h.run(until: { lines.note(h); return h.resumed("local_one") || lines.has("Couldn't resume") }, limit: 1800)
        // The chat is on screen and idle, so 6.7 gives it one resume; "Couldn't resume" is only for
        // a chat that is not on screen (7).
        h.check(h.claude.sent == ["local_one resume"], "the stopped chat on screen gets exactly one resume (6.7); typed \(h.claude.sent), saw \(lines.seen)")
        h.check(!lines.has("Couldn't resume"), "a chat on screen is never named instead: \(lines.seen)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at confirm, kill the app)",
             model: "Recovery: from load on the switch is finished; 6.7: the stopped chat gets one resume; 8 A and B") { h in
        let lines = await autoStart(h)
        let strike = autoStrike(h, at: "confirm", .killApp)
        await startAuto(h)
        await killAppAtStrike(h, strike, "at the automatic switch's confirm")
        await runToEnd(h, lines)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(lines.has("Finished switching to Beta"), "the person sees \"Finished switching to Beta.\" (7); saw \(lines.seen)")
        await h.run(until: { h.resumed("local_one") }, limit: 600)
        h.check(h.resumed("local_one"), "the stopped chat gets one resume after the recovery (6.7); typed \(h.claude.sent)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at confirm, a failed read)",
             model: "6.6: the rollback marks Beta failedTarget and the decision runs again at once with the next target; 8 B: confirm that can't read the log rolls back") { h in
        let lines = await autoStart(h)
        let strike = autoStrike(h, at: "confirm", .failedRead)
        await startAuto(h)
        defer { strike.restore() }
        await h.run(until: { lines.note(h); return h.claude.held == C && !h.switchInFlight && SwitchJournal.load() == nil }, limit: 1800)
        strike.restore()
        h.check(strike.fired, "the log was unreadable at the confirm")
        checkEnds(h, [("Gamma", C)], chats: ["local_one"], lines: lines.seen)
        h.check(h.claude.chats(in: B).isEmpty, "nothing is left in Beta's folder")
        await h.run(until: { h.resumed("local_one") }, limit: 600)
        h.check(h.resumed("local_one"), "the stopped chat gets one resume on Gamma (6.7); typed \(h.claude.sent)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at resume, kill the app)",
             model: "8 A: the switch is done and its journal cleared before the resume; 6.7 and 8 B: the next launch gives the chat its one resume") { h in
        let lines = await autoStart(h, onScreen: false)
        await startAuto(h)
        await h.run(until: { lines.note(h); return h.claude.actions.contains { $0.hasPrefix("open ") } }, limit: 900)
        h.check(h.claude.held == B && SwitchJournal.load() == nil, "the resume runs after the confirm: holds \(String(describing: h.claude.held))")
        h.crashApp(); await h.tick(); await h.settle()
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        await h.pass(10 * 60)
        lines.note(h)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(h.claude.sent == ["local_one resume"], "the next launch gives the chat the resume the kill cut short, once (6.7, 8 B); typed \(h.claude.sent), saw \(lines.seen)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at resume, kill the app, the chat not on screen)",
             model: "6.7 and 12: the next launch tries the chat again for resumeFor, then names it") { h in
        let lines = await autoStart(h, onScreen: false)
        await startAuto(h)
        await h.run(until: { lines.note(h); return h.claude.actions.contains { $0.hasPrefix("open ") } }, limit: 900)
        h.crashApp()
        let launched = h.now
        await h.tick(); await h.settle()
        await h.run(until: { lines.note(h); return lines.has("Couldn't resume") }, limit: ClaudeTiming.resumeFor + 5 * 60)
        let tried = h.now.timeIntervalSince(launched)
        h.check(lines.has("Couldn't resume 1 chat: send it a message."), "the chat the killed resume left is named after the next launch (12): \(lines.seen)")
        h.check(tried >= ClaudeTiming.resumeFor - ClaudeTiming.resumeEvery, "it is tried again for resumeFor first: named after \(Int(tried / 60)) min")
        h.check(h.claude.sent.isEmpty, "nothing typed into a chat not on screen: \(h.claude.sent)")
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        checkActs(h)
    },
    Scenario(pair: "(Automatic switch at resume, kill the app, the person resumes the chat before the app is back)",
             model: "6.7: a chat already resumed is skipped; Recovery: the next launch's resume counts from Claude's reopening, so a chat that ran since is left alone") { h in
        let lines = await autoStart(h, onScreen: false)
        await startAuto(h)
        await h.run(until: { lines.note(h); return h.claude.actions.contains { $0.hasPrefix("open ") } }, limit: 900)
        h.killApp()
        h.check(h.resumeOnDisk, "setup: the killed resume leaves its chat on disk for the next launch")
        // While the app is down, the person sends the chat a message: it runs, then goes idle.
        h.claude.addChat("local_one", in: B, lastActivity: h.now)
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        await h.pass(60)
        h.make(); await h.tick(); await h.settle()
        await h.run(until: { lines.note(h); return !h.resumeOnDisk }, limit: ClaudeTiming.resumeFor + 5 * 60)
        lines.note(h)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(h.claude.sent.isEmpty, "the next launch types nothing into a chat the person resumed since Claude reopened (6.7); typed \(h.claude.sent)")
        h.check(!lines.has("Couldn't resume"), "and does not name it: \(lines.seen)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
    Scenario(pair: "(Automatic switch at resume, kill Claude)",
             model: "7: Claude quits with no switch running; 5 resumeFor: retried every 60 s for 30 min; 8 B: nothing typed into a closed Claude") { h in
        let lines = await autoStart(h, onScreen: false)
        await startAuto(h)
        await h.run(until: { lines.note(h); return h.claude.actions.contains { $0.hasPrefix("open ") } }, limit: 900)
        h.claude.stop(crashed: true)
        await h.pass(3 * 60)
        h.check(h.claude.sent.isEmpty, "B: nothing typed while Claude is closed; typed \(h.claude.sent)")
        // The person opens Claude again within resumeFor, and the chat is on screen.
        h.claude.start()
        h.claude.screens["local_one"] = ChatScreen(busy: false, composer: true, draft: false)
        await h.run(until: { lines.note(h); return h.resumed("local_one") }, limit: 30 * 60)
        lines.note(h)
        checkEnds(h, [("Beta", B)], chats: ["local_one"], lines: lines.seen)
        h.check(h.resumed("local_one"), "the chat gets its one resume once Claude is open again, within resumeFor (5); typed \(h.claude.sent), saw \(lines.seen)")
        checkActs(h)
        await checkSavedLogins(h, [("Alpha", A), ("Beta", B), ("Gamma", C)])
    },
]

/// The standard start for an automatic pair. `promptAnswerable` false gives Claude's quit prompt
/// no Quit anyway button, so the unattended quit waits its 3 min (section 5).
@MainActor func autoStart(_ h: Harness, onScreen: Bool = true, promptAnswerable: Bool = true) async -> Lines {
    await h.standard(onScreen: onScreen)
    if !promptAnswerable { h.claude.quitBehaviour = .promptUnanswered; h.claude.promptHasQuitButton = false }
    return Lines()
}

/// Claude stops Alpha's chat for usage after the hold settled, and the automatic switch starts.
@MainActor func startAuto(_ h: Harness) async {
    h.claude.logLimitStop("local_one", seatReadsFull: true)
    await h.run(until: { h.switchInFlight }, limit: 600)
    h.check(h.switchInFlight, "the limit stop starts the automatic switch (4): \(h.claude.actions), \(h.notice)")
}

/// Runs until the automatic switch has waited a minute on a prompt it cannot answer.
@MainActor func quitWaiting(_ h: Harness, _ lines: Lines) async {
    await h.run(until: { lines.note(h); return h.claude.promptOpen && h.switchInFlight }, limit: 900)
    await h.pass(60)
    lines.note(h)
    h.check(h.switchInFlight && h.claude.promptOpen && h.claude.held == A,
            "the automatic switch waits on Claude's prompt (5 quitWait): in flight \(h.switchInFlight), prompt \(h.claude.promptOpen), \(h.claude.actions)")
}

/// A fault at one step of the automatic switch, as faultRun strikes it.
@MainActor func autoStrike(_ h: Harness, at hook: String, _ fault: Fault) -> Strike {
    let strike = Strike()
    let clock = h.clock, claude = h.claude
    claude.onStep = { name in
        switch strike.next(name, strikeAt: hook) {
        case .none: return
        case .restore: strike.restore()
        case .strike:
            switch fault {
            case .killApp: strike.park(); await clock.sleep(1e9)
            case .failedRead: strike.chmod([claude.logDir], files: 0o200, dirs: 0o300)
            case .fullDisk: strike.chmod([Paths.stateDir, claude.dataDir], files: 0o444, dirs: 0o555)
            case .killClaude: claude.stop(crashed: true)
            }
        }
    }
    return strike
}
