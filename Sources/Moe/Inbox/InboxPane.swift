import AppKit
import MoeDesign
import MoeIsland
import SwiftUI

/// The app's Inbox page (docs/INBOX.md §5): every notice still waiting —
/// including ones hidden from the island — filtered by kind, with this week's
/// finished ones under Done. The detail pane is the reading card itself.
///
/// Many at once (owner, 2026-10-06): Mark all read, Archive all, and a
/// chosen set — ⌘-click or ⇧-click rows, or Select — archived together.
/// Archived cards are finished and kept under Done like any other.
struct InboxPane: View {
    @ObservedObject var conductor: Conductor
    @State private var filter: Filter = .all
    @State private var selected: String?
    /// The rows picked for a bulk action, and where a ⇧-click range starts.
    @State private var picked: Set<String> = []
    @State private var anchor: String?
    @State private var selecting = false
    @State private var confirmArchiveAll = false

    init(conductor: Conductor, selected: String? = nil) {
        self.conductor = conductor
        _selected = State(initialValue: selected)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case needsYou = "Needs you"
        case reminders = "Reminders"
        case ready = "Ready"
        case briefs = "Briefs"
        var id: String { rawValue }

        func admits(_ n: InboxItem) -> Bool {
            switch self {
            case .all: return true
            case .needsYou: return n.kind.needsYou
            case .reminders: return n.kind == .reminder
            case .ready: return n.kind == .work
            case .briefs: return n.kind == .brief
            }
        }
    }

    private var waiting: [InboxItem] { conductor.waitingNotices.filter(filter.admits) }
    private var snoozed: [InboxItem] {
        let now = Date()
        return conductor.notices.filter { $0.status == .open && ($0.snoozedUntil ?? .distantPast) > now }
            .filter(filter.admits).sorted { $0.at > $1.at }
    }
    /// Every card still open under this filter, snoozed ones included: what
    /// "Archive all" finishes, and the order a ⇧-click range runs in.
    private var openRows: [InboxItem] { waiting + snoozed }
    private var unread: Int { openRows.filter { !$0.seen }.count }

    private var done: [InboxItem] {
        conductor.notices.filter { $0.status == .done }.filter(filter.admits)
            .sorted { ($0.doneAt ?? $0.at) > ($1.doneAt ?? $1.at) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 340)
            Rectangle().fill(Theme.rule).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { pickFocus() }
        .onChange(of: conductor.inboxFocus) { _, _ in pickFocus() }
    }

    private func pickFocus() {
        if let focus = conductor.inboxFocus {
            selected = focus
            filter = .all
            conductor.inboxFocus = nil
        } else if selected == nil {
            selected = waiting.first?.id ?? done.first?.id
        }
    }

    // MARK: The list

