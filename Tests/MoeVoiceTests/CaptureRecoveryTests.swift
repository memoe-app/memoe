import Foundation
import Testing
@testable import MoeVoice

/// The microphone coming back after the graph went down under it: retried
/// with growing waits, then started without voice processing, and only then
/// reported. No device is opened — the ladder is handed its `start`.
@MainActor
struct CaptureRecoveryTests {

    struct Refused: LocalizedError { var errorDescription: String? { "device not ready" } }

    /// A stand-in for the graph: fails the first `failures` ordinary starts,
    /// and (optionally) every start that asks for voice processing.
    final class Graph {
        var failures: Int
        var refusesVoiceProcessing = false
        var refusesEverything = false
        var wanted = true
        var up = false
        var slept: [Double] = []
        var starts: [Bool] = []          // each attempt's `plain`
        var log: [String] = []
        init(failures: Int) { self.failures = failures }

        func start(plain: Bool) throws {
            starts.append(plain)
            if refusesEverything { throw Refused() }
            if !plain {
                if refusesVoiceProcessing { throw Refused() }
                if failures > 0 { failures -= 1; throw Refused() }
            }
            up = true
        }

        func recover() async -> CaptureRecovery.Outcome {
            await CaptureRecovery.run(sleep: { self.slept.append($0) },
                                      stillWanted: { self.wanted && !self.up },
                                      start: { try self.start(plain: $0) },
                                      log: { self.log.append($0) })
        }
    }

    /// What it replaced tried once, 300 ms after the change, and stayed deaf.
    @Test func aDeviceStillSettlingIsTriedAgainWithGrowingWaits() async {
        let graph = Graph(failures: 2)
        let outcome = await graph.recover()
        #expect(outcome == .restarted(plain: false, attempts: 3))
        #expect(graph.slept == [0.3, 1, 2])
        #expect(graph.starts == [false, false, false])
        #expect(graph.up)
        #expect(graph.log.count == 2)
    }

    @Test func theFirstTryStillComesAfterTheSettle() async {
        let graph = Graph(failures: 0)
        #expect(await graph.recover() == .restarted(plain: false, attempts: 1))
        #expect(graph.slept == [0.3])
    }

    /// Four tries over 7.3 s, then a plain microphone rather than a dead one.
    @Test func voiceProcessingRefusedFallsBackToAPlainMicrophone() async {
        let graph = Graph(failures: 0)
        graph.refusesVoiceProcessing = true
        let outcome = await graph.recover()
        #expect(outcome == .restarted(plain: true, attempts: 5))
        #expect(graph.slept == [0.3, 1, 2, 4])
        #expect(graph.starts == [false, false, false, false, true])
        #expect(graph.up)
    }

    /// One outcome to report, after everything — and the run ends: no loop.
    @Test func whenNothingStartsItFailsOnceAndStops() async {
        let graph = Graph(failures: 0)
        graph.refusesEverything = true
        let outcome = await graph.recover()
        #expect(outcome == .failed("device not ready"))
        #expect(graph.starts.count == CaptureRecovery.backoff.count + 1)
        #expect(!graph.up)
    }

    /// After a failure, the next configuration change is a fresh run from
    /// the top — and it succeeds on a device that now works.
    @Test func theNextChangeRecoversAfterAFailure() async {
        let graph = Graph(failures: 0)
        graph.refusesEverything = true
        #expect(await graph.recover() == .failed("device not ready"))
        graph.refusesEverything = false
        graph.slept = []; graph.starts = []
        #expect(await graph.recover() == .restarted(plain: false, attempts: 1))
        #expect(graph.slept == [0.3])
        #expect(graph.starts == [false])
    }

    /// Nobody wants the microphone any more (or something else brought it
    /// up) while the ladder waited: it stops without starting anything.
    @Test func aRunNobodyWantsStopsQuietly() async {
        let graph = Graph(failures: 1)
        var polls = 0
        let outcome = await CaptureRecovery.run(
            sleep: { graph.slept.append($0) },
            stillWanted: { polls += 1; return polls < 2 },
            start: { try graph.start(plain: $0) })
        #expect(outcome == .abandoned)
        #expect(graph.starts == [false])
        #expect(graph.slept == [0.3, 1])
    }

    @Test func theLadderIsBounded() {
        #expect(CaptureRecovery.backoff == [0.3, 1, 2, 4])
    }
}
