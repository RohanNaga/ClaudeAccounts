import Foundation

// The same view of what the person sees, read from build 10's Store (before the seat model), so
// the scenarios give a total on build 10 too. Build 10 has no tick: one pass of its 15 s timer is
// called here instead, without its private steady save.

enum ShownState: Equatable { case switching, inUse, needsSignIn, out, ready }
enum ShownAction: Equatable { case switchTo, setUp }

@MainActor extension Harness {
    func make() { store = Store() }
    /// A saved login for a seat, taken through build 10's own capture while Claude is closed.
    func savedLogin(_ row: String, _ seat: StandSeat) async throws {
        guard let acct = AccountStore.load().first(where: { $0.name == row }) else { throw SwitchError.inconsistent }
        claude.writeSignIn(seat)
        do { try await LoginSlot.capture(acct, as: seat.identity) }
        catch { check(false, "setup: saving \(row)'s login threw \(error)"); throw error }
    }
    func tick() async { store.checkAccessibility(); store.refresh(); store.considerAutoSwitch() }
    private func record(_ row: String) -> AccountRecord? { store.accounts.first { $0.name == row } }
    func state(_ row: String) -> ShownState? {
        guard let r = record(row) else { return nil }
        if store.isInUse(r) { return .inUse }
        if !store.hasSavedLogin(r) || store.isRefused(r) { return .needsSignIn }
        if case .ok(_, let five, let week, _)? = store.states[r.id], max(five?.utilization ?? 0, week?.utilization ?? 0) >= 100 { return .out }
        return .ready
    }
    func action(_ row: String) -> ShownAction? {
        guard let r = record(row) else { return nil }
        switch RowAction.pick(inUse: store.isInUse(r), hasSavedLogin: store.hasSavedLogin(r)) {
        case .inUse: return nil
        case .switchTo: return .switchTo
        case .setUp: return .setUp
        }
    }
    var notice: [String] { [store.switching, store.message].compactMap { $0 } }
    var rowNames: [String] { store.accounts.map(\.label) }
    func meterText(_ row: String) -> String? { nil }
    func rename(_ row: String, to name: String) { check(false, "build 10 has no rename by seat") }
    func move(_ row: String, by step: Int) { check(false, "build 10 has no move by seat") }
    func remove(_ row: String) { if let r = record(row) { store.remove(r) } }
    var firstRun: Bool { store.accounts.isEmpty }
    func hasSavedLogin(_ seat: StandSeat) -> Bool { store.accounts.contains { $0.accountUuid == seat.account && $0.orgUuid == seat.org && store.hasSavedLogin($0) } }
    func crashApp() { clock.abandonSleepers(); store = Store() }
    func click(_ row: String) {
        guard let r = record(row) else { check(false, "no row named \(row)"); return }
        if action(row) == .setUp { store.setUp(r) } else { store.switchTo(r) }
    }
}
