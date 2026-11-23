// The menu's views: rows, cards, meters, the sign-in sheet and the menu bar icon.

import AppKit
import SwiftUI

// MARK: - Views

extension Color {
    init(hex: String?) {
        var s = (hex ?? "#2C5B4E").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x2C5B4E
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Good below 60 %, warning from 60 %, critical from 80 %; kept separate from the per-account colors.
func severity(_ pct: Int) -> Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

/// Named account colors, offered in each row's Color menu; new accounts take the first unused one.
let accountColors: [(name: String, hex: String)] = [
    ("Blue", "#3567CF"), ("Orange", "#B96E22"), ("Pink", "#B3405F"), ("Green", "#2C8A5E"),
    ("Purple", "#6B5BD2"), ("Teal", "#1F8A9A"), ("Red", "#C8412F"), ("Gray", "#7A8088"),
]
let presetColors = accountColors.map(\.hex)

/// The capsule in the action slot of the row in use.
struct Badge: View {
    let text: String

    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    }
}

/// The card an account sits on. Fill and edge are system colors over the menu's vibrancy, so they
/// follow light, dark and increased contrast; increased contrast draws the edge in the label color.
struct Card<Content: View>: View {
    var fill: AnyShapeStyle = AnyShapeStyle(Color(nsColor: .quaternarySystemFill))
    /// The in-use account's accent edge; nil draws the quiet outline.
    var edge: Color? = nil
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        // The separator color is too faint to outline a card over the menu's vibrancy; the tertiary
        // label color is the next system gray, lighter in dark mode and darker in light.
        let quiet = contrast == .increased ? Color.primary.opacity(0.55) : Color(nsColor: .tertiaryLabelColor)
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge ?? quiet, lineWidth: edge == nil ? 1 : 1.5))
            .clipShape(shape)
    }
}

struct Meter: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(window.map { "\($0.pct)%" } ?? "n/a").monospacedDigit().fontWeight(.semibold)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    if let w = window {
                        Capsule().fill(severity(w.pct))
                            .frame(width: geo.size.width * CGFloat(min(max(w.pct, 0), 100)) / 100)
                    }
                }
            }
            .frame(height: 5)
            if let w = window {
                Text(w.resetText).font(.caption2)
                    .foregroundStyle(w.resetsSoon ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .fontWeight(w.resetsSoon ? .semibold : .regular)
            }
        }
        .font(.caption)
    }
}

/// A name that turns into a text field while it is renamed: Return saves, Escape cancels, and an
/// empty name puts the default name back.
struct RenameField: View {
    let current: String
    @Binding var renaming: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .focused($focused)
            .onAppear { draft = current; focused = true }
            .onSubmit { onCommit(draft); renaming = false }
            .onExitCommand { renaming = false }
    }
}

/// The account colors, with the current one checked.
struct ColorMenu: View {
    let current: String
    let onPick: (String) -> Void

    var body: some View {
        Menu("Color") {
            ForEach(accountColors, id: \.hex) { color in
                Button { onPick(color.hex) } label: {
                    if color.hex == current { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                }
            }
        }
    }
}

/// Move Up and Move Down in a row's menu: the menu's order is the order auto-switch tries rows in.
/// Each is nil where the row is already at that end; with neither, the menu leaves them out.
struct RowMoves {
    let up: (() -> Void)?
    let down: (() -> Void)?

