import Foundation
import MoeBrain

/// Runs the Hermes gateway as a child of Moe, so the user never opens a
/// terminal, and keeps it running for as long as Moe is.
///
/// The gateway is the one process that holds the Claude sign-in for the
/// Hermes-owned Claude Code child (HERMES-PLAN.md, "Revised after review"),
/// which is what makes two rules here hard ones:
///
/// 1. **Only ever one gateway.** If a Hermes gateway already answers on the
///    port — at launch, on a restart, or because a second Moe won the race
///    to bind it — it is adopted, not duplicated: two gateways would be two
///    owners of the same credential, each refreshing it out from under the
///    other. An adopted gateway is not ours to restart or stop; if it stops
///    answering, the adopt-or-spawn decision is simply made again.
/// 2. **No orphan on quit.** `stop()` sends SIGTERM, waits five seconds, then
///    SIGKILLs the gateway's process group — but a crash or `kill -9` of Moe
///    never calls `stop()`. So the gateway is launched through a tiny bash
///    wrapper that holds the read end of a pipe from Moe; when Moe's side
///    closes for *any* reason, the wrapper TERMs the gateway's group and, five
///    seconds later, KILLs it (Hermes ignores SIGTERM while it drains a
///    turn). macOS has no `PR_SET_PDEATHSIG`; this is the portable
///    equivalent. A process we retire — a gateway that never answered — is
///    likewise TERM'd, then KILL'd, and its `Process` is kept until it has
///    actually exited.
///
/// What this cannot do: Hermes starts some helpers (browser, TTS, the MCP
/// watchdog) with `setsid`, in process groups of their own, and those can
/// outlive the gateway by Hermes's design. Moe has no handle on them.
///
/// Health = `GET /v1/models` with the bearer key. Only two answers count as
/// "a Hermes gateway is here": 200 with a JSON `data` array, or 401 with a
/// JSON `error` (the key is wrong, which HermesBrain explains). Anything else
/// on the port belongs to something that isn't Hermes, and the supervisor
/// says so rather than adopting or spawning on top of it.
///
/// Crash supervision: an exit we didn't ask for is restarted with backoff
/// (1, 2, 4… seconds, capped at 30), at most five times in ten minutes;
/// a gateway that stays healthy for a minute clears the count. After that
/// the supervisor says so once and keeps trying **silently**, once a minute
/// with a fresh window, until something answers; `start()` (New
/// Conversation) tries at once. Our own `stop()` is told apart from a crash
/// by process identity, as the old `claude -p` adapter did.
///
/// One exit is not a crash: Hermes refusing to start because its pid file
/// names a live process. Moe checks the *port* and Hermes checks its *lock*,
/// and a gateway started by hand can hold the second without the first. Then
/// the refusal is read off stderr and answered — adopt what answers on the
/// port, else spawn once more with Hermes's own `--replace` (§handleExitLocked).
///
/// A note on the credential: the setup-token goes into the gateway's
/// environment, and Hermes deliberately hands its whole environment to every
/// shell command the model runs (`tools/environments/local.py`). So the token
/// is visible to anything the model executes. Containment is the Claude Code
/// deny list and Hermes's terminal policy — not environment hygiene here.
///
/// Screen Recording and Accessibility (the model's eyes and hands — Hermes's
/// `computer_use` tool, which runs `screencapture` and posts CGEvents from
/// the hermes-tools MCP server, a Python child of the `claude` CLI, itself a
/// child of the gateway spawned here): TCC attributes both to the
/// *responsible process*, and for everything under this `Process()` chain —
/// Memoe.app → /bin/bash wrapper → hermes → claude → python → screencapture —
/// that is Memoe.app, because nothing in the chain goes through launchd or
/// `setsid` (the wrapper uses `set -m` job control, which changes the process
/// group but not TCC responsibility). So the prompts the user sees are for
/// **Moe**: "Moe would like to record this computer's screen" the first time
/// a screenshot is taken (it fails with "could not create image" until
/// granted — macOS shows the prompt once, then it is a Settings toggle), and
/// Accessibility for the first synthetic click/keystroke, which Moe already
/// holds for push-to-talk. If the gateway is ever launched by launchd or
/// through `open`, responsibility moves to that launcher and the toggles
/// would have to be granted to it instead. Deep links: `x-apple.systempreferences:
/// com.apple.preference.security?Privacy_ScreenCapture` and
/// `…?Privacy_Accessibility`.
/// TODO(Settings/BrainSettings.swift): a status row showing whether Moe has
/// Screen Recording (`CGPreflightScreenCaptureAccess()`) and Accessibility
/// (`AXIsProcessTrusted()`), each with a button opening the deep link above.
///
/// **Threading contract:** every stored property is confined to `queue`.
/// `whenReady` callbacks run on `queue`; `onError`/`onStatus` on main.
final class HermesSupervisor {

    /// Why the gateway could not be brought up, in the user's words.
    struct Failure: Error { let message: String }

    private let queue = DispatchQueue(label: "moe.hermes.supervisor")

    private enum State {
        case idle
        /// Deciding, or spawned and polling health.
        case starting
        /// Answering on the port. `owned` is false for an adopted gateway.
        case ready(owned: Bool)
        /// Died; a restart is scheduled.
        case restarting
        /// Gave up, or never had what it needed. `start()` tries again at
        /// once; after a crash ceiling the quiet retry timer does too.
        case failed(String)
        case stopped
    }

    /// What `GET /v1/models` said.
    private enum Verdict {
        case down          // nothing listening, or no answer
        case hermes(Int)   // a Hermes gateway: 200, or 401 with a JSON error
        case foreign(Int)  // something else owns the port
    }

    // MARK: State — queue-confined
    private var state: State = .idle
    private var process: Process?
    private var launchedAt = Date.distantPast
    /// Children asked to leave that have not yet exited, with their gateway
    /// PIDs. Held so their termination is observed and escalated — never
    /// dropped and forgotten.
    private var retiring: [(wrapper: Process, gateway: pid_t)] = []
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    /// Write end of the liveness pipe (the wrapper's stdin). Held open for
    /// the life of the child; closing it is what tells the wrapper we're gone.
    private var lifeline: Pipe?
    /// PID of the gateway itself, as reported by the wrapper. The wrapper's
    /// own PID is `process.processIdentifier`. 0 until parsed.
    private var gatewayPID: pid_t = 0
    private var firstStdoutLinePending = true
    private var stdoutRemainder = Data()
    private var waiters: [(Result<Void, Failure>) -> Void] = []
    private var healthTask: URLSessionDataTask?
    private var healthDeadline = Date.distantPast
    private var healthGeneration = 0
    /// Times of unexpected exits inside the sliding window.
    private var crashes: [Date] = []
    private var restartTimer: DispatchWorkItem?
    /// The last few KB of the current child's stderr, so an exit can be read
    /// for *why* — Hermes says "already running (PID N)" there and nowhere
    /// Moe can otherwise see.
    private var stderrTail = ""
    /// The current child was spawned with `--replace`, so a second refusal
    /// from it falls through to the ordinary crash path instead of replacing
    /// again. Bounded: one takeover per bring-up.
    private var spawnReplaces = false
    private var childReplaced = false
    /// Bumped per spawn. A stderr chunk that arrives after its child has
    /// exited must not land in the next child's tail — a refusal from one
    /// would make an ordinary crash of the next look like another.
    private var spawnGeneration = 0
    /// After the crash ceiling: a slow, silent retry is due. While it runs a
    /// second give-up is logged but not announced again.
    private var quietRetryTimer: DispatchWorkItem?
    private var quietRetries = 0
    private var adoptedWatch: DispatchWorkItem?
    private var adoptedMisses = 0
    /// The owned child a hang check is running against, if one is. Tied to
    /// the process rather than a flag: a check whose answer never comes back
    /// (its request was cancelled by an exit's own health check) cannot then
    /// block every later one, because the next child is a different object.
    private var hangCheckFor: Process?
    /// A hung gateway was retired; whoever is listening is told when its
    /// replacement answers (`onRecovered`).
    private var announceReturn = false
    private var logHandle: FileHandle?
    private var logSize: UInt64 = 0
    private var shuttingDown = false
    /// configure-hermes.py has been run once for this supervisor.
    private var configured = false

