import MoeDesign
import SwiftUI

// The Memory page's rows and its To check card. The page is MemoryPane.swift.

/// One line of a section. **Its size never depends on the pointer**: the
/// words always have the same width — the row's, less one trailing column
/// of `actionWidth` that is there hovered or not — and where the line came
/// from sits on a line of its own under the words, always laid out, only
/// opaque on hover. The owner's screenshot of 2026-09-22 had a To check line
/// re-wrap into ten lines because "WhatsApp · Jul 16" was inserted beside it.
struct MemoryRowView: View {
    /// The trailing column: Discuss and ×, or Restore. One width for every
    /// row, so every line on a page wraps at the same measure.
    static let actionWidth: CGFloat = 88

    let item: MemoryItem
    let text: String
    let meta: String
    let editing: Bool
    let selected: Bool
    let hovered: Bool
    @Binding var draft: String
    var focus: FocusState<MemoryPane.Focus?>.Binding
    let begin: () -> Void
    let save: () -> Void
    let cancel: () -> Void
    let forget: () -> Void
    let confirm: () -> Void
    let restore: () -> Void
    var discuss: () -> Void = {}
    var pointOnDiscuss = false
    let hover: (Bool) -> Void
    /// The words' laid-out width, each time it changes (the layout test).
    var measured: ((CGFloat) -> Void)? = nil

    var body: some View {
        Group {
            if editing {
                field
            } else {
                HStack(alignment: .top, spacing: Theme.Space.base) {
                    VStack(alignment: .leading, spacing: 3) {
                        words
                        // Always laid out, so hover changes no height.
                        Text(meta.isEmpty ? " " : meta)
                            .font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                            .opacity(hovered && !meta.isEmpty ? 1 : 0)
                            .accessibilityHidden(!hovered || meta.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured?($0) }
                    actions
                        .frame(width: Self.actionWidth, alignment: .trailing)
                        .opacity(hovered ? 1 : 0)
                        .allowsHitTesting(hovered)
                }
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(
                    Rectangle().fill(selected ? Theme.hover : Color.clear)
                        .padding(.horizontal, -Theme.Space.small)
                )
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture(perform: begin)
            }
        }
        .onHover(perform: hover)
    }

    /// The line as words. A people line's name is semibold and what they
    /// are to the person is a shade lighter.
    private var words: some View {
        Group {
            if let name = MemoryReader.boldName(item.line?.text ?? ""), text.hasPrefix(name) {
                Text(verbatim: name).fontWeight(.semibold).foregroundColor(Theme.ink)
                    + Text(verbatim: String(text.dropFirst(name.count))).foregroundColor(Theme.ink2)
            } else {
                Text(verbatim: text)
            }
        }
        .font(MemoryPane.lineFont)
        .foregroundStyle(item.role == .past ? Theme.ink2 : Theme.ink)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.role == .question {
                Text(verbatim: text).font(MemoryPane.lineFont).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 13)
            }
            EditBox {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(MemoryPane.lineFont)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .focused(focus, equals: .field)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .background(alignment: .leading) {
                        if draft.isEmpty && item.role == .question {
                            Text("Your answer").font(MemoryPane.lineFont).foregroundStyle(Theme.ink3)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    /// What a line offers on hover, in the fixed column.
    @ViewBuilder private var actions: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            switch item.role {
            case .past:
                QuietLink(title: "Restore", help: "Bring this back", action: restore)
            case .line, .check, .question:
                QuietLink(title: "Discuss", help: "Talk this line through with Moe, in Chat",
                          over: pointOnDiscuss, action: discuss)
                Button(action: forget) {
                    Text("×")
                        .font(Theme.Typo.ui(16))
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Forget this")
                .accessibilityLabel("Forget this")
            }
        }
        .fixedSize()
    }
}

/// A word that does something, in the page's own voice: no box, no arrow.
struct QuietLink: View {
    let title: String
    var help: String? = nil
    /// Drawn as if the pointer were on it (the snapshot's Discuss hover).
    var over: Bool = false
    let action: () -> Void
    @State private var pointer = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.ui(14))
                .foregroundStyle(over || pointer ? Theme.ink : Theme.ink3)
                .underline(over || pointer, color: Theme.ink3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { pointer = $0 }
        .help(help ?? "")
    }
}

// MARK: - To check, the card

/// One thing Moe is unsure of, asked once: mockup D ("One at a time"), in
/// design B's type and the Theme's colours. A raised card, the quiet
/// "Moe isn't sure · 1 of 3", the question in the display face, and three
/// large choices — Yes (filled), No (outlined), Something else… (words) —
/// with Skip quiet at the far end. "Something else…" opens a field in the
/// card; Return saves it.
struct CheckCardView: View {
    let card: CheckCard
    let position: Int
    let total: Int
    let otherOpen: Bool
    @Binding var otherDraft: String
    var focus: FocusState<MemoryPane.Focus?>.Binding
    let answer: (CardAnswer) -> Void
    let openOther: () -> Void
    let closeOther: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(heading)
                .font(Theme.Typo.ui(13))
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: Theme.Space.small) {
                if let detail = card.detail {
                    Text(card.prompt)
                        .font(Theme.Typo.ui(15))
                        .foregroundStyle(Theme.ink2)
                    quoted(detail)
                } else {
                    Text(verbatim: Self.curled(card.prompt))
                        .font(Theme.Typo.display(card.prompt.count > 90 ? 20 : 24)).fontWeight(.regular)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if otherOpen || card.shape == .open { other } else { choices }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.rule, lineWidth: 1))
    }

