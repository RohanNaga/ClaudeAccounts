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

    /// The card the menu scrolls to when it opens: the account of the seat in use, so its card is
    /// in view however long the list is. Nil when no seat is in use, which leaves the top in view.
    static func openScrollTarget(_ seats: [Seat]) -> String? {
        cards(seats).first { $0.contains { $0.state == .inUse } }?[0].id.account
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

    /// Whether a card shows only its account's name: an account with several organizations that
    /// the person folded away.
    static func isFolded(_ card: [Seat], folded: Set<String>) -> Bool { card.count > 1 && folded.contains(card[0].id.account) }

    static func cardHeight(_ card: [Seat], expanded: Identity?, folded: Set<String> = []) -> CGFloat {
        if isFolded(card, folded: folded) { return line }
        let rows = card.reduce(0) { $0 + rowHeight($1, expanded: expanded) }
        return card.count == 1 ? rows : line + CGFloat(card.count) * hairline + rows
    }

    /// Everything above the cards, plus the menu's padding: the part that never scrolls.
    static func chrome(hasNotice: Bool) -> CGFloat { 2 * padding + titleBar + (hasNotice ? notice : 0) }

    static func cardsHeight(seats: [Seat], expanded: Identity?, folded: Set<String> = []) -> CGFloat {
        let cards = cards(seats)
        return cards.reduce(0) { $0 + cardHeight($1, expanded: expanded, folded: folded) } + CGFloat(max(cards.count - 1, 0)) * cardGap
    }

    /// The menu's height if the screen were tall enough for every row.
    static func contentHeight(seats: [Seat], hasNotice: Bool, expanded: Identity? = nil, folded: Set<String> = []) -> CGFloat {
        chrome(hasNotice: hasNotice) + cardsHeight(seats: seats, expanded: expanded, folded: folded)
    }

    /// The menu's height on a screen whose visible part (below the menu bar) is
    /// `visibleScreenHeight` tall: every row when they fit, else as tall as the screen allows,
    /// with the cards scrolling under the pinned title bar and notice.
    static func height(visibleScreenHeight: CGFloat, seats: [Seat], hasNotice: Bool, expanded: Identity? = nil,
                       folded: Set<String> = []) -> CGFloat {
        chrome(hasNotice: hasNotice) + cardsViewport(visibleScreenHeight: visibleScreenHeight, seats: seats,
                                                     hasNotice: hasNotice, expanded: expanded, folded: folded)
    }

    /// The height the cards get, which scroll when it is less than they need.
    static func cardsViewport(visibleScreenHeight: CGFloat, seats: [Seat], hasNotice: Bool, expanded: Identity?,
                              folded: Set<String> = []) -> CGFloat {
        let room = max(visibleScreenHeight - screenMargin - chrome(hasNotice: hasNotice), minimumCards)
        return min(cardsHeight(seats: seats, expanded: expanded, folded: folded), room)
    }
}

// MARK: - Account colours

/// Named account colours, offered in each account's Color menu.
let accountColors: [(name: String, hex: String)] = [
    ("Blue", "#3567CF"), ("Orange", "#B96E22"), ("Pink", "#B3405F"), ("Green", "#2C8A5E"),
    ("Purple", "#6B5BD2"), ("Teal", "#1F8A9A"), ("Red", "#C8412F"), ("Gray", "#7A8088"),
]

