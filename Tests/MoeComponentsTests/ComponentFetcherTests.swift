import CryptoKit
import Foundation
import Testing
@testable import MoeComponents

// The rules of the on-demand fetcher, each proven by doing the damage: serve
// wrong bytes, cut the connection, take the network away — then look at what
// is on disk, not at what the call returned.

/// A server in memory. Honours a resume the way a real one does (it appends
/// from the length of the part file), and can be told to misbehave.
final class FakeTransport: ComponentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: Data] = [:]
    private var _calls: [(url: String, offset: Int64, expensive: Bool)] = []
    private var _served: Int64 = 0

    /// Cut the connection after this many bytes of the named file, once.
    var cutAfter: [String: Int] = [:]
    /// Throw "unreachable" for every request.
    var offline = false
    /// Ignore the part file and send the whole body, as a server without
    /// range support does.
    var ignoresRange = false
    /// Slow every call down, so two callers overlap.
    var delay: UInt64 = 0

    var calls: [(url: String, offset: Int64, expensive: Bool)] { lock.withLock { _calls } }
    /// Bytes actually sent, across every call.
    var served: Int64 { lock.withLock { _served } }

    func serve(_ component: Component, _ contents: [String: Data]) {
        lock.withLock {
            for file in component.files {
                bodies[component.url(for: file).absoluteString] = contents[file.path]
            }
        }
    }

    func download(_ url: URL, to part: URL, allowExpensive: Bool,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> ComponentDownload {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let fm = FileManager.default
        let have = ignoresRange ? 0 : Int64((try? Data(contentsOf: part))?.count ?? 0)
        lock.withLock { _calls.append((url.absoluteString, have, allowExpensive)) }
        if offline { throw ComponentTransportError.unreachable("The Internet connection appears to be offline.") }
        guard let body = lock.withLock({ bodies[url.absoluteString] }) else {
            throw ComponentTransportError.status(404)
        }
        var data = have > 0 ? (try Data(contentsOf: part)) : Data()
        var rest = body.dropFirst(Int(have))
        let name = url.lastPathComponent
        let cut = lock.withLock { cutAfter.removeValue(forKey: name) }
        if let cut { rest = rest.prefix(max(0, cut - Int(have))) }
        data.append(rest)
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: part)
        lock.withLock { _served += Int64(rest.count) }
        progress(Int64(data.count))
        if cut != nil { throw ComponentTransportError.interrupted("The network connection was lost.") }
        return have > 0 ? .resumed : .fresh
    }
}

/// A small component with real hashes, and a scratch root to fetch it into.
struct Fixture {
    let root: URL
    let contents: [String: Data]
    let component: Component
    let transport = FakeTransport()
    let fetcher: ComponentFetcher

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-components-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var c: [String: Data] = [:]
        c["config.json"] = Data("{\"a\": 1}".utf8)
        c["Encoder.mlmodelc/weights/weight.bin"] = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        c["Encoder.mlmodelc/model.mil"] = Data(repeating: 0x6d, count: 5_000)
        contents = c
        component = Component(
            id: "test", folder: "test-model", title: "the test model",
            without: "Nothing else changes.",
            base: URL(string: "https://example.invalid/repo/resolve/0123456789abcdef0123456789abcdef01234567/")!,
            files: c.keys.sorted().map { ComponentFile($0, Int64(c[$0]!.count), Fixture.hex(c[$0]!)) })
        transport.serve(component, c)
        fetcher = ComponentFetcher(transport: transport)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var folder: URL { root.appendingPathComponent(component.folder) }
    var big: String { "Encoder.mlmodelc/weights/weight.bin" }

    func installedMatches() -> Bool {
        contents.allSatisfy { (try? Data(contentsOf: folder.appendingPathComponent($0.key))) == $0.value }
    }