    @ViewBuilder var items: some View {
        if up != nil || down != nil {
            Divider()
            Button("Move Up") { up?() }.disabled(up == nil)
            Button("Move Down") { down?() }.disabled(down == nil)
        }
    }
}

/// The mark on the row the next automatic switch goes to.
struct NextMark: View {
    var body: some View {
        Text("Next").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            .help("Auto-switch goes here next when Claude stops a chat for usage. Move rows up or down from their ··· menu to change the order.")
    }
}

/// The name above an account's organizations: clicking it shows or folds them away, and its own
/// menu renames or recolors the account.
struct AccountHeader: View {
    let name: String
    let color: String
    let shown: Bool
    /// Folded away while one of the organizations is in use.
    let inUse: Bool
    /// Folded away while the next automatic switch goes to one of the organizations.
    let next: Bool
    let canReset: Bool
    let onFold: () -> Void
    let onRename: (String) -> Void
    let onRecolor: (String) -> Void
    let move: RowMoves
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 8) {
            if renaming {
                Circle().fill(Color(hex: color)).frame(width: 9, height: 9)
                RenameField(current: name, renaming: $renaming, onCommit: onRename)
            } else {
                Button(action: onFold) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: color)).frame(width: 9, height: 9)
                        Text(name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(shown ? 90 : 0))
                        if next { NextMark() }
                        Spacer()
                        if inUse { Badge(text: "In use") }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shown ? "Hide this account's organizations" : "Show this account's organizations")
                .accessibilityLabel(name)
                .accessibilityValue(shown ? "Organizations shown" : "Organizations hidden")
            }
            Menu {
                Button("Rename…") { renaming = true }
                if canReset { Button("Reset Name") { onRename("") } }
                ColorMenu(current: color, onPick: onRecolor)
                move.items
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(name) options")
        }
    }
}

struct AccountRow: View {
    let account: AccountRecord
    let state: AccountState?
    let inUse: Bool
    /// The next automatic switch goes to this row.
    let next: Bool
    /// Another organization of this row's account is the one in use.
    let sameAccountInUse: Bool
    let canSwitch: Bool
    /// How to set up a row Claude has no saved login for yet; nil once it has one or is in use.
    let setUpStep: String?
    let switchBusy: Bool
    let onSwitch: () -> Void
    let onSetUp: () -> Void
    let retryAt: Date?
    let onSignIn: () -> Void
    let onRename: (String) -> Void
    /// Reset Name would change the name, so the row offers it.
    let canReset: Bool
    let onRecolor: (String) -> Void
    let onRemove: () -> Void
    let move: RowMoves
    /// Set when the row is shown under its account's name as one of that account's organizations.
    var organizationTitle: String? = nil
    private var organizationEntry: Bool { organizationTitle != nil }
    @State private var confirmingRemove = false
    @State private var renaming = false

