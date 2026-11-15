import Foundation
import Testing
@testable import MoeBrain

/// The brief rides on the person's message and stays in the transcript, so
/// what it sends is what every later turn re-reads. It went out whole
/// whenever its bytes changed — and `sync.sh` changes its bytes every ten
/// minutes by stamping the minute at the top. Measured over 1,325 turns:
/// 288 whole copies, 12–16 KB each, 16% of the history.
struct BriefLedgerTests {

    /// The shape `moe-home/sync.sh` writes (headings and the two stamps are
    /// its own; the lines are made up).
    static func brief(at stamp: String, calendar: String = "- 2:00–3:00 PM Project Atlas call — in 20 min",
                      inbound: String = "2026-11-12 11:40|Dani|are we still on for two?",
                      calls: String? = "- 11:02 AM missed, Dani", more: Bool = false) -> String {
        // `more`: a few lines either side, as a real brief has — one line
        // changing in a part of one line is a different part, sent whole.
        let tasks = more ? "- Send the Atlas quote\n- Book the dentist\n- Renew the passport" : "- Send the Atlas quote"
        let earlier = more && !inbound.contains("Sam|") ? "2026-11-12 11:52|Sam|invoice attached\n" : ""
        var s = """
        # Right now

        _Refreshed Thursday 12 November, \(stamp)._

        ## Calendar (next few days)

        _As of \(stamp) — the Now line on each message is the clock._

        \(calendar)

        ## Tasks

        \(tasks)

        ## Inbound (recent)

        ### messages

        \(earlier)\(inbound)

        """
        if let calls { s += "\n## Calls\n\n\(calls)\n" }
        return s
    }

    @Test func wholeTheFirstTimeThenNothingWhenOnlyTheStampsMoved() {
        var ledger = BriefLedger()
        let first = Self.brief(at: "11:54 AM")
        #expect(ledger.next(brief: first, session: "a") == .full(first))
        // Ten minutes on: sync.sh ran, nothing happened. This is the case that
        // used to send all of it again.
        #expect(ledger.next(brief: Self.brief(at: "12:04 PM"), session: "a") == .nothing)
        #expect(ledger.next(brief: Self.brief(at: "12:14 PM"), session: "a") == .nothing)
    }

