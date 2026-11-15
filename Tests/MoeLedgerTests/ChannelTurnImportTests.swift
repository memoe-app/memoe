import Foundation
import Testing
import MoeChat
@testable import MoeLedger

/// The audit's F1/F4/F5 (docs/CHANNEL-SYNC-AUDIT-2026-11-13.md): a chat the
/// Mac answered must reach the ledger. The brain queues the turn
/// (`claimstore/channel_spool.py`, whose line format these fixtures copy);
/// `importChannelTurns` records it, one thread per chat.
struct ChannelTurnImportTests {

    private let sunday = Date(timeIntervalSince1970: 1_756_000_000)

    private func mac(_ label: String) -> (Appender, URL, URL) {
        let root = scratchRoot(label)
        let mac = Appender.make(name: "mac-9f3c", root: root.appendingPathComponent("mac"),
                                ledgerDirectory: root.appendingPathComponent("mac/ledger"),
                                clock: FakeClock(sunday))
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        return (mac, cloud.appendingPathComponent("channel-turns.jsonl"),
                cloud.appendingPathComponent("channel-threads.json"))
    }

    private func line(_ platform: String, _ chat: String, at: Double,
                      you: String, moe: String, ids: (String, String)) -> String {
        let object: [String: Any] = ["v": 1, "platform": platform, "chat_id": chat, "at": at,
                                     "you_id": ids.0, "you": you, "moe_id": ids.1, "moe": moe]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func aTelegramTurnTheMacAnsweredIsRecordedAndProjected() throws {
        let (mac, spool, state) = mac("channel-import")
        let t = sunday.timeIntervalSince1970
        try write([line("telegram", "5550001107", at: t, you: "is the car booked?",
                        moe: "Yes, for nine tomorrow.", ids: ("Y1", "M1"))], to: spool)

        let result = try mac.conversations.importChannelTurns(spool: spool, state: state)

        #expect(result.turns == 2)
        #expect(result.threads.count == 1)
        let thread = try #require(result.threads.first)
        let records = mac.conversations.projector.turnRecords(thread: thread)
        #expect(records.map { $0.body["source"]?.stringValue } == ["telegram", "telegram"])
        let file = try #require(mac.store.load(id: thread))
        #expect(file.turns.map(\.text) == ["is the car booked?", "Yes, for nine tomorrow."])
        #expect(file.turns.map(\.role) == [.you, .moe])
        // The queue is gone once recorded.
        #expect(!FileManager.default.fileExists(atPath: spool.path))
        #expect(!FileManager.default.fileExists(atPath: spool.appendingPathExtension("draining").path))
    }

    @Test func oneChatStaysInOneThreadUntilSixQuietHours() throws {
        let (mac, spool, state) = mac("channel-import-threads")
        let t = sunday.timeIntervalSince1970
        try write([
            line("telegram", "1", at: t, you: "a", moe: "b", ids: ("Y1", "M1")),
            line("whatsapp", "44", at: t + 10, you: "c", moe: "d", ids: ("Y2", "M2")),
            line("telegram", "1", at: t + 3600, you: "e", moe: "f", ids: ("Y3", "M3")),
        ], to: spool)
        let first = try mac.conversations.importChannelTurns(spool: spool, state: state)
        #expect(first.threads.count == 2)
        let telegram = first.threads[0]
        #expect(mac.store.load(id: telegram)?.turns.map(\.text) == ["a", "b", "e", "f"])

        try write([line("telegram", "1", at: t + 3600 + 7 * 3600, you: "g", moe: "h",
                        ids: ("Y4", "M4"))], to: spool)
        let later = try mac.conversations.importChannelTurns(spool: spool, state: state)
        #expect(later.threads.count == 1)
        #expect(later.threads[0] != telegram)
    }

    @Test func aDrainCutShortReplaysWithoutWritingATurnTwice() throws {
        let (mac, spool, state) = mac("channel-import-replay")
        let t = sunday.timeIntervalSince1970
        let one = line("telegram", "1", at: t, you: "a", moe: "b", ids: ("Y1", "M1"))
        try write([one], to: spool)
        let first = try mac.conversations.importChannelTurns(spool: spool, state: state)
        // As if the app died after recording but before removing the file.
        try write([one, "not json", line("telegram", "1", at: t + 5, you: "c", moe: "d",
                                         ids: ("Y2", "M2"))],
                  to: spool.appendingPathExtension("draining"))
        let again = try mac.conversations.importChannelTurns(spool: spool, state: state)
        #expect(again.turns == 2)
        #expect(again.unreadable == 1)
        #expect(again.threads == first.threads)
        #expect(mac.conversations.projector.turnRecords(thread: first.threads[0]).count == 4)
    }

    @Test func nothingQueuedIsNothingDone() throws {
        let (mac, spool, state) = mac("channel-import-empty")
        let result = try mac.conversations.importChannelTurns(spool: spool, state: state)
        #expect(result == .init())
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }
}
