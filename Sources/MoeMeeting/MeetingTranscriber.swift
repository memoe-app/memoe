import FluidAudio
import Foundation
import MoeComponents

/// The speech recogniser a meeting borrows from the app. `Moe` conforms
/// its already-loaded Parakeet backend, so the model is loaded once; the
/// CLI conforms a fresh manager; tests conform a stub.
public protocol MeetingAsr: Sendable {
    /// 16 kHz mono in, tokens with times relative to the buffer out.
    func transcribeTimed(_ samples16k: [Float]) async throws -> [TimedToken]
}

/// Speaker diarization over the whole system stream, run once at the end.
public protocol MeetingDiarizer: Sendable {
    func diarize(_ samples16k: [Float]) async throws -> [SpeakerSpan]
}

/// FluidAudio's diarizer (pyannote segmentation + WeSpeaker embeddings,
/// ~13 files downloaded once). Loads on first use; 0.5 s warm.
public final class FluidDiarizer: MeetingDiarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var manager: DiarizerManager?

    public init() {}

    public func diarize(_ samples16k: [Float]) async throws -> [SpeakerSpan] {
        let m = try await load()
        let result = try m.performCompleteDiarization(samples16k, sampleRate: Int(meetingSampleRate))
        return result.segments.map {
            SpeakerSpan($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds))
        }
    }

    private func load() async throws -> DiarizerManager {
        if let existing = lock.withLock({ manager }) { return existing }
        // On disk first, by Memoe's own fetcher — pinned and hash-checked —
        // so FluidAudio below finds it and downloads nothing itself. A build
        // that carries the model returns at once. Offline in a slim build
        // this throws a sentence a person can read, and the caller records
        // it and keeps the notes without speaker names.
        try await ComponentFetcher.shared.ensure(ComponentCatalog.speakerDiarization,
                                                 in: ComponentCatalog.modelsRoot)
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager(config: DiarizerConfig(minSpeechDuration: 0.5))
        m.initialize(models: models)
        lock.withLock { manager = m }
        return m
    }
}

extension TimedToken {
    public init(_ t: TokenTiming) {
        self.init(t.token, t.startTime, t.endTime)
    }
}

/// Transcribes a meeting as it happens: every `windowSeconds` (30 s) the
/// audio written since the last window is read back from each WAV, cut at
/// its quietest point so the window ends in a pause, and recognised; the
/// segments are kept in memory and appended to `transcript.txt` as they
/// come. At stop the remainder is transcribed, diarization runs on the
/// whole system stream, "them" becomes "them (speaker N)", and the file is
/// rewritten with the final labels.
public final class MeetingTranscriber: @unchecked Sendable {

    public let folder: URL
    public var transcriptURL: URL { folder.appendingPathComponent("transcript.txt") }
    public let windowSeconds: Double
    /// The echo canceller takes about a second to converge after the mic
    /// engine starts; until then the far end leaks into the mic at full
    /// level (-20 dBFS on the spike's recording, 0.3–1.2 s). That stretch
    /// is treated as silence so "them" is never also "you".
    public var micWarmUpSeconds: Double = 1.5
    private let asr: MeetingAsr
    private let diarizer: MeetingDiarizer?
    private let lock = NSLock()
    private var segments: [Segment] = []
    /// Every recognised token of the system stream, in the meeting clock,
    /// so the final pass can split lines where the diarizer says the
    /// speaker changed — not only between recognised segments.
    private var themTokens: [TimedToken] = []
    private var consumed: [MeetingRecorder.Stream: Int] = [.system: 0, .mic: 0]
    private var written = 0
    /// How many speakers the diarizer found, once it has run.
    private(set) public var diarizedSpeakers: Int?
    /// Notes worth carrying into the record: a diarizer that failed, say.
    private(set) public var warnings: [String] = []

    /// Called on any thread with the whole timeline so far, after each window.
    public var onUpdate: (([Segment]) -> Void)?