extension Color {
    /// A "#RRGGBB" colour; anything unreadable draws gray.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(digits, radix: 16) ?? 0x7A8088
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Each account's colour, in menu order. An account saved without one (core gives a new row "")
/// shows the first named colour no other account uses, so new accounts differ without a choice.
func resolvedColors(_ saved: [(account: String, color: String)]) -> [String: String] {
    var colors: [String: String] = [:]
    for (account, color) in saved where !color.isEmpty && colors[account] == nil { colors[account] = color }
    for (account, _) in saved where colors[account] == nil {
        let used = Set(colors.values)
        colors[account] = accountColors.first { !used.contains($0.hex) }?.hex ?? accountColors[colors.count % accountColors.count].hex
    }
    return colors
}

// MARK: - Pieces

/// Good below 60 %, warning from 60 %, critical from 80 %.
func severity(_ pct: Int) -> Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

/// A reset time as short as it reads: "3:40 PM" today, "Thu 3:40 PM" this week, "Dec 2" later.
/// A one-line row says only the day of a reset after today ("Thu"); its meters say the hour.
func shortReset(_ date: Date?, now: Date, dayOnly: Bool = false) -> String? {
    guard let date, date > now else { return nil }
    if dayOnly, !Calendar.current.isDate(date, inSameDayAs: now), date.timeIntervalSince(now) < 6 * 86400 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return ClockText.time(date, now: now)
}

extension Color {
    /// The menu's quiet text. The system's secondary label measures about 3.9:1 on the light menu;
    /// this keeps 4.5:1 or more on the menu and on the lit row in use, in light and dark.
    static let quietText = Color.primary.opacity(0.7)
}

/// How long ago a seat's meters were read, while they are no longer fresh: "Read 42m ago", or
/// "Not read yet". Nil while they are fresh.
func readAge(_ meters: SeatMeters, now: Date) -> String? {
    guard let readAt = meters.readAt else { return "Not read yet" }
    guard meters.isStale(at: now) else { return nil }
    let minutes = Int(now.timeIntervalSince(readAt) / 60)
    return minutes < 120 ? "Read \(minutes)m ago" : "Read \(minutes / 60)h ago"
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
            Text(label).foregroundStyle(Color.quietText).frame(width: 44, alignment: .leading)
            MeterBar(meter: meter, stale: stale)
            // A stale percent is quiet, so it doesn't read as current.
            Text(meter.map { "\(Int($0.percent.rounded()))%" } ?? "–").monospacedDigit().fontWeight(.semibold)
                .foregroundStyle(stale ? Color.quietText : .primary)
                .frame(width: 34, alignment: .trailing)
            Text(meter.flatMap { shortReset($0.resetsAt, now: now) }.map { "resets \($0)" } ?? "")
                .foregroundStyle(Color.quietText).lineLimit(1)
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

/// An account's colour dot, before its name.
struct ColorDot: View {
    let hex: String
    var body: some View { Circle().fill(Color(hex: hex)).frame(width: 9, height: 9).accessibilityHidden(true) }
}

/// The account colours, with the current one checked.
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

/// Rename…, and Reset Name when the name is not the default one.
struct NameItems: View {
    let canReset: Bool
    @Binding var renaming: Bool
    let onReset: () -> Void

    var body: some View {
        Button("Rename…") { renaming = true }
        if canReset { Button("Reset Name", action: onReset) }
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
    /// Colours every row of the seat's account.
    var recolor: (Seat, String) -> Void = { _, _ in }
    /// Shows (true) or folds away (false) an account's organizations, by account id.
    var showOrganizations: (String, Bool) -> Void = { _, _ in }
    var setDisplay: (MenuBarDisplay) -> Void = { _ in }
    var setMetric: (UsageMetric) -> Void = { _ in }
    var setSwitchOrder: (SwitchOrder) -> Void = { _ in }
}

/// The title bar's live values.
struct MenuHeader {
    var refreshing = false
    var autoSwitch = true
    var openAtLogin = false
    var updatedAt: Date?
    var display = MenuBarDisplay.gaugeNamePercent
    var metric = UsageMetric.fiveHour
    var switchOrder = SwitchOrder.topToBottom
}

/// What the person chose for how accounts look: colours, folded accounts, and which names they
/// changed, so Reset Name shows only where it does something.
struct MenuLooks {
    /// Each account's colour by account id, defaults already filled in (`resolvedColors`).
    var colors: [String: String] = [:]
    /// Accounts whose organizations are folded under the account's name.
    var folded: Set<String> = []
    /// Accounts whose name is not the default one.
    var renamedAccounts: Set<String> = []
    /// Seats whose organization's name is not the default one.
    var renamedOrganizations: Set<Identity> = []

    /// The seat's account colour; nil, and no dot or Color menu, when none is given.
    func color(_ seat: Seat) -> String? { colors[seat.id.account] }
}

/// The whole menu, drawn from values only: the store's adapter is `MenuContent`.
struct MenuPanel: View {
    let seats: [Seat]
    let notice: Notice?
    let firstRun: Bool
    /// NSScreen.visibleFrame.height of the screen the menu opens on.
    let visibleScreenHeight: CGFloat
    var header = MenuHeader()
    var looks = MenuLooks()
    var actions = MenuActions()
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
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: MenuLayout.cardGap) {
                    ForEach(MenuLayout.cards(seats), id: \.[0].id.account) { card in
                        AccountCard(seats: card, expanded: $expanded, busy: busy, looks: looks, actions: actions, now: now)
                            .id(card[0].id.account)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: MenuLayout.cardsViewport(visibleScreenHeight: visibleScreenHeight, seats: seats,
                                                    hasNotice: notice != nil, expanded: expanded, folded: looks.folded))
            .onAppear { if let target = MenuLayout.openScrollTarget(seats) { proxy.scrollTo(target, anchor: .center) } }
        }
    }
}

/// "Claude Accounts", refresh, and the menu of the rare actions and the settings.
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
            MoreMenu(name: "Claude Accounts") { TitleMenuItems(header: header, actions: actions) }
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.titleBar)
    }
}

