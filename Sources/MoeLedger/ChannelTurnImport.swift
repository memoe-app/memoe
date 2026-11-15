import Foundation
import MoeChat

/// Chat-app turns this Mac answered, brought into the ledger.
///
/// Measured 2026-11-13 (docs/CHANNEL-SYNC-AUDIT-2026-11-13.md, F1/F4/F5): a
/// Telegram message the Mac answered over the relay, and every WhatsApp
/// message, stayed in the brain's own store and never reached the ledger —
/// so the Away machine, and search, never saw them. The brain's memory
/// plugin queues each such turn (`claimstore/channel_spool.py`) because the
/// signing key is the app's; this reads the queue and records the turns as
/// the app records its own, `source` set to the chat app.
///
/// One thread per chat, and a new one after six quiet hours — the same rule
/// the Away machine applies to the chats it answers (`moe-ledger`
/// `_choose_thread`), so a chat reads the same on both sides.
extension ConversationLedger {

    public struct ChannelImport: Equatable {
        public var turns: Int = 0
        public var threads: [String] = []
        public var unreadable: Int = 0
    }

    /// The quiet gap after which a chat starts a new conversation.
    public static let channelQuietGap: TimeInterval = 6 * 3600

    /// Drain `spool` into the ledger. `state` remembers which thread each
    /// chat is writing to. Safe to call again after a crash: the queue is
    /// renamed before it is read and removed only once every turn in it is
    /// recorded, and a turn already recorded (by its id) is not written twice.
    @discardableResult
    public func importChannelTurns(spool: URL, state: URL) throws -> ChannelImport {
        try queue.sync { try importChannelTurnsLocked(spool: spool, state: state) }
    }

    private struct ChatState: Codable {
        var thread: String
        var last: Double
    }

    private struct Line: Decodable {
        var platform: String
        var chat_id: String
        var at: Double
        var you_id: String
        var you: String
        var moe_id: String
        var moe: String
    }

    private func importChannelTurnsLocked(spool: URL, state stateURL: URL) throws -> ChannelImport {
        let fm = FileManager.default
        let draining = spool.appendingPathExtension("draining")
        // A draining file left by a crash is read first; a fresh queue waits
        // for the next round rather than being mixed into it.
        if !fm.fileExists(atPath: draining.path) {
            guard fm.fileExists(atPath: spool.path) else { return ChannelImport() }
            try fm.moveItem(at: spool, to: draining)
        }
        var result = ChannelImport()
        var chats = (try? JSONDecoder().decode([String: ChatState].self,
                                               from: Data(contentsOf: stateURL))) ?? [:]
        let text = (try? String(contentsOf: draining, encoding: .utf8)) ?? ""
        var touched: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)),
                  !line.platform.isEmpty, !line.chat_id.isEmpty else {
                result.unreadable += 1
                continue
            }
            let chat = "\(line.platform):\(line.chat_id)"
            let at = Date(timeIntervalSince1970: line.at)
            var thread: String
            if let known = chats[chat], line.at - known.last < Self.channelQuietGap,
               !projector.isDeleted(thread: known.thread) {
                thread = known.thread
            } else {
                thread = UUID().uuidString
            }
            var conversation = projector.project(thread: thread)
                ?? ConversationStore.Conversation(id: thread, startedAt: at, updatedAt: at)
            if !line.you.isEmpty {
                conversation.turns.append(.init(id: line.you_id, role: .you, text: line.you, at: at))
            }
            if !line.moe.isEmpty {
                conversation.turns.append(.init(id: line.moe_id, role: .moe, text: line.moe, at: at))
            }
            conversation.updatedAt = at
            result.turns += try record(conversation, source: line.platform).count
            chats[chat] = ChatState(thread: thread, last: max(line.at, chats[chat]?.last ?? 0))
            if !touched.contains(thread) { touched.append(thread) }
            // The thread choice is saved per line, so a crash part-way through
            // replays into the same threads and the ids dedupe the rest.
            try JSONEncoder().encode(chats).write(to: stateURL, options: .atomic)
        }
        for thread in touched { try projector.write(thread: thread) }
        try fm.removeItem(at: draining)
        result.threads = touched
        return result
    }
}