    /// "Also mark it done in Reminders?" — the same question the island asks.
    @ViewBuilder
    private var tickBar: some View {
        if let t = conductor.reminderTick {
            VStack(alignment: .leading, spacing: 8) {
                Text("Also mark “\(t.title)” done in Reminders?")
                    .font(Theme.Typo.ui(12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    PaperButton("Mark done", style: .primary) { conductor.tickReminder() }
                    PaperButton("Leave it", style: .quiet) { conductor.dismissReminderTick() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warn.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.warn.opacity(0.3), lineWidth: 1))
            .padding(.bottom, 8)
        } else if let trouble = conductor.tickTrouble {
            Text(trouble)
                .font(Theme.Typo.ui(12))
                .foregroundStyle(Theme.ink2)
                .padding(12)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Inbox").font(Theme.Typo.display(22)).foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    ForEach(Filter.allCases) { f in
                        Button { filter = f } label: {
                            Text(f.rawValue)
                                .font(Theme.Typo.ui(11.5, weight: filter == f ? .semibold : .regular))
                                .foregroundStyle(filter == f ? Theme.paper : Theme.ink2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(filter == f ? Theme.ink : Color.clear))
                                .overlay(Capsule().stroke(filter == f ? Color.clear : Theme.rule, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(f.rawValue.lowercased())")
                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)

            bulkBar
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    tickBar
                    if waiting.isEmpty {
                        Text(filter == .all ? "Nothing waiting. When Moe brings something up, it lands here."
                                            : "Nothing waiting here.")
                            .font(Theme.Typo.ui(12.5))
                            .foregroundStyle(Theme.ink3)
                            .padding(12)
                    }
                    ForEach(waiting) { item($0) }
                    if !snoozed.isEmpty {
                        groupLabel("Snoozed")
                        ForEach(snoozed) { item($0) }
                    }
                    if !done.isEmpty {
                        groupLabel("Done this week")
                        ForEach(done) { item($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        // ↑ and ↓ walk the list once it has the keyboard (Tab reaches it),
        // and the card on the right follows.
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox")
    }

    /// Every row in the order it is drawn: waiting, snoozed, done.
    private var rowsInOrder: [InboxItem] { waiting + snoozed + done }

    /// The next row up or down from the one that is open; the first when
    /// none is. Stops at the ends rather than wrapping.
    private func step(_ by: Int) {
        selected = Self.neighbour(of: selected, in: rowsInOrder.map(\.id), by: by)
    }

    static func neighbour(of current: String?, in ids: [String], by: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(i + by, 0), ids.count - 1)]
    }

    /// One row as one sentence: "Unread. Reminder. Call the dentist. Before
    /// five. 3:00 PM". A finished row says how it finished instead of when.
    static func spoken(_ n: InboxItem, picking: Bool, picked: Bool) -> String {
        var parts: [String] = []
        if picking { parts.append(picked ? "Selected" : "Not selected") }
        if n.status == .open, !n.seen { parts.append("Unread") }
        parts.append(n.kind.label)
        parts.append(NoticeWords.bare(n.title))
        if !n.summary.isEmpty { parts.append(NoticeWords.bare(n.summary)) }
        parts.append(n.status == .done ? (n.outcome ?? "Done") : NoticeStyle.time(n.at))
        return parts.joined(separator: ". ")
    }

    // MARK: Many at once

    @ViewBuilder
    private var bulkBar: some View {
        HStack(spacing: 4) {
            if picked.isEmpty {
                PaperButton("Mark all read", style: .quiet) { conductor.markAllNoticesRead() }
                    .disabled(unread == 0)
                    .opacity(unread == 0 ? 0.45 : 1)
                PaperButton("Archive all", style: .quiet) { confirmArchiveAll = true }
                    .disabled(openRows.isEmpty)
                    .opacity(openRows.isEmpty ? 0.45 : 1)
                Spacer(minLength: 0)
                PaperButton(selecting ? "Cancel" : "Select", style: .quiet) {
                    selecting.toggle()
                    picked = []
                }
                .help("Pick cards to archive together. ⌘-click or ⇧-click a row does the same.")
            } else {
                Text("\(picked.count) selected")
                    .font(Theme.Typo.ui(12, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                PaperButton("Clear", style: .quiet) { picked = []; selecting = false }
                PaperButton("Archive selected", style: .primary) {
                    conductor.archiveNotices(Array(picked))
                    picked = []
                    selecting = false
                }
            }
        }
        .confirmationDialog(openRows.count == 1 ? "Archive this card?" : "Archive all \(openRows.count) cards?",
                            isPresented: $confirmArchiveAll) {
            Button("Archive") {
                conductor.archiveNotices(openRows.map(\.id))
                picked = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They move to Done, where they stay for a week.")
        }
    }

    /// A click on a row: ⌘ (or Select) adds it to the picked set or takes it
    /// out, ⇧ picks every open row from the last one picked to this one, and
    /// a plain click opens it. Only open cards can be picked.
    private func click(_ n: InboxItem) {
        let flags = NSEvent.modifierFlags
        guard n.status == .open else { selected = n.id; return }
        if flags.contains(.shift), let from = anchor ?? selected,
           let a = openRows.firstIndex(where: { $0.id == from }),
           let b = openRows.firstIndex(where: { $0.id == n.id }) {
            picked.formUnion(openRows[min(a, b)...max(a, b)].map(\.id))
            return
        }
        if selecting || flags.contains(.command) || !picked.isEmpty {
            if picked.contains(n.id) { picked.remove(n.id) } else { picked.insert(n.id) }
            anchor = n.id
            return
        }
        selected = n.id
        anchor = n.id
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(Theme.Typo.label(10))
            .tracking(Theme.tracking)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func item(_ n: InboxItem) -> some View {
        let on = selected == n.id
        let finished = n.status == .done
        let isPicked = picked.contains(n.id)
        let picking = (selecting || !picked.isEmpty) && !finished
        return Button { click(n) } label: {
            HStack(alignment: .top, spacing: 8) {
            if picking {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isPicked ? Theme.accent : Theme.ink3)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if !finished && !n.seen {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .help("Unread")
                    }
                    Image(systemName: NoticeStyle.icon(n.kind)).font(.system(size: 9, weight: .bold))
                    Text(n.kind.label).font(Theme.Typo.ui(11, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(finished ? (n.outcome ?? "Done") : NoticeStyle.time(n.at))
                        .font(Theme.Typo.ui(11).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
                .foregroundStyle(NoticeStyle.paperTint(n.kind))
                Text(IslandView.linkedOnPaper(n.title))
                    .font(Theme.Typo.ui(13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !n.summary.isEmpty {
                    Text(IslandView.linkedOnPaper(n.summary))
                        .font(Theme.Typo.ui(12.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(2)
                }
            }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isPicked ? Theme.accent.opacity(0.08) : on ? Theme.raised : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isPicked ? Theme.accent.opacity(0.35) : on ? Theme.rule : Color.clear, lineWidth: 1))
            .opacity(finished && !on ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(n, picking: picking, picked: isPicked))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { click(n) }
        .accessibilityActions {
            if !finished {
                Button("Archive") { conductor.archiveNotices([n.id]) }
                Button(isPicked ? "Take out of the selection" : "Add to the selection") {
                    if picked.contains(n.id) { picked.remove(n.id) } else { picked.insert(n.id) }
                    anchor = n.id
                }
            }
        }
    }

    // MARK: The detail

    @ViewBuilder
    private var detail: some View {
        if let id = selected, conductor.notice(id) != nil {
            NoticeCardView(conductor: conductor, noticeID: id, inApp: true)
                .id(id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
                Text("Pick something on the left to read it.")
                    .font(Theme.Typo.ui(13)).foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised)
        }
    }
}
