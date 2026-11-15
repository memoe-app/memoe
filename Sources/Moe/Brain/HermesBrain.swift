import Foundation
import MoeBrain
import MoeLedger

/// A locally running Hermes Agent gateway, spoken to over HTTP.
///
/// Hermes's `api_server` platform serves an OpenAI-style
/// `POST /v1/chat/completions` on 127.0.0.1. Nothing is spawned here — the
/// gateway is either already up (`hermes gateway run`) or brought up by a
/// `HermesSupervisor` handed in at init, which `start()` waits on before
/// probing. What this class owns is the SSE stream and the mapping of
/// Hermes's frames onto `BrainEvent`.
///
/// The on-the-wire shapes below are from `gateway/platforms/api_server.py`
/// (Hermes v0.20.6), not from a generic OpenAI client:
///
///     data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}],…}
///     data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}],…}
///     event: hermes.tool.progress
///     data: {"tool":"web_search","emoji":"🔍","label":"…","toolCallId":"…","status":"running"}
///     : keepalive                                   (every 30s of silence)
///     data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{…}}
///     data: [DONE]
///
/// A failed turn ends with `finish_reason: "error"` (or `"length"`) and an
/// `error.message` on that same chunk. HTTP-level failures are a JSON body
/// `{"error":{"message":…,"type":…,"code":…}}` with a 4xx/5xx status.
///
/// Session continuity is the `X-Hermes-Session-Id` header: one UUID per
/// conversation, rotated on reset, and Hermes reloads the transcript from its
/// own state.db — so each request carries only the system prompt and the new
/// user turn. Hermes only honours that header (and `X-Hermes-Session-Key`)
/// when the request is authenticated, which is why a key matters.
///
/// The system prompt goes with every turn, not just the first: Hermes applies
/// a request's system message as an *ephemeral* prompt layered over its own
/// core prompt and never stores it with the session, so a turn sent without
/// one would lose Moe's voice rules. That ephemerality is also why the live
/// brief belongs there and nowhere else — a brief prefixed to the user turn
/// would be persisted with the transcript, and N turns would carry N stale
/// briefs. Instead the prompt is rebuilt whenever `_brief.md` changes on
/// disk (a stat per turn), so it is always fresh and never stored.
///
/// **Threading contract:** every stored property is confined to `queue`. All
/// public methods hop onto it; URLSession delivers its callbacks onto it too
/// (its delegate queue is backed by `queue`). Events go out on the main queue.
final class HermesBrain: NSObject, BrainProvider, URLSessionDataDelegate {

    /// The thinking in one streamed choice, when the provider sends it:
    /// Hermes passes it on as `delta.reasoning_content` (the DeepSeek-style
    /// field). Most providers and plans send none, and then nothing shows.
    static func reasoning(in choice: [String: Any]) -> String? {
        guard let delta = choice["delta"] as? [String: Any],
              let t = delta["reasoning_content"] as? String, !t.isEmpty else { return nil }
        return t
    }

    private let queue = DispatchQueue(label: "moe.hermes")

    // MARK: State — queue-confined

    /// One turn waiting for, or holding, the connection.
    private struct Turn {
        let text: String
        let silent: Bool
        var images: [ImageAttachment] = []
        /// What the log calls it (`BrainProvider.send(logAs:)`), kept so a
        /// re-issued turn is logged as the same ask.
        var logAs: String? = nil
        /// Who started it, sent as `X-Hermes-Turn-Origin`. Declared by the
        /// caller; Moe's own turns here (warm-up, priming, a re-issue after
        /// sleep) are `.background`.
        var starter: TurnStarter = .background
        /// How many times this turn has been re-issued after a sleep broke
        /// its stream (`TurnKeeper`). 0 for a turn sent once.
        var resumed = 0
        /// The ask's id on the edge (`moe.task_runs`), the same across
        /// re-issues. Empty for a silent turn, which is nobody's ask.
        var task = ""
        /// The person said it aloud and is waiting to hear the answer
        /// (`X-Hermes-Voice-Turn`). Never set on a re-issue: that goes out
        /// after a wake, to nobody in particular.
        var spoken = false
        /// The chat this turn belongs to may not be remembered ("Don't
        /// remember this chat"): `X-Hermes-No-Memory`. Taken when the turn is
        /// queued, so a re-issue keeps it after the person has moved on.
        var forget = false
        /// Run when Hermes has actually answered this turn, so a caller can
        /// tell "the model has this" from "we queued it". Priming needs the
        /// difference: abandonLocked(), stop() and a failed start all empty
        /// `pending`, and a turn dropped there is never delivered.
        var onDelivered: (() -> Void)? = nil
    }

    /// The request in flight, and what it has produced so far.
    private final class InFlight {
        let task: URLSessionDataTask
        let turn: Turn
        var status = 0
        var buffer = Data()       // unparsed SSE bytes, or an error body
        var eventName = ""        // current SSE event name, "" for plain chunks
        var dataLines: [String] = []
        var text = ""
        var finished = false      // finish_reason seen; ignore the rest
        var cancelled = false     // reset()/stop() — say nothing about it
        var portable = true       // no Mac-only tool used yet (`TaskPortability`)
        var consequential = false // a tool that sends/pays/deletes has run
        var handedToCloud = false // the edge said another device holds the ask
        init(task: URLSessionDataTask, turn: Turn) { self.task = task; self.turn = turn }
    }

    private var urlSession: URLSession!
    private var running = false
    /// The last start ended with the gateway refusing to come up, and nothing
    /// has started this brain since. It is what tells "stopped because the
    /// launch failed" — which a recovery or the next question should undo —
    /// from "never started" and "stopped on purpose", which they must not.
    private var launchFailed = false
    /// The supervisor reported the gateway down *after* this brain was up,
    /// and that was passed on as `.failedToLaunch`: the window shows
    /// "Connecting…" over a brain that is still running. Cleared by the
    /// `.ready` that follows the gateway's return.
    private var toldGatewayIsDown = false
    /// A turn or a probe got nothing from a gateway Moe runs itself, and the
    /// supervisor has been asked to look (`noteUnreachable`). If it finds the
    /// gateway hung and replaces it, the `onRecovered` that follows is for
    /// this brain; a turn that works in the meantime settles the doubt.
    private var gatewayInDoubt = false
    private var shuttingDown = false
    /// False from `start()` until the supervisor says the gateway answers:
    /// turns queue up behind it instead of hitting a port nobody is on yet.
    /// Always true without a supervisor.
    private var gatewayReady = true
    /// Bumped by every `startLocked()`; a readiness callback from an earlier
    /// start (a `reset()` raced it) must not open the gate for this one.
    private var startGeneration = 0
    private var sessionID = UUID().uuidString.lowercased()
    private var systemPrompt = ""
    /// What the last request into `sessionID` told Hermes its child should
    /// have been started with (`LaunchSignature`). A request that differs
    /// makes Hermes replace the child under that turn; it is logged here,
    /// with what moved, because from Hermes's side the cause is only "the
    /// prompt changed" and from the person's it is six seconds of nothing.
    private var lastSignature: (session: String, signature: LaunchSignature)?
    /// `context/_connections.md` — what the prompt above was told is
    /// connected — and whether it still says that. See
    /// `refreshPromptIfConnectionsChangedLocked()`.
    private var connectionsSource = PromptSource(url: Paths.connections)
    private var connectionsWatch: DispatchSourceTimer?
    private var pending: [Turn] = []
    private var current: InFlight?
    /// The Mac slept while `current` was in flight. Read when the stream
    /// breaks: a sleep-shaped failure after a sleep is re-issued once
    /// (`TurnKeeper.verdict`); the same failure on a Mac that stayed awake
    /// is the gateway's problem and is reported as it always was.
    private var sleptDuringTurn = false
    /// A re-issue waiting on the edge's answer and the 2 s settle
    /// (`resumeAfterSleepLocked`). Queue-confined. `abandonLocked` clears it —
    /// an interruption or a conversation switch in that window is the person
    /// dropping the ask, and the re-issue must not land on the next session
    /// behind their next question — and the fire checks the session is still
    /// the one the break happened on.
    private var pendingResume: (inflight: InFlight, session: String)?
    private var probe: URLSessionDataTask?
    /// Bumped for every probe issued. A probe's completion handler only
    /// counts if it carries the current number — a cancelled probe from
    /// before a `reset()` would otherwise clear `probe` under its successor
    /// and report a spurious failure.
    private var probeGeneration = 0

