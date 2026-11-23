// The menu's views: the title bar, the one notice, a card per account with a row per seat, the
// first-run screen, the sign-in window and the menu bar icon.

import AppKit
import SwiftUI

// MARK: - Layout

/// The menu's measures. Every row is drawn at a fixed height, so the menu's height is arithmetic
/// over its rows, and `height` is the same number the drawn menu measures.
enum MenuLayout {
    static let width: CGFloat = 330
    /// Around the whole menu.
    static let padding: CGFloat = 6
    static let titleBar: CGFloat = 30
    static let notice: CGFloat = 24
    static let cardGap: CGFloat = 6
    /// A one-line row, and the account's name above a card's organizations.
    static let line: CGFloat = 30
    /// One meter under the row in use or an expanded row.
    static let meterLine: CGFloat = 18
    /// Below a row's meters, so the last one doesn't touch the card's edge.
    static let meterFoot: CGFloat = 6
    /// Between the rows of a card with several organizations.
    static let hairline: CGFloat = 1
    /// Kept clear below the menu, so it never reaches the screen's bottom edge or the Dock.
    static let screenMargin: CGFloat = 24
    /// The cards never scroll in less than this, so a very short screen still shows a few rows.
    static let minimumCards: CGFloat = 3 * line

    /// The seats in cards: one per account, in the order each account first appears, so an
    /// account's organizations sit together.
    static func cards(_ seats: [Seat]) -> [[Seat]] {
        var cards: [[Seat]] = []
        for seat in seats {
            if let i = cards.firstIndex(where: { $0[0].id.account == seat.id.account }) { cards[i].append(seat) }
            else { cards.append([seat]) }
        }
        return cards
    }

    /// The meters a row lists when it shows both: the 5-hour one only for a plan that has it.
    static func meterLines(_ meters: SeatMeters) -> [(label: String, meter: MeterReading?)] {
        let fiveHour = meters.fiveHour != nil || meters.weekly == nil
        return (fiveHour ? [("5-hour", meters.fiveHour)] : []) + [("Weekly", meters.weekly)]
    }

    /// Whether a row shows both meters: the seat in use always, another seat while it is expanded
    /// and has a reading to show.
    static func showsMeters(_ seat: Seat, expanded: Identity?) -> Bool {
        seat.state == .inUse || (seat.id == expanded && (seat.meters.fiveHour != nil || seat.meters.weekly != nil))
    }

    static func rowHeight(_ seat: Seat, expanded: Identity?) -> CGFloat {
        showsMeters(seat, expanded: expanded)
            ? line + CGFloat(meterLines(seat.meters).count) * meterLine + meterFoot
            : line
    }

    static func cardHeight(_ card: [Seat], expanded: Identity?) -> CGFloat {
        let rows = card.reduce(0) { $0 + rowHeight($1, expanded: expanded) }
        return card.count == 1 ? rows : line + CGFloat(card.count) * hairline + rows
    }

    /// Everything above the cards, plus the menu's padding: the part that never scrolls.
    static func chrome(hasNotice: Bool) -> CGFloat { 2 * padding + titleBar + (hasNotice ? notice : 0) }

    static func cardsHeight(seats: [Seat], expanded: Identity?) -> CGFloat {
        let cards = cards(seats)
        return cards.reduce(0) { $0 + cardHeight($1, expanded: expanded) } + CGFloat(max(cards.count - 1, 0)) * cardGap
    }

    /// The menu's height if the screen were tall enough for every row.
    static func contentHeight(seats: [Seat], hasNotice: Bool, expanded: Identity? = nil) -> CGFloat {
        chrome(hasNotice: hasNotice) + cardsHeight(seats: seats, expanded: expanded)
    }

    /// The menu's height on a screen whose visible part (below the menu bar) is
    /// `visibleScreenHeight` tall: every row when they fit, else as tall as the screen allows,
    /// with the cards scrolling under the pinned title bar and notice.
    static func height(visibleScreenHeight: CGFloat, seats: [Seat], hasNotice: Bool, expanded: Identity? = nil) -> CGFloat {
        chrome(hasNotice: hasNotice) + cardsViewport(visibleScreenHeight: visibleScreenHeight, seats: seats,
                                                     hasNotice: hasNotice, expanded: expanded)
    }

