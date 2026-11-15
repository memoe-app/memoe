import AppKit
import MoeDesign
import MoeIsland
import SwiftUI

/// The reading card: a notice opened as a page on the screen, wherever the
/// person is (docs/INBOX.md §3). The summary on top; the body laid out as
/// headings, lists and drafts, each draft with Copy; a box to ask about it;
/// and the way on — the island, the app, or Got it.
///
/// The same view is the detail pane of the app's Inbox page (`inApp`), so a
/// notice reads and acts the same wherever it is opened.
struct NoticeCardView: View {
    @ObservedObject var conductor: Conductor
    let noticeID: String
    var inApp = false
    /// Snapshots: the offer as if it had loaded (a still runs no `.task`).
    var posedOffer: SituationOffer? = nil
    var onClose: () -> Void = {}

    @State private var ask = ""
    @State private var copied: Set<Int> = []
    @State private var ticked: Set<String> = []
    @State private var offer: SituationOffer?
    @State private var offerLooked = false
    @Environment(\.islandSnapshot) private var snapshotting

    var body: some View {
        if let n = conductor.notice(noticeID) {
            VStack(spacing: 0) {
                header(n)
                Divider().overlay(Theme.rule)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !n.offer.isEmpty { offerBody(n) } else { page(n) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().overlay(Theme.rule)
                footer(n)
            }
            .background(Theme.raised)
            .task(id: n.offer) {
                guard !n.offer.isEmpty, !offerLooked else { return }
                let id = n.offer
                let loaded = await Task.detached { SituationOffer.load(id: id) }.value
                offer = loaded
                offerLooked = true
            }
        } else {
            VStack(spacing: 8) {
                Text("This one is finished.").font(Theme.Typo.ui(14, weight: .medium)).foregroundStyle(Theme.ink2)
                Button("Close", action: onClose)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.raised)
        }
    }

    // MARK: Header

    private func header(_ n: InboxItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(n.kind.label, systemImage: NoticeStyle.icon(n.kind))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(NoticeStyle.paperTint(n.kind))
                        .font(Theme.Typo.ui(11.5, weight: .semibold))
                    Text(byline(n)).font(Theme.Typo.ui(11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Text(IslandView.linkedOnPaper(title(n)))
                    .font(Theme.Typo.heading(19))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if n.status == .done, let outcome = n.outcome {
                    Label(outcome, systemImage: "checkmark.circle.fill")
                        .font(Theme.Typo.ui(11.5, weight: .medium))
                        .foregroundStyle(Theme.good)
                }
            }
            Spacer(minLength: 0)
            if !inApp {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.sunk))
                }
                .buttonStyle(.plain)
                .help("Close. It stays in your inbox.")
                .accessibilityLabel("Close")
                .accessibilityHint("It stays in your inbox")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func byline(_ n: InboxItem) -> String {
        let when = NoticeStyle.time(n.at)
        return n.source.isEmpty || n.source == n.kind.label ? "· \(when)" : "· \(n.source) · \(when)"
    }

    /// Ready work is named for what it is: "Reply to Dana Whitfield".
    private func title(_ n: InboxItem) -> String {
        if let o = offer ?? posedOffer, !o.to.isEmpty, !o.draft.isEmpty { return "Reply to \(o.to)" }
        return n.title
    }

    // MARK: The page

    @ViewBuilder
    private func page(_ n: InboxItem) -> some View {
        if !n.summary.isEmpty {
            Text(IslandView.linked(n.summary))
                .font(Theme.Typo.ui(13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sunk))
        }
        let blocks = Self.pageBlocks(n)
        ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
            block(b, index: i)
        }
    }

    /// The body's blocks, without a first heading that only repeats the title.
    static func pageBlocks(_ n: InboxItem) -> [NoticeBlock] {
        var blocks = NoticeBody.blocks(n.body)
        // "Marketing brief, Tue 09-29" under the title "Marketing brief".
        if case .heading(let h) = blocks.first,
           NoticeWords.bare(h).lowercased().hasPrefix(NoticeWords.bare(n.title).lowercased()) {
            blocks.removeFirst()
        }
        if case .prose(let p) = blocks.first, NoticeWords.bare(p) == NoticeWords.bare(n.title) {
            blocks.removeFirst()
        }
        return blocks
    }

