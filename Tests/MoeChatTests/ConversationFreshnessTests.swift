import Foundation
import Testing
@testable import MoeChat

/// Putting a conversation away after an hour untouched, so the next question
/// does not re-send a week of thread (162k tokens, 12 s to a first word).
struct ConversationFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func situation(idle: TimeInterval?, busy: Bool = false, watched: Bool = false)
        -> ConversationFreshness.Situation {
        .init(lastActivity: idle.map { now.addingTimeInterval(-$0) }, now: now,
              busy: busy, watched: watched)
    }

    @Test func anHourUntouchedStartsFresh() {
        #expect(ConversationFreshness.shouldStartFresh(situation(idle: 60 * 60)))
        #expect(ConversationFreshness.shouldStartFresh(situation(idle: 9 * 60 * 60)))
    }

    @Test func lessThanAnHourKeepsTheThread() {
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: 59 * 60)))
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: 0)))
    }

    /// An empty conversation has nothing to put away.
    @Test func anEmptyConversationIsLeftAlone() {
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: nil)))
    }

    /// A reply still coming, a meeting, dictation: never under work.
    @Test func neverWhileSomethingIsGoingOn() {
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: 5 * 60 * 60, busy: true)))
    }

    /// The person reading the thread must not watch it vanish.
    @Test func neverWhileThePersonIsLookingAtIt() {
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: 5 * 60 * 60, watched: true)))
    }

    /// A clock set back (or a turn stamped in the future) is not "idle".
    @Test func aLastActivityInTheFutureIsNotIdle() {
        #expect(!ConversationFreshness.shouldStartFresh(situation(idle: -60 * 60)))
    }
}
