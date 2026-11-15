import MoeDesign
import MoeIsland
import SwiftUI

/// Each kind's colour and glyph, one table for the island, the card and the
/// app's Inbox, so a reminder is the same amber everywhere.
enum NoticeStyle {
    static func tint(_ kind: InboxItem.Kind) -> Color {
        switch kind {
        case .reminder: return Theme.Island.amber
        case .question: return Theme.Island.moe
        case .work: return Theme.Island.you
        case .brief: return Theme.Island.link
        case .headsUp: return Theme.Island.ink3
        }
    }

    /// The same hue, deep enough to read on the app's light paper.
    static func paperTint(_ kind: InboxItem.Kind) -> Color {
        switch kind {
        case .reminder, .brief: return Theme.warn
        case .question: return Theme.accent
        case .work: return Theme.good
        case .headsUp: return Theme.ink3
        }
    }

    static func icon(_ kind: InboxItem.Kind) -> String {
        switch kind {
        case .reminder: return "alarm.fill"
        case .question: return "questionmark.bubble.fill"
        case .work: return "square.and.pencil"
        case .brief: return "doc.text.fill"
        case .headsUp: return "info.circle.fill"
        }
    }

    static func time(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

/// The island's inbox: what the chat turns into when the inbox icon is
/// pressed. "Needs you" first, then "For your information"; each row's
/// buttons are its kind's (docs/INBOX.md §2).
struct IslandInboxView: View {
    @ObservedObject var conductor: Conductor
    /// Snapshots draw a snooze menu open.
    var snoozeOpenFor: String? = nil

    @State private var snoozing: String?
    @Environment(\.islandSnapshot) private var snapshotting

    var body: some View {
        let rows = conductor.islandNotices
        let needs = rows.filter { $0.kind.needsYou }
        let fyi = rows.filter { !$0.kind.needsYou }
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty, conductor.reminderTick != nil || conductor.tickTrouble != nil {
                // Done on the last one: the Reminders question in place of
                // "All clear", in the same room it was asked.
                tickBar.frame(maxWidth: .infinity, minHeight: InboxLayout.empty - 20, alignment: .top)
            } else if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.Island.ink3)
                        .accessibilityHidden(true)
                    Text("All clear. Nothing waiting.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Island.ink3)
                }
                .frame(maxWidth: .infinity, minHeight: InboxLayout.empty - 20)
            } else if snapshotting {
                // A `ScrollView` rasterises as an empty box (§9): a still
                // draws the rows as they would sit at the top of the scroll.
                Color.clear
                    .overlay(alignment: .top) { list(needs: needs, fyi: fyi) }
                    .clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) { list(needs: needs, fyi: fyi) }
            }
        }
        // A finished row slides out sideways; under Reduce Motion it is gone.
        .calmAnimation(.easeInOut(duration: 0.25), value: rows.map(\.id))
    }

    private func list(needs: [InboxItem], fyi: [InboxItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            tickBar
            if !needs.isEmpty { section("Needs you") }
            ForEach(needs) { row($0) }
            if !fyi.isEmpty { section("For your information").padding(.top, needs.isEmpty ? 0 : 4) }
            ForEach(fyi) { row($0) }
        }
        .padding(.bottom, 4)
    }

    /// "Also mark it done in Reminders?" after Done on a nag that came from
    /// an Apple Reminder. Nothing is written there unless they tap.
    @ViewBuilder
    private var tickBar: some View {
        if let t = conductor.reminderTick {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "checklist").font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Reminders").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.Island.amber)
                Text("Also mark “\(t.title)” done in Reminders?")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Island.ink)
                    .fixedSize(horizontal: false, vertical: true)
                FlowRow {
                    InboxButton("Mark done", style: .primary) { conductor.tickReminder() }
                    InboxButton("Leave it", style: .quiet) { conductor.dismissReminderTick() }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Island.amber.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.Island.amber.opacity(0.3), lineWidth: 1))
        } else if let trouble = conductor.tickTrouble {
            Text(trouble)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Island.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.Island.ink3)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func row(_ n: InboxItem) -> some View {
        let tint = NoticeStyle.tint(n.kind)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                // The glyph is the kind's colour and shape; the word beside
                // it is what VoiceOver reads.
                Image(systemName: NoticeStyle.icon(n.kind)).font(.system(size: 8.5, weight: .bold))
                    .accessibilityHidden(true)
                Text(n.kind.label).font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Text(NoticeStyle.time(n.at))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.Island.ink3)
                Button { conductor.dismissNotice(n.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.Island.ink3)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss it. It moves to Done in the app's Inbox.")
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(tint)
            Text(IslandView.linked(n.title))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Island.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !n.summary.isEmpty {
                Text(IslandView.linked(n.summary))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Island.ink2)
                    .lineSpacing(1.5)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions(n)
                .padding(.top, 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.Island.rule, lineWidth: 1))
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
        // One stop per card: its kind, title, summary and time read as one
        // sentence, and its buttons (Done, Snooze, Dismiss…) are the card's
        // actions rather than five more stops each.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func actions(_ n: InboxItem) -> some View {
        let snoozeOpen = (snoozing ?? snoozeOpenFor) == n.id
        if !n.buy.isEmpty {
            // The 80 % card (docs/PLANS-AND-CAPS-2026-11-13.md §7 D7): its
            // one do-it buys the pack; Stripe shows the price first.
            FlowRow {
                InboxButton(n.buyTitle.isEmpty ? "Add a pack" : n.buyTitle, style: .primary) {
                    conductor.buyNoticePack(n.id)
                }
                InboxButton("Not now", style: .quiet) { conductor.finishNotice(n.id, outcome: "Not now") }
            }
        } else {
            kindActions(n, snoozeOpen: snoozeOpen)
        }
    }

    @ViewBuilder
    private func kindActions(_ n: InboxItem, snoozeOpen: Bool) -> some View {
        switch n.kind {
        case .reminder:
            if snoozeOpen {
                FlowRow {
                    ForEach(Conductor.snoozeChoices(), id: \.label) { c in
                        InboxButton(c.label) { conductor.snoozeNotice(n.id, until: c.until); snoozing = nil }
                    }
                    InboxButton("Cancel", style: .quiet) { snoozing = nil }
                }
            } else {
                FlowRow {
                    InboxButton("Done", style: .primary) { conductor.finishNotice(n.id, outcome: "Done") }
                    InboxButton("Snooze", icon: "chevron.down") { snoozing = n.id }
                    InboxButton("Reply", style: .quiet) { conductor.replyToNotice(n.id, text: "") }
                }
            }
        case .question where !n.expiredText.isEmpty:
            // A send held for their yes: the two answers it can have.
            FlowRow {
                InboxButton("Send it", style: .primary) { conductor.replyToNotice(n.id, text: "Yes, send it.") }
                InboxButton("Don't send") { conductor.finishNotice(n.id, outcome: "Not sent") }
                InboxButton("Answer in words", style: .quiet) { conductor.replyToNotice(n.id, text: "") }
            }
        case .question:
            FlowRow {
                ForEach(n.options, id: \.self) { o in
                    InboxButton(o, style: .chip) { conductor.replyToNotice(n.id, text: o) }
                }
                InboxButton(n.options.isEmpty ? "Answer" : "Answer in words",
                            style: n.options.isEmpty ? .primary : .quiet) {
                    conductor.replyToNotice(n.id, text: "")
                }
                if n.options.isEmpty {
                    InboxButton("Skip", style: .quiet) { conductor.finishNotice(n.id, outcome: "Skipped") }
                }
            }
        case .work:
            FlowRow {
                InboxButton("Review", style: .primary) { conductor.openNotice(n.id) }
                InboxButton("Done") { conductor.finishNotice(n.id, outcome: "Done") }
                    .help("You handled it yourself: it leaves the inbox")
                InboxButton("Not now", style: .quiet) { conductor.dismissNotice(n.id) }
                // The learner's strongest no, reachable at last: it used to
                // be wired nowhere (docs/INBOX-QUIET.md).
                InboxButton("Not this kind", style: .quiet) { conductor.declineNotice(n.id, kind: true) }
                    .help("Moe stops offering this kind of thing")
            }
        case .brief:
            FlowRow {
                InboxButton("Open", style: .primary) { conductor.openNotice(n.id) }
                InboxButton("Got it") { conductor.finishNotice(n.id, outcome: "Got it") }
            }
        case .headsUp:
            FlowRow {
                if !n.openThread.isEmpty {
                    InboxButton("Open it", style: .primary) { conductor.openNoticeThread(n.id) }
                    InboxButton("Later", style: .quiet) { conductor.hideNotice(n.id) }
                } else if !n.awayCarry.isEmpty {
                    InboxButton("Show me", style: .primary) { conductor.awayNotice(n.id, "show") }
                    InboxButton("Not now", style: .quiet) { conductor.awayNotice(n.id, "later") }
                } else {
                    InboxButton("Got it") { conductor.finishNotice(n.id, outcome: "Got it") }
                    if n.body.count > NoticeMaker.briefLength / 2 {
                        InboxButton("Show me", style: .quiet) { conductor.openNotice(n.id) }
                    }
                }
            }
        }
    }
}

