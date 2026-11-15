import Foundation

/// The Chat list, arranged: what you pinned on top, then everything else
/// newest first, the archive out of the way until asked for (the owner's
/// answer 6, 2026-11-13).
public struct ConversationList: Equatable {
    public var pinned: [ConversationStore.Conversation]
    public var recent: [ConversationStore.Conversation]
    public var archived: [ConversationStore.Conversation]

    public init(pinned: [ConversationStore.Conversation] = [],
                recent: [ConversationStore.Conversation] = [],
                archived: [ConversationStore.Conversation] = []) {
        self.pinned = pinned
        self.recent = recent
        self.archived = archived
    }

    /// `convos` newest first, as `ConversationStore.search` gives them. A
    /// search looks through the archive too: something you filed away is
    /// still something you may be looking for. A `tag` keeps only the chats
    /// tagged with it, and looks through the archive the same way.
    public static func arrange(_ convos: [ConversationStore.Conversation],
                               marks: [String: ConversationStore.Marks],
                               searching: Bool, tag: String? = nil) -> ConversationList {
        var list = ConversationList(pinned: [], recent: [], archived: [])
        let searching = searching || tag != nil
        for c in convos {
            let m = marks[c.id] ?? .init()
            if let tag, !m.tags.contains(tag) { continue }
            if m.pinned { list.pinned.append(c) }
            else if m.archived && !searching { list.archived.append(c) }
            else { list.recent.append(c) }
        }
        return list
    }
}
