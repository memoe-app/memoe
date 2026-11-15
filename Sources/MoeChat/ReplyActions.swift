import Foundation

/// The buttons under an answer (the owner's answer 7, 2026-11-13): Send ·
/// Edit · Copy under a draft Moe wrote, a yes under an offer, Retry under an
/// error. Only ever on the newest turn: a yes to an offer three answers up
/// is a yes to something that has moved on.
///
/// None of them sends anything itself. Send and Yes are a turn from the
/// person ("Send it."), so whatever goes out still goes through the send
/// gate's own confirmation, exactly as if it had been typed.
public enum ReplyAction: String, CaseIterable, Sendable, Equatable {
    case send, edit, copy, accept, retry

    public var label: String {
        switch self {
        case .send: return "Send"
        case .edit: return "Edit"
        case .copy: return "Copy"
        case .accept: return "Yes, do it"
        case .retry: return "Retry"
        }
    }

    /// What the button says to Moe, as the person, for the two that answer.
    public var words: String? {
        switch self {
        case .send: return "Send it as it is."
        case .accept: return "Yes, go ahead."
        default: return nil
        }
    }
}

public enum ReplyActions {

    /// The buttons for a turn. `failed`: an error note; `latest`: nothing
    /// has been said since.
    public static func of(text: String, isAnswer: Bool, failed: Bool, latest: Bool) -> [ReplyAction] {
        guard latest else { return [] }
        if failed { return [.retry] }
        guard isAnswer else { return [] }
        if draft(in: text) != nil { return [.send, .edit, .copy] }
        if isOffer(text) { return [.accept] }
        return []
    }

    /// The draft in an answer: its last quoted block, the way the model
    /// writes an email or a message for you (`ReplyBlocks`' quote card).
    public static func draft(in text: String) -> String? {
        for block in ReplyBlocks.parse(text).reversed() {
            if case .quote(let q) = block, q.split(whereSeparator: \.isWhitespace).count >= 3 { return q }
        }
        return nil
    }

    /// The answer ends by offering to do something: its last paragraph is
    /// a question that opens like an offer ("Want me to…?", "Shall I…?").
    /// It only ever adds a button that says yes as the person would.
    public static func isOffer(_ text: String) -> Bool {
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true).last else { return false }
        let line = last.trimmingCharacters(in: .whitespaces)
        guard line.hasSuffix("?") else { return false }
        // The question itself: the last sentence of that paragraph.
        let sentence = line.dropLast()
            .split(whereSeparator: { ".!?".contains($0) }).last
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return offerOpenings.contains { sentence.hasPrefix($0) }
    }

    static let offerOpenings = [
        "want me to", "want the", "want it", "want a ", "should i", "shall i", "do you want me to",
        "would you like me to", "would you like the", "ok to", "okay to", "can i go ahead",
        "should i go ahead", "רוצה ש", "שאשלח", "לשלוח",
    ]
}
