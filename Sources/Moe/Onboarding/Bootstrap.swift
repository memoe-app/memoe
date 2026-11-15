import Foundation

/// The parts of Moe that are not the app, and whether this Mac has them yet.
///
/// Moe is a Swift app with a Python agent under it: the app hears and speaks,
/// and Hermes thinks. Until now Hermes arrived only by running
/// `scripts/install.sh` from a git checkout, so someone who downloaded the dmg
/// got an app that dictated fine and answered nothing, and the only thing it
/// said about that was *"Moe couldn't start the part of itself that thinks.
/// Quit Memoe and open it again; if it keeps happening, reinstall Memoe"* — advice
/// that could not possibly work, because reinstalling did not include the part
/// that was missing.
///
/// The app now carries `install-hermes.sh` in its own payload (`Payload`), so
/// it can do this itself. This is the check and the fix, in one place, so that
/// onboarding and Settings › Brain give the same answer.
enum Bootstrap {

    /// What a failed set-up says: a plain sentence and what to do. Script
    /// names, paths and exit codes go to the log.
    enum Failure {
        static let damaged = "✗ This copy of Memoe is missing a piece it needs. Download Memoe again from memoe.app and replace this one."
        static let tookTooLong = "✗ That took too long, so I stopped it. Check your internet connection and try again — it picks up where it left off."
        static let didNotFinish = "✗ That didn't finish. Check your internet connection and try again — it picks up where it left off."
    }

    struct State {
        var hermes: Bool
        var claudeCLI: Bool

        /// Nothing here blocks anything. Dictation, meetings and the
        /// connectors all work without a brain; this is only about whether
        /// Moe can answer a question.
        var canThink: Bool { hermes }
    }

    static func state() -> State {
        State(hermes: hermesInstalled(), claudeCLI: ClaudeSignIn.claudePath() != nil)
    }

    /// True when a `hermes` executable exists where the supervisor will look.
    ///
    /// Deliberately *not* `Paths.hermesBinary()`: that returns the bare string
    /// "hermes" when it finds nothing (Config.swift), so asking it whether
    /// Hermes exists always says yes and the truth only arrives later, as a
    /// spawn failure the user cannot act on.
    ///
    /// "Exists" means launchable (`Paths.isLaunchable`): a leftover wrapper
    /// whose Python was deleted is not Hermes, and treating it as Hermes is
    /// what kept the bundled seed from ever being laid down.
    static func hermesInstalled() -> Bool {
        let configured = Config.load().hermesBinary
        if !configured.isEmpty, Paths.isLaunchable(configured) { return true }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/hermes",
            "\(home)/.hermes/hermes-agent/.venv/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
        return candidates.contains { Paths.isLaunchable($0) }
    }

    /// The installer, from wherever the payload put it.
    static func installerPath() -> String? {
        ScriptRunner.scriptPath("install-hermes.sh")
    }

