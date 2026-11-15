import AppKit
import Darwin
import MoeDesign
import SwiftUI

// In-app Claude sign-in for the brain.
//
// The Hermes gateway's Claude Code child signs in with a long-lived
// setup-token (HERMES-PLAN.md, "Revised after review"). scripts/hermes-signin.sh
// is the reference for how that token is obtained and stored; this file is
// the same contract without a Terminal:
//
//   1. run `claude setup-token` under a pseudo-terminal (it refuses a pipe),
//   2. open the https URL it prints (claude.ai / anthropic.com only), in the
//      default browser,
//   3. the CLI asks for a code ("Paste code here if prompted >"): the sheet
//      shows a field, the user pastes what the browser page showed, and it
//      is typed into the CLI. Some versions get the code back on their own
//      and never ask; then the field never appears.
//   4. capture the `sk-ant-oat01-…` token from its output (ANSI stripped),
//   5. store it with /usr/bin/security as service `moe-child-oauth`,
//      account `moe`, access list = the security tool only — delete, then
//      add, never `-U` (see the script for why),
//   6. run configure-hermes.py and restart the gateway.
//
// Steps 5 and 6 are **this Mac's** destination, and since the Away brain
// sheet started using this flow they are one of two: `Destination.elsewhere`
// hands the captured token to a caller and writes nothing here — no keychain
// item, no ~/.hermes, no gateway restart. See `AwayBrainSetup.signInDestination`
// for why the away machine gets a token of its own rather than a copy of this
// one. Steps 1–4 — the pty, the host allowlist, the ANSI stripping, the
// length floor, the 401 check — are the same code for both, on purpose: a
// second copy of them is a second place for a guard to go missing.
//
// The token never reaches a log, a file, or the UI; the transcript that
// carried it is dropped the moment it is captured. Debug builds honour the
// same hooks the supervisor's tests use: MOE_SECURITY_BIN (a stub keychain)
// and MOE_CHILD_TOKEN_SERVICE (a test item name), plus MOE_CLAUDE_BIN (the
// fake CLI — required in `--signin-test`, so a test can never reach the
// real one).

extension Notification.Name {
    /// userInfo["section"]: a MainWindow.Section raw value to show.
    static let moeShowSection = Notification.Name("moe.showSection")
    /// Open the Claude sign-in sheet (the Brain pane listens).
    static let moeSignIn = Notification.Name("moe.signIn")
    /// A question was asked and no AI is connected: open the place to
    /// connect one (AppDelegate.watchConnectAnAI).
    static let moeConnectAnAI = Notification.Name("moe.connectAnAI")
    /// Threads changed on disk for a reason other than a reply landing —
    /// another device's turns arrived through the cloud. The Chat list
    /// reloads.
    static let moeConversationsChanged = Notification.Name("moe.conversationsChanged")
}

/// A child process on a pseudo-terminal: `claude setup-token` checks for a
/// tty and prints nothing useful on a pipe. `posix_spawn` with SETSID and
/// the slave opened as fd 0 makes it the child's controlling terminal;
/// `fork` is off the table in a process with Foundation's threads.
/// SETSID also makes the child its own process group, so `terminate` can
/// take its helpers (a browser opener, say) down with it.
final class PtyProcess {
    let pid: pid_t
    private let master: Int32
    private let lock = NSLock()
    private var closed = false

    struct SpawnError: Error { let message: String }