    /// Every file under the root, relative — to see what a failure left.
    func everything() -> [String] {
        // Relative paths straight from FileManager: comparing absolute paths
        // as text trips over /var being a link to /private/var.
        let fm = FileManager.default
        return ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? []).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ComponentFetcherTests {

    @Test func fetchesEveryFileAndLeavesNothingBehind() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        var fractions: [Double] = []
        let lock = NSLock()
        let outcome = try await f.fetcher.ensure(f.component, in: f.root) { p in
            lock.withLock { fractions.append(p) }
        }
        #expect(outcome == .fetched)
        #expect(f.installedMatches())
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .present)
        // Only the model: no staging folder, no .part, no stamp.
        #expect(f.everything() == f.contents.keys.map { "test-model/\($0)" }.sorted())
        #expect(f.transport.calls.count == 3)
        #expect(lock.withLock { fractions.last } == 1.0)
        #expect(lock.withLock { fractions } == lock.withLock { fractions.sorted() })
    }

    @Test func whatIsAlreadyThereIsNotFetchedAgain() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        _ = try await f.fetcher.ensure(f.component, in: f.root)
        let before = f.transport.calls.count
        let again = try await f.fetcher.ensure(f.component, in: f.root)
        #expect(again == .alreadyPresent)
        #expect(f.transport.calls.count == before)
        // …and a different fetcher, as after a relaunch, agrees.
        let cold = FakeTransport()
        cold.offline = true
        #expect(try await ComponentFetcher(transport: cold).ensure(f.component, in: f.root) == .alreadyPresent)
        #expect(cold.calls.isEmpty)
    }

    @Test func aLinkIntoAnAppThatCarriesItCountsAsPresent() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        let bundle = f.root.appendingPathComponent("App/Models/test-model")
        for (path, data) in f.contents {
            let to = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: to)
        }
        try FileManager.default.createSymbolicLink(at: f.folder, withDestinationURL: bundle)
        f.transport.offline = true
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .alreadyPresent)
        #expect(f.transport.calls.isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.folder.path)) == bundle.path)
    }

    @Test func aLinkLeftByAnAppThatNoLongerCarriesItIsReplaced() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        let gone = f.root.appendingPathComponent("Old.app/Models/test-model")
        try FileManager.default.createSymbolicLink(at: f.folder, withDestinationURL: gone)
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .danglingLink)
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.folder.path)) == nil)
        #expect(f.installedMatches())
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func wrongBytesAreRefusedAndNothingIsInstalled() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        var tampered = f.contents
        tampered[f.big]![1234] ^= 0xff           // same length, one byte different
        f.transport.serve(f.component, tampered)
        await #expect(throws: ComponentError.hashMismatch(component: "the test model", file: f.big)) {
            try await f.fetcher.ensure(f.component, in: f.root)
        }
        // Nothing where the app looks, and the bad bytes are not kept
        // anywhere — not as a .part to "resume", not in staging.
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .absent)
        #expect(!f.everything().contains { $0.hasSuffix("weight.bin") || $0.hasSuffix(".part") })
        // A clean download that is wrong is not asked for twice.
        #expect(f.transport.calls.filter { $0.url.hasSuffix("weight.bin") }.count == 1)

        // Put the right bytes back: the same call now succeeds.
        f.transport.serve(f.component, f.contents)
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect(f.installedMatches())
    }

    @Test func aShortFileIsRefusedToo() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        var short = f.contents
        short[f.big] = short[f.big]!.prefix(100_000)
        f.transport.serve(f.component, short)
        await #expect(throws: ComponentError.hashMismatch(component: "the test model", file: f.big)) {
            try await f.fetcher.ensure(f.component, in: f.root)
        }
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
    }

    @Test func anInterruptedDownloadResumesFromWhereItStopped() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        f.transport.cutAfter["weight.bin"] = 120_000
        await #expect(throws: ComponentError.interrupted(component: "the test model", without: "Nothing else changes.")) {
            try await f.fetcher.ensure(f.component, in: f.root)
        }
        // Nothing installed, and the 120 000 bytes that arrived are kept.
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
        let part = ComponentFetcher.staging(for: f.component, in: f.root)
            .appendingPathComponent(f.big + ".part")
        #expect((try? Data(contentsOf: part))?.count == 120_000)

        let servedBefore = f.transport.served
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect(f.installedMatches())
        // It continued: the second request started at 120 000, and only the
        // missing 80 000 bytes of that file crossed the wire.
        let second = f.transport.calls.last { $0.url.hasSuffix("weight.bin") }
        #expect(second?.offset == 120_000)
        let rest = Int64(f.contents.values.reduce(0) { $0 + $1.count }) - servedBefore
        #expect(f.transport.served - servedBefore == rest)
        #expect(f.transport.served == Int64(f.contents.values.reduce(0) { $0 + $1.count }))
        // Files verified before the cut were not asked for again.
        #expect(f.transport.calls.filter { $0.url.hasSuffix("model.mil") }.count == 1)
        #expect(!f.everything().contains { $0.contains(".memoe-fetch") })
    }

    @Test func aCorruptHalfIsThrownAwayAndTheFileFetchedCleanOnce() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        // A part file from "last time" whose bytes are not the file's.
        let part = ComponentFetcher.staging(for: f.component, in: f.root)
            .appendingPathComponent(f.big + ".part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 50_000).write(to: part)

        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect(f.installedMatches())
        let offsets = f.transport.calls.filter { $0.url.hasSuffix("weight.bin") }.map(\.offset)
        #expect(offsets == [50_000, 0])     // resumed, mismatched, restarted clean
    }

    @Test func aServerThatCannotResumeRestartsCleanly() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        f.transport.cutAfter["weight.bin"] = 120_000
        _ = try? await f.fetcher.ensure(f.component, in: f.root)
        f.transport.ignoresRange = true
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect(f.installedMatches())
    }

    @Test func offlineSaysSoAndChangesNothing() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        f.transport.offline = true
        do {
            _ = try await f.fetcher.ensure(f.component, in: f.root)
            Issue.record("an offline fetch must throw")
        } catch let e as ComponentError {
            #expect(e == .offline(component: "the test model", size: "under 1 MB", without: "Nothing else changes."))
            let said = e.localizedDescription
            #expect(said.contains("offline"))
            #expect(said.contains("the test model"))
            #expect(said.contains("Nothing else changes."))
            #expect(said.contains("try again"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
        // Back online, the same call works: offline is not remembered.
        f.transport.offline = false
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
    }

    @Test func aServerErrorIsReportedAsOne() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        f.transport.serve(f.component, [:])       // every file is a 404
        await #expect(throws: ComponentError.server(component: "the test model", status: 404)) {
            try await f.fetcher.ensure(f.component, in: f.root)
        }
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))
    }

    @Test func aHalfThereFolderIsCompletedNotReplaced() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        // What FluidAudio's own interrupted download leaves: some files
        // right, one missing, one wrong — and a file of its own beside them.
        try FileManager.default.createDirectory(at: f.folder.appendingPathComponent("Encoder.mlmodelc"),
                                                withIntermediateDirectories: true)
        try f.contents["config.json"]!.write(to: f.folder.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 5_000).write(to: f.folder.appendingPathComponent("Encoder.mlmodelc/model.mil"))
        try Data("theirs".utf8).write(to: f.folder.appendingPathComponent("other.json"))
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .incomplete)

        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .fetched)
        #expect(f.installedMatches())
        // The right file was not downloaded again; the wrong and the missing were.
        #expect(!f.transport.calls.contains { $0.url.hasSuffix("config.json") })
        #expect(f.transport.calls.count == 2)
        #expect((try? Data(contentsOf: f.folder.appendingPathComponent("other.json"))) == Data("theirs".utf8))
        #expect(!f.everything().contains { $0.contains(".memoe-fetch") })
    }

    @Test func twoCallersShareOneDownload() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        f.transport.delay = 30_000_000
        async let a = f.fetcher.ensure(f.component, in: f.root)
        async let b = f.fetcher.ensure(f.component, in: f.root)
        let outcomes = try await [a, b]
        #expect(outcomes == [.fetched, .fetched])
        #expect(f.transport.calls.count == 3)
        #expect(f.installedMatches())
    }

    @Test func aTopUpNeverUsesAMeteredConnection() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        _ = try await f.fetcher.ensure(f.component, in: f.root, why: .topUp)
        #expect(f.transport.calls.allSatisfy { !$0.expensive })
        let g = Fixture(); defer { g.cleanUp() }
        _ = try await g.fetcher.ensure(g.component, in: g.root)
        #expect(g.transport.calls.allSatisfy { $0.expensive })
    }

    // MARK: keep — the release before the slim one

    private func bundleCopy(_ f: Fixture, _ contents: [String: Data]) throws -> URL {
        let bundle = f.root.appendingPathComponent("Memoe.app/Contents/Resources/Models/test-model")
        for (path, data) in contents {
            let to = bundle.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: to)
        }
        try FileManager.default.createSymbolicLink(at: f.folder, withDestinationURL: bundle)
        return bundle
    }

    @Test func keepCopiesTheAppsModelOutSoItOutlivesTheApp() async throws {
        let f = Fixture(); defer { f.cleanUp() }
        let bundle = try bundleCopy(f, f.contents)
        #expect(ComponentFetcher.keep(f.component, in: f.root) == .copiedOut)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.folder.path)) == nil)
        #expect(f.installedMatches())

        // The update: the app that carried it is replaced by one that does not.
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Memoe.app"))
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        f.transport.offline = true
        #expect(try await f.fetcher.ensure(f.component, in: f.root) == .alreadyPresent)
        #expect(f.transport.calls.isEmpty)
        #expect(f.installedMatches())
        // Once it is a real folder there is nothing more to do.
        #expect(ComponentFetcher.keep(f.component, in: f.root) == .nothingToDo)
    }

    @Test func withoutKeepTheSameUpdateLosesIt() async throws {
        // The falsifier for the test above: skip `keep`, and the component
        // really is gone after the update. If this ever passes as "present",
        // the test above proves nothing.
        let f = Fixture(); defer { f.cleanUp() }
        _ = try bundleCopy(f, f.contents)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("Memoe.app"))
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .danglingLink)
    }

    @Test func keepRefusesAModelThatIsNotThePinnedOne() throws {
        let f = Fixture(); defer { f.cleanUp() }
        var other = f.contents
        other[f.big]![7] ^= 1
        let bundle = try bundleCopy(f, other)
        guard case .refused = ComponentFetcher.keep(f.component, in: f.root) else {
            Issue.record("a model that does not match the manifest must not be kept as if it did")
            return
        }
        // The link is exactly as it was, so the app still works from its own copy.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.folder.path)) == bundle.path)
        #expect(!f.everything().contains { $0.contains(".memoe-fetch") })
        // …and not the empty staging directory either: `everything()` lists
        // files, so it could not see the one a refusal used to leave.
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".memoe-fetch").path))
    }

    @Test func aKeepThatDiedHalfWayIsStartedAgainNotTrusted() throws {
        // What a launch killed mid-copy leaves: the link untouched, and a
        // staging folder holding part of the model — here every file, with
        // the big one cut short. The next launch must not move that into
        // place because a folder of the right name is sitting there.
        let f = Fixture(); defer { f.cleanUp() }
        _ = try bundleCopy(f, f.contents)
        let half = f.root.appendingPathComponent(".memoe-fetch/test-model.keeping")
        for (path, data) in f.contents {
            let to = half.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (path == f.big ? data.prefix(data.count / 2) : data).write(to: to)
        }
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .present)   // through the link
        #expect(ComponentFetcher.keep(f.component, in: f.root) == .copiedOut)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: f.folder.path)) == nil)
        #expect(f.installedMatches())
        #expect(!f.everything().contains { $0.contains(".memoe-fetch") })
    }

    @Test func aKeepTheDiskRefusesLeavesTheLinkExactlyAsItWas() throws {
        // A full disk, a read-only volume: the copy cannot be made. The app
        // must go on working from its own copy, with nothing half-made left.
        let f = Fixture(); defer { f.cleanUp() }
        let bundle = try bundleCopy(f, f.contents)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path) }
        guard case .refused = ComponentFetcher.keep(f.component, in: f.root) else {
            Issue.record("a keep that could not write anything reported something other than refused")
            return
        }
        #expect((try? fm.destinationOfSymbolicLink(atPath: f.folder.path)) == bundle.path)
        #expect(ComponentFetcher.presence(of: f.component, in: f.root) == .present)
        #expect(!f.everything().contains { $0.contains(".memoe-fetch") })
    }

    @Test func keepLeavesAbsentAndRealFoldersAlone() throws {
        let f = Fixture(); defer { f.cleanUp() }
        #expect(ComponentFetcher.keep(f.component, in: f.root) == .nothingToDo)
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: f.folder.appendingPathComponent("config.json"))
        #expect(ComponentFetcher.keep(f.component, in: f.root) == .nothingToDo)
        #expect((try? Data(contentsOf: f.folder.appendingPathComponent("config.json"))) == Data("x".utf8))
    }
}

