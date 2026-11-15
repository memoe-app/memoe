import Foundation
import MoeMeeting

/// "Write the notes" on a meeting that has none (the Meetings pane).
///
/// A meeting whose notes failed, or that was stopped early, used to keep
/// "Transcript saved. Writing the notes took too long, so there are none."
/// for good: the transcript was on disk and the only thing that could read
/// it again was a developer's `swift run` tool the app never shipped. The
/// work is `MeetingNotesRewrite` in MoeMeeting, which that tool calls too;
/// this is what the pane shows around it.
enum MeetingNotesWriter {

    enum State: Equatable {
        case idle
        case writing
        /// A sentence for the person; the button under it says Try again.
        case failed(String)
    }

    /// Whether the button is there at all: no notes, and a record and a
    /// transcript to write them from. Reads the folder, so off the main
    /// thread (`MeetingDetail` asks in a task).
    static func isOffered(for record: MeetingRecord) -> Bool {
        MeetingNotesRewrite.isOffered(for: record, folder: URL(fileURLWithPath: record.folder, isDirectory: true))
    }

    static func buttonTitle(_ state: State) -> String {
        switch state {
        case .idle: return "Write the notes"
        case .writing: return "Writing the notes…"
        case .failed: return "Try again"
        }
    }

    /// What is said beside the button.
    static func line(_ state: State) -> String {
        switch state {
        case .idle:
            return "The transcript was saved. Your AI can read it and write the notes now."
        case .writing:
            return "Reading the transcript and writing the notes. A long meeting takes a couple of minutes; you can leave this page."
        case .failed(let why):
            return why
        }
    }

    /// Runs the writer on the saved transcript. `.idle` means the notes are
    /// on disk and the pane should reload the record; anything else is the
    /// sentence to show, with nothing on disk changed.
    static func write(folder: URL, brain: MeetingBrain,
                      pauseBetween: Duration = .seconds(3)) async -> State {
        switch await MeetingNotesRewrite.run(folder: folder, brain: brain, pauseBetween: pauseBetween) {
        case .success(let done):
            Log.write("meeting: notes written from the saved transcript of \(folder.lastPathComponent) "
                      + "(\(done.attempts) attempt\(done.attempts == 1 ? "" : "s"))")
            return .idle
        case .failure(let failure):
            Log.write("meeting: notes for \(folder.lastPathComponent) were not written — \(failure.detail)")
            return .failed(failure.sentence)
        }
    }
}
