import Foundation
import Testing
@testable import MoeVoice

/// The dead microphone of 2026-11-13, owner's Mac, macOS 27.2, build
/// ce033d23. From moe.log:
///
///     15:30:18Z audio: Chrome is on the microphone, voice processing off so it hears you
///     15:30:18Z audio: restart for voice processing failed (… -10875 …
///               IsFormatSampleRateAndChannelCountValid(outputHWFormat)); retrying plain
///     15:30:18Z audio: microphone restart 1 of 4 failed: Failed to create tap due to
///               format mismatch, <AVAudioFormat …: 2 ch, 44100 Hz, Float32, deinterleaved>
///     …
///     16:47:11Z audio: microphone restart without voice processing failed too: …2 ch, 44100 Hz…
///     16:47:11Z audio: MICROPHONE DEAD — every restart failed
///
/// The default input, the MacBook Pro Microphone, was 1 ch, 48000 Hz; with
/// voice processing on the same graph read 48000 Hz × 9 in.
@MainActor
struct MicEngineRenewalTests {

    static let microphone = AudioShape(sampleRate: 48_000, channels: 1)
    static let staleNode = AudioShape(sampleRate: 44_100, channels: 2)
    static let voiceProcessed = AudioShape(sampleRate: 48_000, channels: 9)

    // MARK: - The rule

