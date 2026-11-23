import Foundation

// What the person sees, read from the Store's seats and notice (model, sections 3 and 11). The
// scenarios assert only through this, so they stay in the model's words.

enum ShownState: Equatable { case switching, inUse, needsSignIn, out, ready }
enum ShownAction: Equatable { case switchTo, setUp }

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
    func action(_ row: String) -> ShownAction? {
        switch store.seats.first(where: { $0.name == row })?.action {
        case .switchTo?: return .switchTo
        case .setUp?: return .setUp
        case nil: return nil
        }
    }
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
    func hasSavedLogin(_ seat: StandSeat) -> Bool { SavedLogins.savedAt(seat.identity) != nil }
    /// The app is quit or crashes: its parked tasks never wake, and a new app starts on the same files.
    func crashApp() { clock.abandonSleepers(); Switch.abandonForTest(); store = Store() }
    func click(_ row: String) {
        guard let s = store.seats.first(where: { $0.name == row }) else { check(false, "no row named \(row)"); return }
        if s.action == .setUp { store.setUp(s) } else { store.switchTo(s) }
    }
}
