import AVFoundation
import FluidAudio
import Foundation
import MoeDictation
import MoeVoice
import Speech

/// Moe's ears and voice. The host of `VoiceMachine`: it owns the audio
/// graph, the recognisers and the synthesiser, feeds what they report into
/// the machine, and does exactly what the machine's actions say. VOICE-PLAN.md §2.
///
/// It decides nothing about turns. Every "should Moe listen / stop / wait /
/// answer" question is answered in `MoeVoice`, where it has a test.
@MainActor
final class VoiceEngine {

    typealias State = VoiceMachine.State

    // MARK: - Outputs

    var onPartial: ((String) -> Void)?
    var onDictationPartial: ((String) -> Void)?
    /// A turn's words, ready for the brain.
    var onUtterance: ((String) -> Void)?
    /// The wake word (or the hotkey) opened a session: light the island,
    /// take the screenshot.
    var onSessionOpened: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// The first buffer of a reply has been heard. Once per reply.
    var onFirstAudio: (() -> Void)?
    /// A turn spoken in two halves, the first of which the brain already
    /// saw and had withdrawn: `text` is both halves.
    var onContinuation: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Something the person should know that is not a failure of the turn —
    /// the premium voice running out of credits. Shown, never spoken, and it
    /// leaves the conversation where it is.
    var onNotice: ((String) -> Void)?
    /// The microphone stopped working, or came back (`AudioFrontEnd`).
    /// A status, not an error: said once on the change.
    var onMicrophoneHealth: ((_ dead: Bool, _ message: String?) -> Void)?
    /// What the front end last said about the microphone.
    var microphoneDead: Bool { frontEnd.microphoneDead }
    /// The front end's own report, for tests that drive it end to end.
    func noteMicrophoneForTests(dead: Bool, message: String? = nil) {
        frontEnd.noteMicrophone(dead: dead, message: message)
    }
    var onLoadProgress: ((String) -> Void)?
    var onConversationEnded: (() -> Void)?
    /// The window has gone quiet: show the offer to close it. The island
    /// answers with `keepListening()` or `dismissConversation()`.
    var onOfferToClose: (() -> Void)?
    /// A hold ended before it ever became a recording.
    var onHoldAbandoned: (() -> Void)?
    /// The reply in flight is no longer wanted aloud (interrupted).
    var onAbandonReply: (() -> Void)?
    /// The interruption was nothing: say the rest, from `heardText`.
    var onResumeReply: (() -> Void)?
    /// A tap of the key is holding the reply, or has let it go. For the
    /// island: a held reply is `.speaking` with nothing coming out, which
    /// on its own is indistinguishable from Moe having broken.
    var onReplyHeld: ((Bool) -> Void)?
    /// Muted or not — including when the hotkey or the end of the
    /// conversation unmuted without the button being pressed.
    var onMicMuted: ((Bool) -> Void)?

    /// What the person has heard of the current reply, and everything
    /// that was queued for it. For the resume and the truncation marker.
    var heardText: String { speech.heardText }
    var spokenText: String { speech.spokenText }

    // MARK: - State

    private var machine = VoiceMachine()
    var state: State { machine.state }
    var inConversation: Bool { machine.inConversation }
    private(set) var dictating = false
    private(set) var externalInput = false
    private(set) var engineKind: TtsEngineKind = TtsEngineKind.shipped

    /// The moment the user stopped talking, read once by the Conductor.
    private var turnBeganAt: Date?
    func takeTurnStart() -> Date? {
        defer { turnBeganAt = nil }
        return turnBeganAt
    }

    // MARK: - Parts

    private let pipeline: AudioPipeline
    /// Read from the meeting's audio thread (`feedExternalInput`); the one
    /// method it reaches there is itself `nonisolated`.
    private nonisolated(unsafe) let frontEnd: AudioFrontEnd
    private let speech: SpeechOut
    let stt = SpeechRouter.forUser()
    private var asr: StreamingEouAsrManager?
    private var vad: VadManager?
    /// Smart Turn: finished, or mid-thought? Optional — without it the
    /// endpointer and the silence fallback still end every turn, later.
    private let smartTurn = SmartTurnDetector()
    private var smartTurnReady = false
    /// "Hey Moe" from the audio. Optional — without it standby falls
    /// back to spotting the name in the streaming transcript.
    private let wakeHead = WakeHead()
    private var wakeHeadReady = false
    /// What ended the last turn, for the trace.
    private var decidedBy = ""
    /// The reply may not become audible before this (`VoiceMachine.Action
    /// .holdReply`, whose tuning carries the reasoning and the numbers).
    private var replyFloorUntil: Date?
    private var replyFloorTask: Task<Void, Never>?
    /// The brain finished while its words were held behind the floor: the
    /// machine hears it once they are released, so the reply is spoken
    /// as the reply and not as an aside after the turn has closed.
    private var brainFinishedBehindFloor = false
    private var behindFloor: Bool { replyFloorUntil.map { Date() < $0 } ?? false }
    /// The reply may not start: the floor after the decision is still up,
    /// or a voice that may be the person going on is being listened to for
    /// words (a continuation onset, ≤ `bargeInHoldSeconds`). Starting the
    /// answer over the second half of the question is the cut-off the whole
    /// continuation window exists to prevent.
    private var holdingReply: Bool {
        if behindFloor { return true }
        guard machine.awaitingContinuationWords else { return false }
        switch machine.state {
        case .thinking, .deciding: return true
        default: return false
        }
    }

    /// Whatever held the reply has let go: say what waited, and tell the
    /// machine the brain finished if it did so meanwhile.
    private func releaseHeldReply() {
        guard !holdingReply else { return }
        flushHeldSpeech()
        if brainFinishedBehindFloor {
            brainFinishedBehindFloor = false
            feed(.brainFinished)
        }
    }
    /// Bumped on every VAD edge, so a turn-model verdict asked at one
    /// pause is dropped if the person spoke again before it came back.
    private var pauseSerial = 0
    /// How much audio from before a VAD onset over a reply is kept — and
    /// fed to the recogniser when it is switched on under the duck, so the
    /// first word ("st-op") is not missing its front. The onset lands one
    /// 256 ms VAD chunk after the sound began; this covers it with room,
    /// and stays short because what came before is Moe's own voice.
    ///
    /// This replaces a 300 ms "barge-in gate" that could never fail: it was
    /// cancelled only by a VAD end, and the VAD cannot end sooner than two
    /// chunks (512 ms) after it starts. The machine's word window is the
    /// gate now (`VoiceMachine.Tuning.bargeInHoldSeconds`).
    private static let onsetPrerollSeconds: Double = 0.5
    /// The capture in progress began as a barge-in: short pre-roll (Moe's
    /// own residue is not the question), and the echo check applies.
    private var bargedIn = false
    /// When the reply was paused for a barge-in, for how to resume it
    /// (`ReplyResume`).
    private var pausedAt: Date?
    /// Words, for the machine's gate (`VoiceMachine.Event.wordsHeard`): how
    /// many normalised words of the recogniser's accumulated transcript were
    /// already accounted for, and the last count of new ones reported.
    private var wordBaseline = 0
    /// The count (and whether a stop word is among them) last told to the
    /// machine — `WordReport`, shared with the replay.
    private var wordReport = WordReport()
    private var wordsReported: Int { wordReport.count }
    private var rawWordsReported = 0
    /// How long the last stretch of speech lasted — the backchannel rule
    /// needs the speech, not the capture, which carries pre-roll and the
    /// wait for the decision.
    private var speechBeganAt: Date?
    /// The VAD's view: an onset has come and no end yet.
    private var vadInSpeech = false
    // The turn's own clock. A `TurnTrace` is only made once the turn has been
    // decided — by then the moments worth measuring (the mic opening, the
    // speech starting, the speech ending) are already past, so they are held
    // here and back-filled. Without this the trace began at the decision and
    // `turnDecidedMs` was written as a literal 0: a number that could not
    // come out wrong, and so measured nothing. VOICE-PLAN.md §7.
    private var turnOpenedAt: Date?
    private var turnSpeechStartedAt: Date?
    /// Since the last wake, has the VAD heard speech begin? False from the
    /// moment the name is accepted until the person starts again — during
    /// which a speech end is the name's own, and the turn model must not
    /// be asked about it. The machine keeps the same fact (`requestHeard`)
    /// for the events it sees; this one guards the calls the engine makes
    /// on its own. Measured 2026-09-06: the 0.7 s grace alone missed the
    /// name's ending on 3 of 7 wakes, and each of those decided the turn
    /// about a second after the name.
    private var speechSinceWake = true
    /// Shorter than this with no words behind it, after the name, is not
    /// the request starting.
    private static let blipSeconds: TimeInterval = 0.4
    private var turnSpeechEndedAt: Date?
    /// The recogniser's own confidence in this turn's transcript, when it
    /// reports one. Recorded, not yet acted on — a threshold picked before
    /// the distribution is known is how the addressee anchor shipped a line
    /// that could never fire.
    private var turnConfidence: Float?
    /// The head's score for the wake that opened this turn, if a head woke it.
    private var turnWakeScore: Double?
    /// How long after the wake head fires the name's own ending is
    /// ignored. The head fires 0.25-0.4 s after the phrase finishes.
    private static let wakeGraceSeconds: Double = 0.7
    private var wakeGraceUntil: Date?
    /// When the wake that opened this turn was accepted.
    private var wokeAt: Date?
    private var wakeGrace: Task<Void, Never>?
    /// Just woken, and the request has not started yet.
    private var inWakeGrace: Bool {
        guard let until = wakeGraceUntil, Date() < until else { return false }
        if case .capturing(.wake) = machine.state { return true }
        return false
    }
    /// The recogniser is set to English, so the endpointer and the turn
    /// model mean what they say. Read once per config change.
    private var englishTurnTaking = true
    // Phase 5: is a follow-up for Moe? (VOICE-PLAN.md §4.3, §4.5)
    private let ownerVoice = OwnerVoice()
    private var ownerVoiceReady = false
    private let judge = AddresseeJudge()
    /// The embedding of the utterance that opened this session — the voice
    /// this conversation belongs to. Cleared when the session closes.
    /// VOICE-ISOLATION.md §2, §3 Tier 0.
    private var sessionAnchor: [Float]?
    /// Below this, a turn in the window is somebody else and never becomes
    /// a turn. Two lines rather than one because CAM++ across a room is
    /// not the sub-1% error rate of the lab, and a single hard gate would
    /// start refusing the owner: under the reject line it is dropped, over
    /// the accept line it is the same speaker, and the band between is
    /// handed to the `unsure` path that already exists.
    ///
    /// Set from measurement, not from a guess: 17 turns of the owner talking
    /// to his own Moe scored 0.51 at the lowest, 0.65 median, 0.85 highest
    /// (`~/.moe/logs/moe.log`, 2026-09-04). The first cut of this put the
    /// reject line at 0.25 — a quarter below anything ever observed, so it
    /// could not have refused a turn, which is a guard that reports PASS
    /// forever. 0.35 keeps a 0.16 margin under the lowest genuine score and
    /// still sits above where a different speaker's cosine lands.
    ///
    /// The caveat those numbers carry: one room, one microphone, one
    /// session, close to the Mac. A genuine turn shouted from a doorway may
    /// well score lower, and the refusals are logged with their score for
    /// exactly that reason — if this line starts refusing the owner, the
    /// log says so and says by how much.
    private static let anchorRejectBelow: Float = 0.35
    private static let anchorAcceptAbove: Float = 0.55
    /// RMS of the turn that opened the session — the loudness a turn
    /// in the window is measured against.
    private var referenceRms: Float?
    /// When the last reply finished playing.
    private var replyEndedAt: Date?
    /// A turn the rules could not place, kept for one more turn so
    /// "Moe?" resolves it.
    private var pendingUnsure: String?
    /// The model said this reply ends the conversation; close when the
    /// last word of it has been heard.
    private var closeWhenDrained = false
    /// Settings is using the microphone for the echo test or an enrolment.
    /// Those take the capture buffer, so nothing else may be using it.
    private var settingsHasMic = false
    private var lastSpeechSeconds: Double = 0
    private var tts: TtsBackend?
    private var voiceID = ""
    private var modelsReady = false
    /// A background retry of a VAD that failed to load; nil when none is
    /// running. One at a time.
    private var vadRetry: Task<Void, Never>?
    /// The turn model's load, which keeps trying until it has one.
    private var turnModelLoad: Task<Void, Never>?
    /// Consecutive wake matches refused because the voice did not match the
    /// enrolment. Reset by any wake that is accepted.
    private var wakesRefusedInARow = 0
    /// Turned off once the enrolment has refused too many wakes in a row to
    /// be believed — and kept off across restarts (`WakeOwnerTrust`, a note
    /// beside the enrolment), until the voice is taught again or forgotten.
    /// In memory alone, every launch believed the bad enrolment afresh:
    /// three more ignored wakes and the same error, each time.
    private lazy var trustOwnerVoiceForWake: Bool = {
        guard let doubt = wakeOwnerTrust.record else { return true }
        Log.write("WAKE: the voice enrolment is not being asked about wakes — it refused \(doubt.refusals) in a row on \(doubt.since.formatted(date: .abbreviated, time: .shortened)); re-teaching the voice clears this")
        return false
    }()
    private let wakeOwnerTrust = WakeOwnerTrust(
        file: OwnerVoice.file.deletingLastPathComponent().appendingPathComponent("wake-owner-distrust.json"))
    /// How many refusals in a row before the enrolment is the likelier
    /// thing to be wrong. Three: a stranger saying the name three times
    /// running is rare, and a person whose Moe has stopped answering has
    /// already tried three times by the time they think about it.
    private static let wakeRefusalsBeforeDoubt = 3
    /// Enough to hear you: the streaming recogniser, and the VAD if it
    /// came up. Six seconds, against sixty-six for everything.
    ///
    /// These were one flag, and one flag meant "Hey Moe" waited on a
    /// 461 MB transcriber that is not needed until the microphone closes
    /// and on a voice that is not needed until there is something to say.
    /// Izzy: "I kill the app and restart it and it takes maybe a minute
    /// before any of it works." Measured at 66 s, of which the part that
    /// hears him was ready at 6.
    private var listenReady = false
    /// The accurate re-read. Until it is up, the endpointer's own
    /// transcript carries the turn — rougher, and immediate.
    private var accurateReady = false
    /// The accurate read started on the VAD's edge, before the turn is
    /// decided — `ProgressiveRead` (MoeVoice) has the reasoning and the
    /// numbers. Claimed in `.transcribe`, synchronously, before the
    /// `.capture(false)` in the same batch discards it; discarded by capture
    /// on or off and by speech resuming.
    private var progressive = ProgressiveSlot<ProgressivePending>()
    private struct ProgressivePending: Sendable {
        /// The audio it was run on, available as soon as the pipeline has
        /// handed it over — before the read itself, so a stale read is
        /// known without waiting for a model.
        let snapshot: Task<ProgressiveRead.Snapshot?, Never>
        let read: Task<Heard, Never>
        let began: Date
    }
    /// Whether the pipeline is keeping audio right now: the `.capture`
    /// action, remembered.
    private var captureOn = false
    /// Something to speak with. A reply that arrives before this waits in
    /// `heldSpeech` rather than being dropped.
    private var voiceReady = false
    /// Woken when `listenReady` is set, or when the load fails without
    /// reaching it — never left waiting on a load that has stopped.
    private var listenWaiters: [CheckedContinuation<Void, Never>] = []
    private var loadTask: Task<Void, Never>?
    private var config: Config
    private var spotter: WakeSpotter
    private var timers: [VoiceMachine.TimerKind: Task<Void, Never>] = [:]

    /// Every call into the pipeline goes through here, in order. A `Task`
    /// per call has no ordering guarantee between two unstructured tasks
    /// hopping to the same actor — and "capture off, capture on" arriving
    /// as "on, off" leaves a dictation recording nothing.
    private var pipelineQueue: Task<Void, Never> = Task {}
    @discardableResult
    private func pipe<T: Sendable>(_ op: @escaping @Sendable (AudioPipeline) async -> T) -> Task<T, Never> {
        let previous = pipelineQueue
        let p = pipeline
        let task = Task<T, Never> {
            await previous.value
            return await op(p)
        }
        pipelineQueue = Task { _ = await task.value }
        return task
    }

    /// Speech that arrived while nothing may talk (you are speaking, a
    /// dictation is running). Said once the machine allows it, dropped if
    /// the reply it belongs to is abandoned first.
    private var heldSpeech: [(text: String, replyEnd: Int?)] = []
    private var holdRequested = false
    private var dictationRequested = false
    /// The streaming model's text for the turn, in case the accurate read
    /// fails outright.
    private var lastStreamingText = ""
    /// The recogniser's last partial, in any state (`reportWords`).
    private var lastPartial = ""
    /// When the transcript last got longer. The machine's `.wordStall`
    /// clock is the net under a microphone the VAD will not let go of; this
    /// is what the turn model's input is trimmed to (`TurnAudio`).
    private var wordsGrewAt = Date.distantPast
    /// The last VAD chunk that was confident speech well over the room's
    /// floor. With `wordsGrewAt`, where the turn model's input is cut.
    private var lastVoicedAt = Date.distantPast
    /// Pauses inside the turn being captured that the person talked through
    /// (`TurnPauses`, on `Date.timeIntervalSinceReferenceDate`): labelled
    /// holds, for the trace, the debug clip and the owner's pause habit.
    private var turnPauses = TurnPauses()
    /// The latest decision and the last word before it: a continuation
    /// measures the pause it cut from there.
    private var lastDecisionAt: Date?
    private var lastDecisionWordAt: Date?
    /// When the person went on after that decision (the continuation
    /// window's onset), if they did.
    private var continuedAt: Date?
    /// The on-device model's vote on the words (`TurnSemanticJudge`), asked
    /// only when `Config.turnSemanticModel` is on; and the last verdict's
    /// reading, for the trace.
    private let turnJudge = TurnSemanticJudge()
    private var lastSemantic: (TurnSemantics.Reading, TurnSemantics.Source)?
    // Diagnostics (VOICE-PLAN.md §7; the 2026-09-22 noise audit): numbers
    // for the turn trace, and a row for every VAD onset the machine refused.
    private var turnVad = VoiceDebug.VadStats()
    private var onsetVad = VoiceDebug.VadStats()
    private var onsetAt: Date?
    /// Where the onset being waited on landed ("speaking(wake)", …).
    private var onsetWindowName = ""
    /// The judge's decision on the onset now pending, for the row the
    /// machine's `.onsetTaken` / `.onsetRejected` asks for.
    private var lastBargeIn: BargeInDecision?
    private var turnModelPs: [Double] = []
    private var stallAsks = 0
    private var floorDb: Float?
    private var trace: TurnTrace?
    private var traceFile: FileHandle?

    // MARK: - Tuning

    /// How long the graph stays up after the last thing needing it.
    private let idleTeardownSeconds: Double = 60
    private let prerollSeconds: Double = 1.5

