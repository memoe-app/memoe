import Foundation
import MoeDesign
import MoeIsland
import Testing
@testable import Moe

/// docs/INBOX-QUIET.md slice 2: every card carries a do-it. The table is the
/// doc's own week (2026-09-29 → 10-06): what it called signal, what it called
/// noise, and the two exceptions it allows.
struct InboxGateTests {

    struct Row: CustomStringConvertible, Sendable {
        let what: String
        let input: NoticeInput
        var origin = InboxGate.Origin()
        let want: InboxGate.Verdict
        var description: String { what }
    }

    static func input(_ text: String, _ change: (inout NoticeInput) -> Void = { _ in }) -> NoticeInput {
        var i = NoticeInput(text: text, at: Date(timeIntervalSince1970: 1_760_000_000))
        change(&i)
        return i
    }

    static let table: [Row] = [
        // The doc's model card: the work is prepared, one tap sends it.
        Row(what: "the insurer card: an offer with a draft behind it",
            input: input("$17,850 offer is $7,108 under valuation. A demand letter is ready to review and a draft objection to send.") {
                $0.offer = "sit_insurer"; $0.job = "moe-situations"
            }, want: .card(.preparedWork)),
        Row(what: "a failed routine of theirs, with Show me / Run it again",
            input: input("Your morning brief did not run today.") {
                $0.options = ["Show me", "Run it again"]; $0.instruction = "rerun job 7"; $0.job = "moe-routine-failures"
            }, want: .card(.answers)),
        Row(what: "a send held for their yes",
            input: input("Waiting on you: a scheduled job wants to send Dana the invoice.") {
                $0.expiredText = "That send expired — nothing was sent."
            }, want: .card(.heldSend)),
        Row(what: "a job they handed off has finished: Open it",
            input: input("Something you handed off in “Hanoi flights” has finished. Open it to hear how it went.") {
                $0.openThread = "thread-1"
            }, want: .card(.openIt)),
        Row(what: "a connection that one step would carry to their cloud computer: Show me",
            input: input("WhatsApp is not on your cloud computer yet.") { $0.awayCarry = "whatsapp" },
            want: .card(.showMe)),
        Row(what: "what their cloud computer held for this Mac while it was shut",
            input: input("The export you asked me to watch finished at 3 AM."),
            origin: .init(writer: "away"), want: .card(.reachedFor)),
        Row(what: "but a Moe job's own report is that job's, wherever it was held",
            input: input("I learned 22 things about you this week.") { $0.job = "moe-weekly-digest" },
            origin: .init(writer: "away"), want: .quiet(.moeAboutMoe)),
        Row(what: "a follow-up Moe is keeping: Done closes it",
            input: input("Did the deck go to Sam?") { $0.loops = ["deck-to-sam"]; $0.job = "moe-proactive" },
            want: .card(.followUp)),
        Row(what: "a reminder they set themselves",
            input: input("Call the dentist before 5.") { $0.job = "dentist"; $0.jobID = "a1b2" },
            want: .card(.askedFor)),
        // Slice 3 sorts worker routines from telling ones; until then a
        // routine the person made is theirs, and is shown.
        Row(what: "their own marketing routine handing work back ('post by hand')",
            input: input("Reply draft ready. Post by hand, then edit TOPICS.md.") { $0.job = "marketing-brief"; $0.jobID = "c3" },
            want: .card(.askedFor)),
        Row(what: "the brain reaching for them on purpose",
            input: input("The export you asked me to watch has finished."),
            origin: .init(writer: "reach_owner"), want: .card(.reachedFor)),
        // Decision 1's exception: a pure FYI only when time-critical.
        Row(what: "a scam in progress, flagged time-critical",
            input: input("The 'bank' texting you is the scam going round Israel this week. Do not tap the link.") { $0.job = "moe-situations" },
            origin: .init(writer: "cron", timeCritical: true), want: .card(.timeCritical)),
        Row(what: "a booking cancelled for tomorrow, flagged time-critical",
            input: input("Your host cancelled tomorrow's stay in Hanoi."),
            origin: .init(timeCritical: true), want: .card(.timeCritical)),
        Row(what: "the same booking news with no flag: an FYI",
            input: input("Your host cancelled tomorrow's stay in Hanoi."),
            want: .quiet(.nothingToTap)),
        // Decision 7: moments are the island's; still shown until it has them.
        Row(what: "a meeting-soon nudge from nudge.json",
            input: input("Andrew Wilson in 10 minutes."), origin: .init(moment: true), want: .card(.moment)),
        Row(what: "the calendar heads-up, by its job",
            input: input("Andrew Wilson meeting tomorrow 3–4 PM on Teams.") { $0.job = "moe-calendar-heads-up" },
            origin: .init(writer: "cron"), want: .card(.moment)),
        Row(what: "a send held for their yes expired: nothing was sent, and they may be counting on it",
            input: input("That send to Dana expired — nothing was sent."),
            origin: .init(consequence: true), want: .card(.consequence)),
        // Decision 3: Moe about Moe is never a card.
        // As `moe-weekly-digest.py` really sends it: with a note for the
        // brain, which is not something to tap.
        Row(what: "'I learned 22 things about you'",
            input: input("I learned 22 things about you this week.") {
                $0.job = "moe-weekly-digest"; $0.instruction = "This was the weekly digest of what was learned."
            },
            origin: .init(writer: "digest"), want: .quiet(.moeAboutMoe)),
        Row(what: "'nothing new' from one of Moe's own jobs",
            input: input("Nothing new since this morning. 4 duplicate memories tidied.") { $0.job = "moe-memory-tidy"; $0.jobID = "t1" },
            origin: .init(writer: "cron"), want: .quiet(.moeAboutMoe)),
        // Measured, 2026-09-30: the pass named no loop, and Done still
        // closes it in the ledger by its words.
        Row(what: "the background pass's follow-up that named no loop",
            input: input("Miriam's Portfolio Command access issue is overdue since the 24th—six days now.") {
                $0.job = "moe-proactive"; $0.jobID = "024baf6a8bc5"
            }, origin: .init(writer: "cron"), want: .card(.followUp)),
        // The app cannot tell whose it is, so it is not hidden.
        Row(what: "a scheduler delivery that names no job (it may be their reminder)",
            input: input("Water the plants."), origin: .init(writer: "cron"), want: .card(.unattributed)),
        Row(what: "a job id the scheduler could not put a name to",
            input: input("Water the plants.") { $0.jobID = "9f3" }, origin: .init(writer: "cron"), want: .card(.askedFor)),
        Row(what: "an intents summary with nowhere else to go",
            input: input("3 things queued while you were away were handled.") { $0.job = "moe-drain-intents" },
            origin: .init(writer: "moe-drain-intents"), want: .quiet(.moeAboutMoe)),
        Row(what: "a withdrawn send, as its card's note",
            input: input("That WhatsApp send to “Dana” was withdrawn because the task that asked for it stopped — nothing was sent."),
            origin: .init(writer: ConfirmLifecycle.noteSource), want: .quiet(.moeAboutMoe)),
        Row(what: "a ticket that is fixed: nothing for them to do",
            input: input("Ticket #12 is fixed: sending from Gmail works again. Nothing for you to do.") { $0.job = "moe-tickets" },
            want: .quiet(.moeAboutMoe)),
        Row(what: "a missed call as a bare number, from nobody in particular",
            input: input("Missed call from +1 555 0100."), want: .quiet(.nothingToTap)),
        Row(what: "a question with nothing to tap is still nothing to tap",
            input: input("How often should I check r/mac?") { $0.kind = "question"; $0.job = "moe-learn-deep" },
            want: .quiet(.moeAboutMoe)),
        Row(what: "a note for the brain is not a button for the person",
            input: input("Your cloud computer is set up and running.") { $0.instruction = "Say it is running." },
            want: .quiet(.nothingToTap)),
    ]