    /// The height the cards get, which scroll when it is less than they need.
    static func cardsViewport(visibleScreenHeight: CGFloat, seats: [Seat], hasNotice: Bool, expanded: Identity?) -> CGFloat {
        let room = max(visibleScreenHeight - screenMargin - chrome(hasNotice: hasNotice), minimumCards)
        return min(cardsHeight(seats: seats, expanded: expanded), room)
    }
}

// MARK: - Pieces

/// Good below 60 %, warning from 60 %, critical from 80 %.
func severity(_ pct: Int) -> Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

/// A reset time as short as it reads: "3:40 PM" today, "Thu 3:40 PM" this week, "Dec 2" later.
/// A one-line row says only the day of a reset after today ("Thu"); its meters say the hour.
func shortReset(_ date: Date?, now: Date, dayOnly: Bool = false) -> String? {
    guard let date, date > now else { return nil }
    if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if date.timeIntervalSince(now) < 6 * 86400 {
        return date.formatted(dayOnly ? .dateTime.weekday(.abbreviated) : .dateTime.weekday(.abbreviated).hour().minute())
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

/// A meter's bar. A stale reading draws faded, so its colour doesn't claim more than it knows.
struct MeterBar: View {
    let meter: MeterReading?
    var stale = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let meter {
                    Capsule().fill(severity(Int(meter.percent.rounded())))
                        .frame(width: geo.size.width * CGFloat(min(max(meter.percent, 0), 100)) / 100)
                }
            }
        }
        .frame(height: 5)
        .opacity(stale ? 0.4 : 1)
        .accessibilityHidden(true)
    }
}

/// One meter on its own line: its name, its bar, its percent and when it resets.
struct MeterLine: View {
    let label: String
    let meter: MeterReading?
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            MeterBar(meter: meter, stale: stale)
            Text(meter.map { "\(Int($0.percent.rounded()))%" } ?? "–").monospacedDigit().fontWeight(.semibold)
                .frame(width: 34, alignment: .trailing)
            Text(meter.flatMap { shortReset($0.resetsAt, now: now) }.map { "resets \($0)" } ?? "")
                .foregroundStyle(.tertiary).lineLimit(1)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.caption)
        .frame(height: MenuLayout.meterLine)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(meter.map { m in
            "\(Int(m.percent.rounded())) percent" + (shortReset(m.resetsAt, now: now).map { ", resets \($0)" } ?? "")
        } ?? "not read")
    }
}

/// The capsule on the row in use.
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

/// The "···" button that opens a row's or an account's menu.
struct MoreMenu<Items: View>: View {
    let name: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(name) options")
    }
}

// MARK: - The menu

/// What the menu's controls do. The app wires them to the store; a render or a test leaves them empty.
struct MenuActions {
    var switchTo: (Seat) -> Void = { _ in }
    var setUp: (Seat) -> Void = { _ in }
    var rename: (Seat, String, _ organization: Bool) -> Void = { _, _, _ in }
    var canMove: (Seat, _ by: Int, _ organization: Bool) -> Bool = { _, _, _ in false }
    var move: (Seat, _ by: Int, _ organization: Bool) -> Void = { _, _, _ in }
    var remove: (Seat) -> Void = { _ in }
    /// Opens the sign-in window for a seat's meters, or for a new seat when nil.
    var signIn: (Seat?) -> Void = { _ in }
    var notice: (NoticeAction) -> Void = { _ in }
    var closeNotice: () -> Void = {}
    var refresh: () -> Void = {}
    var setAutoSwitch: (Bool) -> Void = { _ in }
    var toggleOpenAtLogin: () -> Void = {}

    static let none = MenuActions()
}

/// The title bar's live values.
struct MenuHeader {
    var refreshing = false
    var autoSwitch = true
    var openAtLogin = false
    var updatedAt: Date?
}

