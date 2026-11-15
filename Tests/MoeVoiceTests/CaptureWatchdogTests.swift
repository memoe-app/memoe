import Foundation
import Testing
@testable import MoeVoice

/// A running graph that delivers no buffers is restarted; a healthy one is
/// left alone; and it never loops.
struct CaptureWatchdogTests {

    /// ~47 buffers a second at 48 kHz × 1024 frames, looked at once a second.
    @Test func aHealthyStreamIsNeverRestarted() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 0, now: 0)
        var delivered = 0
        for second in 1...600 {
            delivered += 47
            #expect(dog.observe(delivered: delivered, speaking: false, now: Double(second)) == .healthy)
        }
        #expect(dog.restarts == 0)
    }

    @Test func twoSecondsOfNothingRestartsTheGraph() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 100, now: 10)
        #expect(dog.observe(delivered: 147, speaking: false, now: 11) == .healthy)
        #expect(dog.observe(delivered: 147, speaking: false, now: 12) == .waiting)
        #expect(dog.observe(delivered: 147, speaking: false, now: 13) == .restart(attempt: 1))
    }

    /// One slow look is not silence: a single buffer is a live microphone.
    @Test func aTrickleIsAStream() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 0, now: 0)
        for second in 1...30 {
            #expect(dog.observe(delivered: second, speaking: false, now: Double(second) * 1.9) == .healthy)
        }
    }

    /// A graph that has only just come up gets longer — five seconds — for
    /// its first buffer; once it has delivered, two seconds is the line.
    @Test func aFreshGraphIsGivenTimeToDeliver() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 0, now: 100)
        #expect(dog.observe(delivered: 0, speaking: false, now: 102) == .waiting)
        #expect(dog.observe(delivered: 0, speaking: false, now: 104.9) == .waiting)
        #expect(dog.observe(delivered: 0, speaking: false, now: 105) == .restart(attempt: 1))
    }

    /// Three restarts, each a full five seconds after the last, then one give-up
    /// and silence — however long the microphone stays dead.
    @Test func itIsBoundedAndSaysSoOnce() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 5, now: 0)
        var verdicts: [CaptureWatchdog.Verdict] = []
        var t = 0.0
        while t < 3600 {
            t += 1
            let v = dog.observe(delivered: 5, speaking: false, now: t)
            if case .restart = v { dog.graphStarted(delivered: 5, now: t) }
            if v != .waiting { verdicts.append(v) }
        }
        #expect(verdicts == [.restart(attempt: 1), .restart(attempt: 2), .restart(attempt: 3), .giveUp])
    }

    /// Buffers arriving again end the spell: the next one starts from one.
    @Test func recoveryResetsTheCount() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 0, now: 0)
        #expect(dog.observe(delivered: 0, speaking: false, now: 5) == .restart(attempt: 1))
        #expect(dog.restarts == 1)
        dog.graphStarted(delivered: 0, now: 5.5)
        #expect(dog.observe(delivered: 40, speaking: false, now: 6.5) == .healthy)
        #expect(dog.restarts == 0)
        #expect(dog.observe(delivered: 40, speaking: false, now: 7.5) == .waiting)
        #expect(dog.observe(delivered: 40, speaking: false, now: 8.5) == .restart(attempt: 1))
    }

    /// …and after a give-up too: a microphone that comes back is watched again.
    @Test func aGiveUpIsNotForever() {
        var dog = CaptureWatchdog()
        dog.maxRestarts = 1
        dog.graphStarted(delivered: 0, now: 0)
        #expect(dog.observe(delivered: 0, speaking: false, now: 5) == .restart(attempt: 1))
        #expect(dog.observe(delivered: 0, speaking: false, now: 10) == .giveUp)
        #expect(dog.observe(delivered: 0, speaking: false, now: 60) == .waiting)
        #expect(dog.observe(delivered: 9, speaking: false, now: 61) == .healthy)
        #expect(dog.observe(delivered: 9, speaking: false, now: 63) == .restart(attempt: 1))
    }

    /// A restart stops the player. Never under a reply.
    @Test func itWaitsForMoeToFinishSpeaking() {
        var dog = CaptureWatchdog()
        dog.graphStarted(delivered: 0, now: 0)
        #expect(dog.observe(delivered: 3, speaking: true, now: 1) == .healthy)
        #expect(dog.observe(delivered: 3, speaking: true, now: 3) == .waiting)
        #expect(dog.observe(delivered: 3, speaking: true, now: 9) == .waiting)
        #expect(dog.observe(delivered: 3, speaking: false, now: 10) == .restart(attempt: 1))
    }
}
