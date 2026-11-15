import Foundation
import Testing
@testable import MoeChat

struct TagRulesTests {

    @Test func aReplyBecomesAtMostThreeShortTags() {
        #expect(TagRules.accept("travel, Lisbon, work email") == ["travel", "lisbon", "work email"])
        #expect(TagRules.accept("Tags: #travel, \"food\".") == ["travel", "food"])
        #expect(TagRules.accept("a, b, c, d") == ["a", "b", "c"])
        #expect(TagRules.accept("travel, travel") == ["travel"])
        #expect(TagRules.accept("This conversation is about planning a trip to Lisbon") == nil)
        #expect(TagRules.accept("") == nil)
    }

    @Test func onlyAnsweredExchangesCount() {
        let t = { (id: String, role: ConversationStore.StoredTurn.Role, text: String) in
            ConversationStore.StoredTurn(id: id, role: role, text: text, at: Date()) }
        let turns = [t("1", .you, "one"), t("2", .moe, "a"), t("3", .you, "two"), t("4", .you, "three"),
                     t("5", .moe, "b"), t("6", .you, "four")]
        #expect(TagRules.exchanges(of: turns).map(\.you) == ["one", "three"])
    }

    @Test func thePromptIsBoundedAndOffersTheTagsInUse() {
        let long = String(repeating: "word ", count: 500)
        let user = TagRules.user(exchanges: Array(repeating: (long, long), count: 10), existing: ["travel"])
        #expect(user.count < 2_000)
        #expect(user.contains("Existing tags: travel"))
    }

    @Test func theGate() {
        #expect(TagRules.wants(forget: false, tagged: false, answeredExchanges: TagRules.minExchanges))
        #expect(!TagRules.wants(forget: true, tagged: false, answeredExchanges: 9))
        #expect(!TagRules.wants(forget: false, tagged: true, answeredExchanges: 9))
        #expect(!TagRules.wants(forget: false, tagged: false, answeredExchanges: TagRules.minExchanges - 1))
    }

    @Test func theFilterKeepsOnlyThatTagAndLooksInTheArchive() {
        let c = { (id: String) in ConversationStore.Conversation(id: id, startedAt: Date(), updatedAt: Date(), turns: []) }
        let marks: [String: ConversationStore.Marks] = [
            "a": .init(tags: ["travel"]), "b": .init(archived: true, tags: ["travel"]), "c": .init(tags: ["food"]),
        ]
        let list = ConversationList.arrange([c("a"), c("b"), c("c")], marks: marks, searching: false, tag: "travel")
        #expect(list.recent.map(\.id) == ["a", "b"])
        #expect(ConversationList.arrange([c("a"), c("b"), c("c")], marks: marks, searching: false).recent.map(\.id) == ["a", "c"])
        #expect(TagRules.vocabulary(marks) == ["travel", "food"])
    }

    /// Marks written before tags and the switch existed still read: an old
    /// marks.idx must not lose every pin.
    @Test func anOlderMarksFileStillReads() throws {
        let old = #"{"x":{"pinned":true,"archived":false}}"#.data(using: .utf8)!
        let map = try JSONDecoder().decode([String: ConversationStore.Marks].self, from: old)
        #expect(map["x"]?.pinned == true && map["x"]?.forget == false && map["x"]?.tags == [])
    }

    @Test func aPrivateChatHoldsNoTags() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        try store.setTags(["travel"], for: "x")
        try store.setForget(true, for: "x")
        #expect(store.marks()["x"]?.tags == [])
        try store.setTags(["travel"], for: "x")
        #expect(store.marks()["x"]?.tags == [] && store.marks()["x"]?.tagged == true)
    }
}
