import Foundation

/// Lays the `~/.moe` payload down from inside the app bundle.
///
/// Everything Moe needs on disk that is not the binary — the connectors and
/// their manifests, the tools the model shells out to, `lib/`, `prompts/`,
/// `learn/`, the Hermes glue with its plugins and jobs, `sync.sh` / `doctor.sh`
/// / `learn.sh` / `nudge.sh`, the connect scripts the Connections pane launches
/// by path, and the starter vocabulary. `build.sh` stages all of it at
/// `Contents/Resources/moe-home`, mirroring `~/.moe` one directory for one, so
/// this is a plain recursive copy with no name list of its own to drift.
///
/// **Why a copy rather than running from the bundle.** Three reasons, each on
/// its own sufficient: `connectors/` holds credentials beside its own code
/// (`gmail-accounts.json`, `telegram.session`, `drive-docs-files.json`) and a
/// read-only directory breaks every connect flow; `gmail.py` and `telegram.py`
/// locate `confirm.sh` as `realpath(__file__)/../tools/confirm.sh` and their
/// comments deliberately refuse `$MOE_HOME`, so `tools/` must stay a sibling of
/// `connectors/`; and nothing may be written or `chmod`'d inside a signed
/// bundle without breaking the seal that Gatekeeper checks.
///
/// Before this existed the payload reached a Mac only through
/// `scripts/install.sh`, which copies it out of a git checkout of a private
/// repo — so a downloaded Moe had an empty Connections pane and a Brain pane
/// that could not choose a provider, and said nothing about why. docs/BUNDLE.md.
enum Payload {

    /// Files the user is expected to edit, seeded once and never replaced.
    /// Everything else in the payload is ours and is refreshed on an update.
    private static let userOwned: Set<String> = ["vocabulary.txt"]

    /// Records which payload this home was laid down from, so an app update
    /// refreshes the scripts without doing the work on every launch.
    static func stampURL(in home: URL) -> URL { home.appendingPathComponent(".payload") }

