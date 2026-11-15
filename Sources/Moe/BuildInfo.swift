import Foundation
import MoeAudio
import MoeBrain
import MoeComponents

/// `Moe --build-info` — what is actually in this binary, and what is beside it.
///
/// This exists because of a specific pair of mistakes. A turn appeared in
/// `~/.moe/logs/moe.log` with no `ack:` line beside it, and two of us
/// diagnosed it without checking what binary had written the log: one blamed
/// a guard in the Conductor, the other blamed a rule in `InstantAck`. Both
/// were wrong. The build running at the time simply did not contain
/// `InstantAck` — `install.sh` had run `./build.sh >/dev/null`, and the only
/// place the missing piece announced itself was that discarded stdout.
///
/// A log is written by a binary, and a binary is not the working tree. So
/// rather than assert what is compiled in, this **runs** each thing and
/// prints what came back: an ack phrase, a spoken tool step, a real de-click
/// of a synthetic impulse. A feature that is absent cannot produce output,
/// and one that is present cannot fail to.
///
/// Exits non-zero when a model the app expects to carry is not there, so
/// "is this build complete" is one command and an exit code rather than a
/// `strings` incantation.
enum BuildInfo {

    static func run() -> Int32 {
        var problems: [String] = []

        print("Moe " + version() + "  (build " + build() + ")")
        print("  binary   \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        print("  built    \(binaryDate())")
        print("  bundle   \(Bundle.main.bundleURL.path)")
        if Bundle.main.bundleIdentifier == nil {
            print("           — a command-line build, not an app bundle")
        }
        if let currency = currency() { print("  \(currency.text)") }

        // MARK: The voice this build ships with
        print("\nVoice")
        let shipped = TtsEngineKind.shipped
        let shippedVoice = TtsCatalogue.defaultVoice(for: shipped, locale: Config.load().locale)
        print("  default engine   \(shipped.rawValue)  (voice \(shippedVoice))")
        let config = Config.load()
        // Resolve the config the way VoiceEngine does, not the way it reads.
        // A config naming a dropped engine, or a voice that belonged to one,
        // is corrected at load — so printing the raw value here would report a
        // voice the app is not going to use. That is the whole failure this
        // command exists to prevent, and it applied to the command itself.
        let inUse = TtsEngineKind(rawValue: config.ttsEngine) ?? shipped
        let offered = TtsCatalogue.voices(for: inUse, locale: config.locale)
        let inUseDefault = TtsCatalogue.defaultVoice(for: inUse, locale: config.locale)
        let voiceInUse = offered.contains { $0.id == config.ttsVoice }
            ? config.ttsVoice
            : inUseDefault
        var note = ""
        if inUse != shipped || voiceInUse != shippedVoice { note = "   ← changed in Settings" }
        if TtsEngineKind(rawValue: config.ttsEngine) == nil, !config.ttsEngine.isEmpty {
            note = "   ← config says '\(config.ttsEngine)', which this build has no engine for"
        } else if !config.ttsVoice.isEmpty, voiceInUse != config.ttsVoice {
            note = "   ← config says '\(config.ttsVoice)', which \(inUse.displayName) does not have"
        }
        print("  in use now       \(inUse.rawValue)  (voice \(voiceInUse))" + note)
        let tuning = TtsTuning.base(for: inUse)
        print("  tuning           speed \(tuning.speed)"
              + (tuning.steps > 0 ? ", \(tuning.steps) steps" : ""))

        // MARK: The models beside it
        print("\nModels")
        // Which of the three builds this is (docs/SLIM-DOWNLOAD.md §7), read
        // from the same Info.plist key the app acts on. The release scripts
        // read the key; this line is for a person asking an installed app.
        let onDemand = OnDemandModels.mode
        let onDemandFolders = Set(ComponentCatalog.all.map(\.folder))
        print("  on demand        \(onDemand.rawValue)  — \(onDemandMeaning(onDemand))")
        if let dir = Models.bundleModels {
            print("  in this bundle   \(dir.path)")
            for (name, _) in Models.bundled {
                let path = dir.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: path.path) {
                    print("  ✓ \(pad(name, 26))\(size(of: path))")
                    if onDemand == .on, onDemandFolders.contains(name) {
                        problems.append("\(name) is in the bundle of a build that says it is fetched on demand")
                    }
                } else if onDemand == .on, onDemandFolders.contains(name) {
                    // Left out on purpose. Not a fault — and said, so that
                    // "Complete." is never read as "carries all eight".
                    print("  · \(pad(name, 26))on demand — fetched when first needed")
                } else {
                    print("  ✗ \(pad(name, 26))MISSING")
                    problems.append("\(name) is not in the bundle")
                }
            }
        } else {
            print("  none bundled — every model downloads on first use")
            print("  (expected for a `swift build`; a release carries them)")
        }

        // MARK: Prove the features by running them
        print("\nWhat this binary can do")
        report("instant ack",
               InstantAck.phrase(for: "add a cron for the morning digest"),
               &problems)
        report("spoken tool step",
               SpokenStep.phrase(tool: "calendar_pull", label: ""),
               &problems)
        // Off is the shipped state, not a fault: the pass made Kokoro
        // scratchy and the taps it aimed at were a starved player. Reporting
        // "produced nothing" for a feature that is correctly disabled is the
        // same mistake as a gate that passes while seeing nothing, pointed
        // the other way.
        if Declick.passes == 0 {
            print("  · \(pad("de-click", 20))off (MOE_DECLICK=4 to enable)")
        } else {
            report("de-click", declickProof(), &problems)
        }

        if problems.isEmpty {
            print("\nComplete.")
            return 0
        }
        print("\nIncomplete — \(problems.count) problem(s):")
        for p in problems { print("  • \(p)") }
        return 1
    }