/// The whole menu, drawn from values only: the store's adapter is `MenuContent`.
struct MenuPanel: View {
    let seats: [Seat]
    let notice: Notice?
    let firstRun: Bool
    /// NSScreen.visibleFrame.height of the screen the menu opens on.
    let visibleScreenHeight: CGFloat
    var header = MenuHeader()
    var actions = MenuActions.none
    var now: Date = World.now()
    /// The one row expanded to both meters. Never remembered: it is cleared whenever the menu opens.
    @State var expanded: Identity? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TitleBar(header: header, actions: actions)
            if firstRun {
                FirstRunView()
            } else {
                if let notice { NoticeLine(notice: notice, actions: actions) }
                cards
            }
        }
        .padding(MenuLayout.padding)
        .frame(width: MenuLayout.width)
        // The menu window can be kept between openings, so the expansion is dropped on close.
        .onDisappear { expanded = nil }
    }

    private var cards: some View {
        let busy = seats.contains { if case .switching = $0.state { return true } else { return false } }
        let inUseCard = MenuLayout.cards(seats).first { $0.contains { $0.state == .inUse } }?[0].id.account
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: MenuLayout.cardGap) {
                    ForEach(MenuLayout.cards(seats), id: \.[0].id.account) { card in
                        AccountCard(seats: card, expanded: $expanded, busy: busy, actions: actions, now: now)
                            .id(card[0].id.account)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: MenuLayout.cardsViewport(visibleScreenHeight: visibleScreenHeight, seats: seats,
                                                    hasNotice: notice != nil, expanded: expanded))
            .onAppear { if let inUseCard { proxy.scrollTo(inUseCard, anchor: .center) } }
        }
    }
}

/// "Claude Accounts", refresh, and the menu of the rare actions and the one setting.
struct TitleBar: View {
    let header: MenuHeader
    let actions: MenuActions
    @State private var clickSpin = false

    var body: some View {
        HStack(spacing: 4) {
            Text("Claude Accounts").font(.headline)
            Spacer()
            Button {
                // Spins for a moment on every click, so a click shows it registered even when every
                // seat was read seconds ago.
                clickSpin = true
                actions.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { clickSpin = false }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, options: .speed(1.5), isActive: header.refreshing || clickSpin)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help((header.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened)). " } ?? "") + "Refresh (⌘R)")
            .accessibilityLabel("Refresh")
            MoreMenu(name: "Claude Accounts") {
                Button("Add Account…") { actions.signIn(nil) }
                Divider()
                Toggle("Auto-Switch When Out", isOn: Binding(get: { header.autoSwitch }, set: { actions.setAutoSwitch($0) }))
                    .help("When Claude stops a chat because the seat in use is out of usage, quit Claude, reopen it on the next seat in this menu's order that has room, and send \u{201C}resume\u{201D} to the chats that were working")
                Toggle("Open at Login", isOn: Binding(get: { header.openAtLogin }, set: { _ in actions.toggleOpenAtLogin() }))
                Divider()
                Button("Quit Claude Accounts") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.titleBar)
    }
}

/// The one notice: the most important thing the person should know, on one line. A longer
/// explanation, when there is one, is its tooltip.
struct NoticeLine: View {
    let notice: Notice
    let actions: MenuActions