    static var bundlePayload: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("moe-home", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// A file in the checkout this binary was built from — **debug builds
    /// only**, and nil in a release.
    ///
    /// Sixteen helper lookups used to end with `~/moe/moe-home/…` as a last
    /// resort, in every build. On a stranger's Mac that path does not exist
    /// and the rung was dead weight. On the owner's it does exist, and on
    /// 2026-11-12 it was a checkout 1,409 commits behind `main`: a release
    /// Moe whose installed script and bundled copy were both missing would
    /// have run a nine-week-old one from there and reported nothing. A
    /// missing script now fails where it is missing, in words.
    ///
    /// What is left is the developer convenience it was meant to be: a
    /// `swift build` binary has no bundle payload, so it may read the tree it
    /// was compiled from — that tree, by `#filePath`, never whichever
    /// checkout happens to be sitting at `~/moe`.
    static func checkoutPath(_ relative: String, file: String = #filePath) -> String? {
        #if DEBUG
        // …/Sources/Moe/Payload.swift → the repo root.
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(relative).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
        #else
        return nil
        #endif
    }

    /// The version this build would install: the app's version, plus a digest
    /// of the payload's shape — every file's path, size and modification date.
    ///
    /// The app version alone is not enough. A developer who edits a script in
    /// moe-home/ and rebuilds does not bump CFBundleVersion, and a file count
    /// alone misses an edit that does not add a file, so the payload would go
    /// stale for exactly the person most likely to be confused by it. Sizes
    /// and dates come from the directory listing, so this reads no file
    /// contents and costs nothing measurable at launch.
    static func version(of payload: URL) -> String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let fm = FileManager.default

        // FNV-1a over the listing. Not a security hash: it answers "is this
        // the same payload I laid down last time", and a collision costs a
        // skipped refresh, never a wrong file.
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        }
        let names = files(in: payload)
        for rel in names {
            mix(rel)
            let a = try? fm.attributesOfItem(atPath: payload.appendingPathComponent(rel).path)
            mix(String((a?[.size] as? Int) ?? -1))
            let t = (a?[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? -1
            mix(String(t))
        }
        return "\(short)-\(build)-\(names.count)-\(String(h, radix: 36))"
    }

    /// Copies the payload into `~/.moe` when this build has not been laid down
    /// yet. Returns what happened, for the log — never throws at the caller:
    /// a Moe that will not start because a copy failed is worse than a Moe
    /// with a stale script, and every reader of these files reports its own
    /// absence in words the user can act on.
    ///
    /// Called synchronously during launch, and that is deliberate: the
    /// supervisor reads `configure-hermes.py` moments later and the
    /// Connections pane resolves its scripts by path, so a copy racing them
    /// would show an empty pane on the first run and a full one on the
    /// second. It is ~80 files under a megabyte, and after the first run it
    /// is a single file read.
    ///
    /// `home` is explicit rather than ambient: `FileManager
    /// .homeDirectoryForCurrentUser` ignores `$HOME` for a non-sandboxed
    /// process, so a test cannot redirect this by setting an environment
    /// variable, and a release build that honoured one would be a way to make
    /// Moe write its scripts somewhere else. `Moe --install-payload <dir>`
    /// passes it on the command line instead.
    @discardableResult
    static func installIfNeeded(into home: URL = Paths.home) -> String {
        guard let payload = bundlePayload else {
            // A `swift build` binary run from the command line has no bundle
            // payload, and neither did every build before 2026-08-31. Both are
            // expected: scripts/install.sh is what populates ~/.moe there.
            return "no payload in this build; ~/.moe left as it is"
        }

        let want = version(of: payload)
        let stamp = stampURL(in: home)
        let have = (try? String(contentsOf: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if have == want { return "payload \(want) already installed" }

        // One writer. `Moe --ask`, `--voice-test`, `--sync` and the app itself
        // all reach this, and two of them at different versions would
        // interleave their swaps — leaving files that briefly do not exist and
        // a stamp claiming failure. O_EXCL on a lock file is the whole
        // mechanism; the loser does nothing and reports why, because the
        // winner is about to make its work unnecessary anyway.
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let lock = home.appendingPathComponent(".payload.lock")
        let fd = open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 && errno != EEXIST {
            // A read-only or full home, not a competing install. Saying
            // "another copy of Memoe is installing it" there would be wrong and
            // would never clear.
            return "payload: cannot write to \(home.path) (errno \(errno))"
        }
        if fd < 0 {
            // A lock older than ten minutes is a crashed run, not a live one.
            let age = (try? FileManager.default.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date)
                .flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 0
            if age < 600 { return "payload: another copy of Memoe is installing it" }
            try? FileManager.default.removeItem(at: lock)
            return "payload: cleared a stale lock; the next launch installs it"
        }
        close(fd)
        defer { try? FileManager.default.removeItem(at: lock) }

        let (copied, failed) = install(from: payload, into: home)
        // The stamp records this version whether or not every file landed.
        //
        // The first version of this wrote "<version> (n failed)", which can
        // never equal the version it is compared against — so one permanently
        // unwritable file meant every launch re-enumerated and byte-compared
        // the whole tree, synchronously, before the window appeared. What
        // stands in for the retry: `Moe --install-payload` repairs it, the
        // failure is logged with the names, and every reader of these files
        // falls back to the copy inside the app (ScriptRunner.scriptPath), so
        // a partly-laid-down home still works.
        try? want.write(to: stamp, atomically: true, encoding: .utf8)

        if !failed.isEmpty {
            return "payload \(want): copied \(copied), could not write \(failed.count): \(failed.prefix(3).joined(separator: ", ")) — `Moe --install-payload` retries"
        }
        return have == nil
            ? "payload \(want) installed (\(copied) files)"
            : "payload updated \(have!) → \(want) (\(copied) files)"
    }

    /// Starts the two background jobs the product assumes are running, once.
    ///
    /// `scripts/install.sh` writes `com.moe.sync` (every 10 minutes) and
    /// `com.moe.digest` (hourly) and bootstraps them. Nothing in the app did:
    /// `Launchd.set` was only ever reached from the Settings switches, so a
    /// Mac that installed Moe by downloading it never refreshed its context
    /// at all. `~/.moe/context/_brief.md` was never written, the model's
    /// "what is going on right now" block stayed empty, and Settings read
    /// "Last sync: never" forever with both switches off and no explanation.
    ///
    /// Once, keyed on its own marker rather than on whether the jobs are
    /// loaded: someone who turns them off in Settings has said what they
    /// want, and a launch must not argue with that.
    ///
    /// `com.memoe.app` — start Moe at login — is deliberately not here.
    /// install.sh asks before adding it, and a downloaded app that quietly
    /// installs itself into a login session has helped itself to something
    /// nobody offered.
    @discardableResult
    static func startBackgroundJobsOnce(in home: URL = Paths.home) -> String {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            return "background jobs: no executable path"
        }

        // A launchd job records the *path* it should run, so where the app was
        // when the job was written is where launchd will look forever. Two
        // paths must never be written:
        //
        //   /Volumes/…            the app was double-clicked inside the dmg
        //   …/AppTranslocation/…  Gatekeeper ran a quarantined app from a
        //                         randomised read-only copy, which disappears
        //
        // Either one produces two agents that fail every ten minutes for the
        // life of the Mac, and the marker below would stop anything from ever
        // fixing them. So they are not written at all; the next launch from
        // /Applications writes them properly.
        // (A release copy never gets this far from either — it is offered
        // the move to Applications at launch, `MoveToApplications`; this
        // still holds for any other build.)
        let origin = MoveToApplications.origin(ofPath: exe)
        if origin != .elsewhere {
            return "background jobs: not yet — Moe is running from \(origin == .diskImage ? "the disk image" : "a temporary copy")"
        }

        // A third path that must never be written, and it is worse than the
        // two above because it survives quitting the app.
        //
        // `Launchd.jobsLabel` derives from `Bundle.main.bundleIdentifier`,
        // which is **nil for a bare binary** — `.build/debug/Moe`, run
        // straight out of a checkout. `MainWindow.swift` falls back to
        // "com.memoe.app" for it, so the label becomes the REAL app's
        // `com.moe.jobs`, and the plist it writes points launchd at the debug
        // binary in somebody's worktree. Every ten minutes, for ever, until a
        // person notices.
        //
        // Measured on 2026-09-04: one `.build/debug/Moe --ask` repointed the
        // owner's live `com.moe.jobs` at a checkout. Nothing in the app
        // repairs it either — the marker below then agrees with the debug
        // path, so the next launch of the real Moe reads "already set up".
        // It was only undone by an unrelated `catch-up.sh` install.
        //
        // Moe Dev is unaffected: it is a real bundle with its own identifier,
        // which is the whole point of it. This is only ever a build nobody
        // installed.
        if Bundle.main.bundleIdentifier == nil {
            return "background jobs: not written — this build has no bundle "
                 + "identifier, so it would claim the installed Moe's launchd job"
        }

        // The marker records which executable the jobs point at, so an app
        // that moves — Downloads to Applications, or a reinstall elsewhere —
        // is noticed and the plists are rewritten. Storing only a date, as
        // this first did, meant the first path won permanently.
        // The marker carries a schema tag as well as the path. Without one,
        // a Mac whose app has not moved reads "already set up" and returns
        // before the migration below ever runs — so the two superseded agents
        // would survive every upgrade, and the collapse to one agent would
        // land for new installs only. Bumping this string is how a future
        // change to the set of agents forces itself to be applied once.
        let schema = "jobs-v2"
        let marker = home.appendingPathComponent(".jobs-started")
        let recorded = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let want = "\(exe)\n\(schema)"
        if recorded == want {
            // The marker says "this path, this schema" — and says nothing
            // about whether launchd still has a working job. A reinstall at
            // the same path leaves the marker true and the job dead
            // (Launchd.jobsAilment). So the marker is a shortcut past the
            // *writing*, never past the *checking*.
            guard let ailment = Launchd.jobsAilment() else {
                return "background jobs: already set up"
            }
            Log.write("background jobs: \(ailment) — writing it again")
            if Launchd.set(label: Launchd.jobsLabel, enabled: true) {
                firstSync()
                return "background jobs: revived — \(ailment)"
            }
            return "background jobs: \(ailment), and it would not start; trying again next launch"
        }

        // The new agent goes in FIRST, and the old ones come out after.
        //
        // The other order is a trap. `Moe --sync` reaches this code — a
        // missing sync.sh sends it through FirstRun.installHomeIfNeeded — and
        // the process running it may itself be the `com.moe.sync` job. Booting
        // out your own launchd job kills you on the spot (measured), so the
        // migration died on its first iteration: old agent unloaded, new agent
        // never written, no marker, and a Mac with no sync at all until the
        // next login replayed the same suicide.
        //
        // Writing the replacement first means the worst case is a moment with
        // both, not a moment with neither.
        var started: [String] = []
        if Launchd.set(label: Launchd.jobsLabel, enabled: true) { started.append(Launchd.jobsLabel) }

        // And still not from inside one of the jobs being removed. Left to
        // the next run, which will be the new agent and can safely do it —
        // the marker below is not written until then, so it does happen.
        let cleared = Launchd.runningAsSupersededJob() ? 0 : Launchd.removeSuperseded()

        // The marker is only written when the job actually started. Writing
        // it regardless — as this first did — turned one transient launchctl
        // failure into a Mac that never syncs again, silently and for good.
        guard started.count == 1 else {
            return "background jobs: \(Launchd.jobsLabel) did not start; will try again next launch"
        }

        // And only once the old agents are actually gone. The marker is what
        // makes this whole function a no-op on later launches, so writing it
        // while a superseded agent is still on disk — because we deferred the
        // removal, or because `launchctl bootout` failed — would freeze this
        // Mac at three agents permanently, with nothing left to retry it.
        if Launchd.supersededRemain() {
            firstSync()
            return "background jobs: \(Launchd.jobsLabel) started; older agents still to be removed on the next run"
        }
        try? want.write(to: marker, atomically: true, encoding: .utf8)

        // And one sync immediately, because the first timer fires ten minutes
        // from now and until then the model has nothing to say about today.
        // install.sh runs exactly this for the same reason. Detached and
        // ignored: it writes ~/.moe/context and its failures belong in its own
        // log, not in a launch.
        firstSync()

        let note = cleared > 0 ? " (replaced \(cleared) older agent\(cleared == 1 ? "" : "s"))" : ""
        return recorded == nil
            ? "background jobs: started \(started.joined(separator: ", "))\(note)"
            : "background jobs: repointed at \(exe)\(note)"
    }

    /// Removes the symlinks Models.linkIfNeeded made, wherever they point at
    /// a bundle that is going away.
    ///
    /// A dangling symlink is worse than a missing directory: `mkdir` over one
    /// fails with EEXIST, so FluidAudio can no longer create the directory it
    /// wants to download into — not for Moe, and not for any other app on
    /// that Mac that uses the same caches. Removing a symlink removes the
    /// link and never the models it pointed at.
    static func removeModelLinks() -> Int {
        let fm = FileManager.default
        var removed = 0
        for (name, root) in Models.bundled {
            let link = root.url.appendingPathComponent(name)
            guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil else { continue }
            if (try? fm.removeItem(at: link)) != nil { removed += 1 }
        }
        return removed
    }

    /// `Moe --sync`, once, in the background.
    ///
    /// Through the app's own executable rather than a shell: the connectors it
    /// runs ask macOS for Calendar and Contacts, and a permission prompt is
    /// attributed to the process that raised it. Going through Bundle.main
    /// means the grant the user gave Moe is the grant these run under — the
    /// same reasoning as the LaunchAgent, whose ProgramArguments[0] is this
    /// binary rather than /bin/bash.
    private static func firstSync() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--sync"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: - The copy

    private static func install(from payload: URL, into home: URL) -> (copied: Int, failed: [String]) {
        let fm = FileManager.default
        var copied = 0
        var failed: [String] = []

        for rel in files(in: payload) {
            let src = payload.appendingPathComponent(rel)
            let dst = home.appendingPathComponent(rel)

            // Seeded once. install.sh has always refused to overwrite the
            // vocabulary for the same reason: the user edits it.
            if userOwned.contains(rel), fm.fileExists(atPath: dst.path) { continue }

            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let exists = fm.fileExists(atPath: dst.path)
                if exists {
                    // Same bytes already there: leave the file alone so its
                    // mtime keeps meaning "when this last changed".
                    if let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: dst), a == b {
                        // …but fix the mode on the way past. The whole reason
                        // the mode is repaired at all is lib/connectors.sh and
                        // hermes-jobs/*.py — files that are 644 in the repo,
                        // that install.sh never chmods, and that hardly ever
                        // change. Every one of them takes this shortcut, so
                        // repairing only files whose contents differ repaired
                        // none of them, ever, including through
                        // `Moe --install-payload`.
                        if isExecutable(rel), let mode = (try? fm.attributesOfItem(atPath: dst.path))?[.posixPermissions] as? NSNumber,
                           mode.int16Value & 0o111 == 0 {
                            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                        }
                        continue
                    }
                }
                // Copy beside it, then swap. Deleting first and copying second
                // — which this did — means a full disk or a crash mid-copy
                // leaves no file at all, and a missing ~/.moe/sync.sh is worse
                // than a stale one: `Moe --sync` hard-fails and the background
                // refresh stops until someone opens the app again.
                let tmp = dst.appendingPathExtension("moe-new")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: src, to: tmp)
                if exists {
                    // A directory where the payload has a file: replaceItemAt
                    // would silently destroy it. Say so instead.
                    var isDir: ObjCBool = false
                    _ = fm.fileExists(atPath: dst.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        try? fm.removeItem(at: tmp)
                        failed.append(rel)
                        continue
                    }
                    _ = try fm.replaceItemAt(dst, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: dst)
                }
                // After the swap, not before. `replaceItemAt` carries the
                // *original* item's metadata over to the replacement — that is
                // what "not usingNewMetadataOnly" means — so a mode set on the
                // temporary file is discarded on every update. Measured: tmp
                // 0755, destination 0644, result 0644. That mattered: install.sh
                // never chmods lib/*.sh or hermes-jobs/*.py, they are mode 644
                // in the repo, and this was the only thing that could have
                // repaired them.
                if isExecutable(rel) {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
                }
                copied += 1
            } catch {
                // The same tidy-up the directory refusal does nine lines up.
                // Without it a throw leaves <file>.moe-new in ~/.moe for ever,
                // and only hermes-plugins/ and hermes-jobs/ are ever pruned.
                try? fm.removeItem(at: dst.appendingPathExtension("moe-new"))
                failed.append(rel)
            }
        }
        // The two trees that are wholly ours. install.sh `rm -rf`s these before
        // copying, because Hermes loads every plugin it finds: a plugin
        // withdrawn in an update would otherwise keep running for ever, and a
        // renamed one would run twice. Nothing else in ~/.moe is ever deleted
        // — the rest holds credentials, memories and files people edit.
        for dir in ["hermes-plugins", "hermes-jobs"] {
            let live = home.appendingPathComponent(dir, isDirectory: true)
            guard fm.fileExists(atPath: live.path) else { continue }
            let shipped = Set(files(in: payload).filter { $0.hasPrefix(dir + "/") })
            for rel in files(in: live).map({ dir + "/" + $0 }) where !shipped.contains(rel) {
                // Two things are in the home and deliberately not in the
                // bundle, and neither is stale: the plugin test suites, which
                // build.sh prunes from the payload but install.sh copies and
                // connectors/validate.sh runs — deleting them would make that
                // check silently stop happening — and Python's own caches.
                if rel.contains("/tests/") || rel.contains("__pycache__")
                    || rel.contains(".pytest_cache") { continue }
                try? fm.removeItem(at: home.appendingPathComponent(rel))
            }
        }

        return (copied, failed)
    }

    /// Mirrors the `chmod +x` list in scripts/install.sh: everything a shell,
    /// Hermes or the Connections pane executes rather than reads.
    private static func isExecutable(_ rel: String) -> Bool {
        if rel.hasSuffix(".sh") { return true }
        if rel.hasSuffix(".py") {
            // Only the ones something actually execs. connectors/*.py are
            // launched directly by the app; learn/*.py and hermes/*.py by
            // shells and by Hermes.
            return rel.hasPrefix("connectors/") || rel.hasPrefix("learn/")
                || rel.hasPrefix("hermes/") || rel.hasPrefix("hermes-jobs/")
        }
        return false
    }

    /// Every file in the payload, as paths relative to its root.
    private static func files(in root: URL) -> [String] {
        // No .skipsHiddenFiles. build.sh stages the payload with `find -type f`,
        // which includes dotfiles, so skipping them here would mean a file
        // that is in the bundle and silently never reaches ~/.moe — invisible
        // until someone wondered why a feature did nothing.
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return [] }
        var out: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            out.append(String(path.dropFirst(prefix.count)))
        }
        return out.sorted()
    }
}