    private static func onDemandMeaning(_ mode: OnDemandMode) -> String {
        switch mode {
        case .off:     return "every model is in the app"
        case .prepare: return "every model is in the app; two are copied out at launch, for the slim release"
        case .on:      return "two models are fetched when first needed, not carried"
        }
    }

    // MARK: - Running each thing rather than claiming it

    private static func report(_ label: String, _ result: String?,
                               _ problems: inout [String]) {
        if let result {
            print("  ✓ \(pad(label, 20))\(result)")
        } else {
            print("  ✗ \(pad(label, 20))produced nothing")
            problems.append("\(label) produced nothing — is it in this build?")
        }
    }

    /// De-click a synthetic impulse and say what it did. Nothing about this
    /// is a claim: if the pass is missing or broken, no sample changes and
    /// the line reads as a failure.
    private static func declickProof() -> String? {
        let rate: Double = 24_000
        var samples = (0..<4_800).map {
            0.3 * Float(sin(2 * Double.pi * 200 * Double($0) / rate))
        }
        let spike = 2_400
        samples[spike] = 0.95
        let mended = Declick.repair(&samples, sampleRate: rate)
        guard mended > 0, abs(samples[spike]) < 0.5 else { return nil }
        return "repaired \(mended) sample(s) of \(Declick.passes) pass(es); "
             + "runs up to \(Declick.maxRun)"
    }

    // MARK: - Bits

