import Foundation
import Testing
@testable import Moe

/// `FileWatch` against a real directory: the three polls it replaced
/// (`Conductor.watchForNoted`, `watchForInbox`, `watchForNudges`) are only
/// as good as this is.
///
/// Every test that is about an *event* runs with the safety tick an hour
/// away, so a watcher that hears nothing cannot pass by being polled.
@Suite(.serialized)
struct FileWatchTests {

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var again = 0
        func hit() -> Bool {
            lock.lock(); defer { lock.unlock() }
            n += 1
            if again > 0 { again -= 1; return true }
            return false
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func reset() { lock.lock(); n = 0; lock.unlock() }
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-watch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func wait(_ seconds: Double = 10, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return done()
    }

    /// A started watcher that has already said its one opening call, with
    /// the count back at zero.
    static func watching(_ dir: URL, accepting: (@Sendable (String) -> Bool)? = nil,
                         safety: TimeInterval = 3600, retry: TimeInterval = 5,
                         createIfMissing: Bool = false) async throws -> (FileWatch, Count) {
        let count = Count()
        let w = FileWatch(directory: dir, accepting: accepting, coalesce: 0.2, safety: safety, retry: retry,
                          createIfMissing: createIfMissing, deliverOn: DispatchQueue(label: "test.deliver")) {
            count.hit()
        }
        w.start()
        #expect(await wait { count.value >= 1 }, "a watcher says once at the start what was there before it")
        try await Task.sleep(nanoseconds: 700_000_000)
        count.reset()
        return (w, count)
    }

    @Test func aFileCreatedChangedRenamedAndDeletedIsEachHeard() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir)
        defer { w.stop() }
        let file = dir.appendingPathComponent("a.json")

