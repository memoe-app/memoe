import Foundation
import Testing
import MoeVoice
@testable import Moe

/// The dead microphone of 2026-11-13, as the person saw it: the chat showed
/// "Failed to create tap due to format mismatch, <AVAudioFormat …: 2 ch,
/// 44100 Hz, Float32, deinterleaved>" as two bubbles in the conversation —
/// one per hold press whose recovery ran out — while the sidebar still said
/// "Voice ready". Driven through the real Conductor, from the front end's
/// own report.
@MainActor
@Suite(.serialized)
struct MicrophoneDeadStatusTests {

    @Test func aDeadMicrophoneIsOneQuietStatusNotABubblePerFailure() throws {
        let (moe, _) = try StallGuardConductorTests.make()
        let before = moe.turns.count

        // Two hold presses, two exhausted ladders — as at 15:34 and 16:47.
        moe.voice.noteMicrophoneForTests(dead: true, message: AudioFrontEnd.deadMessage)
        moe.voice.noteMicrophoneForTests(dead: true, message: AudioFrontEnd.deadMessage)

        #expect(moe.turns.count == before, "a dead microphone put \(moe.turns.count - before) bubble(s) in the conversation")
        #expect(moe.statusLine == AudioFrontEnd.deadMessage)
        #expect(moe.microphoneDead)
        #expect(moe.voiceStatus.ok == false)
        #expect(moe.voiceStatus.text == "Microphone not working")
    }

    @Test func theStatusClearsWhenTheMicrophoneComesBack() throws {
        let (moe, _) = try StallGuardConductorTests.make()
        moe.voice.noteMicrophoneForTests(dead: true, message: AudioFrontEnd.deadMessage)
        moe.voice.noteMicrophoneForTests(dead: false)
        #expect(!moe.microphoneDead)
        #expect(moe.statusLine.isEmpty)
        #expect(moe.voiceStatus.text != "Microphone not working")
    }

    /// What the person reads is plain: none of AVFoundation's text.
    @Test func whatIsSaidCarriesNoEngineText() {
        for line in [AudioFrontEnd.deadMessage, AudioFrontEnd.silentMessage] {
            #expect(!line.contains("AVAudioFormat"))
            #expect(!line.contains("Exception"))
            #expect(!line.contains("44100"))
        }
    }
}