    @Test func theMeasuredNodeIsStaleAgainstTheMeasuredMicrophone() {
        #expect(MicEngineRenewal.isStale(node: Self.staleNode, device: Self.microphone, voiceProcessing: false))
        #expect(MicEngineRenewal.after(node: Self.staleNode, device: Self.microphone, voiceProcessing: false)
                == .staleFormat(node: Self.staleNode, device: Self.microphone))
    }

    @Test func aPlainNodeThatMatchesTheMicrophoneIsKept() {
        #expect(MicEngineRenewal.after(node: Self.microphone, device: Self.microphone, voiceProcessing: false) == nil)
    }

    /// With voice processing on, 9 channels over a 1-channel microphone is
    /// the canceller's shape, not a stale node.
    @Test func voiceProcessingsChannelsAreNotStaleness() {
        #expect(MicEngineRenewal.after(node: Self.voiceProcessed, device: Self.microphone, voiceProcessing: true) == nil)
    }

    /// A device that cannot be read never costs a rebuild per start.
    @Test func anUnreadDeviceIsNeverStale() {
        #expect(MicEngineRenewal.after(node: Self.staleNode, device: nil, voiceProcessing: false) == nil)
    }

    @Test func voiceProcessingGoingOffTakesANewEngine() {
        #expect(MicEngineRenewal.before(lastStartFailed: false, voiceProcessingOnEngine: true,
                                        voiceProcessingWanted: false) == .voiceProcessingOff)
        #expect(MicEngineRenewal.before(lastStartFailed: false, voiceProcessingOnEngine: true,
                                        voiceProcessingWanted: true) == nil)
        #expect(MicEngineRenewal.before(lastStartFailed: false, voiceProcessingOnEngine: false,
                                        voiceProcessingWanted: false) == nil)
    }

    @Test func aFailedStartIsNeverRetriedOnTheSameEngine() {
        #expect(MicEngineRenewal.before(lastStartFailed: true, voiceProcessingOnEngine: false,
                                        voiceProcessingWanted: true) == .lastStartFailed)
    }

    // MARK: - The day, replayed

    struct TapMismatch: LocalizedError {
        let shape: AudioShape
        var errorDescription: String? { "Failed to create tap due to format mismatch, <AVAudioFormat: \(shape)>" }
    }

    /// One AVAudioEngine as it behaved on macOS 27.2: voice processing on
    /// reads 9 channels; switched off in place, the node reads 2 ch,
    /// 44100 Hz for the rest of its life and every tap on it is refused.
    final class MeasuredEngine {
        var voiceProcessing = false
        var node = MicEngineRenewalTests.microphone
        var poisoned = false
        func setVoiceProcessing(_ on: Bool) {
            if voiceProcessing, !on { poisoned = true }
            voiceProcessing = on
            node = poisoned ? MicEngineRenewalTests.staleNode
                : (on ? MicEngineRenewalTests.voiceProcessed : MicEngineRenewalTests.microphone)
        }
        func installTap() throws { if poisoned { throw TapMismatch(shape: node) } }
    }

    /// `AudioFrontEnd.start()`'s order: renew before, settle voice
    /// processing, read back, renew after, tap. `renew: false` is the code
    /// as it stood at ce033d23 — one engine for the life of the app.
    final class Graph {
        var engine = MeasuredEngine()
        var engines = 1
        var lastStartFailed = false
        var callOnMicrophone = false
        let renew: Bool
        var up = false
        init(renew: Bool) { self.renew = renew }

        func fresh() { engine = MeasuredEngine(); engines += 1; lastStartFailed = false }

        func start(plain: Bool) throws {
            do {
                let wanted = !plain && !callOnMicrophone
                if renew, MicEngineRenewal.before(lastStartFailed: lastStartFailed,
                                                  voiceProcessingOnEngine: engine.voiceProcessing,
                                                  voiceProcessingWanted: wanted) != nil { fresh() }
                engine.setVoiceProcessing(wanted)
                if renew, MicEngineRenewal.after(node: engine.node, device: MicEngineRenewalTests.microphone,
                                                 voiceProcessing: wanted) != nil {
                    fresh(); engine.setVoiceProcessing(wanted)
                }
                try engine.installTap()
                lastStartFailed = false
                up = true
            } catch {
                lastStartFailed = true
                throw error
            }
        }

        /// The graph was up with voice processing; Chrome takes the
        /// microphone; the call watchdog restarts it plain, then — on a
        /// throw — the recovery ladder runs.
        func chromeTakesTheMicrophone() async -> CaptureRecovery.Outcome {
            try? start(plain: false)
            up = false
            callOnMicrophone = true
            do { try start(plain: false); return .restarted(plain: false, attempts: 0) } catch {}
            return await CaptureRecovery.run(sleep: { _ in }, stillWanted: { !self.up },
                                             start: { try self.start(plain: $0) })
        }
    }

    /// The fix: the restart that turns voice processing off gets a new
    /// engine, and the microphone comes straight back.
    @Test func chromeTakingTheMicrophoneNoLongerKillsIt() async {
        let graph = Graph(renew: true)
        let outcome = await graph.chromeTakesTheMicrophone()
        #expect(outcome == .restarted(plain: false, attempts: 0))
        #expect(graph.up)
        #expect(graph.engine.node == Self.microphone)
        #expect(graph.engines == 2)
    }

    /// The control: the same morning on one engine is the log above — every
    /// rung of the ladder refused with the 2 ch / 44.1 kHz format.
    @Test func onOneEngineEveryRungFailsAsItDid() async {
        let graph = Graph(renew: false)
        let outcome = await graph.chromeTakesTheMicrophone()
        guard case .failed(let why) = outcome else {
            Issue.record("expected the measured failure, got \(outcome)"); return
        }
        #expect(why.contains("2 ch, 44100 Hz"))
        #expect(!graph.up)
    }

    /// Whatever poisoned an engine, the next hold press gets a new one: the
    /// 16:47 press found the 15:30 engine still broken.
    @Test func aLaterPressAfterAFailureStartsOnANewEngine() throws {
        let graph = Graph(renew: true)
        graph.engine.poisoned = true
        graph.engine.node = Self.staleNode
        #expect(throws: TapMismatch.self) {
            // A poisoned engine whose node happens to read right is still
            // refused once…
            graph.engine.node = Self.voiceProcessed
            try graph.start(plain: false)
        }
        // …and the next start is on a new one.
        try graph.start(plain: false)
        #expect(graph.up)
    }

    // MARK: - The sidebar

    @Test func theSidebarNeverSaysReadyOverADeadMicrophone() {
        #expect(VoiceStatus.sidebar(modelsReady: true, microphoneDead: true) == (false, "Microphone not working"))
        #expect(VoiceStatus.sidebar(modelsReady: true, microphoneDead: false) == (true, "Voice ready"))
        #expect(VoiceStatus.sidebar(modelsReady: false, microphoneDead: false) == (false, "Voice loading…"))
    }
}
