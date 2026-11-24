// Draws the menu in fixed states to PNGs, for reviewing a menu change and for docs/menu.png.
// Built and run by scripts/render-menu.sh with every app source except Main.swift, so the app
// never starts. Seats.build and AppState.notice decide each state from hand-built Facts, and
// MenuPanel draws them with empty MenuActions at a fixed time. Nothing reads a file, runs a
// program, opens Claude, the keychain or the network: the menu is drawn from values only.

import AppKit
import SwiftUI

func uuid(_ n: Int) -> String { String(format: "%08x-0000-4000-8000-%012x", n, n) }

let cal = Calendar.current
let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14, minute: 5))!
func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
    cal.date(byAdding: .day, value: dayOffset, to: cal.date(bySettingHour: h, minute: m, second: 0, of: now)!)!
}
let thursday9 = at(9, 0, dayOffset: 3)

func row(_ id: Int, account: Int, name: String, orgName: String, color: String = "") -> AccountRecord {
    AccountRecord(id: "r\(id)", name: name, color: color, configDir: "/nonexistent", keychainService: "none",
                  email: nil, accountUuid: uuid(account), orgName: orgName, orgUuid: uuid(100 + id))
}

/// 8 seats across 5 accounts.
let baseRows: [AccountRecord] = [
    row(1, account: 1, name: "Alpha", orgName: "alpha@example.com's Organization"),
    row(2, account: 1, name: "Alpha", orgName: "Labs"),
    row(3, account: 1, name: "Alpha", orgName: "Research"),
    row(4, account: 2, name: "Beta", orgName: "beta@example.com's Organization"),
    row(5, account: 2, name: "Beta", orgName: "Studio"),
    row(6, account: 3, name: "Work", orgName: "Northwind"),
    row(7, account: 4, name: "Home", orgName: "home@example.com's Organization"),
    row(8, account: 5, name: "Side", orgName: "side@example.com's Organization"),
].labelled()

func m(_ five: Double?, _ fiveAt: Date?, _ week: Double?, _ weekAt: Date?, read: Date) -> SeatMeters {
    SeatMeters(fiveHour: five.map { MeterReading(percent: $0, resetsAt: fiveAt) },
               weekly: week.map { MeterReading(percent: $0, resetsAt: weekAt) }, readAt: read)
}

/// A Claude log line saying Claude holds `id` from `date`, read the way the app reads Claude's log.
func logLine(_ date: Date, _ id: Identity) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = ClaudeLog.timeFormat
    return "\(f.string(from: date)) [info] \(ClaudeLog.identity) accountId=\(id.account) orgId=\(id.org)"
}

/// A Claude log line at `date`, in Claude's own stamp.
func logAt(_ date: Date, _ body: String) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = ClaudeLog.timeFormat
    return "\(f.string(from: date)) [info] \(body)"
}

/// Claude stopped `chat` for a usage limit at `date`.
func limitStop(_ date: Date, _ chat: String) -> String {
    logAt(date, "\(ClaudeLog.cycle)\(chat)\(ClaudeLog.apiError)success): \(ClaudeLog.limitTexts[0]) usage limit")
}

/// `upgrade` is the first minutes after installing over the previous build: the seat in use has
/// room, Claude stopped one of its chats hours ago, and most seats are not read yet. `fullNoStop`
/// is the seat in use reading 100 after a turn that ended normally, with no chat stopped.
/// `staleWait` is `allOut` 20 minutes later, with every reading stale while the usage service stalls.
/// `brake` is the seat in use out with a chat stopped, 5 minutes after an automatic switch.
/// `switchFailed` is the seat in use at 100 after an automatic switch to Research failed and reopened Claude.
/// `answerPrompt` is an automatic switch to Research, the seat in use out with a chat stopped,
/// waiting on Claude's quit prompt it can't press.
enum Scenario { case spread, allOut, noAccessibility, stale, upgrade, fullNoStop, staleWait, brake, switchFailed, answerPrompt }

/// A desktop-like backdrop that differs from the panel in both appearances.
let backdrop = Color(red: 0.45, green: 0.52, blue: 0.60)

