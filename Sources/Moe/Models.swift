import Foundation
import FluidAudio

/// The speech and voice models, and how they get onto a stranger's Mac.
///
/// Moe's recognition and its voice are Core ML models that FluidAudio fetches
/// from Hugging Face into two cache directories (see `Root`).
/// Left to itself that is **889 MB downloaded before Moe can answer once**,
/// behind a status line that says "loading speech recognition…" with no
/// percentage — and nothing at all on a Mac that is offline. docs/BUNDLE.md §2.
///
/// So a release carries them. `scripts/fetch-models.sh` stages them into the
/// repo's gitignored `Models/`, `build.sh` copies that into
/// `Contents/Resources/Models/<repo folder>`, and this links each cache
/// directory at the bundle on first run.
///
/// **Links, not copies.** A copy would put ~900 MB on the disk twice, once in
/// the app and once in the cache. A symlink costs nothing, and the
/// models are read-only anyway: they ship pre-compiled as `.mlmodelc`, so
/// nothing needs to write into them. What a link *cannot* survive is the app
/// moving or being deleted, so every launch checks that each link still points
/// at this bundle and repoints it when it does not.
///
/// **A real directory always wins.** If a model is already downloaded — every
/// Mac that ran Moe before this existed has them — that directory is left
/// exactly as it is. This only ever creates a link where there was nothing,
/// or repairs a link it made itself.
enum Models {

    /// FluidAudio has **two** cache roots, not one, and which one a model
    /// lands in depends on the backend that fetched it. Measured rather than
    /// assumed: after `Moe --fetch-models`, the recognisers were in
    /// Application Support and the voice was in ~/.cache. Getting this wrong
    /// is silent — the link goes in the wrong place, the library downloads
    /// anyway, and the only symptom is a slow first run.
    enum Root {
        /// `~/Library/Application Support/FluidAudio/Models` — the recognisers.
        case appSupport
        /// `~/.cache/fluidaudio/Models` — the voices.
        case cache

        var url: URL { url(under: nil) }

        /// `base` replaces the real roots with two directories beneath it, so
        /// a test can watch the links being made. Explicit, not an
        /// environment variable: both real roots are resolved through
        /// FileManager, which ignores $HOME for a non-sandboxed process, and
        /// a release that honoured an env var would be a way to point Moe's
        /// models somewhere else.
        func url(under base: URL?) -> URL {
            if let base {
                switch self {
                case .appSupport: return base.appendingPathComponent("appsupport", isDirectory: true)
                case .cache:      return base.appendingPathComponent("cache", isDirectory: true)
                }
            }
            let fm = FileManager.default
            switch self {
            case .appSupport:
                return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            case .cache:
                return fm.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
            }
        }
    }

    /// The model directories a release carries, and the root each belongs in.
    /// The names are FluidAudio's own `Repo.folderName`, and the bundle
    /// mirrors them one for one under `Contents/Resources/Models/<root>/`.
    ///
    ///   parakeet-eou-streaming    the streaming recogniser (eager, 214 MB)
    ///   parakeet-tdt-0.6b-v3      the accurate transcriber (eager, 461 MB)
    ///   parakeet-ctc-110m-coreml  vocabulary boost (lazy, 98 MB)
    ///   speaker-diarization       who said what, in meetings (lazy, 13 MB)
    ///   silero-vad                when anyone is speaking (eager, 1 MB) —
    ///                             and "Hey Moe" is dead without it, because
    ///                             the wake head is only ever run on audio
    ///                             the VAD called speech
    ///   campplus                  whose voice it is (lazy, 28 MB)
    ///   kokoro-82m-coreml         the default voice (eager, 79 MB)
    ///   kokoro                    its shared G2P assets (24 MB) — a separate
    ///                             directory, and the one FluidAudio fetches
    ///                             even when the voice itself is bundled
    static let bundled: [(name: String, root: Root)] = [
        ("parakeet-eou-streaming", .appSupport),
        ("parakeet-tdt-0.6b-v3", .appSupport),
        ("parakeet-ctc-110m-coreml", .appSupport),
        ("speaker-diarization", .appSupport),
        // One megabyte, and the whole wake word depends on it. Left
        // unbundled it was fetched at every launch, and on 2026-09-03
        // HuggingFace answered 429: the VAD did not load, and with it
        // "Hey Moe" stopped working — silently, because the failure is
        // logged as "continuing without" and nothing said what "without"
        // costs. It was on this Mac the whole time.
        ("silero-vad", .appSupport),
        // The owner's voice. Failed the same way, the same minute.
        ("campplus", .appSupport),
        ("kokoro-82m-coreml", .cache),
        ("kokoro", .cache),
    ]