    init(config: Config) {
        self.config = config
        let (stream, cont) = AsyncStream<AudioPipeline.Output>.makeStream()
        pipeline = AudioPipeline { cont.yield($0) }
        frontEnd = AudioFrontEnd(pipeline: pipeline)
        speech = SpeechOut(frontEnd: frontEnd)
        spotter = WakeSpotter(phrases: config.wakePhrases)
        apply(config: config)

        // The capture's frames, onward to the cloud recogniser as they are
        // heard (`SpeechRouter.feedLive`); nothing happens to them unless a
        // live turn is on.
        let router = stt
        pipe { await $0.setCloudSink { feed in
            switch feed {
            case .audio(let frame): router.feedLive(frame)
            case .turnTaken: router.markTurnBoundary()
            }
        } }

        Task { [weak self] in
            for await out in stream { self?.handle(out) }
        }
        speech.onFirstAudio = { [weak self] in
            guard let self else { return }
            // Once per turn, not once per pump run: a reply that parks
            // between sentences restarts the pump, and the felt-latency
            // number must not move to the last chunk.
            // …and only on a turn that asked something: an interruption's
            // trace has no submit, and the resumed audio is not its answer.
            if self.trace?.firstAudioHeardMs == nil, self.trace?.submittedMs != nil { self.mark(\.firstAudioHeardMs) }
            self.onFirstAudio?()
        }
        frontEnd.onEchoCancellationChanged = { [weak self] on in
            guard let self else { return }
            Log.write("voice: echo cancellation \(on ? "on" : "off") — barge-in \(on ? "available" : "off until the call ends")")
            self.machine.tuning.bargeIn = self.config.bargeIn && on
        }
        frontEnd.onRestarted = { [weak self] in
            guard let self else { return }
            // The graph came back on a new device: the recogniser's
            // buffered audio and the VAD's state belong to the old one.
            self.pipe { await $0.resetAsr(); await $0.resetVad() }
            // A turn in progress has lost its endpointer and its VAD edge;
            // let the silence fallback end it.
            if case .capturing(let s) = self.machine.state, s != .hold { self.feed(.speechEnded) }
        }
        speech.onIdle = { [weak self] in
            guard let self else { return }
            self.mark(\.lastAudioHeardMs)
            self.replyEndedAt = Date()
            if self.closeWhenDrained {
                self.closeWhenDrained = false
                Log.write("voice: the goodbye has been heard; closing")
                self.feed(.stopAll)
                return
            }
            // A reply that asks something gets a longer window to answer in
            // (`Tuning.followUpAfterQuestionSeconds`).
            let asked = self.speech.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            self.feed(.replyEndedWithQuestion(asked))
            self.feed(.ttsDrained)
        }
        speech.onError = { [weak self] m in self?.onError?(m) }
        speech.onNotice = { [weak self] m in self?.onNotice?(m) }
        // The call watchdog restarts the graph, which stops the player: it
        // must know when that would cut a sentence (`CallMicDebounce`).
        frontEnd.playbackBusy = { [weak self] in self?.speech.busy ?? false }
        frontEnd.onError = { [weak self] m in self?.onError?(m) }
        frontEnd.onMicrophoneHealth = { [weak self] dead, m in self?.onMicrophoneHealth?(dead, m) }
    }

    /// Settings changed: the machine's tuning and the wake spotter follow.
    func apply(config: Config) {
        self.config = config
        machine.tuning.conversation = config.conversationMode
        machine.tuning.holdOpensConversation = config.holdOpensConversation
        machine.tuning.followUpSeconds = config.followUpSeconds
        machine.tuning.attendSeconds = config.attendSeconds
        // Barge-in needs the canceller: without it the VAD hears Moe's
        // own voice. The front end says whether it is running (never
        // while a call app holds the microphone).
        machine.tuning.bargeIn = config.bargeIn && frontEnd.echoCancellationActive
        machine.tuning.offerToCloseAfter = config.closeOffer == "off" ? 0 : config.closeOfferAfter
        // Always on. Every config.json written by an older build carries
        // `echoCancellation: false` (the old default, saved out with the
        // rest), and the cost that default was avoiding — ducking every
        // other app — is switched off in the front end now. Open-mic
        // listening does not work without it.
        frontEnd.echoCancellation = true
        spotter = WakeSpotter(phrases: config.wakePhrases)
        englishTurnTaking = SpeechLanguages.usesEnglishTurnTaking(config.locale)
        // The streaming recogniser is English: in another language its lack
        // of words says nothing, so a wordless capture is read, not dropped.
        machine.tuning.readWordlessCaptures = !englishTurnTaking
        // The wait after a verdict, from its evidence (`EndpointPolicy`).
        // English only: the fit is on English turns, and the words' shape
        // (danglers) is an English list.
        var endpoint: EndpointPolicy? = config.turnEvidence && englishTurnTaking ? .shipped : nil
        // The owner's own pause habit, when asked for and once there is
        // enough of it (`OwnerPauses`): a floor under the reply's hold.
        if config.turnOwnerPauses, endpoint != nil {
            let learnt = OwnerPauses()
            let holds = learnt.holds(fromTraceLines: Self.recentTraceLines())
            if let floor = learnt.floor(holds) {
                endpoint?.ownerQuietFloor = floor
                Log.write(String(format: "turn: your pauses — %d logged; the reply waits for at least %.2f s of quiet", holds.count, floor))
            } else {
                Log.write("turn: your pauses — \(holds.count) logged, \(learnt.minHolds) needed before they change anything")
            }
        }
        machine.tuning.endpoint = endpoint
        applyWakeHeadPolicy()
    }

    /// The tail of the turn traces (`turns.jsonl`), newest last: where the
    /// owner's holds are read from. Durations only; never words.
    static func recentTraceLines(maxBytes: Int = 2_000_000) -> [String] {
        let url = Config.homeDir.appendingPathComponent("logs/voice/turns.jsonl")
        let current = tail(of: url, maxBytes: maxBytes)
        // Just after a rotation the rest of the window is in `turns.jsonl.1`.
        let short = maxBytes - current.bytes
        guard short > 0 else { return current.lines }
        let old = tail(of: URL(fileURLWithPath: url.path + ".1"), maxBytes: short)
        return old.lines + current.lines
    }

