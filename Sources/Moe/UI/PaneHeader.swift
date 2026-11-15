import AppKit
import MoeDesign
import SwiftUI

/// The bar at the top of a pane: its name, and whatever that pane's one or two
/// actions are.
///
/// It exists because the shell dropped `NavigationSplitView`. Panes used to
/// hang their actions off `.toolbar`, which renders only inside a navigation
/// container — without one those buttons vanish silently, taking "Reveal in
/// Finder" and the Connections search field with them. A header the pane draws
/// itself cannot be quietly disconnected the same way.
struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.base) {
                Text(title)
                    .font(Theme.Typo.heading(19))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.base)
                trailing
            }
            .padding(.horizontal, Theme.Space.wide)
            .padding(.vertical, Theme.Space.base)
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Controls

/// The quiet outlined button used for a pane's secondary actions.
///
/// `prominent` fills it in the accent: the one button on a row that does
/// the thing the row is for ("Connect", "Sign in again"). `large` is the
/// 34pt version for a row's main action — the outlined 26pt pill was the
/// button people said was hard to hit on Connections.
struct PaneButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var large = false
    var danger = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.snug) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: large ? 11 : 10, weight: .medium))
                        .accessibilityHidden(true)
                }
                // One line, always. A button label is a short phrase and
                // wrapping it turns "Check now" into two stacked words in a
                // pill — which is what happened the moment a third button
                // joined the row. The button gives up width before it gives
                // up being readable.
                Text(title).font(Theme.Typo.ui(large ? 13 : 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(prominent ? Theme.onAccent : (danger ? Theme.bad : Theme.ink2))
            .padding(.horizontal, large ? Theme.Space.cosy : Theme.Space.base)
            .padding(.vertical, large ? 8 : 5)
            .background(
                Capsule(style: .circular)
                    .fill(prominent ? Theme.accent : Color.clear)
            )
            .overlay(
                // A circular Capsule, not a continuous RoundedRectangle of
                // radius `pill` (999): the continuous curve cannot fit a
                // radius of half the height, so the outline's ends came out
                // flat, as if clipped — Dismiss on the Fix card showed it.
                Capsule(style: .circular)
                    .strokeBorder(prominent ? Color.clear
                                  : (danger ? Theme.bad.opacity(0.4) : Theme.ruleStrong), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chips, tabs, banners
//
// Three more pieces the redesigned panes share. A chip row is how a choice
// with a handful of answers is shown *in full* — every model, every effort
// level — instead of behind a menu that hides all but the current one. A
// tab bar splits a pane that had grown to seventeen switches. A banner is
// the one line that says whether the thing on the page is working.

/// One answer in a chip row: the id it stands for, the words on the chip,
/// and a two-word meaning underneath.
struct ChoiceChip: Identifiable, Equatable {
    let id: String
    let title: String
    var caption: String = ""
}

/// Answers laid out as chips that wrap, the chosen one filled in the accent
/// tint. Every option is visible; nothing is behind a menu.
struct ChipRow: View {
    let chips: [ChoiceChip]
    let selected: String?
    var disabled = false
    let pick: (String) -> Void

    var body: some View {
        // An even grid, not a ragged flow: every chip the same width and
        // height, as many to a row as the widest one allows (owner,
        // 2026-09-25: "I like when everything is kind of even").
        EvenGrid(spacing: Theme.Space.small) {
            ForEach(chips) { chip in
                let on = chip.id == selected
                Button { pick(chip.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chip.title)
                            .font(Theme.Typo.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        if !chip.caption.isEmpty {
                            Text(chip.caption)
                                .font(Theme.Typo.ui(11))
                                .foregroundStyle(on ? Theme.accentDeep : Theme.ink3)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(on ? Theme.accentTint : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(on ? Theme.accent : Theme.rule, lineWidth: Theme.Stroke.edge)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .animation(Theme.Motion.easeOut, value: on)
            }
        }
    }
}

/// Cells of one width and one height, in as many columns as the widest
/// cell's natural width allows. Used where a row of choices would otherwise
/// come out ragged — five chips, five widths.
struct EvenGrid: Layout {
    var spacing: CGFloat = 8
    var maxColumns = 4

    private func metrics(_ width: CGFloat, _ subviews: Subviews) -> (cols: Int, cell: CGSize) {
        guard !subviews.isEmpty else { return (1, .zero) }
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = natural.map(\.width).max() ?? 0
        var cols = width.isFinite ? Int((width + spacing) / (widest + spacing)) : subviews.count
        cols = max(1, min(cols, maxColumns, subviews.count))
        let cellWidth = width.isFinite ? (width - spacing * CGFloat(cols - 1)) / CGFloat(cols) : widest
        let tallest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
        return (cols, CGSize(width: cellWidth, height: tallest))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (cols, cell) = metrics(width, subviews)
        let rows = (subviews.count + cols - 1) / cols
        let w = CGFloat(cols) * cell.width + spacing * CGFloat(cols - 1)
        return CGSize(width: width.isFinite ? width : w,
                      height: CGFloat(rows) * cell.height + spacing * CGFloat(max(rows - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (cols, cell) = metrics(bounds.width, subviews)
        for (i, s) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(i % cols) * (cell.width + spacing)
            let y = bounds.minY + CGFloat(i / cols) * (cell.height + spacing)
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cell))
        }
    }
}

/// Left-to-right, wrapping when a row is full. SwiftUI has no flow layout of
/// its own on macOS; this is the smallest one that does the job.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A row of pills in the pane header, one of which is on. Titles never wrap.
struct PaneTabs<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab

    var body: some View {
        // Wraps rather than running off the pane: Running in the background
        // has six tabs, and in one row they pushed the whole page wider than
        // the window (seen in the 2026-09-25 snapshots).
        FlowLayout(spacing: Theme.Space.tight) {
            ForEach(tabs, id: \.0) { tab, title in
                let on = tab == selection
                Button { selection = tab } label: {
                    Text(title)
                        .font(Theme.Typo.ui(12, weight: .semibold))
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Theme.Space.base)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                                .fill(on ? Theme.selected : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(Theme.Motion.easeOut, value: on)
            }
        }
    }
}

/// One line that says whether the thing on the page works: a mark and a
/// sentence, in a quiet card. `neutral` is for the steps on the way
/// ("checking…"), which are not verdicts and must not look like one.
struct PaneBanner: View {
    enum Tone { case good, warn, bad, neutral }
    let tone: Tone
    let text: String
    var busy = false

    private var colour: Color {
        switch tone {
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        case .neutral: return Theme.ink3
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.small) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(colour).frame(width: 7, height: 7).offset(y: -1)
            }
            Text(text)
                .font(Theme.Typo.ui(12, weight: tone == .neutral ? .regular : .medium))
                .foregroundStyle(tone == .bad ? Theme.bad : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.cosy)
        .padding(.vertical, Theme.Space.base)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.sidebar)
        )
    }
}

/// An inline search field, replacing `.searchable` — which also needed the
/// navigation container the shell no longer has.
struct PaneSearch: View {
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 150

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typo.ui(12))
                .frame(width: width)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.ink3)
                        .accessibilityLabel("Clear search")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, 5)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                .strokeBorder(Theme.rule, lineWidth: 1.5)
        )
    }
}

