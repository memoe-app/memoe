import Foundation
import MoeBrain
import MoeLedger

/// Which AI sits behind Moe. See PRODUCT.md §3 — the app never depends on one
/// vendor's subscription policy, so the brain is swappable.
///
/// Today there is exactly one: a Hermes Agent gateway. Providers are chosen
/// inside Hermes (`~/.hermes/config.yaml`), not here — the `claudeCode` and
/// `geminiCli` adapters this enum used to name were removed when Hermes
/// became the core, and config.json values naming them decode as `.hermes`.
enum BrainKind: String, Codable, CaseIterable {
    /// A locally running Hermes Agent gateway, over HTTP. See HERMES-PLAN.md.
    case hermes

    /// What to call it in a status line or an error.
    var displayName: String {
        switch self {
        case .hermes: return "Hermes"
        }
    }

    /// The command the user would run in a terminal to check it works.
    var cliName: String {
        switch self {
        case .hermes: return "hermes"
        }
    }
}

/// Why a turn ended. Only `.answered` is the model finishing its own reply;
/// everything else is the harness or the wire ending it, and nothing may
/// treat that as the model having stopped of its own accord — above all the
/// stall guard, which would otherwise tell the brain to "carry on" with a
/// turn that was stopped because it had already sent or paid.
enum TurnEnd: Equatable {
    /// The model's own end of turn (`finish_reason: stop`, or `[DONE]`).
    case answered
    /// Cut at the length limit: what arrived is real, but not the end.
    case truncated
    /// The stream ended with no finish from the model.
    case streamEnded
    /// The turn failed; `.error` came first.
    case failed
    /// A sleep broke a turn that had already sent or paid: stopped, never
    /// re-issued unasked (`TurnKeeper` `.stop`).
    case stoppedAfterSleep
    /// The cloud took the ask while the Mac slept; its answer lands there.
    case handedToCloud
}

/// Events a brain surfaces to the Conductor. Always delivered on the main queue.
enum BrainEvent {
    /// The session is up. `tools` and `mcpServers` may be empty for a brain
    /// that doesn't report them — the UI only counts them.
    case ready(sessionID: String, tools: [String], mcpServers: [String])
    /// A piece of the reply. Not emitted for silent turns.
    case textDelta(String)
    /// A piece of the model's thinking, for providers that stream it
    /// (`delta.reasoning_content`). Shown folded inside the steps, never
    /// spoken. Not emitted for silent turns.
    case reasoningDelta(String)
    /// The reply is complete; carries the full text so the transcript can be
    /// corrected if deltas were missed, and why it ended. Not emitted for
    /// silent turns.
    case turnFinished(String, TurnEnd)
    /// The model went to use a tool. `detail` is Hermes's own preview of the
    /// call — the command, the query, the filename — and `emoji` its icon for
    /// that tool; both come straight off `hermes.tool.progress` rather than
    /// being invented here. `id` is the gateway's `toolCallId`, which is what
    /// pairs this with `toolFinished` when several steps run at once.
    /// `spoken` is the same step said out loud (`SpokenStep`), or nil when
    /// there is nothing honest to say about it.
    case toolStarted(name: String, id: String, emoji: String?, detail: String, spoken: String?)
    /// That step came back. Without it the island reports whatever ran last
    /// as the thing happening now, for the rest of the turn.
    ///
    /// `fix`: it came back failed, for a reason the person can fix, and the
    /// tool said which (docs/FIXABLE-FAILURES.md; `ToolFix`). Nil for every
    /// other outcome, including a failure with no known code.
    case toolFinished(id: String, fix: ToolFix? = nil)
    /// A line for the status area, nothing more.
    case status(String)
    /// Something the person needs to read, which is not part of the reply and
    /// must not vanish when the next status line lands. Today that is one
    /// thing: the usage limit is nearly spent, and Moe is about to stop
    /// answering. `statusLine` cannot carry it — it is overwritten by the
    /// next step of the same turn and cleared at the end — so this goes into
    /// the transcript, where it stays.
    case notice(String)
    /// The turn failed. The Conductor stops waiting for a reply.
    case error(String)
    /// The brain could not be brought up at all — binary missing, and so on.
    case failedToLaunch(String)
    /// A long-lived brain process died underneath us. The Conductor restarts
    /// it with backoff. Brains that spawn a process per turn never emit this.
    case exited(code: Int32)
}

/// An image that rides along with a user turn — the screenshot taken when
/// the talk key went down (ScreenContext). Sent as an OpenAI-style
/// `image_url` data URL; Hermes hands it to the model as an image.
struct ImageAttachment {
    let data: Data
    /// "image/jpeg" or "image/png".
    let mediaType: String

    var dataURL: String { "data:\(mediaType);base64," + data.base64EncodedString() }
}

/// What the Conductor needs from whatever is thinking on Moe's behalf.
///
/// Derived from ClaudeBridge's actual call sites rather than from what an AI
/// adapter could conceivably offer: every member here is used by Conductor or
/// by `Moe --ask`, and nothing else is.
///
/// Threading contract, inherited from ClaudeBridge: every method may be called
/// from the main thread and returns at once; implementations do their work on
/// their own serial queue and deliver `onEvent` on the main queue.
protocol BrainProvider: AnyObject {
    var onEvent: ((BrainEvent) -> Void)? { get set }

    /// Bring the brain up. Idempotent while running.
    func start()

    /// A new provider/model selection for every turn from now on, without a
    /// restart. Brains that don't name a model per turn ignore it. Follow it
    /// with `reset()` so the next session starts on the new model.
    func apply(brain: BrainSelection)

    /// Whether what is said in the open chat may be remembered. `false` for a
    /// chat the person marked "Don't remember this chat": every turn queued
    /// from then on asks the brain to learn nothing and write no memory. Brains
    /// with no memory of their own ignore it.
    func remember(_ remembers: Bool)