    @ViewBuilder
    private func block(_ b: NoticeBlock, index: Int) -> some View {
        switch b {
        case .heading(let h):
            // A section's name, in its own words: a heading can be a whole
            // line ("Reply draft for you to post (r/mac, …)"), and in capitals
            // that read as shouting.
            Text(IslandView.linkedOnPaper(NoticeWords.bare(h)))
                .font(Theme.Typo.ui(14.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        case .prose(let p):
            Text(IslandView.linkedOnPaper(p))
                .font(Theme.Typo.prose(13.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.ink3)
                        Text(IslandView.linkedOnPaper(item))
                            .font(Theme.Typo.prose(13.5))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .todo(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button {
                        if ticked.contains(item) { ticked.remove(item) } else { ticked.insert(item) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: ticked.contains(item) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(ticked.contains(item) ? Theme.good : Theme.ink3)
                            Text(IslandView.linkedOnPaper(item))
                                .font(Theme.Typo.prose(13.5))
                                .foregroundStyle(ticked.contains(item) ? Theme.ink3 : Theme.ink)
                                .strikethrough(ticked.contains(item))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item)
                    .accessibilityValue(ticked.contains(item) ? "Ticked" : "Not ticked")
                }
            }
        case .draft(let d):
            draftCard(d, index: index)
        }
    }

    private func draftCard(_ text: String, index: Int, label: String = "Draft") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(Theme.Typo.label(9.5))
                .tracking(Theme.tracking)
                .foregroundStyle(Theme.ink3)
            Text(text)
                .font(Theme.Typo.prose(13.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                PaperButton(copied.contains(index) ? "Copied" : "Copy",
                            icon: copied.contains(index) ? "checkmark" : "doc.on.doc",
                            style: copied.contains(index) ? .done : .primary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied.insert(index)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.rule, lineWidth: 1))
        // The draft and its Copy as one stop: "Draft, <the words>", with
        // Copy as its action.
        .accessibilityElement(children: .combine)
    }

    // MARK: Ready work: an offer's prepared draft

    @ViewBuilder
    private func offerBody(_ n: InboxItem) -> some View {
        if let offer = offer ?? posedOffer {
            Text(offer.offer.isEmpty ? n.summary : offer.offer)
                .font(Theme.Typo.ui(13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sunk))
            if !offer.to.isEmpty {
                HStack(spacing: 10) {
                    Text("To").font(Theme.Typo.ui(12.5)).foregroundStyle(Theme.ink3).frame(width: 44, alignment: .leading)
                    Text(offer.to + (offer.source.isEmpty ? "" : " · \(offer.source)"))
                        .font(Theme.Typo.ui(13)).foregroundStyle(Theme.ink)
                }
            }
            if !offer.draft.isEmpty { draftCard(offer.draft, index: 10_000, label: "The reply") }
            if !offer.options.isEmpty {
                block(.heading("Other ways to handle it"), index: 10_001)
                block(.bullets(offer.options), index: 10_002)
            }
            if !offer.research.isEmpty {
                block(.heading("What I found"), index: 10_003)
                block(.bullets(offer.research), index: 10_004)
            }
            Text("Nothing is sent until you press Send and confirm.")
                .font(Theme.Typo.ui(11.5))
                .foregroundStyle(Theme.ink3)
        } else if offerLooked || snapshotting {
            page(n)
            Text("This offer is no longer current, so there is nothing to send from it.")
                .font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Footer

    private func footer(_ n: InboxItem) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if snapshotting {
                    Text(ask.isEmpty ? askPlaceholder(n) : ask)
                        .font(Theme.Typo.ui(13.5))
                        .foregroundStyle(ask.isEmpty ? Theme.ink3 : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(askPlaceholder(n), text: $ask)
                        .textFieldStyle(.plain)
                        .font(Theme.Typo.ui(13.5))
                        .onSubmit { continueInIsland(n) }
                        .accessibilityLabel(askPlaceholder(n))
                }
                Button { continueInIsland(n) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(ask.trimmingCharacters(in: .whitespaces).isEmpty
                                                  ? Theme.ink3 : Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Ask Moe about this, in a conversation of its own")
                .accessibilityLabel("Ask Moe about this")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sunk))

            HStack(spacing: 6) {
                if !inApp {
                    PaperButton("Open in app") { conductor.onOpenInboxPage?(n.id); onClose() }
                }
                PaperButton("Continue in island") { continueInIsland(n) }
                if n.kind != .work {
                    PaperButton("Read aloud", icon: "play.fill", style: .quiet) { conductor.playNotice(n.id) }
                }
                Spacer(minLength: 0)
                if n.status == .open { primaryActions(n) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func askPlaceholder(_ n: InboxItem) -> String {
        n.kind == .work ? "Tell Moe what to change" : "Ask about this, or tell Moe what to change"
    }

    @ViewBuilder
    private func primaryActions(_ n: InboxItem) -> some View {
        if !n.buy.isEmpty {
            PaperButton("Not now", style: .quiet) { conductor.finishNotice(n.id, outcome: "Not now"); onClose() }
            PaperButton(n.buyTitle.isEmpty ? "Add a pack" : n.buyTitle, style: .primary) {
                conductor.buyNoticePack(n.id); onClose()
            }
        } else if !n.offer.isEmpty {
            PaperButton("Not this kind", style: .quiet) { conductor.declineNotice(n.id, kind: true); onClose() }
                .help("Moe stops offering this kind of thing")
            PaperButton("Not now", style: .quiet) { conductor.declineNotice(n.id, kind: false); onClose() }
            // Handled another way (the owner, 2026-09-29: "there's no way to
            // complete it"): it leaves the inbox, nothing is sent.
            PaperButton("Done", style: (offer ?? posedOffer)?.draft.isEmpty == false ? .normal : .primary) {
                conductor.finishNotice(n.id, outcome: "Done"); onClose()
            }
            if let offer = offer ?? posedOffer, !offer.draft.isEmpty {
                PaperButton(offer.to.isEmpty ? "Use draft" : offer.to.count > 18 ? "Send reply" : "Send to \(offer.to)",
                            icon: "paperplane.fill",
                            style: .primary) {
                    conductor.useNoticeDraft(n.id, offer: offer)
                    onClose()
                }
            }
        } else {
            switch n.kind {
            case .reminder:
                PaperButton("Snooze 1 hour", style: .quiet) {
                    conductor.snoozeNotice(n.id, until: Date().addingTimeInterval(3600)); onClose()
                }
                PaperButton("Done", style: .primary) { conductor.finishNotice(n.id, outcome: "Done"); onClose() }
            default:
                PaperButton("Got it", style: .primary) { conductor.finishNotice(n.id, outcome: "Got it"); onClose() }
            }
        }
    }

    private func continueInIsland(_ n: InboxItem) {
        conductor.replyToNotice(n.id, text: ask)
        ask = ""
        conductor.onOpenIsland?()
        onClose()
    }
}

/// A button on paper: the app's capsule, in four weights.
struct PaperButton: View {
    enum Style { case primary, normal, quiet, done }
    let title: String
    var icon: String?
    var style: Style = .normal
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, icon: String? = nil, style: Style = .normal, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title).font(Theme.Typo.ui(12.5, weight: style == .primary ? .semibold : .regular))
            }
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(style == .normal ? Theme.rule : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return Theme.onAccent
        case .normal: return Theme.ink
        case .quiet: return hovering ? Theme.ink : Theme.ink2
        case .done: return Theme.good
        }
    }

    private var fill: Color {
        switch style {
        case .primary: return hovering ? Theme.accentDeep : Theme.accent
        case .normal: return hovering ? Theme.sunk : Theme.raised
        case .quiet, .done: return hovering ? Theme.hover : .clear
        }
    }
}

// MARK: - The window

/// A borderless card that can take the keyboard, so the ask box works.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One reading card at a time, on the screen the mouse is on, over whatever
/// the person is doing, on whichever desktop they are on. Movable by its
/// background; Esc or ✕ closes it and leaves the notice in the inbox.
@MainActor
final class NoticeCardWindow {
    static let shared = NoticeCardWindow()
    private var panel: NSPanel?
    private var escMonitor: Any?

    static let size = NSSize(width: 580, height: 680)

    func show(_ id: String, conductor: Conductor) {
        close()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let height = min(Self.size.height, visible.height - 60)
        let frame = NSRect(x: visible.maxX - Self.size.width - 48,
                           y: visible.maxY - height - 30,
                           width: Self.size.width, height: height)
        let p = CardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                          backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let view = NoticeCardView(conductor: conductor, noticeID: id) { [weak self] in self?.close() }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.rule, lineWidth: 1))
        let host = NSHostingView(rootView: view)
        // The window is the size it was given. Left to itself the hosting
        // view grew the panel to the page's full height, and the footer —
        // Send, Done — ended up under the Dock (the owner, 2026-09-29).
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        p.contentView = host
        panel = p
        p.makeKeyAndOrderFront(nil)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self, let panel = self.panel, e.window === panel else { return e }
            self.close()
            return nil
        }
    }

    func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}