    @Test(arguments: table)
    func theBar(_ row: Row) {
        #expect(InboxGate.decide(row.input, origin: row.origin) == row.want, "\(row.what)")
    }

    /// A time-critical flag never rescues a card's own withdrawal note.
    @Test func aWithdrawalNoteIsQuietEvenWhenFlagged() {
        var origin = InboxGate.Origin(writer: ConfirmLifecycle.noteSource)
        origin.timeCritical = true
        #expect(InboxGate.decide(Self.input("That send expired before you answered — nothing was sent."),
                                 origin: origin) == .quiet(.moeAboutMoe))
    }

    // MARK: Kept, not destroyed

    @Test func whatFailsTheBarIsKeptUnderDoneAndRead() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_500)
        let i = Self.input("Ticket #12 is fixed: sending from Gmail works again.") { $0.job = "moe-tickets" }
        let kept = try #require(InboxGate.kept(i, among: [], now: now))
        #expect(kept.status == .done)
        #expect(kept.outcome == InboxGate.outcome)
        #expect(kept.doneAt == now)
        #expect(kept.seen, "a quiet notice must not make the notch glow")
        #expect(kept.body == i.text, "every word is kept")
        #expect(!kept.isWaiting(now: now) && !kept.onIsland(now: now))
    }

    @Test func theSameQuietWordsAreKeptOnce() throws {
        let i = Self.input("Nothing new since this morning.") { $0.job = "moe-memory-tidy" }
        let first = try #require(InboxGate.kept(i, among: []))
        #expect(InboxGate.kept(i, among: [first]) == nil)
        // The same words on an open card are a different thing: still kept.
        var open = NoticeMaker.make(i)
        open.status = .open
        #expect(InboxGate.kept(i, among: [open]) != nil)
    }

    // MARK: The file's two new keys

    @Test func theInboxFileCarriesItsWriterAndItsFlag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-gate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ body: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: body).write(to: dir.appendingPathComponent(name))
        }
        try write("1-a.json", ["text": "The export finished.", "at": 10.0, "source": "reach_owner"])
        try write("2-b.json", ["text": "Do not tap that link.", "at": 11.0, "source": "cron", "time_critical": true])
        // "true" as a string, or 1, is not the flag: only a real JSON true.
        try write("3-c.json", ["text": "Hello.", "at": 12.0, "time_critical": "true"])
        try write("4-d.json", ["text": "Hello again.", "at": 13.0, "time_critical": 1])
        let got = ReminderChannels.pending(in: dir, remembering: ReminderChannels.Unreadable())
        #expect(got.map(\.writer) == ["reach_owner", "cron", "", ""])
        #expect(got.map(\.timeCritical) == [false, true, false, false])
    }

    // MARK: Through the real Conductor

    @MainActor
    @Test func aNoticeWithNothingToTapNeverReachesTheIsland() throws {
        let moe = try InboxQuietConductorTests.make()
        let t = InboxQuietConductorTests.tag()
        let waiting = moe.waitingNotices.count
        moe.receiveNotice(Self.input("I learned 22 things about you this week \(t).") { $0.job = "moe-weekly-digest" })
        let n = try #require(moe.notices.first { $0.body.contains(t) }, "it must be kept, not destroyed")
        #expect(n.status == .done)
        #expect(n.outcome == InboxGate.outcome)
        #expect(moe.waitingNotices.count == waiting)
        #expect(!moe.islandNotices.contains { $0.id == n.id })
        #expect(moe.noticePeek?.id != n.id, "nothing is said under the notch")
        // Said again, it is still one row.
        moe.receiveNotice(Self.input("I learned 22 things about you this week \(t).") { $0.job = "moe-weekly-digest" })
        #expect(moe.notices.filter { $0.body.contains(t) }.count == 1)
    }

    @MainActor
    @Test func aNoticeWithADoItStillArrives() throws {
        let moe = try InboxQuietConductorTests.make()
        let t = InboxQuietConductorTests.tag()
        moe.receiveNotice(Self.input("Pick one \(t).") { $0.options = ["Yes", "No"]; $0.job = "moe-proactive" })
        let n = try #require(moe.notices.first { $0.body.contains(t) })
        #expect(n.status == .open)
        #expect(moe.islandNotices.contains { $0.id == n.id })
    }

    @MainActor
    @Test func anInboxFileIsJudgedByItsWriter() throws {
        let moe = try InboxQuietConductorTests.make()
        let t = InboxQuietConductorTests.tag()
        func message(_ text: String, writer: String, flagged: Bool = false) -> ReminderChannels.Message {
            var m = ReminderChannels.Message(url: URL(fileURLWithPath: "/dev/null"), text: text, job: "", jobID: "",
                                             loops: [], said: "", at: Date())
            m.writer = writer
            m.timeCritical = flagged
            return m
        }
        moe.receive(message("The export finished \(t)-reach.", writer: "reach_owner"))
        moe.receive(message("That send was withdrawn \(t)-confirm — nothing was sent.", writer: ConfirmLifecycle.noteSource))
        moe.receive(message("Do not tap that link \(t)-flag.", writer: "cron", flagged: true))
        moe.receive(message("Just so you know \(t)-fyi.", writer: "digest"))
        func status(_ tag: String) -> InboxItem.Status? { moe.notices.first { $0.body.contains("\(t)-\(tag)") }?.status }
        #expect(status("reach") == .open)
        #expect(status("confirm") == .done)
        #expect(status("flag") == .open)
        #expect(status("fyi") == .done)
    }
}

extension Conductor {
    /// For a test that is about something other than the bar: the notice is
    /// let in as a time-critical one, which is the last thing the bar asks
    /// about, so an offer or a follow-up is still let in as what it is.
    func arrive(_ input: NoticeInput) {
        receiveNotice(input, origin: InboxGate.Origin(timeCritical: true))
    }
}