    /// "Login expires in 5 h" inside the warning window, nil otherwise.
    private var expiryWarning: String? {
        guard case .ok(_, _, _, let expires?) = state, expires.timeIntervalSinceNow < API.signInWarning else { return nil }
        let hours = max(Int(expires.timeIntervalSinceNow / 3600), 0)
        return hours > 0 ? "Login expires in \(hours) h." : "Login expires within the hour."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // An organization entry lines up under its account's dot instead of repeating it.
                Circle().fill(organizationEntry ? Color.clear : Color(hex: account.color)).frame(width: 9, height: 9)
                if renaming {
                    RenameField(current: organizationTitle ?? account.name, renaming: $renaming, onCommit: onRename)
                } else {
                    Text(organizationTitle ?? account.name)
                        .fontWeight(organizationEntry ? .regular : .semibold).lineLimit(1).truncationMode(.middle)
                        .help(account.label)
                    if case .ok(let plan?, _, _, _) = state {
                        Text(plan.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if next { NextMark() }
                }
                Spacer()
                // One fixed box for both, so "In use" and Switch share a center line and right edge.
                Group {
                    switch RowAction.pick(inUse: inUse, hasSavedLogin: canSwitch) {
                    case .inUse:
                        Badge(text: "In use")
                    case .switchTo:
                        Button("Switch", action: onSwitch).controlSize(.small).disabled(switchBusy)
                            .help(organizationEntry ? "Quit Claude, switch it to this organization, and bring your open sessions along"
                                                    : "Quit Claude, sign it in as this account, and bring your open sessions along")
                    case .setUp:
                        Button("Set Up", action: onSetUp).controlSize(.small).disabled(switchBusy)
                            .help(sameAccountInUse
                                  ? "Shows how to save this organization: choose it once in Claude's own account menu"
                                  : "Quit Claude, save the account it's using, and reopen it at the sign-in page for this account")
                    }
                }
                .frame(width: 62, height: 22, alignment: .trailing)
                Menu {
                    // An organization entry's name is its organization; the account's menu is on its name above.
                    if !organizationEntry {
                        Text(account.organization)
                        Divider()
                    }
                    Button("Rename…") { renaming = true }
                    if canReset { Button("Reset Name") { onRename("") } }
                    if !organizationEntry { ColorMenu(current: account.color, onPick: onRecolor) }
                    move.items
                    Divider()
                    Button("Sign in again…", action: onSignIn)
                    Button("Remove…") { confirmingRemove = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            switch state {
            case .ok(_, let fh, let wk, _):
                if MeterRule.showsFiveHour(fiveHour: fh, weekly: wk) { Meter(label: "5-hour", window: fh) }
                Meter(label: "Weekly", window: wk)
                if let warning = expiryWarning { signInPrompt(warning) }
                if let until = retryAt, until > World.now() {
                    Text("Rate-limited by the usage service · retrying at \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            case .rateLimited(let until):
                Text("Waiting for the usage service · retrying at \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            case .needsLogin(let why):
                signInPrompt(why)
            case .error(let why):
                Text(why).font(.caption).foregroundStyle(.orange)
            case .loading, nil:
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            if let setUpStep {
                Text("Not set up: \(setUpStep).").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirmingRemove {
                HStack {
                    Text("Remove \(account.label) from this app?").font(.caption)
                    Spacer()
                    Button("Cancel") { confirmingRemove = false }.controlSize(.small)
                    Button("Remove", role: .destructive) { confirmingRemove = false; onRemove() }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        // Inside an account's card, the organization in use is lit; a one-row card lights itself.
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(inUse && organizationEntry ? Color.accentColor.opacity(0.12) : .clear)
            .padding(3))
    }

    private func signInPrompt(_ reason: String) -> some View {
        HStack {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Sign in again", action: onSignIn).controlSize(.small)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Usage is the point of the menu; the rare setup actions live behind the header's ···.
            HStack(spacing: 4) {
                Text("Claude Accounts").font(.headline)
                Spacer()
                RefreshButton(store: store)
                Menu {
                    Button("Add Account…") { openSignIn(nil) }
                    Divider()
                    Picker("Menu Bar Shows", selection: $store.settings.display) {
                        ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Gauge Tracks", selection: $store.settings.metric) {
                        ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Toggle("Auto-Switch When Out", isOn: Binding(get: { store.settings.autoSwitch },
                                                                set: { store.setAutoSwitch($0) }))
                        .help("When Claude stops a chat because the account in use is out of usage, quit Claude, reopen it on the next account in this menu's order that has room, and send \u{201C}resume\u{201D} to the chats that were working")
                    Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { _ in store.toggleOpenAtLogin() }))
                    Divider()
                    Button("Quit Claude Accounts") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            if let step = store.switching {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(step).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if let msg = store.message {
                // Wraps to every line it needs: a cut-off instruction can't be followed.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(msg).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.messageStays {
                        Button { store.closeMessage() } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Close").accessibilityLabel("Close message")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if store.settings.autoSwitch, !store.accessibilityGranted {
                HStack {
                    if store.accessibilityGrantedBefore {
                        // macOS keeps the old entry switched on, so allowing it again does nothing until it is replaced.
                        Text("After an update, macOS needs Accessibility allowed again. Remove Claude Accounts from the Accessibility list with \u{201C}\u{2212}\u{201D}, then add it again.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Settings…") { store.openAccessibilitySettings() }.controlSize(.small)
                    } else {
                        Text("Auto-switch moves Claude to another account when Claude stops a chat at the usage limit. Allow Accessibility so it can answer Claude's quit prompt and send \u{201C}resume\u{201D} to the chats that were working.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") { store.setAutoSwitch(true) }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
            if store.accounts.isEmpty {
                Text("No accounts yet. Add one to see its 5-hour and weekly usage here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            // One card per account; an account in several organizations lists each beneath its
            // name, shown until its name is clicked to fold them away.
            let groups = store.accounts.groupedByAccount()
            let next = store.nextRow
            VStack(alignment: .leading, spacing: 6) {
                ForEach(groups, id: \.[0].id) { group in accountCard(group, next: next) }
            }
            .padding(.top, 2)
        }
        .padding(6)
        .frame(width: 330)
        .onAppear {
            store.checkAccessibility()
            store.refreshIfStale()
        }
    }

    private func row(_ acct: AccountRecord, in group: [AccountRecord], next: String?, organizationTitle: String? = nil) -> some View {
        AccountRow(account: acct, state: store.states[acct.id], inUse: store.isInUse(acct), next: acct.id == next,
                   sameAccountInUse: !store.isInUse(acct) && acct.accountUuid != nil && acct.accountUuid == store.inUse?.account,
                   canSwitch: store.hasSavedLogin(acct),
                   // The status line already says it once Set Up was clicked.
                   setUpStep: store.hasSavedLogin(acct) || (store.isInUse(acct) && !store.isRefused(acct))
                       || store.messageEndsWithSetUp == acct.id ? nil
                       : SetUpRule.step(for: acct, claudeAccount: store.inUse?.account, refused: store.isRefused(acct)),
                   switchBusy: store.switching != nil,
                   onSwitch: { store.switchTo(acct) }, onSetUp: { store.setUp(acct) },
                   retryAt: store.retryAt[acct.id],
                   onSignIn: { openSignIn(acct) },
                   onRename: { store.rename(acct, to: $0, organization: organizationTitle != nil) },
                   canReset: store.accounts.renamed(acct, to: "", organization: organizationTitle != nil)
                       .first { $0.id == acct.id }.map { $0.label != acct.label } ?? false,
                   // An account's color is shared by all of its organizations.
                   onRecolor: { store.recolor(acct, $0) },
                   onRemove: { store.remove(acct) },
                   move: moves(acct, organization: organizationTitle != nil),
                   organizationTitle: organizationTitle)
    }

    /// The name above an account's organizations, which folds them away.
    private func header(_ group: [AccountRecord], next: String?) -> some View {
        let account = group[0].accountUuid ?? group[0].id
        let shown = store.settings.showsOrganizations(of: account)
        return AccountHeader(name: group[0].name, color: group[0].color, shown: shown,
                             inUse: !shown && group.contains(where: store.isInUse),
                             next: !shown && group.contains { $0.id == next },
                             canReset: store.accounts.renamed(group[0], to: "", organization: false).first { $0.id == group[0].id }?.name != group[0].name,
                             onFold: {
                                 withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { store.setShowsOrganizations(of: account, !shown) }
                             },
                             onRename: { store.rename(group[0], to: $0, organization: false) },
                             onRecolor: { store.recolor(group[0], $0) },
                             move: moves(group[0], organization: false))
    }

    private func shown(_ group: [AccountRecord]) -> Bool {
        store.settings.showsOrganizations(of: group[0].accountUuid ?? group[0].id)
    }

    /// One card per account. Its organizations are rows inside, split by hairlines; the
    /// card of the account in use has an accent edge and its organization in use is lit.
    private func accountCard(_ group: [AccountRecord], next: String?) -> some View {
        let inUse = group.contains(where: store.isInUse)
        return Card(fill: AnyShapeStyle(inUse && group.count == 1 ? Color.accentColor.opacity(0.12)
                                        : Color(nsColor: .quaternarySystemFill)),
                    edge: inUse ? .accentColor : nil) {
            VStack(alignment: .leading, spacing: 0) {
                if group.count == 1 {
                    row(group[0], in: group, next: next)
                } else {
                    header(group, next: next).padding(.horizontal, 10).padding(.vertical, 8)
                    if shown(group) {
                        ForEach(group) { acct in
                            Divider().padding(.leading, 27)
                            row(acct, in: group, next: next, organizationTitle: acct.organization)
                        }
                    }
                }
            }
        }
    }

    /// Move Up and Move Down for a row's menu, each nil where the row is already at that end.
    private func moves(_ acct: AccountRecord, organization: Bool) -> RowMoves {
        func step(_ by: Int) -> (() -> Void)? {
            store.accounts.moved(acct, by: by, organization: organization) == nil ? nil
                : { store.move(acct, by: by, organization: organization) }
        }
        return RowMoves(up: step(-1), down: step(1))
    }


    /// One window serves both jobs: adding an account (nil) or signing one in again.
    private func openSignIn(_ acct: AccountRecord?) {
        store.signInTarget = acct
        openWindow(id: "sign-in")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The header's refresh control. It spins while a read runs, and for a moment on every click,
/// so a click always shows it registered even when every account was read seconds ago.
struct RefreshButton: View {
    @ObservedObject var store: Store
    @State private var clickSpin = false

    var body: some View {
        Button {
            clickSpin = true
            store.refresh(manual: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { clickSpin = false }
        } label: {
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate, options: .speed(1.5), isActive: store.loading || clickSpin)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("r")
        .help((store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened)). " } ?? "")
              + "Each account updates about once a minute. Refresh (⌘R)")
    }
}

/// Adds a new account, or signs an existing one in again when `store.signInTarget` is set.
struct SignInView: View {
    @ObservedObject var store: Store
    @StateObject private var flow = LoginFlow()
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var code = ""
    @State private var target: AccountRecord?

    private var busy: Bool {
        switch flow.phase {
        case .starting, .waitingForCode, .verifying: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.map { "Sign in again: \($0.label)" } ?? "Add a Claude account")
                .font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            steps
        }
        .padding(20)
        .frame(width: 400)
        // Opening this window is the request, so the login starts at once.
        .onAppear {
            target = store.signInTarget
            if flow.phase == .idle { flow.start(reauth: target) }
        }
        .onDisappear {
            if busy { flow.cancel() } else { flow.reset() }
            store.signInTarget = nil
        }
    }

    private func restart(reauth: AccountRecord?, organization: String? = nil, email: String? = nil) {
        code = ""
        target = reauth
        flow.reset()
        flow.start(reauth: reauth, organization: organization, email: email)
    }

    private func close() { dismissWindow(id: "sign-in") }

    @ViewBuilder private var steps: some View {
        switch flow.phase {
        case .idle, .starting:
            HStack { ProgressView().controlSize(.small); Text("Opening the sign-in page in your browser…").font(.callout) }
        case .waitingForCode:
            Text(target.map { "In your browser, choose Continue with Google and pick the account \($0.label) belongs to. After you click Authorize, the page shows a code. Paste it here." }
                 ?? "In your browser, choose Continue with Google and pick the account to add. After you click Authorize, the page shows a code. Paste it here.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField("Paste the code", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .onSubmit { flow.submit(code: code) }
            HStack {
                Button("Open the page again") { flow.openLoginPage() }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { flow.cancel(); close() }
                Button(target == nil ? "Add account" : "Sign in") { flow.submit(code: code) }
                    .keyboardShortcut(.defaultAction).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Checking the code…").font(.callout) }
        case .done(let who, let next):
            Label(target == nil ? "Added \(who)." : "Signed in again as \(who).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let next { Text(next).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if target == nil { Button("Add another") { restart(reauth: nil) } }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
            .onAppear { store.refresh(forcing: target?.id) }
        case .otherOrganization(let other):
            Text("That organization is already added as \(other.existing). To add this account's other organization, sign in once more"
                 + (other.known == nil ? " and choose the other organization on the page before you click Authorize."
                                       : "; the page picks the other organization for you."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { close() }
                Spacer()
                Button("Add Other Organization") { restart(reauth: nil, organization: other.known, email: other.email) }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { close() }
                Spacer()
                Button("Try again") { restart(reauth: target) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The whole menu bar item drawn as one template image, so alignment is exact by construction:
/// the text's visual middle (half its cap height above the baseline) sits at the image's middle,
/// and each glyph is centred on that same line by its drawn shape rather than its box. macOS
/// tints template images for light and dark menu bars and centres the image in the bar.
func menuBarImage(title: String, fraction: Double, warning: Bool) -> NSImage {
    let base = NSFont.menuBarFont(ofSize: 0)
    // Fixed-width digits, so the percentage doesn't shift the item as it changes.
    let font = NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
    let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.black])
    let height: CGFloat = 22, glyphWidth: CGFloat = 16, gap: CGFloat = 4
    let textWidth = title.isEmpty ? 0 : ceil(text.size().width)
    let width = glyphWidth + (title.isEmpty ? 0 : gap + textWidth)
    let middle = height / 2

    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        if warning { drawWarning(centeredAt: NSPoint(x: glyphWidth / 2, y: middle)) }
        else { drawGauge(fraction, centeredAt: NSPoint(x: glyphWidth / 2, y: middle)) }
        if !title.isEmpty {
            // Baseline chosen so the midpoint of the capitals and digits lands on `middle`.
            text.draw(at: NSPoint(x: glyphWidth + gap, y: middle - font.capHeight / 2 + font.descender))
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = title.isEmpty ? "Claude Accounts" : title
    return image
}

/// A speedometer: a 270° arc filled to `fraction`, a needle at the same angle, and a hub.
/// Centred on its ink: the open-bottomed arc reaches `radius` above its centre but only
/// radius·sin45° below it, and the stroke's half-width pads both ends equally.
private func drawGauge(_ fraction: Double, centeredAt mid: NSPoint) {
    let value = CGFloat(min(max(fraction, 0), 1))
    let radius: CGFloat = 6, stroke: CGFloat = 1.7, sweep: CGFloat = 270, start: CGFloat = 225
    let center = NSPoint(x: mid.x, y: mid.y - (radius - radius * sin(.pi / 4)) / 2)
    let angle = start - sweep * value

    func arc(to end: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = stroke
        path.lineCapStyle = .round
        return path
    }
    // Template images keep only alpha, so the unused part of the arc is a fainter shade.
    NSColor.black.withAlphaComponent(0.35).setStroke()
    arc(to: start - sweep).stroke()
    NSColor.black.setStroke()
    if value > 0.01 { arc(to: angle).stroke() }

    let rad = angle * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(rad) * radius * 0.62, y: center.y + sin(rad) * radius * 0.62))
    needle.lineWidth = 1.6
    needle.lineCapStyle = .round
    needle.stroke()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
}

/// A rounded warning triangle with the exclamation mark cut out, centred on its ink.
private func drawWarning(centeredAt mid: NSPoint) {
    let w: CGFloat = 14, h: CGFloat = 12.5
    let bottom = mid.y - h / 2
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: mid.x, y: bottom + h))
    triangle.line(to: NSPoint(x: mid.x + w / 2, y: bottom))
    triangle.line(to: NSPoint(x: mid.x - w / 2, y: bottom))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = 2
    NSColor.black.set()
    triangle.fill()
    triangle.stroke()
    // Punch the mark out of the fill so the menu bar shows through it.
    NSGraphicsContext.current?.compositingOperation = .clear
    NSBezierPath(roundedRect: NSRect(x: mid.x - 0.9, y: bottom + 4.4, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
    NSBezierPath(ovalIn: NSRect(x: mid.x - 1, y: bottom + 1.6, width: 2, height: 2)).fill()
    NSGraphicsContext.current?.compositingOperation = .sourceOver
}
