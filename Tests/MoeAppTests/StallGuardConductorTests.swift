import Foundation
import Testing
import MoeVoice
import MoeLedger
@testable import Moe

/// docs/FIXABLE-FAILURES.md bug 9, driven through the real Conductor.
///
/// A stand-in brain records what the Conductor sends it and replays what a
/// brain would say back — the same `BrainEvent`s `HermesBrain` emits, with
/// the same `TurnEnd` it gives each way a turn can end. Nothing here is a
/// read of the source: the turn is submitted, the reply arrives, and the
/// test looks at what the Conductor then sent, and what is on screen.
///
/// The real stalled reply, 2026-09-23 21:39:09Z, is the promise below.
@MainActor
@Suite(.serialized)
struct StallGuardConductorTests {

    static let promise = "Good, the browser's loading Google Flights now — one sec while I set the Hanoi to Kunming search for around October 30th."

    // MARK: - The model stopped on a promise

    @Test func aPromiseThatEndsTheTurnGetsOneContinuation() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight from Hanoi to Kunming around October 30th", origin: .typed, starter: .person)
        try await brain.waitForSends(1)

        brain.reply(Self.promise, end: .answered)
        #expect(brain.sent.count == 2, "the stall guard sent nothing")
        let note = try #require(brain.sent.last)
        #expect(note.text.hasPrefix("(Background note, not from the person"))
        #expect(note.text.contains("one sec while I set the Hanoi to Kunming search"))
        #expect(!note.silent, "the continuation's answer has to reach the person")
        #expect(moe.isAwaitingReplyForTests, "the Conductor must be owed the continuation's answer")

        // Nothing of it is put in the thread as the person's.
        #expect(moe.turns.filter { $0.role == .you }.count == 1)
    }

    /// The continuation's answer goes on the end of the promise: one answer,
    /// so ⏸ ↺ and a barge-in all find the reply they belong to.
    @Test func theContinuationWritesOnTheEndOfTheSameAnswer() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply(Self.promise, end: .answered)
        brain.reply("The cheapest is VietJet at $142, leaving 10:05.", end: .answered)

        let answers = moe.turns.filter { $0.role == .moe }
        #expect(answers.count == 1)
        #expect(answers.first?.text == Self.promise + "\n\n" + "The cheapest is VietJet at $142, leaving 10:05.")
        #expect(answers.first?.isStreaming == false)
        #expect(!moe.isAwaitingReplyForTests)
    }

    /// Never a loop: a continuation that stalls again is left alone.
    @Test func atMostOneContinuationPerTurn() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply(Self.promise, end: .answered)
        brain.reply("Let me open the booking page.", end: .answered)
        #expect(brain.sent.count == 2)
    }

    /// …and the next thing the person asks gets its own one.
    @Test func theNextTurnGetsItsOwnContinuation() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply(Self.promise, end: .answered)
        brain.reply("VietJet at $142.", end: .answered)
        moe.submit("and a hotel in Kunming", origin: .typed, starter: .person)
        try await brain.waitForSends(3)
        brain.reply("Let me search for hotels near the old town.", end: .answered)
        #expect(brain.sent.count == 4)
    }

    @Test func anAnswerThatIsNotAPromiseSendsNothing() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("If you mean something else — Wi-Fi, a specific app — tell me which and I'll check.", end: .answered)
        #expect(brain.sent.count == 1)
    }

    // MARK: - The harness ended the turn: never "carry on"

    /// `HermesBrain.resumeAfterSleepLocked`, `.stop`: the Mac slept during a
    /// turn that had already sent or paid, and it is never re-issued unasked.
    /// Telling the brain to carry on would send or pay a second time.
    @Test func aTurnStoppedAfterASleepIsNeverContinued() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("book the VietJet flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.notice(TurnKeeper.stoppedNote))
        brain.reply("Let me book it now.", end: .stoppedAfterSleep)
        #expect(brain.sent.count == 1)
    }

    /// `HermesBrain.noteSystemWake`: on waking, the edge said the cloud took
    /// the ask. Its answer lands on the chat; a second run here duplicates it.
    @Test func aTurnTheCloudTookOnWakeIsNeverContinued() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.notice(HermesBrain.cloudHasItNote))
        brain.reply(Self.promise, end: .handedToCloud)
        #expect(brain.sent.count == 1)
    }

    /// `HermesBrain.resumeAfterSleepLocked`, `.resume` refused by the edge:
    /// the stream broke in the sleep and the cloud already holds the ask.
    @Test func aTurnTheCloudTookInsteadOfAResumeIsNeverContinued() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .spoken, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.notice(HermesBrain.cloudHasItNote))
        brain.reply("Let me set the search for the 30th.", end: .handedToCloud)
        #expect(brain.sent.count == 1)
    }

    /// Nor a failed, truncated or broken-off turn: only the model's own end.
    @Test func onlyTheModelsOwnEndOfTurnCounts() async throws {
        for end in [TurnEnd.failed, .truncated, .streamEnded] {
            let (moe, brain) = try Self.make()
            moe.submit("find me a flight", origin: .typed, starter: .person)
            try await brain.waitForSends(1)
            if end == .failed { brain.emit(.error("Moe lost its train of thought")) }
            brain.reply(Self.promise, end: end)
            #expect(brain.sent.count == 1, "\(end)")
        }
    }

    // MARK: - The voice owes the reply again

    /// A spoken turn's continuation reaches the voice machine as the reply
    /// being owed again (`.replyContinues`) — pending and live, so the key
    /// and a voice over it interrupt it. `VoiceMachineReplyContinuesTests`
    /// has what the machine does with it.
    @Test func aSpokenTurnsContinuationIsOwedThroughTheVoice() async throws {
        let (moe, brain) = try Self.make()
        moe.submit("find me a flight", origin: .spoken, starter: .person)
        try await brain.waitForSends(1)
        #expect(!moe.voice.fedForTests.contains(.replyContinues))
        brain.reply(Self.promise, end: .answered)
        let fed = moe.voice.fedForTests
        let finished = try #require(fed.lastIndex(of: .brainFinished))
        let continues = try #require(fed.lastIndex(of: .replyContinues))
        #expect(continues > finished, "the reply is owed again after the finish, not before")
    }

    // MARK: - Harness

    static func make() throws -> (Conductor, FakeBrain) {
        try requireScratchHome()
        var config = Config()
        config.replyChime = false        // no sound out of a test run
        config.screenContext = false
        let brain = FakeBrain()
        return (Conductor(config: config, brain: brain), brain)
    }

    static func requireScratchHome() throws {
        // The Conductor writes its log, history and conversations under its
        // home. scripts/test.sh points MOE_HOME at a scratch directory; on
        // any other home this refuses rather than write into a real Moe's.
        let home = Paths.home.standardizedFileURL.path
        let scratch = ProcessInfo.processInfo.environment["MOE_HOME"].map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        try #require(scratch != nil && home == scratch && !home.contains("Application Support"),
                     "run through scripts/test.sh: Paths.home is \(home), not a scratch MOE_HOME")
    }
}