    /// Ten seconds, not thirty.
    ///
    /// A window is only recognised once it is *full*, so the wait before a
    /// sentence appears is up to a whole window plus the poll interval —
    /// thirty seconds meant a line you had just said showed up twenty
    /// seconds later, which is far too late to be reading along with a call.
    ///
    /// The cost is real but small. Parakeet runs at roughly 190× realtime on
    /// Apple silicon, so ten seconds of audio is about fifty milliseconds of
    /// work; tripling the number of passes is nothing. What genuinely
    /// suffers is diarisation, which clusters speakers within a window and
    /// has less to cluster from — speaker numbering can drift more between
    /// windows on a busy call. Reading along in near-real-time is worth more
    /// than perfectly stable "#2" labels, and the labels are re-derived for
    /// the saved transcript at the end anyway.
    public init(folder: URL, asr: MeetingAsr, diarizer: MeetingDiarizer?, windowSeconds: Double = 10) {
        self.folder = folder
        self.asr = asr
        self.diarizer = diarizer
        self.windowSeconds = windowSeconds
    }

    public var timeline: [Segment] { lock.withLock { segments } }

    /// Frames available and not yet transcribed, per stream.
    public func pending(available: (MeetingRecorder.Stream) -> Int) -> [MeetingRecorder.Stream: Int] {
        lock.withLock {
            var out: [MeetingRecorder.Stream: Int] = [:]
            for s in MeetingRecorder.Stream.allCases { out[s] = available(s) - (consumed[s] ?? 0) }
            return out
        }
    }

    /// One live pass: transcribe a full window from each stream that has
    /// one. `final` takes whatever is left instead. Returns true if
    /// anything was recognised.
    @discardableResult
    public func tick(available: (MeetingRecorder.Stream) -> Int,
                     url: (MeetingRecorder.Stream) -> URL, final: Bool = false) async -> Bool {
        let windowFrames = Int(windowSeconds * meetingSampleRate)
        var any = false
        for stream in MeetingRecorder.Stream.allCases {
            let from = lock.withLock { consumed[stream] ?? 0 }
            let have = available(stream) - from
            guard have > 0, final || have >= windowFrames else { continue }
            let want = final ? have : windowFrames
            guard var samples = try? Wav.readFrames(url(stream), from: from, count: want), !samples.isEmpty else { continue }
            var cut = samples.count
            if !final { cut = Windowing.bestCut(samples); samples.removeSubrange(cut...) }
            lock.withLock { consumed[stream] = from + cut }
            if stream == .mic {
                let warm = Int(micWarmUpSeconds * meetingSampleRate) - from
                if warm > 0 { for i in 0..<min(warm, samples.count) { samples[i] = 0 } }
            }
            // Not merely "not silent": the echo-cancelled mic still carries
            // the far end faintly, and a recogniser fed that invents words.
            //
            // The window's own noise floor, measured once here, is both the
            // baseline for this gate and the baseline every segment of this
            // window is judged against below — a segment cannot supply its
            // own (see `segmentHasSpeech`).
            let baseline = Windowing.noiseFloorDb(samples)
            if !Windowing.hasSpeech(samples, noiseFloorDb: baseline) { continue }
            let offset = Double(from) / meetingSampleRate
            do {
                let tokens = try await asr.transcribeTimed(samples)
                let speaker: Speaker = stream == .mic ? .you : .them(nil)
                // Every line must stand on audio that has speech energy of
                // its own; a recogniser given a window with one loud second
                // will happily write sentences over the quiet rest of it.
                let fresh = Timeline.segments(from: tokens, speaker: speaker, offset: offset)
                    .filter { Self.segmentHasSpeech($0, in: samples, offset: offset, noiseFloorDb: baseline) }
                guard !fresh.isEmpty else { continue }
                // The same rule applies to the tokens kept for the final
                // pass: a token whose segment was dropped as hallucinated
                // must not come back when "them" is rebuilt per speaker.
                let kept = tokens.filter { tok in
                    fresh.contains { $0.start - 0.05 <= tok.start + offset && tok.end + offset <= $0.end + 0.05 }
                }
                lock.withLock {
                    segments = Timeline.merge(segments, fresh)
                    if stream == .system {
                        themTokens += kept.map { TimedToken($0.token, $0.start + offset, $0.end + offset) }
                    }
                }
                any = true
            } catch {
                lock.withLock { warnings.append("transcription failed at \(Timeline.clock(offset)): \(error)") }
            }
        }
        if any {
            appendNewLines()
            onUpdate?(timeline)
        }
        return any
    }