func facts(_ s: Scenario, order: SwitchOrder) -> Facts {
    var f = Facts()
    f.rows = baseRows
    f.claude = ClaudeFacts(installed: true, running: true, missing: [])
    f.log.read(logLine(at(13, 0), baseRows[1].seat), readAt: at(13, 0))   // Claude holds Alpha · Labs since 1 PM
    f.trusted = s != .noAccessibility
    f.order = order
    let fresh = now.addingTimeInterval(-2 * 60)
    f.saved = Set(baseRows.filter { $0.id != "r7" }.map(\.seat))   // Home was never signed in
    switch s {
    case .spread, .noAccessibility, .stale, .fullNoStop, .brake, .switchFailed, .answerPrompt:
        f.meters[baseRows[0].seat] = m(22, at(16, 40), 41, thursday9, read: now.addingTimeInterval(-42 * 60)) // stale
        f.meters[baseRows[1].seat] = m(64, at(16, 10), 38, thursday9, read: fresh)                         // in use
        f.meters[baseRows[2].seat] = m(8, at(18, 15), 15, thursday9, read: fresh)
        f.meters[baseRows[3].seat] = m(12, at(17, 0), 20, thursday9, read: fresh)
        f.meters[baseRows[4].seat] = m(100, at(17, 30), 57, thursday9, read: fresh)                        // out
        f.meters[baseRows[5].seat] = m(31, at(15, 50), 24, thursday9, read: fresh)
        f.meters[baseRows[7].seat] = m(5, at(18, 45), 72, thursday9, read: fresh)
        if s == .stale {
            // The seat in use read 42 min ago, and Work not read yet.
            f.meters[baseRows[1].seat] = m(64, at(16, 10), 38, thursday9, read: now.addingTimeInterval(-42 * 60))
            f.meters[baseRows[5].seat] = nil
        }
        if s == .brake || s == .answerPrompt {
            f.log.read(limitStop(now.addingTimeInterval(-3 * 60), "local_build"), readAt: now.addingTimeInterval(-3 * 60), arrived: true)
            f.meters[baseRows[1].seat] = m(100, at(16, 10), 38, thursday9, read: fresh)
        }
        if s == .brake { f.lastAutoSwitch = now.addingTimeInterval(-5 * 60) }
        if s == .answerPrompt { f.switching = SwitchFacts(target: baseRows[2].seat, step: QuitWatch.answerPrompt) }
        if s == .switchFailed { f.failedTargets[baseRows[2].seat] = now.addingTimeInterval(-60) }
        if s == .fullNoStop || s == .switchFailed {
            f.log.read(logAt(at(13, 50), "\(ClaudeLog.healthyCycle)local_build (12s, hadFirstResponse=true)"), readAt: at(13, 50), arrived: true)
            f.meters[baseRows[1].seat] = m(100, at(16, 10), 38, thursday9, read: fresh)
        }
    case .allOut, .staleWait:
        f.meters[baseRows[0].seat] = m(100, at(16, 40), 41, thursday9, read: fresh)
        f.meters[baseRows[1].seat] = m(100, at(16, 10), 61, thursday9, read: fresh)
        f.log.read(limitStop(now.addingTimeInterval(-6 * 60), "local_build"), readAt: now.addingTimeInterval(-6 * 60), arrived: true)   // read full after the stop
        f.meters[baseRows[2].seat] = m(100, at(15, 20), 33, thursday9, read: fresh)
        f.meters[baseRows[3].seat] = m(100, at(17, 0), 48, thursday9, read: fresh)
        f.meters[baseRows[4].seat] = m(100, at(17, 30), 57, thursday9, read: fresh)
        f.meters[baseRows[5].seat] = m(100, at(15, 50), 70, thursday9, read: fresh)
        f.meters[baseRows[7].seat] = m(64, at(18, 45), 100, thursday9, read: fresh)
        if s == .staleWait { for seat in f.meters.keys { f.meters[seat]?.readAt = now.addingTimeInterval(-20 * 60) } }
        // The Store told this wait when every seat read out.
        f.wait = AutoSwitch.Wait(hold: f.log.hold?.key ?? "", stops: f.log.hold.map { f.log.limitStops(in: $0) } ?? [:], told: true)
    case .upgrade:
        // Claude held Alpha · Labs from 10:39, stopped a chat there at 10:41, moved on at 10:42 and
        // came back at 1 PM; its meters read 40% and 6%. Beta reads out until Thursday; the rest
        // are not read yet.
        f.log = ClaudeEvents()
        f.log.read([logLine(at(10, 39), baseRows[1].seat), limitStop(at(10, 41), "local_build"),
                    logLine(at(10, 42), baseRows[0].seat), logLine(at(13, 0), baseRows[1].seat)].joined(separator: "\n"),
                   readAt: now.addingTimeInterval(-2 * 60))
        f.meters[baseRows[1].seat] = m(40, at(15, 40), 6, at(22, 0, dayOffset: 6), read: fresh)
        f.meters[baseRows[3].seat] = m(31, at(16, 30), 100, thursday9, read: fresh)
    }
    return f
}