    /// Something went wrong *after* readiness callbacks were answered — the
    /// gateway kept crashing, say. Delivered on the main queue.
    var onError: ((String) -> Void)?
    /// A line for the status area. Delivered on the main queue.
    var onStatus: ((String) -> Void)?
    /// The gateway answers again after this supervisor had said it could not
    /// be brought up — the quiet retry worked, or a deliberate `start()` did —
    /// or after a hung one was replaced.
    /// Without this the recovery was known only here: the brain that was told
    /// "failed" stayed stopped, and refused every question on a Mac whose
    /// gateway was healthy. Delivered on the main queue.
    var onRecovered: (() -> Void)?
    /// A failure has been reported and nothing has answered since.
    private var gaveUp = false

    /// Where the gateway stands, for HermesBrain's error messages.
    enum Standing {
        /// Moe's own child (running, starting, or being restarted).
        case owned
        /// One Moe didn't start; Moe will replace it if it goes away.
        case adopted
        /// Given up, with the reason. `start()` (New Conversation) retries.
        case failed(String)
    }

    var standing: Standing {
        queue.sync {
            switch state {
            case .ready(let owned): return owned ? .owned : .adopted
            case .failed(let m):    return .failed(m)
            default:                return .owned
            }
        }
    }

    private let config: Config
    private let port: Int
    private let apiKey: String
    private let urlSession: URLSession
    private let healthTimeout: TimeInterval
    private let quietRetryInterval: TimeInterval
    private let hangProbeTimeout: TimeInterval
    private let hangProbeGap: TimeInterval

    static let logURL = Paths.logs.appendingPathComponent("hermes-gateway.log")
    private static let logLimit: UInt64 = 5 * 1024 * 1024
    private static let healthInterval: TimeInterval = 0.5
    private static let defaultHealthTimeout: TimeInterval = 30
    private static let stopGrace: TimeInterval = 5
    private static let maxCrashes = 5
    private static let crashWindow: TimeInterval = 600
    /// Healthy this long and the crash count starts over.
    private static let stableAfter: TimeInterval = 60
    /// An exit this soon after launch, with a healthy gateway on the port,
    /// is a lost race to bind — not a crash.
    private static let collisionWindow: TimeInterval = 3
    /// An adopted gateway is asked this often whether it's still there.
    private static let adoptedInterval: TimeInterval = 5
    /// Hermes refuses to start while its pid file names a live process, and
    /// says so on stderr within a moment of launch. An exit inside this
    /// window that carries that sentence is a refusal, not a crash.
    private static let refusalWindow: TimeInterval = 20
    /// After the crash ceiling, how long before the next silent attempt.
    private static let defaultQuietRetryInterval: TimeInterval = 60
    private static let stderrTailLimit = 4096
    /// How long one "are you there?" to Moe's own gateway may take, and the
    /// pause before asking a second time. Generous on purpose: these only
    /// run after a turn has already gone 120 s without a byte (Hermes sends
    /// a keepalive every 30 s, so that is four missed in a row) or the port
    /// refused a connection, and the thing being decided is whether to kill
    /// a process that may be an hour into somebody's research. A healthy
    /// gateway answers `/v1/models` in milliseconds however long its turns
    /// run; a Mac under heavy load is the case the five seconds are for.
    private static let defaultHangProbeTimeout: TimeInterval = 5
    private static let defaultHangProbeGap: TimeInterval = 3
    /// Two misses in a row, the same bar an adopted gateway is held to.
    private static let hangMisses = 2

    init(config: Config) {
        self.config = config
        self.port = (1...65535).contains(config.hermesPort) ? config.hermesPort : 8642
        self.apiKey = HermesKey.resolve(config)
        // Debug-only test hook: a shorter wait for the never-answers path.
        self.healthTimeout = TestHooks.env("MOE_HERMES_HEALTH_TIMEOUT").flatMap(Double.init)
            ?? Self.defaultHealthTimeout
        // Debug-only test hook: a shorter wait before the silent retry.
        self.quietRetryInterval = TestHooks.env("MOE_HERMES_RETRY_INTERVAL").flatMap(Double.init)
            ?? Self.defaultQuietRetryInterval
        // Debug-only test hooks: a quicker verdict on a hung gateway.
        self.hangProbeTimeout = TestHooks.env("MOE_HERMES_HANG_PROBE_TIMEOUT").flatMap(Double.init)
            ?? Self.defaultHangProbeTimeout
        self.hangProbeGap = TestHooks.env("MOE_HERMES_HANG_PROBE_GAP").flatMap(Double.init)
            ?? Self.defaultHangProbeGap
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.waitsForConnectivity = false
        cfg.connectionProxyDictionary = [:]   // loopback only; never via a proxy
        let dq = OperationQueue()
        dq.maxConcurrentOperationCount = 1
        dq.underlyingQueue = queue
        urlSession = URLSession(configuration: cfg, delegate: nil, delegateQueue: dq)
    }

    // MARK: - Public

    /// Bring the gateway up: adopt one that's already there, else spawn one.
    /// Idempotent while starting or ready; after a failure it tries again
    /// with a clean crash window.
    func start() {
        queue.async { self.startLocked() }
    }

    /// Call back once the gateway answers on the port — at once if it
    /// already does — or with a `Failure` if it can't be brought up.
    /// The callback runs on the supervisor's queue.
    func whenReady(_ callback: @escaping (Result<Void, Failure>) -> Void) {
        queue.async {
            switch self.state {
            case .ready:            callback(.success(()))
            case .failed(let m):    callback(.failure(Failure(message: m)))
            case .stopped:          callback(.failure(Failure(message: "Moe is shutting down.")))
            case .idle, .starting, .restarting:
                self.waiters.append(callback)
            }
        }
    }

    /// `done(owned, why)` once the gateway is up — `owned` true only for
    /// Moe's own child — or `done(false, why)` on any other terminal state.
    ///
    /// Answers from the queue-confined `state`, ON the queue, and never via
    /// `standing`: that does `queue.sync` on this same queue, and a caller
    /// that read it inside a `whenReady` callback trapped libdispatch
    /// (`__DISPATCH_WAIT_FOR_QUEUE__`, exit 133) — on the first launch that
    /// ever decided to move Hermes, and at every launch after. Callers that
    /// need `standing` must hop to their own queue first; this one exists so
    /// `HermesUpgrade`'s gate does not have to remember that.
    func whenOwnedReady(_ done: @escaping (Bool, String) -> Void) {
        whenReady { [weak self] result in
            guard let self else { done(false, "the supervisor is gone"); return }
            switch result {
            case .success:
                if case .ready(let owned) = self.state {
                    done(owned, owned ? "Moe's own gateway is up" : "another Moe holds the gateway (adopted)")
                } else {
                    done(false, "the gateway is no longer ready")
                }
            case .failure(let f):
                done(false, f.message)
            }
        }
    }

    /// HermesBrain couldn't connect, or a turn went silent until it timed
    /// out. For an adopted gateway this brings the next liveness check forward
    /// instead of waiting out the interval.
    ///
    /// For Moe's OWN gateway it is the only liveness check there is. Until
    /// 2026-11-12 this returned at once for an owned gateway, on the reasoning
    /// that a child's exit is observed directly — true, and no help when the
    /// child is alive and has stopped answering. Every turn then ended in
    /// "Moe is taking too long to answer" after 120 s, for as long as the app
    /// stayed open, with a supervisor that believed it was `.ready`.
    ///
    /// The report is evidence, not a verdict: a research turn can run for half
    /// an hour by design, and a turn that timed out here says nothing about
    /// the other sessions the gateway is serving. So the gateway is ASKED —
    /// `/v1/models`, twice — and only one that answers neither is retired.
    func noteUnreachable() {
        queue.async {
            switch self.state {
            case .ready(owned: false):
                self.adoptedWatch?.cancel()
                self.watchAdoptedLocked(delay: 0)
            case .ready(owned: true):
                guard let p = self.process, self.hangCheckFor !== p else { return }
                self.hangCheckFor = p
                self.checkOwnedForHangLocked(p, misses: 0)
            default:
                return
            }
        }
    }

