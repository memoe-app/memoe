import Foundation
import Testing
@testable import MoeChat

/// Pin, archive and rename in the Chat list (the owner's answer 6,
/// 2026-11-13).
struct ConversationListTests {

    private func store() -> ConversationStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moe-list-tests-\(UUID().uuidString)", isDirectory: true)
        return ConversationStore(directory: dir)
    }

    private func thread(_ s: ConversationStore, _ said: String, daysAgo: Double) throws -> String {
        let at = Date().addingTimeInterval(-daysAgo * 86_400)
        let c = ConversationStore.Conversation(startedAt: at, updatedAt: at, turns: [
            .init(role: .you, text: said, at: at), .init(role: .moe, text: "Done.", at: at)])
        try s.save(c)
        return c.id
    }

    @Test func pinnedOnTopArchivedAside() throws {
        let s = store()
        let old = try thread(s, "Old tax question", daysAgo: 20)
        let lisbon = try thread(s, "Trip to Lisbon", daysAgo: 5)
        let nopa = try thread(s, "Dinner at Nopa", daysAgo: 0)
        try s.setPinned(true, for: lisbon)
        try s.setArchived(true, for: old)

        let list = ConversationList.arrange(s.all(), marks: s.marks(), searching: false)
        #expect(list.pinned.map(\.id) == [lisbon])
        #expect(list.recent.map(\.id) == [nopa])
        #expect(list.archived.map(\.id) == [old])
    }

    /// A search finds what you filed away.
    @Test func searchLooksInTheArchive() throws {
        let s = store()
        let old = try thread(s, "Old tax question", daysAgo: 20)
        try s.setArchived(true, for: old)
        let list = ConversationList.arrange(s.search("tax"), marks: s.marks(), searching: true)
        #expect(list.recent.map(\.id) == [old])
        #expect(list.archived.isEmpty)
    }

    @Test func pinningUnarchivesAndArchivingUnpins() throws {
        let s = store()
        let id = try thread(s, "Kitchen quotes", daysAgo: 1)
        try s.setArchived(true, for: id)
        try s.setPinned(true, for: id)
        #expect(s.marks()[id] == .init(pinned: true, archived: false))
        try s.setArchived(true, for: id)
        #expect(s.marks()[id] == .init(pinned: false, archived: true))
        try s.setArchived(false, for: id)
        #expect(s.marks()[id] == nil)
    }

    /// The marks survive the thread being written again (a re-projection
    /// from the ledger rewrites the file), and go with it when it is deleted.
    @Test func marksSurviveARewriteAndGoWithADelete() throws {
        let s = store()
        let id = try thread(s, "Gift for Dana", daysAgo: 1)
        try s.setPinned(true, for: id)
        var c = try #require(s.load(id: id))
        c.turns.append(.init(role: .you, text: "and wrap it"))
        try s.save(c)
        #expect(s.marks()[id]?.pinned == true)
        try s.delete(id: id)
        #expect(s.marks()[id] == nil)
    }

    /// A name you give a thread is its title from then on.
    @Test func aRenameIsTheTitle() throws {
        let s = store()
        let id = try thread(s, "book me a table for two somewhere near the office", daysAgo: 0)
        try s.setTitle("Friday dinner", for: id)
        #expect(s.load(id: id)?.title == "Friday dinner")
    }
}