    /// Installs Claude Code, if the user chose that way of thinking.
    ///
    /// Not bundled and never will be: it is Anthropic's own binary, ~190 MB,
    /// it updates itself, and it is **one of four answers** to the question
    /// onboarding asks. Someone who picks an API key or a local model needs
    /// none of it. So it is fetched at the moment it is chosen, by the same
    /// script `scripts/install.sh` uses — one implementation, because this is
    /// the code path that runs a script off the internet and two copies of it
    /// would drift.
    @discardableResult
    static func installClaudeCLI(progress: @escaping @Sendable (String) -> Void) -> Bool {
        guard let script = ScriptRunner.scriptPath("install-claude.sh") else {
            Log.write("bootstrap: install-claude.sh is not in the payload")
            progress(Failure.damaged)
            return false
        }
        progress("Getting Claude Code. It is about 200 MB.")
        let r = ScriptRunner.run(script, [], timeout: 900, onLine: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("✓") || t.hasPrefix("✗") || t.hasPrefix("›") { progress(t) }
        })
        if r.timedOut {
            Log.write("bootstrap: install-claude.sh timed out")
            progress(Failure.tookTooLong)
            return false
        }
        if r.status != 0 { Log.write("bootstrap: install-claude.sh exited \(r.status)") }
        return r.status == 0
    }

    /// Runs `install-hermes.sh`, reporting each ✓/✗ line as it arrives.
    ///
    /// The script is the same one a developer runs, unchanged and unwrapped:
    /// it downloads a pinned uv, a uv-managed Python 3.14 and the pinned
    /// Hermes commit, syncs a locked venv and puts a `hermes` wrapper on the
    /// PATH. It asks nothing, it is safe to re-run, and a half-finished run
    /// repairs itself on the next one. Measured at ~1.5 minutes and ~1.3 GB.
    ///
    /// `progress` is called on an arbitrary queue with one line at a time —
    /// the caller hops to the main actor. The timeout is twenty minutes, not
    /// the 60 s `HermesConfigure` uses: that one bounds a configuration step
    /// inside a launch, and this one bounds a 1.3 GB download that has hung.
    /// A bound short enough to protect a launch would cut off every slow
    /// connection instead.
    @discardableResult
    static func installHermes(progress: @escaping @Sendable (String) -> Void) -> Bool {
        // The seed first, when this build carries one: a local copy of a tree
        // Apple already notarized, with no network at all. The script below
        // stays as the fallback — for a development build, for a seed that
        // failed to land, and for `hermes update` afterwards — because an
        // offline path that silently becomes the only path would strand
        // anyone whose seed is damaged.
        // The launch-time copy (SeedInstall) may still be running: the seed
        // lock would then say "another copy of Memoe is installing it" and
        // this would fall through to a download nobody needs.
        if SeedInstall.seedingNow {
            progress("› It is already on its way — a few seconds more.")
            return false
        }
        if HermesSeed.bundleSeed != nil, !hermesInstalled() {
            progress("Setting up the part of Moe that thinks. It is already in the app, so this is quick.")
            let line = HermesSeed.installIfNeeded()
            if hermesInstalled() {
                progress("✓ Ready, with nothing downloaded. Now choose how Moe should think.")
                return true
            }
            // Not fatal, and worth saying: the fallback below is about to run
            // and the user should know why it is slower than promised.
            progress("› \(line)")
            progress("› Falling back to downloading it.")
        }

        guard let script = installerPath() else {
            Log.write("bootstrap: install-hermes.sh is not in the payload")
            progress(Failure.damaged)
            return false
        }
        progress("Setting up the part of Moe that thinks. This takes a minute or two.")
        // 20 minutes: the script itself is ~1.5 min on a normal connection,
        // and the cap is here to end a hung download rather than to bound a
        // slow one. It downloads ~1.3 GB.
        let r = ScriptRunner.run(script, [], timeout: 1200, onLine: { line in
            // The script's own ✓/✗/› lines are already written for a person;
            // everything else it prints goes to its log file, not here.
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("✓") || t.hasPrefix("✗") || t.hasPrefix("›") { progress(t) }
        })
        let result = r.status == 0 && !r.timedOut
        if r.timedOut {
            Log.write("bootstrap: install-hermes.sh timed out")
            progress(Failure.tookTooLong)
            return false
        }
        if result {
            progress("✓ Ready. Now choose how Moe should think.")
        } else {
            // Why is in the installer's own log (logs/install-hermes.log in
            // Moe's home) — for whoever reads logs, not for this screen.
            Log.write("bootstrap: install-hermes.sh exited \(r.status); see logs/install-hermes.log")
            progress(Failure.didNotFinish)
        }
        return result
    }
}

// MARK: - The seed, laid down at launch

/// Lays the bundled Hermes down once per process, from launch, and tells
/// whoever is watching. `Bootstrap.installHermes` is the button in Settings ›
/// Brain; this is what makes the button unnecessary on a Mac that only
/// downloaded the dmg. A stranger's first launch copies ~820 MB out of the
/// app in the background while they read the first two onboarding screens,
/// and the brain screen shows "getting ready" only for whatever is left.
///
/// One coordinator, because `HermesSeed.installIfNeeded` takes a lock and a
/// second caller during the copy is told "another copy of Memoe is installing
/// it" — which `installHermes` would then read as a failed seed and fall
/// back to the network download. So the button is only offered once this
/// has finished, one way or the other.
@MainActor
final class SeedInstall: ObservableObject {
    static let shared = SeedInstall()

    enum Phase: Equatable {
        /// No seed in this build, or Hermes is already here.
        case notNeeded
        case running
        case done
        /// The line `HermesSeed.installIfNeeded` returned. The network
        /// installer is the way forward from here.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .notNeeded

    /// Readable off the main actor, for `Bootstrap.installHermes`, which
    /// runs on a background queue. Written only on the main thread; a stale
    /// read costs one "already on its way" line, never a wrong install.
    nonisolated(unsafe) private(set) static var seedingNow = false

    private init() {}

    /// Idempotent. Runs the copy off the main thread and calls `done` on the
    /// main actor when Hermes is runnable — the moment to restart a brain
    /// that failed to launch a minute ago because there was nothing to run.
    func startIfNeeded(done: @escaping @MainActor () -> Void = {}) {
        guard phase != .running else { return }
        guard HermesSeed.bundleSeed != nil, !Bootstrap.hermesInstalled() else {
            phase = .notNeeded
            return
        }
        phase = .running
        Self.seedingNow = true
        Log.write("hermes seed: laying it down at launch")
        DispatchQueue.global(qos: .userInitiated).async {
            let line = HermesSeed.installIfNeeded()
            let ok = Bootstrap.hermesInstalled()
            DispatchQueue.main.async {
                Log.write("hermes seed: \(line)")
                Self.seedingNow = false
                self.phase = ok ? .done : .failed(line)
                if ok { done() }
            }
        }
    }
}