    /// Is Moe's own gateway still answering? One that is gets left alone,
    /// however slow the turn that raised the question. One that misses twice
    /// is hung: retired, and a fresh one started in its place.
    private func checkOwnedForHangLocked(_ p: Process, misses: Int) {
        guard process === p, !shuttingDown, case .ready(owned: true) = state else {
            if hangCheckFor === p { hangCheckFor = nil }
            return
        }
        checkHealth(timeout: hangProbeTimeout) { [self] verdict in
            guard process === p, case .ready(owned: true) = state else {
                if hangCheckFor === p { hangCheckFor = nil }
                return
            }
            switch verdict {
            case .hermes:
                hangCheckFor = nil
                Log.write("hermes gateway: a turn got no answer, but the gateway answers on port "
                          + "\(port) — slow, not hung; leaving it alone")
            case .foreign(let status):
                // Something else answers on the port while our child lives.
                // Restarting ours would not move it; say so and stop.
                hangCheckFor = nil
                Log.write("hermes gateway: a turn got no answer, and port \(port) answered HTTP "
                          + "\(status) — not a gateway; leaving Moe's own as it is")
            case .down:
                let missed = misses + 1
                guard missed >= Self.hangMisses else {
                    queue.asyncAfter(deadline: .now() + hangProbeGap) { [weak self] in
                        self?.checkOwnedForHangLocked(p, misses: missed)
                    }
                    return
                }
                hangCheckFor = nil
                retireHungLocked(misses: missed)
            }
        }
    }

