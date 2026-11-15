import Foundation
import Testing
import MoeIsland
@testable import Moe

/// Thinking folds inside the steps, and only when the provider streams it
/// (the owner's answer 10, 2026-11-13).
@MainActor
struct ChatThinkingTests {

    @Test func theStreamCarriesThinkingAsReasoningContent() {
        let with: [String: Any] = ["delta": ["reasoning_content": "Friday is the 14th"]]
        #expect(HermesBrain.reasoning(in: with) == "Friday is the 14th")
        #expect(HermesBrain.reasoning(in: ["delta": ["content": "Booked."]]) == nil)
        #expect(HermesBrain.reasoning(in: ["delta": ["reasoning_content": ""]]) == nil)
    }

    @Test func aTurnKeepsWhatItThought() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("which Friday is it", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.reasoningDelta("The person means "))
        brain.emit(.reasoningDelta("this coming Friday."))
        brain.reply("Friday the 14th.", end: .answered)
        try await Task.sleep(nanoseconds: 100_000_000)

        let answer = try #require(moe.turns.last { $0.role == .moe })
        #expect(answer.thinking == "The person means this coming Friday.")
        #expect(!answer.text.contains("person means"), "thinking leaked into the answer")
        #expect(IslandView.stepsSummary(answer)?.hasPrefix("Thought it through") == true)
        #expect(IslandView.stepLines(answer).contains { $0.hasPrefix("Thinking: The person means") })
    }

    /// A provider that streams no thinking shows nothing for it.
    @Test func noThinkingNoFold() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("hi", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Hey.", end: .answered)
        try await Task.sleep(nanoseconds: 100_000_000)
        let answer = try #require(moe.turns.last { $0.role == .moe })
        #expect(answer.thinking.isEmpty)
        #expect(IslandView.stepsSummary(answer) == nil)
    }

    @Test func summaryWordsWithAndWithoutSteps() {
        #expect(WorkingRow.summary(steps: 0, took: 4, thought: true) == "Thought it through · 4 s")
        #expect(WorkingRow.summary(steps: 2, took: 9, thought: true) == "2 steps · 9 s")
        #expect(WorkingRow.summary(steps: 0, took: nil, thought: false) == nil)
    }
}