    private static func tail(of url: URL, maxBytes: Int) -> (lines: [String], bytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return ([], 0) }
        var lines = text.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // a partial line
        return (lines, data.count)
    }

    // MARK: - Permissions

    static func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Models

    /// Downloads (first run only) and loads the models. Serialised: the app
    /// warms them at launch and a key press asks for them too; one load.
    func loadModels() async {
        if modelsReady { return }
        if let existing = loadTask { await existing.value; return }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Wait only until Moe can hear — not until it can also re-read and
    /// speak. Everything that opens a session from a key, the name or the
    /// island waits on this; dictation and the echo test, which really do
    /// need the accurate model, still wait on the whole load.
    private func waitUntilListening() async {
        if listenReady || modelsReady { return }
        if loadTask == nil, !modelsReady { Task { await loadModels() } }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listenWaiters.append(cont)
        }
    }

    /// Set it, and let go of whoever was waiting. Also called when the
    /// load fails before this point: the flag stays false and the waiters
    /// find that out, rather than waiting on something that has stopped.
    private func releaseListenWaiters() {
        let waiting = listenWaiters
        listenWaiters.removeAll()
        for cont in waiting { cont.resume() }
    }

    private func performLoad() async {
        guard !modelsReady else { return }
        let loadBegan = Date()
        do {
            Log.write("loading streaming recognizer…")
            onLoadProgress?("Getting my ears on…")
            // 400 ms of honest silence after the endpointer's token. The
            // turn model (below) ends a finished thought sooner than that;
            // the token is the second opinion, not the wait.
            let recognizer = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 400)
            try await recognizer.loadModels()
            await recognizer.setPartialCallback { [weak self] text in
                Task { @MainActor in self?.handle(.partial(text)) }
            }
            await recognizer.setEouCallback { [weak self] text in
                Task { @MainActor in self?.handle(.endOfUtterance(text)) }
            }
            asr = recognizer
            await pipeline.attach(asr: recognizer)

            Log.write("loading voice activity detector…")
            do {
                let v = try await VadManager()
                vad = v
                await pipeline.attach(vad: v)
            } catch {
                // This used to say "continuing without" and leave it there,
                // which was wrong about what "without" costs. A session does
                // still work — the endpointer ends turns on its own. But the
                // wake head is only ever run on audio the VAD called speech
                // (`AudioPipeline.process`), so no VAD means **the name does
                // not work at all**, and nothing said so.
                //
                // It happened on 2026-09-03: HuggingFace answered 429 while
                // checking a model that was already on this Mac, and "Hey
                // Moe" was dead for the rest of the session with one line in
                // the log to show for it.
                Log.write("VAD LOAD FAILED: \(error)")
                if wakeWanted {
                    Log.write("VAD is what tells the wake head when to listen — “Hey Moe” is off until it loads")
                    onError?("“Hey Moe” is unavailable — Moe could not load the model that hears when someone is speaking. The key and the shortcut still work.")
                }
                retryVadInBackground()
            }

            // Moe can hear. Everything below is about what happens after
            // the person has finished talking, so none of it belongs in
            // front of them starting.
            listenReady = true
            Log.write("listening ready (\(Self.ms(since: loadBegan)))")
            releaseListenWaiters()

            // The wake head, from the bundle; a few milliseconds to open.
            // Told to the machine as a tuning change so standby switches
            // from the transcript spotter to the head wherever it is.
            let owner = ownerVoice
            let judge = judge
            Task { [weak self] in
                await judge.warmUp()
                do {
                    try await owner.load()
                    await owner.warmUp()
                    await MainActor.run { self?.ownerVoiceReady = true }
                } catch {
                    Log.write("OWNER VOICE UNAVAILABLE (continuing without): \(error)")
                }
            }

            let head = wakeHead
            let pipe = pipeline
            Task { [weak self] in
                do {
                    try await head.load()
                    await pipe.attach(wake: head, policy: head.policy)
                    await MainActor.run { self?.applyWakeHeadPolicy() }
                    await MainActor.run {
                        guard let self else { return }
                        self.wakeHeadReady = true
                        self.feed(.setWakeHead(true))
                    }
                } catch {
                    Log.write("WAKE HEAD UNAVAILABLE (standby reads the transcript instead): \(error)")
                }
            }

            // Off the critical path: an 8 MB download must never hold up
            // the first press. Until it lands, the endpointer and the
            // silence fallback end turns on their own.
            //
            // And if it does not land — offline, Hugging Face slow, a file
            // that is not the pinned one — it is tried again later
            // (`TurnModelRetry`), not given up on for the session. The log
            // says which of the two ways turns are being ended, each time
            // that changes.
            let detector = smartTurn
            let fallbackSeconds = machine.tuning.silenceFallbackSeconds
            turnModelLoad?.cancel()
            turnModelLoad = Task { [weak self] in
                let attempts = await TurnModelRetry.run(
                    load: { try await detector.load() },
                    sleep: { (try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))) != nil },
                    onFailure: { failures, error, retryIn in
                        Log.write("SMART TURN LOAD FAILED (attempt \(failures)): \(error.localizedDescription)")
                        Log.write(String(format: "endpointing: SILENCE TIMER only (%.1f s after speech stops) — no turn model; trying again in %.0f s",
                                         fallbackSeconds, retryIn))
                    })
                guard let attempts, let self else { return }
                let name = await detector.modelName ?? "turn model"
                self.smartTurnReady = true
                self.feed(.setTurnModel(true))
                Log.write("endpointing: TURN MODEL (\(name)) live"
                          + (attempts > 1 ? " — loaded on attempt \(attempts); the silence timer is the fallback again" : ""))
            }

            // Side by side, not one after the other. They share nothing,
            // and run sequentially they cost 41 s + 18 s of a person
            // waiting. The voice starts first because a reply with nowhere
            // to go waits in `heldSpeech`, and the accurate model has the
            // endpointer's transcript standing in for it meanwhile.
            Log.write("loading voice…")
            onLoadProgress?("Finding my voice…")
            let voiceLoad = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.loadVoiceBackend()
                    self.voiceReady = true
                    Log.write("voice ready (\(Self.ms(since: loadBegan)))")
                    // A reply that arrived while it was loading.
                    self.flushHeldSpeech()
                } catch {
                    Log.write("VOICE LOAD FAILED: \(error)")
                    self.onError?("I couldn't get my voice ready, so I can't speak yet. Quit Memoe and open it again.")
                }
            }

            Log.write("loading accurate recognizer…")
            onLoadProgress?("Sharpening my hearing…")
            do {
                try await warmAccurateModel()
                accurateReady = true
                Log.write("accurate recognizer ready (\(Self.ms(since: loadBegan)))")
                // The recogniser can now confirm the name: the head may listen lower.
                applyWakeHeadPolicy()
            } catch {
                Log.write("ACCURATE MODEL LOAD FAILED: \(error)")
                onError?("I couldn't get ready to hear \(SpeechLanguages.entry(for: config.locale)?.englishName ?? config.locale). Check your internet connection, then quit Memoe and open it again.")
            }
            await voiceLoad.value

            modelsReady = true
            Log.write("all models ready")
            onLoadProgress?("")
            // The cloud recogniser's session too, so the first turn's
            // `Begin` is not paid inside the turn. Idle-closed after a
            // minute like any other; reopened at the next capture.
            stt.warmCloud(locale: config.locale)
        } catch {
            Log.write("MODEL LOAD FAILED: \(error)")
            onError?("I couldn't get ready to listen. Quit Memoe and open it again — if it keeps happening, download Memoe again from memoe.app.")
        }
        // Whether it got there or not. A caller waiting to listen must be
        // let go either way, and it checks the flag rather than assuming.
        releaseListenWaiters()
    }

    /// Try the VAD again, quietly, a few times.
    ///
    /// Every observed failure has been transient — a rate limit, a network
    /// blip at login — for a model that is one megabyte and usually already
    /// on the disk. Retrying costs nothing and restores the wake word
    /// without the person having to know it was gone, which beats asking
    /// them to relaunch an app whose failure they were never told about.
    private func retryVadInBackground() {
        guard vadRetry == nil else { return }
        vadRetry = Task { [weak self] in
            for delay in [3.0, 10.0, 30.0, 120.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.vad == nil else { return }
                guard let v = try? await VadManager() else { continue }
                await self.pipeline.attach(vad: v)
                self.vad = v
                Log.write("VAD loaded on retry — the wake word works again")
                self.onLoadProgress?("")
                return
            }
            Log.write("VAD still unavailable after four tries; the wake word stays off this session")
        }
    }

    private func warmAccurateModel() async throws {
        let report = onLoadProgress
        try await stt.warmUp(locale: config.locale) { text in
            Task { @MainActor in report?(text) }
        }
    }

    private func loadVoiceBackend() async throws {
        let kind = TtsEngineKind(rawValue: config.ttsEngine) ?? TtsEngineKind.shipped
        engineKind = kind
        // Cleared on every load: `lastFallback` is about the load that just
        // happened, never a stale one. A caller that reads it after
        // `useVoice` returns is reading this run.
        lastFallback = nil
        // Why the engine that was asked for could not be used, when it
        // could not. Set by the arms below; turned into the person's
        // sentence at the end, where the voice that will actually speak is
        // finally known.
        var substituted: String?
        // A voice saved for a different engine is not a voice. PocketTTS was
        // the default for part of a day, so a real config can say
        // `ttsVoice: "george"` while the engine that had a George is gone —
        // and handing Kokoro an unknown pack name is a load failure, i.e. no
        // voice at all. Fall back to the engine's own default instead.
        let offered = TtsCatalogue.voices(for: kind, locale: config.locale)
        let fallback = TtsCatalogue.defaultVoice(for: kind, locale: config.locale)
        if config.ttsVoice.isEmpty {
            voiceID = fallback
        } else if offered.contains(where: { $0.id == config.ttsVoice }) {
            voiceID = config.ttsVoice
        } else {
            Log.write("voice: \(kind.displayName) has no voice '\(config.ttsVoice)'; using \(fallback)")
            voiceID = fallback
        }
        let backend: TtsBackend
        switch kind {
        case .kokoro: backend = KokoroBackend()
        case .pocket:
            // PocketTTS is a 939 MB download and is never bundled. A config
            // naming it on a Mac that has not fetched it must not turn the
            // first spoken word into a download — that is precisely what
            // `TtsEngineKind.shipped` exists to prevent, and a saved config
            // is exactly how the setting arrives on a fresh machine
            // (restored backup, a synced home, a second Mac).
            //
            // So: speak with the shipped engine now, say why, and leave the
            // download to the moment someone asks for it in Settings.
            if PocketBackend.isDownloaded {
                backend = PocketBackend()
            } else {
                substituted = "it has not been downloaded on this Mac yet"
                engineKind = .shipped
                voiceID = TtsCatalogue.defaultVoice(for: .shipped, locale: config.locale)
                backend = KokoroBackend()
            }
        case .inworld:
            // The cloud voice, same shape as PocketTTS above: a saved config
            // can name it on a Mac that may not use it (no entitlement, an
            // allowance spent, no network), and the answer is to speak with
            // the shipped engine now and say why — once, because this runs
            // on every voice change and the reason does not change with it.
            //
            // `warmUp()` opens the socket, so the credential is minted and
            // the connection proven here rather than on the first sentence.
            var cloud: TtsBackend?
            if CloudVoice.mayUse(.tts) {
                let candidate = InworldBackend()
                do {
                    try await candidate.warmUp()
                    cloud = candidate
                } catch {
                    // The reason in the person's words, not the raw error:
                    // "offline" is what `CloudVoiceUnavailable` calls an edge
                    // that answered 404, and reading that on screen would
                    // send someone to check their wifi.
                    substituted = CloudVoiceUnavailable.reason(for: error)
                    Log.write("voice: the cloud voice would not open — \(error)")
                }
            } else {
                substituted = CloudVoice.whyNotUsable()
            }
            if let cloud {
                backend = cloud
                // When a sentence fails mid-reply — socket gone, token
                // refused — SpeechOut re-renders that one sentence here
                // rather than dropping it. Warmed in the background so the
                // first fallback does not pay Kokoro's 1.3 s graph build.
                // The chosen voice's twin, not the shipped default: a British
                // man must not drop mid-answer into an American woman
                // (`TtsCatalogue.localTwin`).
                let local = KokoroBackend()
                let localVoice = TtsCatalogue.localTwin(ofCloudVoice: voiceID)
                localFallback = (local, localVoice)
                Task.detached {
                    _ = try? await local.render("Ready when you are.", voice: localVoice)
                }
            } else {
                engineKind = .shipped
                voiceID = TtsCatalogue.localTwin(ofCloudVoice: voiceID)
                backend = KokoroBackend()
            }
        }
        if !backend.isCloudBackend { localFallback = nil }
        try await backend.warmUp()
        tts = backend
        speech.use(backend: backend, voice: voiceID)
        speech.setLocalFallback(localFallback?.backend, voice: localFallback?.voice ?? "")

        // The person chose an engine and is about to hear a different one.
        // Written down here, where both halves are finally known, so that
        // `useVoice` can say it out loud and the log can stop lying about
        // it. Both mattered on 2026-09-07: the log said
        // `voice: Cloud warmed in 818 ms` two lines under `using Kokoro`,
        // because the line below used to interpolate the engine that was
        // *asked for* rather than the one that loaded.
        if let substituted {
            let fallback = VoiceFallback(
                asked: kind.displayName,
                used: engineKind.displayName,
                voice: TtsCatalogue.label(of: voiceID, for: engineKind, locale: config.locale),
                why: substituted)
            lastFallback = fallback
            Self.logFallback(fallback)
        } else {
            // It works again. Forget what was last logged, so that if it
            // breaks a second time the log says so instead of coalescing
            // with an hour-old line.
            Self.lastLoggedFallback = nil
        }

        // Loaded is not run: the first synthesis pays to build the graph on
        // the accelerator (measured 1.3 s). Spend it now, silently. Not for
        // the cloud voice: its warm-up is the open socket, and a render
        // there spends the person's allowance on a sentence nobody hears.
        guard !backend.isCloudBackend else { return }
        let warming = backend
        // The engine that actually loaded, never `kind`. See above.
        let loaded = engineKind
        let voice = voiceID
        Task.detached {
            let began = Date()
            _ = try? await warming.render("Ready when you are.", voice: voice)
            Log.write("voice: \(loaded.displayName) warmed in \(VoiceEngine.ms(since: began))")
        }
    }

    /// The local engine a cloud render falls back to, sentence by sentence.
    /// Set only while the cloud voice is in use.
    private var localFallback: (backend: TtsBackend, voice: String)?

    /// The engine that was asked for could not be used and something else
    /// spoke instead — nil when the person got what they picked. Set by
    /// `loadVoiceBackend` on every load, so it is never stale.
    private(set) var lastFallback: VoiceFallback?

    /// The last fallback written to the log, so a Mac that is offline for
    /// an hour does not fill `moe.log` with the same line on every voice
    /// change.
    ///
    /// It used to be a `Bool` — `logCloudFallbackOnce` — set for the life
    /// of the process, which meant the *first* fallback was logged and
    /// every one after it was silent. That is why pressing "Use and
    /// preview" a second and third time on 2026-09-07 left no trace at all.
    /// A different reason, or the same reason after the voice worked again,
    /// is news and is written.
    private static var lastLoggedFallback: String?
    private static func logFallback(_ fallback: VoiceFallback) {
        guard Self.lastLoggedFallback != fallback.logLine else { return }
        Self.lastLoggedFallback = fallback.logLine
        Log.write(fallback.logLine)
    }

    func useLanguage(_ locale: String) async {
        config = Config.update { $0.locale = locale }
        do {
            try await warmAccurateModel()
            onLoadProgress?("")
        } catch {
            Log.write("LANGUAGE MODEL LOAD FAILED: \(error)")
            onError?("I couldn't get ready to hear \(SpeechLanguages.entry(for: locale)?.englishName ?? "that language"). Check your internet connection, then pick it again.")
        }
    }

    /// Settings' "Use and preview": save the choice, load it, and **say so
    /// when it did not take**.
    ///
    /// The return value is the whole point. This used to return nothing, so
    /// a Mac that could not reach the cloud voice loaded Kokoro, wrote one
    /// line to a log file, and left Settings showing "Cloud" and "Clive"
    /// while Heart spoke. The person's own words for that were "something's
    /// wrong with the cloud voice" — which is what a silent substitution
    /// looks like from the other side of the screen.
    ///
    /// Nil means they got what they picked. Anything else is the engine
    /// that spoke instead, and why; the caller must show it. `onError` is
    /// used as well, so a substitution is as visible as a load failure —
    /// they are the same event to the person, and this is their own key
    /// press, not a background load.
    @discardableResult
    func useVoice(engine: TtsEngineKind, voice: String) async -> VoiceFallback? {
        stopSpeaking()
        config = Config.update {
            $0.ttsEngine = engine.rawValue
            $0.ttsVoice = voice
        }
        do {
            onLoadProgress?("loading \(engine.displayName)…")
            try await loadVoiceBackend()
            onLoadProgress?("")
            if let fallback = lastFallback { onError?(fallback.sentence) }
            return lastFallback
        } catch {
            onError?("Couldn't load \(engine.displayName): \(error.localizedDescription)")
            return nil
        }
    }

    func preview(_ text: String = "Hey, it's Moe. This is how I'll sound.") async {
        await loadModels()
        speak(text)
    }

    // MARK: - Commands

    /// What Moe says when it offers to close. One short question, never a
    /// list of things it could do: the person is already in a conversation
    /// and knows what Moe is for.
    static let closeOfferLine = "Anything else?"

    /// The goodbye has been said: close the session once it has finished
    /// playing, not now. Cutting Moe off mid-goodbye to prove the
    /// conversation is over is worse than the conversation running on.
    func closeAfterSpeaking() {
        closeWhenDrained = true
    }

    /// The person answered the offer by keeping it open (the island's
    /// tick). The window starts again from the top.
    func keepListening() {
        guard machine.state == .followUp else { return }
        feed(.timer(.followUp))     // close…
        toggle()                    // …and open a fresh session, listening
    }

    /// The person answered by closing it (the island's cross, or a
    /// dismissal in any language).
    func dismissConversation() {
        feed(.dismiss)
    }

    /// The wake-word switch. Standby (mic open for the name) follows it —
    /// once the microphone is allowed and the models are up, so the tap
    /// never raises the permission prompt on its own.
    func setWakeWord(_ on: Bool) {
        wakeWanted = on
        guard on else { feed(.setWake(false)); return }
        Task { [weak self] in
            guard let self else { return }
            guard await Self.requestMicrophone() else { self.onError?(Self.micDeniedMessage); return }
            await self.waitUntilListening()
            guard self.listenReady, self.wakeWanted else { return }
            self.feed(.setWake(true))
        }
    }
    private var wakeWanted = false

    /// Models loaded, voice ready to be used.
    var isReady: Bool { modelsReady }

    /// The hotkey and the island button.
    func toggle() {
        guard ensureReady(then: { $0.toggle() }) else { return }
        feed(.toggle)
        switch machine.state {
        case .attending, .capturing: onSessionOpened?()
        default: break
        }
    }

    /// Mute yourself: Moe goes on working and talking, and nothing said in
    /// the room reaches it until you press mute again (the talk key talks
    /// through it while held). `surface` — "island", "chat" — is for the log.
    func setMicMuted(_ on: Bool, from surface: String? = nil) {
        muteSurface = surface
        feed(.setMuted(on))
        muteSurface = nil
    }
    /// Where the mute press in flight came from, and why the machine says
    /// mute changed — both only for the log line (`MuteCause.logLine`).
    private var muteSurface: String?
    private var pendingMuteCause: VoiceMachine.MuteCause?

    /// The pause button: hold the reply where it is, or let it go on.
    func pauseReply(_ pause: Bool) { feed(.pauseReply(pause)) }
    var micMuted: Bool { machine.muted }

    /// Double tap, ×, Esc.
    func stopAll() {
        holdRequested = false
        feed(.stopAll)
    }

    /// Stop talking now (a new conversation, a typed message, a voice
    /// change). The machine hears it as the audio ending, so a session
    /// that was `.speaking` moves on instead of waiting for a drain that
    /// the cancelled pump will never report.
    func stopSpeaking() {
        heldSpeech.removeAll()
        let wasBusy = speech.busy
        speech.stop()
        if wasBusy, case .speaking = machine.state { feed(.ttsDrained) }
    }

    /// The brain wrote the first token of its reply (`TurnTrace.noteFirstToken`
    /// decides whether it counts). Brain latency and voice latency are two
    /// different numbers, and until this the trace could only show their sum.
    func markFirstToken() {
        trace?.noteFirstToken()
    }

    /// The brain went back into the reply it had just finished — the stall
    /// guard's one continuation. The reply is owed again, exactly as a
    /// spoken turn's is: a finish still held behind the floor is withdrawn
    /// with it, since the brain is not finished after all.
    func replyContinues() {
        brainFinishedBehindFloor = false
        feed(.replyContinues)
    }

    /// The brain's reply is over, however it ended.
    func replyFinished() {
        mark(\.brainDoneMs)
        if holdingReply, !heldSpeech.isEmpty {
            brainFinishedBehindFloor = true
            return
        }
        feed(.brainFinished)
    }

    private func armReplyFloor(_ seconds: Double) {
        replyFloorUntil = Date().addingTimeInterval(seconds)
        replyFloorTask?.cancel()
        replyFloorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.replyFloorUntil = nil
            if !self.heldSpeech.isEmpty {
                Log.write("turn: floor up \(Int(seconds * 1000)) ms after the decision — releasing the reply")
            }
            self.releaseHeldReply()
        }
    }

    private func clearReplyFloor() {
        replyFloorTask?.cancel(); replyFloorTask = nil
        replyFloorUntil = nil
        brainFinishedBehindFloor = false
    }

    // MARK: Hold to talk

    /// A press from rest that may be a tap (`Conductor.holdBegan`): get the
    /// audio graph running so the pre-roll fills, and show nothing, open no
    /// recogniser, change no state. If the press turns into a hold,
    /// `beginHold(earlierBy:)` takes the audio from when it went down.
    /// Only with the microphone already granted — a tap must never be what
    /// raises the permission prompt.
    func warmHold() {
        guard !externalInput, listenReady,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if machine.state == .off {
            do { try frontEnd.start() } catch { Log.write("hold: could not warm the graph — \(error)") }
        }
    }

    /// The press `warmHold` was for turned out to be a tap: let the graph go
    /// as it would have, had it never been started.
    func coolHold() {
        if machine.state == .off { frontEnd.scheduleTeardown(after: idleTeardownSeconds) }
    }

    /// A reply's audio is out: playing, or queued to play.
    var isSpeaking: Bool { speech.busy }

    /// Run `done` once everything already asked of the pipeline is done —
    /// for the stop's receipt, which wants the moment the capture really
    /// closed, not the moment it was asked to.
    func afterPipeline(_ done: @escaping @MainActor @Sendable () -> Void) {
        let t = pipe { _ in }
        Task { @MainActor in
            await t.value
            done()
        }
    }

    #if DEBUG
    /// Set by a Conductor test: a hold moves the machine and nothing else —
    /// no microphone permission, no models, no graph.
    var holdsWithoutAudioForTests = false

    /// Move the machine without running a single effect — no graph, no
    /// recogniser — so a Conductor test can put the voice where a log says
    /// it was. The host hears the state change as it would for real.
    func driveMachineForTests(_ events: [VoiceMachine.Event]) {
        for event in events {
            let before = machine.state
            _ = machine.handle(event)
            if machine.state != before { onStateChange?(machine.state) }
        }
    }
    #endif

    /// - Parameter earlierBy: the key went down this long ago (a press from
    ///   rest is only begun once it has lasted a tap's length): the pre-roll
    ///   and the tap clock both reach back to the real press.
    func beginHold(earlierBy: TimeInterval = 0) async {
        #if DEBUG
        if holdsWithoutAudioForTests {
            driveMachineForTests([.holdDown])
            Log.write("hold: recording (test, no audio)")
            return
        }
        #endif
        holdRequested = true
        guard await Self.requestMicrophone() else {
            holdRequested = false
            onError?(Self.micDeniedMessage)
            return
        }
        guard holdRequested else { return }
        if !listenReady, !modelsReady {
            onLoadProgress?("Warming up…")
            await waitUntilListening()
            guard listenReady else {
                holdRequested = false
                onError?(Self.modelsUnavailableMessage)
                return
            }
            onLoadProgress?("")
            // The key came up while the models were loading: arming now
            // would start a recording the release has already been and
            // gone for.
            guard holdRequested else { return }
        }
        holdRequested = false
        let earlier = min(max(0, earlierBy), Self.holdReachBackLimit)
        holdBeganAt = Date().addingTimeInterval(-earlier)
        holdPrerollExtra = earlier
        let wasWaiting: Bool
        switch machine.state {
        case .attending, .followUp: wasWaiting = true
        default: wasWaiting = false
        }
        feed(.holdDown)
        if case .capturing(.hold) = machine.state {
            // Capture was already running while Moe waited: everything
            // before the key is room talk, not the question.
            if wasWaiting { pipe { await $0.trimCapture(keepLastSeconds: 0.3) } }
            onSessionOpened?()
        }
        Log.write("hold: recording")
    }

    private var holdBeganAt: Date?
    /// How much further back than the usual 0.3 s a hold's pre-roll reaches:
    /// the time between the press and `beginHold`. Spent by the capture.
    private var holdPrerollExtra: Double = 0
    /// Never more than this: past it the audio is not this press's.
    static let holdReachBackLimit: TimeInterval = 1.0
    /// Shorter than this and the key was brushed, not held: nothing is
    /// read back — least of all the pre-roll of whatever you were saying
    /// to someone else.
    private let tapSeconds: TimeInterval = 0.3

    /// - Parameter tap: the key already knows it was a tap. Trusted over the
    ///   clock below, which starts late and stops late.
    func endHold(tap: Bool = false) async {
        if holdRequested {
            // `beginHold` is still waiting on permission or models.
            holdRequested = false
            onPartial?("")
            Log.write("hold: released before the mic was armed — nothing recorded")
            onHoldAbandoned?()
            return
        }
        let held = holdBeganAt.map { Date().timeIntervalSince($0) } ?? 0
        holdBeganAt = nil
        if tap || held < tapSeconds {
            Log.write("hold: a tap (\(Int(held * 1000)) ms) — nothing recorded")
            feed(.holdCancelled)
        } else {
            feed(.holdUp)
        }
    }

    /// The key came up too soon to be a question (a tap): drop it.
    func cancelHold() {
        holdRequested = false
        holdBeganAt = nil
        feed(.holdCancelled)
    }

    /// The key was part of a shortcut, not a press: another key went down
    /// while it was held (`TalkChordMachine`). Nothing was asked, so nothing
    /// is recorded, and — unlike a tap — a reply the press stopped plays on.
    /// A `beginHold` still waiting on the microphone or the models sees
    /// `holdRequested` gone and arms nothing.
    func abortHold() {
        holdRequested = false
        holdBeganAt = nil
        feed(.holdAborted)
    }

    // MARK: Speaking

    /// Queue part of a reply (or an aside) to be spoken. Synchronous on
    /// purpose: the Conductor queues the tail of a reply and then reports
    /// the reply finished, and those two must land in that order.
    /// - Parameter replyEnd: where in the raw reply text this piece ends,
    ///   for a piece of a reply; nil for an aside or a step narration.
    ///   It is what a barge-in resumes from and what the transcript is cut
    ///   at — offsets, because heard speech never matches reply text.
    func speak(_ text: String, replyEnd: Int? = nil) {
        let clean = Speaker.strippedForSpeech(text)
        // Never aloud on the meeting's microphone path: the room would hear it.
        guard !clean.isEmpty, !externalInput else { return }
        // Moe can now hear before it can speak, so an answer can arrive
        // with nothing to say it. It waits where a reply already waits
        // when Moe is not allowed to talk — dropping it would lose the
        // answer to the person's first question, silently.
        guard voiceReady else {
            if heldSpeech.count < 32 { heldSpeech.append((clean, replyEnd)) }
            return
        }
        if Self.mayTalk(in: machine.state), !holdingReply {
            do { try frontEnd.start() } catch { return }
            // An aside from rest is its own utterance: nothing of the last
            // reply belongs to it.
            switch machine.state {
            case .thinking, .speaking: break
            default: speech.beginReply()
            }
            if trace?.firstAudioQueuedMs == nil { mark(\.firstAudioQueuedMs) }
            // Kokoro rejects anything past ~510 phonemes and produces no
            // audio at all for it; the remainder of a long reply is exactly
            // that size. Sentence-sized pieces for every engine. Only the
            // last piece carries the offset: marking an earlier one heard
            // would say more was heard than was.
            let pieces = SentenceSplitter.chunk(clean)
            for (i, piece) in pieces.enumerated() {
                speech.speak(piece, replyEnd: i == pieces.count - 1 ? replyEnd : nil)
            }
            // Only if something was actually queued: a `.speaking` state
            // with nothing to drain would never end.
            if speech.busy { feed(.speechQueued) }
        } else {
            heldSpeech.append((clean, replyEnd))
        }
    }

    /// How far into the current reply's raw text the person has heard.
    var heardReplyOffset: Int { speech.heardReplyOffset }

    /// A short spoken note, skipped if Moe is already talking so it never
    /// cuts across the actual answer.
    func speakAside(_ text: String) {
        guard !speech.busy, heldSpeech.isEmpty else { return }
        speak(text)
    }

    private static func mayTalk(in state: State) -> Bool {
        switch state {
        case .capturing, .deciding, .suspended: return false
        default: return true
        }
    }

    // MARK: Dictation

    func beginDictation() async {
        dictationRequested = true
        guard await Self.requestMicrophone() else {
            dictationRequested = false
            onError?(Self.micDeniedMessage)
            return
        }
        if !modelsReady {
            onLoadProgress?("Warming up…")
            await loadModels()
            guard modelsReady else {
                dictationRequested = false
                onError?(Self.modelsUnavailableMessage)
                return
            }
            onLoadProgress?("")
        }
        guard dictationRequested, !dictating else { return }
        dictationRequested = false
        feed(.suspend)
        dictating = true
        do { try frontEnd.start() } catch {
            Log.write("AUDIO GRAPH FAILED: \(error)")
            onError?("Microphone unavailable: \(error.localizedDescription)")
            dictating = false
            feed(.resume)
            return
        }
        await pipe {
            await $0.resetAsr()
            await $0.setCapture(true, prerollSeconds: 0.3)
            await $0.setAsr(true)
        }.value
        Log.write("dictation: recording")
    }

    /// The key came up: transcribe and return the text. Empty when nothing
    /// usable was said.
    func endDictation() async -> String {
        dictationRequested = false
        guard dictating else { return "" }
        let audio = await pipe { p -> [Float] in
            await p.setAsr(false)
            let audio = await p.takeCapture()
            await p.setCapture(false, prerollSeconds: 0)
            return audio
        }.value
        Log.write("dictation: released, \(audio.count) samples")
        var text = ""
        if audio.count > Int(AudioPipeline.rate * 0.25) {
            text = await transcribe(audio)
        }
        pipe { await $0.resetAsr() }
        onDictationPartial?("")
        finishDictation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancelDictation() {
        dictationRequested = false
        guard dictating else { return }
        pipe {
            await $0.setAsr(false)
            _ = await $0.takeCapture()
            await $0.setCapture(false, prerollSeconds: 0)
            await $0.resetAsr()
        }
        onDictationPartial?("")
        Log.write("dictation: cancelled")
        finishDictation()
    }

    private func finishDictation() {
        dictating = false
        feed(.resume)
        flushHeldSpeech()
    }

    // MARK: Meeting mode

    /// The meeting's microphone feeds this engine from now on.
    func attachExternalInput() {
        externalInput = true
        frontEnd.attachExternalInput()
    }

    func detachExternalInput() {
        guard externalInput else { return }
        externalInput = false
        frontEnd.detachExternalInput()
    }

    nonisolated func feedExternalInput(_ buffer: AVAudioPCMBuffer) {
        frontEnd.feedExternalInput(buffer)
    }

    func shutDown() {
        speech.stop()
        frontEnd.stop()
        traceFile?.closeFile()
    }

    // MARK: - The machine

    /// Models must be up before the machine may open a session from a key;
    /// a press that arrives during the load is honoured when it finishes.
    private func ensureReady(then action: @escaping (VoiceEngine) -> Void) -> Bool {
        if listenReady || modelsReady { return true }
        onLoadProgress?("Waking up — the first time takes a few seconds…")
        Task { [weak self] in
            guard let self else { return }
            guard await Self.requestMicrophone() else { self.onError?(Self.micDeniedMessage); return }
            await self.waitUntilListening()
            guard self.listenReady else {
                self.onLoadProgress?("")
                self.onError?(Self.modelsUnavailableMessage)
                return
            }
            self.onLoadProgress?("")
            action(self)
        }
        return false
    }

    /// Events that arrive while the actions of another are being carried
    /// out — a reply resumed inside a decision, a Conductor callback that
    /// answers at once. Running them nested would interleave two
    /// transitions' actions; they wait their turn instead.
    private var feeding = false
    private var pendingEvents: [VoiceMachine.Event] = []

    #if DEBUG
    /// Every event handed to the machine, in order — for a test that drives
    /// the Conductor and has to see what reached the voice.
    private(set) var fedForTests: [VoiceMachine.Event] = []
    #endif

    private func feed(_ event: VoiceMachine.Event) {
        #if DEBUG
        fedForTests.append(event)
        #endif
        if feeding { pendingEvents.append(event); return }
        feeding = true
        feedNow(event)
        while !pendingEvents.isEmpty { feedNow(pendingEvents.removeFirst()) }
        feeding = false
    }

    private func feedNow(_ event: VoiceMachine.Event) {
        let before = machine.state
        // What ended the turn arrives as `.decided`, from the machine, which
        // knows which clock it was — the stall net used to be recorded as
        // "turn-model" because it borrowed that event.
        let waitingBefore = machine.awaitingWords
        let actions = machine.handle(event)
        if !waitingBefore, machine.awaitingWords {
            // A VAD onset over a reply: the machine is waiting on words.
            onsetAt = Date()
            onsetVad = VoiceDebug.VadStats()
            onsetWindowName = Self.name(before)
            lastBargeIn = nil
        }
        for action in actions { perform(action) }
        // An onset that held the reply has been decided, one way or the other.
        if waitingBefore, !machine.awaitingWords { releaseHeldReply() }
        if machine.state != before {
            Log.write("voice: \(Self.name(before)) → \(Self.name(machine.state))")
            onStateChange?(machine.state)
            if Self.mayTalk(in: machine.state) { flushHeldSpeech() }
            frontEnd.setVoiceProcessingBypassed(!Self.needsCanceller(machine.state))
        }
    }

    /// Does the voice-processing unit have anything to do in this state?
    ///
    /// Apple's voice-processing unit costs about a fifth of a CPU core
    /// whenever it is running (`AudioFrontEnd.setVoiceProcessingBypassed`
    /// has the measurements), and a profile of an idle Moe found 78% of its
    /// CPU inside it. An idle Moe sits in `standby` — wake word armed, mic
    /// open, nothing happening — so bypassing it there is the whole saving,
    /// and it is kept.
    ///
    /// Everywhere else the unit stays on, and not only for the echo
    /// canceller. The bypass property switches off *all* of the uplink
    /// processing — echo cancellation, automatic gain and noise suppression
    /// are siblings under it in Apple's header — and the first version of
    /// this rule bypassed it in every capturing state on the reasoning that
    /// there was nothing to cancel. Measured across that install (2026-09-06
    /// 05:44Z, same microphone): the RMS of a captured turn fell from a
    /// median of 0.063 (n=167) to 0.003 (n=56), transcription confidence
    /// from 0.94 to 0.75, wake turns came back as "Il m'a" and "Hey no,
    /// no", the owner-voice check refused the owner three times in a row,
    /// and every level comparison that spans two states — the addressee
    /// ratio, the barge-in reference, the trailing-silence trim — was
    /// comparing raw air against processed speech. The CPU profile was
    /// true; it was not the whole story.
    ///
    /// `thinking` and `speaking` also need the canceller converged before a
    /// sound plays: entering on the way *into* the turn hands the adaptive
    /// filter the thinking pause to settle, where un-bypassing at the
    /// instant playback starts would leak the first syllable into the mic.
    static func needsCanceller(_ state: VoiceMachine.State) -> Bool {
        switch state {
        case .off, .standby, .suspended: return false
        case .attending, .capturing, .deciding, .thinking, .speaking, .followUp: return true
        }
    }

    private func perform(_ action: VoiceMachine.Action) {
        switch action {
        case .audio(let on):
            if on {
                // A graph that will not start is retried, then started
                // without voice processing, before anything is said
                // (`CaptureRecovery`); the one error comes through
                // `frontEnd.onError`, and `onRestarted` when it is back.
                frontEnd.startOrRecover()
            } else {
                frontEnd.scheduleTeardown(after: idleTeardownSeconds)
            }

        case .asr(let on):
            // Switched on under a VAD onset (Moe thinking or speaking): the
            // onset is a chunk late, so the recogniser is given the moment
            // before it too, or a short "stop" arrives without its front.
            let prime: Double
            switch machine.state {
            case .speaking, .thinking: prime = on && machine.awaitingWords ? Self.onsetPrerollSeconds : 0
            default: prime = 0
            }
            pipe { await $0.setAsr(on, primeSeconds: prime) }

        case .wake(let on):
            pipe { await $0.setWake(on) }

        case .duckSpeech(let on):
            frontEnd.duck(on)

        case .judgeBargeIn:
            // Words over the reply, which is still only ducked. Whose? Every
            // cheap check runs now, before anything is paused: whose voice
            // (the owner's enrolment), whether it is Moe's own sentence coming
            // back, and how loud against the voice that opened the session.
            // They used to run after the capture ended, so a false stop was
            // heard first and "resumed" afterwards.
            let window = onsetWindowName
            let words = wordsReported
            let urgent = wordReport.urgent
            let heard = TurnPolicy.words(lastPartial).dropFirst(wordBaseline).joined(separator: " ")
            let playing = speech.textAroundPlayhead
            let atPlayhead = speech.wordsAtPlayhead
            let enforceOwner = config.ownerGateEnforce
            let owner = ownerVoice
            let ownerReady = ownerVoiceReady
            let spotter = spotter
            Task { [weak self] in
                guard let self else { return }
                let audio = await self.pipe { await $0.peekCapture() }.value
                // The person's own audio only: the capture opens with
                // `onsetPrerollSeconds` of pre-roll, which is Moe's ducked
                // reply, not them (review H2).
                let own = BargeInJudge.ownAudio(audio, prerollSeconds: Self.onsetPrerollSeconds,
                                                sampleRate: Int(AudioPipeline.rate))
                let ownSeconds = Double(own.count) / AudioPipeline.rate
                let ownerScore = ownerReady && ownSeconds >= BargeInJudge.ownerMinSeconds
                    ? await owner.score(own).map(Double.init) : nil
                var signals = BargeInJudge.Signals(
                    window: window, words: words,
                    named: NameMatch.namesMoe(heard, spotter: spotter), urgent: urgent,
                    ownerScore: ownerScore, ownerSeconds: ownSeconds,
                    echoSimilarity: playing.isEmpty || heard.isEmpty ? nil : EchoFilter.windowSimilarity(heard, playing),
                    heard: heard,
                    levelRatio: self.bargeInLevel(audio))
                signals.urgentEchoesPlayhead = BargeInJudge.echoesThePlayhead(heard: heard, playing: atPlayhead)
                signals.enforceOwner = enforceOwner
                let decision = BargeInJudge.decide(signals)
                Log.write(decision.logLine + (decision.ownerWouldRefuse == true
                    ? " — the owner check (not enforcing) would have refused it" : ""))
                self.lastBargeIn = decision
                self.feed(.bargeInJudged(decision.taken))
            }

        case .capture(let on):
            if on, !captureOn {
                turnVad = VoiceDebug.VadStats()
                turnPauses = TurnPauses()
                // A new capture: an owner-gate reading from an earlier one
                // belongs to that one, not to this (review N5).
                pendingOwnerGate = nil
                // The reply will want the voice warm: Inworld drops an idle
                // socket at 10 minutes, and PocketTTS goes slow after one
                // (`PocketBackend.prepareForTurn`). Done now, under the
                // person's words, rather than on the reply's first sentence.
                // Not the cloud voice once it is out of credits: nothing
                // will be asked of it.
                if let tts, !(tts.isCloudBackend && speech.premiumSpent) {
                    Task { await tts.prepareForTurn() }
                }
            }
            captureOn = on
            // A new owner of the buffer, or no buffer: an early read still
            // pending is a prefix of nothing now. On a normal turn this
            // finds nothing — `.transcribe` claimed it a moment ago.
            discardProgressive()
            // A held key gets a short pre-roll: enough for the syllable
            // that started before the key landed, not the last sentence
            // you said to someone else. A wake match needs the whole
            // phrase and what followed it.
            let preroll: Double
            if case .capturing(.hold) = machine.state {
                preroll = 0.3 + holdPrerollExtra
                holdPrerollExtra = 0
            }
            // A capture that opens under a VAD onset over the reply (or
            // over Moe thinking) starts the VAD's chunk late: the pre-roll
            // is the start of "no, wait —", kept short because before it
            // is Moe's own voice. The echo check covers the residue.
            else if case .speaking = machine.state { preroll = Self.onsetPrerollSeconds }
            else if case .thinking = machine.state, machine.awaitingWords { preroll = Self.onsetPrerollSeconds }
            else { preroll = prerollSeconds }
            // The turn starts here, not at the decision: this is the moment
            // the mic began keeping what it heard.
            if on, turnOpenedAt == nil { turnOpenedAt = Date() }
            // The cloud recogniser follows the capture: on means open the
            // session and take the frames from the first one (the pre-roll
            // included, so a wake turn's name is in there — the spotter
            // strips it from the text); off means the turn is over, and if
            // it was never read back, its words are dropped there and then.
            // Before the pipeline call, so the pre-roll it forwards on
            // `setCapture` finds the feed already on.
            if on {
                stt.noteAgentContext(speech.spokenText)
                stt.beginLiveTurn(locale: config.locale)
            } else {
                stt.endLiveTurn()
            }
            pipe { await $0.setCapture(on, prerollSeconds: preroll) }

        case .askTurnModel:
            // The endpointer proposed an ending; the model decides.
            askTurnModel()

        case .askTurnModelOnStall:
            // The words stopped and the VAD never said so — in noise it
            // cannot. Asked the same way, stale only if words grew since.
            Log.write("turn: no new words for \(String(format: "%.1f", machine.tuning.wordStallSeconds)) s — asking the turn model whatever the VAD says")
            askTurnModel(onStall: true)

        case .onsetRejected(let why):
            // A sound over a reply that was let go. One row each: these are
            // what a noise dataset is made of, and until now they left
            // nothing but a log line (and only the judge's half of them).
            let decision: BargeInDecision
            switch why {
            case .noWords:
                decision = BargeInDecision(window: onsetWindowName, taken: false, check: .words,
                                           words: wordsReported)
            case .notForMoe:
                decision = lastBargeIn ?? BargeInDecision(window: onsetWindowName, taken: false,
                                                          check: .noSignal, words: wordsReported)
            case .superseded:
                decision = BargeInDecision(window: onsetWindowName, taken: false, check: .superseded,
                                           words: wordsReported)
            }
            writeOnsetRow(outcome: why.rawValue, decision)

        case .onsetTaken(let how):
            // …and every one that took the floor, with the check that let it.
            let decision: BargeInDecision
            switch how {
            case .judged:
                decision = lastBargeIn ?? BargeInDecision(window: onsetWindowName, taken: true,
                                                          check: .noSignal, words: wordsReported)
            case .overThinking, .intoWindow:
                decision = BargeInDecision(window: onsetWindowName, taken: true, check: .words,
                                           words: wordsReported)
            case .continuation:
                decision = BargeInDecision(window: onsetWindowName, taken: true, check: .continuation,
                                           words: wordsReported)
                // The decision before this was a false endpoint: the pause it
                // was taken in is a labelled hold (the trace here, the clip
                // around the decision — `saveDecisionClip` — once it is cut).
                let resumed = speechBeganAt ?? Date()
                continuedAt = resumed
                let cut = lastDecisionWordAt.map { Int((resumed.timeIntervalSince($0) * 1000).rounded()) }
                writeOnsetRow(outcome: how.rawValue, decision, continuedAfterMs: cut.flatMap { $0 > 0 ? $0 : nil })
                return
            }
            writeOnsetRow(outcome: how.rawValue, decision)

        case .decided(let reason):
            decidedBy = reason.rawValue
            // Whatever held the last reply is not this turn's; `.holdReply`
            // follows in the same batch when this one is held. Not for a
            // capture that was only the room: that is no new turn, and the
            // reply it interrupted keeps whatever floor it had.
            let unread = reason == .noWords || reason == .notOwner
            if !unread { clearReplyFloor() }
            if unread {
                // Sound with no words, or words in somebody else's voice:
                // nothing is read and nothing is sent; the turn clock starts
                // again with the next sound.
                Log.write(reason == .noWords
                          ? "turn: \(Self.name(machine.state)) — sound with no words, ended without a read"
                          : "turn: \(Self.name(machine.state)) — not the owner's voice, ended without a read")
                var row = TurnTrace(source: "\(Self.name(machine.state))", startedAt: turnOpenedAt ?? Date())
                row.endpoint = reason.rawValue
                row.decidedBy = reason.rawValue
                row.outcome = reason.rawValue
                if let gate = pendingOwnerGate { row.ownerGateScore = gate.score; row.ownerGate = gate.outcome }
                pendingOwnerGate = nil
                fillVad(&row, turnVad)
                writeTraceLine(row)
                if config.voiceDebugAudio {
                    let clip = pipe { await $0.peekCapture(lastSeconds: 8) }
                    saveDecisionClip(before: clip, kind: "turn", reason: reason.rawValue, words: wordsReported)
                }
                turnVad = VoiceDebug.VadStats()
                turnOpenedAt = captureOn ? Date() : nil
                turnSpeechStartedAt = nil
                turnSpeechEndedAt = nil
            }

        case .holdReply(let seconds):
            armReplyFloor(seconds)

        case .resetAsr:
            forgetWords()
            wordBaseline = 0
            wordReport.reset(); rawWordsReported = 0
            pipe { await $0.resetAsr() }

        case .transcribe(let turn):
            wakeGrace?.cancel(); wakeGrace = nil
            wakeGraceUntil = nil
            speechSinceWake = true
            turnBeganAt = Date()
            // The holds inside this turn, before the trace takes and clears them.
            let holds = turnPauses.spans
            let decisionT = Date().timeIntervalSinceReferenceDate
            let lastWordT = max(wordsGrewAt, lastVoicedAt).timeIntervalSinceReferenceDate
            lastDecisionAt = Date()
            lastDecisionWordAt = max(wordsGrewAt, lastVoicedAt)
            continuedAt = nil
            // Before the trace: `beginTrace()` clears the turn's speech span,
            // and reading it afterwards measured every turn by its last VAD
            // segment (`TurnAudio.speechSeconds`).
            let seconds = TurnAudio.speechSeconds(turnStarted: turnSpeechStartedAt,
                                                  turnEnded: turnSpeechEndedAt,
                                                  lastSegment: lastSpeechSeconds,
                                                  segmentBegan: speechBeganAt)
            beginTrace()
            mark(\.turnDecidedMs)
            let fallback = lastStreamingText
            // The recogniser keeps this turn's words; a voice going on after
            // the decision is counted from here.
            wordBaseline = TurnPolicy.words(fallback).count
            wordReport.reset(); rawWordsReported = 0
            forgetWords()
            // Before the take: the derived `.capture(false)` follows this
            // action in the same batch, and without the claim its
            // `endLiveTurn` threw the cloud's copy of the turn away before
            // the read (queued behind the pipeline) could ask for it.
            stt.claimLiveTurn()
            let capture = pipe { await $0.takeCapture() }
            // Every turn decision, as audio, when the owner has asked for it:
            // the eight seconds the turn model reads and the seconds after,
            // which say whether the person went on (research-endpointing.md
            // §6.2 — the labels come free from what happened next). Held-key
            // turns too: every pause inside one is a pause the person talked
            // through, which is exactly the label the turn model lacks.
            //
            // Held-key turns keep the whole turn (to `heldKeyClipSeconds`), so
            // every pause in them is in the clip, labelled; a hands-free turn
            // the person goes on after is labelled "continued", with the
            // pause it was decided in (`VoiceDebug.labelledHolds`).
            let held = decidedBy == VoiceMachine.EndReason.key.rawValue
            saveDecisionClip(before: capture, kind: "turn", reason: decidedBy,
                             turnModelP: trace?.turnModelP, words: TurnPolicy.words(fallback).count,
                             holds: holds, decisionT: decisionT, lastWordT: held ? nil : lastWordT,
                             label: held ? "hold-to-talk" : nil,
                             beforeSeconds: held ? VoiceDebug.heldKeyClipSeconds : VoiceDebug.beforeDecisionSeconds)
            // Now, not in the task below: `.capture(false)` is next in this
            // batch and discards whatever is still pending.
            let early = progressive.claim()
            defer { trace?.decidedBy = decidedBy }
            // Both the window and an interruption are `.deciding(.followUp,…)`,
            // and words in either can turn out not to be for Moe — the
            // person carried on talking to somebody else while Moe
            // answered. Judged the same way, with two differences: over a
            // reply the prior leans much further towards "for Moe",
            // because talking over an assistant is deliberate; and when
            // the words are not for Moe the reply *resumes* rather than
            // being dropped, because Moe was mid-sentence.
            // The second half of a turn the session already took: never
            // dropped on the voice (review H3).
            let restOfATurn = machine.decidingTheRestOfATurn
            let isFollowUp: Bool
            if case .deciding(.followUp, _) = machine.state { isFollowUp = true } else { isFollowUp = false }
            let inWindow = isFollowUp
            // A wake turn's capture starts before the name (pre-roll): the
            // re-read is cut at the last match, not only a leading one.
            let isWake: Bool
            if case .deciding(.wake, _) = machine.state { isWake = true } else { isWake = false }
            // What Moe was saying, for the echo check — on a barge-in only:
            // a follow-up that quotes Moe ("is that the platform team?") is
            // a question, not an echo.
            let wasBargeIn = bargedIn
            bargedIn = false
            let spokenReference = wasBargeIn ? speech.spokenText : ""
            trace?.decidedBy = decidedBy
            // The speech, not the capture: the capture carries pre-roll and
            // the wait for the decision, so it is never under a second.
            //
            // The WHOLE turn's speech, not the last VAD segment. A person
            // who pauses mid-sentence produces several segments, and the
            // last one can be a trailing word — measured 2026-09-07
            // 01:25:08Z: a 32-word request whose final segment was a
            // sliver, so the loudness was read off that sliver (ratio 0.04
            // against 0.93 for the turns around it), the owner and anchor
            // checks were skipped as too short, and the turn was dropped
            // as "not for Moe".
            // (`seconds` is read above, before `beginTrace()` clears the span.)
            Task { [weak self] in
                let audio = await capture.value
                guard let self else { return }
                let began = Date()
                var text = ""
                if audio.count > Int(AudioPipeline.rate * 0.25) {
                    // Cold, the accurate model would hold the turn for as
                    // long as it takes to load — which is the wait this
                    // whole staging exists to remove. The endpointer has
                    // already written down what it heard; use that.
                    if await self.accurateReady {
                        let scored = await self.accurateRead(audio, early: early)
                        text = scored.text
                        // The fallback used to fire here too, and it was the
                        // wrong way round: the accurate model had *run* and
                        // reported nothing, which is an answer, and it was
                        // being overruled by the rougher live one — the model
                        // documented as "rougher, and immediate", whose
                        // decoder carries cache across turns. That is how
                        // silence, a door, or the tail of an abandoned
                        // utterance became a sentence and reached the brain.
                        // Empty from the model that looked hardest stands.
                        self.turnConfidence = scored.confidence
                        let conf = scored.confidence.map { String(format: "%.2f", $0) } ?? "-"
                        let level = Self.rms(audio)
                        Log.write("turn: re-read \(Self.seconds(audio.count, at: AudioPipeline.rate)) in \(Self.ms(since: began)), confidence \(conf), level \(String(format: "%.3f", level))")
                        // A read that never answered is not a read that
                        // heard nothing. The paragraph above is about the
                        // second; this is the first, and there the live
                        // recogniser's words are all anyone has — and the
                        // person has already watched them appear on the
                        // island, so dropping the turn here is Moe losing
                        // something it visibly had. `TurnPolicy.transcript`
                        // is the rule and carries the incident.
                        let outcome: ReadOutcome = scored.timedOut ? .neverAnswered
                                                                   : .answered(scored.text)
                        text = TurnPolicy.transcript(read: outcome, live: fallback)
                        if !scored.timedOut, QuietTurnPolicy.liveWordsOutrankEmptyRead(
                            read: scored.text, readConfidence: scored.confidence,
                            live: fallback, level: level) {
                            Log.write("turn: the re-read came back empty and unsure — the live recogniser's "
                                      + "\(fallback.split(separator: " ").count) word(s) stand")
                            text = fallback
                        }
                        if scored.timedOut {
                            self.turnConfidence = nil
                            if TurnPolicy.fellBackToLiveWords(read: outcome, live: fallback) {
                                Log.write("turn: the re-read never came back — the live recogniser's "
                                          + "\(fallback.split(separator: " ").count) word(s) stand")
                            } else {
                                Log.write("turn: the re-read never came back, and the live recogniser had nothing")
                            }
                        }
                        // A wake turn read out of near-silence with the
                        // recogniser unsure of its own words is the
                        // recogniser inventing a request, not hearing one.
                        // Real requests in the log: confidence 0.81–0.98
                        // at level 0.03–0.10; the inventions: 0.10–0.60 at
                        // 0.001. Both conditions, so a quiet but clear
                        // "what time is it" still goes through.
                        // Every source now, not only wakes: the inventions came
                        // through follow-up windows too (`QuietTurnPolicy`).
                        if QuietTurnPolicy.isInvented(text: text, confidence: scored.confidence, level: level) {
                            Log.write("turn: too quiet and too unsure to be a request — treated as nothing said")
                            text = ""
                        }
                    } else {
                        text = fallback
                        Log.write("turn: accurate model still loading — the endpointer's words stand")
                    }
                }
                // Stopped while it was being read — a double-tap, a dismiss, a
                // newer turn: the machine would ignore it, so nothing more is
                // spent on it and the log does not claim it was submitted.
                guard self.machine.awaitsTranscript(turn: turn) else {
                    Log.write("turn \(turn): the read came back after the turn was stopped — dropped")
                    return
                }
                var cleaned = self.spotter.strippingPhrase(from: text, anywhere: isWake)
                // "mm-hmm" inside the window is said to a speaker, not as
                // one: it neither starts a turn nor closes the window.
                // "yes", "sure", "okay" are backchannels said *to* a
                // speaker — unless Moe just asked something, when they
                // are the answer.
                let moeAsked = self.speech.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                // A barge-in that was taken can still come to nothing once the
                // whole of it is read: which check said so, for the trace.
                var afterRead: BargeInDecision.Check? = wasBargeIn && cleaned.isEmpty ? .readEmpty : nil
                if inWindow, !moeAsked, TurnPolicy.isBackchannel(cleaned, seconds: seconds) {
                    Log.write("heard: backchannel \"\(cleaned)\" — ignored")
                    cleaned = ""
                    afterRead = .backchannel
                } else if wasBargeIn, !cleaned.isEmpty,
                          let echo = await self.moeHearingItself(cleaned, spoken: spokenReference,
                                                                 audio: audio, seconds: seconds) {
                    // Moe hearing itself through what the canceller left.
                    // Measured: it said "Sure, take your time.", heard
                    // "Sugar take me", and answered itself.
                    Log.write("heard: Moe's own voice coming back — ignored")
                    cleaned = ""
                    afterRead = echo
                } else if !cleaned.isEmpty, isFollowUp || wasBargeIn,
                          await self.meansWeAreDone(cleaned) {
                    // "I'm not talking to you", "that's all", "we're done"
                    // — in any language. Moe stops rather than answering it.
                    Log.write("heard: the conversation is over — stopping")
                    self.pendingUnsure = nil
                    self.mark(\.transcribedMs)
                    self.feed(.stopAll)
                    self.turnBeganAt = nil
                    self.feed(.transcribed(turn: turn, ""))
                    return
                } else if isFollowUp || wasBargeIn, !cleaned.isEmpty,
                          await self.clearlyNotTheOwner(Self.speechTail(audio, seconds: seconds),
                                                        seconds: seconds, text: cleaned, at: "the end of the turn",
                                                        continuation: restOfATurn) {
                    // Before it becomes a turn: a voice that is clearly not the
                    // owner's (the TV, somebody else) never reaches the brain.
                    cleaned = ""
                    afterRead = .ownerVoice
                } else if inWindow, !cleaned.isEmpty {
                    // Inside the window, words are not a turn until they
                    // are for Moe (§4.3). "Thanks Moe" closes it.
                    if Addressee.isClosePhrase(cleaned) {
                        Log.write("heard: a goodbye — window closed")
                        self.pendingUnsure = nil
                        self.mark(\.transcribedMs)
                        self.feed(.dismiss)
                        // The machine is in `.deciding` until a transcript
                        // arrives: a dismiss it ignored (suspended, say)
                        // must not leave it waiting forever.
                        self.turnBeganAt = nil
                        self.feed(.transcribed(turn: turn, ""))
                        return
                    }
                    let named = cleaned.count != text.trimmingCharacters(in: .whitespacesAndNewlines).count
                    cleaned = await self.addressed(cleaned, named: named, audio: audio,
                                                   seconds: seconds, moeAsked: moeAsked,
                                                   overAReply: wasBargeIn)
                    if cleaned.isEmpty, afterRead == nil { afterRead = .addressee }
                } else {
                    Log.write("heard: \"\(cleaned)\"")
                    if !cleaned.isEmpty, !isFollowUp, !wasBargeIn {
                        self.openedSession(with: audio, seconds: seconds, wake: isWake)
                    }
                }
                self.mark(\.transcribedMs)
                // Flagged turns, as audio, when asked for: the endings the
                // noise work is about, and a barge-in that came to nothing.
                if wasBargeIn {
                    // The last word on the barge-in, after the whole of it
                    // was read: it stood, or which check let it go.
                    let decision = BargeInDecision(window: "speaking", taken: !cleaned.isEmpty,
                                                   check: afterRead ?? .words,
                                                   words: TurnPolicy.meaningfulWords(in: cleaned))
                    if var t = self.trace { decision.stamp(&t); self.trace = t }
                    Log.write("turn: \(decision.logLine) — after the read")
                    if cleaned.isEmpty, self.config.voiceDebugAudio {
                        let side = VoiceDebug.Sidecar(kind: "barge-in", reason: "false-interruption",
                                                      decidedAtSeconds: Double(audio.count) / AudioPipeline.rate,
                                                      clipSeconds: Double(audio.count) / AudioPipeline.rate,
                                                      bargeIn: decision)
                        self.saveDebugClip(audio, reason: "barge-in-false-interruption", sidecar: side)
                    }
                }
                if isFollowUp || wasBargeIn {
                    Log.write("turn \(turn): window=\(inWindow) followUp=\(isFollowUp) bargeIn=\(wasBargeIn) → \(cleaned.isEmpty ? "dropped" : "submitted")")
                }
                // A turn that goes nowhere must not leave its clock running:
                // only `submit` consumes the mark, so a dropped voice turn's
                // start was inherited by the next thing typed — "first token
                // 25.9 s" on a four-second typed turn (2026-09-06 20:03Z).
                if cleaned.isEmpty { self.turnBeganAt = nil }
                self.feed(.transcribed(turn: turn, cleaned))
            }

        case .submit(let text):
            closeWhenDrained = false
            mark(\.submittedMs)
            noteBrain()
            speech.beginReply()
            // Spoken addresses, written. Dictation has had a cleanup pass
            // and an optional polish pass for a long time; what is *said*
            // to Moe has had neither, so "email jane at example dot ai"
            // reached the brain as prose and the brain sent mail to
            // nobody. This is the one piece of that cleanup that changes
            // meaning rather than style, so it is the one worth running
            // here — the rest (fillers, stutters, capitalisation) is for a
            // reader, and the brain does not need it.
            onUtterance?(SpokenAddress.rewrite(text))

        case .submitContinuation(let text):
            closeWhenDrained = false
            mark(\.submittedMs)
            noteBrain()
            speech.beginReply()
            Log.write("turn: continued — the pause was a breath; asking again with both halves (\(text.split(separator: " ").count) words)")
            onContinuation?(SpokenAddress.rewrite(text))

        case .ignoredInterruptionsOff(let byName):
            // Once per reply: nothing stopped, nothing restarted.
            Log.write("turn: \(byName ? "the name" : "a voice") over \(Self.name(machine.state)) ignored — interruptions are off")

        case .stopSpeaking:
            clearReplyFloor()
            heldSpeech.removeAll()
            speech.stop()

        case .holdSpeech:
            speech.pause()
            Log.write("turn: reply paused by the person")

        case .pauseSpeech:
            // Only ever the machine taking a barge-in it heard words for.
            bargedIn = true
            pausedAt = Date()
            speech.pause()
            Log.write("turn: reply paused — someone is talking over it")

        case .muteCause(let cause):
            // Always emitted just before `.micMuted`, which logs it.
            pendingMuteCause = cause

        case .micMuted(let on):
            let cause = pendingMuteCause ?? .unrecorded
            Log.write(cause.logLine(muted: on, surface: cause == .button ? muteSurface : nil))
            pendingMuteCause = nil
            muteSurface = nil
            onMicMuted?(on)

        case .mutedWindowExpired:
            Log.write("voice: the muted window sat untouched for "
                      + "\(Int(machine.tuning.mutedWindowSeconds / 60)) min; closing the conversation")

        case .replyHeld(let held):
            // The audio stopped when the key went down; this is the state
            // the person is left in, and how they get out of it.
            Log.write(held ? "turn: reply held by the key — a tap carries on"
                           : "turn: reply let go by the key")
            onReplyHeld?(held)

        case .abandonReply:
            clearReplyFloor()
            heldSpeech.removeAll()
            speech.stop()    // a reply only paused for the barge-in is over now
            trace?.bargedIn = true
            onAbandonReply?()

        case .resumeReply:
            trace?.outcome = "false-interruption"
            let held = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
            pausedAt = nil
            if speech.isPaused, ReplyResume.after(pausedFor: held) == .inPlace {
                // Only paused, and briefly: carry on from the very sample it
                // stopped at. Nothing was thrown away, so nothing is re-queued.
                Log.write("turn: false interruption — carrying on (held \(Int(held * 1000)) ms)")
                // Back in from the duck, not at full volume at once.
                frontEnd.fadeBackIn()
                speech.resume()
                return
            }
            // An aside that was not a reply (a voice preview, a nudge) has
            // no offsets to rewind to: the tap simply ended it.
            if case .speaking(.aside) = machine.state, !speech.carriesReply {
                heldSpeech.removeAll()
                feed(.ttsDrained)
                return
            }
            if speech.isPaused {
                // Held long enough that picking up mid-word would sound like a
                // skip: start the sentence again, from the last one heard —
                // the re-queue below, which is what a reply that was stopped
                // outright has always done.
                Log.write("turn: false interruption held \(Int(held * 1000)) ms — saying the sentence again")
                speech.stop()
            }
            // The Conductor re-queues from the last sentence heard; what
            // arrived during the interruption is superseded by that.
            heldSpeech.removeAll()
            Log.write("turn: false interruption — resuming from \"\(speech.heardText.suffix(40))\"")
            onResumeReply?()
            // Nothing left to say (all of it had been heard): the reply's
            // audio is over, and the machine must hear that.
            if !speech.busy, case .speaking = machine.state { feed(.ttsDrained) }

        case .cue(let kind):
            frontEnd.cue(kind == .wake ? .wake : .close)

        case .armTimer(let kind, let seconds):
            timers[kind]?.cancel()
            timers[kind] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.timers[kind] = nil
                self.feed(.timer(kind))
            }

        case .cancelTimer(let kind):
            timers[kind]?.cancel()
            timers[kind] = nil

        case .clearPartial:
            onPartial?("")

        case .offerToClose:
            // However the person asked to be asked. Spoken, it is an aside:
            // it must not become the reply that a barge-in would cut, and
            // the window's clock is not restarted by Moe's own voice.
            let how = config.closeOffer
            if how == "spoken" || how == "both" { speakAside(Self.closeOfferLine) }
            if how == "shown" || how == "both" { onOfferToClose?() }
            Log.write("window: offered to close (\(how))")

        case .conversationEnded:
            pendingUnsure = nil
            referenceRms = nil
            // The next turn is likeliest right after this one.
            stt.warmCloud(locale: config.locale)
            // The anchor belongs to one conversation. Keeping it would
            // make the next person to open a session a stranger.
            sessionAnchor = nil
            bargedIn = false
            endTrace()
            onConversationEnded?()
        }
    }

    private func flushHeldSpeech() {
        guard !heldSpeech.isEmpty, voiceReady, Self.mayTalk(in: machine.state), !holdingReply else { return }
        let held = heldSpeech
        heldSpeech.removeAll()
        for line in held { speak(line.text, replyEnd: line.replyEnd) }
    }

    // MARK: - What the pipeline reports

    private func handle(_ out: AudioPipeline.Output) {
        switch out {
        case .level(let l):
            onLevel?(l)
            wakeTeachLevel?(l)

        case .vad(let p, let peakDb, let floorDb, _):
            // Confident speech, clear of the room: the latest moment the
            // person was plainly talking, whether or not a word came of it.
            if p >= 0.85, floorDb.map({ peakDb >= $0 + 5 }) ?? true { lastVoicedAt = Date() }
            self.floorDb = floorDb
            if captureOn { turnVad.add(p) }
            if machine.awaitingWords { onsetVad.add(p) }

        case .speechStarted:
            // Whatever the early read heard, this is more. The energy check
            // at claim time would catch it too; the VAD is the surer signal.
            discardProgressive()
            speechSinceWake = true
            pauseSerial &+= 1
            speechBeganAt = Date()
            vadInSpeech = true
            lastSpeechSeconds = 0
            if captureOn { turnPauses.started(at: Date().timeIntervalSinceReferenceDate) }
            if turnSpeechStartedAt == nil { turnSpeechStartedAt = Date() }
            // No barge-in without the canceller: with voice processing off
            // (a call app has the microphone) the VAD would hear Moe's
            // own voice and stop it on every sentence.
            if case .speaking(let s) = machine.state, s != .aside, !frontEnd.echoCancellationActive {
                return    // Moe's own voice, most likely; no canceller to say otherwise
            }
            // Over Moe's voice (or Moe thinking) a VAD edge is not an
            // interruption — a door, a keyboard, the canceller's residue all
            // make one. The machine ducks, turns the recogniser on and waits
            // for words; `.partial` below reports them.
            let wasWaiting: Bool
            switch machine.state {
            case .attending, .followUp: wasWaiting = true
            default: wasWaiting = false
            }
            feed(.speechStarted)
            if wasWaiting {
                // Everything before this was the silence of waiting.
                pipe { await $0.trimCapture(keepLastSeconds: 1.0) }
            }
            checkTheOwnerAtOnset()

        case .speechRose:
            // A voice rising over speech the VAD was already in. Only over a
            // playing reply is that news — the VAD has been calling Moe's
            // echo speech since the reply began, so the person talking over
            // it makes no edge of their own — and only with the canceller
            // on, as for an edge. The machine waits on words for it exactly
            // as it does for an edge; nothing is ducked or stopped here.
            guard case .speaking(let s) = machine.state, s != .aside,
                  frontEnd.echoCancellationActive else { return }
            feed(.speechRose)

        case .speechEnded:
            vadInSpeech = false
            // The end of "Hey Moe" itself: the request has not been said
            // yet, and the no-speech timer is already waiting for it.
            if inWakeGrace {
                wakeGrace?.cancel(); wakeGrace = nil
                wakeGraceUntil = nil
                Log.write("wake: that was the name; waiting for the request")
                return
            }
            // The same ending, past the grace: the name ran long, or the
            // head was slow. Nothing has started since, so this is still
            // not the request.
            if case .capturing(.wake) = machine.state, !speechSinceWake {
                Log.write("wake: that was the name (late); waiting for the request")
                return
            }
            // Something started after the name and stopped almost at once,
            // and the recogniser has no words for it: a breath, a chair.
            // Not the request either. Measured on the first build with the
            // name guard (2026-09-06 16:27:03Z): such a blip a second after
            // the name had the turn model asked, "finished" at p=0.96, and
            // an empty re-read before the person had said a word.
            if case .capturing(.wake) = machine.state,
               lastStreamingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let began = speechBeganAt, Date().timeIntervalSince(began) < Self.blipSeconds {
                Log.write("wake: a blip (\(Int(Date().timeIntervalSince(began) * 1000)) ms) — still waiting for the request")
                speechSinceWake = false
                speechBeganAt = nil
                feed(.speechWasNoise)
                return
            }
            pauseSerial &+= 1
            if let began = speechBeganAt { lastSpeechSeconds = Date().timeIntervalSince(began) }
            turnSpeechEndedAt = Date()
            if captureOn { turnPauses.ended(at: Date().timeIntervalSinceReferenceDate) }
            // Before the feed: it may decide the turn in this very batch,
            // and `.transcribe` claims what is pending at that moment.
            startProgressiveRead()
            feed(.speechEnded)
            askTurnModel()

        case .woke(let score):
            // Settings recording "Hey Moe" to teach it is not calling it.
            guard !dictating, !settingsHasMic else { return }
            // The second stage first: the recogniser reads what the head
            // fired on, and a lookalike never gets as far as the owner check.
            if wakeConfirming {
                confirmWake(then: { $0.wakeHeard(score) }, score: score)
                return
            }
            wakeHeard(score)

        case .partial(let text):
            if dictating {
                onDictationPartial?(text)
                return
            }
            switch machine.state {
            case .standby:
                if let hit = spotter.match(in: text) {
                    Log.write("WAKE matched")
                    feed(.woke)
                    onSessionOpened?()
                    if !hit.tail.isEmpty { onPartial?(hit.tail) }
                } else if text.count > 160 {
                    // Keep the standby buffer short: a long one costs
                    // accuracy and pushes the phrase out of the window.
                    pipe { await $0.resetAsr() }
                }
            case .attending, .capturing:
                noteWords(text)
                onPartial?(spotter.strippingPhrase(from: text))
            case .followUp:
                noteWords(text)
                if let hit = spotter.match(in: text), hit.tail.isEmpty {
                    feed(.woke)
                } else {
                    onPartial?(spotter.strippingPhrase(from: text))
                }
            default:
                break
            }
            reportWords(text)

        case .endOfUtterance(let text):
            guard !dictating else { return }
            // The endpointer heard a complete utterance: "Hey Moe" is one.
            if inWakeGrace { return }
            // The endpointer is an English model. On French or Hebrew its
            // "they have finished" is a guess about sounds it was never
            // trained on, and acting on it cuts people off mid-sentence.
            // There, silence alone ends the turn — which is what Settings
            // says happens (VOICE-PLAN.md §8, Phase 6).
            guard englishTurnTaking else { return }
            if case .standby = machine.state {
                pipe { await $0.resetAsr() }
                return
            }
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .capturing(.wake) = machine.state, !speechSinceWake {
                if said.isEmpty {
                    Log.write("eou: nothing since the name — ignored")
                    pipe { await $0.resetAsr() }
                    return
                }
                speechSinceWake = true
            }
            if !said.isEmpty { Log.write("eou: \"\(said)\"") }
            lastStreamingText = text
            feed(.endOfUtterance(text))
        }
    }

    /// Tell the machine how many words that could be somebody taking the
    /// floor have arrived — the gate between a sound and a voice.
    ///
    /// The recogniser's transcript is cumulative, so what counts is what came
    /// after `wordBaseline`. While nothing is waiting on words over a reply,
    /// the baseline follows the transcript: a late partial for the last word
    /// of the turn just sent is not the person going on.
    private func reportWords(_ text: String) {
        // Whatever the state: over a reply `lastStreamingText` is not kept,
        // and the judge needs the words the onset brought.
        lastPartial = text
        switch machine.state {
        case .off, .standby, .suspended:
            return
        case .thinking, .deciding, .speaking:
            guard machine.awaitingWords else {
                wordBaseline = TurnPolicy.words(text).count
                wordReport.reset(); rawWordsReported = 0
                return
            }
        case .attending, .capturing, .followUp:
            break
        }
        // The person going on with their own turn: any token at all is
        // them talking (a filler included), and the machine takes it.
        if machine.awaitingWords {
            let raw = max(0, TurnPolicy.words(text).count - wordBaseline)
            if raw > rawWordsReported {
                rawWordsReported = raw
                feed(.wordsGrew)
            }
        }
        // A rise in the count, or a stop word the recogniser revised its way
        // to ("know" → "no") with the count unchanged (review M2).
        guard let (n, urgent) = wordReport.update(text: text, baseline: wordBaseline,
                                                  countNods: machine.wordsCountNods) else { return }
        if machine.awaitingWords, !QuietTurnPolicy.onsetSoundsLikeSpeech(meanVad: onsetVad.mean,
                                                                         chunks: onsetVad.count) {
            Log.write(String(format: "turn: %d word(s) over %@, but the voice detector averaged %.2f — the room, not taken",
                             n, Self.name(machine.state), onsetVad.mean ?? 0))
            return
        }
        if machine.awaitingWords {
            Log.write("turn: \(n) word(s)\(urgent ? ", one of them a stop word" : "") over \(Self.name(machine.state)) — a voice, not the room")
        }
        feed(.wordsHeard(n, urgent: urgent))
    }

    /// A turn boundary: drop the transcript and the check armed against it, so
    /// a work item from the turn just finished cannot end the next one.
    private func forgetWords() {
        lastStreamingText = ""
        wordsGrewAt = Date()
    }

    /// A partial arrived. Remember it, and if it said something new, push the
    /// stall check back.
    private func noteWords(_ text: String) {
        if text.count > lastStreamingText.count {
            wordsGrewAt = Date()
            // The machine's unfinished-sentence clock restarts on this.
            if case .capturing(let s) = machine.state, s != .hold { feed(.wordsGrew) }
        }
        lastStreamingText = text
    }

    /// The VAD saw a pause. Ask the turn model whether the thought is
    /// finished; its verdict ends the turn early or holds the door.
    /// - Parameter onStall: asked because the words stopped, not because a
    ///   pause was heard. Its answer is stale only if words grew since; a VAD
    ///   edge in the meantime — which steady noise produces constantly — does
    ///   not make it stale.
    private func askTurnModel(onStall: Bool = false) {
        guard smartTurnReady, !inWakeGrace else { return }
        guard case .capturing(let s) = machine.state, s != .hold else { return }
        // Nothing said since the name: the buffer is "Hey Moe" and quiet,
        // and this model calls that finished (p 0.92–0.99, measured).
        if s == .wake, !speechSinceWake { return }
        let audio = pipe { await $0.peekCapture(lastSeconds: Double(WhisperFeatures.seconds)) }
        // Where the words last grew, for cutting the noise off the end. Only
        // when there are words: with none, the energy trim is all there is.
        let hasWords = !lastStreamingText.trimmingCharacters(in: .whitespaces).isEmpty
        // A pause just after the name is not the end of a request nobody has
        // made yet (`WakeOwnerCheck.wordlessFinishAfterWake`).
        if s == .wake, !hasWords,
           !WakeOwnerCheck.mayFinishWordless(sinceWake: wokeAt.map { Date().timeIntervalSince($0) }) { return }
        // …or the last moment of plain speech over the room, if that is later
        // (a word the recogniser has not written yet).
        let lastWordAt = max(wordsGrewAt, lastVoicedAt)
        // Measured against when the question was asked, not when the audio
        // came back from the pipeline queue (review L1).
        let askedAt = Date()
        let detector = smartTurn
        let stateWhenAsked = machine.state
        let pauseWhenAsked = pauseSerial
        let wordsWhenAsked = wordsReported
        // The words' meaning, beside the audio (`TurnSemantics`): the rules
        // now, and — only where they have no opinion, and only when switched
        // on — Apple's on-device model, asked at the same moment as Smart
        // Turn and waited for no longer than its budget. Unavailable, late
        // or unclear, it is simply not there (fail open).
        let textWhenAsked = lastStreamingText
        let judge = turnJudge
        let modelVote: Task<(reading: TurnSemantics.Reading?, ms: Int), Never>? =
            config.turnSemanticModel && englishTurnTaking && hasWords
                && TurnSemantics.read(textWhenAsked) == .unknown
            ? Task { await judge.judge(textWhenAsked) } : nil
        Task { [weak self] in
            // Cut the pause off the end first. The VAD does not report a
            // stop until it has heard 250 ms of quiet, so what arrives here
            // always ends in a quarter-second the person did not say — and
            // measured against this exact model, that quarter-second is most
            // of what it answers about. See `TurnAudio`.
            //
            // In noise the energy trim finds nothing to cut — the room is
            // louder than a twentieth of the speech — so first cut at the
            // last word the recogniser wrote, whatever the room is doing.
            var peeked = await audio.value
            if hasWords {
                let since = askedAt.timeIntervalSince(lastWordAt)
                let before = peeked.count
                peeked = TurnAudio.trimAfterLastWord(peeked, sampleRate: Int(AudioPipeline.rate),
                                                     secondsSinceLastWord: since)
                if peeked.count < before, since > 1 {
                    Log.write("turn model: cut \(Self.seconds(before - peeked.count, at: AudioPipeline.rate)) of sound after the last word")
                }
            }
            let samples = TurnAudio.trimTrailingSilence(
                peeked, sampleRate: Int(AudioPipeline.rate),
                keep: TurnAudio.pauseTheModelWasTrainedOn)
            guard samples.count > Int(AudioPipeline.rate * 0.3) else { return }
            let began = Date()
            let p = (try? await detector.probabilityComplete(samples)) ?? nil
            let vote = await modelVote?.value
            guard let self, let p else { return }
            self.turnModelPs.append(Double(p))
            if onStall { self.stallAsks += 1 }
            // Only if nothing has moved on since the pause was seen — and
            // "moved on" includes the person speaking again, which leaves
            // the state value equal.
            guard self.machine.state == stateWhenAsked else { return }
            if onStall {
                guard self.wordsReported == wordsWhenAsked else { return }
            } else {
                guard self.pauseSerial == pauseWhenAsked else { return }
            }
            // A weak "finished" on a transcript that ends mid-clause is not
            // finished; and the words' opinion travels with the audio
            // model's, so when both say "not finished" the machine waits
            // longer (`midClauseSilenceSeconds`). One rule, shared with the
            // Tier-0 replay (`TurnVerdictRule`).
            let verdict = TurnVerdictRule.verdict(p: Double(p), text: self.lastStreamingText)
            // The evidence the wait is planned from (`EndpointPolicy`): the
            // score, the words, and how long it has already been quiet.
            // The model's vote counts only for the words it was shown.
            let model = self.lastStreamingText == textWhenAsked ? vote?.reading : nil
            let evidence = EndpointPolicy.Evidence(p: Double(p), text: self.lastStreamingText,
                                                   pauseSoFar: Date().timeIntervalSince(lastWordAt), model: model)
            let (reading, source) = evidence.reading
            self.lastSemantic = (reading, source)
            if let policy = self.machine.tuning.endpoint {
                let plan = policy.plan(evidence, onStall: onStall)
                // Never the words: the reading, who gave it, and the model's time.
                let judged = vote.map { v in
                    v.reading == nil ? ", on-device model no answer in \(v.ms) ms" : ", on-device model \(v.ms) ms"
                } ?? ""
                Log.write(String(format: "turn model%@: p=%.2f after %.2f s quiet, %d words, words read %@ (%@%@) — decide in %.2f s, hold the reply %.2f s (%@)",
                                 onStall ? " (words stalled)" : "", p, evidence.pauseSoFar, evidence.words,
                                 reading.rawValue, source.rawValue, judged,
                                 plan.decideIn, plan.hold, Self.ms(since: began)))
            } else {
                Log.write("turn model\(onStall ? " (words stalled)" : ""): \(verdict.complete ? "finished" : "mid-thought") (p=\(String(format: "%.2f", p)), \(Self.ms(since: began)))")
            }
            self.feed(.turnVerdict(complete: verdict.complete, stillMidClause: verdict.stillMidClause,
                                   evidence: evidence))
        }
    }

    // MARK: - Owner voice (VOICE-PLAN.md §4.5)

    /// How many turns are in the owner's centroid, and whether it is worth
    /// anything yet. Read from disk, so it is the truth even before the
    /// model has loaded — otherwise Settings would say "no voice" and hide
    /// the button that erases one.
    func ownerVoiceState() async -> (turns: Int, enrolled: Bool) {
        let turns = await ownerVoice.storedTurns
        return (turns, turns >= OwnerVoice.seedCount)
    }

    enum EnrolResult: Equatable {
        case enrolled(turns: Int)
        case heardNothing
        case busy
        case unavailable(String)
    }

    /// Read one prompt aloud and fold it into the owner's voice.
    ///
    /// Settings owns the microphone for the duration: this runs only when
    /// no turn is in flight, because taking the capture buffer out from
    /// under one loses it.
    func enrolOwnerVoice(seconds: Double = 4,
                         onListening: (@MainActor () -> Void)? = nil) async -> EnrolResult {
        guard !settingsHasMic else { return .busy }
        guard !dictating, !externalInput, machine.state == .off || machine.state == .standby else { return .busy }
        guard await Self.requestMicrophone() else { onError?(Self.micDeniedMessage); return .unavailable(Self.micDeniedMessage) }
        await loadModels()
        guard ownerVoiceReady else {
            return .unavailable("Moe's voice model isn't on this Mac yet. It downloads in the background; try again in a few minutes.")
        }
        settingsHasMic = true
        defer {
            settingsHasMic = false
            if !machine.inConversation, machine.state == .off {
                frontEnd.scheduleTeardown(after: idleTeardownSeconds)
            }
        }
        do { try frontEnd.start() } catch {
            return .unavailable("The microphone is unavailable: \(error.localizedDescription)")
        }
        pipe { await $0.setCapture(true, prerollSeconds: 0) }
        // The graph and the capture are up now, not when the button was
        // pressed: the prompt says "read this" only once it can be heard.
        _ = await pipe { await $0.captureSeconds }.value
        onListening?()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let audio = await pipe { await $0.takeCapture() }.value
        pipe { await $0.setCapture(false, prerollSeconds: 0) }
        // Silence is not an enrolment: a room with nobody in it would
        // teach the centroid the fan.
        guard Self.rms(audio) > 0.01 else { return .heardNothing }
        // The first few seed it; after that a voice that disagrees with
        // what Moe knows is refused, so a guest at an unlocked Mac cannot
        // walk the centroid over to themselves.
        let stored = await ownerVoice.storedTurns
        _ = await ownerVoice.enrol(audio, known: stored < OwnerVoice.seedCount)
        let turns = await ownerVoice.storedTurns
        guard turns > stored else { return .heardNothing }
        // The voice has been taught again: the doubt was about the old one.
        believeOwnerVoiceAgain()
        return .enrolled(turns: turns)
    }

    func forgetOwnerVoice() async {
        await ownerVoice.forget()
        // No enrolment, nothing to doubt — and the next one starts trusted.
        believeOwnerVoiceAgain()
    }

    private func believeOwnerVoiceAgain() {
        if !trustOwnerVoiceForWake { Log.write("WAKE: the voice was re-taught — asking it about wakes again") }
        wakeOwnerTrust.clear()
        trustOwnerVoiceForWake = true
        wakesRefusedInARow = 0
    }

    // MARK: - Teach Moe its name (Settings › Voice)

    enum WakeTeachResult: Equatable {
        /// Measured, and the threshold this Mac now runs (`changed` when
        /// it is not the one it was running).
        case done(WakeCalibration.Pick, changed: Bool)
        case heardNothing
        case busy
        case unavailable(String)
    }

    /// How one clip went: kept (and where), or not kept and why.
    enum WakeClip: Equatable {
        /// Saved; `quiet` when the card should say it was quiet.
        case kept(URL, quiet: Bool)
        case rejected(WakeTeachFlow.Problem)
    }

    /// The level the teach card's meter draws; set while the card holds
    /// the microphone, nil otherwise.
    private var wakeTeachLevel: (@MainActor (Float) -> Void)?

    /// Open the microphone for the teach card (`WakeTeachCard`), which
    /// then records one line at a time with `recordWakeClip` and gives
    /// the microphone back with `closeWakeTeach` — on finishing, on a
    /// pause and on cancel. Settings owns the microphone in between, as
    /// for an enrolment. Nil when it is open; otherwise why not.
    ///
    /// Until 2026-09-24 this was one call that ran the whole script and
    /// skipped any clip it did not like without saying so; the card
    /// needs to show each clip, redo one, and stop and carry on.
    func openWakeTeach(level: @escaping @MainActor (Float) -> Void) async -> WakeTeachResult? {
        if settingsHasMic, wakeTeachLevel != nil { wakeTeachLevel = level; return nil }
        guard !settingsHasMic else { return .busy }
        guard !dictating, !externalInput, machine.state == .off || machine.state == .standby else { return .busy }
        guard await Self.requestMicrophone() else { onError?(Self.micDeniedMessage); return .unavailable(Self.micDeniedMessage) }
        await loadModels()
        guard vad != nil else {
            return .unavailable("Moe's voice activity detector isn't loaded yet. Try again in a moment.")
        }
        do { try frontEnd.start() } catch {
            return .unavailable("The microphone is unavailable: \(error.localizedDescription)")
        }
        settingsHasMic = true
        wakeTeachLevel = level
        return nil
    }

    /// Give the microphone back. Safe to call when it is not held.
    func closeWakeTeach() {
        guard settingsHasMic, wakeTeachLevel != nil else { return }
        wakeTeachLevel = nil
        pipe { await $0.setCapture(false, prerollSeconds: 0) }
        settingsHasMic = false
        if !machine.inConversation, machine.state == .off {
            frontEnd.scheduleTeardown(after: idleTeardownSeconds)
        }
    }

    /// One line of the `--wake-record` session, driven by the card: the
    /// line is on screen, the VAD says when it was said, and the clip is
    /// saved where the Terminal flow and the trainer look. The same waits,
    /// trims and margins as the loop it came out of; what changed is that
    /// a clip not kept says why (`WakeTeachFlow.judge`) instead of being
    /// skipped in silence. Nil when the task was cancelled — a pause, a
    /// redo, the card closing — and then nothing is saved.
    func recordWakeClip(_ prompt: WakeRecorder.Prompt, number: Int, session: String,
                        onSpeech: @escaping @MainActor () -> Void) async -> WakeClip? {
        guard settingsHasMic, wakeTeachLevel != nil else { return nil }
        pipe { await $0.setCapture(true, prerollSeconds: 0.5) }
        // A moment to read the line; everything before it is thrown away,
        // the tail of the previous clip included.
        try? await Task.sleep(nanoseconds: 700_000_000)
        _ = await pipe { await $0.takeCapture() }.value
        var waited = 0.0
        while !vadInSpeech, waited < 15, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        if Task.isCancelled { return nil }
        guard vadInSpeech else {
            Log.write("wake teach: clip \(number) (\(prompt.folder)) — not kept: nothingHeard (no speech in 15 s)")
            return .rejected(.nothingHeard)
        }
        onSpeech()
        let began = await pipe { await $0.captureSeconds }.value
        var speaking = 0.0
        while vadInSpeech, speaking < 12, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
            speaking += 0.1
        }
        let ended = await pipe { await $0.captureSeconds }.value
        // The VAD's own lag plus a little tail: the last consonant.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let whole = await pipe { await $0.takeCapture() }.value
        if Task.isCancelled { return nil }
        let samples = WakeRecorder.trim(whole, from: began, to: ended, head: 0.35, tail: 0.45)
        // Judged on the audio exactly as recorded: in standby that is the
        // unprocessed microphone the wake word itself listens to, so a
        // voice loud enough to wake Moe is loud enough to teach it. Too
        // short, distorted or nothing over the room is not kept; quiet is
        // kept with a note (`WakeTeachFlow.judge` has the measurements).
        let level = WakeTeachFlow.ClipLevel.measure(samples, rate: AudioPipeline.rate)
        let verdict = WakeTeachFlow.judge(level)
        Log.write("wake teach: clip \(number) (\(prompt.folder)) — \(level.description) — \(verdict.words)")
        if case .reject(let problem) = verdict { return .rejected(problem) }
        let folder = WakeRecordings.dir.appendingPathComponent(prompt.folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(String(format: "%@-app-%03d.wav", session, number))
        do {
            try WakeRecorder.write(samples, to: url)
        } catch {
            Log.write("wake teach: could not save \(url.lastPathComponent): \(error)")
            return .rejected(.nothingHeard)
        }
        return .kept(url, quiet: verdict == .keepQuiet)
    }

    /// Score every clip on disk and apply the pick. `progress` hears
    /// (scored, of) as each clip is replayed — the card's honest bar.
    func measureWakeTeach(progress: @escaping @MainActor (Int, Int) -> Void) async -> WakeTeachResult {
        await loadModels()
        guard let vad else {
            return .unavailable("Moe's voice activity detector isn't loaded yet. Try again in a moment.")
        }
        return await measureWakeThreshold(vad: vad, progress: progress)
    }

    /// Every clip on disk through the bench, then the pick — applied to
    /// the running pipeline and written for the next launch.
    private func measureWakeThreshold(vad: VadManager,
                                      progress: @escaping @MainActor (Int, Int) -> Void) async -> WakeTeachResult {
        // Its own head: the live one may still be loading, and the
        // incremental state must not be shared with a pipeline mid-run.
        let head = WakeHead()
        do { try await head.load() } catch {
            return .unavailable("The wake word model is not in this copy of Memoe (\(error)).")
        }
        let shipped = await head.shippedPolicy
        let current = await head.policy
        var positives: [[WakeCalibration.Sample]] = []
        var others: [[WakeCalibration.Sample]] = []
        let files = WakeBench.files(under: WakeRecordings.dir)
        progress(0, files.count)
        for (n, file) in files.enumerated() {
            defer { progress(n + 1, files.count) }
            guard let (mono, rate) = WakeBench.decode(file) else { continue }
            let replay = await WakeBench.replay(mono, rate: rate, head: head, vad: vad, policy: current)
            if WakeRecordings.isPositive(file) { positives.append(replay.trace) } else { others.append(replay.trace) }
        }
        guard let pick = WakeCalibration.pick(positives: positives, confusables: others,
                                              shipped: shipped, current: current) else {
            return .heardNothing
        }
        let changed = pick.threshold != current.threshold
        do { try WakeTuning(pick, head: await head.identity).save() } catch {
            Log.write("wake teach: could not write \(WakeTuning.file.path): \(error)")
        }
        await applyWakeThreshold(pick.threshold)
        Log.write(String(format: "wake teach: threshold %.2f (was %.2f) — %@", pick.threshold, current.threshold,
                         WakeCalibration.summary(pick, changed: changed)))
        return .done(pick, changed: changed)
    }

    /// This Mac's threshold, on the head and on the pipeline's copy of
    /// the policy — nil for the sidecar's. The head re-reads `WakeTuning`
    /// when it loads, so before that there is nothing to re-attach.
    func applyWakeThreshold(_ t: Float?) async {
        let head = wakeHead
        await head.setThreshold(t)
        applyWakeHeadPolicy()
    }

    // MARK: - The wake word's second stage (WakeConfirm)

    /// How much audio before a head hit the recogniser reads: the phrase
    /// ends 0.25–0.4 s before the head fires, and "Hey Moe" is ~0.6 s.
    nonisolated static let wakeConfirmSeconds = 2.0

    /// Every head hit is read by the local recogniser before Moe wakes:
    /// when asked for, and only where the local recogniser reads this
    /// language and has loaded.
    private var wakeConfirming: Bool {
        config.wakeConfirm && accurateReady && !SpeechLanguages.usesWhisper(config.locale)
    }

    /// The head's policy for what the second stage can do right now: its own
    /// threshold, or `wakeConfirmThreshold` while every hit is confirmed.
    private func applyWakeHeadPolicy() {
        let head = wakeHead
        let confirming = wakeConfirming
        let threshold = Float(config.wakeConfirmThreshold)
        Task { [weak self] in
            guard await head.isLoaded else { return }
            let base = await head.policy
            let policy = WakeConfirm.headPolicy(base, confirming: confirming, threshold: threshold)
            self?.pipe { await $0.attach(wake: head, policy: policy) }
            if confirming, policy.threshold < base.threshold {
                Log.write(String(format: "wake: head at %.2f, every hit confirmed by the recogniser (its own line %.2f)",
                                 policy.threshold, base.threshold))
            }
        }
    }

    /// Did the recogniser hear the name in what the head fired on?
    private func confirmWake(then accept: @escaping (VoiceEngine) -> Void, score: Float) {
        let window = pipe { await $0.peekRecent(lastSeconds: Self.wakeConfirmSeconds) }
        let parakeet = stt.parakeet
        let spotter = spotter
        Task { [weak self] in
            let audio = await window.value
            let began = Date()
            let text = (try? await parakeet.transcribe(samples16k: audio, language: "en")) ?? ""
            guard let self else { return }
            guard WakeConfirm.heardTheName(text, spotter: spotter) else {
                // The words belong to whoever said them: the count, not the text.
                Log.write(String(format: "WAKE refused (%.2f): the recogniser heard no name in it (%d word(s), %@)",
                                 score, TurnPolicy.words(text).count, Self.ms(since: began)))
                return
            }
            Log.write(String(format: "wake: the recogniser heard the name (%@)", Self.ms(since: began)))
            accept(self)
        }
    }

    /// The clips and the threshold they chose, gone; the shipped one back.
    func forgetWakeRecordings() async {
        WakeRecordings.removeAll()
        WakeTuning.remove()
        await applyWakeThreshold(nil)
        Log.write("wake teach: recordings and threshold forgotten")
    }

    // MARK: - Does the canceller work here? (VOICE-PLAN.md §7)

    /// Speak a sentence with the microphone open and measure how much of
    /// it comes back. The one honest answer to "can I interrupt Moe on
    /// this Mac", which depends on the microphone and speakers in use,
    /// not on a setting.
    ///
    /// Runs only from Settings, on the user's request: it takes about
    /// eight seconds and Moe talks during it.
    func runEchoTest() async -> EchoTest.Verdict {
        guard !settingsHasMic, !dictating, !externalInput,
              machine.state == .off || machine.state == .standby else {
            return .unavailable("Moe is busy with the microphone right now. Try again in a moment.")
        }
        guard await Self.requestMicrophone() else { return .unavailable(Self.micDeniedMessage) }
        await loadModels()
        guard modelsReady else { return .unavailable("Moe's speech models are still loading.") }
        do { try frontEnd.start() } catch {
            return .unavailable("The microphone is unavailable: \(error.localizedDescription)")
        }
        guard frontEnd.echoCancellationActive else {
            let who = frontEnd.echoCancellationHeldBy
            return .unavailable(who.map { "\($0) has the microphone, so echo cancellation is off while your call is on." }
                                ?? "Echo cancellation is not running on this device.")
        }
        settingsHasMic = true
        defer {
            settingsHasMic = false
            if machine.state == .off { frontEnd.scheduleTeardown(after: idleTeardownSeconds) }
        }

        let phrase = "Testing, one two three. This is what my voice sounds like to your microphone."
        // The room, with nothing playing.
        pipe { await $0.setCapture(true, prerollSeconds: 0) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let floor = await pipe { await $0.takeCapture() }.value
        // The room, while Moe speaks.
        speech.beginReply()
        speech.speak(phrase)
        try? await Task.sleep(nanoseconds: 400_000_000)
        var waited = 0
        while speech.busy, waited < 120 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        let during = await pipe { await $0.takeCapture() }.value
        pipe { await $0.setCapture(false, prerollSeconds: 0) }
        // A call app arriving mid-test takes voice processing away, and
        // what was measured after that is a measurement of nothing.
        guard frontEnd.echoCancellationActive else {
            return .unavailable("A call started while Moe was measuring. Try again when the call ends.")
        }
        // A muted or absent input device gives silence, and silence would
        // read as a perfect canceller.
        guard Self.rms(floor) > 1e-5 || Self.rms(during) > 1e-5 else {
            return .unavailable("No sound is reaching Moe from this microphone. Check the input device in System Settings.")
        }

        let heardBack = during.count > Int(AudioPipeline.rate * 0.5)
            ? await transcribe(during) : ""
        let played = !speech.heardText.isEmpty
        let leak = EchoTest.leakDb(floorRms: Self.rms(floor), spokenRms: Self.rms(during))
        // Its own words back out of the microphone is the proof: a level
        // rise alone could be the fan or a passing truck.
        let ownWords = EchoFilter.isEcho(heardBack, of: phrase)
        stopSpeaking()
        let verdict = EchoTest.verdict(leakDb: leak, heardOwnWords: ownWords, playedAnything: played)
        Log.write(String(format: "echo test: leak %.1f dB, own words %@, played %@ — %@",
                         leak, ownWords ? "yes" : "no", played ? "yes" : "no", "\(verdict)"))
        return verdict
    }

    // MARK: - Is this for me? (Phase 5)

    /// Is this Moe's own voice returning through the microphone?
    ///
    /// Two signals, because neither is enough alone. The words: a
    /// recogniser hearing quiet echo writes something *like* what was
    /// said, and a short reply mangles badly enough that the ordinary
    /// threshold misses it ("Sure, take your time." came back as "Sugar
    /// take me", scoring 0.69 against a bar of 0.8). And the loudness:
    /// whatever the canceller leaves is far below a person actually
    /// speaking, which holds in every language and for every sentence.
    private func moeHearingItself(_ text: String, spoken: String,
                                  audio: [Float], seconds: Double) async -> BargeInDecision.Check? {
        guard !spoken.isEmpty else { return nil }
        let spokenAudio = Self.speechTail(audio, seconds: seconds)
        // The voice itself, where there is an enrolment to compare against.
        // This is the signal that actually separates the two speakers:
        // measured within the same minute, the person scored 0.60-0.69 and
        // Moe's own synthesised voice 0.17. Nothing about the words or the
        // level comes close to that, and it holds in any language.
        if ownerVoiceReady, seconds >= 0.8, let owner = await ownerVoice.score(spokenAudio) {
            if owner < 0.35 {
                Log.write(String(format: "echo: the voice scored %.2f against yours — that is Moe", owner))
                return .ownerVoice
            }
            // A voice that *is* the owner's cannot be Moe's, whatever the
            // words look like. Say so and stop guessing.
            if owner >= 0.5 { return nil }
        }
        // A short transcript is where the recogniser's guesses are worst,
        // so the bar comes down — but only against what Moe was saying.
        let bar = text.count < 30 ? 0.6 : 0.8
        if EchoFilter.isEcho(text, of: spoken, threshold: bar) { return .echoText }
        // Nothing like the words, but far too quiet to be the person who
        // opened this session: the canceller's residue.
        if let reference = referenceRms {
            let level = Self.rms(spokenAudio) / max(reference, 1e-6)
            if level < 0.3 {
                Log.write(String(format: "echo: %.2f of the level this session opened at", level))
                return .loudness
            }
        }
        return nil
    }

    /// Does this mean "we are finished"?
    ///
    /// The English phrases are a fast path that costs nothing; the model
    /// is what actually decides, because the sentence may be in any
    /// language and there is no published classifier for this at all.
    /// Without the model (Apple Intelligence off) the fast path is all
    /// there is — and then the offer to close is what saves the person
    /// from a window that will not take a hint.
    private func meansWeAreDone(_ text: String) async -> Bool {
        if Addressee.isDismissal(text) || Addressee.isClosePhrase(text) { return true }
        guard await judge.judge(moeSaid: speech.spokenText, heard: text) == .done else { return false }
        Log.write("addressee: the model read that as a goodbye")
        return true
    }

    // MARK: - Is it the owner? (OwnerGate, PLAN.md Step 1.4)

    /// A second into a hands-free capture — the window, or the person going
    /// on after a decision — score the voice, and end the capture if it is
    /// clearly somebody else's. Early, so the TV does not hold a turn open
    /// until the ceiling; the end-of-turn check in `.transcribe` catches what
    /// this is too early for.
    private func checkTheOwnerAtOnset() {
        guard ownerVoiceReady, case .capturing(let s) = machine.state, s == .followUp || s == .wake || s == .hotkey
        else { return }
        // Only the hands-free rest of a session: the window, or a continuation.
        // The first capture after the name or the hotkey is the person who
        // opened the session.
        guard s == .followUp else { return }
        let stateThen = machine.state
        let serial = pauseSerial
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.machine.state == stateThen, self.pauseSerial == serial else { return }
            // The speech since the onset, not the wait before it.
            let heard = Self.speechTail(await self.pipe { await $0.peekCapture(lastSeconds: 2.0) }.value,
                                        seconds: 1.2)
            let seconds = Double(heard.count) / AudioPipeline.rate
            guard self.machine.state == stateThen,
                  await self.clearlyNotTheOwner(heard, seconds: seconds, text: self.lastStreamingText, at: "the onset",
                                                continuation: self.machine.capturingTheRestOfATurn)
            else { return }
            guard self.machine.state == stateThen else { return }
            self.feed(.notTheOwner)
        }
    }

    /// `OwnerGate` on this audio: against the session's anchor voice when the
    /// session has one (a guest who opened it is its owner), else against the
    /// owner's enrolment. Logs the number, never the words.
    private func clearlyNotTheOwner(_ audio: [Float], seconds: Double, text: String, at moment: String,
                                    continuation: Bool) async -> Bool {
        guard ownerVoiceReady else { return false }
        let named = NameMatch.namesMoe(text, spotter: spotter)
        let score: Double?
        let enrolled: Bool
        if let anchor = sessionAnchor {
            enrolled = true
            score = await ownerVoice.embedding(audio).map { Double(OwnerVoice.cosine($0, anchor)) }
        } else {
            enrolled = await ownerVoice.storedTurns >= OwnerVoice.seedCount
            score = await ownerVoice.score(audio).map(Double.init)
        }
        let verdict = OwnerGate.verdict(score: score, enrolled: enrolled, named: named, seconds: seconds)
        let outcome = OwnerGate.outcome(verdict, enforce: config.ownerGateEnforce, continuation: continuation)
        // Every score is written down, dropped or not: these numbers are
        // how the line is set before the gate is ever allowed to act.
        if let score {
            let rounded = (score * 1000).rounded() / 1000
            if trace != nil { trace?.ownerGateScore = rounded; trace?.ownerGate = outcome.rawValue }
            else { pendingOwnerGate = (rounded, outcome.rawValue) }
        }
        switch outcome {
        case .pass:
            return false
        case .shadow:
            Log.write(String(format: "owner gate (not enforcing): at %@ the voice scored %.2f against %@ — would have dropped it",
                             moment, score ?? 0, sessionAnchor == nil ? "your enrolment" : "the voice that opened this"))
            if config.voiceDebugAudio {
                // The audio that was scored, not the capture as it is now: at
                // the end of a turn the capture has already been handed over,
                // and on 2026-09-29 22:08 this saved 2.9 s of zeros beside a
                // 0.22 that had been read off 20 s of speech.
                let scored = audio
                let clip = Task<[Float], Never> { scored }
                saveDecisionClip(before: clip, kind: "owner-gate", reason: "shadow", words: wordsReported,
                                 beforeSeconds: Double(scored.count) / AudioPipeline.rate)
            }
            return false
        case .drop:
            Log.write(String(format: "owner gate: at %@ the voice scored %.2f against %@ — not them; dropped",
                             moment, score ?? 0, sessionAnchor == nil ? "your enrolment" : "the voice that opened this"))
            return true
        }
    }

    /// An owner-gate reading taken before this turn had a trace.
    private var pendingOwnerGate: (score: Double, outcome: String)?

    /// A turn that opened a session (the name, or the key) is the
    /// owner's and the loudness reference for the window that follows.
    private func openedSession(with audio: [Float], seconds: Double, wake: Bool) {
        referenceRms = Self.rms(Self.speechTail(audio, seconds: seconds))
        guard ownerVoiceReady, seconds >= 1 else { return }
        let owner = ownerVoice
        let spoken = Self.speechTail(audio, seconds: seconds)
        // The anchor: whoever opened this session owns it, whether they
        // said the name or held the key. Every turn in the window is
        // scored against *them*, not against the owner in general — which
        // is what lets a guest be answered and the person beside them be
        // ignored. VOICE-ISOLATION.md §2.
        Task { [weak self] in
            let e = await owner.embedding(spoken)
            await MainActor.run { self?.sessionAnchor = e }
        }
        // Only the name enrols: anyone can press the key on this Mac,
        // and a guest's three held turns would make the owner a stranger.
        guard wake else { return }
        Task { await owner.enrol(spoken) }
    }

    /// Decide, inside the window, whether `text` was for Moe. Returns
    /// the text to submit ("" to discard). A turn the rules cannot
    /// place goes to the on-device judge when there is one; otherwise it
    /// is kept for one turn so "Moe?" can claim it.
    private func addressed(_ text: String, named: Bool, audio: [Float],
                           seconds: Double, moeAsked: Bool, overAReply: Bool = false) async -> String {
        if let kept = pendingUnsure, Addressee.isNameOnly(text) {
            pendingUnsure = nil
            Log.write("heard: the name — takes the turn kept a moment ago")
            return kept
        }
        let moeSaid = speech.spokenText
        // The speech, not the capture: the pre-roll and the wait for the
        // decision are silence, and silence in the buffer moves both the
        // embedding and the level.
        let spoken = Self.speechTail(audio, seconds: seconds)
        let owner = ownerVoiceReady && seconds >= 1 ? await ownerVoice.score(spoken) : nil
        let level = referenceRms.map { Self.rms(spoken) / max($0, 1e-6) }
        // From Moe's last word to this speech starting, not to now: the
        // re-read and the endpointer's wait are not the person pausing.
        let since: Double? = replyEndedAt.flatMap { end in
            guard let began = speechBeganAt, began > end else { return nil }
            return began.timeIntervalSince(end)
        }
        let signals = Addressee.Signals(
            text: text, namedMoe: named,
            secondsSinceReply: since,
            moeAskedQuestion: moeAsked,
            levelRatio: level, ownerScore: owner, speechSeconds: seconds,
            english: englishTurnTaking)
        // The anchor gate, before the words get a vote. A background voice
        // that says something request-shaped can out-score a −1.5 in the
        // fusion; whose voice it is should not be one term among many when
        // it is the whole question. VOICE-ISOLATION.md §0, §3 Tier 0.
        var anchor: Float?
        var anchorInBand = false
        if let sessionAnchor, seconds >= 1, let e = await ownerVoice.embedding(spoken) {
            anchor = OwnerVoice.cosine(e, sessionAnchor)
        }
        var verdict = Addressee.verdict(signals)
        var by = "rules"
        if let anchor {
            if anchor < Self.anchorRejectBelow, !Addressee.anchorOverruled(signals) {
                // Not the voice this conversation belongs to. Naming Moe
                // is the one thing that still gets through: a second
                // person can join a conversation by asking for it.
                if !named {
                    Log.write(String(format: "window: another voice (anchor %.2f, level %@, owner %@); dropped", anchor,
                                     level.map { String(format: "%.2f", $0) } ?? "-",
                                     owner.map { String(format: "%.2f", $0) } ?? "-"))
                    keepUnsent(text)
                    pendingUnsure = nil
                    let decided = trace?.decidedBy ?? ""
                    trace?.decidedBy = decided + " addressee:anchor"
                    return ""
                }
            } else if anchor >= Self.anchorRejectBelow, anchor < Self.anchorAcceptAbove,
                      verdict == .directed, !named {
                // (Under the reject line but overruled by the room: the words
                // decide, as though there were no anchor.)
                // In the band: might be them, might not. Keep it rather
                // than answer it — a "Moe?" in the next turn claims it.
                verdict = .unsure
                by = "anchor-unsure"
                anchorInBand = true
            }
        }
        if verdict == .unsure {
            if let judged = await judge.judge(moeSaid: moeSaid, heard: text) {
                verdict = judged
                by = "judge"
            } else if !anchorInBand, Addressee.leansDirected(signals, above: overAReply ? 0 : 0.75) {
                // No model on this Mac (or it took too long): a turn that
                // looks like a request with nothing pointing away is taken,
                // because dropping every ambiguous one makes the window
                // useless. The acoustic and owner signals are the guard.
                verdict = .directed
                by = "rules (no judge)"
            }
        }
        // The words of a turn that was not for Moe belong to whoever
        // said them: the log gets the numbers, never the sentence.
        let detail = String(format: "%d words, score %.1f, level %@, owner %@, anchor %@",
                            text.split(separator: " ").count,
                            Addressee.score(signals),
                            level.map { String(format: "%.2f", $0) } ?? "-",
                            owner.map { String(format: "%.2f", $0) } ?? "-",
                            anchor.map { String(format: "%.2f", $0) } ?? "-")
        switch verdict {
        case .directed:
            Log.write("heard: \"\(text)\" — for Moe (\(by); \(detail))")
            pendingUnsure = nil
            let decided = trace?.decidedBy ?? ""
            trace?.decidedBy = decided + " addressee:\(by)"
            return text
        case .notDirected:
            Log.write(overAReply
                      ? "window: talking to somebody else over Moe (\(by); \(detail)); carrying on"
                      : "window: not for Moe (\(by); \(detail)); dropped")
            pendingUnsure = nil
            return ""
        case .done:
            // The model read a goodbye in a turn the fast path did not
            // recognise — a language it does not cover, most likely.
            Log.write("window: the model read a goodbye (\(detail)); stopping")
            pendingUnsure = nil
            feed(.stopAll)
            return ""
        case .unsure:
            Log.write("window: unsure (\(by); \(detail)); kept for one turn")
            pendingUnsure = text
            // Never lost without a trace. 2026-09-29 21:48: 202 words, the
            // owner's own, dropped here and kept nowhere — the log holds the
            // numbers and never the sentence, and the audio clip only the last
            // ten seconds — and they could not remember what they had said.
            // Something that long is somebody's thought; it goes into the
            // conversation, not sent, where they can read it and say it again.
            keepUnsent(text)
            return ""
        }
    }

    /// A turn in the window this long that Moe does not answer is shown in
    /// the conversation rather than dropped without a trace.
    static let keepUnsentWords = 12

    private func keepUnsent(_ text: String) {
        guard text.split(separator: " ").count >= Self.keepUnsentWords else { return }
        onNotice?("Not sent to Moe — it wasn't sure that was meant for it: \u{201C}\(text)\u{201D}")
    }

    /// The last `seconds` of speech from a capture that also holds
    /// pre-roll and the wait for the decision.
    /// The person's voice out of a turn's capture: the pause trimmed off the
    /// end, then the last `seconds` of what is left.
    ///
    /// Four things read this — the loudness reference, the level ratio the
    /// addressee scorer uses, the owner-voice embedding, and the echo test —
    /// and all four were being handed silence.
    ///
    /// The capture ends where the VAD said speech stopped, which is 250 ms
    /// *after* it stopped, plus however long the decision took. Taking the
    /// last `seconds` of that buffer therefore takes the pause and the end of
    /// the sentence, and for a short answer it takes the pause alone. The
    /// comment this replaces knew silence "moves both the embedding and the
    /// level" and took the tail to avoid it — but the silence is at the tail.
    ///
    /// Measured over 345 logged turns before this fix, `levelRatio` — the
    /// speech's loudness against the loudness this session opened at, so it
    /// should sit near 1 — read:
    ///
    ///     min 0.000   p10 0.000   p50 0.081   p90 1.820   max 92.240
    ///
    /// A median of 0.081 is not a person talking more quietly, it is a
    /// measurement of the gap after they finished. 202 of those 345 fell
    /// under the scorer's 0.35 cliff and took its −1.5, the largest single
    /// term it has, and **82 of 200 turns inside the window — 41% — were
    /// dropped as "not for Moe"**. That is the owner saying he answered a
    /// question and Moe "didn't even catch anything I said, and then it just
    /// stopped".
    ///
    /// The thresholds those four use are deliberately left alone in the same
    /// change. They were chosen against this signal, and moving them and the
    /// measurement together would leave neither testable. **Falsifier:
    /// `levelRatio` should now centre near 1.0, and the drop rate should
    /// fall well below 41%.**
    private static func speechTail(_ audio: [Float], seconds: Double) -> [Float] {
        let voiced = TurnAudio.trimTrailingSilence(audio, sampleRate: Int(AudioPipeline.rate))
        guard seconds > 0, seconds.isFinite else { return voiced }
        let want = Int(seconds * AudioPipeline.rate)
        guard want > 0, voiced.count > want else { return voiced }
        return Array(voiced.suffix(want))
    }

    private static func rms(_ audio: [Float]) -> Float {
        guard !audio.isEmpty else { return 0 }
        var acc: Float = 0
        for x in audio { acc += x * x }
        return sqrt(acc / Float(audio.count))
    }

    // MARK: - The early read

    /// Start the accurate read now, on the VAD's edge, rather than after the
    /// turn is decided. `ProgressiveRead` has the reasoning and the numbers;
    /// the short of it is that the model's cost is a fixed encoder pass
    /// whatever the audio, so the only way to take it off the turn is to
    /// have paid it before the turn is decided.
    ///
    /// Two tasks, not one: the snapshot lands as soon as the pipeline hands
    /// the audio over, the read when the model is done. The claim checks the
    /// snapshot against the turn first and waits for the model only when the
    /// read will be used — a stale read costs the turn nothing extra.
    private func startProgressiveRead() {
        guard ProgressiveRead.shouldStart(enabled: config.earlyRead,
                                          accurateReady: accurateReady,
                                          capturing: captureOn,
                                          local: stt.accurateReadIsLocal(locale: config.locale))
        else { return }
        discardProgressive()
        let audio = pipe { await $0.peekCapture() }
        let began = Date()
        let snapshot = Task<ProgressiveRead.Snapshot?, Never> {
            let samples = await audio.value
            guard samples.count > Int(AudioPipeline.rate * 0.25) else { return nil }
            return ProgressiveRead.Snapshot(samples)
        }
        let read = Task<Heard, Never> { [weak self] in
            guard await snapshot.value != nil, let self else { return Heard() }
            let samples = await audio.value
            let heard = await self.transcribeScored(samples)
            if !Task.isCancelled {
                Log.write("stt: progressive read \(Self.seconds(samples.count, at: AudioPipeline.rate)) in \(Self.ms(since: began))")
            }
            return heard
        }
        progressive.begin(ProgressivePending(snapshot: snapshot, read: read, began: began))
    }

    private func discardProgressive() {
        guard let p = progressive.claim() else { return }
        p.read.cancel()
    }

    /// The accurate read of a turn: the early one, when the turn is that
    /// read plus quiet; otherwise the whole buffer, exactly as before the
    /// early read existed. With the flag off `early` is always nil and this
    /// is the old call.
    private func accurateRead(_ audio: [Float], early: ProgressivePending?) async -> Heard {
        guard let early else { return await transcribeScored(audio) }
        let waited = Date()
        var why = "no snapshot"
        if let snap = await early.snapshot.value {
            switch ProgressiveRead.coverage(of: snap, in: audio) {
            case .stands:
                let heard = await early.read.value
                Log.write("stt: tail read \(Self.seconds(audio.count - snap.count, at: AudioPipeline.rate)) in \(Self.ms(since: waited)) — quiet after the progressive read, which stood")
                return heard
            case .stale(let reason):
                why = reason
            }
        }
        early.read.cancel()
        let began = Date()
        let heard = await transcribeScored(audio)
        Log.write("stt: tail read \(Self.seconds(audio.count, at: AudioPipeline.rate)) in \(Self.ms(since: began)) — whole buffer; progressive read stale: \(why)")
        return heard
    }

    /// How long the accurate read may take before the turn gives up on it.
    ///
    /// The rule and the incident that produced it are in
    /// `TurnReadDeadline`. The short of it: this is a backstop against a
    /// wedged model, and a backstop that is tighter than the backend's own
    /// budget stops being a backstop — on 2026-09-09 a flat 30 s here beat
    /// AssemblyAI's 51.7 s and threw away a 59.6 s dictation the cloud
    /// went on to transcribe correctly 14 s later.
    private func transcribe(_ audio16k: [Float]) async -> String {
        await transcribeScored(audio16k).text
    }

    /// The accurate re-read, with the engine's own confidence in it.
    private func transcribeScored(_ audio16k: [Float], deadline: TimeInterval? = nil) async -> Heard {
        let deadline = deadline
            ?? TurnReadDeadline.seconds(forAudioSeconds: Double(audio16k.count) / Double(AudioPipeline.rate))
        // What Moe last said, for the cloud recogniser's `agent_context`:
        // read here, on the main actor, rather than from the engine's own
        // thread later.
        stt.noteAgentContext(speech.spokenText)
        let work = Task { () -> Heard in
            do {
                let r = try await self.stt.transcribeScored(samples16k: audio16k,
                                                            locale: self.config.locale)
                return Heard(text: r.text, confidence: r.confidence)
            } catch is CancellationError {
                // An early read the turn did not need, or the deadline's
                // own cancel after it has already answered. Not a failure.
                return Heard()
            } catch {
                Log.write("accurate transcription failed: \(error)")
                return Heard()
            }
        }
        // Whichever comes first, and the loser is never waited for. A task
        // group would not do: `await someTask.value` is not cancellable, so
        // cancelling the group still waits for the task it is racing —
        // which made every read take the full deadline.
        let heard = await withCheckedContinuation { (cont: CheckedContinuation<Heard, Never>) in
            let box = FirstResult(cont)
            Task { let value = await work.value; box.finish(value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                guard box.finish(nil) else { return }
                Log.write("accurate transcription: gave up after \(Int(deadline)) s")
                work.cancel()
            }
        }
        return heard
    }

    /// One of two racers wins; the other's answer is dropped.
    /// The transcript and how sure the engine was, raced against a deadline.
    struct Heard: Sendable {
        var text: String = ""
        var confidence: Float?
        /// The deadline won: the model never answered at all.
        ///
        /// Not the same fact as an empty `text`, and the difference is the
        /// whole turn. "The model read the audio and heard nothing" is an
        /// answer and it stands (see `.transcribe`). "The model never
        /// answered" is no answer, and overruling the live recogniser with
        /// it throws away words that were heard, shown on the island, and
        /// are still in hand.
        var timedOut = false
    }

    private final class FirstResult: @unchecked Sendable {
        private var cont: CheckedContinuation<Heard, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Heard, Never>) { cont = c }
        /// True when this call is the one that decided it.
        @discardableResult
        func finish(_ value: Heard?) -> Bool {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            guard let c else { return false }
            c.resume(returning: value ?? Heard(timedOut: true))
            return true
        }
    }

    /// A head hit the second stage (if any) let through: the owner check,
    /// then the wake.
    private func wakeHeard(_ score: Float) {
        // The head hears "Hey Moe" in things that are not it — "how are
        // you" woke it at 0.83, and a real wake scores 0.76-0.92, so no
        // threshold separates them. Whose voice it was does: Moe's own
        // comes back around 0.17, and a colleague across the room is
        // not the person who enrolled. One embedding, about 15 ms
        // against a 250 ms target, and it only ever refuses where there
        // is an enrolment to be sure with.
        if ownerVoiceReady, trustOwnerVoiceForWake {
            // The pre-roll, not the capture: standby captures nothing,
            // so `peekCapture` here read whatever the last conversation
            // left behind — the same stale seconds at every wake, and
            // therefore the same verdict at every wake.
            let window = pipe { await $0.peekRecent(lastSeconds: 2.0) }
            let owner = ownerVoice
            Task { [weak self] in
                let audio = await window.value
                guard let self else { return }
                let voice = audio.count > Int(AudioPipeline.rate) ? await owner.score(audio) : nil
                if let voice, WakeOwnerCheck.refuses(head: score, voice: voice) {
                    self.wakesRefusedInARow += 1
                    Log.write(String(format: "WAKE ignored (%.2f): that voice scored %.2f against yours",
                                     score, voice))
                    // A centroid built from the wrong audio refuses the
                    // owner exactly as confidently as it refuses a
                    // stranger, and from inside there is no way to tell
                    // those apart. What can be told apart is *how
                    // often*: a stranger triggers the name a few times
                    // an evening, and a wrong centroid refuses every
                    // single attempt — which is what happened on
                    // 2026-09-03, six in a row, and the wake word was
                    // simply gone with a plausible line in the log.
                    //
                    // So the check gets to be wrong a few times and
                    // then stops being trusted. `OwnerVoice` says of
                    // itself that it is "a soft signal by default,
                    // never a gate on its own"; this is the wake path
                    // finally honouring that.
                    if self.wakesRefusedInARow >= Self.wakeRefusalsBeforeDoubt {
                        Log.write("WAKE: \(self.wakesRefusedInARow) refusals in a row — trusting the head over the enrolment from here")
                        self.trustOwnerVoiceForWake = false
                        self.wakeOwnerTrust.distrust(refusals: self.wakesRefusedInARow)
                        self.onError?("Moe was ignoring “Hey Moe” because it did not recognise your voice. It has stopped doing that — if it now wakes for other people, re-teach it your voice in Settings › Voice.")
                        self.acceptWake(score)
                    }
                    return
                }
                self.wakesRefusedInARow = 0
                self.acceptWake(score, voice: voice)
            }
            return
        }
        acceptWake(score)
    }

    /// A wake the head heard and the voice check did not refuse.
    private func acceptWake(_ score: Float, voice: Float? = nil) {
        // The head runs in standby and while Moe speaks; the phrase
        // ends after the VAD's edge, so with barge-in on the machine
        // may already be capturing the interruption when the name
        // lands. A gate still pending is moot: this is the name.
        let wasOpen = machine.inConversation
        // The owner score of every accepted wake, so the gate's threshold
        // can be set from the distribution rather than guessed (it never
        // was logged, and 0.3 refused the owner half the time).
        let owner = voice.map { String(format: ", owner %.2f", $0) } ?? ""
        // The name over a reply stops it, interruptions on or off (owner,
        // 2026-10-06) — but only a sure one: the false wakes were weak.
        if case .speaking(let s) = machine.state, s != .aside, !machine.tuning.bargeIn,
           score < WakeOwnerCheck.stopsReplyAtHead {
            Log.write("WAKE heard (\(String(format: "%.2f", score))\(owner)) over the reply — too unsure to stop it")
            return
        }
        Log.write("WAKE heard (\(String(format: "%.2f", score))\(owner)) in \(machine.state)")
        wokeAt = Date()
        turnWakeScore = Double(score)
        speechSinceWake = false
        forgetWords()    // the last turn's partial must not count as this request's words
        feed(.woke)
        // "Hey Moe" is not the turn. The head fires a moment after the
        // phrase ends, so the VAD's end-of-speech for the *name* lands
        // right about now — and left alone it ends the turn before the
        // person has asked anything. Shipped untested, that looked like
        // Moe answering "Hey man" to itself.
        //
        // For the length of the grace window the name's own ending is
        // ignored. If speech is still going when it expires, the
        // request came in the same breath ("Hey Moe, what's the
        // weather") and the machine is told speech is in progress so
        // its no-speech timer stands down. If it is not, that timer
        // waits for the request, as it was armed to.
        wakeGraceUntil = Date().addingTimeInterval(Self.wakeGraceSeconds)
        wakeGrace?.cancel()
        wakeGrace = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.wakeGraceSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.wakeGrace = nil
            self.wakeGraceUntil = nil
            guard case .capturing(.wake) = self.machine.state, self.vadInSpeech else { return }
            self.speechSinceWake = true
            self.feed(.speechStarted)
        }
        if !wasOpen, machine.inConversation { onSessionOpened?() }
    }

    // MARK: - Trace

    private func beginTrace() {
        endTrace()
        let source: String
        switch machine.state {
        case .deciding(let s, _): source = "\(s)"
        case .capturing(let s): source = "\(s)"
        default: source = "?"
        }
        // Back-date the trace to when the mic opened, and back-fill the two
        // moments that happened before there was a trace to write them on.
        // Everything the reply stamps later runs on the same clock, so
        // `feltLatencyMs` is the gap it says it is.
        let opened = turnOpenedAt ?? Date()
        var t = TurnTrace(source: source, startedAt: opened)
        func offset(_ d: Date?) -> Int? {
            guard let d, d >= opened else { return nil }
            return Int(d.timeIntervalSince(opened) * 1000)
        }
        t.speechStartMs = offset(turnSpeechStartedAt)
        t.speechEndMs = offset(turnSpeechEndedAt)
        t.wakeScore = turnWakeScore
        t.confidence = turnConfidence
        t.endpoint = decidedBy.isEmpty ? nil : decidedBy
        fillVad(&t, turnVad)
        t.turnModelP = turnModelPs.isEmpty ? nil : turnModelPs.map { ($0 * 1000).rounded() / 1000 }
        t.stallAsks = stallAsks > 0 ? stallAsks : nil
        t.holdsMs = turnPauses.durationsMs
        turnPauses = TurnPauses()
        if let (reading, source) = lastSemantic {
            t.semantic = reading.rawValue; t.semanticSource = source.rawValue
        }
        lastSemantic = nil
        if let gate = pendingOwnerGate { t.ownerGateScore = gate.score; t.ownerGate = gate.outcome }
        pendingOwnerGate = nil
        turnModelPs = []
        stallAsks = 0
        trace = t
        turnOpenedAt = nil
        turnSpeechStartedAt = nil
        turnSpeechEndedAt = nil
        turnWakeScore = nil
        turnConfidence = nil
    }

    /// Stamp a moment on the current turn's trace.
    private func mark(_ key: WritableKeyPath<TurnTrace, Int?>) {
        guard let now = trace?.ms() else { return }
        trace?[keyPath: key] = now
    }

    private func endTrace() {
        guard let t = trace else { return }
        trace = nil
        writeTraceLine(t)
        if let felt = t.feltLatencyMs {
            Log.write("turn: felt latency \(felt) ms (stop → first word heard)")
        }
    }

    private func fillVad(_ t: inout TurnTrace, _ stats: VoiceDebug.VadStats) {
        if let mean = stats.mean {
            t.vadMeanP = (mean * 1000).rounded() / 1000
            t.vadMaxP = (stats.max * 1000).rounded() / 1000
            t.vadChunks = stats.count
        }
        if let floor = floorDb { t.noiseFloorDb = (Double(floor) * 10).rounded() / 10 }
    }

    /// The row, the log line and (when asked for) the clip for one onset
    /// decision. `BargeInDecision` says which check decided it.
    private func writeOnsetRow(outcome: String, _ decision: BargeInDecision, continuedAfterMs: Int? = nil) {
        var row = TurnTrace(source: "onset", startedAt: onsetAt ?? Date())
        row.outcome = outcome
        row.continuedAfterMs = continuedAfterMs
        row.onsetWindow = onsetWindowName.isEmpty ? Self.name(machine.state) : onsetWindowName
        row.onsetWords = wordsReported
        decision.stamp(&row)
        fillVad(&row, onsetVad)
        writeTraceLine(row)
        Log.write("turn: \(decision.logLine) — \(outcome)")
        if config.voiceDebugAudio {
            // Queued before the `.capture(false)` this batch may carry.
            let before = pipe { await $0.peekCapture(lastSeconds: 4) }
            saveDecisionClip(before: before, kind: "barge-in", reason: outcome, bargeIn: decision)
        }
        onsetAt = nil
        lastBargeIn = nil
    }

    /// Speech level at the end of an onset's audio against the voice that
    /// opened this session; nil when there is nothing to measure. The last
    /// 0.3 s, not the whole buffer: the capture opens with a pre-roll that
    /// holds Moe's own voice, and averaging that in would measure the wrong
    /// thing. It is a distance measurement more than an identity one — the
    /// people talking *near* the owner are quieter because they are further
    /// away.
    private func bargeInLevel(_ audio: [Float]) -> Double? {
        let tail = Array(audio.suffix(Int(AudioPipeline.rate * 0.3)))
        guard tail.count > Int(AudioPipeline.rate * 0.1),
              let reference = referenceRms, reference > 1e-6 else { return nil }
        return Double(Self.rms(tail) / reference)
    }

    /// A clip around a decision, when `voiceDebugAudio` is on: what led to
    /// it (`before`, already queued on the pipeline) and the
    /// `VoiceDebug.afterDecisionSeconds` that followed, read off the
    /// pre-roll ring once they have been heard — whether the person went on
    /// is the label. With a sidecar saying what was decided and on what.
    private func saveDecisionClip(before: Task<[Float], Never>, kind: String, reason: String,
                                  turnModelP: [Double]? = nil, words: Int? = nil,
                                  bargeIn: BargeInDecision? = nil,
                                  holds: [TurnPauses.Span] = [], decisionT: Double? = nil,
                                  lastWordT: Double? = nil, label: String? = nil,
                                  beforeSeconds: Double = VoiceDebug.beforeDecisionSeconds) {
        guard config.voiceDebugAudio else { return }
        Task { [weak self] in
            let lead = await before.value
            try? await Task.sleep(nanoseconds: UInt64(VoiceDebug.afterDecisionSeconds * 1_000_000_000))
            guard let self else { return }
            let after = await self.pipe { await $0.peekRecent(lastSeconds: VoiceDebug.afterDecisionSeconds) }.value
            let clip = VoiceDebug.decisionClip(before: lead, after: after, sampleRate: Int(AudioPipeline.rate),
                                               beforeSeconds: beforeSeconds)
            let clipSeconds = Double(clip.samples.count) / AudioPipeline.rate
            // Whether the person went on is known now, 2.5 s later.
            var labelled: (holds: [TurnPauses.Span], label: String?) = ([], label)
            if let decisionT {
                let resumed = self.continuedAt.map { $0.timeIntervalSinceReferenceDate }
                labelled = VoiceDebug.labelledHolds(holds, decisionT: decisionT, lastWordT: lastWordT,
                                                    resumedT: resumed, decidedAt: clip.decidedAt,
                                                    clipSeconds: clipSeconds, label: label)
            }
            let sidecar = VoiceDebug.Sidecar(kind: kind, reason: reason, decidedAtSeconds: clip.decidedAt,
                                             clipSeconds: clipSeconds,
                                             turnModelP: turnModelP, words: words, bargeIn: bargeIn,
                                             holds: labelled.holds.isEmpty ? nil : labelled.holds,
                                             label: labelled.label)
            self.saveDebugClip(clip.samples, reason: "\(kind)-\(reason)", sidecar: sidecar)
        }
    }

    /// One clip of a flagged moment, under `voice/debug/` in Moe's home,
    /// only when `voiceDebugAudio` is on. Capped (`VoiceDebug.capBytes`),
    /// oldest out first, a clip and its sidecar together. Never uploaded,
    /// never read by anything but a person.
    private func saveDebugClip(_ samples: [Float], reason: String, sidecar: VoiceDebug.Sidecar? = nil) {
        guard config.voiceDebugAudio, samples.count > Int(AudioPipeline.rate * 0.2) else { return }
        let dir = Config.homeDir.appendingPathComponent("voice/debug", isDirectory: true)
        let name = VoiceDebug.fileName(at: Date(), reason: reason)
        Task.detached(priority: .utility) {
            let data = VoiceDebug.wav(samples, sampleRate: Int(AudioPipeline.rate))
            let side = sidecar?.json()
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { ["wav", "json"].contains($0.pathExtension) }
                .map { VoiceDebug.Stored(name: $0.lastPathComponent,
                                         bytes: (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            for old in VoiceDebug.prune(existing, incoming: data.count + (side?.count ?? 0)) {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
            }
            try? data.write(to: dir.appendingPathComponent(name))
            if let side {
                let json = (name as NSString).deletingPathExtension + ".json"
                try? side.write(to: dir.appendingPathComponent(json))
            }
        }
    }

    /// The route this turn is asked on, for the trace (`TurnTrace.brain`).
    private func noteBrain() {
        trace?.brain = config.brainProvider.rawValue
        trace?.model = config.brainModel.isEmpty ? nil : config.brainModel
    }

    private func writeTraceLine(_ t: TurnTrace) {
        guard let line = t.jsonLine() else { return }
        if traceFile == nil {
            let dir = Config.homeDir.appendingPathComponent("logs/voice", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("turns.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            traceFile = try? FileHandle(forWritingTo: url)
            traceFile?.seekToEndOfFile()
        }
        // `write(_:)` raises an Objective-C exception on a full disk;
        // `write(contentsOf:)` throws, and a lost trace line is not a crash.
        try? traceFile?.write(contentsOf: (line + "\n").data(using: .utf8) ?? Data())
        // One line per turn used to grow for ever. Past 4 MB the file becomes
        // `turns.jsonl.1` (one generation kept), so the pair stays under 8 MB
        // and `recentTraceLines`' 2 MB window always has both halves to read.
        if let end = try? traceFile?.offset(), end > Self.traceLimit {
            try? traceFile?.close()
            traceFile = nil
            let url = Config.homeDir.appendingPathComponent("logs/voice/turns.jsonl")
            Log.rotate(url)
        }
    }

    static let traceLimit: UInt64 = 4_000_000

    // MARK: - Helpers

    /// The models did not load, said to the person who just held the key.
    ///
    /// It used to end "See ~/.moe/logs/moe.log." — a file path, to someone
    /// who wanted to talk. Whatever went wrong is already in that log; the
    /// person needs to know that typing still works and that trying again
    /// is worth it.
    static let modelsUnavailableMessage =
        "Moe can't listen just now — the voice is still being set up. You can type below."

    static let micDeniedMessage = "Moe can't hear you: microphone access is off. "
        + "Turn it on in System Settings › Privacy & Security › Microphone."

    /// "820 ms" / "2.4 s".
    nonisolated static func ms(since start: Date) -> String {
        let s = Date().timeIntervalSince(start)
        return s < 1 ? "\(Int(s * 1000)) ms" : String(format: "%.1f s", s)
    }

    /// Milliseconds as a number, for arithmetic rather than a log line.
    nonisolated static func msSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    nonisolated static func seconds(_ samples: Int, at rate: Double) -> String {
        String(format: "%.1f s", Double(samples) / max(rate, 1))
    }

    private static func name(_ s: State) -> String {
        switch s {
        case .off: return "off"
        case .standby: return "standby"
        case .attending(let x): return "attending(\(x))"
        case .capturing(let x): return "capturing(\(x))"
        case .deciding(let x, let t): return "deciding(\(x) #\(t))"
        case .thinking(let x): return "thinking(\(x))"
        case .speaking(let x): return "speaking(\(x))"
        case .followUp: return "followUp"
        case .suspended: return "suspended"
        }
    }
}
