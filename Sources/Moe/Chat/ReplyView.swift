import AppKit
import MoeChat
import MoeDesign
import MoeIsland
import SwiftUI

/// One renderer for an answer's blocks, on every surface: the Chat page, the
/// notch card and the floating window (which draws the notch card's view).
///
/// The deep dive (§6) found two renderers already, and every new block kind
/// a two-place change; a third would have made it three. Each surface passes
/// a `ReplyStyle` — its fonts, inks and spacing — and nothing else. The notch
/// card's numbers are `IslandChat`'s, so what it draws is what it measured.
struct ReplyStyle {
    var proseSize: CGFloat
    var proseFont: (CGFloat) -> Font
    var ink: Color
    var dim: Color
    var cardFill: Color
    var cardStroke: Color
    var codeSize: CGFloat
    var codeInk: Color
    var blockGap: CGFloat
    var paragraphGap: CGFloat
    var listGap: CGFloat
    var listMarker: CGFloat
    var listIndent: CGFloat
    var boxPad: CGFloat
    var codeHeader: CGFloat
    var tableSize: CGFloat
    /// Wider tables fold to a line that opens the window; nil draws any.
    var tableColumns: Int?
    var lineSpacing: CGFloat
    /// Inline markdown to attributed text, with this surface's link colour.
    var inline: (String) -> AttributedString
    /// "Open in window", for what the surface folds away.
    var openWindow: (() -> Void)?

    /// The Chat page: the reading serif on paper.
    static var page: ReplyStyle {
        ReplyStyle(proseSize: 15, proseFont: { Theme.Typo.prose($0) },
                   ink: Theme.ink, dim: Theme.ink3,
                   cardFill: Theme.sunk, cardStroke: Theme.rule,
                   codeSize: 12.5, codeInk: Theme.ink2,
                   blockGap: Theme.Space.base, paragraphGap: 5, listGap: 4,
                   listMarker: 20, listIndent: 18, boxPad: Theme.Space.base,
                   codeHeader: 24, tableSize: 13, tableColumns: nil, lineSpacing: 3,
                   inline: { ReplyMarkdown.inline($0) }, openWindow: nil)
    }

    /// The notch card and the floating window: white on black, at
    /// `IslandChat`'s sizes.
    static func island(openWindow: (() -> Void)?) -> ReplyStyle {
        ReplyStyle(proseSize: CGFloat(IslandChat.moeSize), proseFont: { .system(size: $0) },
                   ink: .white.opacity(0.96), dim: .white.opacity(0.5),
                   cardFill: .white.opacity(0.07), cardStroke: .white.opacity(0.10),
                   codeSize: CGFloat(IslandChat.codeSize), codeInk: .white.opacity(0.88),
                   blockGap: CGFloat(IslandChat.blockGap), paragraphGap: CGFloat(IslandChat.paragraphGap),
                   listGap: CGFloat(IslandChat.listGap), listMarker: CGFloat(IslandChat.listMarker),
                   listIndent: CGFloat(IslandChat.listIndent), boxPad: CGFloat(IslandChat.boxPad),
                   codeHeader: CGFloat(IslandChat.codeHeader), tableSize: CGFloat(IslandChat.tableSize),
                   tableColumns: openWindow == nil ? nil : IslandChat.tableColumnsOnCard,
                   lineSpacing: 0,
                   inline: { IslandView.linked($0) }, openWindow: openWindow)
    }
}

/// An answer, block by block, in a style.
struct ReplyView: View {
    let blocks: [ReplyBlock]
    let style: ReplyStyle
    /// Which way the answer as a whole leans: a paragraph that opens on an
    /// English word in a Hebrew answer still reads right to left.
    let leaning: TextDirection

