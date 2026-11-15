import Foundation
import MoeIsland
import Testing
@testable import Moe

/// Inbox slice 1 (docs/INBOX-QUIET.md) through the real Conductor: ✕
/// finishes, one card per subject, cards closed by their source, Done is not
/// "not wanted", bulk archive, and the one-time archive of the backlog.
@MainActor
@Suite(.serialized)
struct InboxQuietConductorTests {

    static func make() throws -> Conductor {
        // The learner's file is shared with OfferConductorTests, which may run
        // beside this suite: it is never deleted here, only read for this
        // test's own situation ids.
        let (moe, _) = try StallGuardConductorTests.make()
        return moe
    }

    static func tag() -> String { String(UUID().uuidString.prefix(6)).lowercased() }

    static func input(_ text: String, at: Date = Date(), offer: String = "", loops: [String] = [],
                      job: String = "", kind: String = "", subject: String = "") -> NoticeInput {
        var i = NoticeInput(text: text, at: at)
        i.offer = offer
        i.loops = loops
        i.job = job
        i.kind = kind
        i.subject = subject
        return i
    }

    /// What the learner was told about this one situation, in order.
    static func feedback(_ sid: String) -> [String] {
        let text = (try? String(contentsOf: SituationOffer.feedbackURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["id"] as? String == sid else { return nil }
            return row["action"] as? String
        }
    }

    // MARK: ✕ finishes

    @Test func dismissFinishesTheCardAndItLeavesTheCount() throws {
        let moe = try Self.make()
        let t = Self.tag()
        moe.arrive(Self.input("Your dashboard still needs expense tracking \(t)."))
        let n = try #require(moe.notices.first { $0.body.contains(t) })
        let before = moe.waitingNotices.count
        moe.dismissNotice(n.id)
        #expect(moe.notice(n.id)?.status == .done)
        #expect(moe.notice(n.id)?.outcome == "Dismissed")
        #expect(moe.waitingNotices.count == before - 1, "✕ used to only hide it; the Inbox count kept it")
        #expect(!moe.islandNotices.contains { $0.id == n.id })
    }

    @Test func dismissOnAnOfferDeclinesItAsNotNow() throws {
        let moe = try Self.make()
        let sid = "sit_\(Self.tag())"
        moe.arrive(Self.input("A reply is ready.", offer: sid))
        let n = try #require(moe.notices.first { $0.offer == sid })
        moe.dismissNotice(n.id)
        #expect(moe.notice(n.id)?.status == .done)
        #expect(Self.feedback(sid) == ["not-now"])
    }

    // MARK: Done is not "not wanted"; Not this kind is reachable

    @Test func doneOnAnOfferIsHandledNotNotNow() throws {
        let moe = try Self.make()
        let sid = "sit_\(Self.tag())"
        moe.arrive(Self.input("A reply is ready.", offer: sid))
        let n = try #require(moe.notices.first { $0.offer == sid })
        moe.finishNotice(n.id, outcome: "Done")
        #expect(Self.feedback(sid) == ["handled"], "Done taught the learner the person did not want it")
    }

    @Test func notThisKindRecordsTheStrongestNo() throws {
        let moe = try Self.make()
        let sid = "sit_\(Self.tag())"
        moe.arrive(Self.input("A reply is ready.", offer: sid))
        let n = try #require(moe.notices.first { $0.offer == sid })
        moe.declineNotice(n.id, kind: true)
        #expect(Self.feedback(sid) == ["not-this-kind"])
        #expect(moe.notice(n.id)?.outcome == "Not this kind")
    }

    // MARK: One card per subject

    @Test func aNoticeAboutAnOpenSubjectUpdatesThatCard() throws {
        let moe = try Self.make()
        let sid = "sit_\(Self.tag())"
        moe.arrive(Self.input("Israel may be about to send more money.", at: Date().addingTimeInterval(-600), offer: sid))
        let first = try #require(moe.notices.first { $0.offer == sid })
        moe.dismissNotice(first.id)   // finished: the next one is a new card
        moe.arrive(Self.input("Israel is being pressured again.", offer: sid))
        let second = try #require(moe.notices.first { $0.offer == sid && $0.status == .open })
        #expect(second.id != first.id)
        moe.openInbox()
        moe.arrive(Self.input("Israel has lost $4,495 this month.", offer: sid))
        let open = moe.notices.filter { $0.subject == "situation:\(sid)" && $0.status == .open }
        #expect(open.count == 1)
        #expect(open.first?.id == second.id)
        #expect(open.first?.body == "Israel has lost $4,495 this month.")
        #expect(open.first?.seen == false, "raised back up, unread")

        // A loop card, by its slug; and the writer's own subject.
        let slug = "hanoi-\(Self.tag())"
        moe.arrive(Self.input("You need a hotel for Hanoi.", loops: [slug]))
        moe.arrive(Self.input("The host cancelled Hanoi.", loops: [slug, "other"]))
        #expect(moe.notices.filter { $0.subject == "loop:\(slug)" }.count == 1)
        let ev = "event:\(Self.tag())"
        moe.arrive(Self.input("Andrew at 3.", subject: ev))
        moe.arrive(Self.input("Andrew at 3 PM today, four items.", subject: ev))
        #expect(moe.notices.filter { $0.subject == ev }.count == 1)
    }

    @Test func anInboxFileCarriesItsSubjectThroughToTheCard() throws {
        let moe = try Self.make()
        let ev = "routine:\(Self.tag())"
        let url = URL(fileURLWithPath: "/dev/null")
        var m = ReminderChannels.Message(url: url, text: "Today's brief.", job: "x", jobID: "", loops: [],
                                         said: "", at: Date())
        m.subject = ev
        moe.receive(m)
        let m2 = ReminderChannels.Message(url: url, text: "Today's brief, again.", job: "x", jobID: "", loops: [],
                                      said: "", at: Date(), subject: ev)
        moe.receive(m2)
        #expect(moe.notices.filter { $0.subject == ev }.count == 1)
    }

    // MARK: Closed by their source

    @Test func cardsCloseWhenTheirSourceResolves() throws {
        let moe = try Self.make()
        let t = Self.tag()
        let old = Date().addingTimeInterval(-InboxLifecycle.grace - 60)
        moe.arrive(Self.input("Stale offer \(t).", at: old, offer: "sit_stale_\(t)"))
        moe.arrive(Self.input("Live offer \(t).", at: old, offer: "sit_live_\(t)"))
        moe.arrive(Self.input("Shlomo waits \(t).", at: old, loops: ["cash-\(t)"]))
        moe.arrive(Self.input("Eli waits \(t).", at: old, loops: ["eli-\(t)"]))
        moe.arrive(Self.input("Review \(t) starts in 9 minutes.", at: Date().addingTimeInterval(-10 * 60),
                                     job: InboxLifecycle.headsUpJob))
        let sources = InboxLifecycle.Sources(offerLive: { $0 == "sit_live_\(t)" },
                                             openLoops: ["eli-\(t)"])
        moe.closeResolvedNotices(sources: sources)
        func status(_ word: String) -> InboxItem.Status? { moe.notices.first { $0.body.hasPrefix(word) && $0.body.contains(t) }?.status }
        #expect(status("Stale offer") == .done)
        #expect(status("Live offer") == .open)
        #expect(status("Shlomo") == .done)
        #expect(status("Eli") == .open)
        #expect(status("Review") == .done)
    }

    /// What the sweep reads: SituationOffer.load over the situations file
    /// (resolved, dismissed, or offered over a day ago are all gone) and the
    /// ledger's `{"open": {slug: …}}`. Files that will not read close nothing.
    @Test func theSweepReadsTheSituationsFileAndTheLedger() throws {
        let fresh = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-25 * 3600))
        let json = """
        {"sit_ok": {"status": "offered", "offered": {"for": "v1", "at": "\(fresh)"}, "prepared": {"for": "v1", "offer": "x"}},
         "sit_done": {"status": "resolved", "offered": {"for": "v1", "at": "\(fresh)"}, "prepared": {"for": "v1"}},
         "sit_old": {"status": "offered", "offered": {"for": "v1", "at": "\(stale)"}, "prepared": {"for": "v1"}}}
        """
        let s = Conductor.liveSources(situations: Data(json.utf8), ledger: Data(#"{"open": {"eli": {}}}"#.utf8))
        #expect(s.offerLive("sit_ok") == true)
        #expect(s.offerLive("sit_done") == false)
        #expect(s.offerLive("sit_old") == false)
        #expect(s.offerLive("sit_missing") == false)
        #expect(s.openLoops == ["eli"])
        let blind = Conductor.liveSources(situations: nil, ledger: Data("[]".utf8))
        #expect(blind.offerLive("sit_ok") == nil)
        #expect(blind.openLoops == nil)
        #expect(Conductor.liveSources(situations: Data("garbage".utf8), ledger: nil).offerLive("x") == nil)
    }

    // MARK: Many at once

    @Test func markAllReadAndArchiveSelectedAndAll() throws {
        let moe = try Self.make()
        let t = Self.tag()
        for i in 0..<4 { moe.arrive(Self.input("Card \(i) \(t).")) }
        let mine = { moe.notices.filter { $0.body.contains(t) } }
        #expect(mine().allSatisfy { !$0.seen })
        moe.markAllNoticesRead()
        #expect(mine().allSatisfy { $0.seen && $0.status == .open })

        let two = mine().prefix(2).map(\.id)
        moe.archiveNotices(two)
        #expect(mine().filter { $0.status == .done }.map(\.id).sorted() == two.sorted())
        #expect(mine().filter { $0.status == .done }.allSatisfy { $0.outcome == "Archived" && $0.doneAt != nil })

        moe.archiveNotices(moe.notices.filter { $0.status == .open }.map(\.id))
        #expect(moe.notices.allSatisfy { $0.status == .done })
        #expect(moe.waitingNotices.isEmpty)
        // Kept under Done for the week, like any finished card.
        #expect(NoticeStore.prune(moe.notices).filter { $0.body.contains(t) }.count == 4)
    }

    // MARK: The backlog, once

    @Test func theBacklogIsArchivedOnceAndRecentWorkStays() throws {
        let moe = try Self.make()
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-backlog-\(UUID().uuidString)/backlog-archived")
        defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }
        let t = Self.tag()
        let now = Date()
        moe.arrive(Self.input("Insurer offer \(t).", at: now.addingTimeInterval(-3600), offer: "sit_ins_\(t)"))
        moe.arrive(Self.input("Old offer \(t).", at: now.addingTimeInterval(-50 * 3600), offer: "sit_old_\(t)"))
        moe.arrive(Self.input("Brief \(t).", at: now.addingTimeInterval(-600), kind: "brief"))
        moe.arrive(Self.input("Hanoi \(t).", at: now.addingTimeInterval(-600), loops: ["hanoi-\(t)"]))
        let n = moe.archiveBacklogOnce(now: now, flag: flag)
        #expect(n >= 3)
        let open = moe.notices.filter { $0.status == .open }
        #expect(open.map(\.body) == ["Insurer offer \(t)."])
        #expect(moe.notices.filter { $0.body.contains(t) && $0.status == .done }.allSatisfy { $0.outcome == "Archived" })
        #expect(FileManager.default.fileExists(atPath: flag.path))
        // Once: a second launch archives nothing, whatever is waiting.
        moe.arrive(Self.input("New brief \(t).", kind: "brief"))
        #expect(moe.archiveBacklogOnce(now: now, flag: flag) == 0)
        #expect(moe.notices.contains { $0.body == "New brief \(t)." && $0.status == .open })
    }
}