    /// A throwaway silent turn at launch, so the first real question doesn't
    /// pay the cold-start cost and auth problems surface while the panel is
    /// still hidden.
    func warmUp()

    /// One user turn. `silent` turns carry background notes (a restored
    /// transcript, a nudge that was read aloud) — the model sees them, but no
    /// deltas or `turnFinished` come back and nothing is logged as a reply.
    /// `images` are the pictures for this turn: the screenshot, if there is
    /// one, and any photos the person attached.
    ///
    /// `logAs` is what goes in the transcript log in place of `text`, for the
    /// turns where those are not the same thing. A spoken turn now leaves here
    /// carrying the brief and the delivery rules as well as the person's
    /// words, and logging all of it wrote eleven kilobytes of unchanging
    /// scaffolding into `moe.log` for every question anybody asked — which is
    /// not a tidiness complaint: the log is the instrument these changes are
    /// measured with, and a grep for what somebody said came back with six
    /// copies of the delivery rules and none of the sentence.
    ///
    /// `starter` is who started the turn — see `TurnStarter`. It has no
    /// default on purpose: every caller says, so a new one cannot slip in
    /// as the person by omission.
    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter)

    /// The same turn, also saying whether the person SPOKE it and is waiting
    /// to hear the answer. A brain that can open such a turn faster does
    /// (`HermesBrain`); every other brain ignores the word and sends the turn
    /// as it always did, which is the default below.
    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter, spoken: Bool)

    /// Abandon whatever is in flight and begin a clean conversation with a
    /// freshly built system prompt. Also the only way to interrupt a turn.
    ///
    /// `warmingUp` is false when the caller is about to send a real turn.
    /// A session takes one turn at a time, so a silent warm-up queued here
    /// would sit in front of the user's question — and rather than sparing
    /// it the cold start, make it wait through one and then pay for its own.
    func reset(warmingUp: Bool)

    /// Drop the turn in flight and keep the session. For an interruption:
    /// the person talked over the answer, and what they want next is an
    /// answer to their next words, in the same conversation, from a brain
    /// that is already warm. A brain that cannot cancel a turn without
    /// losing the session falls back to `reset(warmingUp: false)`.
    ///
    /// Measured before this existed (7 days to 2026-09-06): every
    /// interruption rotated the session, Hermes spawned a fresh child
    /// (1.6–5.2 s to boot) and ran a warm-up turn (p50 1.7 s) *inside the
    /// person's next turn* — 85 times, and first token after one came at
    /// 12–27 s. Closing the request frees the turn in about 65 ms and the
    /// same child answers what comes next.
    func abandonTurn()

    /// The same, calling `done` once the turn has been let go on this side
    /// (the request cancelled) — for the stop's receipt.
    func abandonTurn(then done: @escaping @Sendable () -> Void)

    /// Carry on a thread rather than start a new one: take the session the
    /// resume names, and, if it carries priming, learn the conversation
    /// before the person's next turn arrives. See `BrainResume`.
    func resume(_ resume: BrainResume)

    /// What distinguishes this brain from another for session continuity —
    /// provider and model. A session belongs to one of these; a thread
    /// outlives all of them.
    var brainFingerprint: String { get }

    /// The session a turn sent right now would land in. `reset()` rotates it,
    /// so this is the only honest answer to "has the brain been told this?" —
    /// see `ConversationLedger.save`.
    var currentSessionID: String { get }

    /// The Mac is about to sleep. A brain with a turn in flight notes it, so
    /// a stream found broken on wake is re-issued rather than reported
    /// (`TurnKeeper`). Nothing is cancelled here.
    func noteSystemSleep()

    /// The Mac is awake again. A brain with a turn that slept asks the edge
    /// whether the ask is still its own before letting the turn run on.
    func noteSystemWake()

    /// Final shutdown. Synchronous — the app is exiting.
    func stop()
}

extension BrainProvider {
    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter, spoken: Bool) {
        send(text, images: images, silent: silent, logAs: logAs, starter: starter)
    }
    func send(_ text: String, starter: TurnStarter) {
        send(text, images: [], silent: false, logAs: nil, starter: starter)
    }
    func send(_ text: String, silent: Bool, starter: TurnStarter) {
        send(text, images: [], silent: silent, logAs: nil, starter: starter)
    }
}

/// Who started a turn: sent to Hermes as `X-Hermes-Turn-Origin`.
///
/// Hermes lets its Chrome-extension browser lane act in the person's own
/// Chrome only on a `.person` turn. So `.person` means someone typed or said
/// this just now and is at the Mac. Everything Moe sends on its own is
/// `.background`: a restored transcript, a nudge note, meeting notes (other
/// people's words), a handed-off job's result (a subagent's words, possibly
/// web content), a stall-guard continuation, and every re-send after a
/// relaunch or a sleep — those can go out half an hour after a crash with
/// nobody there. It is declared at each call site, never guessed from the
/// text: a text check missed the stall guard's "not from the person:".
enum TurnStarter: String, Sendable, Equatable {
    case person, background
}

extension BrainProvider {
    func apply(brain: BrainSelection) {}
    func remember(_ remembers: Bool) {}
    func noteSystemSleep() {}
    func noteSystemWake() {}
    func reset() { reset(warmingUp: true) }
    func abandonTurn() { reset(warmingUp: false) }
    func abandonTurn(then done: @escaping @Sendable () -> Void) {
        abandonTurn()
        done()
    }

    /// A brain that cannot reattach to a past session still gets a clean one,
    /// which is what every brain did before this existed.
    func resume(_ resume: BrainResume) { reset() }
    var brainFingerprint: String { "" }
    var currentSessionID: String { "" }
}