    init(_ text: String, style: ReplyStyle) {
        self.blocks = ReplyBlocks.parse(text)
        self.style = style
        self.leaning = TextDirection.message(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ReplyBlockView(block: block, style: style, leaning: leaning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReplyBlockView: View {
    let block: ReplyBlock
    let style: ReplyStyle
    var leaning: TextDirection = .leftToRight

    var body: some View {
        switch block {
        case .prose(let s):
            VStack(alignment: .leading, spacing: style.paragraphGap) {
                ForEach(Array(ReplyBlock.paragraphs(s).enumerated()), id: \.offset) { _, p in
                    paragraph(p)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let s):
            paragraph(s, weight: .semibold)
        case .quote(let s):
            // A draft Moe wrote for you: a card, the way a mail client shows
            // a message, not a column of ">" (the owner, 2026-09-25).
            let lines = TextDirection.preparedLines(s)
            text(lines.text, size: style.proseSize - 0.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .reads(lines.direction)
                .padding(style.boxPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card)
                .overlay(cardEdge)
        case .code(let s, let language):
            code(s, language: language)
        case .list(let items):
            VStack(alignment: .leading, spacing: style.listGap) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listItem(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .table(let t):
            if let most = style.tableColumns, t.columns > most {
                foldedTable(t)
            } else {
                table(t)
            }
        }
    }

    // MARK: Pieces

    private func text(_ s: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Text(style.inline(s))
            .font(style.proseFont(size).weight(weight))
            .foregroundStyle(style.ink)
            .lineSpacing(style.lineSpacing)
    }

    /// A paragraph in its own direction: right-aligned and right to left
    /// when it is Hebrew or Arabic, whatever the paragraphs around it are.
    private func paragraph(_ s: String, weight: Font.Weight = .regular) -> some View {
        let p = TextDirection.prepared(s, context: leaning)
        return text(p.text, size: style.proseSize, weight: weight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .reads(p.direction)
    }

    /// The marker in a column of its own, so a wrapped line sits under the
    /// text and not under the bullet.
    /// A right-to-left item puts its marker on the right.
    private func listItem(_ item: ReplyListItem) -> some View {
        let p = TextDirection.prepared(item.text, context: leaning)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(item.marker)
                .font(style.proseFont(style.proseSize).monospacedDigit())
                .foregroundStyle(item.ordered ? style.ink : style.dim)
                .frame(width: style.listMarker, alignment: .leading)
            text(p.text, size: style.proseSize)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.level) * style.listIndent)
        .reads(p.direction)
    }

    private func code(_ s: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language ?? "code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(style.dim)
                Spacer(minLength: 0)
                CopyGlyphButton(text: s, ink: style.dim)
            }
            .frame(height: style.codeHeader)
            Text(s)
                .font(.system(size: style.codeSize, design: .monospaced))
                .foregroundStyle(style.codeInk)
                .lineSpacing(CGFloat(IslandChat.codeLine) - style.codeSize - 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, style.boxPad)
        .padding(.bottom, style.boxPad)
        .padding(.top, style.boxPad - 4)
        .background(card)
        .overlay(cardEdge)
        // Code reads left to right whatever the text around it.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func table(_ t: ReplyTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<t.columns, id: \.self) { c in
                    cell(t.header.indices.contains(c) ? t.header[c] : "", bold: true,
                         trailing: t.trailing.indices.contains(c) && t.trailing[c])
                }
            }
            Divider().overlay(style.cardStroke)
            ForEach(t.rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(0..<t.columns, id: \.self) { c in
                        cell(t.cell(r, c), bold: false,
                             trailing: t.trailing.indices.contains(c) && t.trailing[c])
                    }
                }
            }
        }
        .padding(.horizontal, style.boxPad)
        .padding(.bottom, style.boxPad / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
        .overlay(cardEdge)
        // A Hebrew table starts its first column on the right.
        .reads(leaning)
    }

    private func cell(_ s: String, bold: Bool, trailing: Bool) -> some View {
        Text(style.inline(s))
            .font(style.proseFont(style.tableSize).weight(bold ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(bold ? style.ink : style.ink.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .padding(.vertical, CGFloat(IslandChat.tableRowPad) / 2)
    }

    /// A table too wide for the card: a line that says so and opens the
    /// window, where it is drawn whole.
    private func foldedTable(_ t: ReplyTable) -> some View {
        Button { style.openWindow?() } label: {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                Text("A table, \(t.rows.count) rows · Open in window")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(style.dim)
            .frame(height: CGFloat(IslandChat.moeLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the conversation in the Memoe window")
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.cardFill)
    }

    private var cardEdge: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.cardStroke, lineWidth: 1)
    }
}

extension View {
    /// Lays this out, and its text, in a direction: leading is the right
    /// edge for right to left. Every surface that draws a message uses it.
    func reads(_ direction: TextDirection) -> some View {
        environment(\.layoutDirection, direction == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// Copy, as a small glyph that says "Copied" for a moment.
struct CopyGlyphButton: View {
    let text: String
    let ink: Color
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied" : "Copy")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .frame(minWidth: 24, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy the code")
        .accessibilityLabel(copied ? "Copied" : "Copy the code")
    }
}
