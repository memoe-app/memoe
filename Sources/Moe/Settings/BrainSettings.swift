import AppKit
import MoeBrain
import MoeDesign
import SwiftUI

// The Brain pane: which provider and model Hermes runs, and whatever that
// provider needs — a sign-in, a key, a local server's address.
//
// Two layers keep it honest. ~/.hermes is written only by
// configure-hermes.py (`--set-provider` … `--set-key NAME`, key on stdin),
// which validates the result with Hermes's own loader before touching a
// file; and every request Moe sends names the provider and model anyway
// (`BrainSelection`), so a turn can never run on a model other than the one
// shown here. See BrainProviderKind for what each provider is.

/// What `configure-hermes.py --show` reports: the state of ~/.hermes, with
/// key *names* and presence only.
struct BrainStatus: Decodable {
    var provider = ""
    var model = ""
    var base_url = ""
    var reasoning_effort = ""
    var keys: [String: Bool] = [:]
    var codex_signed_in = false
    var claude_signed_in = false
    /// A stored token Anthropic answered 401 to; cleared by a new sign-in.
    var claude_signin_rejected = false
}

/// The pane's side of configure-hermes.py, plus the post-apply probe.
/// Everything here blocks on a subprocess or the network; call it off the
/// main thread.
enum BrainSetup {