    init(path: String, arguments: [String], environment: [String: String]) throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else {
            throw SpawnError(message: "Couldn't open a terminal for the sign-in.")
        }
        let slavePath = String(cString: name)
        // A wide terminal: the CLI wraps its lines to the window, and a
        // token wrapped onto a second line would be captured cut short —
        // seen 2026-09-02, 79 of 108 characters, because the size never
        // took: on macOS TIOCSWINSZ on the master is ENOTTY until some
        // process holds the slave open, and the size is dropped again on the
        // slave's last close. So: open the slave here, size it through that
        // descriptor, keep ours open across the spawn (the child's own open
        // then carries the size), and close ours right after.
        // TIOCSWINSZ = _IOW('t', 103, struct winsize) = 0x80087467.
        let s = open(slavePath, O_RDWR | O_NOCTTY)
        guard s >= 0 else {
            close(m)
            throw SpawnError(message: "Couldn't open a terminal for the sign-in.")
        }
        var ws = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(s, UInt(0x8008_7467), &ws) == 0 else {
            close(s); close(m)
            throw SpawnError(message: "Couldn't size the terminal for the sign-in.")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, &attr, argv, envp)
        close(s)   // the child holds the slave now; ours would only keep EOF away
        guard rc == 0 else {
            close(m)
            throw SpawnError(message: "Couldn't start the sign-in (\(String(cString: strerror(rc)))).")
        }
        pid = child
        master = m
    }

    /// Blocks until the child has closed its side (or an error). Chunks
    /// are raw bytes: ANSI, carriage returns and all.
    func read(_ chunk: (Data) -> Void) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, 4096) }
            if n > 0 { chunk(Data(buf[0..<n])); continue }
            if n < 0 && errno == EINTR { continue }
            return   // 0 or EIO: the slave is closed
        }
    }

    func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var data = Array(text.utf8)
        while !data.isEmpty {
            let n = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, data.count) }
            if n <= 0 { return }
            data.removeFirst(n)
        }
    }

    /// The whole process group (the child is its leader), then the child
    /// itself in case it changed groups.
    func terminate() { kill(-pid, SIGTERM); kill(pid, SIGTERM) }
    func killNow() { kill(-pid, SIGKILL); kill(pid, SIGKILL) }

    /// Reap; returns the exit status (or 128+signal), -1 if unknown.
    func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { return -1 } }
        lock.lock(); closed = true; close(master); lock.unlock()
        if (status & 0x7f) != 0 { return 128 + (status & 0x7f) }
        return (status >> 8) & 0xff
    }
}

/// The sign-in itself, off the main thread. UI observes `phase`.
@MainActor
final class ClaudeSignInFlow: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Waiting for the browser step to complete.
        case approving
        /// The CLI wants the code the browser page shows. `rejected` after
        /// a code it didn't accept.
        case code(rejected: Bool)
        /// Token in hand; storing and configuring.
        case finishing
        case done
        /// `minted` is true when a real token was created at Anthropic before
        /// the failure. The sheet must say so: it is a credential that exists,
        /// that nobody can reach, and that signing in again does not replace.
        case failed(String, minted: Bool)
    }

    @Published private(set) var phase: Phase = .idle

    /// Where the browser was sent. Never the token. Published: the sheet
    /// shows it as a link to copy, and it arrives after the phase does.
    @Published private(set) var lastURL: URL?
    /// The last failure's sentence, kept across `cancel()` so a *caller* can
    /// show it after the sheet has closed. `cancel()` resets `phase`, so the
    /// Away brain sheet had no way to say anything at all when a sign-in
    /// failed and the person pressed "Not now" — the sheet vanished and the
    /// pane behind it was blank. Cleared by `begin()`. Never the token.
    private(set) var lastFailure: String?
    /// True when `lastFailure` came after a token had been minted.
    private(set) var lastFailureMinted = false
    private var running = false
    private var cancelled = false
    /// Which run the results arriving on the main actor belong to. `reset()`
    /// bumps it, so a run that is still dying cannot overwrite the phase of
    /// the one that replaced it. Without this, pressing the button again
    /// inside the SIGTERM→SIGKILL window either did nothing (the old
    /// `cancel()` left `running` true, so `begin()` returned immediately and
    /// the sheet sat on a spinner over a dead process) or, once `running` was
    /// cleared, let the dead run's "Cancelled." land on the live one.
    private var generation = 0

    /// After the token is stored: configure Hermes and restart the brain.
    /// Nil (tests) skips both.
    var onStored: (() -> Void)?
    /// How to open the approval page. Tests substitute a recorder.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Where the token goes when it is captured. The default is this Mac's
    /// brain; the Away brain sheet sets a hand-off that seals it for the
    /// machine and leaves this Mac's own sign-in exactly where it was.
    /// Set it *before* `begin()` — it is read once, on the way in.
    var destination: ClaudeSignIn.Destination = .thisMac
    /// `Moe --onboarding-rehearsal`: walk the sheet's phases on a timer
    /// instead of running the sign-in tool. No browser, no token, nothing
    /// stored. Any code typed in is "accepted".
    var rehearsal = false

    func begin() {
        guard !running else { return }
        lastFailure = nil
        lastFailureMinted = false
        if rehearsal {
            phase = .approving
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.phase == .approving else { return }
                self.phase = .code(rejected: false)
            }
            return
        }
        running = true
        cancelled = false
        generation += 1
        let gen = generation
        phase = .approving
        lastURL = nil
        let open = openURL
        let where_ = destination
        let weakSelf = WeakBox(self)
        Task.detached(priority: .userInitiated) {
            let result = ClaudeSignIn.run(event: { event in
                Task { @MainActor in
                    guard let self = weakSelf.value else { return }
                    switch event {
                    case .url(let url):
                        self.lastURL = url
                        open(url)
                    case .codeNeeded:
                        if self.phase == .approving { self.phase = .code(rejected: false) }
                    case .codeRejected:
                        self.phase = .code(rejected: true)
                    case .tokenSeen:
                        self.phase = .finishing
                    }
                }
            }, destination: where_)
            await MainActor.run {
                guard let self = weakSelf.value else { return }
                // A run that has been reset out from under us reports nothing:
                // its phase, its failure and its `running` all belong to a
                // later run now.
                guard gen == self.generation else { return }
                self.running = false
                if self.cancelled { self.phase = .idle; return }
                switch result {
                case .success:
                    self.phase = .done
                    self.onStored?()
                case .failure(let f):
                    self.lastFailure = f.message
                    self.lastFailureMinted = f.minted
                    self.phase = .failed(f.message, minted: f.minted)
                }
            }
        }
    }

    /// The code from the browser page, typed into the CLI. Never logged.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case .code = phase else { return }
        if rehearsal {
            phase = .finishing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.phase == .finishing else { return }
                self.phase = .done
                self.onStored?()
            }
            return
        }
        phase = .approving
        ClaudeSignIn.send(code: trimmed)
    }

    /// Stop the CLI (its whole process group) and go back to idle. Safe
    /// when nothing is running: then it just resets a finished sheet.
    ///
    /// It touches the process-wide `ClaudeSignIn.current` **only when this
    /// flow is the one running**, so a second flow's cancel can never reach
    /// the onboarding window's sign-in.
    func cancel() {
        if running {
            cancelled = true
            ClaudeSignIn.cancel()
        } else {
            phase = .idle
        }
    }

    /// Back to `.idle` unconditionally, stopping anything this flow started.
    /// `cancel()` cannot do this: it leaves `running` true for the three
    /// seconds the child gets between SIGTERM and SIGKILL, and a sheet shown
    /// in that window finds a phase its `.onAppear` will not restart.
    func reset() {
        if running {
            cancelled = true
            ClaudeSignIn.cancel()
        }
        generation += 1
        running = false
        lastFailure = nil
        lastFailureMinted = false
        phase = .idle
    }
}

