import Testing
import MoeChat
@testable import MoeIsland

/// The owner, 2026-09-25: a drafted email showed as a column of ">" in Chat
/// and on the island. A quote is its own block now, markers removed, drawn
/// as a card on both surfaces.
struct ReplyBlocksTests {

    @Test func aQuotedDraftIsOneBlockWithoutItsMarkers() {
        let blocks = ReplyBlocks.parse("Here it is:\n\n> Hi,\n>\n> I built Memoe.\n\nSend it?")
        #expect(blocks == [.prose("Here it is:"), .quote("Hi,\n\nI built Memoe."), .prose("Send it?")])
    }

    @Test func headingsLoseTheirHashesButHashtagsStay() {
        #expect(ReplyBlocks.parse("## Plan\nstep one") == [.heading("Plan"), .prose("step one")])
        #expect(ReplyBlocks.parse("#launch day") == [.prose("#launch day")])
    }

    @Test func codeFencesStillWork() {
        #expect(ReplyBlocks.parse("run:\n```\nls -la\n```\ndone")
                == [.prose("run:"), .code("ls -la"), .prose("done")])
    }

    @Test func anUnclosedQuoteOrFenceKeepsItsText() {
        #expect(ReplyBlocks.parse("> half a draft") == [.quote("half a draft")])
        #expect(ReplyBlocks.parse("```\nls") == [.code("ls")])
    }

    @Test func plainTextIsOneBlock() {
        #expect(ReplyBlocks.parse("Nopa, 7:00.") == [.prose("Nopa, 7:00.")])
    }

    /// The island measures a quote as the card it draws: taller than the
    /// same words as plain text.
    @Test func theIslandMeasuresAQuoteAsACard() {
        let plain = IslandChat.height(.moe(id: "1", text: "Hi, I built Memoe."))
        let quoted = IslandChat.height(.moe(id: "1", text: "> Hi, I built Memoe."))
        #expect(quoted == plain + IslandChat.boxPad * 2)
    }

    // MARK: Lists, tables, code and paragraphs (deep dive §2.6, 2026-11-13)

    @Test func aListIsItsOwnBlockWithMarkersAndLevels() {
        let blocks = ReplyBlocks.parse("Before you go:\n- Leave by **10:50**\n- Bring the card\n  - the new one\n1. Reply to Dana\n2) Move Eli")
        #expect(blocks == [
            .prose("Before you go:"),
            .list([ReplyListItem(marker: "•", text: "Leave by **10:50**"),
                   ReplyListItem(marker: "•", text: "Bring the card"),
                   ReplyListItem(marker: "•", text: "the new one", level: 1),
                   ReplyListItem(marker: "1.", text: "Reply to Dana"),
                   ReplyListItem(marker: "2.", text: "Move Eli")]),
        ])
    }

    @Test func notEveryDashIsAList() {
        #expect(ReplyBlocks.parse("-\n-5 degrees") == [.prose("-\n-5 degrees")])
        #expect(ReplyBlocks.parse("2026 was good") == [.prose("2026 was good")])
    }

    @Test func anIndentedLineCarriesTheItemOn() {
        #expect(ReplyBlocks.parse("- one\n  still one\nafter") ==
                [.list([ReplyListItem(marker: "•", text: "one still one")]), .prose("after")])
    }

    @Test func aPipeTableIsATable() {
        let blocks = ReplyBlocks.parse("| Flight | Price |\n|---|---:|\n| TP 1361 | €184 |\n| FR 7262 | €96 |\nCheapest is FR.")
        #expect(blocks == [
            .table(ReplyTable(header: ["Flight", "Price"], rows: [["TP 1361", "€184"], ["FR 7262", "€96"]],
                              trailing: [false, true])),
            .prose("Cheapest is FR."),
        ])
    }

    @Test func aPipeWithoutASeparatorIsJustText() {
        #expect(ReplyBlocks.parse("| not a table") == [.prose("| not a table")])
    }

    @Test func aFenceNamesItsLanguageAndKeepsItsIndent() {
        #expect(ReplyBlocks.parse("```swift\nif x {\n    y()\n}\n```")
                == [.code("if x {\n    y()\n}", language: "swift")])
    }

    @Test func aBlankLineSeparatesProseAndEachLineIsAParagraph() {
        let blocks = ReplyBlocks.parse("Two things.\nStandup at 9:30.\n\nThat's all.")
        #expect(blocks == [.prose("Two things.\nStandup at 9:30."), .prose("That's all.")])
        #expect(ReplyBlock.paragraphs("Two things.\nStandup at 9:30.") == ["Two things.", "Standup at 9:30."])
    }

    /// The card is measured as it is drawn: a paragraph break costs its gap,
    /// a list its gaps, code its header and box.
    @Test func theIslandMeasuresEachBlockAsDrawn() {
        let one = IslandChat.height(.moe(id: "1", text: "Two things."))
        let two = IslandChat.height(.moe(id: "1", text: "Two things.\nStandup."))
        #expect(two == one + IslandChat.moeLine + IslandChat.paragraphGap)
        let list = IslandChat.height(.moe(id: "1", text: "- a\n- b"))
        #expect(list == IslandChat.rowSlack + 2 * IslandChat.moeLine + IslandChat.listGap)
        let code = IslandChat.height(.moe(id: "1", text: "```\nls\n```"))
        #expect(code == IslandChat.rowSlack + IslandChat.codeHeader + IslandChat.codeLine + 2 * IslandChat.boxPad)
    }
}

