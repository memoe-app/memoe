import Foundation
import Testing
import MoeVoice
import MoeMeeting
@testable import Moe

/// Who started each turn the Conductor sends, driven through the real
/// Conductor: every path below is the one the app takes (the voice engine's
/// own callbacks, the nudge buttons, a brain restart, a relaunch pickup, a
/// meeting ending), and the stand-in brain records the `TurnStarter` each
/// send carried. `HermesBrain` turns that into `X-Hermes-Turn-Origin`;
/// scripts/test-turn-origin.sh proves that half against a fake gateway.
///
/// Why it matters: Hermes lets its Chrome lane act in the person's own
/// Chrome only on a `.person` turn. A background send marked `.person` is a
/// transcript, a subagent's result or a note written half an hour after a
/// crash, opening tabs in front of whoever is — or is not — at the Mac.
@MainActor
@Suite(.serialized)
struct TurnStarterConductorTests {

    // MARK: - The person

    @Test func typedIsThePerson() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("what's on my calendar", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.starter == .person)
    }

    @Test func spokenAndItsContinuationAreThePerson() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.voice.onUtterance?("what's on my calendar")
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.starter == .person, "a spoken turn")
        brain.reply("You have two meetings.", end: .answered)
        moe.voice.onContinuation?("and tomorrow")
        try await brain.waitForSends(2)
        #expect(brain.sent.last?.starter == .person, "the person's own voice continuation")
    }

    @Test func answeringANudgeIsThePerson() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.queueReminder("Call the dentist before five.", origin: .init(moment: true))
        let item = try #require(moe.notices.first)
        moe.replyToNotice(item.id, text: "done already")
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.starter == .person)
    }

    // MARK: - Moe on its own

    /// The continuation's text says "not from the person:" — which the old
    /// text check ("not from the user.") missed, so it went out as the person.
    @Test func theStallGuardContinuationIsBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply(StallGuardConductorTests.promise, end: .answered)
        try await brain.waitForSends(2)
        #expect(brain.sent[0].starter == .person)
        #expect(brain.sent[1].text.hasPrefix("(Background note, not from the person"))
        #expect(brain.sent[1].starter == .background, "the stall guard went out as the person")
    }

    @Test func aHandedOffResultIsBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.reportFinishedHelper("Booked nothing. Cheapest: VietJet $142 — https://example.com/book")
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.starter == .background)
        #expect(brain.sent.last?.silent == false, "still spoken to the person")
    }

    @Test func playingAndDismissingANudgeAreBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.queueReminder("Call the dentist before five.", origin: .init(moment: true))
        let first = try #require(moe.notices.first)
        moe.playNotice(first.id)
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.starter == .background, "play")
        // Done on a follow-up tells the brain to close it: Moe's own note.
        moe.queueReminder("Did the deck go to Sam?",
                          handle: .init(job: "moe-proactive", jobID: "", loops: ["deck-for-sam"], said: ""))
        let followUp = try #require(moe.notices.first { $0.loops == ["deck-for-sam"] })
        moe.finishNotice(followUp.id)
        try await brain.waitForSends(2)
        #expect(brain.sent.last?.starter == .background, "done")
    }

    @Test func meetingNotesAreBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        brain.emit(.ready(sessionID: "s", tools: [], mcpServers: []))
        let record = MeetingRecord(startedAt: Date(), durationSeconds: 60, folder: "/tmp/meeting",
                                   notes: nil)
        moe.rememberMeeting(at: URL(fileURLWithPath: "/tmp/meeting"), record: record)
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.text.contains("sat in on a meeting") == true)
        #expect(brain.sent.last?.starter == .background)
    }

    /// The brain died and came back: the conversation is replayed to it.
    @Test func theRestoreAfterARestartIsBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("what's on my calendar", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("You have two meetings.", end: .answered)
        brain.emit(.exited(code: 1))   // first restart waits 1 s, then restores
        for _ in 0..<300 where brain.sent.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(brain.sent.count >= 2, "no restore was sent after the restart")
        #expect(brain.sent.last?.silent == true)
        #expect(brain.sent.last?.starter == .background)
    }

    /// Moe was quit mid-turn; the next launch picks the ask up — up to half
    /// an hour later, with nobody necessarily at the Mac.
    @Test func aTurnPickedUpAfterARelaunchIsBackground() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("find me a cheap backpack", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("On it.", end: .answered)
        moe.saveConversation(flush: true)
        let thread = moe.currentConversationID
        TurnKeeper.write(TurnKeeper.Record(text: "find me a cheap backpack", logAs: nil, startedAt: Date(),
                                           sessionID: "old", thread: thread))
        defer { TurnKeeper.clear() }
        let before = brain.sent.count
        brain.emit(.ready(sessionID: "s", tools: [], mcpServers: []))
        try await brain.waitForSends(before + 1)
        let pickup = try #require(brain.sent.last)
        #expect(pickup.text.contains("find me a cheap backpack"))
        #expect(pickup.starter == .background)
    }
}
