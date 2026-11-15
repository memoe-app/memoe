import Foundation
import Testing
@testable import Moe

/// The Chat page while Moe works (docs/CHAT-DEEP-DIVE-2026-11-13.md §2.2–2.4):
/// send turns into ■ with nothing typed, a held message can be taken back
/// or dropped, and the empty placeholder of a reply not yet begun is not
/// drawn as an empty "Moe 6:31".
@MainActor
struct ChatWorkingTests {

    @Test func sendBecomesStopOnlyWhileWorkingWithNothingTyped() {
        #expect(ComposerAction.of(working: true, hasDraft: false) == .stop)
        #expect(ComposerAction.of(working: true, hasDraft: true) == .send(enabled: true))
        #expect(ComposerAction.of(working: false, hasDraft: false) == .send(enabled: false))
        #expect(ComposerAction.of(working: false, hasDraft: true) == .send(enabled: true))
    }

    private func conductor(_ pose: (inout Conductor.SnapshotState) -> Void) throws -> Conductor {
        try StallGuardConductorTests.requireScratchHome()
        var s = Conductor.SnapshotState()
        pose(&s)
        let c = Conductor(config: Config())
        c.pose(s)
        return c
    }

    @Test func aHeldMessageCanBeTakenBackIntoTheBox() throws {
        let c = try conductor { $0.mode = .thinking; $0.awaitingReply = true; $0.queuedTyped = "and Dana too" }
        #expect(c.isWorking)
        let held = c.takeBackQueued()
        #expect(held?.text == "and Dana too")
        #expect(c.queuedTyped == nil)
        #expect(c.takeBackQueued() == nil)
    }

    @Test func aHeldMessageCanBeDropped() throws {
        let c = try conductor { $0.mode = .thinking; $0.awaitingReply = true; $0.queuedTyped = "never mind" }
        c.cancelQueued()
        #expect(c.queuedTyped == nil)
        // Dropped means dropped: the turn ending sends nothing.
        c.pose(Conductor.SnapshotState())
        #expect(!c.turns.contains { $0.text == "never mind" })
    }

    @Test func theEmptyPlaceholderOfAReplyIsNotDrawn() {
        #expect(!ChatPane.drawn(Turn(role: .moe, text: "", isStreaming: true)))
        #expect(ChatPane.drawn(Turn(role: .moe, text: "Nopa has", isStreaming: true)))
        #expect(ChatPane.drawn(Turn(role: .moe, text: "")))
        #expect(ChatPane.drawn(Turn(role: .you, text: "")))
    }

    @Test func timesFollowTheMacsClock() {
        let at = Date(timeIntervalSince1970: 1_763_057_600)   // 18:13 UTC
        let us = ChatTime.make(Locale(identifier: "en_US"))
        us.timeZone = TimeZone(identifier: "UTC")
        let gb = ChatTime.make(Locale(identifier: "en_GB"))
        gb.timeZone = TimeZone(identifier: "UTC")
        #expect(us.string(from: at).contains("PM"))
        #expect(!gb.string(from: at).contains("PM"))
    }
}
