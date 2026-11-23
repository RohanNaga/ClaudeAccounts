import Foundation

// The same view of what the person sees, read from build 10's Store (before the seat model), so
// the scenarios give a total on build 10 too. Build 10 has no tick: one pass of its 15 s timer is
// called here instead, without its private steady save.

enum ShownState: Equatable { case switching, inUse, needsSignIn, out, ready }
enum ShownAction: Equatable { case switchTo, setUp }

@MainActor extension Harness {
    func make() { store = Store() }
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
    func click(_ row: String) {
        guard let r = record(row) else { check(false, "no row named \(row)"); return }
        if action(row) == .setUp { store.setUp(r) } else { store.switchTo(r) }
    }
}