// MARK: - Settings rows
//
// The pattern Permissions already uses, generalised so Brain, Voice and
// Background can share it.
//
// Those three were left as native `Form`s on the argument that a settings
// pane should look like settings and that Form earns its keep on alignment
// and accessibility. Three panes in a row proved that wrong in practice: the
// header was ours and everything under it was Apple's — grey cards on a cream
// ground, system section captions, system pickers — so the window read as two
// applications stacked. These are the four pieces that replace it.

/// A settings section heading on its own.
///
/// `SettingGroup` is the usual way to get one, and this is the same label for
/// the places that lay their own section out — LicencePane, which arrived from
/// main while these were being written.
func settingsLabel(_ title: String) -> some View {
    Text(title)
        .font(Theme.Typo.heading(15))
        .foregroundStyle(Theme.ink)
}

/// A group of settings under a quiet uppercase label.
struct SettingGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Sentence case in the heading face, as Settings › Voice has it
            // since 2026-09-25 (design D) — every page now reads the same.
            settingsLabel(title)
            // Leading, not the VStack default: a bare Text among full-width
            // rows used to float to the middle of the pane.
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One setting: what it is, what it does, and the control that changes it.
///
/// The explanation is serif prose at 13pt with a measure. It used to be an
/// 11pt grey caption running the full width of the pane — the longest text in
/// the app set in its smallest type, which is precisely backwards.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String = ""
    /// A quieter line under the detail: where this row's answer came from
    /// when it was not the shipped default ("You set this."). Nil for the
    /// ordinary case, so a pane that never needs it looks as it always did.
    var note: String? = nil
    var last = false
    @ViewBuilder var control: Control
    @Environment(\.settingSpotlight) var spotlight

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.base) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typo.ui(13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Typo.prose(12.5))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(Theme.Typo.ui(11))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Theme.measure, alignment: .leading)
                }
            }
            Spacer(minLength: Theme.Space.base)
            control
                .padding(.top, 1)
        }
        // No divider between rows: the calmer look of Settings › Voice.
        // `last` is kept so no caller has to change.
        .padding(.vertical, 9)
        .settingSpotlight(title, lit: spotlight == title)
    }
}

