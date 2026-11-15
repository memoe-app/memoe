import Foundation
import Testing
import MoeChat
import MoeLedger
@testable import Moe

/// Edit and resend (the owner's answer, 2026-11-13: a fresh session, no fork).
/// The chat is cut at the edited message and goes on as a new thread; the
/// turns before it are told to a fresh session the way reopening a chat tells
/// them; the old thread goes through the ledger's own delete.
@MainActor
struct ChatEditResendTests {

    private func twoExchanges() async throws -> (Conductor, FakeBrain) {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("Book a table for two on Friday", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Nopa has 7:30.", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)
        moe.submit("Make it Saturday", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        brain.reply("Saturday at 8 then.", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)
        moe.saveConversation(flush: true)
        return (moe, brain)
    }

    @Test func theChatIsCutThereAndTheChangedMessageGoes() async throws {
        let (moe, brain) = try await twoExchanges()
        let old = moe.currentConversationID
        let second = try #require(moe.turns.last { $0.role == .you })
        moe.pinConversation(id: old, true)

        moe.resend(editing: second.id, to: "Make it Sunday")
        try await brain.waitForSends(3)

        #expect(moe.turns.map(\.text).filter { !$0.isEmpty } == ["Book a table for two on Friday", "Nopa has 7:30.", "Make it Sunday"])
        #expect(brain.sent.last?.text.contains("Make it Sunday") == true)
        let new = moe.currentConversationID
        #expect(new != old, "the edited chat kept its thread, so its session still holds what was cut")

        // A fresh session, told the kept turns and nothing that was cut.
        let resume = try #require(brain.resumed.last)
        #expect(resume.threadID == new)
        let priming = try #require(resume.priming, "the kept turns were not replayed")
        #expect(priming.contains("Nopa has 7:30."))
        #expect(!priming.contains("Saturday"), "a cut turn was told to the new session")

        // The old thread is gone through the ledger's delete; its pin went with the chat.
        #expect(moe.conversationLedger.deletedThreads().contains(old))
        #expect(!moe.conversations().contains { $0.id == old })
        #expect(moe.conversationMarks()[new]?.pinned == true)
        #expect(moe.conversationMarks()[old] == nil)

        brain.reply("Sunday at 7.", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)
        moe.saveConversation(flush: true)
        let saved = try #require(moe.conversations().first { $0.id == new })
        #expect(saved.turns.map(\.text) == ["Book a table for two on Friday", "Nopa has 7:30.",
                                            "Make it Sunday", "Sunday at 7."],
                "the new thread holds the kept turns once each, then the new exchange")
    }

    @Test func editingTheFirstMessageStartsAfresh() async throws {
        let (moe, brain) = try await twoExchanges()
        let first = try #require(moe.turns.first { $0.role == .you })
        moe.resend(editing: first.id, to: "Book a table for four")
        try await brain.waitForSends(3)
        #expect(moe.turns.map(\.text).filter { !$0.isEmpty } == ["Book a table for four"])
        #expect(brain.resumed.last?.priming == nil)
    }

    @Test func notWhileMoeIsWorking() async throws {
        let (moe, brain) = try await twoExchanges()
        let first = try #require(moe.turns.first { $0.role == .you })
        let thread = moe.currentConversationID
        moe.submit("And a cake", origin: .typed, starter: .person)
        try await brain.waitForSends(3)
        #expect(!moe.canEdit(first.id))
        moe.resend(editing: first.id, to: "changed")
        #expect(moe.currentConversationID == thread)
        #expect(moe.turns.first?.text == "Book a table for two on Friday")
    }
}