    var onEvent: ((BrainEvent) -> Void)?

    /// The open ask, reported (docs/AWAY-HANDOFF.md slice 2). `onTask` gets
    /// every open and done, in order, on this brain's queue — the official
    /// build's cloud half queues and sends them (`CloudLink`). `taskArbiter` is
    /// asked, before a turn a sleep broke is re-issued, whether this Mac
    /// still holds the ask; unset, the answer is yes.
    var onTask: ((BrainTaskReport) -> Void)?
    var taskArbiter: ((String, @escaping (Bool) -> Void) -> Void)?
    /// The thread the session was resumed on; the task row names it.
    private var threadID = ""
    /// The open chat is one the person asked not to be remembered: every turn
    /// queued from now on carries `X-Hermes-No-Memory` (`remember(_:)`).
    private var forgetting = false
    /// Debug-only (`Moe --ask`, scripts/test-turn-keeper.sh): a thread for
    /// a brain that was started rather than resumed, so the ask is reported.
    var threadForTests: String {
        get { queue.sync { threadID } }
        set { queue.sync { threadID = newValue } }
    }

    /// One line for the window's Hermes row. Read from the main thread; the
    /// supervisor's `standing` is a short sync hop onto its queue.
    var gatewayStatus: String {
        guard let supervisor else { return "Running — Moe found it already going and is using it." }
        switch supervisor.standing {
        case .owned:            return "Running. Moe starts it and stops it with the app."
        case .adopted:          return "Running — it was already going when Moe started, so Moe is using it."
        case .failed(let why):  return "Not running. \(why)"
        }
    }

    private let config: Config
    /// Provider + model every turn asks for (config.json's brain settings).
    /// Replaced by `apply(brain:)` when the Brain pane changes the model.
    private var brain: BrainSelection
    /// Port, base URL and key — shared with the dictation polisher.
    /// `var`, re-read when the gateway comes up: configure-hermes writes the
    /// gateway key *while the supervisor starts*, which on a fresh install is
    /// after this brain was built. Keeping the key from construction meant
    /// the first question on a new Mac was a 401 — "Moe couldn't unlock its
    /// own thinking" (owner's Mac, 2026-09-10 19:04:46) — until something
    /// else happened to rebuild the brain.
    private var endpoint: HermesEndpoint
    private var port: Int { endpoint.port }
    private var apiKey: String { endpoint.apiKey }
    /// Runs the gateway as Moe's child. Nil means it's someone else's job
    /// (`hermes gateway run` in a terminal) and the probe goes out at once.
    private let supervisor: HermesSupervisor?

    /// Something the gateway reads only at boot has changed — see
    /// `HermesSupervisor.reload`. No-op without a supervisor: a gateway Moe
    /// did not start is not Moe's to restart.
    func reloadGateway(reason: String) { supervisor?.reload(reason: reason) }

    /// Calls `done(true)` once a gateway **of Moe's own** is answering — the
    /// one state in which `HermesUpgrade` may rewrite the tree at
    /// `~/.hermes/hermes-agent`: nothing is still importing it, and `reload`
    /// has something to restart afterwards. Every other terminal answer —
    /// failed, shutting down, or a gateway somebody else started — is
    /// `done(false)` (`HermesUpgradeGate`). Without a supervisor there is no
    /// gateway of Moe's at all, so `false`. Runs `done` on the supervisor's queue.
    func whenOwnGatewayUp(_ done: @escaping (Bool, String) -> Void) {
        guard let supervisor else { done(false, "this gateway was not started by Moe"); return }
        // `whenOwnedReady`, not `whenReady` + `standing`: the callback runs on
        // the supervisor's queue, and `standing` would `queue.sync` on that
        // same queue — a libdispatch trap, reached on the first launch that
        // ever decided to move Hermes. The supervisor answers `owned` from
        // its own state instead.
        supervisor.whenOwnedReady { owned, why in
            let quitting = why.hasPrefix("Moe is shutting down")
            done(HermesUpgradeGate.mayRun(ready: owned, owned: owned, shuttingDown: quitting), why)
        }
    }

    init(config: Config, supervisor: HermesSupervisor? = nil) {
        self.config = config
        self.supervisor = supervisor
        self.endpoint = HermesEndpoint(config: config)
        self.brain = BrainSelection(config: config)
        super.init()

        // A gateway that keeps dying after it was once up: the supervisor has
        // given up, so say so the same way a failed launch is said.
        supervisor?.onError = { [weak self] message in
            self?.queue.async { self?.toldGatewayIsDown = true }
            self?.emit(.failedToLaunch(message))
        }
        supervisor?.onStatus = { [weak self] line in
            self?.emit(.status(line))
        }
        // The supervisor keeps trying after it gives up, and says so in the
        // failure it reports ("Moe will keep trying quietly"). This is the
        // other half of that promise: when it works, the brain comes back
        // with it instead of staying stopped until a relaunch.
        supervisor?.onRecovered = { [weak self] in
            self?.queue.async { self?.gatewayRecoveredLocked() }
        }

        // Loopback only, no proxy (see HermesEndpoint). A turn that runs
        // tools can be quiet for a while; Hermes sends a keepalive comment
        // every 30s of silence, so the idle timeout only has to outlast
        // that. The resource timeout bounds a whole turn.
        let cfg = HermesEndpoint.sessionConfiguration()
        // Debug-only test hook (scripts/test-hermes-supervisor.sh §18): a
        // turn that goes quiet is given up on sooner than two minutes.
        cfg.timeoutIntervalForRequest = TestHooks.env("MOE_HERMES_TURN_IDLE_TIMEOUT").flatMap(Double.init) ?? 120
        cfg.timeoutIntervalForResource = 3600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { self.startLocked() }
    }

