import Foundation
import Darwin

// Invariants A and B (model, section 8) under injected faults at every step of the journaled
// switch (section 6). Each step crossed with each fault is its own pair. The fault strikes once,
// on the switch's own task, as its step begins (World.willStep). A full disk or a failed read
// lasts until the next step begins or the undo starts, so each fault stays inside its step.

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
let faultScenarios: [Scenario] = faultSteps.flatMap { step in
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
    private var struck = false, isParked = false
    private var changed: [(path: String, mode: mode_t)] = []
    var fired: Bool { lock.withLock { struck } }
    var parked: Bool { lock.withLock { isParked } }

    /// What to do at a willStep: strike at the step's first start, put things back at any later one.
    func next(_ step: String, strikeAt hook: String) -> Next {
        lock.withLock {
            if !struck, step == hook { struck = true; return .strike }
            return struck && !changed.isEmpty ? .restore : .none
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
                if step.hook == "quit" { claude.stop() } else { clock.after(step.hook == "launch" ? 1 : claude.nameAfter + 5) { claude.stop() } }
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
    }
    if fault == .killClaude, step.hook != "quit" {
        h.check(lines.contains { $0.contains("Open Claude to finish switching to \(targetRow)") }, "the parked switch says \"Open Claude to finish switching to \(targetRow).\" (section 7); saw \(lines)")
        h.check(held == target, "the parked switch confirms \(targetRow) once Claude opens (section 7)")
    }

    // Invariant B (section 8): nothing acted on that the app could not read.
    let presses = claude.actions.filter { $0.hasPrefix("pressed ") }
    h.check(presses.allSatisfy { $0 == "pressed Quit anyway" || $0 == "pressed Cancel" }, "B: nothing pressed but Quit anyway or Cancel; pressed \(presses)")
    h.check(claude.sent.allSatisfy { $0.hasSuffix(" resume") } && Set(claude.sent).count == claude.sent.count,
            "B: nothing typed but one resume per chat; typed \(claude.sent)")
    if fault == .failedRead, step.hook == "confirm" {
        h.check(held == A, "B: a confirm that can't read the log rolls back (section 8)")
        // The miss clears once the relaunch on Alpha logs its Named line, so either line may stand.
        h.check(lines.contains { $0.contains(pausedLine) || $0.contains("\(targetRow) didn't open in time") },
                "B: one line says why the switch went back (sections 6 and 8); saw \(lines)")
    }

    // Every saved login is intact: each one, loaded, signs Claude in to its own seat.
    claude.stop()
    for (row, seat) in saved + (step.setUp && h.savedAt(C) != nil ? [("Gamma", C)] : []) {
        do {
            try await SavedLogins.load(seat.identity)
            h.check(claude.signInOnDisk() == seat, "A: \(row)'s saved login, loaded, signs Claude in to \(row)")
        } catch { h.check(false, "A: \(row)'s saved login loads (\(error.localizedDescription))") }
    }
}