private final class WeakBox: @unchecked Sendable {
    weak var value: ClaudeSignInFlow?
    init(_ v: ClaudeSignInFlow) { value = v }
}

enum ClaudeSignIn {
    struct Failure: Error {
        let message: String
        /// **A real, year-long token was minted at Anthropic before this
        /// failed.** Everything after `state.setToken` is post-mint: the 401
        /// check, a missing script, a missing interpreter, a refused body, a
        /// publish that did not land. In all of them the transcript is gone,
        /// the only copy of the token is dropped by `clearToken()`, and
        /// nothing on this Mac or anywhere else can name, reach or withhold
        /// it — it stays valid until it expires.
        ///
        /// This is why the flag exists rather than a nicer message: the old
        /// post-mint step was one keychain write that essentially cannot
        /// fail, and the away path replaced it with a subprocess, a seal, a
        /// disk write and a sync. "That didn't work" must not look the same
        /// as "nothing was created", and "Try again" must not read as free.
        var minted = false
    }

    /// Where a captured token goes. There are exactly two, and they are never
    /// the same item: this Mac's brain reads one keychain entry, the away
    /// machine reads a sealed document, and each was minted by its own
    /// sign-in (`AwayBrainSetup.signInDestination` carries the argument).
    enum Destination {
        /// This Mac's brain: keychain `moe-child-oauth`/`moe`, then
        /// configure-hermes.py and the gateway restart.
        case thisMac
        /// Somewhere else. `deliver` gets the token and this Mac keeps
        /// nothing — no keychain write, no ~/.hermes, no restart. It runs on
        /// the sign-in's own (background) thread and may block; `name` is for
        /// the log, and must never be built from anything secret.
        case elsewhere(name: String, deliver: (String) -> Result<Void, Failure>)
    }

    static let tokenPattern = "sk-ant-oat01-[A-Za-z0-9_-]+"
    /// A real token is 108 characters. One wrapped by an 80-column terminal
    /// arrives as 79 and then fails every turn with "401 OAuth access token
    /// is invalid" — so anything short is a capture problem, never a token.
    static let minTokenLength = 100

    enum Event {
        case url(URL)
        case codeNeeded
        case codeRejected
        case tokenSeen
    }