    /// "2 of 6" — with the kind only when it says more than the page's own
    /// subtitle does ("Moe isn't sure about these" is already above it).
    private var heading: String {
        let count = "\(position) of \(total)"
        return card.label == "Moe isn't sure" ? count : "\(card.label) · \(count)"
    }

    /// Straight quotes as the crawl writes them, curled as a page sets them.
    static func curled(_ text: String) -> String {
        var out = ""
        var prev: Character = " "
        for ch in text {
            let opens = prev.isWhitespace || "([{—–-".contains(prev)
            switch ch {
            case "\"": out.append(opens ? "“" : "”")
            case "'": out.append(opens ? "‘" : "’")
            default: out.append(ch)
            }
            prev = ch
        }
        return out
    }

    /// The line asked about, in the display face; a person's name weighted.
    private func quoted(_ detail: String) -> some View {
        var raw = ""
        if case .line(let l) = card.kind { raw = l.text }
        return Group {
            if let name = MemoryReader.boldName(raw), detail.hasPrefix(name) {
                Text(verbatim: name).fontWeight(.medium).foregroundColor(Theme.ink)
                    + Text(verbatim: String(detail.dropFirst(name.count))).foregroundColor(Theme.ink2)
            } else {
                Text(verbatim: detail).foregroundColor(Theme.ink)
            }
        }
        .font(Theme.Typo.display(24))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var choices: some View {
        if card.choices.isEmpty {
            // One row while it fits; narrower, Yes and No above the rest —
            // never a button broken mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    yesNo
                    elseButton
                    Spacer(minLength: Theme.Space.base)
                    skipButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        yesNo
                        Spacer(minLength: Theme.Space.base)
                        skipButton
                    }
                    // Its words line up with Yes above, not its padding.
                    elseButton.padding(.leading, -12)
                }
            }
        } else {
            // Which is right: each line is a choice (1, 2).
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(card.choices.enumerated()), id: \.offset) { i, c in
                    CardButton(title: c, style: .choice, key: "\(i + 1)") { answer(.pick(i)) }
                }
                HStack(spacing: 10) {
                    elseButton
                    Spacer(minLength: Theme.Space.base)
                    skipButton
                }
            }
        }
    }

    @ViewBuilder private var yesNo: some View {
        CardButton(title: "Yes", style: .filled, key: "Y") { answer(.yes) }
        CardButton(title: "No", style: .outlined, key: "N") { answer(.no) }
    }

    /// Not on "Remember this again?": a deleted fact is kept or let go,
    /// and a new wording is an ordinary line the person can add.
    @ViewBuilder private var elseButton: some View {
        if case .line(let l) = card.kind, l.revival {
            EmptyView()
        } else {
            CardButton(title: "Something else…", style: .words, key: "E", action: openOther)
        }
    }

    private var skipButton: some View {
        Button(action: skip) {
            Text("Skip").font(Theme.Typo.ui(14)).foregroundStyle(Theme.ink3)
                .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Ask me later (→)")
    }

    /// On an open question: close it, it does not need an answer.
    private var dismissButton: some View {
        Button { answer(.dismiss) } label: {
            Text("Doesn’t matter").font(Theme.Typo.ui(14)).foregroundStyle(Theme.ink3)
                .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Moe stops asking about this")
    }

    private var other: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            TextField("", text: $otherDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Typo.prose(17))
                .foregroundStyle(Theme.ink)
                .focused(focus, equals: .other)
                .onSubmit { answer(.other(otherDraft)) }
                .onExitCommand(perform: closeOther)
                .background(alignment: .leading) {
                    if otherDraft.isEmpty {
                        Text(card.detail != nil ? "What is right?" : "Your answer")
                            .lineLimit(1)
                            .font(Theme.Typo.prose(17)).foregroundStyle(Theme.ink3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5))
            HStack(spacing: Theme.Space.base) {
                CardButton(title: "Save", style: .filled, key: nil) { answer(.other(otherDraft)) }
                if card.shape == .open {
                    dismissButton
                    Spacer(minLength: Theme.Space.small)
                    skipButton
                } else {
                    Button(action: closeOther) {
                        Text("Cancel").font(Theme.Typo.ui(14)).foregroundStyle(Theme.ink3)
                            .padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    Spacer(minLength: Theme.Space.small)
                    Text("Return saves · Esc goes back")
                        .font(Theme.Typo.ui(12)).foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
        }
    }
}

/// A choice on the card: filled (the accent), outlined, plain words, or a
/// whole line to pick (outlined, full width, the only one that wraps).
private struct CardButton: View {
    enum Style { case filled, outlined, words, choice }
    let title: String
    let style: Style
    let key: String?
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(Theme.Typo.ui(15, weight: style == .filled ? .medium : .regular))
                .foregroundStyle(style == .filled ? Theme.onAccent
                                 : style == .words ? (over ? Theme.ink : Theme.ink2) : Theme.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(style == .choice ? nil : 1)
                .fixedSize(horizontal: style != .choice, vertical: true)
                .padding(.horizontal, style == .words ? 12 : style == .choice ? 16 : 20)
                .padding(.vertical, 10)
                .frame(minWidth: style == .words ? 0 : 72,
                       maxWidth: style == .choice ? .infinity : nil,
                       alignment: style == .choice ? .leading : .center)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(style == .filled ? (over ? Theme.accentDeep : Theme.accent)
                              : style != .words && over ? Theme.hover : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style == .outlined || style == .choice ? Theme.ruleStrong : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .help(key.map { "\(title) (\($0))" } ?? title)
    }
}
