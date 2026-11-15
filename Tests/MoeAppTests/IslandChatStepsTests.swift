import Foundation
import Testing
import MoeIsland
@testable import Moe

/// The notch card and the floating window (the same view) after the owner's
/// answers of 2026-11-13: what Moe did folds to one line under a finished
/// answer, and the row that held a lone ⋯ is drawn only while it is used.
@MainActor
struct IslandChatStepsTests {

    private func conductor(_ pose: (inout Conductor.SnapshotState) -> Void) throws -> Conductor {
        try StallGuardConductorTests.requireScratchHome()
        var s = Conductor.SnapshotState()
        pose(&s)
        let c = Conductor(config: Config())
        c.pose(s)
        return c
    }

    private static func answered() -> Turn {
        var t = Turn(role: .moe, text: "Table for two at Nopa, Friday at 7:00.")
        t.tools = ["Looked at your calendar", "Read opentable.com", "Worked through the page"]
        t.took = 48
        t.links = [.init(url: "https://www.opentable.com/r/nopa", label: "opentable.com/r")]
        return t
    }

    @Test func aFinishedAnswerFoldsWhatItDidToOneLine() throws {
        let answer = Self.answered()
        let c = try conductor { $0.turns = [Turn(role: .you, text: "book Nopa"), answer] }
        let rows = IslandView.chatRows(c)
        let id = answer.id.uuidString + ":steps"
        #expect(rows.last == .steps(id: id, summary: "3 steps · 48 s · 1 source", lines: []))
        let open = IslandView.chatRows(c, openSteps: [id])
        #expect(open.last == .steps(id: id, summary: "3 steps · 48 s · 1 source",
                                    lines: answer.tools + ["opentable.com/r"]))
        // Opened, the card is measured taller by exactly the list.
        let folded = IslandChat.height(rows.last!)
        let opened = IslandChat.height(open.last!)
        #expect(opened - folded == IslandChat.stepsGap + 4 * IslandChat.stepLine)
    }

    @Test func noStepsLineWhileTheAnswerIsStillArriving() throws {
        var answer = Self.answered()
        answer.isStreaming = true
        let c = try conductor { $0.mode = .thinking; $0.turns = [answer] }
        #expect(!IslandView.chatRows(c).contains { if case .steps = $0 { return true } else { return false } })
    }

    @Test func anAnswerThatDidNothingHasNoStepsLine() throws {
        let c = try conductor { $0.turns = [Turn(role: .moe, text: "Hi.")] }
        #expect(IslandView.chatRows(c) == [.moe(id: c.turns[0].id.uuidString, text: "Hi.")])
    }

    @Test func theControlsRowIsDrawnOnlyWhileOpenOrMuted() {
        #expect(!Dropdown.showsControlsRow(hasControls: true, open: false, muted: false))
        #expect(Dropdown.showsControlsRow(hasControls: true, open: true, muted: false))
        #expect(Dropdown.showsControlsRow(hasControls: true, open: false, muted: true))
        #expect(!Dropdown.showsControlsRow(hasControls: false, open: true, muted: true))
    }

    /// The card is sized for what is drawn: a finished answer, folded, has
    /// no controls row under it any more.
    @Test func theCardNoLongerCountsALoneTrayRow() throws {
        let c = try conductor { $0.turns = [Turn(role: .you, text: "hi"), Self.answered()] }
        let contents = IslandView.dropdownContents(c, draft: IslandDraft(), accessibility: nil,
                                                   updateShowing: false, width: 420,
                                                   notch: CGSize(width: 200, height: 32))
        #expect(!contents.controls)
        let draft = IslandDraft()
        draft.trayOpen = true
        let opened = IslandView.dropdownContents(c, draft: draft, accessibility: nil,
                                                 updateShowing: false, width: 420,
                                                 notch: CGSize(width: 200, height: 32))
        #expect(opened.controls)
    }
}