    /// Overall budget for the user to approve in the browser.
    static let budget: TimeInterval = 300
    /// After the token has been seen, how long the CLI gets to wrap up on
    /// its own (it may wait for a keypress) before it is stopped.
    static let wrapUpGrace: TimeInterval = 5
    /// After SIGTERM, how long before SIGKILL.
    static let killGrace: TimeInterval = 3
    /// No output for this long after the URL, no token, and the CLI's last
    /// line asks for a keypress ("Press Enter to continue"): one Enter, once
    /// per prompt. Never into the code prompt — that line doesn't ask for one.
    static let idleNudge: TimeInterval = 2

    /// Hosts the approval page may be on. Anything else the CLI prints
    /// (a docs link, say) is not opened.
    static let allowedHosts = ["claude.ai", "anthropic.com"]

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Debug-only override; release searches PATH and the usual places.
    static func claudePath() -> String? {
        if let env = TestHooks.env("MOE_CLAUDE_BIN") { return env }
        // The process's own PATH first, then where the installers put it.
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let p = d + "/claude"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Everything the terminal would have printed, minus ANSI and CRs.
    /// Styling (SGR, `…m`) vanishes; every other CSI sequence — cursor
    /// moves, erases — becomes a line break. Ink draws the line after the
    /// token by moving the cursor, not by printing "\n", and with the
    /// escape simply dropped the token came out as "<token>Store" from
    /// "Store this token securely" (2026-09-02, 113 characters).
    static func stripANSI(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*m", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-ln-z]", with: "\n", options: .regularExpression)
        return out.replacingOccurrences(of: "\r", with: "")
    }

    /// The first https URL on an allowed host.
    static func firstApprovedURL(in text: String) -> URL? {
        var search = text.startIndex
        while let r = text.range(of: "https://[^\\s\"'<>]+", options: .regularExpression, range: search..<text.endIndex) {
            var s = String(text[r])
            while let last = s.last, ".,)]".contains(last) { s.removeLast() }
            if let url = URL(string: s), isAllowed(url) { return url }
            search = r.upperBound
        }
        return nil
    }

    /// A complete token: followed by something that isn't part of one, or
    /// `final` (the process has exited, so nothing more is coming).
    static func token(in text: String, final: Bool) -> String? {
        let pattern = final ? tokenPattern : tokenPattern + "(?=[^A-Za-z0-9_-])"
        var search = text.startIndex
        while let r = text.range(of: pattern, options: .regularExpression, range: search..<text.endIndex) {
            let t = String(text[r])
            if t.count >= minTokenLength { return t }
            search = r.upperBound
        }
        return nil
    }

    /// The longest token-shaped run in the transcript, for the log when
    /// nothing long enough was found.
    static func longestTokenRun(in text: String) -> Int {
        var best = 0, search = text.startIndex
        while let r = text.range(of: tokenPattern, options: .regularExpression, range: search..<text.endIndex) {
            best = max(best, text.distance(from: r.lowerBound, to: r.upperBound))
            search = r.upperBound
        }
        return best
    }

    // MARK: - Rejected token marker

    /// ~/.moe/hermes/claude-signin-rejected: written when a turn fails with
    /// "OAuth access token is invalid", removed when a new token is stored.
    /// configure-hermes.py --show reads it, so the Brain pane says the
    /// sign-in was rejected instead of "signed in" for a token Anthropic
    /// won't take (a keychain item is presence, not validity).
    static var rejectedMarker: URL { Paths.home.appendingPathComponent("hermes/claude-signin-rejected") }

    static func markRejected() {
        let url = rejectedMarker
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        Log.write("sign-in: Claude rejected the stored token; the Brain pane will ask for a new sign-in")
    }

    static func clearRejected() { try? FileManager.default.removeItem(at: rejectedMarker) }

    /// The captured token against the profile endpoint, before it is
    /// stored. Measured 2026-09-02: a good setup-token (inference scope
    /// only) answers 403 there, a bad one 401. So only a definite 401
    /// refuses the sign-in; no answer, or anything else, is not evidence
    /// against the token.
    static func rejected(token: String) -> Bool {
        if TestHooks.env("MOE_CLAUDE_BIN") != nil { return false }   // fakes never reach the network
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        Log.write("sign-in: profile check answered HTTP \(status) (0 = no answer; 403 is a good token)")
        return status == 401
    }

    /// The CLI is sitting on its "Paste code here" prompt.
    static func wantsCode(_ tail: String) -> Bool {
        tail.range(of: "paste code here", options: .caseInsensitive) != nil
            || tail.range(of: "paste the code", options: .caseInsensitive) != nil
    }