    var body: some View {
        HStack(spacing: 6) {
            if notice.kind == .switching { ProgressView().controlSize(.mini) }
            Text(notice.text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(notice.detail ?? notice.text)
            if let action = notice.action {
                Button(action == .openAccessibility ? "Allow…" : "Add") { actions.notice(action) }
                    .controlSize(.small)
            }
            if notice.kind == .success {
                Button { actions.closeNotice() } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Close").accessibilityLabel("Close notice")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.notice)
        .accessibilityElement(children: .contain)
    }
}

/// One account: its seat alone, or its name above a row per organization. The account in use has
/// an accent edge, and its organization in use is lit.
struct AccountCard: View {
    let seats: [Seat]
    @Binding var expanded: Identity?
    let busy: Bool
    let actions: MenuActions
    let now: Date
    @State private var renaming = false

    var body: some View {
        let inUse = seats.contains { $0.state == .inUse }
        Card(fill: AnyShapeStyle(inUse && seats.count == 1 ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill)),
             edge: inUse ? .accentColor : nil) {
            VStack(alignment: .leading, spacing: 0) {
                if seats.count == 1 {
                    SeatRow(seat: seats[0], title: seats[0].name, inCard: false, expanded: $expanded, busy: busy, actions: actions, now: now)
                } else {
                    accountName
                    ForEach(seats) { seat in
                        Divider().frame(height: MenuLayout.hairline).padding(.leading, 10)
                        SeatRow(seat: seat, title: seat.organization, inCard: true, expanded: $expanded, busy: busy, actions: actions, now: now)
                    }
                }
            }
        }
    }

    private var accountName: some View {
        let first = seats[0]
        return HStack(spacing: 8) {
            if renaming {
                RenameField(current: first.accountName, renaming: $renaming) { actions.rename(first, $0, false) }
            } else {
                Text(first.accountName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                MoreMenu(name: first.accountName) {
                    Button("Rename…") { renaming = true }
                    MoveItems(seat: first, organization: false, actions: actions)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.line)
    }
}

/// Move Up and Move Down: the menu's order is the order the automatic switch tries seats in.
struct MoveItems: View {
    let seat: Seat
    let organization: Bool
    let actions: MenuActions

    var body: some View {
        let up = actions.canMove(seat, -1, organization), down = actions.canMove(seat, 1, organization)
        if up || down {
            Divider()
            Button("Move Up") { actions.move(seat, -1, organization) }.disabled(!up)
            Button("Move Down") { actions.move(seat, 1, organization) }.disabled(!down)
        }
    }
}

/// One seat. A Ready, Out, Needs-sign-in or Switching seat is one line; the seat in use, and a
/// seat whose name was clicked, also lists both meters.
struct SeatRow: View {
    let seat: Seat
    let title: String
    /// One of several organizations inside an account's card.
    let inCard: Bool
    @Binding var expanded: Identity?
    let busy: Bool
    let actions: MenuActions
    let now: Date
    @State var renaming = false
    @State var confirmingRemove = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stale: Bool { seat.meters.isStale(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if confirmingRemove { removeLine } else { summaryLine }
            }
            .frame(height: MenuLayout.line)
            if MenuLayout.showsMeters(seat, expanded: expanded) {
                ForEach(MenuLayout.meterLines(seat.meters), id: \.label) { line in
                    MeterLine(label: line.label, meter: line.meter, stale: stale, now: now)
                }
                Spacer().frame(height: MenuLayout.meterFoot)
            }
        }
        .padding(.horizontal, 10)
        // Inside an account's card, the organization in use is lit; a one-row card lights itself.
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(seat.state == .inUse && inCard ? Color.accentColor.opacity(0.12) : .clear)
            .padding(3))
        .help(seat.meters.readText(at: now).map { "Usage \($0)" } ?? "")
    }

    @ViewBuilder private var summaryLine: some View {
        if renaming {
            RenameField(current: title, renaming: $renaming) { actions.rename(seat, $0, inCard) }
        } else {
            name
            Spacer(minLength: 4)
            status
            actionButton
            MoreMenu(name: seat.name) {
                Button("Rename…") { renaming = true }
                MoveItems(seat: seat, organization: inCard, actions: actions)
                Divider()
                Button("Sign in again…") { actions.signIn(seat) }
                Button("Remove…") { confirmingRemove = true }
            }
        }
    }

    /// The name, which shows or hides both meters on a row that isn't in use.
    @ViewBuilder private var name: some View {
        let label = Text(title).fontWeight(inCard ? .regular : .semibold).lineLimit(1).truncationMode(.middle)
            .layoutPriority(1)
        if seat.state == .inUse || (seat.meters.fiveHour == nil && seat.meters.weekly == nil) {
            label.accessibilityValue(summary)
        } else {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded = expanded == seat.id ? nil : seat.id }
            } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(expanded == seat.id ? "Hide the meters" : "Show both meters")
                .accessibilityValue(summary)
                .accessibilityHint(expanded == seat.id ? "Hides both meters" : "Shows both meters")
        }
    }

    /// What the row says between its name and its button.
    @ViewBuilder private var status: some View {
        switch seat.state {
        case .inUse:
            Badge(text: "In use")
        case .switching:
            ProgressView().controlSize(.mini)
            Text("Switching").font(.caption).foregroundStyle(.secondary)
        case .needsSignIn:
            Text("Sign in once").font(.caption).foregroundStyle(.secondary)
        case .out(let resetsAt):
            MeterBar(meter: seat.meters.fuller, stale: stale).frame(width: 40)
            Text(shortReset(resetsAt, now: now, dayOnly: true).map { "Out · \($0)" } ?? "Out")
                .font(.caption).fontWeight(.semibold).lineLimit(1).fixedSize()
        case .ready:
            if let fuller = seat.meters.fuller {
                MeterBar(meter: fuller, stale: stale).frame(width: 40)
                Text("\(Int(fuller.percent.rounded()))%").font(.caption).monospacedDigit().fontWeight(.semibold)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Text("Not read yet").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch seat.action {
        case .switchTo?:
            Button("Switch") { actions.switchTo(seat) }.controlSize(.small).disabled(busy)
                .help("Quit Claude, open it on this seat, and bring your chats along")
                .accessibilityLabel("Switch to \(seat.name)")
        case .setUp?:
            Button("Set Up") { actions.setUp(seat) }.controlSize(.small).disabled(busy)
                .help("Quit Claude and reopen it at the sign-in page for this seat")
                .accessibilityLabel("Set up \(seat.name)")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var removeLine: some View {
        Text("Remove \(seat.name)?").font(.caption).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("Cancel") { confirmingRemove = false }.controlSize(.small)
        Button("Remove", role: .destructive) { confirmingRemove = false; actions.remove(seat) }.controlSize(.small)
    }

    /// The row read aloud: its state and its fuller meter.
    private var summary: String {
        let meter = seat.meters.fuller.map { "\(Int($0.percent.rounded())) percent used" }
        let state: String
        switch seat.state {
        case .inUse: state = "In use"
        case .switching: state = "Switching"
        case .needsSignIn: state = "Needs sign-in"
        case .out(let at): state = "Out" + (shortReset(at, now: now).map { ", resets \($0)" } ?? "")
        case .ready: state = "Ready"
        }
        return ([state] + (meter.map { [$0] } ?? []) + (seat.meters.readText(at: now).map { [$0] } ?? [])).joined(separator: ", ")
    }
}

/// Before any seat exists: what the app does, what it reads and keeps, and the one step to start.
struct FirstRunView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(FirstRun.lines, id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(FirstRun.waiting).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 10)
    }
}

/// The menu as the app shows it: the store's values and actions handed to `MenuPanel`, sized to
/// the screen the menu opens on.
struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var screenHeight = NSScreen.main?.visibleFrame.height ?? 800

    var body: some View {
        MenuPanel(seats: store.seats, notice: store.notice, firstRun: store.firstRun, visibleScreenHeight: screenHeight,
                  header: MenuHeader(refreshing: store.loading, autoSwitch: store.settings.autoSwitch,
                                     openAtLogin: store.openAtLogin, updatedAt: store.lastUpdated),
                  actions: actions)
            .onAppear {
                // The menu opens under its menu bar item, where the pointer is.
                let mouse = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                    screenHeight = screen.visibleFrame.height
                }
                store.checkAccessibility()
                store.refreshIfStale()
            }
    }

    private var actions: MenuActions {
        MenuActions(switchTo: { store.switchTo($0) }, setUp: { store.setUp($0) },
                    rename: { store.rename($0, to: $1, organization: $2) },
                    canMove: { store.canMove($0, by: $1, organization: $2) },
                    move: { store.move($0, by: $1, organization: $2) },
                    remove: { store.remove($0) },
                    signIn: { seat in
                        store.signInTarget = seat
                        openWindow(id: "sign-in")
                        NSApp.activate(ignoringOtherApps: true)
                    },
                    notice: { store.noticeAction($0) }, closeNotice: { store.closeNotice() },
                    refresh: { store.refresh(manual: true) }, setAutoSwitch: { store.setAutoSwitch($0) },
                    toggleOpenAtLogin: { store.toggleOpenAtLogin() })
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
