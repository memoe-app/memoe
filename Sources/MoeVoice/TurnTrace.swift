import Foundation

/// One record per spoken turn: where the time went. VOICE-PLAN.md §7.
///
/// Durations only — never a word of what was said. Written as one JSON line
/// per turn so "it felt slow" can be answered with the number that was slow.
public struct TurnTrace: Codable, Equatable, Sendable {
    public var source: String
    public var startedAt: Date
    /// Milliseconds from `startedAt`, each set once when the moment arrives.
    public var speechStartMs: Int?
    public var speechEndMs: Int?
    public var turnDecidedMs: Int?
    public var decidedBy: String?
    public var transcribedMs: Int?
    public var submittedMs: Int?
    public var firstTokenMs: Int?
    public var firstAudioQueuedMs: Int?
    public var firstAudioHeardMs: Int?
    public var brainDoneMs: Int?
    public var lastAudioHeardMs: Int?
    public var bargedIn = false
    public var outcome: String?
    /// The wake head's score for the phrase that opened this turn, when a
    /// head opened it. A number, never a word — enough to tell a run of
    /// confident wakes from a run of marginal ones without recording the
    /// room. It is what makes a false-accept rate measurable off this Mac
    /// rather than only off a corpus. VOICE-PLAN.md §7.
    public var wakeScore: Double?
    /// The recogniser's own confidence in this turn's words, when the engine
    /// reports one (Parakeet does; Whisper has nothing comparable, so nil is
    /// a real answer). A number, never the words. Logged before anything
    /// gates on it, so the threshold comes from the distribution.
    public var confidence: Float?
    /// Why the turn ended, as the machine decided it (`VoiceMachine.EndReason`):
    /// key, eou, turn-model, stall, vad, verdict-hold, ceiling, cap,
    /// no-speech, no-words. `decidedBy` carries the same plus annotations.
    public var endpoint: String?
    /// Silero's probability over the capture: mean and highest, and how many
    /// 256 ms chunks that was. Numbers, never audio.
    public var vadMeanP: Double?
    public var vadMaxP: Double?
    public var vadChunks: Int?
    /// The room's noise floor when the turn ended, dBFS.
    public var noiseFloorDb: Double?
    /// Every Smart Turn probability asked in this turn, in order — including
    /// the ones the words or a VAD edge made stale.
    public var turnModelP: [Double]?
    /// How many of those were asked because the words stalled.
    public var stallAsks: Int?
    /// For a row that is not a turn but a VAD onset the machine refused to
    /// act on: where it landed (speaking, thinking, deciding, followUp) and
    /// how many words the recogniser had written when it was let go.
    public var onsetWindow: String?
    public var onsetWords: Int?
    /// For a barge-in (a row of its own, or the turn it became): whether
    /// it was taken, which check decided (`BargeInDecision.Check`), and
    /// the numbers that check read. Numbers, never the words.
    public var bargeInTaken: Bool?
    public var bargeInCheck: String?
    public var bargeInLevel: Double?
    public var bargeInOwner: Double?
    public var bargeInEcho: Double?
    /// The owner gate's score on this turn and what it did ("shadow" when
    /// it would have dropped the turn but is not enforcing, "drop", "pass").
    public var ownerGateScore: Double?
    public var ownerGate: String?
    /// Pauses inside this turn that the person talked through (`TurnPauses`),
    /// in ms — labelled holds. On a held-key turn, every pause before the
    /// release.
    public var holdsMs: [Int]?
    /// On a continuation ("the pause was a breath"): the quiet from the last
    /// word before the decision to the person going on, in ms. The decision
    /// was a false endpoint and this is the hold it cut.
    public var continuedAfterMs: Int?
    /// What the words said at the last verdict (`TurnSemantics.Reading`) and
    /// who said it ("rules" or "model"). Never the words.
    public var semantic: String?
    public var semanticSource: String?
    /// Which brain answered (`BrainProviderKind.rawValue`: claude-code-cli,
    /// openai-codex, anthropic, …) and on which model, so the routes can be
    /// timed apart. Until 2026-10-30 every row was the owner's Claude plan
    /// and nothing said so; the ChatGPT plan and key routes had no numbers.
    public var brain: String?
    public var model: String?

    public init(source: String, startedAt: Date = Date()) {
        self.source = source
        self.startedAt = startedAt
    }

    /// The brain's first token of the reply to this turn. Once per turn,
    /// and only on a turn that asked something: an interruption's trace has
    /// no submit, and deltas arriving for it belong to the reply it
    /// interrupted. Until 2026-09-23 nothing set this at all — 232 of 232
    /// rows on the owner's Mac had no first token, so brain latency and
    /// voice latency could not be told apart (research-eval-harness.md §2).
    /// Returns whether it was set.
    @discardableResult
    public mutating func noteFirstToken(at now: Date = Date()) -> Bool {
        guard firstTokenMs == nil, submittedMs != nil else { return false }
        firstTokenMs = ms(now)
        return true
    }

    public func ms(_ now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(startedAt) * 1000)
    }

    /// The number that describes how fast Moe feels: the gap between the
    /// user stopping and the first word being heard.
    public var feltLatencyMs: Int? {
        guard let end = speechEndMs ?? turnDecidedMs, let heard = firstAudioHeardMs else { return nil }
        // A negative gap means the two marks belong to different turns —
        // a reply that was still playing when this turn's speech ended,
        // say. Not a measurement of anything.
        let felt = heard - end
        return felt >= 0 ? felt : nil
    }

    public func jsonLine() -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(self), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
