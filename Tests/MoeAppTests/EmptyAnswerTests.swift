import Foundation
import Testing
import MoeVoice
import MoeLedger
@testable import Moe

/// A stream that ends with nothing in it is a failure the person is told
/// about — not a finished turn with an empty answer.
///
/// Before 2026-11-12 `HermesBrain` closed such a turn with `error: nil`, and
/// the Conductor has no branch for an empty answer: the island went quiet as
/// though Moe had replied. The first two tests put real bytes through
/// HermesBrain's own URLSession delegate and SSE parser and end the stream
/// the way URLSession does; the third drives the real Conductor with the
/// events that come out, and looks at what is on screen.
@MainActor
@Suite(.serialized)
struct EmptyAnswerTests {

    private static func events(for bytes: Data) async throws -> [BrainEvent] {
        // finishTurn clears the in-flight record under the home.
        try StallGuardConductorTests.requireScratchHome()
        let brain = HermesBrain(config: Config())
        var events: [BrainEvent] = []
        brain.onEvent = { events.append($0) }
        brain.replayStreamForTesting(bytes, thenEnd: true)
        func finished() -> Bool {
            events.contains { if case .turnFinished = $0 { return true } else { return false } }
        }
        for _ in 0..<100 where !finished() { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(finished(), "the brain never finished the turn: \(events)")
        return events
    }

    @Test func aStreamThatEndsWithNothingIsAFailureWithWords() async throws {
        // A role chunk and a keepalive, then the connection closes: no
        // content, no finish_reason, no [DONE].
        let sse = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}\n\n: keepalive\n\n"
        let events = try await Self.events(for: Data(sse.utf8))

        let errors = events.compactMap { e -> String? in
            if case .error(let m) = e { return m } else { return nil }
        }
        #expect(errors == [HermesBrain.noAnswerNote], "the person was told nothing: \(events)")
        let ends = events.compactMap { e -> TurnEnd? in
            if case .turnFinished(_, let end) = e { return end } else { return nil }
        }
        #expect(ends == [.failed])
    }

    /// The other side of the line: some of the answer arrived, so it stands.
    @Test func aStreamThatEndsEarlyWithWordsKeepsThem() async throws {
        let sse = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Half an answer\"},\"finish_reason\":null}]}\n\n"
        let events = try await Self.events(for: Data(sse.utf8))

        #expect(!events.contains { if case .error = $0 { return true } else { return false } })
        let ends = events.compactMap { e -> (String, TurnEnd)? in
            if case .turnFinished(let t, let end) = e { return (t, end) } else { return nil }
        }
        #expect(ends.count == 1)
        #expect(ends.first?.0 == "Half an answer")
        #expect(ends.first?.1 == .streamEnded)
    }

    /// What the brain now emits, through the real Conductor: the sentence is
    /// in the thread, nothing is owed, and no empty answer of Moe's is left.
    @Test func theConductorShowsItAndStopsWaiting() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("what's on my calendar", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        #expect(moe.isAwaitingReplyForTests)

        brain.emit(.error(HermesBrain.noAnswerNote))
        brain.emit(.turnFinished("", .failed))

        #expect(!moe.isAwaitingReplyForTests)
        #expect(moe.turns.contains { $0.role == .system && $0.text == HermesBrain.noAnswerNote })
        #expect(brain.sent.count == 1, "a failed turn must not be prodded to carry on")
        // And it is short enough to say whole.
        #expect(SpokenError.line(for: HermesBrain.noAnswerNote)
                == "I couldn't answer that. No answer came back. Ask me again.")
    }
}
