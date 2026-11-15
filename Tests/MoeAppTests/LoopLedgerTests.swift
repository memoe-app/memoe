import Foundation
import Testing
@testable import Moe

/// Done on something the background pass raised goes to moe-screen's
/// ledger (`deliver.py loop done`), not to the brain as a request — the
/// request was never carried out (Miriam, 2026-09-29: pressed Done at
/// 18:42, `miriam-portfolio-cmd` never reached closed.json, raised again
/// the next morning). Driven through the real Conductor with a recording
/// ledger in place of the Python.
@MainActor
@Suite(.serialized)
struct LoopLedgerTests {
    final class Calls: @unchecked Sendable {
        var args: [[String]] = []
    }

    static func ledger(_ calls: Calls, reply: LoopLedger.Reply?) -> LoopLedger {
        LoopLedger { args in
            calls.args.append(args)
            return reply
        }
    }

    static func settle(_ until: () -> Bool) async {
        for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Captured from moe-screen's own `deliver.py loop done` at df94b458,
    /// run against a scratch home whose brief carries the Miriam Reminder
    /// (DoneMeansQuietUntilItChangesTest's fixture) — never a line made up
    /// to agree with this parser.
    static let capturedHeld = #"{"closed": [], "held": true, "anchor": "Reminders | Deal with Miriam's Portfolio Command access issue | due 9/24/26", "reminder": "Deal with Miriam's Portfolio Command access issue", "ok": true}"#
    /// The same, with nothing to close or hold: exit 1.
    static let capturedNothing = #"{"closed": [], "held": false, "anchor": "", "reminder": "", "ok": false}"#

    @Test func parsesTheOneLine() {
        let r = LoopLedger.parse(Data((Self.capturedHeld + "\n").utf8), exit: 0)
        #expect(r.ok && r.answered && r.held)
        #expect(r.closed.isEmpty)
        #expect(r.reminder == "Deal with Miriam's Portfolio Command access issue")
        let none = LoopLedger.parse(Data(Self.capturedNothing.utf8), exit: 1)
        #expect(none.answered && !none.ok && !none.held && !LoopLedger.unheard(none))
        #expect(LoopLedger.unheard(LoopLedger.parse(Data("usage: …".utf8), exit: 2)))
        #expect(LoopLedger.unheard(LoopLedger.parse(Data(), exit: 0)), "a silent old deliver.py")
    }

    @Test func doneHoldsTheLoopsAndTheWordsAndOffersTheReminder() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        var notes: [String] = []
        moe.dismissalNoteForTests = { notes.append($0) }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: LoopLedger.parse(Data(Self.capturedHeld.utf8), exit: 0))
        moe.queueReminder("Miriam's portfolio access is 5 days overdue now. Need to handle this.",
                          handle: .init(job: "moe-proactive", jobID: "024baf6a8bc5",
                                        loops: ["miriam-portfolio-cmd"], said: ""))
        let n = try #require(moe.notices.first { $0.loops == ["miriam-portfolio-cmd"] })
        moe.finishNotice(n.id, outcome: "Done")
        await Self.settle { moe.reminderTick != nil }

