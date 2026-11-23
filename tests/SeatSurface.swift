import Foundation

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
    func tick() async { await store.tick() }
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
    var notice: [String] { [store.notice?.text, store.notice?.detail].compactMap { $0 } }
    var rowNames: [String] { store.seats.map(\.name) }
    private func seat(_ row: String) -> Seat? { store.seats.first { $0.name == row } }
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
        return cards[..<i].reduce(0) { $0 + MenuLayout.cardHeight($1, expanded: nil) + MenuLayout.cardGap }
    }
    /// The stand-in's write mark inside a seat's saved login: which of Claude's cookie writes it copied.
    func savedMark(_ seat: StandSeat) -> String? {
        claude.writeMark(in: SavedLogins.dir(seat.identity).appendingPathComponent("current/cookies.db"))
    }
    func hasSavedLogin(_ seat: StandSeat) -> Bool { savedAt(seat) != nil }
    /// When the seat's login was last saved, so a scenario can tell it was left untouched.
    func savedAt(_ seat: StandSeat) -> Date? { SavedLogins.savedAt(seat.identity) }
    /// The Mac wakes from sleep (the app's NSWorkspace.didWakeNotification).
    func wake() { store.woke() }
    /// The app is quit or crashes: its parked tasks never wake, and a new app starts on the same files.
    func crashApp() { clock.abandonSleepers(); Switch.abandonForTest(); store = Store() }
    func click(_ row: String) {
        guard let s = store.seats.first(where: { $0.name == row }) else { check(false, "no row named \(row)"); return }
        if s.action == .setUp { store.setUp(s) } else { store.switchTo(s) }
    }
}