    /// Moe's own gateway is running and answers nothing. Replace it.
    ///
    /// Counted against the same budget as a crash, so a gateway that hangs
    /// again and again reaches the same ceiling and the same quiet retry — a
    /// hang cannot become a respawn loop. And each one costs a failed turn
    /// plus two unanswered checks first, so the rate is bounded from the
    /// other side by how often anybody asks.
    private func retireHungLocked(misses: Int) {
        let who = gatewayPID > 0 ? "pid \(gatewayPID)" : "wrapper \(process?.processIdentifier ?? 0)"
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.crashWindow }
        crashes.append(now)
        let leaving = process
        guard crashes.count <= Self.maxCrashes else {
            Log.write("hermes gateway: \(who) is running but stopped answering on port \(port) "
                      + "(\(misses) checks) — and that is too many times; retiring it")
            retireCurrentLocked()
            failLocked("The part of Moe that thinks kept stopping. Moe will keep trying "
                       + "quietly; New Conversation tries again right now.")
            scheduleQuietRetryLocked()
            return
        }
        Log.write("hermes gateway: \(who) is running but stopped answering on port \(port) "
                  + "(\(misses) checks) — hung; replacing it (attempt \(crashes.count) of \(Self.maxCrashes))")
        DispatchQueue.main.async { self.onStatus?("Restarting the part of Moe that thinks") }
        announceReturn = true
        retireCurrentLocked()
        // As a reload does it: wait for the retired child to be gone, and
        // never adopt it if it is not — see `bringUpAfterLocked`.
        state = .restarting
        bringUpAfterLocked(leaving)
    }

    /// Replace the running gateway with a fresh one, because a file it reads
    /// **only at boot** has changed under it — today that means the relay dial
    /// in `~/.hermes/.env` after an Away enrolment (CLOUD-PLAN 4a.2).
    ///
    /// Not a crash: the backoff window is untouched, so a person who enrols,
    /// leaves and enrols again does not spend the crash budget that exists to
    /// stop a broken gateway spinning.
    ///
    /// Deliberately does nothing in the four states where a restart would buy
    /// nothing or take something away — an adopted gateway is not Moe's to
    /// bounce, and one that has not spawned yet will read the new file itself.
    func reload(reason: String) {
        queue.async { [self] in
            guard !shuttingDown else { return }
            switch state {
            case .stopped:
                return
            case .ready(owned: false):
                Log.write("hermes gateway: \(reason), but this gateway was not started by Moe "
                          + "— restart it yourself for that to take effect")
            case .idle, .failed:
                Log.write("hermes gateway: \(reason); nothing is running, so the next start "
                          + "reads it")
            case .restarting:
                Log.write("hermes gateway: \(reason); a restart is already due and will read it")
            case .starting where process == nil:
                // Still deciding adopt-or-spawn. Whatever we spawn execs after
                // this, so it reads the new file without being told.
                Log.write("hermes gateway: \(reason); it has not started yet, so it will read it")
            case .starting, .ready(owned: true):
                // `.starting` with a child means it is already spawned and read
                // the OLD file — the same stale gateway as `.ready`, just not
                // answering yet.
                Log.write("hermes gateway: \(reason) — restarting so it re-reads .env")
                DispatchQueue.main.async { self.onStatus?("Restarting the part of Moe that thinks") }
                let leaving = process
                retireCurrentLocked()
                // `.restarting` for the duration of the wait, so `stop()`,
                // `start()` and a second `reload` all see that something is
                // already in hand rather than racing it.
                state = .restarting
                bringUpAfterLocked(leaving)
            }
        }
    }

    /// `bringUpLocked`, but not until the child we just retired has actually
    /// exited — or the grace period is up.
    ///
    /// **Without the wait this replaces a gateway with itself.** SIGTERM is
    /// asynchronous: for a moment the retired gateway is still listening, and
    /// `bringUpLocked`'s first act is to ask whether a Hermes is on the port
    /// and *adopt* one that answers. So the reload would adopt the process it
    /// had just told to die — as `owned: false`, which means Moe would then
    /// refuse to restart or stop it — and the new settings would reach nothing,
    /// which is the exact failure the reload exists to fix.
    ///
    /// The crash path never meets this because `scheduleRestartLocked` waits
    /// out a backoff of at least a second first. A reload has no backoff to
    /// hide behind, so it waits on the artefact instead of on a duration:
    /// `retiring` holds the child until its termination is observed.
    private func bringUpAfterLocked(_ leaving: Process?, deadline: Date? = nil) {
        guard !shuttingDown, case .restarting = state else {
            // `.restarting` is the marker this walk owns the bring-up. Anything
            // else means something newer took over — a stop, or a crash of the
            // child that was still on its way out — and it decides, not this.
            return
        }
        let end = deadline ?? Date().addingTimeInterval(Self.stopGrace + 2)
        let gone = leaving == nil || !retiring.contains { $0.wrapper === leaving! }
        if gone || Date() >= end {
            if !gone {
                // It ignored SIGTERM and SIGKILL has been sent. An earlier
                // version went ahead with the ordinary adopt-or-spawn here,
                // reasoning that "a gateway still there after the grace period
                // is one the adopt path would have taken anyway" — which is
                // not the same situation at all: Moe has just killed this
                // process group, so adopting it would hand the slot to a
                // dead-man-walking and mark it not-ours-to-restart. The whole
                // hazard this function exists for, moved behind a timer.
                Log.write("hermes gateway: the retired child outlived the grace period; "
                          + "starting the replacement, and not adopting what is still there")
            }
            bringUpLocked(mayAdopt: gone)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.bringUpAfterLocked(leaving, deadline: end)
        }
    }

    /// Terminate the gateway we own. Synchronous: SIGTERM, up to five
    /// seconds of grace, then SIGKILL. Safe to call more than once.
    func stop() {
        var wrapper: Process?
        var gateway: pid_t = 0
        var leftovers: [(wrapper: Process, gateway: pid_t)] = []
        queue.sync {
            shuttingDown = true
            restartTimer?.cancel(); restartTimer = nil
            quietRetryTimer?.cancel(); quietRetryTimer = nil
            adoptedWatch?.cancel(); adoptedWatch = nil
            healthTask?.cancel(); healthTask = nil
            wrapper = process
            gateway = gatewayPID
            leftovers = retiring
            process = nil
            gatewayPID = 0
            state = .stopped
            let pending = waiters; waiters = []
            for w in pending { w(.failure(Failure(message: "Moe is shutting down."))) }
        }
        // A retiring child is already on its way out (TERM sent, KILL
        // scheduled); make sure of it before the app is gone.
        for r in leftovers {
            if r.gateway > 0 { kill(-r.gateway, SIGKILL); kill(r.gateway, SIGKILL) }
            if r.wrapper.isRunning { kill(r.wrapper.processIdentifier, SIGKILL) }
        }

        if let p = wrapper, p.isRunning {
            Log.write("hermes gateway: stopping pid \(gateway) (wrapper \(p.processIdentifier))")
            p.terminate()   // SIGTERM to the wrapper, which forwards to the gateway's group
            let deadline = Date().addingTimeInterval(Self.stopGrace)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning || (gateway > 0 && kill(gateway, 0) == 0) {
                Log.write("hermes gateway: still running after \(Int(Self.stopGrace))s — SIGKILL")
                if gateway > 0 { kill(-gateway, SIGKILL); kill(gateway, SIGKILL) }
                kill(p.processIdentifier, SIGKILL)
                p.waitUntilExit()
            }
            Log.write("hermes gateway: stopped")
        }
        sweepDrivenBrowsers()
        // Dropping the lifeline last: if the wrapper somehow survived all of
        // the above, its stdin closing is one more reason for it to leave.
        queue.sync {
            teardownPipesLocked()
            closeLogLocked()
        }
    }

    /// Close the browser Hermes drives once the gateway is gone. It starts in
    /// its own session, so neither the SIGTERM nor the SIGKILL above reaches
    /// it, and a gateway that was killed never ran its own cleanup. Found by
    /// its `--user-data-dir` under Hermes's home (`DrivenBrowsers`), never by
    /// name: the person's own browser cannot match. SIGTERM, a short wait,
    /// then SIGKILL for whatever is still there.
    private func sweepDrivenBrowsers() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let table = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let pids = DrivenBrowsers.pids(inProcessTable: table, hermesHome: HermesUpgrade.hermesHome.path)
        guard !pids.isEmpty else { return }
        Log.write("hermes gateway: closing \(pids.count) driven browser(s) it left behind: \(pids)")
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    // MARK: - Bringing it up

    private func startLocked() {
        switch state {
        case .starting, .ready, .restarting, .stopped: return
        case .failed:
            // A deliberate retry starts a fresh window, and it is announced
            // like a first start: the person asked, so they hear the answer.
            crashes = []
            quietRetryTimer?.cancel(); quietRetryTimer = nil
            quietRetries = 0
        case .idle: break
        }
        guard !shuttingDown else { return }
        bringUpLocked()
    }

    /// The one decision, made at launch and again after every exit: is a
    /// Hermes gateway already on the port? Adopt it. Otherwise spawn ours.
    /// `mayAdopt: false` when we know the incumbent is one WE just killed —
    /// see `bringUpAfterLocked`. Adopting it would mark it `owned: false`,
    /// which means Moe will not restart or stop it, and that is exactly the
    /// failure a reload exists to prevent.
    private func bringUpLocked(mayAdopt: Bool = true) {
        guard !shuttingDown else { return }
        state = .starting
        checkHealth(timeout: 2) { [self] verdict in
            guard case .starting = state, process == nil else { return }
            if case .hermes = verdict, !mayAdopt {
                // Its port may still be held for a moment. Spawning loses the
                // bind, the health check fails, and the ordinary crash path
                // retries with backoff — which heals. Adopting never does.
                Log.write("hermes gateway: the gateway on port \(port) is the one Moe just "
                          + "retired; starting a replacement rather than adopting it")
                spawnLocked()
                return
            }
            switch verdict {
            case .hermes(let status):
                Log.write("hermes gateway: adopted an existing gateway on port \(port) "
                          + "(HTTP \(status); not started by Moe, so Moe won't restart or stop it)")
                becomeReadyLocked(owned: false)
            case .foreign(let status):
                // A person cannot act on a port number, but they can quit the
                // other app; the log has the detail for whoever wants it.
                Log.write("hermes gateway: port \(port) answered HTTP \(status) to /v1/models — not a gateway")
                failLocked("Another program on this Mac is using the door Moe needs. Quit it and open Memoe again.")
            case .down:
                spawnLocked()
            }
        }
    }

    private func becomeReadyLocked(owned: Bool) {
        state = .ready(owned: owned)
        if quietRetries > 0 {
            Log.write("hermes gateway: back, on silent attempt \(quietRetries) after giving up")
            quietRetries = 0
        }
        let pending = waiters; waiters = []
        for w in pending { w(.success(())) }
        if gaveUp || announceReturn {
            gaveUp = false
            announceReturn = false
            DispatchQueue.main.async { self.onRecovered?() }
        }
        if owned {
            // Stable for a minute: forget earlier crashes.
            let p = process
            queue.asyncAfter(deadline: .now() + Self.stableAfter) { [weak self] in
                guard let self, let p, self.process === p, case .ready(owned: true) = self.state else { return }
                self.crashes = []
            }
        } else {
            adoptedMisses = 0
            watchAdoptedLocked(delay: Self.adoptedInterval)
        }
    }

    /// Reported once: to whoever is waiting on readiness if anyone is
    /// (the initial `start()`), else through `onError` — a failure after
    /// readiness, such as an adopted gateway dying and the respawn not
    /// having what it needs, must not sit here unannounced.
    private func failLocked(_ message: String) {
        state = .failed(message)
        gaveUp = true
        Log.write("hermes gateway: \(message)")
        let pending = waiters; waiters = []
        for w in pending { w(.failure(Failure(message: message))) }
        // Said once. A silent retry that fails again is in the log, not on
        // the island: the person already heard it, and hearing it every
        // minute would be the thing they quit Moe to stop.
        if pending.isEmpty, quietRetries == 0 {
            DispatchQueue.main.async { self.onError?(message) }
        }
    }

    /// Giving up used to be final: `.failed` until New Conversation or a
    /// relaunch. On 2026-09-07 that left the owner's Moe brainless for ten
    /// minutes over a condition that had cleared itself — another gateway
    /// held Hermes's lock and was stopped by hand — because nothing ever
    /// looked again. So the ceiling is a pause, not a stop: every
    /// `quietRetryInterval` the adopt-or-spawn decision is made once more,
    /// with a fresh crash window, and silently — the message above was
    /// delivered once and stands until something answers on the port.
    private func scheduleQuietRetryLocked() {
        guard !shuttingDown else { return }
        quietRetryTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shuttingDown, case .failed = self.state else { return }
            self.quietRetries += 1
            self.crashes = []
            Log.write("hermes gateway: silent attempt \(self.quietRetries) after giving up")
            self.bringUpLocked()
        }
        quietRetryTimer = work
        queue.asyncAfter(deadline: .now() + quietRetryInterval, execute: work)
    }

    /// Before the first spawn of this supervisor's life: make sure ~/.hermes
    /// is Moe's (configure-hermes.py is idempotent, bounded, and runs off
    /// this queue so `standing` never waits on it). Then spawn.
    private func spawnLocked() {
        guard !shuttingDown else { return }
        state = .starting
        guard !configured, HermesConfigure.wanted else {
            spawnConfiguredLocked()
            return
        }
        configured = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            HermesConfigure.runAndLog()
            self?.queue.async {
                guard let self, !self.shuttingDown, self.process == nil,
                      case .starting = self.state else { return }
                self.spawnConfiguredLocked()
            }
        }
    }

    private func spawnConfiguredLocked() {
        guard !shuttingDown else { return }
        // The bundled Hermes is still being unpacked. Spawning now runs a
        // `hermes` that is not there yet — exit 127 five times over, the
        // "kept stopping" line, and a first minute of a fresh download that
        // looks broken (owner's Mac, 0.3.17, 2026-09-10 19:03:55). The seed's
        // own completion restarts the brain (AppDelegate), so wait for it.
        if SeedInstall.seedingNow, !Bootstrap.hermesInstalled() {
            Log.write("hermes gateway: waiting for the thinking part to finish unpacking")
            state = .idle
            return
        }
        state = .starting

        // The Hermes-owned Claude Code child signs in with a setup-token that
        // the in-app sign-in (or scripts/hermes-signin.sh) stored in the
        // keychain. No token, no
        // gateway: Hermes would come up and every turn would fail with a
        // login error, which is a worse message than this one.
        // Only the Claude provider starts that child; for any other brain
        // the token is optional (exported if present, so a later switch back
        // to Claude on this gateway still works) and its absence is no reason
        // to keep the gateway down.
        let token: String
        switch HermesKey.childOAuthToken() {
        case .success(let t): token = t
        case .failure(let f):
            guard config.brainProvider != .claudeCode else {
                failLocked(f.message)
                return
            }
            Log.write("hermes gateway: no Claude sign-in in the keychain; fine for \(config.brainProvider.rawValue)")
            token = ""
        }

        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        openLogLocked()

        let hermes = Paths.hermesBinary()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `--accept-hooks` sits on `gateway`, before the subcommand (see
        // `hermes gateway --help`); the env var below covers versions that
        // only read the setting from the environment.
        // The name after the script is bash's `$0`. It is what `ps` shows in
        // the argument list — nothing at runtime matches on it; only
        // scripts/test-hermes-supervisor.sh does, and that scopes on the fake
        // binary's path rather than this string. It is
        // **not** what Activity Monitor prints in its Process Name column,
        // which reads `bash` regardless, because bash does not write `$0` into
        // its own argv. An earlier version of this comment claimed otherwise;
        // it was measured and it was wrong.
        //
        // Naming it properly would mean `exec -a` on the bash process, or a
        // real helper binary in the bundle, and the interpreter below it would
        // still be `python3.14` — renaming *that* means giving the venv an
        // interpreter under a different name, and pyvenv.cfg resolution stops
        // working. So this is only for whoever runs `ps`, and it is still
        // worth more than "moe-hermes-wrapper".
        // "Moe Helper", not "Moe Helper (thinking)". `$0` is fixed when the
        // process is spawned and this one lives for the whole session, so the
        // parenthesis was a claim the name could never keep: it read
        // "thinking" while the helper sat idle at 1% CPU, and the owner —
        // looking for something to stop after Moe had already stopped —
        // reasonably read it as still working. A label that cannot be kept
        // true should not assert. Same rule as the spoken step that said
        // "Working on your Mac" for every action.
        // `--replace` only on the second try after Hermes refused to start
        // because its pid file names a live process that Moe's port check
        // could not see — see `handleExitLocked`. Never on a first spawn: two
        // Moes racing to bind would each take over the other's gateway.
        var argv = [hermes, "gateway", "--accept-hooks", "run"]
        if spawnReplaces { argv.append("--replace") }
        childReplaced = spawnReplaces
        spawnReplaces = false
        p.arguments = ["-c", Self.wrapperScript, "Moe Helper"] + argv
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.environment = Self.childEnvironment(token: token)

        let life = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = life
        p.standardOutput = outP
        p.standardError = errP

        firstStdoutLinePending = true
        stdoutRemainder.removeAll()
        outP.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.ingestStdout(d) }
        }
        stderrTail = ""
        spawnGeneration += 1
        let generation = spawnGeneration
        errP.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.ingestStderr(d, generation: generation) }
        }

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                // Identity check: a process we deliberately retired or
                // stopped must not be mistaken for a crash of its replacement.
                if proc === self.process {
                    self.handleExitLocked(proc)
                } else if let i = self.retiring.firstIndex(where: { $0.wrapper === proc }) {
                    self.retiring.remove(at: i)
                    Log.write("hermes gateway: retired wrapper \(proc.processIdentifier) has exited (\(Self.describeExit(proc)))")
                }
            }
        }

        do {
            try p.run()
        } catch {
            teardownPipesLocked()
            Log.write("hermes gateway: couldn't start \(hermes): \(error.localizedDescription)")
            // Two different failures wore the same sentence, and one of them
            // was advice that could not work: on a Mac that only downloaded
            // Moe, the thinking part was never installed, so "reinstall Memoe"
            // reinstalled everything except the missing thing. Bootstrap can
            // tell the two apart, and Settings › Brain has the button.
            if !Bootstrap.hermesInstalled() {
                failLocked("Moe's thinking part isn't installed on this Mac yet. Open Settings › Brain and choose Set it up — it takes a minute or two.")
            } else {
                failLocked("Moe couldn't start the part of itself that thinks. Quit Memoe and open it again; if it keeps happening, open Settings › Brain and choose Set it up.")
            }
            return
        }

        process = p
        launchedAt = Date()
        gatewayPID = 0
        lifeline = life
        outPipe = outP
        errPipe = errP
        Log.write("hermes gateway: launched \(hermes) (wrapper pid \(p.processIdentifier))")

        healthDeadline = Date().addingTimeInterval(healthTimeout)
        pollHealthLocked(for: p)
    }

    /// Poll every half second until the port answers or the deadline passes.
    private func pollHealthLocked(for p: Process) {
        guard process === p, !shuttingDown else { return }
        checkHealth(timeout: 1) { [self] verdict in
            guard process === p, case .starting = state else { return }
            if case .hermes = verdict {
                let who = gatewayPID > 0 ? "pid \(gatewayPID)" : "wrapper \(p.processIdentifier)"
                Log.write("hermes gateway: healthy on port \(port) (\(who))")
                becomeReadyLocked(owned: true)
            } else if Date() >= healthDeadline {
                Log.write("hermes gateway: no answer on port \(port) after "
                          + "\(Int(healthTimeout))s — giving up on this attempt")
                // Treat it as a crash: retire it and let the backoff decide.
                retireCurrentLocked()
                scheduleRestartLocked(after: "It started but never answered.")
            } else {
                queue.asyncAfter(deadline: .now() + Self.healthInterval) { [weak self] in
                    self?.pollHealthLocked(for: p)
                }
            }
        }
    }

    /// Liveness of a gateway that isn't ours. Two misses in a row and the
    /// adopt-or-spawn decision is made again.
    private func watchAdoptedLocked(delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .ready(owned: false) = self.state, !self.shuttingDown else { return }
            self.checkHealth(timeout: 2) { verdict in
                guard case .ready(owned: false) = self.state else { return }
                if case .hermes = verdict {
                    self.adoptedMisses = 0
                    self.watchAdoptedLocked(delay: Self.adoptedInterval)
                    return
                }
                self.adoptedMisses += 1
                if self.adoptedMisses < 2 {
                    self.watchAdoptedLocked(delay: 1)
                    return
                }
                Log.write("hermes gateway: the gateway on port \(self.port) that Moe didn't start has "
                          + "stopped answering — starting Moe's own")
                DispatchQueue.main.async { self.onStatus?("Restarting the part of Moe that thinks") }
                self.bringUpLocked()
            }
        }
        adoptedWatch = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// `GET /v1/models` with the bearer key, judged by shape, not just status.
    private func checkHealth(timeout: TimeInterval, _ done: @escaping (Verdict) -> Void) {
        healthTask?.cancel()
        healthGeneration += 1
        let generation = healthGeneration
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        req.timeoutInterval = timeout
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let task = urlSession.dataTask(with: req) { [weak self] data, response, error in
            // Completion runs on the delegate queue, which is `queue`.
            guard let self, generation == self.healthGeneration else { return }
            self.healthTask = nil
            if error != nil { done(.down); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            switch status {
            case 200 where json?["data"] is [Any]:
                done(.hermes(200))
            case 401 where json?["error"] is [String: Any]:
                done(.hermes(401))
            case 0:
                done(.down)
            default:
                done(.foreign(status))
            }
        }
        healthTask = task
        task.resume()
    }

    // MARK: - Exit and restart

    private func handleExitLocked(_ proc: Process) {
        let how = Self.describeExit(proc)
        let age = Date().timeIntervalSince(launchedAt)
        process = nil
        gatewayPID = 0
        // What is left in the stderr pipe, read here rather than trusting the
        // readability handler to have run first: the refusal below is the
        // last thing Hermes writes before it exits. Polled, never a blocking
        // read to EOF — Hermes's `setsid` helpers can outlive it holding the
        // write end, and a blocking read here would hang this whole queue.
        if let h = errPipe?.fileHandleForReading {
            h.readabilityHandler = nil
            let rest = Self.drain(h.fileDescriptor)
            if !rest.isEmpty { ingestStderr(rest, generation: spawnGeneration) }
        }
        teardownPipesLocked()
        guard !shuttingDown else { return }
        Log.write("hermes gateway: exited (\(how)) after \(Int(age))s")
        let refusedBy = Self.lockHolder(in: stderrTail)
        stderrTail = ""
        // Read before it is cleared: the first run of scripts/test-hermes-
        // supervisor.sh §15c cleared it first, and a takeover Hermes refused
        // became a spawn loop with no backoff at all — thousands of gateways
        // in five minutes. The test exists so that this line stays here.
        let replaced = childReplaced
        childReplaced = false

        // Hermes refused to start: its pid file names a live process. Moe's
        // own check said nothing answers on the port, and both were right —
        // on 2026-09-07 a gateway started by hand held the lock without ever
        // binding the port, and Moe spent its whole crash budget in fifteen
        // seconds being told so, then gave up. Two truths, one decision:
        // if a Hermes answers on the port after all, it is the one to use;
        // if not, the lock-holder is dead weight and Hermes's own `--replace`
        // takes it over. Once per bring-up — a second refusal is a crash.
        if let holder = refusedBy, age < Self.refusalWindow {
            state = .starting
            checkHealth(timeout: 2) { [self] verdict in
                guard case .starting = state, process == nil else { return }
                if case .hermes = verdict {
                    Log.write("hermes gateway: refused — pid \(holder) holds Hermes's lock and answers "
                              + "on port \(port); adopting it")
                    becomeReadyLocked(owned: false)
                } else if !replaced {
                    Log.write("hermes gateway: refused — pid \(holder) holds Hermes's lock but nothing "
                              + "answers on port \(port); replacing it")
                    spawnReplaces = true
                    spawnLocked()
                } else {
                    scheduleRestartLocked(after: "It was refused again, even with --replace.")
                }
            }
            return
        }

        // Died almost at once with a healthy gateway on the port: we lost the
        // race to bind — another Moe, or a gateway started by hand between
        // our check and our spawn. That gateway is the one to use.
        if age < Self.collisionWindow {
            var wasReady = false
            if case .ready = state { wasReady = true }
            state = .starting
            checkHealth(timeout: 2) { [self] verdict in
                guard case .starting = state, process == nil else { return }
                if case .hermes = verdict {
                    Log.write("hermes gateway: port \(port) is already served by another gateway "
                              + "(port collision, not a crash) — adopting it")
                    if wasReady {
                        state = .ready(owned: false)
                        adoptedMisses = 0
                        watchAdoptedLocked(delay: Self.adoptedInterval)
                    } else {
                        becomeReadyLocked(owned: false)
                    }
                } else {
                    scheduleRestartLocked(after: "It stopped (\(how)).")
                }
            }
            return
        }
        scheduleRestartLocked(after: "It stopped (\(how)).")
    }

    /// The wrapper exits 128+N when the gateway died of signal N; the
    /// wrapper itself dying of a signal is reported as such too.
    private static func describeExit(_ proc: Process) -> String {
        let code = proc.terminationStatus
        if proc.terminationReason == .uncaughtSignal { return "signal \(code)" }
        return code > 128 ? "signal \(code - 128)" : "code \(code)"
    }

    /// Whatever is buffered on `fd` right now, without waiting for more.
    private static func drain(_ fd: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < 64 * 1024 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0, pfd.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            out.append(buf, count: n)
        }
        return out
    }

    /// The pid Hermes named when it refused to start, or nil if this stderr
    /// is not a refusal. Two spellings: the cheap preflight in hermes_cli
    /// ("Another gateway instance is already running (PID N).") and the
    /// authoritative check in gateway/run.py ("Gateway already running
    /// (PID N).").
    static func lockHolder(in stderr: String) -> pid_t? {
        guard stderr.contains("already running") else { return nil }
        guard let r = stderr.range(of: #"already running \(PID (\d+)"#, options: .regularExpression)
        else { return nil }
        let digits = stderr[r].drop { !$0.isNumber }
        return pid_t(digits)
    }

    private func scheduleRestartLocked(after why: String) {
        guard !shuttingDown else { return }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < Self.crashWindow }
        crashes.append(now)
        guard crashes.count <= Self.maxCrashes else {
            failLocked("The part of Moe that thinks kept stopping. Moe will keep trying "
                       + "quietly; New Conversation tries again right now.")
            scheduleQuietRetryLocked()
            return
        }
        let delay = min(pow(2.0, Double(crashes.count - 1)), 30)
        state = .restarting
        Log.write("hermes gateway: \(why) Restarting in \(Int(delay))s (attempt \(crashes.count) of \(Self.maxCrashes))")
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.shuttingDown, case .restarting = self.state else { return }
            self.bringUpLocked()
        }
        restartTimer = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Ask the current child to leave without treating its exit as a crash:
    /// TERM its group now, KILL it if it's still there after the grace
    /// period. The `Process` stays in `retiring` until it has exited.
    private func retireCurrentLocked() {
        guard let p = process else { return }
        let gpid = gatewayPID
        process = nil
        gatewayPID = 0
        teardownPipesLocked()
        retiring.append((wrapper: p, gateway: gpid))
        if gpid > 0 { kill(-gpid, SIGTERM) }
        if p.isRunning { p.terminate() }
        // The wrapper escalates on its own too; this is the belt to its braces.
        queue.asyncAfter(deadline: .now() + Self.stopGrace) { [weak self] in
            guard let self, self.retiring.contains(where: { $0.wrapper === p }) else { return }
            Log.write("hermes gateway: retired pid \(gpid) ignored SIGTERM — SIGKILL")
            if gpid > 0 { kill(-gpid, SIGKILL); kill(gpid, SIGKILL) }
            // The wrapper reaps the gateway and exits on its own; only if it
            // hasn't a moment later does it get the same treatment.
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.retiring.contains(where: { $0.wrapper === p }), p.isRunning else { return }
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    private func teardownPipesLocked() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        try? outPipe?.fileHandleForReading.close()
        try? errPipe?.fileHandleForReading.close()
        try? lifeline?.fileHandleForWriting.close()
        outPipe = nil
        errPipe = nil
        lifeline = nil
    }

    // MARK: - Gateway output → log

    /// Everything to the log; the tail of it kept for `handleExitLocked` to
    /// read the reason for an exit. Chunks from an earlier child are logged
    /// but never kept.
    private func ingestStderr(_ data: Data, generation: Int) {
        appendLogLocked(data)
        guard generation == spawnGeneration else { return }
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail = String(stderrTail.suffix(Self.stderrTailLimit))
        }
    }

    private func ingestStdout(_ data: Data) {
        guard firstStdoutLinePending else { appendLogLocked(data); return }
        stdoutRemainder.append(data)
        guard let nl = stdoutRemainder.firstIndex(of: 0x0A) else { return }
        let line = String(data: stdoutRemainder[stdoutRemainder.startIndex..<nl], encoding: .utf8) ?? ""
        let rest = stdoutRemainder[stdoutRemainder.index(after: nl)...]
        firstStdoutLinePending = false
        if line.hasPrefix("moe-hermes-pid "), let pid = pid_t(line.dropFirst("moe-hermes-pid ".count)) {
            gatewayPID = pid
            Log.write("hermes gateway: gateway pid \(pid)")
        } else {
            appendLogLocked(Data((line + "\n").utf8))
        }
        stdoutRemainder.removeAll()
        if !rest.isEmpty { appendLogLocked(Data(rest)) }
    }

    private func openLogLocked() {
        guard logHandle == nil else { return }
        let url = Self.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        logSize = (try? h.seekToEnd()) ?? 0
        logHandle = h
        let stamp = ISO8601DateFormatter().string(from: Date())
        appendLogLocked(Data("---- \(stamp) launched by Moe ----\n".utf8))
    }

    private func appendLogLocked(_ data: Data) {
        if logHandle == nil { openLogLocked() }
        guard let h = logHandle else { return }
        if logSize + UInt64(data.count) > Self.logLimit { rotateLogLocked() }
        try? (logHandle ?? h).write(contentsOf: data)
        logSize += UInt64(data.count)
    }

    /// Keep one previous generation: `hermes-gateway.log.1`.
    private func rotateLogLocked() {
        try? logHandle?.close()
        logHandle = nil
        let fm = FileManager.default
        let old = URL(fileURLWithPath: Self.logURL.path + ".1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: Self.logURL, to: old)
        logSize = 0
        openLogLocked()
    }

    private func closeLogLocked() {
        try? logHandle?.close()
        logHandle = nil
    }

    // MARK: - Environment

    static func childEnvironment(
        token: String,
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
    ) -> [String: String] {
        // The WHOLE process environment, PATH extended — not the four
        // variables this comment used to name. Anything set with
        // `launchctl setenv` reaches the gateway and every shell it
        // spawns, which is why the Composio gate corroborates
        // MOE_RUNS_IN with the platform rather than trusting it.
        var env = BrainPrompt.childEnvironment()
        let home = NSHomeDirectory()
        // Moe's own Python comes second, as it was always meant to: this list
        // named `~/.hermes/python/python/bin` from 2026-08-29, and nothing has
        // been at that path since the interpreter moved under `tools/` and
        // the venv. So `python3` in the gateway's children — both hooks, and
        // the skills that say `python3 …/moe-ticket.py` — has been whichever
        // Python the Mac had, or the developer-tools stub.
        env["PATH"] = "\(home)/.hermes/bin:" + BrainSetup.pathWithMoePython(
            "\(home)/.hermes/node/bin:" + (env["PATH"] ?? "/usr/bin:/bin"))
        // A local content filter / proxy on this Mac intercepts HTTP and breaks
        // Hermes's client (its TLS and its loopback calls both go wrong).
        // Hermes talks to loopback and to provider APIs that it must reach
        // directly; `*` opts every host out of any proxy the environment names.
        env["NO_PROXY"] = "*"
        env["no_proxy"] = "*"
        // Non-TTY: auto-approve shell hooks, or the gateway blocks on a prompt
        // nobody can see.
        env["HERMES_ACCEPT_HOOKS"] = "1"
        // Whether Moe may front a window or switch Space to finish something
        // it cannot do quietly. Read by the pre-tool hook, which is the only
        // place a policy the model cannot talk its way past can live: the
        // model chooses `delivery_mode`, so a rule enforced in the prompt is
        // a request, not a setting.
        env["MOE_COMPUTER_USE_TAKEOVER"] = Config.load().computerUseMayTakeOver ? "1" : "0"
        // What Hermes calls this app when a tool fails for a grant the person
        // can turn on (tools/fix_reasons.py `host_app_name`): the row they
        // will look for in System Settings. Unset, it says "the app".
        env["HERMES_HOST_APP_NAME"] = BuildInfo.hostAppName
        // Hermes's host-wide gateway singleton (upstream 9eb90b0a03,
        // gateway/host_rendezvous.py + host_attach.py) keeps its host lock
        // and rendezvous record in ONE directory per OS user —
        // `$HERMES_GATEWAY_LOCK_DIR`, else ~/.local/state/hermes/gateway-locks
        // — and a `gateway run` that finds a live owner there serving the
        // same profile ATTACHES to it and exits 0 without binding a port.
        // Moe, Moe Dev and a gateway a session starts in a terminal all run
        // the `default` profile of ~/.hermes, so in the shared directory any
        // one of them would stand down for another, and Moe's supervisor
        // would see a clean exit and no port. A directory inside this app's
        // own home gives each its own record; the per-home gateway.pid lock
        // (handled with `--replace`, see §handleExitLocked) is unchanged.
        // Set unconditionally: an inherited value (`launchctl setenv`) must
        // not put Moe back in the shared room. `gateway.standalone` cannot do
        // this — Hermes ignores it on the default profile. On a Hermes before
        // that commit the variable only moves the token-scoped locks
        // (gateway/status.py `_get_lock_dir`), which guard two gateways on
        // one bot token — impossible here, both would share ~/.hermes's lock.
        env["HERMES_GATEWAY_LOCK_DIR"] = Self.gatewayLockDirectory.path
        // Hermes never installs its own dependencies here. Since Hermes moved
        // to Python 3.14 and its `pm` package manager, a feature that wants an
        // optional extra (or a tool: node, uv, a browser) can build a fresh
        // environment under ~/.hermes/installs and boot into it from then on —
        // wheels from PyPI, outside the seed Memoe shipped and signed. This is
        // upstream's own switch for a sealed install (its Docker image sets
        // it); configure-hermes.py writes the config-file twin,
        // `security.allow_lazy_installs: false`, which covers the processes
        // this environment does not reach. Set unconditionally.
        env["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        // The Hermes-owned Claude Code child signs in with this. Never logged,
        // never written to a file — but see the class comment: Hermes passes
        // it on to every shell command the model runs.
        if !token.isEmpty { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        // Hermes's Anthropic adapter otherwise reads the user's *own* Claude
        // Code login out of the keychain, prefers it over the token above,
        // and on a 401 refreshes it — which rotates that login's refresh
        // token and logs every Claude Code session on the Mac out (seen
        // 2026-09-02). The fork honours this switch: never read, refresh or
        // write that login. Moe's brain runs on Moe's token or not at all.
        env["HERMES_CLAUDE_CODE_CREDENTIALS"] = "0"
        // Same rule the `claude -p` adapter had: an inherited API key must not let the
        // child bill an API account instead of using the subscription.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        // The Codex side of the same two rules. Hermes signs in to Codex on
        // its own (device code, its own store); it must never adopt and
        // refresh the user's Codex CLI login from ~/.codex/auth.json — the
        // fork honours this switch. And an inherited OpenAI key, Codex home
        // or Codex base URL (a shell launch) must not redirect the child.
        env["HERMES_CODEX_CLI_CREDENTIALS"] = "0"
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_HOME")
        env.removeValue(forKey: "HERMES_CODEX_BASE_URL")
        // Signal: Hermes's adapter talks to a signal-cli daemon, and
        // wrapperScript starts that daemon beside the gateway when this names
        // an executable (scripts/signal-daemon.sh, in Moe's own home so Moe
        // Dev runs its own). Never inherited: an unset name means no daemon.
        let signalDaemon = Paths.home.appendingPathComponent("scripts/signal-daemon.sh").path
        if FileManager.default.isExecutableFile(atPath: signalDaemon) {
            env["MOE_SIGNAL_DAEMON"] = signalDaemon
        } else {
            env.removeValue(forKey: "MOE_SIGNAL_DAEMON")
        }
        // The window a person types a password or a sign-in code into, so
        // the vault stores it without the model seeing it (ticket #17;
        // Sources/MoeConfirm/SecretMain.swift). Hermes runs this path as a
        // program — one argument, never split on spaces, which matters
        // because "Memoe Dev.app" has one. Never inherited: a value from
        // `launchctl setenv` or a shell would let anything on the Mac stand
        // in for the window that is handed the password.
        if let prompt = Self.secretPromptCommand(executableDirectory: executableDirectory) {
            env["HERMES_SECRET_PROMPT_CMD"] = prompt
        } else {
            env.removeValue(forKey: "HERMES_SECRET_PROMPT_CMD")
        }
        return env
    }

    /// Where this app's gateway keeps Hermes's host lock and rendezvous
    /// record: inside its own home, so Memoe and Memoe Dev never share one
    /// (see `childEnvironment`). Hermes creates it, mode 0700.
    static var gatewayLockDirectory: URL {
        Paths.home.appendingPathComponent("hermes-gateway-locks", isDirectory: true)
    }

    /// `moe-secret` beside this app's own executable — the link build.sh
    /// makes to `moe-confirm`, inside the signed bundle — or nil when there
    /// is none (a `swift run`, a test runner). A bare absolute path, not
    /// quoted: it is an exec path, not a shell line.
    static func secretPromptCommand(
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent()
    ) -> String? {
        guard let dir = executableDirectory else { return nil }
        let path = dir.appendingPathComponent("moe-secret").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs the gateway as a job in its own process group (`set -m` for the
    /// launch only, so bash prints no job-control chatter), reports its PID
    /// on the first stdout line, forwards SIGTERM/SIGINT/SIGHUP to that group
    /// with a KILL five seconds behind, and — the part that matters —
    /// does the same the moment its stdin (a pipe Moe holds) reaches EOF,
    /// which happens when Moe exits by any route at all, including a crash
    /// or `kill -9`. Exits with the gateway's status (128+N for signal N).
    /// Also runs the Hermes installer for `HermesUpgrade`: a child that must
    /// die with Moe, SIGKILL included, is exactly what this gives the gateway.
    static let wrapperScript = """
    trap '' PIPE
    exec 3<&0
    set -m
    # Signal's daemon (scripts/signal-daemon.sh) rides in the gateway's own
    # job: started by the same subshell that then execs the gateway, so it
    # shares the gateway's process group (reap below takes both) and its
    # parent pid IS the gateway's — which is how it stops by itself when the
    # gateway exits on its own. It does nothing unless Signal was linked.
    if [ -n "${MOE_SIGNAL_DAEMON:-}" ] && [ -x "$MOE_SIGNAL_DAEMON" ]; then
      ( "$MOE_SIGNAL_DAEMON" >/dev/null 2>&1 & exec "$@" ) </dev/null 3<&- &
    else
      "$@" </dev/null 3<&- &
    fi
    child=$!
    set +m
    echo "moe-hermes-pid $child"
    # The gateway's stdout/stderr are already wired to the log; from here on
    # bash's own job notices ("Killed: 9") would only add noise to it.
    exec 2>/dev/null
    # TERM the gateway's group; KILL it if it is still there five seconds
    # later. Polls rather than sleeps so the helper is gone as soon as the
    # gateway is.
    reap() {
      kill -TERM -- -"$child" 2>/dev/null
      for _ in $(seq 50); do kill -0 "$child" 2>/dev/null || return; sleep 0.1; done
      kill -KILL -- -"$child" 2>/dev/null
    }
    leave() { reap & }
    trap leave TERM INT HUP
    # fd 3 is Moe's pipe. With job control off, bash gives a background job
    # /dev/null for stdin, so the watcher must read the pipe through fd 3.
    { cat <&3 >/dev/null; reap; } &
    watcher=$!
    wait "$child"; code=$?
    while kill -0 "$child" 2>/dev/null; do wait "$child"; code=$?; done
    kill "$watcher" 2>/dev/null
    exit "$code"
    """
}

// MARK: - Keys and tokens

/// The two secrets Hermes needs from Moe: the gateway's bearer key (shared
/// with HermesBrain) and the Claude Code child's sign-in (supervisor only).
enum HermesKey {

    /// config.json's `hermesKey`, else `API_SERVER_KEY` from ~/.hermes/.env
    /// where `hermes gateway setup` keeps it. Empty means none.
    static func resolve(_ config: Config) -> String {
        config.hermesKey.isEmpty ? keyFromHermesEnv() : config.hermesKey
    }

    /// Quotes and `export` are tolerated.
    static func keyFromHermesEnv() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix("API_SERVER_KEY=") else { continue }
            var value = String(line.dropFirst("API_SERVER_KEY=".count))
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, (f == "\"" || f == "'"), value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }

    /// The keychain item `scripts/hermes-signin.sh` writes: service
    /// `moe-child-oauth`, account `moe`, holding the `claude setup-token`.
    /// The failure case is a user-facing sentence.
    ///
    /// Read through `/usr/bin/security` rather than `SecItemCopyMatching`:
    /// the item is written by the `security` tool with an access list of
    /// exactly that tool, so a direct API read from Moe would block on an
    /// access dialog the user may never see (a debug build with no window
    /// hangs forever). The value only ever lives in this pipe and the
    /// returned string — never a log or a file.
    /// The Conductor recognises a sign-in problem by this prefix and turns
    /// it into a "Sign in" call to action. scripts/test-hermes-supervisor.sh
    /// greps for it too.
    static let needSignInPrefix = "Moe needs an AI to think with"
    static let signInHint = "Connect one in Settings → Brain: your Claude or ChatGPT plan, or an API key."

    /// Is there a stored sign-in at all? Metadata only (no `-w`), so the
    /// item's access list is never consulted and no keychain dialog can
    /// appear — this runs at launch to decide whether to show onboarding.
    static func childOAuthTokenExists() -> Bool {
        let service = TestHooks.env("MOE_CHILD_TOKEN_SERVICE") ?? "moe-child-oauth"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TestHooks.env("MOE_SECURITY_BIN") ?? "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", "moe", "-s", service]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func childOAuthToken() -> Result<String, HermesSupervisor.Failure> {
        // Debug-only override so tests never touch the real item.
        let service = TestHooks.env("MOE_CHILD_TOKEN_SERVICE") ?? "moe-child-oauth"
        let needSignIn = needSignInPrefix
        let p = Process()
        // Debug-only: tests point this at a stub so the real keychain (and
        // its dialogs) is never touched. Release always uses the real tool.
        p.executableURL = URL(fileURLWithPath: TestHooks.env("MOE_SECURITY_BIN") ?? "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", "moe", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return .failure(.init(message: "\(needSignIn) — couldn't run /usr/bin/security (\(error.localizedDescription))."))
        }
        try? out.fileHandleForWriting.close()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        switch p.terminationStatus {
        case 0:
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                return .failure(.init(message: "\(needSignIn) — the stored sign-in is empty. \(signInHint)"))
            }
            return .success(token)
        case 44:   // errSecItemNotFound
            return .failure(.init(message: "\(needSignIn). \(signInHint)"))
        default:
            // Typically: the item exists but its access list doesn't admit
            // the security tool, or a keychain dialog was dismissed/timed out.
            return .failure(.init(message: "Moe couldn't get at your saved Claude sign-in. Your Mac may be "
                + "waiting for you to allow it — look for a box asking for your password. \(signInHint)"))
        }
    }
}

// MARK: - configure-hermes.py

/// Runs ~/.moe/hermes/configure-hermes.py the way the docs say a person
/// would: no flags, non-interactive, re-runnable. Exit 0 = done, 2 = done
/// but not signed in yet (not an error: the sign-in sheet is the fix),
/// anything else is logged. Bounded at 60 s.
enum HermesConfigure {
    static let timeout: TimeInterval = 60

    /// The line `configure-hermes.py` prints when it wrote a relay dial
    /// setting that was not already there — its `RELAY_CHANGED_MARKER`,
    /// spelled the same on both sides on purpose, and asserted equal by
    /// `test_configure_hermes.py` so the two cannot drift apart silently.
    ///
    /// It matters because the gateway reads `~/.hermes/.env` once, at boot,
    /// and `register_relay_adapter()` runs once, at startup. A dial written
    /// while the gateway is up reaches nothing until it is restarted — and
    /// the gateway is always up when somebody enrols in Settings › Away.
    static let relayChangedMarker = "MOE-RELAY-DIAL: changed"

    /// Off for the supervisor's tests: they run a fake gateway against a
    /// stub keychain, and configuring the real ~/.hermes for that would be
    /// wrong. `MOE_HERMES_CONFIGURE=0` says so explicitly; a test item
    /// name in the keychain hook implies it.
    static var wanted: Bool {
        if TestHooks.env("MOE_HERMES_CONFIGURE") == "0" { return false }
        // A test that has pointed the whole step at a stand-in is asking for
        // it to run. That is explicit, and it beats the inference below, which
        // exists only to keep the supervisor's own suite away from the real
        // ~/.hermes — a suite that sets both is saying what it wants.
        if TestHooks.env("MOE_HERMES_CONFIGURE_SCRIPT") != nil { return true }
        if TestHooks.env("MOE_CHILD_TOKEN_SERVICE") != nil { return false }
        return BrainSetup.scriptPath() != nil
    }

    enum Outcome { case done, notSignedIn, failed(String), missing }

    /// What the run did, and whether the relay dial moved while doing it.
    /// `relayChanged` is false for every outcome that wrote nothing, so a
    /// caller can act on it without checking the outcome first.
    struct Result {
        let outcome: Outcome
        let relayChanged: Bool
    }

    /// True if the relay dial changed, so the caller can restart the gateway.
    @discardableResult
    static func runAndLog() -> Bool {
        let result = run()
        switch result.outcome {
        case .done:             Log.write("configure-hermes: done")
        case .notSignedIn:      Log.write("configure-hermes: done; sign in first")
        case .failed(let why):  Log.write("configure-hermes: \(why)")
        case .missing:          Log.write("configure-hermes: script not found; skipped")
        }
        return result.relayChanged
    }

    static func run() -> Result {
        guard let script = BrainSetup.scriptPath() else {
            return Result(outcome: .missing, relayChanged: false)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: BrainSetup.python())
        p.arguments = [script]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["MOE_SECURITY_BIN"] = TestHooks.env("MOE_SECURITY_BIN") ?? "/usr/bin/security"
        // After an erase that removed CuaDriver, and until setup is finished
        // again: the launch that follows must not quietly put back what the
        // person just removed (configure-hermes.py SKIP_DRIVER_ENV).
        if MacEraseRun.holdsDriverInstall { env[MacEraseRun.skipDriverEnv] = "1" }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            return Result(outcome: .failed("couldn't run: \(error.localizedDescription)"),
                          relayChanged: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        let reader = DispatchQueue.global()
        let group = DispatchGroup()
        group.enter()
        reader.async {
            collected = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 1)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            group.wait()
            // A run we killed wrote nothing we can reason about: it may have
            // been mid-write, and claiming the dial changed would restart the
            // gateway on a guess. `relayChanged` is a fact or it is false.
            return Result(outcome: .failed("gave up after \(Int(timeout))s"), relayChanged: false)
        }
        p.waitUntilExit()
        group.wait()
        let text = String(decoding: collected, as: UTF8.self)
        // A WHOLE line, not `contains`: the marker also appears in this file,
        // in the script's own comments, and one day in a report note that
        // quotes it. A substring match would restart the gateway on a mention.
        let relayChanged = text.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == relayChangedMarker }
        switch p.terminationStatus {
        case 0: return Result(outcome: .done, relayChanged: relayChanged)
        case 2: return Result(outcome: .notSignedIn, relayChanged: relayChanged)
        default:
            let tail = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " | ")
            // A failed run may still have written .env before it failed —
            // the write happens well before the last of the payload installs
            // — so the marker is honoured whatever the exit code.
            return Result(outcome: .failed("exit \(p.terminationStatus): \(tail)"),
                          relayChanged: relayChanged)
        }
    }
}