        #expect(calls.args.count == 1)
        let args = try #require(calls.args.first)
        #expect(Array(args.prefix(3)) == ["loop", "done", "miriam-portfolio-cmd"])
        #expect(args.dropFirst(3).first == "--text")
        #expect(args.last?.contains("Miriam") == true, "the words travel, so a slug-less nag can be held")
        #expect(moe.reminderTick == ReminderTick(noticeID: n.id,
                                                 title: "Deal with Miriam's Portfolio Command access issue"))
        #expect(notes.isEmpty, "the ledger did it; the brain is not asked as well")
        #expect(brain.sent.isEmpty)
        moe.dismissReminderTick()
        #expect(moe.reminderTick == nil)
    }

    @Test func aNagWithNoLoopIsStillHeldByItsWords() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        moe.dismissalNoteForTests = { _ in }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: LoopLedger.parse(Data(Self.capturedHeld.utf8), exit: 0))
        // Four of the seven Miriam raises carried loops [].
        moe.queueReminder("Miriam's Portfolio Command access issue is overdue since the 24th—six days now.",
                          handle: .init(job: "moe-proactive", jobID: "024baf6a8bc5", loops: [], said: ""))
        let n = try #require(moe.notices.first)
        moe.finishNotice(n.id, outcome: "Skipped")
        await Self.settle { !calls.args.isEmpty }
        let args = try #require(calls.args.first)
        #expect(Array(args.prefix(3)) == ["loop", "done", "--text"])
        #expect(moe.reminderTick == nil, "Skip is not done: nothing offered for Reminders")
    }

    @Test func anOlderDeliverFallsBackToTheBrain() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        var notes: [String] = []
        moe.dismissalNoteForTests = { notes.append($0) }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: .init(exit: 2))
        moe.queueReminder("Did the deck go to Sam?",
                          handle: .init(job: "moe-proactive", jobID: "", loops: ["deck-for-sam"], said: ""))
        let n = try #require(moe.notices.first { $0.loops == ["deck-for-sam"] })
        moe.finishNotice(n.id)
        await Self.settle { !notes.isEmpty }
        #expect(notes.first?.contains("deck-for-sam") == true)
    }

    @Test func nothingToDoIsNotAFailure() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        var notes: [String] = []
        moe.dismissalNoteForTests = { notes.append($0) }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: LoopLedger.parse(Data(Self.capturedNothing.utf8), exit: 1))
        moe.queueReminder("Did the deck go to Sam?",
                          handle: .init(job: "moe-proactive", jobID: "", loops: ["deck-for-sam", "Not A Slug!"], said: ""))
        let n = try #require(moe.notices.first { $0.loops.contains("deck-for-sam") })
        moe.finishNotice(n.id)
        await Self.settle { !calls.args.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(Array(calls.args.first?.prefix(4) ?? []) == ["loop", "done", "deck-for-sam", "--text"],
                "a name deliver.py would refuse is left out")
        #expect(notes.isEmpty, "exit 1 with its line is an answer, not a reason to ask the brain")
    }

    @Test func aSilentOldDeliverAlsoFallsBack() async throws {
        // The installed deliver.py of 2026-09-30 exits 0 with no output.
        let (moe, _) = try StallGuardConductorTests.make()
        var notes: [String] = []
        moe.dismissalNoteForTests = { notes.append($0) }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: LoopLedger.parse(Data(), exit: 0))
        moe.queueReminder("Did the deck go to Sam?",
                          handle: .init(job: "moe-proactive", jobID: "", loops: ["deck-for-sam"], said: ""))
        let n = try #require(moe.notices.first { $0.loops == ["deck-for-sam"] })
        moe.finishNotice(n.id)
        await Self.settle { !notes.isEmpty }
        #expect(notes.first?.contains("deck-for-sam") == true)
    }

    @Test func somethingThePassDidNotRaiseNeverTouchesTheLedger() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        moe.dismissalNoteForTests = { _ in }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: .init(exit: 0, answered: true, ok: true))
        moe.queueReminder("Call the dentist before five.", origin: .init(moment: true))
        let n = try #require(moe.notices.first)
        moe.finishNotice(n.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(calls.args.isEmpty)
    }

    @Test func snoozeMovesEachLoop() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        moe.dismissalNoteForTests = { _ in }
        let calls = Calls()
        moe.loopLedger = Self.ledger(calls, reply: .init(exit: 0, answered: true, ok: true, next: "2026-10-01T13:00:00Z"))
        moe.queueReminder("Andrew Wilson meeting tomorrow 3–4 PM on Teams.",
                          handle: .init(job: "moe-proactive", jobID: "", loops: ["andrew-wilson-meeting"], said: ""))
        let n = try #require(moe.notices.first)
        let until = Date(timeIntervalSince1970: 1_790_000_000)
        moe.snoozeNotice(n.id, until: until)
        await Self.settle { !calls.args.isEmpty }
        #expect(calls.args.first == ["loop", "snooze", "andrew-wilson-meeting",
                                     ISO8601DateFormatter().string(from: until)])
    }
}
