import CryptoKit
import Foundation

/// What a turn carries that the brain's process was **started** with.
///
/// On the plan route the model runs in a child process whose system prompt
/// and model are fixed when it is spawned. A request that names a different
/// one does not get a different answer from the same process; it gets a new
/// process, under the turn, and the person waits for it: 5.9–6.9 s, measured
/// over 519 real turns (docs/SPEED-FINDINGS-2026-11-12.md), on 11% of them
/// and 22% in the last month of that sample.
///
/// So everything that changes from one turn to the next — the clock, the
/// brief, the delivery rules, whether it was typed or spoken, how hard to
/// think — rides on the turn's own message or its per-request options, and
/// **this** is the part that must stay still: the system message, the
/// provider and the model. `LaunchSignatureTests` builds two consecutive
/// ordinary turns through the real request path with everything volatile
/// changed between them and fails if these three move.
///
/// Reasoning effort is deliberately not here. It is a per-request option on
/// every route: an API route applies it to the call, and the plan route's
/// child takes it on its control channel without restarting.
public struct LaunchSignature: Equatable, Sendable {
    /// SHA-256 of the system message, hex. The text itself is 30–60 KB and
    /// is never logged; its digest and length are enough to say it moved.
    public let promptDigest: String
    public let promptLength: Int
    public let provider: String
    public let model: String

    public init(systemPrompt: String, provider: String, model: String) {
        promptDigest = SHA256.hash(data: Data(systemPrompt.utf8)).map { String(format: "%02x", $0) }.joined()
        promptLength = systemPrompt.count
        self.provider = provider
        self.model = model
    }

    /// The signature of a `/v1/chat/completions` body as it is about to be
    /// sent — read back out of the JSON, so it is what Hermes will see and
    /// not what the caller meant to send. nil for a body that is not one.
    public init?(requestBody: Data?) {
        guard let requestBody,
              let body = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]] else { return nil }
        let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
        self.init(systemPrompt: system,
                  provider: body["provider"] as? String ?? "",
                  model: body["model"] as? String ?? "")
    }

    /// What moved since `earlier`, in words for the log. Empty when nothing did.
    public func changes(since earlier: LaunchSignature) -> [String] {
        var out: [String] = []
        if promptDigest != earlier.promptDigest {
            out.append("the system prompt (\(earlier.promptLength) → \(promptLength) characters)")
        }
        if provider != earlier.provider { out.append("the provider (\(earlier.provider) → \(provider))") }
        if model != earlier.model { out.append("the model (\(earlier.model) → \(model))") }
        return out
    }
}