    /// The last non-empty line asks for a keypress.
    static func wantsKeypress(_ text: String) -> Bool {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let l = line.lowercased()
        return l.contains("press enter") || l.contains("press any key") || l.contains("to continue")
    }

    // The one run at a time, so the sheet can type a code into it or stop it.
    private static let currentLock = NSLock()
    private static var current: PtyProcess?

    /// Type the browser page's code into the running CLI.
    static func send(code: String) {
        currentLock.lock(); let p = current; let s = currentState; currentLock.unlock()
        guard let p else { return }
        // The next "Invalid code" is about this code, not an earlier one.
        s?.markCodeSent()
        p.write(code + "\n")
    }

    /// Stop the running sign-in, if any (Cancel, window close, app quit).
    static func cancel() {
        currentLock.lock(); let p = current; let s = currentState; currentLock.unlock()
        guard let p else { return }
        s?.markCancelled()
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { p.killNow() }
    }

    private static var currentState: RunState?

    /// Blocking. `event(.url)` is delivered at most once, `.tokenSeen` when
    /// the token has been captured (before it is stored). `configure` applies
    /// to `.thisMac` only — `.elsewhere` never configures anything here.
    static func run(event: @escaping (Event) -> Void, configure: Bool = true,
                    destination: Destination = .thisMac) -> Result<Void, Failure> {
        guard let claude = claudePath() else {
            return .failure(.init(message: "Claude Code isn't installed on this Mac yet."))
        }
        var env = BrainPrompt.childEnvironment()
        env["TERM"] = "xterm-256color"
        env["CI"] = nil
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        let child: PtyProcess
        do {
            child = try PtyProcess(path: claude, arguments: ["setup-token"], environment: env)
        } catch let e as PtyProcess.SpawnError {
            return .failure(.init(message: e.message))
        } catch {
            return .failure(.init(message: "Couldn't start the sign-in."))
        }
        Log.write("sign-in: started (pid \(child.pid))")

        let state = RunState()
        currentLock.lock(); current = child; currentState = state; currentLock.unlock()
        // `current === child`, not an unconditional clear. `reset()` can start
        // a second run while the first is still inside its three-second
        // SIGTERM→SIGKILL window; the dying one used to null the slot on its
        // way out and take the live run's code field and Cancel with it.
        defer {
            currentLock.lock()
            if current === child { current = nil; currentState = nil }
            currentLock.unlock()
        }

        let start = Date()
        // Watchdog: overall budget, the post-token grace, TERM→KILL, the
        // idle nudge.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 0.5, repeating: 0.5)
        watchdog.setEventHandler {
            let now = Date()
            let s = state.snapshot()
            if let t = s.terminatedAt {
                if now.timeIntervalSince(t) > killGrace { child.killNow() }
            } else if s.gotToken {
                if now.timeIntervalSince(s.tokenAt) > wrapUpGrace {
                    Log.write("sign-in: the sign-in tool didn't exit on its own — stopping it")
                    state.markTerminated()
                    child.terminate()
                }
            } else if now.timeIntervalSince(start) > budget {
                Log.write("sign-in: no approval after \(Int(budget))s — giving up")
                state.markTimedOut()
                state.markTerminated()
                child.terminate()
            } else if !s.nudged, s.urlSeen, now.timeIntervalSince(s.lastOutput) > idleNudge,
                      wantsKeypress(state.text) {
                state.markNudged()
                child.write("\n")
            }
        }
        watchdog.resume()

        child.read { chunk in
            state.append(chunk)
            let text = state.text
            if !state.urlSeen, let url = firstApprovedURL(in: text) {
                state.markURLSeen()
                Log.write("sign-in: opening \(url.host ?? "the approval page") in the browser")
                event(.url(url))
            }
            if !state.gotToken, let t = token(in: text, final: false) {
                state.setToken(t)       // drops the transcript
                Log.write("sign-in: token captured")
                event(.tokenSeen)
                // Some versions wait for a keypress after showing it.
                child.write("\n")
                return
            }
            if state.urlSeen, !state.gotToken {
                if !state.needsCode, wantsCode(text) {
                    state.markNeedsCode()
                    Log.write("sign-in: the sign-in tool asks for the code from the page")
                    event(.codeNeeded)
                } else if state.codeSent, state.textSinceCode.range(of: "invalid code", options: .caseInsensitive) != nil {
                    state.markCodeRejected()
                    Log.write("sign-in: code rejected")
                    event(.codeRejected)
                }
            }
        }
        var code = child.wait()
        watchdog.cancel()
        if !state.gotToken, let t = token(in: state.text, final: true) {
            state.setToken(t)
            Log.write("sign-in: token captured")
            event(.tokenSeen)
        }
        if state.terminated { code = 0 }
        guard let tok = state.token else {
            if state.cancelled {
                return .failure(.init(message: "Cancelled."))
            }
            if state.timedOut {
                return .failure(.init(message: "That took too long. Approve the sign-in in your browser within a few minutes."))
            }
            let plain = state.text
            if plain.range(of: "does not permit", options: .caseInsensitive) != nil {
                return .failure(.init(message: "Your Claude account doesn't allow this kind of sign-in. Ask whoever manages it, or use a different account."))
            }
            if plain.localizedCaseInsensitiveContains("invalid code") {
                return .failure(.init(message: "That code didn't work. Copy the whole code from the page and try again."))
            }
            if plain.localizedCaseInsensitiveContains("not logged in") || plain.localizedCaseInsensitiveContains("/login") {
                return .failure(.init(message: "Claude Code isn't signed in on this Mac yet, so it couldn't hand over a sign-in."))
            }
            let run = longestTokenRun(in: plain)
            if run > 0 {
                Log.write("sign-in: the token came through cut short (\(run) characters; \(minTokenLength)+ expected)")
                return .failure(.init(message: "The sign-in tool printed the token cut short. Try again."))
            }
            Log.write("sign-in: no token (exit \(code))")
            return .failure(.init(message: "The sign-in didn't finish."))
        }
        defer { state.clearToken() }
        if rejected(token: tok) {
            Log.write("sign-in: Anthropic answered 401 to the captured token (\(tok.count) characters) — not stored; it cannot be withheld")
            return .failure(.init(message: "Claude didn't accept the token the sign-in produced.", minted: true))
        }
        if case .elsewhere(let name, let deliver) = destination {
            // Nothing on this Mac is touched: not the keychain item the brain
            // reads, not ~/.hermes, not the rejected marker (which is about
            // *this* Mac's token and would be a lie about someone else's).
            // This Mac is the courier, not a second holder.
            Log.write("sign-in: token captured for \(name) — not stored on this Mac")
            switch deliver(tok) {
            case .success:
                Log.write("sign-in: handed to \(name) (\(tok.count) characters)")
                return .success(())
            case .failure(let f):
                // Post-mint. `deliver` reports its own reason; what it cannot
                // know is that a credential now exists that nobody can reach.
                Log.write("sign-in: a token was minted and could not be delivered to \(name) — it cannot be withheld")
                return .failure(.init(message: f.message, minted: true))
            }
        }
        switch store(token: tok) {
        case .success:
            Log.write("sign-in: stored (\(tok.count) characters)")
            clearRejected()
            // ~/.hermes is set up here, not at the next launch, so the
            // gateway restart that follows finds it ready. Its `relayChanged`
            // is deliberately dropped for that reason: the restart is already
            // coming, and the gateway it starts reads the file we just wrote.
            if configure, HermesConfigure.wanted { HermesConfigure.runAndLog() }
            return .success(())
        case .failure(let f):
            return .failure(f)
        }
    }