/// The 8 seats plus 16 one-seat accounts, 8 above and 8 below, so the in-use card sits mid-list
/// and the cards need more than a 900 pt screen gives them.
func overflowFacts() -> Facts {
    let before = ["Gamma", "Delta", "Echo", "Fern", "Grove", "Harbor", "Iris", "Juniper"]
    let after = ["Kestrel", "Lumen", "Maple", "Nova", "Orbit", "Pine", "Quartz", "Reed"]
    let extra = { (names: [String], start: Int) in
        names.enumerated().map { i, n in row(start + i, account: start + i, name: n, orgName: "\(n.lowercased())@example.com's Organization") }
    }
    var f = facts(.noAccessibility, order: .topToBottom)
    f.rows = (extra(before, 20) + baseRows + extra(after, 40)).labelled()
    for (i, r) in f.rows.enumerated() where f.meters[r.seat] == nil && r.id != "r7" {
        f.saved.insert(r.seat)
        let p = Double((i * 37) % 90)
        f.meters[r.seat] = m(p, at(17, 0), p / 2, thursday9, read: now.addingTimeInterval(-120))
    }
    return f
}

/// The README's picture: the seat in use with both meters, Next, two seats out, one to set up.
func readmeFacts() -> Facts {
    let rows = [
        row(1, account: 1, name: "Work", orgName: "Northwind Labs", color: "#2C8A5E"),
        row(2, account: 1, name: "Work", orgName: "work@example.com's Organization", color: "#2C8A5E"),
        row(3, account: 1, name: "Work", orgName: "Northwind Research", color: "#2C8A5E"),
        row(4, account: 2, name: "Support", orgName: "support@example.com's Organization", color: "#3567CF"),
        row(5, account: 3, name: "Personal", orgName: "personal@example.com's Organization", color: "#B3405F"),
        row(6, account: 4, name: "Studio", orgName: "Harbor Studio", color: "#B96E22"),
        row(7, account: 4, name: "Studio", orgName: "studio@example.com's Organization", color: "#B96E22"),
        row(8, account: 5, name: "Side Project", orgName: "side@example.com's Organization", color: "#6B5BD2"),
    ].labelled()
    var f = Facts()
    f.rows = rows
    f.claude = ClaudeFacts(installed: true, running: true, missing: [])
    f.log.read(logLine(at(13, 0), rows[0].seat), readAt: at(13, 0))
    f.trusted = true
    let fresh = now.addingTimeInterval(-2 * 60)
    for r in rows where r.id != "r3" { f.saved.insert(r.seat) }   // Northwind Research is still to set up
    f.meters[rows[0].seat] = m(42, at(16, 23), 61, at(14, 25, dayOffset: 3), read: fresh)
    f.meters[rows[1].seat] = m(30, at(17, 10), 22, thursday9, read: fresh)
    f.meters[rows[3].seat] = m(35, at(18, 0), 100, at(10, 0, dayOffset: 2), read: fresh)
    f.meters[rows[4].seat] = m(47, at(16, 50), 30, thursday9, read: fresh)
    f.meters[rows[5].seat] = m(72, at(17, 20), 44, thursday9, read: fresh)
    f.meters[rows[6].seat] = m(100, at(17, 40), 52, thursday9, read: fresh)
    f.meters[rows[7].seat] = m(12, at(18, 30), 9, thursday9, read: fresh)
    return f
}