/// A brain that answers when told to.
final class FakeBrain: BrainProvider, @unchecked Sendable {
    struct Sent: Equatable {
        let text: String; let silent: Bool; var starter: TurnStarter = .person
        /// Sent as the person's own spoken turn (`BrainProvider.send(spoken:)`).
        var spoken = false
        var logAs: String? = nil
    }
    var onEvent: ((BrainEvent) -> Void)?
    private(set) var sent: [Sent] = []

    func start() {}
    func warmUp() {}
    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter) {
        send(text, images: images, silent: silent, logAs: logAs, starter: starter, spoken: false)
    }
    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter, spoken: Bool) {
        sent.append(Sent(text: text, silent: silent, starter: starter, spoken: spoken, logAs: logAs))
    }
    func reset(warmingUp: Bool) {}
    func stop() {}

    /// The session a turn lands in. Empty by default — a brain with no
    /// session to name — and set by a test that rotates it.
    var sessionID = ""
    var currentSessionID: String { sessionID }

    /// Every resume the Conductor asked for — which thread, which session.
    private(set) var resumed: [BrainResume] = []
    func resume(_ resume: BrainResume) { resumed.append(resume) }

    func emit(_ event: BrainEvent) { onEvent?(event) }

    /// Every selection the Conductor handed over (`apply(brain:)`).
    private(set) var applied: [BrainSelection] = []
    func apply(brain: BrainSelection) { applied.append(brain) }

    /// Every "may this chat be remembered" the Conductor handed over.
    private(set) var remembers: [Bool] = []
    func remember(_ remembers: Bool) { self.remembers.append(remembers) }

    /// A reply streamed and finished, the way HermesBrain reports one.
    func reply(_ text: String, end: TurnEnd) {
        emit(.textDelta(text))
        emit(.turnFinished(text, end))
    }

    /// `submit` hands the words over from a Task (the screenshot may still
    /// be encoding), so the first send lands a moment after it returns.
    @MainActor
    func waitForSends(_ n: Int) async throws {
        for _ in 0..<200 where sent.count < n { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(sent.count >= n, "the brain was sent \(sent.count) message(s), expected \(n)")
    }
}
