import AppKit
import SwiftUI

// What the person sees, read from the Store's seats and notice (model, sections 3 and 11). The
// scenarios assert only through this, so they stay in the model's words.

/// A seat's state without its details, so a scenario compares it with ==.
enum ShownState: Equatable { case switching, inUse, needsSignIn, out, ready }

@MainActor extension Harness {
    func make() { store = Store() }
    /// How often the app's own timer runs a tick.
    var tickEvery: TimeInterval { Store.tickEvery }
    /// A switch is running, its resume included.
    var switchInFlight: Bool { store?.switchTask != nil }
    /// A saved login for a seat, taken through the app's own save while Claude is closed.
    func savedLogin(_ row: String, _ seat: StandSeat) async throws {
        claude.writeSignIn(seat)
        do { try await SavedLogins.save(seat.identity) }
        catch { check(false, "setup: saving \(row)'s login threw \(error)"); throw error }
    }
    /// The app's own tick; nothing while the app is down.
    func tick() async { await store?.tick() }
    func state(_ row: String) -> ShownState? {
        guard let s = store.seats.first(where: { $0.name == row }) else { return nil }
        switch s.state {
        case .switching: return .switching
        case .inUse: return .inUse
        case .needsSignIn: return .needsSignIn
        case .out: return .out
        case .ready: return .ready
        }
    }
    func action(_ row: String) -> SeatAction? { seat(row)?.action }
    /// The notice's short line and its full sentence.
    var notice: [String] { [store?.notice?.text, store?.notice?.detail].compactMap { $0 } }
    var rowNames: [String] { store.seats.map(\.name) }
    func seat(_ row: String) -> Seat? { store.seats.first { $0.name == row } }
    /// The meter's age as the row says it: "not read yet", "read N min ago", or nil while fresh.
    func meterText(_ row: String) -> String? { seat(row)?.meters.readText(at: clock.now()) }
    func rename(_ row: String, to name: String) { if let s = seat(row) { store.rename(s, to: name, organization: false) } else { check(false, "no row named \(row)") } }
    func move(_ row: String, by step: Int) { if let s = seat(row) { store.move(s, by: step, organization: false) } else { check(false, "no row named \(row)") } }
    func remove(_ row: String) { if let s = seat(row) { store.remove(s) } else { check(false, "no row named \(row)") } }
    var firstRun: Bool { store.firstRun }
    /// The menu's measures on a screen whose visible part is `screen` points tall, from the same
    /// MenuLayout the drawn menu uses: its height, the height every row would need, and the
    /// pinned part (title bar and notice) that never scrolls.
    func menu(screen: CGFloat) -> MenuMeasure {
        let notice = store.notice != nil
        return MenuMeasure(height: MenuLayout.height(visibleScreenHeight: screen, seats: store.seats, hasNotice: notice),
                           content: MenuLayout.contentHeight(seats: store.seats, hasNotice: notice),
                           pinned: MenuLayout.chrome(hasNotice: notice), margin: MenuLayout.screenMargin, row: MenuLayout.line)
    }
    /// The row's five-hour and weekly percents, as its meters show them.
    func percents(_ row: String) -> [Double] { [seat(row)?.meters.fiveHour?.percent, seat(row)?.meters.weekly?.percent].compactMap { $0 } }
    /// How far down the cards a row's card starts, in points, with the menu unscrolled.
    func cardTop(_ row: String) -> CGFloat? {
        let cards = MenuLayout.cards(store.seats)
        guard let i = cards.firstIndex(where: { $0.contains { $0.name == row } }) else { return nil }
        return cards[..<i].reduce(0) { $0 + MenuLayout.cardHeight($1, expanded: []) + MenuLayout.cardGap }
    }
    /// The rows on the card the menu scrolls to as it opens (nil: it stays at the top).
    var openScrollCard: [String]? {
        guard let id = MenuLayout.openScrollTarget(store.seats) else { return nil }
        return MenuLayout.cards(store.seats).first { $0[0].id.account == id }?.map(\.name)
    }
    /// The stand-in's write mark inside a seat's saved login: which of Claude's cookie writes it copied.
    func savedMark(_ seat: StandSeat) -> String? {
        claude.writeMark(in: SavedLogins.dir(seat.identity).appendingPathComponent("current/cookies.db"))
    }
    func hasSavedLogin(_ seat: StandSeat) -> Bool { savedAt(seat) != nil }
    /// When the seat's login was last saved, so a scenario can tell it was left untouched.
    func savedAt(_ seat: StandSeat) -> Date? {
        ["current", "prev"].lazy.compactMap { name in
            (try? Data(contentsOf: SavedLogins.dir(seat.identity).appendingPathComponent("\(name)/login.json")))
                .flatMap { try? JSONDecoder().decode(SavedLogins.Meta.self, from: $0) }?.savedAt
        }.first
    }
    /// The Mac wakes from sleep (the app's NSWorkspace.didWakeNotification).
    func wake() { store.woke() }
    /// The app is quit or crashes: its parked tasks never wake, and nothing of it runs until
    /// `make()` starts a new app on the same files.
    func killApp() { clock.abandonSleepers(); Switch.abandonForTest(); store = nil }
    /// The app is quit or crashes, and a new app starts at once on the same files.
    func crashApp() { killApp(); make() }
    func click(_ row: String) {
        guard let s = store.seats.first(where: { $0.name == row }) else { check(false, "no row named \(row)"); return }
        if s.action == .setUp { store.setUp(s) } else { store.switchTo(s) }
    }

