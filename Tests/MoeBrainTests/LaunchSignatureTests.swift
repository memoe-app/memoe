import Foundation
import Testing
@testable import MoeBrain

struct LaunchSignatureTests {

    @Test func theSameThreeThingsAreTheSameSignature() {
        let a = LaunchSignature(systemPrompt: "You are Moe.", provider: "claude-code-cli", model: "sonnet")
        #expect(a == LaunchSignature(systemPrompt: "You are Moe.", provider: "claude-code-cli", model: "sonnet"))
        #expect(a.changes(since: a).isEmpty)
    }

    @Test func eachOfTheThreeIsNamedWhenItMoves() {
        let a = LaunchSignature(systemPrompt: "You are Moe.", provider: "claude-code-cli", model: "sonnet")
        #expect(LaunchSignature(systemPrompt: "You are Moe!", provider: "claude-code-cli", model: "sonnet")
            .changes(since: a) == ["the system prompt (12 → 12 characters)"])
        #expect(LaunchSignature(systemPrompt: "You are Moe.", provider: "claude-code-cli", model: "opus")
            .changes(since: a) == ["the model (sonnet → opus)"])
        #expect(LaunchSignature(systemPrompt: "You are Moe.", provider: "anthropic", model: "sonnet")
            .changes(since: a) == ["the provider (claude-code-cli → anthropic)"])
    }

    /// Read back out of the body that is sent — and blind, on purpose, to
    /// everything that is allowed to differ between two turns.
    @Test func itIsReadFromTheRequestBodyAndIgnoresWhatMayDiffer() throws {
        func body(user: Any, options: [String: Any]?) throws -> Data {
            var b: [String: Any] = ["stream": true, "model": "sonnet", "provider": "claude-code-cli",
                                    "messages": [["role": "system", "content": "You are Moe."],
                                                 ["role": "user", "content": user]]]
            if let options { b["model_options"] = options }
            return try JSONSerialization.data(withJSONObject: b)
        }
        let spoken = try #require(LaunchSignature(requestBody: try body(user: "what's up", options: nil)))
        let typedWithPicture = try #require(LaunchSignature(requestBody: try body(
            user: [["type": "text", "text": "(Typed, not spoken: …) and this"],
                   ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]],
            options: ["reasoning_effort": "high"])))
        #expect(spoken == typedWithPicture)
        #expect(spoken == LaunchSignature(systemPrompt: "You are Moe.", provider: "claude-code-cli", model: "sonnet"))
        #expect(LaunchSignature(requestBody: Data("not json".utf8)) == nil)
        #expect(LaunchSignature(requestBody: nil) == nil)
    }

    /// The prompt itself never reaches a log line: a digest and a length.
    @Test func whatItSaysAboutAChangeCarriesNoneOfThePrompt() {
        let a = LaunchSignature(systemPrompt: "secret plover", provider: "p", model: "m")
        let b = LaunchSignature(systemPrompt: "secret plover and more", provider: "p", model: "m")
        #expect(!b.changes(since: a).joined().contains("plover"))
        #expect(a.promptDigest.count == 64)
    }
}