    /// Delete-then-add with the access list the reader expects — exactly
    /// what scripts/hermes-signin.sh does, and for the same reasons.
    static func store(token: String) -> Result<Void, Failure> {
        let service = TestHooks.env("MOE_CHILD_TOKEN_SERVICE") ?? "moe-child-oauth"
        let bin = TestHooks.env("MOE_SECURITY_BIN") ?? "/usr/bin/security"
        _ = security(bin, ["delete-generic-password", "-a", "moe", "-s", service])
        let rc = security(bin, ["add-generic-password", "-a", "moe", "-s", service,  // erase-allowlist: moe-child-oauth
                                "-T", "/usr/bin/security", "-w", token])
        guard rc == 0 else {
            return .failure(.init(message: "Couldn't save the sign-in on this Mac.", minted: true))
        }
        return .success(())
    }

    private static func security(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Shared between the reader thread, the watchdog and the sheet.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = Data()
        private var _text = ""
        private var _token: String?
        private var _urlSeen = false
        private var _needsCode = false
        private var _codeSent = false
        private var codeMark = 0
        private var tokenAt = Date.distantPast
        private var lastOutput = Date()
        private var nudged = false
        private var _timedOut = false
        private var _terminatedAt: Date?
        private var _cancelled = false

        struct Snapshot {
            let gotToken: Bool, tokenAt: Date, urlSeen: Bool, needsCode: Bool
            let lastOutput: Date, nudged: Bool, terminatedAt: Date?
        }

        var token: String? { lock.lock(); defer { lock.unlock() }; return _token }
        var gotToken: Bool { lock.lock(); defer { lock.unlock() }; return _token != nil }
        var text: String { lock.lock(); defer { lock.unlock() }; return _text }
        var urlSeen: Bool { lock.lock(); defer { lock.unlock() }; return _urlSeen }
        var needsCode: Bool { lock.lock(); defer { lock.unlock() }; return _needsCode }
        var codeSent: Bool { lock.lock(); defer { lock.unlock() }; return _codeSent }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
        var terminated: Bool { lock.lock(); defer { lock.unlock() }; return _terminatedAt != nil }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        /// Output since the last code was typed.
        var textSinceCode: String {
            lock.lock(); defer { lock.unlock() }
            return String(_text.dropFirst(min(codeMark, _text.count)))
        }

        func append(_ d: Data) {
            lock.lock(); defer { lock.unlock() }
            raw.append(d)
            if raw.count > 256 * 1024 { raw = raw.suffix(128 * 1024); codeMark = 0 }
            _text = ClaudeSignIn.stripANSI(String(decoding: raw, as: UTF8.self))
            lastOutput = Date()
            nudged = false   // a new prompt may earn one more Enter
        }
        /// Keeps the token, drops the transcript that carried it.
        func setToken(_ t: String) {
            lock.lock(); _token = t; tokenAt = Date(); raw = Data(); _text = ""; lock.unlock()
        }
        func clearToken() { lock.lock(); _token = nil; lock.unlock() }
        func markURLSeen() { lock.lock(); _urlSeen = true; lock.unlock() }
        func markNeedsCode() { lock.lock(); _needsCode = true; lock.unlock() }
        func markCodeSent() { lock.lock(); _codeSent = true; codeMark = _text.count; lock.unlock() }
        func markCodeRejected() { lock.lock(); _codeSent = false; lock.unlock() }
        func markNudged() { lock.lock(); nudged = true; lock.unlock() }
        func markTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
        func markTerminated() { lock.lock(); if _terminatedAt == nil { _terminatedAt = Date() }; lock.unlock() }
        func markCancelled() { lock.lock(); _cancelled = true; if _terminatedAt == nil { _terminatedAt = Date() }; lock.unlock() }
        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return Snapshot(gotToken: _token != nil, tokenAt: tokenAt, urlSeen: _urlSeen, needsCode: _needsCode,
                            lastOutput: lastOutput, nudged: nudged, terminatedAt: _terminatedAt)
        }
    }

    /// `Moe --signin-test [away]`: the whole flow, headless, for
    /// scripts/test-signin.sh. Prints the URL it would have opened and
    /// "stored" (this Mac) or "sent" (the away machine); never the token.
    /// Refuses to run without MOE_CLAUDE_BIN (debug builds only), so it can
    /// never reach the real CLI. MOE_SIGNIN_TEST_CODE is typed in when the
    /// fake asks for a code.
    ///
    /// `destination` is the *same* value the sheets build — the away one
    /// comes from `AwayBrainSetup.signInDestination` — because a headless
    /// test of a destination this file invented for itself would prove
    /// nothing about the one a person presses.
    static func runHeadless(destination: Destination = .thisMac) -> Int32 {
        let err = FileHandle.standardError
        guard TestHooks.env("MOE_CLAUDE_BIN") != nil else {
            err.write(Data("error: --signin-test needs MOE_CLAUDE_BIN (a fake claude); refusing to run the real one\n".utf8))
            return 2
        }
        let code = TestHooks.env("MOE_SIGNIN_TEST_CODE")
        var opened: URL?
        let result = run(event: { e in
            switch e {
            case .url(let u): opened = u
            case .codeNeeded:
                err.write(Data("code: asked\n".utf8))
                if let code { send(code: code) }
            case .codeRejected: err.write(Data("code: rejected\n".utf8))
            case .tokenSeen: break
            }
        }, configure: false, destination: destination)
        if let opened { err.write(Data("url: \(opened.absoluteString)\n".utf8)) }
        switch result {
        case .success:
            if case .elsewhere = destination { print("sent") } else { print("stored") }
            Log.flush()
            return 0
        case .failure(let f):
            // Whether a real credential was created before this failed is the
            // one fact about a failure that costs something, and it has to be
            // observable to a test — a sentence in a SwiftUI subtitle is not.
            if f.minted { err.write(Data("minted: yes\n".utf8)) }
            err.write(Data("error: \(f.message)\n".utf8))
            Log.flush()
            return 1
        }
    }
}

