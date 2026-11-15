import Foundation

/// When a conversation left alone is put away and a fresh one started.
///
/// Every turn re-sends the whole conversation, and nothing ever ended one but
/// ⌘N or a spoken goodbye. Measured on the owner's Mac, one notch thread
/// lived from 2026-10-30 to 11-07: 45k tokens on its first turn, 162k by
/// its 123rd message, and the first reply went from 3.6 s to 12.0 s (15.0 s
/// after a gap, when the provider's cache had gone cold too). A question
/// asked after an hour away is almost never a follow-up, and Moe's memory
/// carries what matters across; the thread itself stays in Chat.
public enum ConversationFreshness {
    /// How long a conversation sits untouched before it is put away.
    public static let idleLimit: TimeInterval = 60 * 60

    /// What is going on when the check runs. Anything in progress, or the
    /// person looking at Moe, means not now: the conversation on screen must
    /// not vanish from under them.
    public struct Situation: Equatable {
        public var lastActivity: Date?
        public var now: Date
        /// A reply owed, a voice window open, dictation, a meeting, a notice
        /// being answered: any of them.
        public var busy: Bool
        /// The island's panel or one of Moe's own windows is in front.
        public var watched: Bool

        public init(lastActivity: Date?, now: Date, busy: Bool, watched: Bool) {
            self.lastActivity = lastActivity
            self.now = now
            self.busy = busy
            self.watched = watched
        }
    }

    public static func shouldStartFresh(_ s: Situation, idleLimit: TimeInterval = idleLimit) -> Bool {
        guard let last = s.lastActivity, !s.busy, !s.watched else { return false }
        return s.now.timeIntervalSince(last) >= idleLimit
    }
}