@Suite struct ComponentCatalogTests {

    /// The repository root, from this file's own path.
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyComponentIsPinnedToACommitAndHashedFileByFile() {
        #expect(!ComponentCatalog.all.isEmpty)
        for c in ComponentCatalog.all {
            #expect(!c.files.isEmpty)
            // …/resolve/<40 hex>/ — a commit, never `main`.
            let parts = c.base.pathComponents
            let revision = parts.last ?? ""
            #expect(parts.dropLast().last == "resolve")
            #expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit), "\(c.id) is pinned to '\(revision)'")
            #expect(c.base.scheme == "https")
            #expect(c.base.absoluteString.hasSuffix("/"))
            for file in c.files {
                #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit))
                #expect(file.bytes > 0)
                #expect(!file.path.hasPrefix("/") && !file.path.contains(".."))
                #expect(c.url(for: file).absoluteString == c.base.absoluteString + file.path)
            }
            #expect(Set(c.files.map(\.path)).count == c.files.count)
        }
        #expect(Set(ComponentCatalog.all.map(\.id)).count == ComponentCatalog.all.count)
    }

    @Test func theCatalogIsTheListBuildShLeavesOut() throws {
        // One list of what a slim build drops: ON_DEMAND_MODELS in
        // fetch-models.sh. build.sh removes exactly those folders, so a
        // folder there with no component here would ship an app that has
        // lost a model and has no way to get it back.
        let script = try String(contentsOf: Self.repo.appendingPathComponent("scripts/fetch-models.sh"), encoding: .utf8)
        let line = script.split(separator: "\n").first { $0.hasPrefix("ON_DEMAND_MODELS=\"") }
        let listed = Set((line ?? "").dropFirst("ON_DEMAND_MODELS=\"".count).dropLast().split(separator: " ").map(String.init))
        #expect(!listed.isEmpty)
        #expect(listed == Set(ComponentCatalog.all.map(\.folder)))
        #expect(Set(ComponentCatalog.manifest.keys) == listed)
        #expect(Set(ComponentCatalog.pins.keys) == listed)
    }

    @Test func sizesAreTheMeasuredOnes() {
        // Measured from the 0.3.24 bundle, 2026-11-12 (docs/SLIM-DOWNLOAD.md §1).
        #expect(ComponentCatalog.vocabularyBoost.bytes == 102_803_869)
        #expect(ComponentCatalog.vocabularyBoost.files.count == 16)
        #expect(ComponentCatalog.speakerDiarization.bytes == 13_987_593)
        #expect(ComponentCatalog.speakerDiarization.files.count == 13)
        #expect(ComponentCatalog.vocabularyBoost.size == "103 MB")
        #expect(ComponentCatalog.speakerDiarization.size == "14 MB")
    }

    @Test func anUnreadableModeIsOff() {
        #expect(OnDemandMode.read(nil) == .off)
        #expect(OnDemandMode.read([:]) == .off)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": "ON"]) == .off)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": "1"]) == .off)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": 1]) == .off)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": "off"]) == .off)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": "prepare"]) == .prepare)
        #expect(OnDemandMode.read(["MoeOnDemandComponents": "on"]) == .on)
    }
}
