import Foundation
import Testing
@testable import MoeChat

/// Hebrew and Arabic read right to left on every surface, paragraph by
/// paragraph (the owner's answer 13, 2026-11-13).
struct TextDirectionTests {

    @Test func englishIsLeftToRightAndLeftUnmarked() {
        #expect(TextDirection.paragraph("Your table for two is at 7.") == .leftToRight)
        let p = TextDirection.prepared("Your table for two is at 7.", context: .leftToRight)
        #expect(p.text == "Your table for two is at 7.")
        #expect(p.direction == .leftToRight)
    }

    @Test func hebrewAndArabicAreRightToLeft() {
        #expect(TextDirection.paragraph("שלום, מה שלומך?") == .rightToLeft)
        #expect(TextDirection.paragraph("مرحبا، كيف حالك؟") == .rightToLeft)
        #expect(TextDirection.message("הפגישה עם דנה מחר בעשר.") == .rightToLeft)
    }

    /// The case every chat app gets wrong: a Hebrew line that opens on an
    /// English word, its punctuation at the wrong end.
    @Test func hebrewOpeningOnAnEnglishWordStaysRightToLeft() {
        let line = "Zoom עם דנה מחר בעשר."
        #expect(TextDirection.paragraph(line) == .rightToLeft)
        let p = TextDirection.prepared(line, context: .leftToRight)
        #expect(p.text.unicodeScalars.first == "\u{200F}")
    }

    /// Inside a Hebrew answer, even a mostly-English line opening on an
    /// English word reads with the message.
    @Test func theMessageCarriesAnEnglishLeadInHebrewAnswer() {
        #expect(TextDirection.paragraph("Calendar invite sent to דנה", context: .rightToLeft) == .rightToLeft)
        #expect(TextDirection.paragraph("Calendar invite sent to דנה", context: .leftToRight) == .leftToRight)
    }

    @Test func aHebrewNameInEnglishStaysLeftToRight() {
        #expect(TextDirection.paragraph("Meeting with דנה tomorrow at ten") == .leftToRight)
    }

    /// The direction is settled from the first letters, so a paragraph that
    /// is still streaming does not flip once it is long.
    @Test func directionDoesNotFlipLaterInTheStream() {
        let start = "שלום רב, הנה מה שמצאתי"
        let later = start + " " + String(repeating: "and a lot of English after that ", count: 10)
        #expect(TextDirection.paragraph(start) == .rightToLeft)
        #expect(TextDirection.paragraph(later) == .rightToLeft)
    }

    @Test func linkAddressesAreNotWords() {
        #expect(TextDirection.paragraph("[דנה](https://calendar.example.com/event/abcdefghijklmnop)") == .rightToLeft)
    }

    /// A bubble: each line marked on its own, aligned by its first line.
    @Test func mixedLinesInOneBubble() {
        let text = "תזכיר לי מחר\nSend the deck to Dana"
        let p = TextDirection.preparedLines(text)
        #expect(p.direction == .rightToLeft)
        let lines = p.text.split(separator: "\n").map(String.init)
        #expect(lines[0].unicodeScalars.first == "\u{200F}")
        // An English line in a Hebrew message keeps its own direction.
        #expect(lines[1].unicodeScalars.first == "\u{200E}")
    }

    @Test func anEnglishBubbleIsUntouched() {
        let p = TextDirection.preparedLines("Book it\nfor two")
        #expect(p.text == "Book it\nfor two")
        #expect(p.direction == .leftToRight)
    }

    /// The parser leaves Hebrew lists and quotes alone for the renderer to
    /// direct, and code stays code.
    @Test func hebrewBlocksParseAsTheirKinds() {
        let blocks = ReplyBlocks.parse("""
        הנה הרשימה:
        - חלב
        - Bread מלא
        > שלום דנה,
        > נתראה מחר.
        ```swift
        let x = 1
        ```
        """)
        guard blocks.count == 4,
              case .prose(let intro) = blocks[0],
              case .list(let items) = blocks[1],
              case .quote(let quote) = blocks[2],
              case .code(_, let language) = blocks[3] else {
            Issue.record("blocks: \(blocks)"); return
        }
        let leaning = TextDirection.message("הנה הרשימה: חלב Bread מלא")
        #expect(TextDirection.paragraph(intro, context: leaning) == .rightToLeft)
        #expect(TextDirection.paragraph(items[1].text, context: leaning) == .rightToLeft)
        #expect(TextDirection.preparedLines(quote).direction == .rightToLeft)
        #expect(language == "swift")
    }
}
