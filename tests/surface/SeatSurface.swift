import Foundation

// What the person sees, read from the Store's seats and notice (model, sections 3 and 11). The
// scenarios assert only through this, so they stay in the model's words.

enum ShownState: Equatable { case switching, inUse, needsSignIn, out, ready }
enum ShownAction: Equatable { case switchTo, setUp }

@MainActor extension Harness {
    func make() { store = Store() }
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
    func click(_ row: String) {
        guard let s = store.seats.first(where: { $0.name == row }) else { check(false, "no row named \(row)"); return }
        if s.action == .setUp { store.setUp(s) } else { store.switchTo(s) }
    }
}