/// A row's button: the island's capsule, in four weights.
struct InboxButton: View {
    enum Style { case primary, normal, quiet, chip }
    let title: String
    var icon: String?
    var style: Style = .normal
    let action: () -> Void

    init(_ title: String, icon: String? = nil, style: Style = .normal, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: style == .primary ? .semibold : .medium))
                if let icon {
                    Image(systemName: icon).font(.system(size: 7.5, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style == .quiet ? 6 : 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(style == .chip ? Theme.Island.moe.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.Island.ground
        case .normal: return Theme.Island.ink
        case .quiet: return hovering ? Theme.Island.ink : Theme.Island.ink3
        case .chip: return Theme.Island.moe
        }
    }

    private var fill: Color {
        switch style {
        case .primary: return Theme.Island.ink.opacity(hovering ? 1 : 0.92)
        case .normal: return Color.white.opacity(hovering ? 0.18 : 0.11)
        case .quiet: return .clear
        case .chip: return Theme.Island.moe.opacity(hovering ? 0.14 : 0.0)
        }
    }
}

/// Buttons in a row that wraps when it runs out of width.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The line beside the folded notch when something arrives: it rides in the
/// right ear (`IslandEars.Right.notice`) for six seconds. Until 2026-10-15
/// it was a tab hanging under the notch with an amber edge.
enum NoticeTab {
    /// "Marketing brief · Reply draft…": the title, and the start of the
    /// summary when there is room. Short, because the ear sits in the menu
    /// bar and covers the icons beside the notch while it is out.
    static func earLine(_ n: InboxItem) -> String {
        let title = NoticeWords.bare(n.title)
        guard !n.summary.isEmpty else { return NoticeWords.oneLine(title, max: 34) }
        let first = NoticeWords.bare(n.summary).components(separatedBy: " · ").first ?? n.summary
        return NoticeWords.oneLine("\(title) · \(first)", max: 34)
    }
}

/// The inbox icon in the island's band, with its count. Pressed, it swaps
/// the chat for the inbox; pressed again, back.
struct InboxIconButton: View {
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "tray.fill" : "tray")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(on ? Theme.Island.ground : .white.opacity(0.75))
                .frame(width: 21, height: 21)
                .background(Circle().fill(on ? Theme.Island.ink : Color.white.opacity(hovering ? 0.2 : 0.11)))
                .overlay(alignment: .topTrailing) {
                    if count > 0, !on {
                        Text("\(min(count, 99))")
                            .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.black.opacity(0.85))
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Theme.Island.amber))
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(on ? "Inbox, showing" : "Inbox")
        .accessibilityValue(count == 0 ? "Nothing waiting" : count == 1 ? "1 waiting" : "\(count) waiting")
        .accessibilityHint(on ? "Goes back to the conversation" : "Shows what is waiting for you")
    }
}
