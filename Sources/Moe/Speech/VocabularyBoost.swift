import FluidAudio
import Foundation
import MoeComponents

/// Acoustic vocabulary boosting: your names and jargon, recovered from the
/// audio rather than patched into the string afterwards.
///
/// `Vocabulary` (MoeDictation) does the cheap half — it rewrites a heard form
/// you already wrote down ("cooper netties => Kubernetes"). That only works
/// for mistakes you have already seen and typed out. This does the other
/// half: a second, small CTC model reads the *same audio* looking for your
/// terms specifically, and where it finds acoustic evidence for one under a
/// word Parakeet mangled, the word is replaced. Nobody has to have predicted
/// the mangling.
///
/// FluidAudio ships the machinery (`CtcKeywordSpotter` + `VocabularyRescorer`,
/// after NVIDIA's CTC-based word spotter, arXiv:2406.07096); this is the
/// wiring — when to load it, what to feed it, and how never to let it break a
/// transcription.
///
/// **Cost.** A separate CTC encoder, ~130 MB, downloaded on first use and
/// only ever downloaded when the user actually has vocabulary terms. An empty
/// vocabulary — the default — pays nothing: no download, no load, no work per
/// utterance. That is why `boost` takes the terms as an argument and decides
/// for itself whether there is anything to do.
///
/// **Safety.** Every failure path returns nil and the caller keeps the
/// unboosted text. A vocabulary feature that can lose a transcription is
/// worse than no vocabulary feature.
actor VocabularyBoost {

    /// Terms below this many characters are dropped before the session is
    /// built. FluidAudio applies its own `minTermLength` (3) internally, but
    /// short terms are also what generate false positives ("or" → "VR"), and
    /// a term the rescorer will never fire on is only slowing the spotter
    /// down. Four is deliberately stricter than FluidAudio's three: a
    /// three-letter name in a dictation vocabulary is nearly always an
    /// initialism that Parakeet already spells correctly.
    static let minTermLength = 4

    /// How many terms the spotter is given. The rescorer is O(terms × words)
    /// by default, and a vocabulary this size already covers every name in a
    /// normal Contacts sync. Matches `Conductor.promptVocabularyLimit`, which
    /// caps the same list on its way into the polish prompt.
    static let maxTerms = 400

    /// FluidAudio's rescorer with its "spotter rescue" pass switched off.
    ///
    /// That pass takes a term the spotter heard but the rescorer could not
    /// match to any similar-looking word, and forces it in at the position
    /// the CTC detection implies. It is built for long, distinctive
    /// vocabularies — drug names, company names — where a mangled term is
    /// unrecoverable by string similarity alone. A dictation vocabulary is
    /// the opposite: a handful of short words that collide with ordinary
    /// speech, and the rescue then fires on anything vaguely shaped like one.
    ///
    /// Measured both ways over the eleven-clip bench, ten-term vocabulary
    /// (`scripts/make-bench-clips.sh`, `Moe --stt-bench`):
    ///
    ///     rescue off   8.4% → 5.4% WER    5 errors fixed
    ///     rescue on    8.4% → 24.6% WER   27 errors introduced
    ///
    /// With it on, eight of eleven clips got *worse* — including three that
    /// had been perfect — and the one about Nithya and Joaquin went to 100%.
    /// It fires on ordinary speech: "dropping tokens" → "Parakeet", "at the
    /// seam." → "Parakeet", "decoder was still" → "WhisperKit". FluidAudio's
    /// own benchmark says the same (Documentation/ASR/CustomVocabulary.md):
    /// for short vocabularies, turning the rescue off both cuts false
    /// positives (~94 → ~19) and *raises* recall (0.92 → 0.97), because
    /// spurious replacements stop clobbering words that were already right.
    ///
    /// What survives is the fuzzy-match path, which is the one that earns its
    /// keep: "LiveMarley" → "Livmarli", "Anwin" → "Anwen", "Shevonne" →
    /// "Siobhan". The price of switching the rescue off is the case it was
    /// built for — a term mangled past recognition, like "and Joaquin are"
    /// heard as "Ranwakina", stays wrong. Five fixed against twenty-seven
    /// introduced is not a close call.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    // Do not run the CTC pass concurrently with the decode. It looks like
    // free latency — the spotter reads the audio, not the transcript, so
    // there is no data dependency and it could start the moment recording
    // ends. Tried, measured, reverted.
    //
    // Both models run on the Neural Engine, which is one shared resource, so
    // concurrent CoreML work contends instead of overlapping — and the
    // contention is not free. On the same 6.3 s clip, three runs each:
    //
    //     serial      decode 0.12 s + boost 0.31 s = 0.43 s
    //     concurrent  decode 0.35 s + boost 0.58 s = 0.93 s
    //
    // The decode itself got three times slower. Splitting FluidAudio's
    // VocabularyBoostingSession into its spotter and rescorer halves (both
    // are public, so it is easy) buys nothing and costs the clarity of using
    // the pipeline as shipped.
    //
    // The dictation latency worth attacking is the polish round trip, which
    // is several times all of this put together.

    /// Built lazily, and rebuilt whenever the term list changes — a name
    /// added to vocabulary.txt is boosted on the next utterance, with no
    /// restart, the same as everywhere else in the vocabulary pipeline.
    private var session: VocabularyBoostingSession?
    /// The terms `session` was built from, so a rebuild is only paid for when
    /// they actually differ.
    private var sessionTerms: [String] = []
    /// In flight, so two utterances arriving together don't both download.
    private var building: Task<VocabularyBoostingSession?, Never>?
    /// The terms the in-flight build is for. Kept alongside `building` so a
    /// second caller can tell "already building exactly this" from "building
    /// something stale" — `sessionTerms` cannot answer that, because it is
    /// not set until the build finishes.
    private var buildingTerms: [String] = []
    /// Set once a build has failed, so a missing model or an offline first
    /// run costs one attempt rather than one per utterance. Cleared when the
    /// terms change, which is the user's natural "try again".
    private var buildFailed = false

    /// True when boosting could run — there are terms and the models loaded.
    /// For the self-test and diagnostics; never gates `boost`, which decides
    /// per call.
    var isActive: Bool { session != nil }

    /// Load the CTC model ahead of the first dictation, if there is anything
    /// to boost.
    ///
    /// Measured cold: 15.5 s to download-check, load and build the session.
    /// On the first press that is 15.5 s of someone holding a key watching
    /// nothing happen — so it happens at warm-up instead, beside the speech
    /// model, where the app is already saying it is getting ready. Silent and
    /// harmless when the vocabulary is empty: nothing loads, nothing
    /// downloads.
    func warmUp(terms: [String]) async {
        _ = await session(for: Self.usable(terms), waitIfBuilding: true)
    }

    /// The transcript with vocabulary terms restored, or nil to keep `text`
    /// exactly as it is.
    ///
    /// `timings` and `samples` must share a clock — timing zero is the first
    /// sample — which is what the single-window dictation path gives for free.
    ///
    /// - Parameters:
    ///   - text: what the primary model wrote.
    ///   - timings: that model's token times, from the same decode.
    ///   - samples: the 16 kHz audio behind it.
    ///   - terms: the canonical spellings to look for.
    func boost(text: String, timings: [TokenTiming], samples: [Float],
               terms: [String]) async -> String? {
        let wanted = Self.usable(terms)
        guard !wanted.isEmpty, !text.isEmpty, !timings.isEmpty, !samples.isEmpty else { return nil }
        guard let session = await session(for: wanted) else { return nil }

        let started = Date()
        guard let out = await session.rescore(text: text, tokenTimings: timings,
                                              audioSamples: samples) else { return nil }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // Which terms fired, never the transcript around them: a term is
        // something the user wrote in vocabulary.txt, the sentence is what
        // they were saying.
        let applied = out.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
        Log.write("dictation: vocabulary boost applied \(applied.count) term(s) in \(ms) ms")
        return out.text
    }

    /// The corrections the boost would make, as word pairs, rather than the
    /// rewritten text.
    ///
    /// For meetings. A meeting transcript is a stream of timed tokens, not a
    /// string: the times carry speaker attribution, the hallucination filter
    /// and the timeline. Handing back the boost's rewritten text would fix the
    /// spelling and lose the clock, so the meeting path takes the word pairs
    /// and applies them to the tokens instead (`TokenRewrite`).
    func corrections(text: String, timings: [TokenTiming], samples: [Float],
                     terms: [String]) async -> [(from: String, to: String)] {
        let wanted = Self.usable(terms)
        guard !wanted.isEmpty, !text.isEmpty, !timings.isEmpty, !samples.isEmpty else { return [] }
        guard let session = await session(for: wanted) else { return [] }
        guard let out = await session.rescore(text: text, tokenTimings: timings,
                                              audioSamples: samples) else { return [] }
        return out.replacements.compactMap { r in
            guard r.shouldReplace, let to = r.replacementWord, !to.isEmpty else { return nil }
            return (from: r.originalWord, to: to)
        }
    }

    /// Terms worth giving the spotter: long enough to be distinctive, capped,
    /// deduplicated, in a stable order so an unchanged vocabulary compares
    /// equal and never triggers a rebuild.
    static func usable(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in terms {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= minTermLength else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == maxTerms { break }
        }
        return out.sorted()
    }

    /// The session for these terms, building it if this is the first use or
    /// the vocabulary has changed since.
    /// - Parameter waitIfBuilding: wait for a build already in flight.
    ///   Only the warm-up does. A turn must not: the build is 15 s of
    ///   CoreML and the person is waiting for their words, which is what
    ///   "a boost that is not ready yet simply does not happen for an
    ///   utterance or two" means. Measured the other way: the first turn of
    ///   a session sat 30 s in "reading that back".
    private func session(for terms: [String], waitIfBuilding: Bool = false) async -> VocabularyBoostingSession? {
        if let session, sessionTerms == terms { return session }
        if !waitIfBuilding, building != nil { return nil }

        // The terms a build is *for*, set before it starts rather than after
        // it finishes. Without this, two callers arriving together both see
        // `sessionTerms` still holding the old value, both conclude the
        // vocabulary changed, and each cancels the other's build — so the
        // 99 MB model loads twice. Observed at launch, where `loadModels` and
        // `useLanguage` each warm the engines: "vocabulary boost ready,
        // 23 terms in 16.2 s" immediately followed by another at 0.6 s.
        if let building, buildingTerms == terms { return await building.value }

        // A genuinely changed vocabulary supersedes a build in flight, and is
        // also the retry: whatever was wrong last time, the user has since
        // edited the file and deserves another go.
        if buildingTerms != terms {
            buildFailed = false
            building?.cancel()
            building = nil
        }
        if buildFailed { return nil }

        // A turn never waits for a download. In a slim build the model may
        // not be on this Mac yet; start fetching it and answer "no boost
        // this time", exactly as for a build already in flight.
        if !waitIfBuilding, !Self.modelOnDisk {
            // Not on every utterance: offline, each attempt is a log line
            // and a refused connection, and the answer will not change in
            // the next ten seconds.
            if let after = fetchRetryAfter, Date() < after { return nil }
            fetchRetryAfter = Date().addingTimeInterval(Self.fetchRetryInterval)
            Task { _ = await self.session(for: terms, waitIfBuilding: true) }
            return nil
        }

        let task = Task<VocabularyBoostingSession?, Never> {
            await Self.build(terms: terms)
        }
        building = task
        buildingTerms = terms
        let built = await task.value
        // Only clear the in-flight marker if it is still ours: a newer build
        // for newer terms may have replaced it while this one ran.
        if building == task { building = nil }
        if let built {
            session = built
            sessionTerms = terms
        } else if Self.modelOnDisk {
            buildFailed = true
        }
        // …and when the model is simply not here yet (a slim build, offline)
        // nothing is latched: that is not a build that failed, it is a
        // download that has not happened, and it is retried — rarely, see
        // `fetchRetryAfter` — until it has.
        return built
    }

    /// Whether the vocabulary model is on this Mac, bundled or fetched.
    private static var modelOnDisk: Bool {
        ComponentFetcher.presence(of: ComponentCatalog.vocabularyBoost,
                                  in: ComponentCatalog.modelsRoot) == .present
    }
    /// How long a turn waits before asking for the model again.
    static let fetchRetryInterval: TimeInterval = 600
    private var fetchRetryAfter: Date?

    /// Download (first time) and load the CTC model, tokenise the terms, and
    /// assemble the session. Nil on any failure — logged, never thrown: the
    /// caller's fallback is the unboosted transcript, which is fine.
    private static func build(terms: [String]) async -> VocabularyBoostingSession? {
        do {
            let started = Date()
            // On disk first, by Memoe's own fetcher: a pinned commit, every
            // file checked against its sha256, resumable. In a build that
            // carries the model this returns at once. When it throws — the
            // Mac is offline, the bytes were wrong — the catch below is the
            // whole consequence; it must not reach FluidAudio's downloader,
            // which pins nothing and checks nothing.
            try await OnDemandModels.ensure(ComponentCatalog.vocabularyBoost)
            let models = try await CtcModels.downloadAndLoad()
            let tokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory())

            // A term the CTC tokenizer cannot encode has nothing to spot;
            // dropping it here keeps the session's own term count honest.
            let encoded = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term, weight: nil, aliases: nil,
                                            tokenIds: nil, ctcTokenIds: ids,
                                            minSimilarity: nil)
            }
            guard !encoded.isEmpty else {
                Log.write("dictation: vocabulary boost off — no term could be tokenised")
                return nil
            }

            let context = CustomVocabularyContext(terms: encoded,
                                                  minTermLength: minTermLength)
            let session = try await VocabularyBoostingSession(vocabulary: context,
                                                             ctcModels: models,
                                                             config: rescorerConfig)
            let seconds = Date().timeIntervalSince(started)
            Log.write(String(format: "dictation: vocabulary boost ready, %d terms in %.1f s",
                             encoded.count, seconds))
            return session
        } catch {
            // Not fatal and not worth an alert: dictation carries on
            // unboosted, which is exactly what it did before this existed.
            Log.write("dictation: vocabulary boost unavailable (\(error.localizedDescription))")
            return nil
        }
    }

    /// Drop the CTC model from memory. The next boost reloads it.
    func unload() {
        building?.cancel()
        building = nil
        session = nil
        sessionTerms = []
        buildFailed = false
    }
}
