import Foundation
import MoeMeeting
import Testing
@testable import Moe

/// "Write the notes" on a meeting that has none: the record's state decides
/// whether the button is there, pressing it runs the notes writer on the
/// saved transcript, and a failure is a sentence with Try again — with
/// nothing on disk changed.
struct MeetingNotesWriterTests {

    /// A brain that answers from a script, one reply per call.
    actor ScriptedBrain: MeetingBrain {
        private var replies: [Result<String, Error>]
        private(set) var asked: [String] = []
        init(_ replies: [Result<String, Error>]) { self.replies = replies }
        func complete(system: String, user: String) async throws -> String {
            asked.append(user)
            guard !replies.isEmpty else { throw Down() }
            return try replies.removeFirst().get()
        }
    }
    struct Down: Error, LocalizedError { var errorDescription: String? { "the gateway is not answering" } }

    static let notes = #"""
    {"title":"Hanoi trip planning","summary":"Dana and you agreed the dates and who books what.",
     "decisions":["Fly on the 30th"],
     "action_items":[{"who":"Dana","what":"Book the flights","when":"Friday"}],"todos":[],"open_questions":[]}
    """#
    static let transcriptText = "[00:00:03] You: Shall we fly on the 30th?\n[00:00:09] Speaker 1: Yes. I will book the flights by Friday.\n"

    /// A meeting folder as a failed finish leaves it.
    static func meeting(failure: String? = "writing the notes did not finish within 240 s",
                        incomplete: Bool = false, transcript: String? = transcriptText) throws -> (URL, MeetingRecord) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-notes-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var record = MeetingRecord(startedAt: Date(timeIntervalSince1970: 1_762_900_000), durationSeconds: 1500,
                                   folder: folder.path, driftNote: "Clocks agreed to within 12 ms.",
                                   summaryFailure: failure)
        record.incomplete = incomplete
        try record.json().write(to: folder.appendingPathComponent("meeting.json"))
        if let transcript {
            try transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        }
        return (folder, record)
    }

    static func onDisk(_ folder: URL) throws -> MeetingRecord {
        try MeetingRecord.decoder().decode(MeetingRecord.self,
                                           from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
    }

    // MARK: Which meetings get the button

    @Test func aMeetingWhoseNotesTookTooLongIsOfferedIt() throws {
        let (folder, record) = try Self.meeting()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(MeetingListing.blurb(record).hasPrefix("No notes"))
        #expect(MeetingNotesWriter.isOffered(for: record))
        #expect(MeetingNotesWriter.buttonTitle(.idle) == "Write the notes")
    }

    @Test func aMeetingStoppedEarlyIsOfferedIt() throws {
        let (folder, record) = try Self.meeting(failure: "Moe quit while the meeting was being recorded", incomplete: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(MeetingListing.blurb(record) == "Stopped early — transcript only.")
        #expect(MeetingNotesWriter.isOffered(for: record))
    }

    @Test func aMeetingWithNotesOrWithNothingToReadIsNot() throws {
        let (noTranscript, r1) = try Self.meeting(transcript: nil)
        defer { try? FileManager.default.removeItem(at: noTranscript) }
        #expect(!MeetingNotesWriter.isOffered(for: r1))

        let (empty, r2) = try Self.meeting(transcript: "  \n")
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!MeetingNotesWriter.isOffered(for: r2))

        let (folder, base) = try Self.meeting()
        defer { try? FileManager.default.removeItem(at: folder) }
        var withNotes = base
        withNotes.notes = MeetingNotes.parse(Self.notes)
        withNotes.summarised = true
        #expect(!MeetingNotesWriter.isOffered(for: withNotes))

        // A record the pane made up for a folder whose meeting.json will not read.
        try Data("not json".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        #expect(!MeetingNotesWriter.isOffered(for: base))
    }

    // MARK: Pressing it

    @Test func pressingItWritesTheNotesFromTheSavedTranscript() async throws {
        let (folder, record) = try Self.meeting()
        defer { try? FileManager.default.removeItem(at: folder) }
        let brain = ScriptedBrain([.success(Self.notes)])
        let state = await MeetingNotesWriter.write(folder: folder, brain: brain, pauseBetween: .zero)
        #expect(state == .idle)

        let asked = await brain.asked
        #expect(asked.count == 1)
        #expect(asked[0].contains("I will book the flights by Friday"), "the brain reads the saved transcript")

        let now = try Self.onDisk(folder)
        #expect(now.summarised)
        #expect(now.summaryFailure == nil)
        #expect(now.summaryFile == "summary.md")
        #expect(now.notes?.summary == "Dana and you agreed the dates and who books what.")
        #expect(now.notes?.actionItems.map(\.what) == ["Book the flights"])
        #expect(now.startedAt == record.startedAt && now.durationSeconds == record.durationSeconds)
        let markdown = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(markdown.contains("Book the flights"))
        #expect(markdown.contains("Clocks agreed to within 12 ms."), "what the record knew about the recording is in the footer")
        #expect(markdown.contains(MeetingNotesRewrite.footerLine))
        // The transcript is the record: never touched.
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8) == Self.transcriptText)
        // And the button goes, and the list's line is the summary.
        #expect(!MeetingNotesWriter.isOffered(for: now))
        #expect(MeetingListing.blurb(now) == "Dana and you agreed the dates and who books what.")
    }

    @Test func aBrainThatCannotBeReachedIsASentenceAndTryAgain() async throws {
        let (folder, _) = try Self.meeting(incomplete: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))

        let state = await MeetingNotesWriter.write(folder: folder, brain: ScriptedBrain([]), pauseBetween: .zero)
        guard case .failed(let sentence) = state else { Issue.record("no failure: \(state)"); return }
        #expect(sentence == "Your AI could not be reached, so the notes were not written. The transcript is still here.")
        #expect(!sentence.contains("gateway") && !sentence.contains("/"), "no error text, no path")
        #expect(MeetingNotesWriter.buttonTitle(state) == "Try again")
        #expect(MeetingNotesWriter.line(state) == sentence)
        // Nothing on disk changed, so trying again starts from the same place.
        #expect(try Data(contentsOf: folder.appendingPathComponent("meeting.json")) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("summary.md").path))
        let untouched = try Self.onDisk(folder)
        #expect(MeetingNotesWriter.isOffered(for: untouched))

        // Try again, with the brain back.
        let again = await MeetingNotesWriter.write(folder: folder, brain: ScriptedBrain([.success(Self.notes)]),
                                                   pauseBetween: .zero)
        #expect(again == .idle)
        let now = try Self.onDisk(folder)
        #expect(now.summarised)
        #expect(now.incomplete, "it was still stopped early; that stays true")
    }

    @Test func aReplyThatIsNotNotesIsAskedForOnceMoreThenSaidPlainly() async throws {
        let (folder, _) = try Self.meeting()
        defer { try? FileManager.default.removeItem(at: folder) }
        let prose = ScriptedBrain([.success("Sure! Here are your notes."), .success("Still prose.")])
        let state = await MeetingNotesWriter.write(folder: folder, brain: prose, pauseBetween: .zero)
        #expect(state == .failed("Your AI answered, but not with notes. The transcript is still here."))
        #expect(await prose.asked.count == 2)

        let second = ScriptedBrain([.success("Sure! Here are your notes."), .success(Self.notes)])
        #expect(await MeetingNotesWriter.write(folder: folder, brain: second, pauseBetween: .zero) == .idle)
    }

    /// `transcriptFile` comes out of a file anyone can edit.
    @Test func aRecordPointingOutsideItsFolderIsNotRead() async throws {
        let (folder, base) = try Self.meeting()
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = base
        record.transcriptFile = "../../../../etc/hosts"
        try record.json().write(to: folder.appendingPathComponent("meeting.json"))
        let brain = ScriptedBrain([.success(Self.notes)])
        let result = await MeetingNotesRewrite.run(folder: folder, brain: brain)
        #expect(result == .failure(.noTranscript))
        #expect(await brain.asked.isEmpty)
    }

    /// The developer's tool and the pane are one implementation.
    @Test func theRedoToolCallsTheSameWriter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tool = try String(contentsOf: root.appendingPathComponent("Sources/MeetingNotesRedo/main.swift"), encoding: .utf8)
        #expect(tool.contains("MeetingNotesRewrite.run("))
        #expect(!tool.contains("MeetingSummaryPrompt.user("), "the tool has its own copy of the writer again")
        let pane = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Meeting/MeetingsPane.swift"), encoding: .utf8)
        #expect(pane.contains("MeetingNotesWriter.write("))
    }
}