    /// The gateway answers again after the supervisor had reported a failure.
    ///
    /// Two brains can be listening. One whose launch failed is stopped
    /// (`running == false`) and is started again. One that was already up
    /// when the gateway later died is still running, but the Conductor was
    /// told `.failedToLaunch` and shows "Connecting…" — a probe emits the
    /// `.ready` that puts the window right.
    private func gatewayRecoveredLocked() {
        guard !shuttingDown else { return }
        if running {
            // Only when the window was told otherwise. A start this brain
            // made itself probes on its own, and a second `.ready` in the
            // middle of the turn that caused it would be noise.
            guard toldGatewayIsDown || gatewayInDoubt else { return }
            toldGatewayIsDown = false
            gatewayInDoubt = false
            Log.write("hermes: the gateway is back; checking in with it")
            probeLocked()
        } else if launchFailed {
            Log.write("hermes: the gateway came back on its own; starting again")
            startLocked()
        }
    }

    private func startLocked() {
        guard !running, !shuttingDown else { return }
        running = true
        launchFailed = false
        toldGatewayIsDown = false
        gatewayInDoubt = false
        rebuildPromptLocked()
        startConnectionsWatchLocked()
        if apiKey.isEmpty {
            Log.write("hermes: no key configured — Hermes won't keep the conversation "
                      + "between turns. Set hermesKey in ~/.moe/config.json to API_SERVER_KEY.")
        }
        emit(.status("waking up"))
        guard let supervisor else {
            probeLocked()
            return
        }
        // Moe's own gateway: hold the probe and any queued turns until it
        // answers on the port. `start()` is idempotent on the supervisor, so
        // a reset() here does not restart the gateway.
        gatewayReady = false
        startGeneration += 1
        let generation = startGeneration
        supervisor.start()
        supervisor.whenReady { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard generation == self.startGeneration, self.running, !self.shuttingDown else { return }
                switch result {
                case .success:
                    self.gatewayReady = true
                    let fresh = HermesEndpoint(config: Config.load())
                    if fresh.apiKey != self.endpoint.apiKey, !fresh.apiKey.isEmpty {
                        self.endpoint = fresh
                        Log.write("hermes: using the gateway key configure-hermes just wrote")
                    }
                    self.probeLocked()
                    self.pumpLocked()
                case .failure(let f):
                    // Nothing to talk to. Drop what was queued; the user gets
                    // one clear message rather than one per turn.
                    self.running = false
                    self.launchFailed = true
                    self.pending.removeAll()
                    self.emit(.failedToLaunch(f.message))
                }
            }
        }
    }

    // The idle brief refresh is gone, and so is the ceiling it worked
    // against. It existed to move one cost off the person: a new brief meant
    // a new system prompt, a new system prompt meant Hermes killed the Claude
    // Code child and spawned another, so this waited 45 s for a silence,
    // rebuilt the prompt and spent a whole silent turn to make the respawn
    // happen *there* instead of under the next question.
    //
    // It half-worked, which is the worst kind. Over 1,387 logged turns 151 —
    // 11% — still had the child respawn underneath them (p50 8.1 s to first
    // token, against 5.6 s warm), and the other 89% of the time it bought
    // that by spending an extra round trip every ten minutes, all day, for
    // nothing anyone asked for.
    //
    // With the brief on the turn (`BrainPrompt.briefBlock`) the system prompt
    // stops moving, so there is no respawn to move and nothing to pay for.

    private func rebuildPromptLocked() {
        // Re-read: the pane may have changed the model since this brain
        // was built without rebuilding it (a model-only Apply).
        let config = Config.load()
        // Take the connections file as read at the same moment the prompt is
        // built from it, so "has it changed since?" means since THIS prompt.
        _ = connectionsSource.take()
        systemPrompt = BrainPrompt.systemPrompt(
            supportsTools: config.brainCapabilities.mayUseTools,
            language: SpeechLanguages.entry(for: config.locale)?.englishName ?? "English")
    }

    /// **What is connected changed under a running conversation — rebuild.**
    ///
    /// The prompt above is assembled once, in `startLocked()`, and Hermes
    /// bakes it into its Claude Code child at spawn. Everything in it is
    /// frozen for the life of that child, which is the right trade for all of
    /// it except this one file.
    ///
    /// 2026-09-07, on the owner's Mac, from `~/.moe/logs/moe.log` and
    /// `~/.moe/conversations/`:
    ///
    ///     21:31:12  brain ready: 1 tool(s), 0 connection(s)
    ///     21:33:43  cloud: Composio project minted for this tenant
    ///     21:34–35  two Gmail accounts connected in the Connections pane
    ///     21:36:09  "Are you connected to my Gmail"
    ///     21:36:13  "No — no mailbox is added yet, so I can't see your
    ///                Gmail at all. Want me to walk you through connecting
    ///                it?"
    ///     21:47:36  context/_connections.md finally rewritten, by sync.sh
    ///
    /// Every word of that answer was the truth as the prompt had it at
    /// 21:31 — two minutes before the Composio project existed. The
    /// connection was never broken; nothing ever told the brain about it.
    /// `connect.sh` now rewrites the file the moment a connection changes,
    /// and this is the other half: noticing, without waiting for a New
    /// Conversation.
    ///
    /// Cheap on purpose. It is one read of a file under a kilobyte, and it
    /// compares BYTES — `sync.sh` rewrites that file every ten minutes with
    /// identical contents, and a check keyed on mtime would respawn the child
    /// six times an hour for nothing. `PromptSource` is where that rule lives
    /// and `PromptSourceTests` is what holds it there.
    @discardableResult
    private func refreshPromptIfConnectionsChangedLocked() -> Bool {
        guard connectionsSource.isStale() else { return false }
        let changed = connectionsSource.changedLines()
        rebuildPromptLocked()
        Log.write("hermes: what is connected changed — rebuilt the system prompt "
                  + "(Hermes will respawn its child on the next turn)"
                  + (changed.isEmpty ? "" : ": " + changed.joined(separator: " | ")))
        return true
    }

    /// Between turns, every minute: if what is connected changed, rebuild
    /// now and send the silent warm-up turn, so the child's respawn is paid
    /// here and not by the next thing the person says. Measured 09-24 → 10-06:
    /// a respawn turn cost 9.3 s p50 against 4.4 s warm, and every one of the
    /// 20 that hit a voice turn did so because the check only ran at submit.
    /// The check at submit stays as the backstop.
    private func startConnectionsWatchLocked() {
        connectionsWatch?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.shuttingDown, self.gatewayReady,
                  self.current == nil, self.pending.isEmpty else { return }
            if self.refreshPromptIfConnectionsChangedLocked() {
                Log.write("hermes: warming the new child now, between turns")
                self.warmUpLocked()
            }
        }
        timer.resume()
        connectionsWatch = timer
    }

    /// `GET /v1/models`: proves the gateway is up and the key is right, and
    /// gives the UI something to count.
    ///
    /// This is also where auth and connection problems are meant to surface
    /// at launch — as `.failedToLaunch` — because the silent warm-up turn
    /// that follows reports nothing, by design.
    private func probeLocked() {
        probe?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        var req = endpoint.request("v1/models")
        req.timeoutInterval = 8
        let task = urlSession.dataTask(with: req) { [weak self] data, response, error in
            // Completion handlers of a delegate-backed session run on the
            // delegate queue, which is `queue`.
            guard let self, generation == self.probeGeneration,
                  self.running, !self.shuttingDown else { return }
            self.probe = nil
            if let error {
                // Our own cancel — reset()/stop() — is not news.
                if (error as NSError).code == NSURLErrorCancelled { return }
                self.emit(.failedToLaunch(self.describe(error)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                self.emit(.failedToLaunch(self.describeHTTPFailure(status: status, body: data ?? Data())))
                return
            }
            var models: [String] = []
            if let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }
            }
            self.emit(.ready(sessionID: self.sessionID, tools: models, mcpServers: []))
        }
        probe = task
        task.resume()
    }

    func stop() {
        queue.sync {
            shuttingDown = true
            running = false
            connectionsWatch?.cancel()
            connectionsWatch = nil
            abandonLocked(keepRecord: true)
            // Kept for a relaunch to pick up — unless it is already too old
            // for that, in which case it is only the person's words on disk.
            if let record = TurnKeeper.read(), TurnKeeper.leftover(record) == nil {
                TurnKeeper.clear()
            }
            urlSession.invalidateAndCancel()
        }
        // Outside the queue: this blocks for up to five seconds while the
        // gateway is asked, then made, to leave.
        supervisor?.stop()
    }

    /// Drop the in-flight request and everything queued behind it, silently.
    /// `keepRecord`: a quit keeps the in-flight record so a relaunch can pick
    /// the turn up; an interruption or a conversation switch is the person
    /// dropping it, and the record goes with it.
    private func abandonLocked(keepRecord: Bool = false) {
        probe?.cancel()
        probe = nil
        if let c = current {
            c.cancelled = true
            c.task.cancel()
            current = nil
            if !c.turn.silent, !keepRecord {
                TurnKeeper.clear()
                // The person dropped it: the edge hears so, or the cloud
                // would cover an ask nobody wants any more.
                reportTaskLocked(.done, c, status: "abandoned")
            }
        }
        if let waiting = pendingResume {
            // A re-issue not yet sent is dropped with the rest, and reported:
            // it is the same ask the person just walked away from.
            pendingResume = nil
            if !keepRecord {
                TurnKeeper.clear()
                reportTaskLocked(.done, waiting.inflight, status: "abandoned")
            }
        }
        pending.removeAll()
    }

    /// The Mac is going to sleep. Nothing is cancelled — a short sleep may
    /// leave the stream intact — but if it comes back broken, the break is
    /// now known to be the sleep's.
    func noteSystemSleep() {
        queue.async { if self.current != nil { self.sleptDuringTurn = true } }
    }

    /// The Mac is awake again. A turn still in flight whose stream survived
    /// the sleep (loopback can) would otherwise run to the end without ever
    /// asking whether the cloud took the ask meanwhile — and answer twice.
    /// So: a turn that slept asks the edge now; `held` or `done` ends it
    /// here with a word to the person, exactly as the broken-stream path
    /// does. No arbiter, or a turn that did not sleep: nothing.
    func noteSystemWake() {
        queue.async { [self] in
            guard let c = current, sleptDuringTurn, !c.turn.silent, !c.turn.task.isEmpty,
                  let ask = taskArbiter else { return }
            let session = sessionID
            ask(c.turn.task) { [weak self] mayResume in
                guard let self else { return }
                self.queue.async {
                    guard !mayResume, let live = self.current, live === c, !live.finished,
                          self.sessionID == session else { return }
                    Log.write("hermes: the cloud took this ask while the Mac slept; ending it here")
                    live.cancelled = true
                    live.task.cancel()
                    live.handedToCloud = true
                    live.finished = true
                    self.current = nil
                    TurnKeeper.clear()
                    self.emit(.notice(Self.cloudHasItNote))
                    self.emit(.turnFinished(live.text, .handedToCloud))
                    self.pumpLocked()
                }
            }
        }
    }

    /// Said when the cloud has the ask — on the chat, which is where the
    /// cloud answers (docs/AWAY-HANDOFF.md §3), not here.
    static let cloudHasItNote = "Your Mac was asleep long enough that Moe carried on in the cloud. "
        + "The answer lands on the chat you last spoke to Moe from."

    /// The turn in flight is over; the session is not. Cancelling the
    /// request closes its stream, and the gateway ends the turn on the
    /// disconnect — measured at 65 ms from close to `turn finished`. The
    /// child stays warm and the next turn lands in the same conversation.
    func abandonTurn() {
        queue.async { self.abandonLocked() }
    }

    /// Hermes has no endpoint that interrupts a `/v1/chat/completions` turn
    /// by session: closing the stream is the interrupt (the gateway polls for
    /// the disconnect every 100 ms and interrupts the agent). `done` is when
    /// the stream is closed here.
    func abandonTurn(then done: @escaping @Sendable () -> Void) {
        queue.async {
            self.abandonLocked()
            done()
        }
    }

    /// A clean conversation: new session id, fresh prompt, and — like the
    /// CLI brains — a warm-up turn so the Conductor gets its `.ready` back.
    func reset(warmingUp: Bool = true) {
        queue.async {
            self.abandonLocked()
            self.sessionID = UUID().uuidString.lowercased()
            self.running = false
            self.startLocked()
            if warmingUp { self.warmUpLocked() }
        }
    }

    /// Carry on a thread: take the session id derived from it, and — when
    /// this session has not been told the conversation — send it as a silent
    /// turn before anything the person says next.
    ///
    /// This replaces the `reset()` that `openConversation` used to do. The
    /// derived id means a session Hermes still has in its `state.db` simply
    /// continues, transcript and all; the priming covers the case it does
    /// not, which is every thread that predates the ledger.
    func resume(_ resume: BrainResume) {
        queue.async {
            self.abandonLocked()
            self.sessionID = resume.sessionID
            self.threadID = resume.threadID
            self.running = false
            self.startLocked()
            if let priming = resume.priming {
                // Silent: the model sees it, the window does not, and no
                // reply comes back. It also serves as the warm-up turn.
                self.sendLocked(priming, silent: true, starter: .background, onDelivered: resume.onDelivered)
                Log.write("hermes: resumed \(resume.threadID) into session \(resume.sessionID), "
                          + "\(priming.count) characters of it")
            } else {
                Log.write("hermes: resumed \(resume.threadID) into session \(resume.sessionID)")
                self.warmUpLocked()
            }
        }
    }

    /// Provider and model: a warm `claude` child keeps the model it was
    /// started with, so a model change must not land on the same session.
    var brainFingerprint: String {
        queue.sync { "hermes/\(brain.provider.rawValue)/\(brain.model)" }
    }

    var currentSessionID: String { queue.sync { sessionID } }

    // MARK: - Sending

    func warmUp() {
        queue.async { self.warmUpLocked() }
    }

    func apply(brain: BrainSelection) {
        queue.async { self.brain = brain }
    }

    func remember(_ remembers: Bool) {
        queue.async { self.forgetting = !remembers }
    }

    private func warmUpLocked() {
        sendLocked("Respond with only the word: ready", silent: true, starter: .background)
    }

    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter) {
        send(text, images: images, silent: silent, logAs: logAs, starter: starter, spoken: false)
    }

    func send(_ text: String, images: [ImageAttachment], silent: Bool, logAs: String?,
              starter: TurnStarter, spoken: Bool) {
        queue.async {
            self.sendLocked(text, images: images, silent: silent, logAs: logAs, starter: starter,
                            spoken: spoken)
        }
    }

    private func sendLocked(_ text: String, images: [ImageAttachment] = [], silent: Bool,
                            logAs: String? = nil, starter: TurnStarter, spoken: Bool = false,
                            onDelivered: (() -> Void)? = nil) {
        // A launch that failed is not the end of this brain. The person
        // asking again is the best reason there is to try again, and it is
        // what the failure told them to expect; the turn queues behind the
        // start and is answered, or the start says plainly why not. Only for
        // a turn somebody is waiting on: a silent one must not make Moe
        // announce a failure nobody asked about.
        if !running, launchFailed, !shuttingDown, !silent {
            Log.write("hermes: asked while stopped after a failed launch; starting again")
            startLocked()
        }
        guard running, !shuttingDown else {
            emit(.error("Moe isn't connected."))
            return
        }
        // One turn at a time on a session. The CLI brains get this for free
        // from a stdin pipe; here two concurrent requests with the same
        // session id would race each other in Hermes's transcript.
        // A person's turn that has to wait for one of Moe's own — a warm-up,
        // a thread's priming — is waiting for the brain's process to start:
        // the same six seconds as a respawn, by another road, and until now
        // just as invisible in the log.
        if !silent, starter == .person, let ahead = current?.turn ?? pending.first, ahead.silent {
            Log.write("hermes: this turn is waiting behind a silent one (the brain is still starting)")
        }
        pending.append(turnLocked(text, images: images, silent: silent, logAs: logAs,
                                  starter: starter, spoken: spoken, onDelivered: onDelivered))
        if !silent { Log.write("→ \(logAs ?? text)") }
        pumpLocked()
    }

    /// A turn as `sendLocked` queues it: this chat's "don't remember" is
    /// taken now, so a re-issue keeps it.
    private func turnLocked(_ text: String, images: [ImageAttachment] = [], silent: Bool,
                            logAs: String? = nil, starter: TurnStarter, spoken: Bool = false,
                            onDelivered: (() -> Void)? = nil) -> Turn {
        Turn(text: text, silent: silent, images: images, logAs: logAs,
             starter: starter, task: silent ? "" : UUID().uuidString.lowercased(),
             spoken: spoken && !silent && starter == .person,
             forget: forgetting, onDelivered: onDelivered)
    }

    /// A turn as the request Hermes would receive for it now.
    private func requestLocked(for turn: Turn) -> URLRequest {
        Self.request(endpoint: endpoint, sessionID: sessionID, system: systemPrompt,
                     brain: brain, text: turn.text, images: turn.images,
                     starter: turn.starter, logAs: turn.logAs, spoken: turn.spoken,
                     forget: turn.forget)
    }

    /// The request the next turn sent would be, through `remember` and the
    /// queue the way a real one goes. For tests.
    func nextRequestForTesting(_ text: String, starter: TurnStarter) -> URLRequest {
        queue.sync { requestLocked(for: turnLocked(text, silent: false, starter: starter)) }
    }

    private func pumpLocked() {
        guard current == nil, !pending.isEmpty, running, gatewayReady else { return }
        let turn = pending.removeFirst()

        // Nothing to check here any more. A new brief used to mean a new
        // system prompt, which means Hermes kills the Claude Code child and
        // starts another one — and this was the backstop that paid that bill
        // in front of the person when the idle pass had not managed to:
        //
        //     07:00:15,533  conversation turn … msg='Where are you pulling…'
        //     07:00:15,539  claude-code: system prompt changed; respawning
        //     07:00:22,370  claude-code turn finished        ← 6.8 s
        //
        // The brief now rides on the user's turn (`BrainPrompt.briefBlock`),
        // so it is fresher than this ever made it and it costs nothing.

        // …but there IS something to check: whether what Moe is connected to
        // changed while this conversation was running. Bytes, not mtime, so
        // the ten-minute sync's identical rewrite costs nothing.
        refreshPromptIfConnectionsChangedLocked()

        let req = requestLocked(for: turn)
        noteSignatureLocked(of: req)
        let task = urlSession.dataTask(with: req)
        current = InFlight(task: task, turn: turn)
        // Debug-only, for scripts/test-turn-keeper.sh: pretend the Mac slept
        // during every turn, so the fake's dropped stream takes the resume
        // path. Compiled out of a release build (`TestHooks.env`).
        sleptDuringTurn = TestHooks.env("MOE_TEST_SLEPT_DURING_TURN") != nil
        if !turn.silent {
            TurnKeeper.write(.init(text: turn.text, logAs: turn.logAs, startedAt: Date(),
                                   sessionID: sessionID, resumed: turn.resumed, task: turn.task,
                                   thread: threadID))
            // "I am working on this" — at the start, so nothing has to beat
            // the lid. A re-issue opens the same task again, which the edge
            // treats as the same row.
            reportTaskLocked(.open, current!, status: "ok")
        }
        task.resume()
    }

    /// One turn as the request Hermes receives. Static and pure so the test
    /// that holds the launch signature still (`LaunchSignatureTests`) builds
    /// its turns through the very code a real one goes through.
    ///
    /// Session key "moe" is stable across conversations on purpose: the
    /// session id is the transcript, the key is the person. The Now line
    /// (ticket #9) is stamped here and nowhere else: this is the one place
    /// every turn — spoken, typed, a background note, a resume's priming, a
    /// re-issue after sleep — becomes a request, so none can go without it,
    /// and a re-issue's pre-sleep line is replaced by the time it is actually
    /// sent. `TurnClock` says why not at the callers.
    static func request(endpoint: HermesEndpoint, sessionID: String, system: String,
                        brain: BrainSelection, text: String, images: [ImageAttachment] = [],
                        starter: TurnStarter, logAs: String? = nil, spoken: Bool = false,
                        forget: Bool = false) -> URLRequest {
        endpoint.chatRequest(sessionID: sessionID, sessionKey: "moe",
                             system: system, user: TurnClock.stamped(text), stream: true,
                             brain: brain, images: images,
                             origin: starter,
                             // The person's own words, apart from the wrapper
                             // (`HermesEndpoint.chatRequest`): what the log calls
                             // the turn is exactly that, for every person-started send.
                             personWords: starter == .person ? (logAs ?? text) : nil,
                             spoken: spoken, noMemory: forget)
    }

    /// Say so when this request names a different launch than the last one
    /// into the same session did. Nothing is refused: a connection really did
    /// change, or somebody changed the language — but it is never silent.
    private func noteSignatureLocked(of request: URLRequest) {
        guard let signature = LaunchSignature(requestBody: request.httpBody) else { return }
        defer { lastSignature = (sessionID, signature) }
        guard let last = lastSignature, last.session == sessionID else { return }
        let moved = signature.changes(since: last.signature)
        guard !moved.isEmpty else { return }
        Log.write("hermes: this turn asks for a different brain process than the last one did — "
                  + moved.joined(separator: ", ")
                  + ". Hermes starts a new one under this turn (about six seconds).")
    }

    /// One line for the edge about the ask in flight. Portability is what
    /// this turn has reached for so far; `.done` carries the status.
    private func reportTaskLocked(_ op: BrainTaskReport.Op, _ c: InFlight, status: String) {
        guard !c.turn.task.isEmpty, !threadID.isEmpty, !c.handedToCloud else { return }
        onTask?(BrainTaskReport(op: op, task: c.turn.task, thread: threadID,
                                 portable: c.portable, status: status))
    }

    /// A stream that broke after a sleep: put the same ask back at the head
    /// of the queue, once, with a note saying why the model is seeing it
    /// again, after a moment for the gateway to come back with the Mac.
    /// True when that was done; false when the failure is the caller's to
    /// report as it always was.
    private func resumeAfterSleepLocked(_ c: InFlight, error: Error) -> Bool {
        guard !c.turn.silent else { return false }
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return false }
        let record = TurnKeeper.Record(text: c.turn.text, logAs: c.turn.logAs, startedAt: Date(),
                                       sessionID: sessionID, resumed: c.turn.resumed)
        let verdict = TurnKeeper.verdict(for: record, error: URLError.Code(rawValue: e.code),
                                         slept: sleptDuringTurn, consequential: c.consequential)
        switch verdict {
        case .giveUp:
            Log.write("hermes: stream broke (\(e.code)), slept=\(sleptDuringTurn), resumed=\(c.turn.resumed): not re-issued")
            return false
        case .stop:
            // It had already sent or paid: never again unasked. Told, and
            // closed on the edge as stopped so the cloud does not pick it up.
            Log.write("hermes: the Mac slept during a turn that had sent or paid; stopped, not re-issued")
            c.finished = true
            TurnKeeper.clear()
            reportTaskLocked(.done, c, status: "stopped")
            emit(.notice(TurnKeeper.stoppedNote))
            emit(.turnFinished(c.text, .stoppedAfterSleep))
            return true
        case .resume(let text):
            Log.write("hermes: the Mac slept during this turn and the stream broke (\(e.code)); picking it up again")
            // `.background` whoever asked first: a re-issue goes out after a
            // wake, and nobody may be at the Mac.
            let again = Turn(text: text, silent: false, images: c.turn.images, logAs: c.turn.logAs,
                             starter: .background, resumed: c.turn.resumed + 1, task: c.turn.task,
                             forget: c.turn.forget, onDelivered: c.turn.onDelivered)
            let session = sessionID
            pendingResume = (c, session)
            // Before it goes again: does this Mac still hold the ask? A sleep
            // long enough for the cloud to have taken it (the grace, then a
            // claim) ends here with the cloud's answer on its way, not with
            // two answers. No arbiter — no edge, or the free tier — means yes.
            let ask = taskArbiter ?? { _, done in done(true) }
            ask(c.turn.task) { [weak self] mayResume in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.running else { return }
                    // Dropped meanwhile (an interruption, a new conversation):
                    // `abandonLocked` cleared the token and said so.
                    guard let waiting = self.pendingResume, waiting.inflight === c,
                          self.sessionID == session else { return }
                    self.pendingResume = nil
                    if mayResume {
                        self.emit(.status("Picking up where Moe left off"))
                        self.pending.insert(again, at: 0)
                        self.pumpLocked()
                    } else {
                        Log.write("hermes: the cloud took this ask while the Mac slept; not re-issued here")
                        c.handedToCloud = true
                        c.finished = true
                        TurnKeeper.clear()
                        self.emit(.notice(Self.cloudHasItNote))
                        self.emit(.turnFinished(c.text, .handedToCloud))
                        self.pumpLocked()
                    }
                }
            }
            return true
        }
    }

    // MARK: - URLSessionDataDelegate (on `queue`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let c = current, c.task === dataTask {
            c.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let c = current, c.task === dataTask, !c.cancelled else { return }
        c.buffer.append(data)
        guard c.status == 200 else { return }   // error body; read it at the end
        drainLines(c)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = current, c.task === task else { return }
        current = nil
        defer { pumpLocked() }
        guard !c.cancelled else { return }

        if let error {
            // A turn Hermes finished cleanly and then hung up on is a finished
            // turn, not an error.
            if !c.finished, resumeAfterSleepLocked(c, error: error) { return }
            if !c.finished { finishTurn(c, error: describe(error), end: .failed) }
            return
        }
        if c.status != 200 {
            finishTurn(c, error: describeHTTPFailure(status: c.status, body: c.buffer), end: .failed)
            return
        }
        if !c.finished {
            // Stream ended without a finish chunk — a flush of whatever is
            // left in the buffer, then call it done.
            if !c.buffer.isEmpty { c.buffer.append(0x0A); c.buffer.append(0x0A); drainLines(c) }
            // …unless the Mac slept during it. Measured 2026-09-19 on the
            // owner's Mac: twenty seconds into a lid close the gateway's
            // stream ended CLEANLY, no finish chunk, no error — and this
            // called it a finished turn with an empty answer, cleared the
            // record, and on wake chimed for nothing. A sleep can end a
            // stream either way; both are the same break.
            if !c.finished, sleptDuringTurn,
               resumeAfterSleepLocked(c, error: URLError(.networkConnectionLost)) { return }
            guard !c.finished else { return }
            // Nothing at all came back. This used to be a finished turn with
            // an empty answer and `error: nil` — no words, no sound, the
            // island simply going quiet as though Moe had answered. Whatever
            // the cause, the person asked and got nothing, and that is a
            // failure they are told about. A stream that ended early with
            // some of the answer still stands as what it is.
            if c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.write("hermes: the stream ended with no finish and no answer"
                          + (c.consequential ? " (after a step that sent, paid or deleted)" : ""))
                finishTurn(c, error: c.consequential ? Self.noAnswerAfterActingNote : Self.noAnswerNote,
                           end: .failed)
            } else {
                finishTurn(c, error: nil, end: .streamEnded)
            }
        }
    }

    /// Said and shown when a turn ends with nothing in it. Spoken after
    /// "I couldn't answer that." (`SpokenError`), so it does not repeat it.
    static let noAnswerNote = "No answer came back. Ask me again."
    /// The same, when the turn had already sent, paid or deleted something:
    /// asking again unprompted could do it twice.
    static let noAnswerAfterActingNote =
        "No answer came back, but Moe had already started acting on it. Check what it did before asking again."

    // MARK: - SSE

    /// Tests only: a stand-in turn in flight (status 200, not silent), and
    /// `bytes` delivered to it through the real `urlSession(_:dataTask:didReceive:)`
    /// on the real queue — so they go through `drainLines` and `handleEvent`
    /// exactly as a live stream's do, and what comes out is `onEvent`'s.
    /// Nothing else about a turn (endpoint, auth, the edge) is involved.
    #if DEBUG
    /// `thenEnd`: the stream then closes cleanly, with no error, through the
    /// real `urlSession(_:task:didCompleteWithError:)` — how a stream that
    /// never sent a finish chunk ends.
    func replayStreamForTesting(_ bytes: Data, thenEnd: Bool = false) {
        queue.sync {
            let task = urlSession.dataTask(with: URL(string: "http://127.0.0.1:9/replay")!)
            let c = InFlight(task: task, turn: Turn(text: "replay", silent: false))
            c.status = 200
            current = c
            urlSession(urlSession, dataTask: task, didReceive: bytes)
            if thenEnd, current === c {
                urlSession(urlSession, task: task, didCompleteWithError: nil)
            }
            if current === c { current = nil }
        }
    }
    #endif

    /// Consume complete lines; a blank line dispatches the event built so far.
    private func drainLines(_ c: InFlight) {
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            var line = c.buffer[c.buffer.startIndex..<nl]
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            if line.last == 0x0D { line = line.dropLast() }
            guard let s = String(data: line, encoding: .utf8) else { continue }

            if s.isEmpty {
                if !c.dataLines.isEmpty {
                    handleEvent(c, name: c.eventName, data: c.dataLines.joined(separator: "\n"))
                }
                c.eventName = ""
                c.dataLines = []
            } else if s.hasPrefix(":") {
                continue                                    // ": keepalive"
            } else if s.hasPrefix("event:") {
                c.eventName = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if s.hasPrefix("data:") {
                var v = s.dropFirst(5)
                if v.first == " " { v = v.dropFirst() }
                c.dataLines.append(String(v))
            }
            if c.finished { break }
        }
        if c.buffer.count > 8_000_000 { c.buffer.removeAll(keepingCapacity: false) }
    }

    /// A `completed` `hermes.tool.progress` frame as the event it becomes.
    /// A failure the person can fix says which one, as `fix` on the frame
    /// (the fork's api_server, `fix_reasons.host_fields`); only a code the
    /// app knows is read, and anything else is a plain finish.
    static func toolFinished(frame obj: [String: Any], id: String) -> BrainEvent {
        .toolFinished(id: id, fix: ToolFix.parse(progressFrame: obj))
    }

    private func handleEvent(_ c: InFlight, name: String, data: String) {
        if data == "[DONE]" {
            if !c.finished { finishTurn(c, error: nil, end: .answered) }
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
        else { return }

        if name == "hermes.status" {
            // Lifecycle status from the engine. It has always existed and has
            // never reached this app: it routes through the platform's status
            // adapter, and this route's `send()` is a stub, so the message was
            // produced and dropped. The fork now queues it onto this stream
            // (gateway/platforms/api_server.py, `_on_status`).
            let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            // Logged whole — the log is ours and this is how "why did Moe go
            // quiet" gets answered — but **not shown**. This channel carries
            // whatever the engine wants to say, in the engine's own words:
            // "approval-required: … set tools.terminal.security_mode: auto to
            // run them under the Hermes-owned deny list", "Session context
            // (~N tokens) exceeds the model context window … enable
            // compression in config.yaml". Putting that on Moe's status line
            // would name the engine, the config file and the deny list on the
            // one surface a person reads, which is the thing this product
            // does not do. So exactly one status is shown: the one that says
            // Moe is about to stop answering.
            Log.write("status: \(text)")
            guard !c.turn.silent, Self.isUsageWarning(text) else { return }
            emit(.notice(text))
            return
        }

        if name == "hermes.tool.progress" {
            // Hermes sends the pair — `running` when a tool starts and
            // `completed` when it comes back, correlated by `toolCallId`
            // (gateway/platforms/api_server.py, `_on_tool_start` /
            // `_on_tool_complete`). Moe used to read the first and drop the
            // second, so the island went on reporting a step that had
            // finished minutes ago as the thing happening now. Both halves
            // are used here, and the id is what tells concurrent steps apart
            // — `delegate_task` runs several at once.
            guard !c.turn.silent else { return }
            let tool = obj["tool"] as? String ?? "tool"
            let id = obj["toolCallId"] as? String ?? tool
            switch obj["status"] as? String {
            case "running":
                // A Mac-only tool pins the ask to this Mac: said to the
                // edge once, the first time, and never unsaid.
                if c.portable, TaskPortability.isMacOnly(tool: tool) {
                    c.portable = false
                    reportTaskLocked(.open, c, status: "ok")
                }
                if !c.consequential, TaskPortability.isConsequential(tool: tool) {
                    c.consequential = true
                }
                // `label` is Hermes's own preview of the arguments — the
                // command it is about to run, the query it is searching for,
                // the file it is opening (`agent.display.build_tool_preview`,
                // already redacted for secrets). It is the truest short
                // account of what Moe is doing that exists, so it is what
                // gets shown; the tool's name is only the fallback for a
                // tool that reports no arguments.
                let label = (obj["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tool
                let emoji = (obj["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let spoken = SpokenStep.phrase(tool: tool, label: label)
                // Logged because everything else about a turn is, and because
                // "it went quiet" can only be told from "it was doing nothing"
                // by seeing which steps ran and what was said about them.
                Log.write("tool: \(tool) — \(label)" + (spoken.map { " · says \"\($0)\"" } ?? " · not spoken"))
                emit(.toolStarted(name: tool, id: id, emoji: emoji,
                                  detail: Self.describeTool(tool, label: label),
                                  spoken: spoken))
            case "completed":
                let event = Self.toolFinished(frame: obj, id: id)
                if case .toolFinished(_, let fix?) = event {
                    Log.write("tool: \(tool) failed, fixable: \(fix.code.rawValue)"
                              + (fix.subject.map { " · \($0)" } ?? "")
                              + (fix.pane.map { " · \($0)" } ?? ""))
                }
                emit(event)
            default:
                break
            }
            return
        }

        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return }
        if let delta = choice["delta"] as? [String: Any],
           let t = delta["content"] as? String, !t.isEmpty {
            c.text += t
            if !c.turn.silent { emit(.textDelta(t)) }
        }
        if let thinking = Self.reasoning(in: choice), !c.turn.silent {
            emit(.reasoningDelta(thinking))
        }
        if let reason = choice["finish_reason"] as? String {
            switch reason {
            case "stop":
                finishTurn(c, error: nil, end: .answered)
            case "length":
                finishTurn(c, error: nil, end: .truncated)   // truncated, but what we got is real
            default:
                let extras = obj["hermes"] as? [String: Any]
                let msg = (obj["error"] as? [String: Any])?["message"] as? String
                    ?? extras?["error"] as? String
                    ?? TurnError.generic
                // What the brain says is written for whoever is reading its
                // logs; what the island shows is Moe's. `TurnError` is the
                // one place that translates — the work limit the person set
                // (see `WorkLimit`), a turn that was still busy, and anything
                // naming an internal session id. The brain's own line always
                // goes to the log, here or in `finishTurn`.
                //
                // `failure_reason` / `failure_retryable` are Hermes's own
                // verdict on whether re-running can differ
                // (`agent/error_classifier.py`). The pinned fork computes
                // both and then drops them at the api_server boundary
                // (`_hermes_extras`), so today they are nil and
                // `BrainTrouble` falls back to prose; reading them here is
                // what makes a pin that carries them exact with no further
                // change on this side.
                let verdict = TurnError.personWords(
                    msg, provider: brain.provider,
                    failureReason: extras?["failure_reason"] as? String,
                    failureRetryable: extras?["failure_retryable"] as? Bool)
                if verdict.words != msg { Log.write("hermes: \(BrainTrouble.redacted(msg))") }
                // Kept before the turn ends, so the Settings row is already
                // there when somebody goes looking after reading the chat.
                if let keep = verdict.keep {
                    BrainTrouble.record(keep, provider: brain.provider)
                    Log.write("brain trouble: \(keep.rawValue) on \(brain.provider.rawValue)"
                              + " — Settings › Brain will say so until it is fixed")
                    // The one hard failure Moe already handled, kept because
                    // `configure-hermes.py --show` reads this marker and the
                    // Brain pane's sign-in line is built from it. It used to
                    // fire on two literal strings matched *after* translation
                    // — which this change would have silently stopped, since
                    // the translated sentence no longer carries them. Driven
                    // off the verdict instead, it now also fires for a
                    // rejection Hermes worded some other way.
                    if brain.provider.access == .claudeSignIn, keep == .credentialRejected {
                        ClaudeSignIn.markRejected()
                    }
                }
                finishTurn(c, error: verdict.words, end: .failed)
            }
        }
    }

    /// The end of a turn, good or bad. Same shape the `claude -p` adapter had: a
    /// failure is `.error` *and then* `.turnFinished` with whatever text got
    /// through, so the Conductor (and `Moe --ask`) always sees the turn end.
    /// Silent turns report nothing either way; problems that matter at launch
    /// — the gateway being down, a bad key — are the probe's job to surface.
    private func finishTurn(_ c: InFlight, error: String?, end: TurnEnd) {
        c.finished = true
        if !c.turn.silent {
            TurnKeeper.clear()
            reportTaskLocked(.done, c, status: error == nil ? "ok" : "error")
        }
        if let error { Log.write("hermes: \(error)") }
        // Hermes answered, so Hermes has it. A turn that errored, was
        // cancelled, or never left `pending` does not reach here, which is
        // the whole point of confirming rather than assuming.
        if error == nil {
            c.turn.onDelivered?()
            // **A turn that worked is the proof the trouble is over.** The row
            // in Settings › Brain clears itself here rather than waiting for a
            // restart or a button, because the person fixed the thing they
            // were told to fix and a row that outlives the fault is the same
            // lie as no row at all. A silent turn counts: it spent the same
            // credential on the same provider.
            BrainTrouble.clear()
            gatewayInDoubt = false
        }
        if c.turn.silent {
            Log.write("← (silent turn complete)")
            return
        }
        if let error { emit(.error(error)) }
        // The allowance of requests to the connected apps ran out during
        // this turn (or a background one since the last): said once, here,
        // rather than left to whatever the model made of the refusal.
        if let capped = ComposioCapNotice.take() {
            Log.write("notice: \(capped)")
            emit(.notice(capped))
        }
        Log.write("← \(c.text)")
        emit(.turnFinished(c.text, error == nil ? end : .failed))
    }

    // MARK: - Errors, in the user's words

    /// Every one of these is spoken or shown on the island, so none of them
    /// may name a port, a process or a file: what happened, and what to do.
    private func describe(_ error: Error) -> String {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else {
            return "Moe can't reach the part of itself that thinks. Try again in a moment."
        }
        switch URLError.Code(rawValue: e.code) {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            guard let supervisor else {
                return "The part of Moe that thinks isn't running. Quit Memoe and open it again."
            }
            // Tell the supervisor: an adopted gateway that has gone away is
            // replaced sooner if it doesn't wait for its own next check.
            supervisor.noteUnreachable()
            gatewayInDoubt = true
            switch supervisor.standing {
            case .owned:
                return "Moe is starting the part of itself that thinks. Ask me again in a moment."
            case .adopted:
                return "The part of Moe that thinks stopped answering. Moe is starting a fresh one — ask me again in a moment."
            case .failed(let why):
                return "Moe stopped thinking and couldn't start again. \(why) Try New Conversation."
            }
        case .timedOut:
            // Two minutes without a byte from a gateway that sends a
            // keepalive every thirty seconds. Usually a provider that stopped
            // mid-answer; sometimes the gateway itself, alive and answering
            // nothing — and until 2026-11-12 nothing looked, so every turn
            // after it ended here too. The supervisor asks the gateway
            // directly and replaces it only if it does not answer; a slow
            // turn on a healthy gateway is left exactly as it is.
            if let supervisor {
                supervisor.noteUnreachable()
                gatewayInDoubt = true
            }
            return "Moe is taking too long to answer. Try again."
        case .cancelled:
            return "Stopped."
        default:
            return "Moe lost its train of thought. Try again."
        }
    }

    private func describeHTTPFailure(status: Int, body: Data) -> String {
        let message = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"]
                       as? [String: Any])?["message"] as? String
        switch status {
        case 401:
            // A mismatch between Moe's own two halves; nobody can fix it by
            // reading two file paths, and a reinstall does fix it.
            return "Moe couldn't unlock its own thinking. Quit Memoe and open it again; if it keeps happening, reinstall Memoe."
        case 403:
            return message ?? "Moe wouldn't do that."
        case 503:
            return message ?? "Moe is busy right now — ask me again in a moment."
        default:
            return message ?? "Something went wrong while Moe was thinking. Try again."
        }
    }

    private func emit(_ e: BrainEvent) {
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    // MARK: - Helpers

    /// The phrase the engine uses when the subscription window is nearly
    /// spent: `heads up — 93% of your five hour limit used`. Matched on the
    /// two words that carry the meaning rather than the whole sentence, so a
    /// reworded percentage or window name still lands.
    ///
    /// Source of truth is `agent/transports/claude_code_session.py`
    /// (`_on_rate_limit`), and `scripts/test-usage-warning.sh` reads that file
    /// to prove the phrase is still the one it emits — a rename there must
    /// fail a test here, not go quiet in production, because going quiet is
    /// precisely the failure this feature exists to prevent.
    static let usageWarningPhrase = "limit used"

    static func isUsageWarning(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains(usageWarningPhrase)
    }

    /// Hermes's own `label` is already a short phrase ("Searching: weather in
    /// Boston"); only the bare tool names need translating.
    private static func describeTool(_ tool: String, label: String) -> String {
        guard label == tool else { return label }
        switch tool {
        case "terminal", "execute_code": return "running a command"
        case "read_file":                return "reading a file"
        case "write_file", "patch":      return "writing a file"
        case "web_search":               return "searching the web"
        case "web_extract":              return "reading a page"
        case "browser_exec":             return "working in the browser"
        case "search_files":             return "searching your files"
        default:                         return tool.replacingOccurrences(of: "_", with: " ")
        }
    }
}
