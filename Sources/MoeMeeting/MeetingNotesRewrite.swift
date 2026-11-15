import Foundation

/// Writes a meeting's notes again from its saved `transcript.txt`: the
/// current `MeetingSummaryPrompt`, the current dedupe in `ActionItemScan`,
/// and `summary.md` and the notes in `meeting.json` replaced.
///
/// Two callers, one implementation:
///
/// - **The Meetings pane's "Write the notes".** A meeting whose notes failed
///   ("Writing the notes took too long, so there are none.") or that was
///   stopped early kept that sentence for good; the transcript was there and
///   nothing in the app could read it again.
/// - **`swift run MeetingNotesRedo`**, the developer's tool this was moved
///   out of, for re-deriving old meetings after the prompt improves.
///
/// The transcript is never touched: it is the record, and everything here is
/// derived from it. A failure changes nothing on disk, so the meeting is
/// exactly as it was and can be tried again.
public enum MeetingNotesRewrite {

    public enum Failure: Error, Equatable, Sendable {
        /// `meeting.json` is missing or will not read.
        case noRecord
        /// `transcript.txt` is missing or empty.
        case noTranscript
        /// The brain could not be asked, or gave up. Its own words.
        case brain(String)
        /// The brain answered, and it was not notes.
        case notNotes(String)
        case couldNotWrite(String)

        /// For a person, in the Meetings pane. No path, no error code.
        public var sentence: String {
            switch self {
            case .noRecord:
                return "This meeting's record cannot be read, so there is nothing to write notes into."
            case .noTranscript:
                return "There is no transcript for this meeting, so there is nothing to write notes from."
            case .brain:
                return "Your AI could not be reached, so the notes were not written. The transcript is still here."
            case .notNotes:
                return "Your AI answered, but not with notes. The transcript is still here."
            case .couldNotWrite:
                return "The notes were written but could not be saved to this meeting's folder."
            }
        }

        /// For the log and the developer's tool.
        public var detail: String {
            switch self {
            case .noRecord: return "no readable meeting.json"
            case .noTranscript: return "transcript is empty or missing"
            case .brain(let why): return "brain unavailable: \(why)"
            case .notNotes(let excerpt): return "the reply was not notes: \(excerpt)"
            case .couldNotWrite(let why): return "could not write: \(why)"
            }
        }
    }

    public struct Done: Equatable, Sendable {
        /// The record as it now is on disk (or would be, on a dry run).
        public let record: MeetingRecord
        public let actionItemsBefore: Int
        public let attempts: Int
        public let written: Bool
    }

    /// The footer of a `summary.md` written when the notes are made here and
    /// the meeting had none to carry across.
    public static let footerLine =
        "Transcript: transcript.txt in this folder. Notes written by your AI from the transcript; check anything that matters."

    /// Whether this meeting is one whose notes can be written from the pane:
    /// it has none, and there is a record and a transcript to write them
    /// from. A meeting with notes is left to the developer's tool.
    public static func isOffered(for record: MeetingRecord, folder: URL) -> Bool {
        guard !hasNotes(record) else { return false }
        return (try? load(folder).get()) != nil
    }

    public static func hasNotes(_ record: MeetingRecord) -> Bool {
        guard record.summarised, let notes = record.notes else { return false }
        return !notes.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.actionItems.isEmpty || !notes.decisions.isEmpty
    }

    /// The footer lines of an existing `summary.md`, unwrapped from their
    /// italics, or none when the file has no footer or is not there. They
    /// are facts about the recording — drift, off-the-record spans, why the
    /// audio was kept — which this pass has no way to recompute and no
    /// business dropping.
    public static func existingFooter(_ summary: URL) -> [String] {
        guard let text = try? String(contentsOf: summary, encoding: .utf8),
              let block = text.components(separatedBy: "\n---\n\n").last,
              block != text else { return [] }
        return block.split(separator: "\n").map {
            var line = $0.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("_") { line.removeFirst() }
            if line.hasSuffix("_") { line.removeLast() }
            return line
        }.filter { !$0.isEmpty }
    }

    static func load(_ folder: URL) -> Result<(record: MeetingRecord, transcript: String), Failure> {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
              let record = try? MeetingRecord.decoder().decode(MeetingRecord.self, from: data) else {
            return .failure(.noRecord)
        }
        // `transcriptFile` is read out of a file anybody can edit: a plain
        // name inside this folder, or it is not this meeting's transcript.
        guard !record.transcriptFile.contains("/"), record.transcriptFile != "..",
              let transcript = try? String(contentsOf: folder.appendingPathComponent(record.transcriptFile),
                                           encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noTranscript)
        }
        return .success((record, transcript))
    }

    /// One meeting. `attempts` and `pauseBetween` are `NotesRequest`'s: a
    /// retired session and a reply in prose are both worth one more ask.
    public static func run(folder: URL, brain: MeetingBrain, dryRun: Bool = false,
                           attempts: Int = 2, pauseBetween: Duration = .seconds(3)) async -> Result<Done, Failure> {
        let loaded: (record: MeetingRecord, transcript: String)
        switch load(folder) {
        case .failure(let f): return .failure(f)
        case .success(let l): loaded = l
        }
        var record = loaded.record
        let summaryURL = folder.appendingPathComponent("summary.md")
        let recordURL = folder.appendingPathComponent("meeting.json")
        let before = record.notes?.actionItems.count ?? 0

        var ask = NotesRequest(
            system: MeetingSummaryPrompt.system,
            user: MeetingSummaryPrompt.user(transcript: loaded.transcript, date: record.startedAt,
                                            duration: record.durationSeconds, bookmarks: record.bookmarks))
        ask.attempts = attempts
        ask.pauseBetween = pauseBetween
        let reply: String
        let took: Int
        do {
            (reply, took) = try await ask.run(brain: brain)
        } catch {
            return .failure(.brain((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
        }
        guard var notes = MeetingNotes.parse(reply) else {
            return .failure(.notNotes(NotesRequest.excerpt(reply)))
        }
        // The summary's own list goes through the same sieve as a live
        // scan's, because a single pass over a long transcript repeats
        // itself too.
        notes.actionItems = ActionItemScan.merge(notes.actionItems, [])

        var footer = existingFooter(summaryURL)
        if footer.isEmpty {
            footer = [record.driftNote, footerLine].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let markdown = notes.markdown(date: record.startedAt, duration: record.durationSeconds,
                                      bookmarks: record.bookmarks, captures: record.captures, footer: footer)
        record.notes = notes
        record.summarised = true
        record.summaryFile = "summary.md"
        record.summaryFailure = nil
        guard !dryRun else {
            return .success(Done(record: record, actionItemsBefore: before, attempts: took, written: false))
        }
        do {
            try markdown.write(to: summaryURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
            try record.json().write(to: recordURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        } catch {
            return .failure(.couldNotWrite(error.localizedDescription))
        }
        return .success(Done(record: record, actionItemsBefore: before, attempts: took, written: true))
    }
}