    // MARK: The drawn menu

    /// Opens the menu: the app's own MenuContent drawn offscreen on this store, the way the menu
    /// bar item shows it. Its appearing runs what opening the menu runs (a refresh when due).
    func openMenu() async {
        let host = menuHost ?? NSHostingView(rootView: MenuContent(store: store))
        host.rootView = MenuContent(store: store)
        menuHost = host
        menuWindow.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle()
    }
    /// Closes the menu. Its window stays, as the menu bar keeps it between openings.
    func closeMenu() {
        menuWindow.contentView = nil
    }
    /// The menu's controls, as its buttons call them.
    private var controls: MenuContent { MenuContent(store: store) }
    /// Clicks a row's name (or its chevron, the same button): it opens or closes the row.
    func pressName(_ row: String) {
        guard let s = seat(row) else { check(false, "no row named \(row)"); return }
        guard MenuLayout.canExpand(s) else { check(false, "\(row)'s name is not a button"); return }
        controls.actions.showMeters(s, !controls.looks.expanded.contains(s.id))
    }
    /// Clicks an account's name, which folds or shows its organizations.
    func pressAccount(_ row: String) {
        guard let s = seat(row) else { check(false, "no row named \(row)"); return }
        controls.actions.showOrganizations(s.id.account, controls.looks.folded.contains(s.id.account))
    }
    /// The row shows a chevron: its name opens it to both meters.
    func hasChevron(_ row: String) -> Bool { seat(row).map(MenuLayout.canExpand) ?? false }
    /// The height of the cards as the open menu lays them out (its scroll view's content), and the
    /// height MenuLayout gives them with exactly `rows` opened to both meters. Every row is a fixed
    /// height, so the two agree only when the drawn rows opened are those (or rows of the same
    /// size). Nil drawn height with the menu closed.
    func cardHeights(opened rows: Set<String>) -> (drawn: CGFloat?, expected: CGFloat) {
        let ids = Set(store.seats.filter { rows.contains($0.name) }.map(\.id))
        let expected = MenuLayout.cardsHeight(seats: store.seats, expanded: ids, folded: controls.looks.folded)
        guard let host = menuHost, host.window != nil else { return (nil, expected) }
        host.layoutSubtreeIfNeeded()
        func scrollView(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(scrollView).first }
        return (scrollView(host)?.documentView?.frame.height, expected)
    }
    /// The open menu's text as VoiceOver reads it, in drawing order: every label and value SwiftUI
    /// publishes for what it drew. Empty with the menu closed.
    var drawnTexts: [String] {
        guard let host = menuHost, host.window != nil else { return [] }
        // SwiftUI builds its accessibility tree only once an assistive app asks for it, by setting
        // this attribute on the app, as VoiceOver does.
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                                         with: "AXEnhancedUserInterface")
        host.layoutSubtreeIfNeeded()
        // SwiftUI's elements answer NSAccessibility's informal protocol, not a Swift type.
        func ask(_ o: NSObject, _ name: String) -> Any? {
            o.responds(to: NSSelectorFromString(name)) ? o.perform(NSSelectorFromString(name))?.takeUnretainedValue() : nil
        }
        func texts(_ e: Any) -> [String] {
            guard let o = e as? NSObject else { return [] }
            let own = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"]
                .compactMap { ask(o, $0) as? String }.filter { !$0.isEmpty }
            return own + ((ask(o, "accessibilityChildren") as? [Any]) ?? []).flatMap(texts)
        }
        return texts(host)
    }
    /// The open menu draws `text` right before an In use badge.
    func drawnBeforeInUse(_ text: String) -> Bool {
        let drawn = drawnTexts
        return drawn.indices.dropLast().contains { drawn[$0] == text && drawn[$0 + 1] == "In use" }
    }
    /// The open menu draws `rows`, and no other row, opened to both meters.
    func menuShowsOpened(_ rows: Set<String>, _ what: String) {
        let h = cardHeights(opened: rows)
        check(h.drawn.map { abs($0 - h.expected) < 0.5 } == true,
              "\(what): the cards are drawn \(String(describing: h.drawn)) pt tall, \(h.expected) pt with \(rows.sorted()) opened")
    }
}