/// The menu in Rohan's build-11 screenshot: 9 seats on 6 accounts. Personal 2 is in use, Sam
/// Work's Individual is out, and its RapidEye seat was never signed in.
let ninePeople = [
    row(1, account: 1, name: "Personal", orgName: "personal@example.com's Organization"),
    row(2, account: 2, name: "Work", orgName: "work@example.com's Organization"),
    row(3, account: 2, name: "Work", orgName: "RapidEye"),
    row(4, account: 3, name: "Support", orgName: "support@example.com's Organization"),
    row(5, account: 3, name: "Support", orgName: "RapidEye"),
    row(6, account: 4, name: "School", orgName: "school@example.edu's Organization"),
    row(7, account: 5, name: "Personal 2", orgName: "personal2@example.com's Organization"),
    row(8, account: 6, name: "Sam Work", orgName: "sam@example.com's Organization"),
    row(9, account: 6, name: "Sam Work", orgName: "RapidEye"),
].labelled()

func nineFacts(extra: Bool = false) -> Facts {
    var f = Facts()
    f.rows = ninePeople
    f.claude = ClaudeFacts(installed: true, running: true, missing: [])
    f.log.read(logLine(at(13, 0), ninePeople[6].seat), readAt: at(13, 0))
    f.trusted = true
    let fresh = now.addingTimeInterval(-2 * 60)
    f.saved = Set(ninePeople.filter { $0.id != "r9" }.map(\.seat))
    let readings: [(Double, Double)] = [(18, 33), (42, 51), (9, 12), (27, 40), (63, 22), (5, 71), (58, 46), (100, 64)]
    for (r, p) in zip(ninePeople.prefix(8), readings) {
        f.meters[r.seat] = m(p.0, at(16, 10 + Int(p.0) % 40), p.1, thursday9, read: fresh)
    }
    if extra {
        let before = ["Gamma", "Delta", "Echo", "Fern", "Grove", "Harbor", "Iris", "Juniper"]
        let after = ["Kestrel", "Lumen", "Maple", "Nova", "Orbit", "Pine", "Quartz", "Reed"]
        let more = { (names: [String], start: Int) in
            names.enumerated().map { i, n in row(start + i, account: start + i, name: n, orgName: "\(n.lowercased())@example.com's Organization") }
        }
        f.rows = (more(before, 20) + ninePeople + more(after, 40)).labelled()
        for (i, r) in f.rows.enumerated() where f.meters[r.seat] == nil && r.id != "r9" {
            f.saved.insert(r.seat)
            let p = Double((i * 37) % 90)
            f.meters[r.seat] = m(p, at(17, 0), p / 2, thursday9, read: fresh)
        }
    }
    return f
}

/// `f` with `seat` reading 100 on its 5-hour meter (resetting 4:10 PM) or its weekly one (Thursday)
/// on a fresh reading, and no chat stopped.
func readsFull(_ f: Facts, _ seat: Identity, weekly: Bool = false) -> Facts {
    var f = f
    let old = f.meters[seat]
    f.meters[seat] = weekly ? m(old?.fiveHour?.percent ?? 40, at(16, 10), 100, thursday9, read: now.addingTimeInterval(-2 * 60))
                            : m(100, at(16, 10), old?.weekly?.percent ?? 40, thursday9, read: now.addingTimeInterval(-2 * 60))
    return f
}

/// The README's seats with the longest seat name in the fixtures, Work · Northwind Research, set up,
/// in use from 1:30 PM, and reading full.
func longestNameFacts() -> Facts {
    var f = readmeFacts()
    let seat = f.rows[2].seat
    f.saved.insert(seat)
    f.log.read(logLine(at(13, 30), seat), readAt: at(13, 30))
    return readsFull(f, seat)
}

// MARK: - Drawing

struct Shot: View {
    let seats: [Seat]
    let notice: Notice?
    let visible: CGFloat
    let header: MenuHeader
    let looks: MenuLooks

    /// `expanded` names the rows opened to both meters; `folded`, the accounts whose organizations are hidden.
    init(_ f: Facts, visible: CGFloat, header: MenuHeader = MenuHeader(updatedAt: now.addingTimeInterval(-120)),
         expanded: [String] = [], folded: [String] = [], failure: String? = nil, failureDetail: String? = nil) {
        seats = Seats.build(f, now: now)
        notice = AppState.notice(f, now: now, failure: failure, failureDetail: failureDetail)
        self.visible = visible
        self.header = header
        looks = MenuLooks(colors: resolvedColors(f.rows.map { ($0.seat.account, $0.color) }),
                          folded: Set(seats.filter { folded.contains($0.accountName) }.map(\.id.account)),
                          expanded: Set(seats.filter { expanded.contains($0.name) }.map(\.id)))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        MenuPanel(seats: seats, notice: notice, firstRun: false, visibleScreenHeight: visible,
                  header: header, looks: looks, now: now)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// The panel on a strip of screen `visible` points tall, so the image shows how much of the
/// screen the menu takes; nil draws the panel alone.
struct Screen<Content: View>: View {
    let visible: CGFloat?
    @ViewBuilder let content: Content
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(backdrop)
            content.padding(.top, 6).padding(.trailing, 12)
        }
        .frame(width: MenuLayout.width + 24, height: visible)
    }
}

