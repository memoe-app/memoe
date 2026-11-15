import Foundation
import Testing
@testable import MoeVoice

/// Which Smart Turn file a launch uses, and that a better model can be put in
/// front of v3.2 without ever losing it or waiting on the network.
struct TurnModelCatalogTests {

    typealias C = TurnModelCatalog

    /// A stand-in for a model listed before v3.2, pinned by hash.
    private let candidate = C.Model(name: "candidate", file: "candidate.onnx",
                                    url: URL(string: "https://example.invalid/candidate.onnx")!,
                                    sha256: String(repeating: "a", count: 64), bytes: 0)

    /// What ships is exactly the file Moe always loaded: v3.2, from Hugging
    /// Face — now from a named commit and pinned to its hash, which is Hugging
    /// Face's LFS record for the file and `shasum -a 256` of the copy on the
    /// owner's Mac (8,679,182 bytes), read 2026-11-12.
    @Test func v32IsWhatShipsAndItIsPinned() {
        #expect(C.preference == [C.upstream])
        #expect(C.upstream.file == "smart-turn-v3.2-cpu.onnx")
        #expect(C.upstream.url.absoluteString == "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/f766f81d3cfdf7737ac64aad813d91bbfd56bf93/smart-turn-v3.2-cpu.onnx")
        #expect(C.upstream.sha256 == "2bb026316b14a660486a75b1733cd3fbab8c2fd0314dc9af7be49f8cca967e4f")
        #expect(C.upstream.bytes == 8_679_182)
        // Not `main`: the bytes behind a branch can change under the hash.
        #expect(!C.upstream.url.path.contains("/resolve/main/"))
        // Nothing the app would download is unpinned.
        #expect(C.preference.allSatisfy { $0.sha256?.count == 64 })
    }

    /// The right size and the wrong bytes is not the model. It used to be
    /// "plausibly a model" and loaded.
    @Test func aFileThatIsNotThePinnedOneIsRefused() {
        let impostor = Data(repeating: 7, count: C.upstream.bytes)
        #expect(!C.accepts(C.upstream, data: impostor))
        let why = C.rejection(C.upstream, data: impostor)
        #expect(why?.contains("is not the pinned 2bb026316b14") == true)
        #expect(why?.contains(C.sha256Hex(impostor)) == true)
        #expect(C.rejection(C.upstream, data: Data(repeating: 7, count: 1000)) == "1000 bytes is not a model")
    }

    // MARK: Retrying the load

    /// A download that does not hash is refused and tried again later — and
    /// the session is not left on the silence timer when the next one is good.
    @Test func aHashMismatchIsRefusedAndRetried() async {
        let good = Data(repeating: 3, count: 1_200_000)
        let model = C.Model(name: "pinned", file: "pinned.onnx", url: URL(string: "https://example.invalid/pinned.onnx")!,
                            sha256: C.sha256Hex(good), bytes: good.count)
        var tampered = good; tampered[100] = 4
        let server = Downloads([tampered, good])
        let seen = Seen()
        let attempts = await TurnModelRetry.run(
            load: {
                let data = await server.next()
                if let why = C.rejection(model, data: data) { throw C.Refused(model: model.name, why: why) }
                await seen.loaded(data)
            },
            sleep: { await seen.slept($0); return true },
            onFailure: { failures, error, retryIn in
                #expect(failures == 1)
                #expect(error is C.Refused)
                #expect(retryIn == 30)
            })
        #expect(attempts == 2)
        #expect(await seen.waits == [30])
        // The tampered file was never loaded; the good one was.
        #expect(await seen.loads == [good])
    }

    /// Offline all afternoon: the waits grow, then hold at half an hour.
    @Test func theWaitsGrowAndThenHold() async {
        let seen = Seen()
        let attempts = await TurnModelRetry.run(
            load: { if await seen.waits.count < 6 { throw URLError(.notConnectedToInternet) } },
            sleep: { await seen.slept($0); return true },
            onFailure: { _, _, _ in })
        #expect(attempts == 7)
        #expect(await seen.waits == [30, 120, 600, 1800, 1800, 1800])
        #expect(TurnModelRetry.delay(afterFailures: 0) == 30)
        #expect(TurnModelRetry.delay(afterFailures: 99) == 1800)
    }

    /// A cancelled wait ends it without another attempt.
    @Test func aCancelledWaitStops() async {
        let seen = Seen()
        let attempts = await TurnModelRetry.run(
            load: { await seen.loaded(Data()); throw URLError(.timedOut) },
            sleep: { _ in false },
            onFailure: { _, _, _ in })
        #expect(attempts == nil)
        #expect(await seen.loads.count == 1)
    }

    actor Downloads {
        private var bodies: [Data]
        init(_ bodies: [Data]) { self.bodies = bodies }
        func next() -> Data { bodies.removeFirst() }
    }

    actor Seen {
        var waits: [Double] = []
        var loads: [Data] = []
        func slept(_ s: Double) { waits.append(s) }
        func loaded(_ d: Data) { loads.append(d) }
    }

    /// A fresh Mac downloads the preferred model first and falls back in order.
    @Test func aFreshMacFetchesInOrder() {
        let plan = C.loadPlan([candidate, C.upstream]) { _ in false }
        #expect(plan.attempts.map(\.model.name) == ["candidate", "smart-turn-v3.2"])
        let allDownload = plan.attempts.allSatisfy { $0.download }
        #expect(allDownload)
        #expect(plan.fetchLater.isEmpty)
    }

    /// A Mac holding only v3.2 loads it straight away — voice does not wait on
    /// a download — and fetches the preferred one in the background.
    @Test func whatIsOnDiskLoadsFirstAndTheRestComesLater() {
        let plan = C.loadPlan([candidate, C.upstream]) { $0 == C.upstream }
        #expect(plan.attempts.first == .init(model: C.upstream, download: false))
        #expect(plan.attempts.map(\.model.name) == ["smart-turn-v3.2", "candidate"])
        #expect(plan.fetchLater == [candidate])
        let both = C.loadPlan([candidate, C.upstream]) { _ in true }
        #expect(both.attempts.first == .init(model: candidate, download: false))
        #expect(both.fetchLater.isEmpty)
    }

    /// A pinned model is checked by hash, so a truncated or substituted file is
    /// refused — v3.2 included; only a model named by path is taken on size.
    @Test func aPinnedModelIsCheckedByHash() {
        let junk = Data(repeating: 7, count: 2_000_000)
        #expect(!C.accepts(candidate, data: junk))
        #expect(!C.accepts(C.upstream, data: junk))
        #expect(!C.accepts(C.upstream, data: Data(repeating: 7, count: 1000)))
        #expect(C.accepts(C.order(override: "/tmp/some-model.onnx")[0], data: junk))
        let pinned = C.Model(name: "x", file: "x.onnx", url: URL(string: "https://example.invalid/x")!,
                             sha256: C.sha256Hex(junk), bytes: junk.count)
        #expect(C.accepts(pinned, data: junk))
        var one = junk; one[0] = 8
        #expect(!C.accepts(pinned, data: one))
    }

    /// The benches pin a model by name or path, and nothing else is tried.
    @Test func anOverridePinsOneModel() {
        #expect(C.order(override: nil) == C.preference)
        #expect(C.order(override: " ") == C.preference)
        #expect(C.order(override: "smart-turn-v3.2").map(\.name) == ["smart-turn-v3.2"])
        let byPath = C.order(override: "/tmp/some-model.onnx")
        #expect(byPath.count == 1 && byPath[0].url.isFileURL && byPath[0].name == "some-model")
    }
}
