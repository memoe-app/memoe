import Foundation

/// Tags for the Chat list's filter: one small call per chat, at the cheapest
/// model of the person's own provider, once the chat has a few turns
/// (`wants`), and never again for that chat (`ConversationStore.Marks.tagged`).
/// A chat marked "Don't remember this chat" is never tagged.
public enum TagRules {

    /// Exchanges (your message and its answer) a chat needs before it is
    /// tagged: one is too little to say what a chat is about, and a title
    /// already covers it.
    public static let minExchanges = 3

    /// At most this many tags a chat.
    public static let maxTags = 3

    public static let system = """
        You tag conversations so a person can filter their chat list. Reply with \
        1 to 3 tags, comma separated, nothing else. Each tag is one or two plain \
        lowercase words naming a topic, like "travel", "taxes", "work email" or \
        "garden". Reuse a tag from the person's existing tags whenever one fits. \
        No hashtags, no quotes, no emoji, never a sentence.
        """

    /// The chat's opening exchanges, each side clipped, and the tags the
    /// person already has so the list does not grow a near-duplicate of each.
    /// Bounded, so the call costs the same whatever the chat's length.
    public static func user(exchanges: [(you: String, answer: String)], existing: [String]) -> String {
        func clip(_ s: String, _ n: Int) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }
        var lines = ["Tag this conversation. It goes:", ""]
        for e in exchanges.prefix(minExchanges) {
            lines.append("Person: " + clip(e.you, 300))
            lines.append("Assistant: " + clip(e.answer, 200))
        }
        let known = Array(existing.prefix(24))
        if !known.isEmpty {
            lines.append("")
            lines.append("Existing tags: " + known.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// The model's reply as tags, or nil when it is not a list of them.
    public static func accept(_ reply: String) -> [String]? {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = s.firstIndex(of: "\n") { s = String(s[..<nl]) }
        for label in ["Tags:", "tags:", "Tag:", "tag:"] where s.hasPrefix(label) {
            s = String(s.dropFirst(label.count))
        }
        let strip: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "*", "`", "#", ".", "[", "]"]
        var tags: [String] = []
        for part in s.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            var t = String(part).trimmingCharacters(in: .whitespaces)
            while let f = t.first, strip.contains(f) { t.removeFirst() }
            while let l = t.last, strip.contains(l) { t.removeLast() }
            t = t.trimmingCharacters(in: .whitespaces).lowercased()
            let words = t.split(separator: " ")
            guard !t.isEmpty, words.count <= 2, t.count <= 24 else { return nil }
            if !tags.contains(t) { tags.append(t) }
        }
        guard !tags.isEmpty else { return nil }
        return Array(tags.prefix(maxTags))
    }

    /// Each message of yours with the answer that followed it, in order;
    /// a message with no answer yet is not an exchange.
    public static func exchanges(of turns: [ConversationStore.StoredTurn]) -> [(you: String, answer: String)] {
        var out: [(you: String, answer: String)] = []
        var asked: String?
        for t in turns {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.role == .you, !text.isEmpty { asked = text }
            else if t.role == .moe, !text.isEmpty, let a = asked { out.append((a, text)); asked = nil }
        }
        return out
    }

    /// Only a chat that has not been tagged, is not marked "Don't remember
    /// this chat", and has `minExchanges` answered exchanges.
    public static func wants(forget: Bool, tagged: Bool, answeredExchanges: Int) -> Bool {
        !forget && !tagged && answeredExchanges >= minExchanges
    }

    /// Every tag in use, most used first, then by name: the filter's order.
    public static func vocabulary(_ marks: [String: ConversationStore.Marks]) -> [String] {
        var counts: [String: Int] = [:]
        for m in marks.values where !m.forget {
            for t in m.tags { counts[t, default: 0] += 1 }
        }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }
}
