import Foundation
import Testing
import MoeChat
import MoeLedger
@testable import Moe

/// Background helpers the owner started on 2026-09-29 vanished three ways,
/// each driven here through the real Conductor:
///
/// 1. Seven helpers finished at 16:30 and their result sat in the inbox all
///    day behind an unanswered nudge on the island — every inbox file waited
///    for `pendingNudge == nil`.
/// 2. At 20:33 a sign-in to another Claude account rebuilt the brain, which
///    cleared the chat and started a new brain on a random session: the next
///    question went to a conversation that had never started any helpers.
/// 3. A result names no conversation, so it could only ever be answered in
///    whichever one happened to be on screen.
@MainActor
@Suite(.serialized)
struct HelpersSurviveTests {

    // MARK: - The inbox

    /// A result file, as moe-screen's completions.py writes one.
    @discardableResult
    static func writeResult(_ text: String, session: String? = nil, at: Date = Date()) throws -> URL {
        let dir = ReminderChannels.inbox
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var body: [String: Any] = ["text": text, "at": at.timeIntervalSince1970, "source": "helper",
                                   "job": "", "chat_id": "screen", "said": "", "job_id": "",
                                   "loops": [String](), "kind": "turn"]
        if let session { body["session_id"] = session }
        let url = dir.appendingPathComponent("\(Int(at.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    static func writeReminder(_ text: String) throws -> URL {
        let dir = ReminderChannels.inbox
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body: [String: Any] = ["text": text, "at": Date().timeIntervalSince1970, "source": "cron",
                                   "job": "reminder", "chat_id": "screen", "said": "", "job_id": "",
                                   "loops": [String]()]
        let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    /// The measured case: a nudge unanswered on the island, a helper result
    /// and a reminder behind it. The result runs; the nudge stays where it
    /// was; the reminder still waits its turn on the island.
    @Test func aFinishedHelperIsNotStarvedByANudge() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.queueReminder("Marketing brief, Tue 09-29", origin: .init(moment: true))
        let result = try Self.writeResult("[ASYNC DELEGATION BATCH COMPLETE — deleg_t1] seven drafts written")
        let reminder = try Self.writeReminder("Water the plants \(UUID().uuidString.prefix(6))")
        defer {
            try? FileManager.default.removeItem(at: result)
            try? FileManager.default.removeItem(at: reminder)
        }
        moe.drainInbox()
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.text.contains("seven drafts written") == true,
                "the helper's result was not run while a nudge was waiting")
        #expect(!FileManager.default.fileExists(atPath: result.path), "the result file is still waiting")
        // Both wait in the inbox now (docs/INBOX.md), neither behind the other.
        #expect(moe.notices.contains { $0.body == "Marketing brief, Tue 09-29" && $0.status == .open },
                "the item in the inbox was lost")
        #expect(moe.notices.contains { $0.body.hasPrefix("Water the plants") && $0.status == .open },
                "the reminder did not reach the inbox")
    }

    /// Two results: the older is answered first.
    @Test func resultsRunOldestFirst() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        let newer = try Self.writeResult("newer result", at: Date().addingTimeInterval(-60))
        let older = try Self.writeResult("older result", at: Date().addingTimeInterval(-600))
        defer {
            try? FileManager.default.removeItem(at: newer)
            try? FileManager.default.removeItem(at: older)
        }
        moe.drainInbox()
        try await brain.waitForSends(1)
        #expect(brain.sent[0].text.contains("older result"))
        #expect(FileManager.default.fileExists(atPath: newer.path), "one turn at a time")
    }

    /// A result from the conversation on screen is answered in it.
    @Test func aResultForThisConversationIsAnsweredHere() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        let session = BrainSession.id(thread: moe.currentConversationID, brain: brain.brainFingerprint)
        let url = try Self.writeResult("posted 16 replies", session: session)
        defer { try? FileManager.default.removeItem(at: url) }
        moe.drainInbox()
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.text.contains("posted 16 replies") == true)
    }

    /// A result from another saved conversation is not answered in this one:
    /// Moe says which conversation it belongs to and offers it in the inbox;
    /// Open it opens that conversation and the result is answered there.
    @Test func aResultForAnotherConversationIsOfferedThenAnsweredThere() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("research the seven competitors", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Started seven helpers.", end: .answered)
        moe.saveConversation(flush: true)
        let started = moe.currentConversationID
        moe.newConversation()
        let elsewhere = moe.currentConversationID
        #expect(started != elsewhere)

        let url = try Self.writeResult("seven competitor briefs written",
                                       session: BrainSession.id(thread: started, brain: brain.brainFingerprint))
        defer { try? FileManager.default.removeItem(at: url) }
        let before = brain.sent.count
        moe.drainInbox()
        moe.drainInbox()   // announced once, not every pass
        #expect(brain.sent.count == before, "answered in a conversation that never started it")
        #expect(FileManager.default.fileExists(atPath: url.path), "the result must wait for its conversation")
        let said = moe.turns.filter { $0.role == .system && $0.text.contains("handed off in") }
        #expect(said.count == 1, "the chat should say, once, which conversation it belongs to")
        // Offered in the inbox (docs/INBOX.md), once, with "Open it".
        let offers = moe.notices.filter { $0.openThread == started && $0.status == .open }
        #expect(offers.count == 1, "the inbox should offer that conversation, once")
        let offer = try #require(offers.first)

        moe.openNoticeThread(offer.id)
        #expect(moe.currentConversationID == started, "Open it should open the conversation that started it")
        #expect(moe.notice(offer.id)?.status == .done)
        try await brain.waitForSends(before + 1)
        #expect(brain.sent.last?.text.contains("seven competitor briefs written") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - A sign-in keeps the conversation

    @Test func aSignInKeepsTheConversation() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("start seven helpers on the launch research", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Started seven helpers.", end: .answered)
        let thread = moe.currentConversationID
        let next = FakeBrain()
        moe.makeBrain = { _ in next }

        moe.restartBrain()   // what every sign-in calls

        #expect(moe.currentConversationID == thread, "the sign-in moved to another conversation")
        #expect(moe.turns.contains { $0.text == "Started seven helpers." }, "the sign-in cleared the chat")
        for _ in 0..<300 where next.resumed.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let resume = try #require(next.resumed.first, "the new brain was never resumed on the conversation")
        #expect(resume.threadID == thread)
        #expect(resume.sessionID == BrainSession.id(thread: thread, brain: next.brainFingerprint),
                "the new brain must carry on the thread's own session")
    }
}
