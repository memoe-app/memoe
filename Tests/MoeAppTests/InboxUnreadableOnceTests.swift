import Foundation
import Testing
@testable import Moe

/// The inbox is looked at every five seconds. A file in it that would not
/// parse was read and parsed again on every look, for as long as it sat
/// there. It is read once, and again only if it changes.
struct InboxUnreadableOnceTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reads counted per file name.
    private final class Reads {
        var count: [String: Int] = [:]
        func read(_ url: URL) -> Data? {
            count[url.lastPathComponent, default: 0] += 1
            return try? Data(contentsOf: url)
        }
    }

    @Test func aFileThatWillNotParseIsReadOnce() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{ not json".write(to: dir.appendingPathComponent("1-bad.json"), atomically: true, encoding: .utf8)
        try #"{"at": 1}"#.write(to: dir.appendingPathComponent("2-no-text.json"), atomically: true, encoding: .utf8)
        try #"{"text": "Call Dani", "at": 1790000000}"#
            .write(to: dir.appendingPathComponent("3-good.json"), atomically: true, encoding: .utf8)

        let memory = ReminderChannels.Unreadable()
        let reads = Reads()
        for _ in 0..<5 {
            let found = ReminderChannels.pending(in: dir, remembering: memory, read: reads.read)
            #expect(found.map(\.text) == ["Call Dani"])
        }
        #expect(reads.count["1-bad.json"] == 1)
        #expect(reads.count["2-no-text.json"] == 1)
        // A good message is not this function's to forget: it is read until
        // whoever shows it removes it.
        #expect(reads.count["3-good.json"] == 5)
        // And the unreadable ones are still there for whoever wants a look.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1-bad.json").path))
    }

    @Test func aFileThatChangesIsReadAgain() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("1.json")
        try "{".write(to: url, atomically: true, encoding: .utf8)

        let memory = ReminderChannels.Unreadable()
        let reads = Reads()
        #expect(ReminderChannels.pending(in: dir, remembering: memory, read: reads.read).isEmpty)
        #expect(ReminderChannels.pending(in: dir, remembering: memory, read: reads.read).isEmpty)
        #expect(reads.count["1.json"] == 1)

        try #"{"text": "Now it is whole", "at": 1790000000}"#.write(to: url, atomically: true, encoding: .utf8)
        let found = ReminderChannels.pending(in: dir, remembering: memory, read: reads.read)
        #expect(found.map(\.text) == ["Now it is whole"])
        #expect(reads.count["1.json"] == 2)
    }

    @Test func aFileThatIsGoneIsForgotten() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("1.json")
        try "{".write(to: url, atomically: true, encoding: .utf8)
        let memory = ReminderChannels.Unreadable()
        _ = ReminderChannels.pending(in: dir, remembering: memory)
        let stamp = ReminderChannels.Unreadable.Stamp(of: url)
        #expect(memory.isKnown("1.json", stamp))
        try FileManager.default.removeItem(at: url)
        _ = ReminderChannels.pending(in: dir, remembering: memory)
        #expect(!memory.isKnown("1.json", stamp))
    }
}