    private static func version() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "(unversioned)"
    }

    /// The build number, and the commit it was built from.
    ///
    /// The number alone used to be all there was, so two binaries built
    /// from different trees an hour apart were both "16" — which is how a
    /// missing feature stayed invisible while two people diagnosed it from
    /// a log. build.sh stamps `MoeCommit` now, with "+dirty" when the tree
    /// had uncommitted changes, because a build from an edited tree
    /// matches no commit at all.
    private static func build() -> String {
        let number = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
        guard let commit = Bundle.main.infoDictionary?["MoeCommit"] as? String, !commit.isEmpty else {
            return "\(number) (no commit stamped — built before build.sh recorded one)"
        }
        return "\(number), commit \(commit)" + (isUnreleasedBuild(Bundle.main.infoDictionary) ? ", unreleased build" : "")
    }

    // MARK: - Release or not

    /// True when build.sh stamped this bundle as NOT the published build.
    ///
    /// The version cannot say: `0.3.24 (31)` is the release's name, and every
    /// build made from main until the next release carries it too. build.sh
    /// writes `MoeReleaseBuild` — "1" only under publish-release.sh — so the
    /// app can tell a person, and a problem report, which of the two it is.
    /// A bundle with no such key (built before the stamp existed, or run
    /// straight from .build) claims nothing: absent is "cannot tell", and
    /// only an explicit "0" is "unreleased".
    static func isUnreleasedBuild(_ info: [String: Any]?) -> Bool {
        (info?["MoeReleaseBuild"] as? String) == "0"
    }

    /// The line Settings › About shows under the version on a build that is
    /// not the published one, or nil on a release.
    static func unreleasedNote(_ info: [String: Any]?) -> String? {
        guard isUnreleasedBuild(info) else { return nil }
        guard let commit = info?["MoeCommit"] as? String, !commit.isEmpty else {
            return "Not the published release: built on this Mac."
        }
        return "Not the published release: built from commit \(commit)."
    }

    /// "up to date" or "behind by N changes", in words, or nil when the
    /// question cannot be answered honestly.
    ///
    /// The version number cannot answer it and never could: `0.3.10 build
    /// 17` is the RELEASE's name and changes only when a release is cut, so
    /// every one of the dozens of builds compiled between two releases
    /// reports the same pair. That is precisely why one build silently
    /// replacing another was invisible for hours on 2026-09-03, and why the
    /// owner kept asking "is this the latest?" with no way to find out.
    /// Only the commit distinguishes two builds, and only comparing it with
    /// the project's history says whether it is current.
    ///
    /// So this asks the repository, when there is one — a developer's Mac.
    /// It answers nothing on a stranger's machine, where there is no
    /// checkout and the honest answer about freshness comes from the
    /// updater instead. Nil rather than a guess: "I could not tell" and "it
    /// is current" are different answers and only one of them is reassuring.
    ///
    /// `refreshing: true` fetches first, so the comparison is against main
    /// as it is now rather than as this Mac last happened to see it. That
    /// matters more than it sounds: `origin/main` in a checkout is only as
    /// fresh as the last time some session ran `git fetch`, so without it
    /// this can report "up to date" about a main that moved an hour ago —
    /// the confident wrong answer, which is the only kind worth avoiding
    /// here. When the fetch cannot happen the answer says so instead of
    /// quietly falling back, and reads as a lower bound.
    ///
    /// Otherwise read-only and no network. The fetch writes only refs, so
    /// it is safe beside the sessions working in that repository.
    struct Currency {
        /// What to show a person, in words.
        let text: String
        /// True only when this build is provably everything that has landed.
        /// "Could not check" is not true, and gets the same treatment as
        /// behind — string-matching the prose for this was one typo away
        /// from telling someone a stale build was current.
        let current: Bool
    }

    static func currency(refreshing: Bool = false) -> Currency? {
        guard let commit = Bundle.main.infoDictionary?["MoeCommit"] as? String,
              !commit.isEmpty else { return nil }
        if commit.hasSuffix("+dirty") {
            return Currency(text: "from a tree with uncommitted changes — this build matches no commit, and nobody can rebuild it",
                            current: false)
        }
        guard let repo = repoPath() else { return nil }

        // `seconds` is not optional tidiness: a fetch to an unreachable
        // GitHub, or one waiting behind another session's index lock, hangs
        // for as long as the network lets it, and this runs to draw a line
        // of text in a window someone is looking at.
        func git(_ args: [String], seconds: Double = 10) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo] + args
            // Never prompt: a fetch that stops for credentials would wait
            // for an answer nobody can give it from inside a settings pane.
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["GIT_ASKPASS"] = "/usr/bin/true"
            env["SSH_ASKPASS"] = "/usr/bin/true"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            deadline.cancel()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Ask GitHub what main is now, rather than what this Mac remembers.
        // 30 seconds because it is a network round trip, and because being
        // told nothing is better than being told something out of date.
        var stale = false
        if refreshing, git(["fetch", "--quiet", "origin", "main"], seconds: 30) == nil {
            stale = true
        }

        // A commit the checkout has never heard of: built elsewhere, or from
        // work that was never pushed. Saying "behind by 0" there would be a
        // lie of the reassuring kind.
        guard git(["cat-file", "-e", commit + "^{commit}"]) != nil else {
            return Currency(text: "built from \(commit), which this Mac's copy of the project does not have",
                            current: false)
        }
        guard let behind = git(["rev-list", "--count", commit + "..origin/main"]),
              let n = Int(behind) else { return nil }
        // Two different answers when the fetch did not happen, because they
        // are two different facts. "Behind by 4" is still true — it is a
        // floor, and there may be more. "Up to date" is the one that would
        // be a lie, so it does not get said.
        let when = git(["log", "-1", "--format=%cr", "origin/main"]).map { " (newest work seen: \($0))" } ?? ""
        if n == 0 {
            return stale
                ? Currency(text: "up to date with main as this Mac last saw it — could not reach GitHub to check just now\(when)",
                           current: false)
                : Currency(text: "up to date with everything landed", current: true)
        }
        return Currency(text: "behind by \(stale ? "at least " : "")\(n) change\(n == 1 ? "" : "s")\(when)",
                        current: false)
    }

    /// Is this binary Moe Dev rather than the real Moe?
    ///
    /// Read from the bundle identifier, because on macOS that IS the app's
    /// identity — Launch Services treats two bundles sharing one as the same
    /// app, which is the whole reason Moe Dev has its own. The `MoeDev` key
    /// build.sh also stamps is a fallback for a bundle-less `swift build`,
    /// where there is no identifier at all.
    ///
    /// This is not cosmetic. It decides which app the About pane's "Catch
    /// up" button replaces, and getting it wrong means the workbench quietly
    /// installing over the app the owner is using — the exact accident every
    /// guard written on 2026-09-03 exists to stop.
    static var isDev: Bool {
        if let id = Bundle.main.bundleIdentifier { return id.hasSuffix(".dev") }
        // No bundle at all — a bare `swift build` binary — is nobody's
        // release. It used to read as the REAL Moe unless build.sh had
        // stamped `MoeDev`, which a bare binary never has; so every debug
        // binary run from a worktree would have moved the user's Hermes as
        // if it were the shipped app. Bundle-less means workbench.
        if (Bundle.main.infoDictionary?["MoeDev"] as? String) == "0" { return false }
        return true
    }

    /// What this app is called where a person grants it something: the name
    /// on its row in System Settings › Privacy & Security. Hermes words its
    /// fixable errors with it (`HERMES_HOST_APP_NAME`), and the Fix card
    /// names it, so both say the row the person is about to look for.
    static var hostAppName: String { isDev ? "Memoe Dev" : "Memoe" }

    /// The checkout to compare against: this machine's copy of the project,
    /// if it has one. A worktree is fine — they share the same history.
    static func repoPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for candidate in ["\(home)/moe", "\(home)/Developer/moe", "\(home)/src/moe"] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate + "/.git", isDirectory: &isDir) { return candidate }
        }
        return nil
    }

    /// Is this Mac one that *maintains* Moe, or one that just runs it?
    ///
    /// Everything in the About pane except the version — "This Mac — up to
    /// date with everything landed", "Everyone — …", "Catch up…", "Publish a
    /// release…", "Check for Updates…" — is a maintainer's instrument. It is
    /// written in the vocabulary of the project (commits, main, behind by
    /// four changes) and half of it does nothing at all without a checkout.
    /// To a customer it is at best noise and at worst alarming: "behind by
    /// 37 changes" reads as "your app is broken" to someone who has no idea
    /// what main is and nothing they could do about it.
    ///
    /// **The gate is a checkout of the project, not an address.** Scoping
    /// this to an IP would not do what it sounds like it does: this is an
    /// app on somebody's Mac with no server in the loop, so the only address
    /// it could compare is one it asks itself for — which changes with the
    /// café, the VPN and the router's lease, and which every Mac behind one
    /// home router shares. It would hide the controls from the owner on a
    /// train and show them to a houseguest. What actually distinguishes this
    /// Mac is that the project is on it, which is also the thing the buttons
    /// need in order to work at all, so the same fact answers both
    /// questions and cannot drift apart from them.
    ///
    /// `defaults write com.memoe.app MoeMaintainerMac -bool YES` (or NO)
    /// overrides it either way, for a maintainer Mac with no checkout in the
    /// usual places and for showing a customer's-eye view of the pane
    /// without deleting one.
    ///
    /// Sparkle is untouched by this. The updater still starts, still checks
    /// on its own schedule and still offers a new release to everybody — a
    /// hidden button is one less way to ask, never one less update.
    static var isMaintainerMac: Bool {
        if let forced = UserDefaults.standard.object(forKey: "MoeMaintainerMac") as? Bool {
            return forced
        }
        return repoPath() != nil
    }

    private static func binaryDate() -> String {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func size(of dir: URL) -> String {
        guard let e = FileManager.default.enumerator(at: dir,
                includingPropertiesForKeys: [.fileSizeKey]) else { return "" }
        var bytes = 0
        for case let url as URL in e {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return bytes > 0 ? String(format: "%.0f MB", Double(bytes) / 1_048_576) : ""
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }
}
