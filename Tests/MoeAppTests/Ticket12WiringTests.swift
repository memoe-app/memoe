import Foundation
import Testing

/// Ticket #12's three fixes, pinned where they are wired. The rules are
/// tested in MoeVoice and MoeIsland (`CallMicDebounceTests`,
/// `PremiumVoiceSpentTests`, `TranscriptRevealTests`); the audio graph, the
/// player and the island are in the executable target and cannot be built
/// without a live audio device and a screen, so what these pin is that the
/// app consults those rules rather than its old inline ones.
struct Ticket12WiringTests {

    private static func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func slice(_ source: String, from start: String, to end: String) -> Substring? {
        guard let a = source.range(of: start) else { return nil }
        let rest = source[a.upperBound...]
        guard let b = rest.range(of: end) else { return nil }
        return rest[..<b.lowerBound]
    }

    /// The call watchdog decides through the debouncer, knows whether Moe is
    /// talking, and a browser no longer takes the canceller at `start()`.
    @Test func theCallWatchdogIsDebounced() throws {
        let fe = try Self.source("Sources/Moe/Voice/AudioFrontEnd.swift")
        let watch = try #require(Self.slice(fe, from: "private func watchCallApps()", to: "// MARK: - Bypass"))
        #expect(watch.contains("self.callDebounce.observe("))
        #expect(watch.contains("speaking: self.playbackBusy()"))
        #expect(!watch.contains("calls.isEmpty"), "the watchdog flips on a single poll again")

        let start = try #require(Self.slice(fe, from: "private func startGraph() throws {", to: "var micFormat"))
        #expect(start.contains("!$0.isBrowser"), "a browser's grab turns the canceller off at start again")
        #expect(start.contains("callHolding == nil"))

        let engine = try Self.source("Sources/Moe/Voice/VoiceEngine.swift")
        #expect(engine.contains("frontEnd.playbackBusy = { [weak self] in self?.speech.busy ?? false }"),
                "the watchdog cannot tell a restart would cut Moe off")
    }

    /// Out of credits: remembered, the pump goes local, the notice is given
    /// once and reaches the conversation.
    @Test func runningOutOfCreditsIsHandledAndSaid() throws {
        let speech = try Self.source("Sources/Moe/Voice/SpeechOut.swift")
        let pump = try #require(Self.slice(speech, from: "private func startPump()", to: "private func render("))
        #expect(pump.contains("if self.premiumSpent || self.localForReply, self.backend?.isCloudBackend == true"),
                "every batch asks the spent voice again")
        let render = try #require(Self.slice(speech, from: "private func render(", to: "private func takeHeldTail("))
        #expect(render.contains("PremiumVoiceSpent.matches(error)"))
        #expect(render.contains("premiumSpent = true"))
        #expect(render.contains("onNotice?(PremiumVoiceSpent.notice)"))
        #expect(render.contains("if !spentNoticeGiven"), "the notice would be given every sentence")

        let engine = try Self.source("Sources/Moe/Voice/VoiceEngine.swift")
        #expect(engine.contains("speech.onNotice = { [weak self] m in self?.onNotice?(m) }"))
        let conductor = try Self.source("Sources/Moe/Conductor.swift")
        let notice = try #require(Self.slice(conductor, from: "voice.onNotice = {", to: "voice.onLoadProgress"))
        #expect(notice.contains("turns.append(Turn(role: .system, text: message))"))
        #expect(!notice.contains("mode = .idle"), "a notice must not end the turn it arrives in")
    }

    /// The transcript opens the panel for Moe's answer, both when it starts
    /// speaking and when the reply lands.
    @Test func theTranscriptShowsMoesAnswer() throws {
        let island = try Self.source("Sources/Moe/NotchIsland.swift")
        let observer = try #require(Self.slice(island, from: "transcriptObserver = Publishers", to: "self.watchForOutsideClick()"))
        #expect(observer.contains("ReplyReveal.transcriptOpens("))
        #expect(observer.contains("speaking: mode == .speaking"))
        let reveal = try #require(Self.slice(island, from: "func revealReply() {", to: "orderFrontRegardless"))
        #expect(reveal.contains("transcriptOn: conductor.showsTranscript"))
    }
}
