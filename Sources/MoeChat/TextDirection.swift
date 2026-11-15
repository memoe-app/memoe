import Foundation

/// Which way a paragraph reads: the one rule every surface that draws a
/// message uses (the deep dive's §5.3, the owner's answer 13).
///
/// Nothing set a writing direction anywhere in chat, so a Hebrew message
/// right-aligned in the box it was typed into and left-aligned the moment it
/// was sent, and a Hebrew answer that opened on an English word ("Zoom עם
/// דנה מחר") read left to right with its punctuation at the wrong end — the
/// failure every chat app surveyed has open issues about.
///
/// The rule, per paragraph:
/// - no right-to-left letters at all: left to right;
/// - its first letter is right-to-left: right to left;
/// - it opens on a left-to-right word but right-to-left letters are as many
///   as the others, or the message around it is mostly right-to-left: right
///   to left ("Calendar מעודכן." in a Hebrew answer);
/// - otherwise left to right ("Meeting with דנה tomorrow").
/// Only the first `sample` letters of a paragraph are counted, so a
/// paragraph that is still arriving settles on its direction within its
/// first few words and never turns over again later in the stream. Link
/// addresses (`](…)`) are not words and are not counted.
public enum TextDirection: Equatable, Sendable {
    case leftToRight
    case rightToLeft

    public static let sample = 24

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and their
    /// presentation forms; the historic right-to-left blocks too.
    public static func isRightToLeft(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
             0x10800...0x10FFF, 0x1E800...0x1EFFF:
            return true
        default:
            return false
        }
    }

    private static let letters = CharacterSet.letters

    /// Counts of strong letters, right-to-left and not, in the first `limit`
    /// of them, and which kind came first.
    static func census(_ text: String, limit: Int) -> (rtl: Int, ltr: Int, firstIsRTL: Bool?) {
        var rtl = 0, ltr = 0
        var first: Bool?
        var skippingLink = false
        var previous: Unicode.Scalar = " "
        for u in text.unicodeScalars {
            if skippingLink {
                if u == ")" { skippingLink = false }
                previous = u
                continue
            }
            if previous == "]" && u == "(" { skippingLink = true; previous = u; continue }
            previous = u
            if isRightToLeft(u) {
                guard letters.contains(u) || u.properties.isAlphabetic else { continue }
                rtl += 1
                if first == nil { first = true }
            } else if letters.contains(u) {
                ltr += 1
                if first == nil { first = false }
            }
            if rtl + ltr >= limit { break }
        }
        return (rtl, ltr, first)
    }

    /// The whole message's leaning, from up to 400 letters of it.
    public static func message(_ text: String) -> TextDirection {
        let c = census(text, limit: 400)
        return c.rtl > c.ltr ? .rightToLeft : .leftToRight
    }

    /// One paragraph, in a message that leans `context`.
    public static func paragraph(_ text: String, context: TextDirection = .leftToRight) -> TextDirection {
        let c = census(text, limit: sample)
        guard c.rtl > 0 else { return c.ltr > 0 ? .leftToRight : context }
        if c.firstIsRTL == true { return .rightToLeft }
        if c.rtl >= c.ltr || context == .rightToLeft { return .rightToLeft }
        return .leftToRight
    }

    /// The text with an invisible mark in front that fixes its base
    /// direction, so a paragraph that opens on a word of the other script,
    /// or ends on punctuation, is ordered as its direction says.
    public static func marked(_ text: String, _ direction: TextDirection) -> String {
        (direction == .rightToLeft ? "\u{200F}" : "\u{200E}") + text
    }

    /// A paragraph as it should be drawn in a message leaning `context`:
    /// marked with its direction when it holds any right-to-left letters or
    /// sits in a right-to-left message, and left alone otherwise, so an
    /// English message copies out exactly as it was written.
    public static func prepared(_ text: String, context: TextDirection) -> (text: String, direction: TextDirection) {
        let d = paragraph(text, context: context)
        let needsMark = context == .rightToLeft || text.unicodeScalars.contains(where: isRightToLeft)
        return (needsMark ? marked(text, d) : text, d)
    }

    /// Several paragraphs drawn as one block of text (a bubble): each line
    /// marked with its own direction, and the direction the block as a whole
    /// aligns to.
    public static func preparedLines(_ text: String) -> (text: String, direction: TextDirection) {
        let context = message(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // One block aligns one way, so once any line in it is right to left
        // every line carries its own mark, or an English line would take
        // the block's direction and lose its full stop to the wrong end.
        let anyRTL = text.unicodeScalars.contains(where: isRightToLeft)
        let marked = lines.map { line -> String in
            guard !line.isEmpty, anyRTL else { return line }
            return Self.marked(line, paragraph(line, context: context))
        }
        let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return (marked.joined(separator: "\n"), paragraph(first, context: context))
    }
}