    /// ~/.moe/hermes/configure-hermes.py (installed), then the app's own
    /// copy, then the checkout. Without this script the Brain pane cannot
    /// choose a provider or store a key at all, so the middle candidate is
    /// what keeps a home whose payload copy failed from being inert.
    static func scriptPath() -> String? {
        // Debug-only, for scripts/test-hermes-supervisor.sh: point the whole
        // configure step at a stand-in that prints what a real run would, so
        // Moe's reading of it can be exercised against a real gateway instead
        // of asserted from the source. `TestHooks.env` is compiled out of a
        // release build, so this candidate cannot exist in a shipped Moe.
        if let stub = TestHooks.env("MOE_HERMES_CONFIGURE_SCRIPT") { return stub }
        var candidates = [Paths.home.appendingPathComponent("hermes/configure-hermes.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes/configure-hermes.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes/configure-hermes.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// **The one Python Moe runs anything with**: the interpreter that ships
    /// with it, in the thinking part's own environment. Debug builds honour
    /// `MOE_HERMES_PYTHON` so a test can point it elsewhere.
    ///
    /// Never the system one. On a Mac without Apple's developer tools — which
    /// is most people's — the `python3` in `/usr/bin` is not Python: it is a
    /// stub that puts up "install the command line developer tools?" and
    /// exits. Ten readers used to launch it, so opening the Memory page drew
    /// that dialog and then "Nothing about you yet" over a full memory.
    ///
    /// When Moe's own interpreter is missing (an install that has not
    /// finished, or a broken one), the stdlib-only readers — usage, history,
    /// activity — were deliberately kept working so a Mac could still be told
    /// what happened before it broke. That survives where it is safe: a
    /// *real* interpreter inside the developer tools, by its full path, which
    /// exists only when the tools do and so can never be the stub. With
    /// neither, the answer is Moe's own path: launching it fails at once and
    /// every caller says it could not look.
    static func python() -> String {
        if let env = TestHooks.env("MOE_HERMES_PYTHON") { return env }
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: bundledPython) { return bundledPython }
        return developerPythons.first { fm.isExecutableFile(atPath: $0) } ?? bundledPython
    }

    /// Laid down from the seed inside the app (`HermesSeed`).
    static var bundledPython: String {
        NSHomeDirectory() + "/.hermes/hermes-agent/.venv/bin/python"
    }

    /// `path` with Moe's own interpreter in front of it, so that a bare
    /// `python3` — a helper's `#!/usr/bin/env python3` line, or the word in
    /// one of its shell scripts — is the same Python `python()` names.
    ///
    /// Every helper Moe starts by its own first line resolved `python3`
    /// through a PATH that began `~/.local/bin:/opt/homebrew/bin:
    /// /usr/local/bin`, which is whatever Python that Mac happens to have. On
    /// 2026-11-11 a python.org Python 3.15 arrived in `/usr/local/bin` on the
    /// owner's Mac. That installer ships OpenSSL with an **empty** trust
    /// store until its "Install Certificates" step is run (measured: `ssl.
    /// get_default_verify_paths().cafile` is None), so every HTTPS call any
    /// connector made failed with CERTIFICATE_VERIFY_FAILED — Gmail's "Add
    /// another" said "could not start the sign-in", and Disconnect could not
    /// reach Composio either. On a Mac without the developer tools the same
    /// lookup ends at the `/usr/bin/python3` stub instead.
    ///
    /// The directory is the thinking part's environment (`.venv/bin`), not
    /// the interpreter behind it: a symlink to that interpreter from anywhere
    /// else starts outside the environment (measured — no PyYAML), and
    /// configure-hermes.py's own re-exec cannot notice, because both resolve
    /// to one file.
    ///
    /// Added only when `<dir>/python3` can be run. A directory that is not
    /// there is not put on the PATH to look right: that is how the gateway
    /// carried `~/.hermes/python/python/bin` for ten weeks after the
    /// interpreter moved.
    static func pathWithMoePython(_ path: String, python: String = bundledPython) -> String {
        let dir = (python as NSString).deletingLastPathComponent
        guard !dir.isEmpty,
              FileManager.default.isExecutableFile(atPath: dir + "/python3") else { return path }
        let rest = path.split(separator: ":", omittingEmptySubsequences: true).map(String.init).filter { $0 != dir }
        return ([dir] + rest).joined(separator: ":")
    }

    /// Real interpreters, present only when developer tools are installed.
    static let developerPythons = [
        "/Library/Developer/CommandLineTools/usr/bin/python3",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
    ]

    /// `message` is shown on a settings pane as it stands, so it is always
    /// one of `Said`'s sentences — never the script's own output, which goes
    /// to Moe's log (`report`).
    struct Failure: Error { let message: String }

    /// What a failed run is called on screen.
    ///
    /// The pane used to print the last four lines the script wrote, joined
    /// with spaces, or "configure-hermes.py exited 1." Those are written for
    /// whoever maintains the script — flag names, `config.yaml does not
    /// parse`, a traceback's tail — and a person choosing a model can act on
    /// none of it. They get what happened and what to do; the log gets the
    /// rest, whole.
    enum Said {
        static let missing = "A part of Moe that this needs is missing on this Mac. Quit Memoe and open it again; if this stays, download Memoe again from memoe.app."
        static let wouldNotStart = "Moe couldn't start the part of itself that changes this. Quit Memoe and open it again."
        static let couldNotRead = "Moe couldn't read how its thinking part is set up. Quit Memoe and open it again; if this stays, choose Set it up."
        static let keyNotSaved = "Moe couldn't save that key, and nothing was changed. Check it is the whole key, with nothing before or after it, and try again."
        static let profileNotUsed = "Moe couldn't switch to that browser profile, and nothing was changed. Pick another one."
        static let notSaved = "Moe couldn't save that, and nothing was changed. Try again; if it keeps happening, quit Memoe and open it again."

        /// By what was asked for. The flags are Moe's own (`apply`,
        /// `setWorkLimit`, …), so this reads the request, not the output.
        static func failure(of args: [String]) -> String {
            if args.contains("--set-key") { return keyNotSaved }
            if args.contains("--set-browse-as") { return profileNotUsed }
            if args.contains(where: { $0.hasPrefix("--set-") || $0.hasPrefix("--install-") }) { return notSaved }
            return couldNotRead
        }
    }

    /// The detail, for whoever reads the log. Flags only: a value can be a
    /// model name or a URL, and none of it is needed to find the run.
    private static func report(_ args: [String], _ what: String) {
        let flags = args.filter { $0.hasPrefix("--") }.joined(separator: " ")
        Log.write("brain settings: configure-hermes.py \(flags): \(what)")
    }

    /// Run the script with `args`; `secret` (if any) goes on stdin — never
    /// argv, which every local user can read with `ps`.
    static func run(_ args: [String], secret: String? = nil) -> Result<String, Failure> {
        guard let script = scriptPath() else {
            report(args, "not found in \(Paths.home.path)/hermes or in the app")
            return .failure(.init(message: Said.missing))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python())
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = secret == nil ? FileHandle.nullDevice : input
        do { try p.run() } catch {
            report(args, "could not be started with \(python()): \(error.localizedDescription)")
            return .failure(.init(message: Said.wouldNotStart))
        }
        if let secret {
            try? input.fileHandleForWriting.write(contentsOf: Data((secret + "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
        // Read both pipes before waiting, or a chatty script fills one and hangs.
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let why = (stderr + "\n" + stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            report(args, "exited \(p.terminationStatus)" + (why.isEmpty ? "" : "\n" + why))
            return .failure(.init(message: Said.failure(of: args)))
        }
        return .success(stdout)
    }

    static func show() -> Result<BrainStatus, Failure> {
        switch run(["--show"]) {
        case .failure(let f): return .failure(f)
        case .success(let text):
            guard let line = text.split(whereSeparator: \.isNewline).last,
                  let status = try? JSONDecoder().decode(BrainStatus.self, from: Data(line.utf8))
            else {
                report(["--show"], "exited 0 with no answer: \(text.suffix(400))")
                return .failure(.init(message: Said.couldNotRead))
            }
            return .success(status)
        }
    }

    /// The models this ChatGPT account can actually use, from OpenAI's own
    /// per-account list (`configure-hermes.py --codex-models`). Nil when the
    /// list could not be read — the caller falls back to the curated one
    /// and must not treat that as the account's answer.
    static func codexModels() -> [String]? {
        guard case .success(let text) = run(["--codex-models"]),
              let line = text.split(whereSeparator: \.isNewline).last,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let models = obj["models"] as? [String], !models.isEmpty
        else { return nil }
        return models
    }

    /// The model to start a newly chosen provider on. For ChatGPT, one the
    /// account actually offers: the fixed default is only a guess at a plan.
    static func startingModel(for kind: BrainProviderKind) -> String {
        guard kind == .codex, let live = codexModels() else { return kind.defaultModel }
        return live.contains(kind.defaultModel) ? kind.defaultModel : live[0]
    }

    /// Write the choice into ~/.hermes. `key` is the API key to store under
    /// the provider's env name, or nil to leave credentials alone.
    static func apply(_ selection: BrainSelection, baseURL: String, key: String?) -> Result<String, Failure> {
        var args = ["--set-provider", selection.provider.rawValue, "--set-model", selection.model]
        if selection.provider.usesBaseURL {
            args += ["--set-base-url", baseURL]
        }
        // Always, not only for API transports: configure-hermes.py carries
        // the same level to the Claude Code child as `--effort` on its
        // command line, and clears it for a provider that has no child.
        args += ["--set-reasoning", selection.reasoningEffort]
        var secret: String? = nil
        if let key, !key.isEmpty, let name = selection.provider.keyEnvName {
            args += ["--set-key", name]
            secret = key
        }
        return run(args, secret: secret)
    }

    /// The flag for Settings › Brain › "How long Moe may work on one thing":
    /// minutes in, Hermes's seconds out (`claude_code.turn_timeout`).
    static func workLimitArguments(minutes: Int) -> [String] {
        ["--set-turn-timeout", String(WorkLimit.normalised(minutes) * 60)]
    }

    /// Write the work limit into ~/.hermes. Hermes re-reads config.yaml on
    /// its modification time, so the next turn has it; nothing restarts.
    static func setWorkLimit(minutes: Int) -> Result<String, Failure> {
        run(workLimitArguments(minutes: minutes))
    }

    /// Settings › Permissions › "Browse as": pin Hermes's real-profile copy
    /// to one browser profile (`browser.real_profile_pin`), or "" to follow
    /// whichever the person used last. The script refuses a name that is not
    /// a profile of the default browser, since Hermes fails closed on a
    /// missing pin. Takes effect the next time Moe opens its browser.
    static func browseAsArguments(profileDir: String) -> [String] {
        ["--set-browse-as", profileDir]
    }

    static func setBrowseAs(profileDir: String) -> Result<String, Failure> {
        run(browseAsArguments(profileDir: profileDir))
    }

    /// Ask the service itself, before anything is written.
    ///
    /// `probe` cannot do this job: it goes through Hermes, so it can only
    /// check settings that have already been applied — by which point a
    /// typo in the address has already replaced a working brain. This talks
    /// straight to the address in the field, with the key in the field, and
    /// says what came back.
    ///
    /// `GET /models` first because it costs nothing and most services answer
    /// it; a service that does not gets the smallest completion that can be
    /// asked for. Either one answering means the address and the key are
    /// right, which is the whole question.
    static func testEndpoint(baseURL: String, key: String, model: String) async -> Result<String, Failure> {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
                          .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let models = URL(string: base + "/models") else {
            return .failure(.init(message: "That address isn't a web address Moe can use."))
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        func authorised(_ url: URL, body: Data? = nil) -> URLRequest {
            var r = URLRequest(url: url)
            r.timeoutInterval = 20
            r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if let body {
                r.httpMethod = "POST"
                r.httpBody = body
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return r
        }
        func message(_ data: Data) -> String? {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let e = obj?["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj?["error"] as? String { return m }
            return nil
        }
        func refusal(_ status: Int, _ data: Data) -> Failure {
            let detail = message(data).map { ": " + $0 } ?? "."
            switch status {
            case 401, 403: return .init(message: "The service refused the key\(detail)")
            case 429:      return .init(message: "The service says you are over its limit\(detail)")
            default:       return .init(message: "The service answered \(status)\(detail)")
            }
        }

        do {
            let (data, response) = try await session.data(for: authorised(models))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let ids = ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                if ids.isEmpty { return .success("Answered, and the key works.") }
                if model.isEmpty { return .success("Answered — \(ids.count) models, key accepted.") }
                return ids.contains(model)
                    ? .success("Answered, key accepted, and it has \(model).")
                    : .success("Answered and the key works, but it doesn't list \(model). "
                               + "Check the name — it offers \(ids.prefix(3).joined(separator: ", ")).")
            }
            if status == 401 || status == 403 || status == 429 {
                return .failure(refusal(status, data))
            }
            // No /models here — every service has to answer this one.
            guard !model.isEmpty else {
                return .failure(.init(message: "That address has no model list, so Moe needs a model name to test it with."))
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
            ])
            guard let chat = URL(string: base + "/chat/completions") else {
                return .failure(.init(message: "That address isn't a web address Moe can use."))
            }
            let (d2, r2) = try await session.data(for: authorised(chat, body: body))
            let s2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
            if s2 == 200 { return .success("Answered a real question. The address, the key and \(model) all work.") }
            return .failure(refusal(s2, d2))
        } catch let error as URLError {
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .failure(.init(message: "Nothing answered at that address. Check the host and that it ends in /v1."))
            case .timedOut:
                return .failure(.init(message: "The service didn't answer within twenty seconds."))
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return .failure(.init(message: "Moe couldn't make a secure connection to that address."))
            default:
                return .failure(.init(message: "Couldn't reach that address: \(error.localizedDescription)"))
            }
        } catch {
            return .failure(.init(message: "Couldn't reach that address: \(error.localizedDescription)"))
        }
    }

    /// One tiny turn on a throwaway session, so a wrong model id or a
    /// provider that isn't signed in is a sentence here rather than a
    /// surprise on the first real question. Nil means it answered.
    ///
    /// It is also the fastest route out of a hard failure: somebody told
    /// "your key was turned down" pastes a new one, presses Apply, and this
    /// runs. A probe that answers clears the Settings row on the spot rather
    /// than leaving it up until the next real question — and a probe that
    /// fails the same way writes the row, so the page they are already
    /// looking at says so.
    static func probe(config: Config, brain: BrainSelection) async -> String? {
        let raw = await probeRaw(config: config, brain: brain)
        guard let raw else {
            BrainTrouble.clear()
            return nil
        }
        // Everything below used to hand the provider's own body to the pane:
        // "Error code: 401 - {'error': {'message': 'Incorrect API key
        // provided: sk-proj-…'}}" is what a person saw for a dead key, with
        // a slice of the key still in it. `BrainTrouble` is the same
        // translation the island gets, so the two surfaces cannot drift.
        let verdict = TurnError.personWords(raw, provider: brain.provider)
        if let keep = verdict.keep { BrainTrouble.record(keep, provider: brain.provider) }
        return verdict.words
    }

    /// The probe itself, untranslated — split out so the translation above
    /// has exactly one input and can be tested without a gateway.
    static func probeRaw(config: Config, brain: BrainSelection) async -> String? {
        let endpoint = HermesEndpoint(config: config)
        let session = URLSession(configuration: HermesEndpoint.sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        var req = endpoint.chatRequest(sessionID: UUID().uuidString.lowercased(), sessionKey: "moe-probe",
                                       system: "Answer with one word.", user: "Respond with only the word: ready",
                                       stream: false, brain: brain,
                                       origin: nil)   // a probe, nobody's turn: never live
        req.timeoutInterval = 90
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 200 {
                if let choice = (obj?["choices"] as? [[String: Any]])?.first,
                   let reason = choice["finish_reason"] as? String, reason != "stop", reason != "length" {
                    // Hermes often puts the provider's refusal in the reply
                    // itself ("HTTP 400: … model is not supported …"), and
                    // "Moe couldn't finish the check" hid the one sentence
                    // that said what to change.
                    if let m = (obj?["error"] as? [String: Any])?["message"] as? String { return m }
                    let said = ((choice["message"] as? [String: Any])?["content"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return said.isEmpty ? "Moe couldn't finish the check (it stopped: \(reason))." : said
                }
                return nil
            }
            if let msg = (obj?["error"] as? [String: Any])?["message"] as? String { return msg }
            if status == 401 { return "Moe couldn't unlock its own thinking. Quit Memoe and open it again." }
            return "Something went wrong during the check. Try it again."
        } catch {
            return "Moe couldn't reach the part of itself that thinks. Try again in a moment."
        }
    }
}