// MARK: - The sheet

/// "Sign in with your Claude account" → "Approve in your browser" →
/// (maybe) "Paste the code" → "Done".
struct ClaudeSignInSheet: View {
    @ObservedObject var flow: ClaudeSignInFlow
    /// Called when the sheet is dismissed; `signedIn` says how. The flow is
    /// stopped (or reset) before this is called.
    var onClose: (_ signedIn: Bool) -> Void
    /// The last two phases' wording. The default is this Mac's — the token
    /// was just saved here and the brain is restarting. The Away brain sheet
    /// hands in its own, because on that path nothing on this Mac changed and
    /// "Moe is getting ready to think" would be the sheet claiming a place
    /// the token never went.
    var finishingLine = "Saving your sign-in and getting Moe ready…"
    var doneLine = "Signed in. Moe is getting ready to think."

    /// Said whenever a token was minted and then not delivered. It names the
    /// thing the person cannot otherwise know: a credential exists, Moe has
    /// already destroyed its only copy, and no Remove anywhere reaches it.
    static let orphanNote = "A sign-in was created at Anthropic before this failed. Moe no longer has it and can't take it back — it stays valid until it expires or you sign out of Claude Code on this Mac. Signing in again makes another one."

    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(title)
                .font(Theme.Typo.heading(24))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(Theme.Typo.prose(15))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if case .code = flow.phase {
                TextField("Paste the code here", text: $code)
                    .textFieldStyle(.plain)
                    .font(Theme.Typo.ui(13))
                    .padding(.horizontal, Theme.Space.base)
                    .padding(.vertical, Theme.Space.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.sunk)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Theme.ruleStrong, lineWidth: Theme.Stroke.hair)
                    )
                    .onSubmit { submit() }
            }
            if flow.phase == .approving, let url = flow.lastURL {
                SignInLinkBlock(url: url, open: { flow.openURL(url) })
            }
            HStack(spacing: Theme.Space.cosy) {
                if flow.phase == .approving || flow.phase == .finishing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                buttons
            }
            .padding(.top, Theme.Space.small)
        }
        .padding(Theme.Space.section)
        .frame(width: 420)
        .background(Theme.raised)
        .onAppear { if flow.phase == .idle { flow.begin() } }
    }

    /// The quiet button: text only, like NoticeSheet's dismiss.
    private func quiet(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typo.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        flow.submit(code: code)
        code = ""
    }

    private func close(signedIn: Bool) {
        flow.cancel()
        onClose(signedIn)
    }

    private var title: String {
        switch flow.phase {
        case .idle, .approving: return "Sign in with your Claude account"
        case .code:             return "Paste the code"
        case .finishing:        return "Almost there"
        case .done:             return "Done"
        case .failed(_, let minted):
            return minted ? "That didn't work, and a sign-in was created" : "That didn't work"
        }
    }

    private var subtitle: String {
        switch flow.phase {
        case .idle:        return "Moe will open a page in your browser."
        case .approving:   return "Approve in your browser, then come back here."
        case .code(let rejected):
            return rejected
                ? "That code didn't work. Copy the whole code from the page and paste it again."
                : "The page in your browser shows a code. Copy it and paste it here."
        case .finishing:   return finishingLine
        case .done:        return doneLine
        case .failed(let m, let minted):
            return minted ? m + " " + ClaudeSignInSheet.orphanNote : m
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch flow.phase {
        case .idle, .approving, .finishing:
            quiet("Cancel") { close(signedIn: false) }.keyboardShortcut(.cancelAction)
        case .code:
            quiet("Cancel") { close(signedIn: false) }.keyboardShortcut(.cancelAction)
            PillButton(title: "Continue") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        case .done:
            PillButton(title: "Done") { close(signedIn: true) }.keyboardShortcut(.defaultAction)
        case .failed(_, let minted):
            quiet("Not now") { close(signedIn: false) }.keyboardShortcut(.cancelAction)
            // **Not "Try again" after a mint.** Retrying is not free there: it
            // asks Anthropic for another year-long token and leaves the first
            // one exactly where it is. The label has to cost what the act
            // costs.
            PillButton(title: minted ? "Sign in again anyway" : "Try again") { flow.begin() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
