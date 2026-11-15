import Foundation
import Testing
@testable import Moe

/// 2026-09-25 16:49: the weekly limit, asked by voice, answered by silence.
struct SpokenErrorTests {

    @Test func theWeeklyLimitIsSaidPlainly() {
        let line = SpokenError.line(for: "claude turn failed: You've hit your weekly limit · resets Sep 26 at 10pm (America/New_York)")
        #expect(line == "I couldn't answer that. You've hit your weekly limit. Resets Sep 26 at 10pm.")
    }

    @Test func aLongErrorStopsAtASentence() {
        let long = "The model is overloaded. " + String(repeating: "More detail follows here. ", count: 20)
        let line = SpokenError.line(for: long)
        #expect(line.count < 200)
        #expect(line.hasSuffix("."))
    }

    @Test func nothingAtAllStillSaysSomething() {
        #expect(SpokenError.line(for: "   ") == "Something went wrong and I couldn't answer that.")
    }

    /// The Conductor speaks it on a spoken turn, before the reply is called
    /// finished — otherwise the window opens over silence.
    @Test func theConductorSaysItBeforeTheWindowOpens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Conductor.swift"), encoding: .utf8)
        let arm = try #require(source.components(separatedBy: "case .error(let message):").dropFirst().first?
            .components(separatedBy: "case .failedToLaunch").first)
        let said = try #require(arm.range(of: "self.voice.speak(SpokenError.line(for: message, needsSignIn: self.needsSignIn))"))
        let finished = try #require(arm.range(of: "self.voice.replyFinished()"))
        #expect(said.lowerBound < finished.lowerBound)
        #expect(arm.contains("if self.replySpeaks"))
    }
}
