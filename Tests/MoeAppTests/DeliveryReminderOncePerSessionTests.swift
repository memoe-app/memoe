import Foundation
import Testing
@testable import Moe

/// The delivery reminder is 3,401 characters and stays in the transcript.
/// It rode on every message, so a forty-turn conversation carried forty
/// copies of it. It is sent in full once per brain session and as the short
/// form after; a session the model has not read it in gets the full one.
@MainActor
@Suite(.serialized)
struct DeliveryReminderOncePerSessionTests {

    /// A line only the full reminder has, and one only the short one has.
    static let onlyInFull = "Pace it like someone talking, not like a progress bar."
    static let onlyInShort = "earlier in this conversation still holds"

    // MARK: - The rule

    @Test func fullOnceThenShortThenFullAgainInANewSession() {
        var ledger = BrainPrompt.DeliveryReminderLedger()
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminder)
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminderShort)
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminderShort)
        #expect(ledger.reminder(for: "b") == BrainPrompt.deliveryReminder)
        #expect(ledger.reminder(for: "b") == BrainPrompt.deliveryReminderShort)
        // Back in a session it left: told again, never assumed.
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminder)
    }

    /// A long session is compacted by the agent runtime, and a summary need
    /// not keep the rules the short form points back at. Nothing tells Moe
    /// when that happens, so the full one is sent again on a count: message
    /// 1, 21, 41 … — never more than twenty messages back.
    @Test func theFullOneIsSentAgainEveryTwentyMessages() {
        #expect(BrainPrompt.DeliveryReminderLedger.refreshEvery == 20)
        var ledger = BrainPrompt.DeliveryReminderLedger()
        var fullAt: [Int] = []
        for n in 1...61 where ledger.reminder(for: "a") == BrainPrompt.deliveryReminder { fullAt.append(n) }
        #expect(fullAt == [1, 21, 41, 61])
    }

    /// The count belongs to the session: a new one starts it over, so the
    /// refresh never lands early or late because of what another session read.
    @Test func theCountStartsOverWithTheSession() {
        var ledger = BrainPrompt.DeliveryReminderLedger()
        for _ in 1...15 { _ = ledger.reminder(for: "a") }
        #expect(ledger.reminder(for: "b") == BrainPrompt.deliveryReminder)
        for n in 2...20 {
            #expect(ledger.reminder(for: "b") == BrainPrompt.deliveryReminderShort, "message \(n) of the new session")
        }
        #expect(ledger.reminder(for: "b") == BrainPrompt.deliveryReminder)
    }

    /// What the refresh costs, from the measured sizes — the number the
    /// choice of twenty rests on. Forty messages: 2 full + 38 short.
    @Test func theRefreshCostsUnderATenthOverOncePerSession() {
        let full = BrainPrompt.deliveryReminder.count, short = BrainPrompt.deliveryReminderShort.count
        var ledger = BrainPrompt.DeliveryReminderLedger()
        let carried = (1...40).reduce(0) { sum, _ in sum + ledger.reminder(for: "a").count }
        let once = full + 39 * short, always = 40 * full
        print("delivery reminder over 40 messages: \(carried) characters with the refresh, "
              + "\(once) once per session, \(always) on every message")
        #expect(carried == 2 * full + 38 * short)
        #expect(Double(carried) < Double(once) * 1.10)
        #expect(carried * 3 < always)
    }

    /// A brain that names no session cannot be known to have read anything.
    @Test func aBrainWithNoSessionGetsTheFullOneEveryTime() {
        var ledger = BrainPrompt.DeliveryReminderLedger()
        for _ in 0..<3 { #expect(ledger.reminder(for: "") == BrainPrompt.deliveryReminder) }
        // And an unnamed turn does not make a named session look told.
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminder)
        _ = ledger.reminder(for: "")
        #expect(ledger.reminder(for: "a") == BrainPrompt.deliveryReminder)
    }

    // MARK: - The two texts

    /// The full text is what it was: measured, so a change to it is a choice.
    @Test func theFullReminderIsUnchangedAndTheShortOneIsAFifthOfIt() {
        #expect(BrainPrompt.deliveryReminder.count == 3401)
        print("delivery reminder: full \(BrainPrompt.deliveryReminder.count) characters / \(BrainPrompt.deliveryReminder.utf8.count) bytes, "
              + "short \(BrainPrompt.deliveryReminderShort.count) characters / \(BrainPrompt.deliveryReminderShort.utf8.count) bytes")
        #expect(BrainPrompt.deliveryReminderShort.count < 800)
        #expect(BrainPrompt.deliveryReminderShort.split(separator: "\n", omittingEmptySubsequences: true).count == 3,
                "a heading and two lines")
    }

    /// What the short one may not lose: the clock rule (ticket #9), the
    /// typed marker's name, the end marker — and the heading, which
    /// moe_items.py, the moe-screen sweep and claimstore cut a message at to
    /// find the person's own words.
    @Test func theShortReminderKeepsWhatOthersReadItFor() {
        let short = BrainPrompt.deliveryReminderShort
        #expect(short.hasPrefix("# Before you answer\n"))
        #expect(short.contains(BrainPrompt.nowRule))
        #expect(short.contains("(Typed, not spoken: …)"))
        #expect(short.contains("<end/>"))
        #expect(short.contains(Self.onlyInShort))
        #expect(!short.contains(Self.onlyInFull))
        #expect(BrainPrompt.deliveryReminder.contains(Self.onlyInFull))
        #expect(!BrainPrompt.deliveryReminder.contains(Self.onlyInShort))
    }

    // MARK: - Through the real Conductor

    /// What the brain is actually sent: turn one of a session carries the
    /// full reminder, turns two and three the short one, and the first turn
    /// after the session rotates carries the full one again.
    @Test func theConductorSendsItInFullOncePerSession() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        brain.sessionID = "session-one"

        func ask(_ words: String, expecting n: Int) async throws -> String {
            moe.submit(words, origin: .typed, starter: .person)
            try await brain.waitForSends(n)
            let text = try #require(brain.sent.last?.text)
            #expect(text.contains(words))
            brain.reply("Four.", end: .answered)
            return text
        }

        let first = try await ask("what is two and two", expecting: 1)
        #expect(first.contains(BrainPrompt.deliveryReminder))

        for (n, words) in [(2, "and three and three"), (3, "and four and four")] {
            let later = try await ask(words, expecting: n)
            #expect(later.contains(BrainPrompt.deliveryReminderShort))
            #expect(!later.contains(Self.onlyInFull), "turn \(n) of one session carried the full reminder again")
            #expect(later.count < first.count - 2500)
        }

        brain.sessionID = "session-two"
        let rotated = try await ask("and five and five", expecting: 4)
        #expect(rotated.contains(BrainPrompt.deliveryReminder), "a new session was not told the rules")
    }
}