/// A chosen value and a chevron, rather than a system picker.
///
/// "English", "Heart", "Claude — your monthly plan" are answers to a question.
/// A `Picker` renders them inside a grey bordered well with its own up/down
/// chevron — a control that announces itself as machinery, three or four times
/// down a pane, in the one part of the app that is meant to read as prose.
/// This is the answer, and a mark to say it can be changed.
struct SettingMenu<Content: View>: View {
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: Theme.Space.snug) {
                Text(value)
                    .font(Theme.Typo.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        // Borderless and with the system's own indicator hidden: between them
        // these are what remove the well and the second chevron.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// "Settings › Background" written in running text is not a way to get to
/// Settings › Background. This is.
struct PaneLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.tight) {
                Text(title)
                    .font(Theme.Typo.ui(12, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.accentDeep)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The empty state, in the app's own voice rather than `ContentUnavailableView`'s.
struct PaneEmpty: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.small) {
            Text(title)
                .font(Theme.Typo.heading(20))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.Typo.prose(14))
                .foregroundStyle(Theme.ink2)
                .frame(maxWidth: Theme.measure, alignment: .leading)
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A detail pane: what it says scrolls, what it does stays where it is.
///
/// The Connections detail, the brain's and Chrome's were each one `VStack`
/// with a `Spacer` above the buttons and nothing that scrolled. A stack of
/// fixed-size text has a minimum height — everything in it — and a
/// `maxHeight: .infinity` frame reports that minimum when it is offered less.
/// So a Gmail row with three accounts made the whole window's content taller
/// than the window, and AppKit centres a hosted view that does not fit: the
/// title went off the top, the buttons off the bottom, the list beside it
/// lost its last rows, and nothing scrolled because nothing was a scroll view
/// (the owner's report, 2026-11-12). Here the page scrolls inside the pane
/// and the bar is pinned under it, the same shape as the list's own footer —
/// so the pane's minimum height is the bar's, whatever the page holds.
struct PaneDetail<Page: View, Bar: View>: View {
    /// False for a row with nothing to press: no rule and no empty strip.
    var showsBar = true
    @ViewBuilder var page: Page
    @ViewBuilder var bar: Bar

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page
                    .padding(Theme.Space.wide)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if showsBar {
                Rectangle().fill(Theme.rule).frame(height: 1)
                bar
                    .padding(.horizontal, Theme.Space.wide)
                    .padding(.vertical, Theme.Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A bar of buttons that folds instead of running off the side: one row when
/// it fits, the trailing (usually destructive) button on a row of its own
/// when it does not, and one button per row when even that is too wide. At
/// the window's minimum the Connections detail is about 320pt across, and
/// "Add another", "Check now" and "Disconnect…" in one row need more.
struct PaneActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.small) {
                leading
                Spacer(minLength: Theme.Space.small)
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                HStack(spacing: Theme.Space.small) { leading }
                trailing
            }
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                leading
                trailing
            }
        }
    }
}

/// The filled pill: the one button on a screen that does the main thing.
/// NoticeSheet and MeetingConsentSheet draw the same shape inline; this is
/// the reusable one, for onboarding and the sign-in sheet.
struct PillButton: View {
    let title: String
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.ui(large ? 13 : 12, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, large ? Theme.Space.wide : Theme.Space.cosy)
                .padding(.vertical, large ? Theme.Space.small : 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.pill, style: .continuous)
                        .fill(Theme.accent)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
