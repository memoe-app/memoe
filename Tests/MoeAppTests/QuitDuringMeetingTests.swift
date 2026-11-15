import Foundation
import Testing
@testable import Moe

/// ⌘Q with a meeting on the record used to abandon it — recording kept, no
/// notes, nothing said. Quit asks first; this is the decision it makes.
struct QuitDuringMeetingTests {
    @Test func aRecordingMeetingIsAskedAbout() {
        #expect(QuitDuringMeeting.decide(meeting: .recording(since: Date())) == .ask(.recording))
    }

    @Test func notesBeingWrittenAreAskedAbout() {
        #expect(QuitDuringMeeting.decide(meeting: .stopping) == .ask(.writingNotes))
    }

    @Test func nothingElseStandsInTheWayOfQuit() {
        let url = URL(fileURLWithPath: "/tmp/summary.md")
        for state in [Conductor.MeetingState.off, .starting, .done(url: url)] {
            #expect(QuitDuringMeeting.decide(meeting: state) == .quit)
            #expect(QuitDuringMeeting.notesAreSettled(state))
        }
        #expect(!QuitDuringMeeting.notesAreSettled(.stopping))
        #expect(!QuitDuringMeeting.notesAreSettled(.recording(since: Date())))
    }

    /// Three ways out, in the order the alert shows them — and the safe one
    /// is the default button, so Return never costs the notes.
    @Test func theButtonsMeanWhatTheySay() {
        for question in [QuitDuringMeeting.Question.recording, .writingNotes] {
            let words = QuitDuringMeeting.wording(question)
            #expect(words.buttons.count == 3)
            #expect(words.buttons[1] == "Quit Anyway")
            #expect(words.buttons[2] == "Cancel")
            #expect(words.title.hasPrefix("Memoe "), "the app is Memoe")
            #expect(words.detail.contains("kept"), "it says what survives")
        }
        #expect(QuitDuringMeeting.wording(.recording).buttons[0] == "Stop and Write Notes")
        #expect(QuitDuringMeeting.answer(buttonIndex: 0) == .notesThenQuit)
        #expect(QuitDuringMeeting.answer(buttonIndex: 1) == .quitAnyway)
        #expect(QuitDuringMeeting.answer(buttonIndex: 2) == .cancel)
        // Escape, or anything unexpected, is never a quit.
        #expect(QuitDuringMeeting.answer(buttonIndex: -1) == .cancel)
        #expect(QuitDuringMeeting.answer(buttonIndex: 7) == .cancel)
    }

    // MARK: After "Stop and Write Notes": the notes, then the send

    static let done = Conductor.MeetingState.done(url: URL(fileURLWithPath: "/tmp/summary.md"))
    static let t0 = Date(timeIntervalSince1970: 1_762_900_000)

    @Test func itWaitsForTheNotesAndSaysSo() {
        var waiting = QuitDuringMeeting.Waiting()
        let next = QuitDuringMeeting.next(meeting: .stopping, delivering: false, waiting: &waiting, now: Self.t0)
        guard case .wait(let what) = next else { Issue.record("quit before the notes: \(next)"); return }
        #expect(what.contains("notes"))
        #expect(waiting.deliverySince == nil)
    }

    @Test func withNothingToSendItQuitsOnceTheNotesAreDown() {
        var waiting = QuitDuringMeeting.Waiting()
        #expect(QuitDuringMeeting.next(meeting: Self.done, delivering: false, waiting: &waiting, now: Self.t0)
                == .quit("the meeting notes are settled"))
    }

    /// The bug: the notes were on disk, the Telegram send had just started,
    /// and the quit went.
    @Test func aSendInTheAirHoldsTheQuitAndTheWindowSaysWhatFor() {
        var waiting = QuitDuringMeeting.Waiting()
        let first = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting, now: Self.t0)
        guard case .wait(let what) = first else { Issue.record("quit with the send in the air: \(first)"); return }
        #expect(what.contains("Telegram"))
        #expect(what.contains("20 seconds"))
        #expect(waiting.deliverySince == Self.t0)
        // Still going, twelve seconds on: the countdown is from the first look.
        let later = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting,
                                           now: Self.t0.addingTimeInterval(12))
        #expect(later == .wait("Your notes are written. Sending them to Telegram; Memoe quits when that is done, or in 8 seconds."))
        #expect(waiting.deliverySince == Self.t0)
    }

    @Test func itQuitsWhenTheSendFinishesOrFails() {
        var waiting = QuitDuringMeeting.Waiting()
        _ = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting, now: Self.t0)
        // Sent or failed, the Conductor clears the flag either way.
        let next = QuitDuringMeeting.next(meeting: Self.done, delivering: false, waiting: &waiting,
                                          now: Self.t0.addingTimeInterval(3))
        #expect(next == .quit("the meeting notes are settled and the Telegram send has finished"))
    }

    @Test func itDoesNotWaitForEver() {
        var waiting = QuitDuringMeeting.Waiting()
        _ = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting, now: Self.t0)
        let almost = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting,
                                            now: Self.t0.addingTimeInterval(QuitDuringMeeting.deliveryLimit - 0.5))
        guard case .wait(let what) = almost else { Issue.record("gave up early: \(almost)"); return }
        #expect(what.hasSuffix("or in 1 second."))
        let over = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting,
                                          now: Self.t0.addingTimeInterval(QuitDuringMeeting.deliveryLimit))
        guard case .quit(let why) = over else { Issue.record("still waiting at the limit: \(over)"); return }
        #expect(why.contains("may not have gone"), "the log must not claim it was sent")
        #expect(QuitDuringMeeting.deliveryLimit == 20)
    }

    /// The clock for the send starts when the notes are down, not while
    /// they are still being written.
    @Test func theSendClockStartsAfterTheNotes() {
        var waiting = QuitDuringMeeting.Waiting()
        _ = QuitDuringMeeting.next(meeting: .stopping, delivering: false, waiting: &waiting, now: Self.t0)
        let at = Self.t0.addingTimeInterval(90)
        _ = QuitDuringMeeting.next(meeting: Self.done, delivering: true, waiting: &waiting, now: at)
        #expect(waiting.deliverySince == at)
    }

    /// The wait reads a flag the Conductor has to set and clear.
    @Test func theConductorSaysWhenTheSendIsInTheAir() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Moe/Conductor.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func deliverNotesToTelegram("))
        let body = source[start.upperBound...].prefix(2200)
        #expect(body.contains("meetingDeliveryInFlight = true"))
        #expect(body.contains("meetingDeliveryInFlight = false"))
        let app = try String(contentsOf: root.appendingPathComponent("Sources/Moe/AppDelegate.swift"), encoding: .utf8)
        #expect(app.contains("delivering: conductor.meetingDeliveryInFlight"))
    }
}