        try Data("one".utf8).write(to: file)
        #expect(await Self.wait { count.value >= 1 }, "created")
        try await Task.sleep(nanoseconds: 600_000_000); count.reset()

        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd(); try h.write(contentsOf: Data("two".utf8)); try h.close()
        #expect(await Self.wait { count.value >= 1 }, "changed")
        try await Task.sleep(nanoseconds: 600_000_000); count.reset()

        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("b.json"))
        #expect(await Self.wait { count.value >= 1 }, "renamed")
        try await Task.sleep(nanoseconds: 600_000_000); count.reset()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.json"))
        #expect(await Self.wait { count.value >= 1 }, "deleted")
    }

    /// The plugin's own write: a temp file, then a rename onto the name.
    @Test func anAtomicWriteOntoAnAcceptedNameIsHeard() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir, accepting: { $0 == "nudge.json" })
        defer { w.stop() }
        let tmp = dir.appendingPathComponent("nudge.json.tmp")
        try Data("{}".utf8).write(to: tmp)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(count.value == 0, "the temp file is not the name that was asked about")
        try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("nudge.json"))
        #expect(await Self.wait { count.value >= 1 })
    }

    @Test func otherNamesAndSubdirectoriesAreNotHeard() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let (w, count) = try await Self.watching(dir, accepting: { $0.hasSuffix(".json") })
        defer { w.stop() }
        try Data("x".utf8).write(to: dir.appendingPathComponent("moe.log"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("deep.json"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(count.value == 0)
        // And the watcher is alive, not merely deaf.
        try Data("x".utf8).write(to: dir.appendingPathComponent("real.json"))
        #expect(await Self.wait { count.value >= 1 })
    }

    @Test func aBurstIsOneCallNotOnePerFile() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir)
        defer { w.stop() }
        for i in 0..<40 {
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(i).json"))
        }
        #expect(await Self.wait { count.value >= 1 })
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(count.value <= 3, "40 files made \(count.value) calls")
    }

    /// Moe's home: `~/.moe` is a link to the real directory, and the events
    /// are the real directory's.
    @Test func aDirectoryReachedThroughALinkIsWatchedWhereItReallyIs() async throws {
        let base = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("Application Support/Moe", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent(".moe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let (w, count) = try await Self.watching(link)
        defer { w.stop() }
        #expect(w.watching == FileWatch.Identity(of: real))
        #expect(w.watching?.path.hasSuffix("Application Support/Moe") == true, "the resolved path, with its space")
        try Data("x".utf8).write(to: real.appendingPathComponent("nudge.json"))
        #expect(await Self.wait { count.value >= 1 }, "written by its real path")
        try await Task.sleep(nanoseconds: 600_000_000); count.reset()
        try Data("y".utf8).write(to: link.appendingPathComponent("other.json"))
        #expect(await Self.wait { count.value >= 1 }, "written through the link")
    }

    @Test func aDirectoryDeletedAndMadeAgainIsWatchedAgain() async throws {
        let base = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (w, _) = try await Self.watching(dir, safety: 0.4)
        defer { w.stop() }
        let before = try #require(w.watching)
        try FileManager.default.removeItem(at: dir)
        #expect(await Self.wait { w.watching == nil }, "nothing there, so nothing watched")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let made = try #require(FileWatch.Identity(of: dir))
        #expect(await Self.wait { w.watching == made }, "the new directory is the one watched")
        #expect(made.path == before.path, "the same place, a different directory")
    }

    /// The link is pointed somewhere else (a migration, a restore): no event
    /// says so, which is what the safety tick is for.
    @Test func aLinkPointedAtAnotherDirectoryIsFollowed() async throws {
        let base = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("a", isDirectory: true)
        let b = base.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("home")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let (w, _) = try await Self.watching(link, safety: 0.4)
        defer { w.stop() }
        #expect(w.watching == FileWatch.Identity(of: a))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        #expect(await Self.wait { w.watching == FileWatch.Identity(of: b) })
    }

    @Test func aMissingDirectoryIsMadeWhenAskedAndWaitedForWhenNot() async throws {
        let base = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let made = base.appendingPathComponent("inbox", isDirectory: true)
        let (w1, c1) = try await Self.watching(made, createIfMissing: true)
        defer { w1.stop() }
        #expect(w1.watching != nil)
        try Data("x".utf8).write(to: made.appendingPathComponent("1.json"))
        #expect(await Self.wait { c1.value >= 1 })

        let later = base.appendingPathComponent("memory", isDirectory: true)
        let (w2, _) = try await Self.watching(later, safety: 0.4)
        defer { w2.stop() }
        #expect(w2.watching == nil)
        #expect(!FileManager.default.fileExists(atPath: later.path), "not made unless asked")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        #expect(await Self.wait { w2.watching != nil })
    }

    /// The slow poll that is kept: with no event at all, it still asks.
    @Test func theSafetyTickAsksEvenWhenNothingWasHeard() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir, safety: 0.5)
        defer { w.stop() }
        #expect(await Self.wait(5) { count.value >= 2 })
    }

    /// "Still waiting" from the callback is asked again without any event.
    @Test func workStillWaitingIsAskedAboutAgain() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir, retry: 0.3)
        defer { w.stop() }
        count.again = 2
        try Data("x".utf8).write(to: dir.appendingPathComponent("turn.json"))
        #expect(await Self.wait { count.value >= 3 }, "the event, then two retries")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(count.value == 3, "and it stops once nothing is waiting")
    }

    @Test func aStoppedWatcherSaysNothing() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (w, count) = try await Self.watching(dir, safety: 0.3)
        w.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        count.reset()
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.json"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(count.value == 0)
        #expect(w.watching == nil)
    }

    /// The three polls are gone from the Conductor, and stay gone.
    @Test func theConductorWatchesInsteadOfPolling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Conductor.swift"), encoding: .utf8)
        for name in ["watchForNudges", "watchForNoted", "watchForInbox"] {
            let start = try #require(source.range(of: "private func \(name)()"))
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
            let body = rest[..<end]
            #expect(body.contains("FileWatch("), "\(name) no longer watches")
            #expect(!body.contains("Timer("), "\(name) is polling again")
        }
    }
}