    /// `Contents/Resources/Models`, when this build carries them.
    static var bundleModels: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("Models", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Links the cache at the bundled models. Returns a line for the log.
    /// - Parameter models: the bundle's `Models` directory. A parameter so
    ///   a test can hand it a stand-in for a slim bundle; the app passes none.
    @discardableResult
    static func linkIfNeeded(rootsUnder base: URL? = nil, models: URL? = bundleModels) -> String {
        guard let models else {
            return "no models in this build; they download on first use"
        }
        let fm = FileManager.default
        var linked: [String] = []
        var kept: [String] = []
        var failed: [String] = []
        var cleared: [String] = []

        for (name, root) in bundled {
            let src = models.appendingPathComponent(name, isDirectory: true)
            let rootURL = root.url(under: base)
            guard fm.fileExists(atPath: src.path) else {
                // This build does not carry it (a slim build and an
                // on-demand model: docs/SLIM-DOWNLOAD.md). A link an earlier
                // build left, pointing at a model that is no longer anywhere,
                // is worse than nothing: it reports itself as the model's
                // folder and nothing can be downloaded "into" it. Only ever a
                // link, and only one whose target is gone — a link into
                // another live app, or a real folder, is somebody's model.
                let dst = rootURL.appendingPathComponent(name, isDirectory: true)
                if (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil,
                   !fm.fileExists(atPath: dst.path), (try? fm.removeItem(at: dst)) != nil {
                    cleared.append(name)
                }
                continue
            }
            try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let dst = rootURL.appendingPathComponent(name, isDirectory: true)

            let existing = try? fm.destinationOfSymbolicLink(atPath: dst.path)
            if let existing {
                // Ours, and still pointing at this copy of the app: nothing to do.
                if existing == src.path { kept.append(name); continue }
                // A link we made for an app that has since moved or been
                // replaced. Removing a symlink removes the link, never the
                // models it pointed at.
                try? fm.removeItem(at: dst)
            } else if fm.fileExists(atPath: dst.path) {
                // A real directory — a download from before this existed, or
                // one FluidAudio made itself. Never touched.
                kept.append(name)
                continue
            }

            do {
                try fm.createSymbolicLink(at: dst, withDestinationURL: src)
                linked.append(name)
            } catch {
                failed.append(name)
            }
        }

        var parts: [String] = []
        if !linked.isEmpty { parts.append("linked \(linked.count)") }
        if !kept.isEmpty { parts.append("kept \(kept.count)") }
        if !failed.isEmpty { parts.append("could not link \(failed.joined(separator: ", "))") }
        if !cleared.isEmpty { parts.append("cleared \(cleared.count) stale") }
        return parts.isEmpty ? "no bundled models to link" : "models: " + parts.joined(separator: ", ")
    }

    /// Loads every bundled model with the network switched off.
    ///
    /// This is the only test that actually answers the question the bundling
    /// exists for: *on a Mac that has never downloaded anything, does Moe
    /// hear and speak?* `ModelHub.offlineMode` makes any attempted download a
    /// typed error rather than a silent success, so a model that is missing
    /// from the bundle, or in the wrong cache root, or laid out wrongly, fails
    /// here instead of on a stranger's first run.
    static func verifyOffline() async -> Int {
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        // A slim build does not carry the on-demand models, so "loads with
        // the network off" is not a claim it makes about them — and saying
        // which were left out is what keeps this from being a check that
        // quietly covers less than its name says.
        return await fetchAll(skippingOnDemand: OnDemandModels.mode == .on)
    }

    /// Warms every model this build wants to bundle, which is what downloads
    /// them into FluidAudio's cache. `scripts/fetch-models.sh` runs this and
    /// then copies the cache into the repo's `Models/`, so the list of files
    /// each repo needs comes from FluidAudio itself and can never drift from
    /// what the app loads.
    static func fetchAll(skippingOnDemand: Bool = false) async -> Int {
        var failures = 0
        if skippingOnDemand {
            FileHandle.standardError.write(Data("– not checked: vocabulary boost, speaker diarization (on demand in this build)\n".utf8))
        }

        func step(_ name: String, _ work: () async throws -> Void) async {
            FileHandle.standardError.write(Data("… \(name)\n".utf8))
            do {
                try await work()
                FileHandle.standardError.write(Data("✓ \(name)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("✗ \(name): \(error)\n".utf8))
                failures += 1
            }
        }

        await step("streaming recognizer (parakeet-eou)") {
            let r = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 900)
            try await r.loadModels()
        }
        await step("accurate transcriber (parakeet-tdt-0.6b-v3)") {
            _ = try await AsrModels.downloadAndLoad(version: .v3)
        }
        if !skippingOnDemand {
            await step("vocabulary boost (parakeet-ctc-110m)") {
                _ = try await CtcModels.downloadAndLoad()
            }
            await step("speaker diarization") {
                _ = try await DiarizerModels.downloadIfNeeded()
            }
        }
        await step("voice (kokoro-82m)") {
            let m = KokoroAneManager(variant: .english)
            try await m.initialize()
        }
        return failures
    }
}