/// The title bar's ··· items: the rare actions and the settings.
struct TitleMenuItems: View {
    let header: MenuHeader
    let actions: MenuActions

    var body: some View {
        Button("Add Account…") { actions.signIn(nil) }
        Divider()
        Picker("Menu Bar Shows", selection: Binding(get: { header.display }, set: { actions.setDisplay($0) })) {
            ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
        }
        Picker("Gauge Tracks", selection: Binding(get: { header.metric }, set: { actions.setMetric($0) })) {
            ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Toggle("Auto-Switch When Out", isOn: Binding(get: { header.autoSwitch }, set: { actions.setAutoSwitch($0) }))
            .help("When Claude stops a chat because the seat in use is out of usage, quit Claude, reopen it on the seat marked Next, and send \u{201C}resume\u{201D} to the chats that were working")
        Picker("Switch Order", selection: Binding(get: { header.switchOrder }, set: { actions.setSwitchOrder($0) })) {
            ForEach(SwitchOrder.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Open at Login", isOn: Binding(get: { header.openAtLogin }, set: { _ in actions.toggleOpenAtLogin() }))
        Divider()
        Button("Quit Claude Accounts") { NSApp.terminate(nil) }.keyboardShortcut("q")
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
            Text(notice.text).font(.caption).foregroundStyle(Color.quietText)
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

/// One account: its seat alone, or its name above a row per organization, which the name folds
/// away. The account in use has an accent edge, and its organization in use is lit.
struct AccountCard: View {
    let seats: [Seat]
    @Binding var expanded: Identity?
    let busy: Bool
    let looks: MenuLooks
    let actions: MenuActions
    let now: Date
    @State private var renaming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let inUse = seats.contains { $0.state == .inUse }
        Card(fill: AnyShapeStyle(inUse && seats.count == 1 ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill)),
             edge: inUse ? .accentColor : nil) {
            VStack(alignment: .leading, spacing: 0) {
                if seats.count == 1 {
                    SeatRow(seat: seats[0], title: seats[0].name, inCard: false, expanded: $expanded, busy: busy,
                            looks: looks, actions: actions, now: now)
                } else {
                    accountName(inUse: inUse)
                    if !MenuLayout.isFolded(seats, folded: looks.folded) {
                        ForEach(seats) { seat in
                            Divider().frame(height: MenuLayout.hairline).padding(.leading, 10)
                            SeatRow(seat: seat, title: seat.organization, inCard: true, expanded: $expanded, busy: busy,
                                    looks: looks, actions: actions, now: now)
                        }
                    }
                }
            }
        }
    }

    private func accountName(inUse: Bool) -> some View {
        let first = seats[0], account = first.id.account
        let folded = MenuLayout.isFolded(seats, folded: looks.folded)
        return HStack(spacing: 8) {
            if let hex = looks.color(first) { ColorDot(hex: hex) }
            if renaming {
                RenameField(current: first.accountName, renaming: $renaming) { actions.rename(first, $0, false) }
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { actions.showOrganizations(account, folded) }
                } label: {
                    HStack(spacing: 6) {
                        Text(first.accountName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(folded ? 0 : 90))
                        // Folded away, the account holding the next seat carries its mark.
                        if folded && seats.contains(where: \.isNext) { NextMark() }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folded ? "Show this account's organizations" : "Hide this account's organizations")
                .accessibilityLabel(first.accountName)
                .accessibilityValue(folded ? "Organizations hidden" : "Organizations shown")
                .accessibilityAddTraits(.isHeader)
                // Folded away, the account in use still says so.
                if folded && inUse { Badge(text: "In use") }
                menu
            }
        }
        .padding(.horizontal, 10)
        .frame(height: MenuLayout.line)
    }

    /// The account's own menu: its name, its colour and its place in the order.
    private var menu: some View {
        let first = seats[0]
        return MoreMenu(name: first.accountName) {
            NameItems(canReset: looks.renamedAccounts.contains(first.id.account), renaming: $renaming) { actions.rename(first, "", false) }
            if let hex = looks.color(first) { ColorMenu(current: hex) { actions.recolor(first, $0) } }
            MoveItems(seat: first, organization: false, actions: actions)
        }
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

/// The mark on the seat the automatic switch goes to next, so the switch order shows in the menu.
/// The accent alone measures about 3.8:1 on the card; mixed a fifth toward the label colour (darker
/// in light, lighter in dark) it keeps 4.5:1 or more in both.
struct NextMark: View {
    var body: some View {
        Text("Next").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor.mix(with: .primary, by: 0.2)).fixedSize()
            .help("Auto-switch goes here next when Claude stops a chat for usage. Switch Order in the title's ··· menu, and Move Up and Move Down in a row's ··· menu, change it.")
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
    var looks = MenuLooks()
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
        // A seat alone on its card carries its account's colour; organizations take the card's.
        if !inCard, let hex = looks.color(seat) { ColorDot(hex: hex) }
        if renaming {
            RenameField(current: title, renaming: $renaming) { actions.rename(seat, $0, inCard) }
        } else {
            name
            if seat.isNext { NextMark() }
            Spacer(minLength: 4)
            status
            actionButton
            MoreMenu(name: seat.name) {
                NameItems(canReset: inCard ? looks.renamedOrganizations.contains(seat.id) : looks.renamedAccounts.contains(seat.id.account),
                          renaming: $renaming) { actions.rename(seat, "", inCard) }
                if !inCard, let hex = looks.color(seat) { ColorMenu(current: hex) { actions.recolor(seat, $0) } }
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

    /// What the row says between its name and its button. A meter's text sits before its bar, so
    /// every bar ends at the button and the bars line up down the menu whatever the text's width.
    /// A reading that isn't fresh says its age in place of its percent.
    @ViewBuilder private var status: some View {
        switch seat.state {
        case .inUse:
            if let age = readAge(seat.meters, now: now) { quiet(age) }
            Badge(text: "In use")
        case .switching:
            ProgressView().controlSize(.mini)
            quiet("Switching")
        case .needsSignIn:
            quiet("Sign in once")
        case .out(let resetsAt):
            Text(shortReset(resetsAt, now: now, dayOnly: true).map { "Out · \($0)" } ?? "Out")
                .font(.caption).fontWeight(.semibold).lineLimit(1).fixedSize()
            MeterBar(meter: seat.meters.fuller, stale: stale).frame(width: 40)
        case .ready:
            if let fuller = seat.meters.fuller, !stale {
                Text("\(Int(fuller.percent.rounded()))%").font(.caption).monospacedDigit().fontWeight(.semibold)
            } else {
                quiet(readAge(seat.meters, now: now) ?? "Not read yet")
            }
            MeterBar(meter: seat.meters.fuller, stale: stale).frame(width: 40)
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Color.quietText).lineLimit(1).fixedSize()
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
                                     openAtLogin: store.openAtLogin, updatedAt: store.lastUpdated,
                                     display: store.settings.display, metric: store.settings.metric,
                                     switchOrder: store.settings.switchOrder),
                  looks: looks, actions: actions)
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
                    toggleOpenAtLogin: { store.toggleOpenAtLogin() },
                    recolor: { store.recolor($0, $1) },
                    showOrganizations: { store.setShowsOrganizations(of: $0, $1) },
                    setDisplay: { store.settings.display = $0 }, setMetric: { store.settings.metric = $0 },
                    setSwitchOrder: { store.setSwitchOrder($0) })
    }

    /// The rows' colours, folds and changed names, keyed the way the menu's seats are.
    private var looks: MenuLooks {
        let rows = store.accounts
        let account = { (row: AccountRecord) in row.seat.account }
        func differs(_ row: AccountRecord, organization: Bool) -> Bool {
            guard let reset = rows.renamed(row, to: "", organization: organization).first(where: { $0.id == row.id }) else { return false }
            return organization ? reset.organization != row.organization : reset.name != row.name
        }
        return MenuLooks(colors: resolvedColors(rows.map { (account($0), $0.color) }),
                         folded: Set(rows.map(account).filter { !store.settings.showsOrganizations(of: $0) }),
                         renamedAccounts: Set(rows.filter { differs($0, organization: false) }.map(account)),
                         renamedOrganizations: Set(rows.filter { differs($0, organization: true) }.map(\.seat)))
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
            target = store.signInRecord
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
