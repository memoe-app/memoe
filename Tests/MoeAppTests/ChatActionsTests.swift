import Foundation
import Testing
import MoeChat
@testable import Moe

/// The buttons under the newest turn, through the real Conductor: Retry
/// asks the failed question again as the same message, Send and Yes are
/// the person's own turn (so the send gate still confirms), and nothing is
/// offered on an old turn or while Moe works.
@MainActor
struct ChatActionsTests {

    @Test func retryAsksAgainAsTheSameMessage() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("what's the weather in Lisbon", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.error("Moe's brain didn't answer."))
        try await Task.sleep(nanoseconds: 50_000_000)

        let note = try #require(moe.turns.last)
        #expect(note.failed)
        #expect(moe.actions(for: note) == [.retry])
        let asked = try #require(moe.turns.last { $0.role == .you })
        let storedAs = asked.storedID ?? asked.id.uuidString

        moe.retry(failed: note.id)
        try await brain.waitForSends(2)
        #expect(brain.sent.last?.text.contains("what's the weather in Lisbon") == true)
        #expect(!moe.turns.contains { $0.failed }, "the failed note stayed")
        let again = moe.turns.filter { $0.role == .you }
        #expect(again.count == 1, "the question is on screen twice")
        #expect(again.first?.storedID == storedAs, "the thread would gain a copy of it")
    }

    @Test func sendIsThePersonsOwnTurn() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("draft a reply to Sam", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Here it is:\n\n> Hi Sam, Thursday works for me.\n\nSend it?", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)

        let answer = try #require(moe.turns.last { $0.role == .moe })
        #expect(moe.actions(for: answer) == [.send, .edit, .copy])
        // An older turn has none.
        let yours = try #require(moe.turns.first { $0.role == .you })
        #expect(moe.actions(for: yours).isEmpty)

        moe.answer(.send)
        try await brain.waitForSends(2)
        #expect(brain.sent.last?.starter == .person)
        #expect(brain.sent.last?.text.contains(ReplyAction.send.words!) == true)
        // While Moe works on it, nothing is offered.
        #expect(moe.actions(for: moe.turns.last!).isEmpty)
    }
}