    /// One new message is one new line under its own heading — not every
    /// message beside it, and not the calendar and the tasks as well.
    @Test func aNewMessageIsSentAsOneNewLine() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: Self.brief(at: "11:54 AM", more: true), session: "a")
        let later = Self.brief(at: "12:04 PM", inbound: """
        2026-11-12 11:40|Dani|are we still on for two?
        2026-11-12 11:52|Sam|invoice attached
        2026-11-12 12:01|Dani|running ten late
        """, more: true)
        #expect(ledger.next(brief: later, session: "a") == .update("""
        ## Inbound (recent)

        ### messages
        New:
        2026-11-12 12:01|Dani|running ten late
        """))
        // Told now: the same brief again says nothing.
        #expect(ledger.next(brief: later, session: "a") == .nothing)
    }

    /// A line that left is always said to have left: a finished task and a
    /// message that aged out look the same from here, and guessing which is
    /// which is how a done task stays on the list.
    @Test func aLineThatLeftIsNamed() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: Self.brief(at: "11:54 AM", more: true), session: "a")
        let later = Self.brief(at: "12:04 PM", more: true).replacingOccurrences(of: "- Send the Atlas quote\n", with: "")
        #expect(ledger.next(brief: later, session: "a") == .update("""
        ## Tasks
        No longer listed:
        - Send the Atlas quote
        """))
    }

    /// A part that is mostly different is sent whole — it replaces the copy
    /// the conversation had — and with the stamp its labels are relative to:
    /// a stale "in 20 min" is how a finished meeting gets called upcoming
    /// (ticket #9).
    @Test func aCalendarWhoseLabelMovedIsSentWholeWithItsOwnStamp() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: Self.brief(at: "11:54 AM"), session: "a")
        let later = Self.brief(at: "12:04 PM", calendar: "- 2:00–3:00 PM Project Atlas call — in 10 min")
        #expect(ledger.next(brief: later, session: "a") == .update("""
        ## Calendar (next few days)

        _As of 12:04 PM — the Now line on each message is the clock._

        - 2:00–3:00 PM Project Atlas call — in 10 min
        """))
    }

    @Test func aPartThatWentAwayIsNamed() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: Self.brief(at: "11:54 AM"), session: "a")
        #expect(ledger.next(brief: Self.brief(at: "12:04 PM", calls: nil), session: "a")
                == .update("_No longer in the brief: Calls._"))
    }

    @Test func aNewPartIsSentWhole() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: Self.brief(at: "11:54 AM", calls: nil), session: "a")
        #expect(ledger.next(brief: Self.brief(at: "12:04 PM"), session: "a")
                == .update("## Calls\n\n- 11:02 AM missed, Dani"))
    }

    /// The same lines in another order are the same brief.
    @Test func aReorderingIsNotAChange() {
        var ledger = BriefLedger()
        let a = "2026-11-12 11:40|Dani|one\n2026-11-12 11:52|Sam|two"
        let b = "2026-11-12 11:52|Sam|two\n2026-11-12 11:40|Dani|one"
        _ = ledger.next(brief: Self.brief(at: "11:54 AM", inbound: a), session: "a")
        #expect(ledger.next(brief: Self.brief(at: "12:04 PM", inbound: b), session: "a") == .nothing)
    }

    @Test func aSessionThatHasNotSeenItGetsAllOfIt() {
        var ledger = BriefLedger()
        let text = Self.brief(at: "11:54 AM")
        _ = ledger.next(brief: text, session: "a")
        #expect(ledger.next(brief: text, session: "b") == .full(text))
        // And back in the one it left: told again, never assumed.
        #expect(ledger.next(brief: text, session: "a") == .full(text))
    }

    /// An update leans on the whole brief still being in the transcript, and
    /// a long session's transcript is compacted without a word to Moe. So the
    /// whole brief goes again on message 21, 41, … even when nothing changed.
    @Test func theWholeBriefGoesAgainEveryTwentyMessages() {
        #expect(BriefLedger.refreshEvery == 20)
        var ledger = BriefLedger()
        let text = Self.brief(at: "11:54 AM")
        var fullAt: [Int] = []
        for n in 1...61 {
            if case .full = ledger.next(brief: text, session: "a") { fullAt.append(n) }
        }
        #expect(fullAt == [1, 21, 41, 61])
    }

    /// A brain with no session to name cannot be known to have kept anything:
    /// all of it whenever its words differ, as before — never an update.
    @Test func aBrainWithNoSessionNeverGetsAnUpdate() {
        var ledger = BriefLedger()
        let first = Self.brief(at: "11:54 AM")
        #expect(ledger.next(brief: first, session: "") == .full(first))
        #expect(ledger.next(brief: Self.brief(at: "12:04 PM"), session: "") == .nothing)
        let changed = Self.brief(at: "12:14 PM", calls: nil)
        #expect(ledger.next(brief: changed, session: "") == .full(changed))
        // And an unnamed turn does not make a named session look told.
        #expect(ledger.next(brief: changed, session: "a") == .full(changed))
    }

    /// A brief that was empty when the session started was never really told.
    @Test func afterAnEmptyBriefTheFirstRealOneIsWhole() {
        var ledger = BriefLedger()
        _ = ledger.next(brief: "\n", session: "a")
        let text = Self.brief(at: "11:54 AM")
        #expect(ledger.next(brief: text, session: "a") == .full(text))
    }

    /// What it saves, from this fixture's own sizes: an hour of one
    /// conversation, a sync every ten minutes, one new message in that hour.
    @Test func anHourOfSyncsCarriesAFractionOfWhatItDid() {
        var ledger = BriefLedger()
        var carried = 0, before = 0
        var last = ""
        for (n, stamp) in ["11:04 AM", "11:14 AM", "11:24 AM", "11:34 AM", "11:44 AM", "11:54 AM"].enumerated() {
            let text = n == 3
                ? Self.brief(at: stamp, inbound: "2026-11-12 11:30|Dani|running ten late")
                : (n > 3 ? Self.brief(at: stamp, inbound: "2026-11-12 11:30|Dani|running ten late") : Self.brief(at: stamp))
            if text != last { before += text.count; last = text }       // the old rule: whole, when the bytes differ
            switch ledger.next(brief: text, session: "a") {
            case .nothing: break
            case .full(let all): carried += all.count
            case .update(let some): carried += some.count
            }
        }
        print("brief over six syncs: \(carried) characters now, \(before) when sent whole on every change")
        #expect(carried * 3 < before)
    }
}