    /// The audio under a segment (with 100 ms of slack either side) has
    /// at least two 100 ms frames that stand out from the room.
    ///
    /// `noiseFloorDb` is the *enclosing window's* noise floor and this
    /// function must never be asked to work without it. A segment's span
    /// is the segment plus 100 ms of slack: its quietest tenth is either
    /// speech or that slack, and the slack in a padded window is digital
    /// silence at -200 dBFS. Either way a segment measured against itself
    /// has a baseline that passes everything, which is the whole filter
    /// gone — silently, on exactly the hallucinated lines it exists to
    /// drop.
    static func segmentHasSpeech(_ seg: Segment, in samples: [Float], offset: Double,
                                 noiseFloorDb: Float?) -> Bool {
        let a = max(0, Int((seg.start - offset - 0.1) * meetingSampleRate))
        let b = min(samples.count, Int((seg.end - offset + 0.1) * meetingSampleRate))
        guard b > a else { return false }
        return Windowing.hasSpeech(Array(samples[a..<b]), minFrames: 2, noiseFloorDb: noiseFloorDb)
    }

    /// Append lines not yet on disk. Segments only ever arrive at the end of
    /// the timeline by stream, but the merge interleaves two streams, so
    /// the file is the timeline in arrival order and gets rewritten in
    /// time order at `finish`.
    private func appendNewLines() {
        let (all, start) = lock.withLock { () -> ([Segment], Int) in
            let start = written
            written = segments.count
            return (segments, start)
        }
        guard start < all.count else { return }
        let text = all[start...].map(\.line).joined(separator: "\n") + "\n"
        if let h = try? FileHandle(forWritingTo: transcriptURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
        } else {
            FileManager.default.createFile(atPath: transcriptURL.path, contents: Data(text.utf8),
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    /// The end of the meeting: transcribe the remainder, diarize the
    /// system stream, relabel, rewrite `transcript.txt` in time order.
    public func finish(available: (MeetingRecorder.Stream) -> Int,
                       url: (MeetingRecorder.Stream) -> URL, pauses: PauseLog = PauseLog()) async -> [Segment] {
        await tick(available: available, url: url, final: true)
        if let diarizer {
            do {
                let system = try Wav.read(url(.system))
                if Windowing.hasSpeech(system) {
                    let spans = try await diarizer.diarize(system)
                    let lookup = Timeline.speakerLookup(spans)
                    lock.withLock {
                        diarizedSpeakers = Set(spans.map(\.speakerID)).count
                        // Rebuild "them" from the tokens with the speaker
                        // per token; "you" lines are kept as they are.
                        let you = segments.filter(\.speaker.isYou)
                        let them = Timeline.segments(from: themTokens, speakerAt: lookup)
                        segments = Timeline.merge(you, them)
                    }
                }
            } catch {
                // A component that could not be fetched explains itself in
                // a whole sentence; anything else keeps its raw description.
                let said = (error as? ComponentError)?.localizedDescription ?? "diarization failed: \(error)"
                lock.withLock { warnings.append(said) }
            }
        }
        // Off the record: the audio was already silence, but a window that
        // straddled the pause may have a line starting inside it.
        if !pauses.spans.isEmpty {
            lock.withLock { segments.removeAll { pauses.covers($0.start) } }
        }
        // Both streams are in now, so the far end is finally there to
        // compare against — the echo can only be recognised once its
        // original exists.
        lock.withLock { segments = Timeline.withoutEcho(segments) }
        let final = timeline
        let text = Timeline.format(final) + (final.isEmpty ? "" : "\n")
        try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
        onUpdate?(final)
        return final
    }
}
