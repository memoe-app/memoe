import Foundation

/// A reply's block structure: the parts `ReplyMarkdown.inline` does not read.
///
/// The model writes a drafted email or message as a markdown quote — every
/// line starting "> " — and headings as "# ". Inline parsing leaves those
/// markers on the page, so a draft reached the chat window and the island as
/// a column of ">" down the left edge (the owner, 2026-09-25: "it doesn't look
/// like a clean email-style situation"). The chat window and the island both
/// draw from this one split, a quote as a card of its own.
///
/// Lists and tables joined them on 2026-11-13 (deep dive §2.6, the owner's
/// answer 8): a list printed as lines that happened to start with "-", with
/// no hanging indent, and a table as rows of "|".
public enum ReplyBlock: Hashable, Sendable {
    /// Ordinary text, inline markdown still in it. One paragraph per line:
    /// a blank line ends the block.
    case prose(String)
    /// A fenced ``` block, and the language named on its fence, if any.
    case code(String, language: String? = nil)
    /// A quoted block, markers removed: usually a draft Moe wrote for you.
    case quote(String)
    /// A "# heading" line, markers removed.
    case heading(String)
    /// Consecutive "- " / "1. " lines, markers taken off and kept apart so
    /// a wrapped line sits under the text, not under the bullet.
    case list([ReplyListItem])
    /// A pipe table with its separator line.
    case table(ReplyTable)

    /// The paragraphs of a prose block, one per line.
    public static func paragraphs(_ prose: String) -> [String] {
        prose.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

public struct ReplyListItem: Hashable, Sendable {
    /// "•" for a bullet, "3." for a numbered item (the number as written).
    public var marker: String
    /// The item's words, inline markdown still in them.
    public var text: String
    /// 0 at the margin; one more per two spaces of indent, up to 3.
    public var level: Int

    public init(marker: String, text: String, level: Int = 0) {
        self.marker = marker
        self.text = text
        self.level = level
    }

    public var ordered: Bool { marker != "•" }
}

public struct ReplyTable: Hashable, Sendable {
    public var header: [String]
    public var rows: [[String]]
    /// Per column: right-aligned (a "---:" separator), for numbers.
    public var trailing: [Bool]

    public init(header: [String], rows: [[String]], trailing: [Bool] = []) {
        self.header = header
        self.rows = rows
        self.trailing = trailing
    }

    public var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// Row `r`'s cell in column `c`, or "" where the row is short.
    public func cell(_ r: Int, _ c: Int) -> String {
        rows.indices.contains(r) && rows[r].indices.contains(c) ? rows[r][c] : ""
    }
}

public enum ReplyBlocks {

    public static func parse(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        var buffer: [String] = []
        var items: [ReplyListItem] = []
        var kind: Kind = .prose
        var language: String?

        enum Kind { case prose, code, quote }

        func flushList() {
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
        }

        func flush() {
            flushList()
            let joined = buffer.joined(separator: "\n")
            buffer = []
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            switch kind {
            case .prose: blocks.append(.prose(trimmed))
            case .code:
                // Code keeps its own indentation; only blank edges go.
                let code = joined.trimmingCharacters(in: .newlines)
                blocks.append(.code(code, language: language))
            case .quote: blocks.append(.quote(trimmed))
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let bare = line.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if bare.hasPrefix("```") {
                if kind == .code {
                    flush()
                    kind = .prose
                    language = nil
                } else {
                    flush()
                    kind = .code
                    let name = bare.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = name.isEmpty ? nil : name
                }
                continue
            }
            if kind == .code { buffer.append(line); continue }
            if bare.hasPrefix(">") {
                if kind != .quote { flush(); kind = .quote }
                var rest = bare.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                buffer.append(String(rest))
                continue
            }
            if kind == .quote {
                // A blank line inside a quote is the quote's own paragraph
                // break only when the quote carries on after it; otherwise
                // the quote has ended.
                flush(); kind = .prose
            }
            if bare.isEmpty {
                // A blank line ends a paragraph group or a list.
                flush()
                continue
            }
            if let heading = headingText(bare) {
                flush()
                blocks.append(.heading(heading))
                continue
            }
            if bare.hasPrefix("|"), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flush()
                let header = cells(bare)
                let trailing = cells(lines[i + 1]).map { $0.hasSuffix(":") && !$0.hasPrefix(":") }
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let row = lines[j].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(cells(row))
                    j += 1
                }
                blocks.append(.table(ReplyTable(header: header, rows: rows, trailing: trailing)))
                i = j - 1
                continue
            }
            if let item = listItem(line) {
                if !buffer.isEmpty {
                    // Prose before the list ends where the list starts.
                    let held = items
                    items = []
                    flush()
                    items = held
                }
                items.append(item)
                continue
            }
            if !items.isEmpty {
                // An indented line under an item carries that item on;
                // anything else ends the list.
                if line.hasPrefix("  ") || line.hasPrefix("\t") {
                    items[items.count - 1].text += " " + bare
                    continue
                }
                flushList()
            }
            buffer.append(line)
        }
        // An unclosed fence or quote keeps its text either way: a stream cut
        // mid-block is the normal case, not an error.
        flush()
        return blocks
    }

    /// "# Title" / "## Title" / "### Title" → "Title"; nil for anything else
    /// ("#hashtag", "#1" are not headings).
    static func headingText(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// "- x", "* x", "• x", "+ x", "1. x", "2) x", with its indent as a level.
    /// A line of only "-" or "**bold**" is not one.
    static func listItem(_ line: String) -> ReplyListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(line.prefix(while: { $0 == " " || $0 == "\t" }).count)
        let level = min(indent / 2, 3)
        if let first = rest.first, "-*•+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return ReplyListItem(marker: "•", text: text, level: level)
        }
        let digits = rest.prefix(while: \.isNumber)
        guard (1...3).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")",
              after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ReplyListItem(marker: "\(digits).", text: text, level: level)
    }

    /// "|---|:--:|---:|", the line under a table's header.
    static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix(":") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
            && cells(t).allSatisfy { cell in cell.filter { $0 == "-" }.count >= 1 }
    }

    static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
