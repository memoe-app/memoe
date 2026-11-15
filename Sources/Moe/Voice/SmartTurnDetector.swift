import Foundation
import MoeVoice
import OnnxRuntimeBindings

/// Smart Turn v3.2 (Pipecat, BSD-2): did the person finish, or just pause?
/// VOICE-PLAN.md §4.2.
///
/// An 8 MB Whisper-tiny encoder with a linear head, fed the last eight
/// seconds of the turn when the VAD reports silence. About 35 ms on an M3
/// for the inference and a couple for the features. Its verdict ends a
/// turn early when the thought is finished, and holds the door when it is
/// not ("send it to…"), which is the difference between a timer and a
/// listener.
///
/// Which file is loaded comes from `TurnModelCatalog` (today v3.2 alone,
/// fetched once into `<Moe home>/models/smart-turn` and checked against its
/// pinned SHA-256; `MOE_TURN_MODEL` names another for a bench). Without a
/// model the machine's silence fallback still ends every turn, just later —
/// and `VoiceEngine` keeps trying to load one (`TurnModelRetry`).
actor SmartTurnDetector {

    /// Above this the turn is over. The reference's own value, and it is
    /// staying there.
    ///
    /// I moved it to 0.3 earlier on 2026-09-05 and that was wrong twice over.
    /// Smart Turn's maintainer refuses to make it configurable at all
    /// (pipecat#4478, closed): *"the raw output values are ordinarily very
    /// close to either 0.0 or 1.0. We've trained Smart Turn on a binary
    /// distribution of outputs, and a value in the middle doesn't necessarily
    /// represent lower confidence."* And every production stack — LiveKit,
    /// Pipecat, OpenAI Realtime, Vapi — keeps the classifier binary and makes
    /// the *wait* the tunable thing, which is what `incompleteSilenceSeconds`
    /// already does here.
    ///
    /// The reason 0.3 looked better was the other half of the same mistake:
    /// with the trailing silence trimmed to nothing, "finished" scores
    /// compress downward and stop being bimodal, so a lower line was needed
    /// to catch them. Measured over 80 clips, scored whole and cut at 55%,
    /// varying how much of the pause `TurnAudio` leaves on:
    ///
    ///     keep   threshold   cut off mid-sentence   dawdled   both
    ///     0.00 s      0.30                    25%       54%   0.79   ← was shipping
    ///     0.00 s      0.50                    19%       65%   0.84
    ///     0.20 s      0.50                    18%       42%   0.60
    ///     0.30 s      0.50                    18%       31%   0.49   ← ships
    ///
    /// Fixing the input rather than the line makes both errors smaller at
    /// once. `scripts/bench-turn-model.sh` is the falsifier; the one on the
    /// owner's own voice is `bench-turn-cutoffs.sh`.
    static let threshold = Float(TurnVerdictRule.threshold)
    /// Below this the model is not merely unsure — it is saying "they are
    /// mid-thought" — and the machine waits its longer clock
    /// (`midClauseSilenceSeconds`, 6 s) rather than the ordinary 3 s.
    /// Measured 2026-09-06 22:06Z: the owner spelling an e-mail address
    /// letter by letter got p=0.21 and then p=0.19/0.34, and the 3 s clock
    /// ended the turn twice between letters. Live, only ~4% of turns end
    /// on a clock at all (22 of 543), so the cost of the longer wait falls
    /// on few turns; the cut-off fell on the ones that mattered.
    static let stronglyUnfinished = Float(TurnVerdictRule.stronglyUnfinished)

    private static let dir = Config.homeDir.appendingPathComponent("models/smart-turn", isDirectory: true)

    private var session: ORTSession?
    private var env: ORTEnv?
    private let features = WhisperFeatures()
    /// Which model is loaded (`TurnModelCatalog`), for the log and the benches.
    private(set) var modelName: String?

    /// Load the most preferred model this Mac has and fetch what it lacks
    /// (`TurnModelCatalog.loadPlan`); a model that cannot be fetched,
    /// verified or opened falls through to the next. Throws
    /// only when no model at all will load; the caller then carries on
    /// without one. `MOE_TURN_MODEL` pins one model by name or path (the
    /// benches, which must say what they measured).
    func load() async throws {
        guard session == nil else { return }
        let env = try ORTEnv(loggingLevel: .warning)
        let order = TurnModelCatalog.order(override: ProcessInfo.processInfo.environment["MOE_TURN_MODEL"])
        let plan = TurnModelCatalog.loadPlan(order) { Self.onDisk($0) != nil }
        var lastError: Error = URLError(.fileDoesNotExist)
        for attempt in plan.attempts {
            let model = attempt.model
            do {
                let file = try await Self.ensure(model)
                let opts = try ORTSessionOptions()
                try opts.setIntraOpNumThreads(1)
                try opts.setGraphOptimizationLevel(.all)
                let s: ORTSession
                do {
                    s = try ORTSession(env: env, modelPath: file.path, sessionOptions: opts)
                } catch {
                    // A file the runtime will not open is not a model; the
                    // next launch downloads it again. Never a file named by
                    // path — that one is somebody's.
                    if !model.url.isFileURL { try? FileManager.default.removeItem(at: file) }
                    throw error
                }
                self.env = env
                self.session = s
                self.modelName = model.name
                Log.write("smart turn: loaded \(model.name)")
                if !plan.fetchLater.isEmpty {
                    let later = plan.fetchLater
                    Task.detached(priority: .background) {
                        for m in later {
                            do { _ = try await Self.ensure(m); Log.write("smart turn: \(m.name) ready for the next launch") }
                            catch { Log.write("smart turn: \(m.name) not fetched (\(error.localizedDescription))") }
                        }
                    }
                }
                return
            } catch {
                Log.write("smart turn: \(model.name) unavailable (\(error.localizedDescription)) — trying the next")
                lastError = error
            }
        }
        throw lastError
    }

    var isLoaded: Bool { session != nil }

    /// Probability that the turn is complete, for the last ≤ 8 s of
    /// 16 kHz mono audio. Nil when the model is not up.
    func probabilityComplete(_ audio16k: [Float]) throws -> Float? {
        guard let session else { return nil }
        var feats = features.features(for: audio16k)
        let data = NSMutableData(bytes: &feats, length: feats.count * MemoryLayout<Float>.size)
        let input = try ORTValue(tensorData: data, elementType: .float,
                                 shape: [1, NSNumber(value: WhisperFeatures.mels),
                                         NSNumber(value: WhisperFeatures.frames)])
        let out = try session.run(withInputs: ["input_features": input],
                                  outputNames: ["logits"], runOptions: nil)
        guard let logits = out["logits"] else { return nil }
        // The tensor's bytes are borrowed from the ORT value: read them
        // while it is certainly alive. Despite the name, the graph ends in
        // a sigmoid, so this is a probability.
        return try withExtendedLifetime(out) {
            let bytes = try logits.tensorData() as Data
            guard bytes.count >= MemoryLayout<Float>.size else { return nil }
            return bytes.withUnsafeBytes { $0.load(as: Float.self) }
        }
    }

    /// The model's file when it is on disk and verifies (`TurnModelCatalog.
    /// accepts`: by SHA-256, every launch — 8.7 MB, a few milliseconds). A
    /// file that does not verify is deleted and fetched again.
    private static func onDisk(_ model: TurnModelCatalog.Model) -> URL? {
        if model.url.isFileURL { return model.url }
        let file = dir.appendingPathComponent(model.file)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let why = TurnModelCatalog.rejection(model, data: data) else { return file }
        Log.write("smart turn: \(model.file) on disk does not verify (\(why)) — it will be fetched again")
        try? FileManager.default.removeItem(at: file)
        return nil
    }

    /// On disk, or downloaded, verified and moved into place.
    private static func ensure(_ model: TurnModelCatalog.Model) async throws -> URL {
        if let file = onDisk(model) { return file }
        let fm = FileManager.default
        let file = dir.appendingPathComponent(model.file)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Log.write("smart turn: downloading \(model.name)…")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let (tmp, response) = try await URLSession(configuration: config).download(from: model.url)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? false else {
            try? fm.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        guard let data = try? Data(contentsOf: tmp, options: .mappedIfSafe) else {
            try? fm.removeItem(at: tmp)
            throw URLError(.cannotDecodeContentData)
        }
        // Not "tried anyway": a download that is not the pinned file is not
        // loaded, not kept, and the caller tries again later.
        if let why = TurnModelCatalog.rejection(model, data: data) {
            try? fm.removeItem(at: tmp)
            Log.write("smart turn: REFUSED the download of \(model.file) — \(why)")
            throw TurnModelCatalog.Refused(model: model.name, why: why)
        }
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        try fm.moveItem(at: tmp, to: file)
        Log.write("smart turn: \(model.name) saved (\(data.count) bytes)")
        return file
    }
}