/// Draws `view` offscreen at 2x into a PNG. The app's activation policy keeps every window off screen.
@MainActor
func render<V: View>(_ view: V, dark: Bool, to path: String) {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // Lets the scroll view apply its scroll-to-the-seat-in-use before the capture.
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
    window.contentView = nil
}

/// One NSMenuItem as macOS draws it in a menu: checkmark column, title, shortcut or submenu chevron.
struct MenuRow: View {
    let item: NSMenuItem
    var highlighted = false
    var body: some View {
        if item.isSeparatorItem {
            Divider().padding(.horizontal, 10).frame(height: 11)
        } else {
            HStack(spacing: 0) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(item.state == .on ? 1 : 0).frame(width: 22)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 24)
                if item.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                else if !item.keyEquivalent.isEmpty {
                    Text("⌘" + item.keyEquivalent.uppercased()).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 10)
            .frame(height: 22)
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(RoundedRectangle(cornerRadius: 4).fill(highlighted ? Color.accentColor : .clear).padding(.horizontal, 5))
        }
    }
}

/// An open menu in macOS style. AppKit draws real menus only on screen, so the chrome is this tool's.
struct MenuBox: View {
    let menu: NSMenu
    var highlight: String? = nil
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
                MenuRow(item: item, highlighted: item.title == highlight && !item.isSeparatorItem)
            }
        }
        .padding(.vertical, 5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

@main
enum RenderMenu {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = CommandLine.arguments[1]
        func both(_ name: String, _ view: some View) {
            for dark in [false, true] { render(view, dark: dark, to: "\(out)/\(name)-\(dark ? "dark" : "light").png") }
        }

        for v: CGFloat in [900, 1400] {
            both("menu-\(Int(v))pt", Screen(visible: v) { Shot(facts(.spread, order: .topToBottom), visible: v) })
        }
        render(Screen(visible: nil) { Shot(facts(.allOut, order: .topToBottom), visible: 900) }, dark: false,
               to: "\(out)/notice-waiting-light.png")
        both("stale-states", Screen(visible: nil) { Shot(facts(.stale, order: .topToBottom), visible: 900) })
        both("upgrade-not-read-yet", Screen(visible: nil) { Shot(facts(.upgrade, order: .topToBottom), visible: 900) })
        both("in-use-full-no-stop", Screen(visible: nil) { Shot(facts(.fullNoStop, order: .topToBottom), visible: 900) })
        // The Store keeps telling a wait it posted, Research's reset first, while the readings are stale.
        both("notice-waiting-stale", Screen(visible: nil) {
            Shot(facts(.staleWait, order: .topToBottom), visible: 900, header: MenuHeader(updatedAt: now.addingTimeInterval(-20 * 60)))
        })
        both("notice-brake", Screen(visible: nil) { Shot(facts(.brake, order: .topToBottom), visible: 900) })
        // The line an automatic switch that failed and reopened Claude leaves, as the Store sets it.
        both("notice-switch-failed", Screen(visible: nil) {
            Shot(facts(.switchFailed, order: .topToBottom), visible: 900, failure: "Didn't switch to Alpha · Research. \(AutoSwitch.afterFailureShort)",
                 failureDetail: "Didn't switch to Alpha · Research: Alpha · Research didn't open in time. Back on Alpha · Labs. \(AutoSwitch.afterFailure)")
        })
        // While an automatic switch waits on Claude's quit prompt it can't press.
        both("notice-answer-prompt", Screen(visible: nil) { Shot(facts(.answerPrompt, order: .topToBottom), visible: 900) })
        // The line an automatic switch that couldn't get Claude to quit leaves, as the Store sets it.
        both("notice-quit-failed", Screen(visible: nil) {
            Shot({ var f = facts(.switchFailed, order: .topToBottom); f.pausedHold = f.hold?.key; return f }(), visible: 900,
                 failure: "Didn't switch to Alpha · Research. \(AutoSwitch.afterFailureShort)",
                 failureDetail: "Didn't switch to Alpha · Research: Claude didn't quit, so nothing changed. Its prompt is still open: Cancel keeps Claude as it is. \(AutoSwitch.afterQuitFailure)")
        })
        render(Screen(visible: nil) { Shot(facts(.noAccessibility, order: .topToBottom), visible: 900) }, dark: false,
               to: "\(out)/notice-accessibility-light.png")
        both("overflow-24-seats-900pt", Screen(visible: 900) { Shot(overflowFacts(), visible: 900, header: MenuHeader(updatedAt: now)) })

        // Rohan's nine seats with rows opened to both meters: none, one, and several (a seat alone,
        // an organization, and the out seat), then a list taller than the screen with rows opened.
        let opened: [(String, [String])] = [("collapsed", []), ("one-expanded", ["Personal"]),
                                            ("several-expanded", ["Personal", "Work · RapidEye", "Sam Work · Individual"])]
        for v: CGFloat in [900, 1400] {
            for (state, rows) in opened {
                both("nine-\(Int(v))pt-\(state)", Screen(visible: v) { Shot(nineFacts(), visible: v, expanded: rows) })
            }
        }
        // The seat in use reads full with no chat stopped: its row says Out beside In use.
        let personal2 = ninePeople[6].seat
        for v: CGFloat in [900, 1400] {
            both("nine-\(Int(v))pt-in-use-out", Screen(visible: v) { Shot(readsFull(nineFacts(), personal2), visible: v) })
        }
        both("nine-900pt-in-use-out-weekly", Screen(visible: 900) {
            Shot(readsFull(nineFacts(), personal2, weekly: true), visible: 900, expanded: ["Personal", "Sam Work · Individual"])
        })
        both("in-use-out-longest-name", Screen(visible: nil) { Shot(longestNameFacts(), visible: 900) })
        both("in-use-out-folded", Screen(visible: nil) { Shot(longestNameFacts(), visible: 900, folded: ["Work"]) })
        both("nine-overflow-900pt-expanded", Screen(visible: 900) {
            Shot(nineFacts(extra: true), visible: 900, header: MenuHeader(updatedAt: now),
                 expanded: ["Personal", "Work · RapidEye", "Support · Individual", "School", "Sam Work · Individual"])
        })

        // The title's ··· menu open on Switch Order. SwiftUI fills a Menu's NSMenu only when it opens
        // on screen, so the title bar's own items are built into an NSHostingMenu to read their real
        // titles, submenus and checkmarks.
        let header = MenuHeader(updatedAt: now.addingTimeInterval(-120), switchOrder: .personalFirst)
        let panel = Shot(facts(.spread, order: .personalFirst), visible: 900, header: header)
        render(Screen(visible: nil) { panel }, dark: false, to: "\(out)/order-personal-first-panel-light.png")
        let items = NSHostingMenu(rootView: TitleMenuItems(header: header, actions: MenuActions()))
        items.update()
        let order = items.items.first { $0.title == "Switch Order" }!.submenu!
        let panelX: CGFloat = 260, mainW: CGFloat = 230, subW: CGFloat = 190
        let mainX = panelX + MenuLayout.width - 16 - mainW, mainY: CGFloat = 6 + 6 + 30
        let rowY = items.items.prefix { $0.title != "Switch Order" }.reduce(CGFloat(0)) { $0 + ($1.isSeparatorItem ? 11 : 22) }
        both("switch-order-open", ZStack(alignment: .topLeading) {
            Rectangle().fill(backdrop)
            panel.offset(x: panelX, y: 6)
            MenuBox(menu: items, highlight: "Switch Order", width: mainW).offset(x: mainX, y: mainY)
            MenuBox(menu: order, width: subW).offset(x: mainX - subW + 2, y: mainY + rowY)
        }
        .frame(width: panelX + MenuLayout.width + 12, height: 6 + 419 + 6, alignment: .topLeading))

        // docs/menu.png: the panel alone with an 8 pt clear margin, light.
        render(Shot(readmeFacts(), visible: 900).padding(8), dark: false, to: "\(out)/menu-readme.png")
    }
}
