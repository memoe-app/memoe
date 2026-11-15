import Foundation
import MoeIsland
import SwiftUI
import Testing
@testable import Moe

/// VoiceOver and Reduce Motion outside the island: the words a row is read
/// as, the keys that walk the Inbox, and the one switch that stops things
/// sliding. What VoiceOver actually says is only provable with VoiceOver on;
/// these hold the parts that are plain functions.
struct AccessOutsideTheIslandTests {

    static func notice(_ text: String, kind: String = "", _ change: (inout InboxItem) -> Void = { _ in }) -> InboxItem {
        var i = NoticeInput(text: text, at: Date(timeIntervalSince1970: 1_762_900_000))
        i.kind = kind
        i.job = "dentist"; i.jobID = "j1"
        var n = NoticeMaker.make(i, id: "n1")
        change(&n)
        return n
    }

    @Test func anInboxRowIsReadAsOneSentence() {
        let n = Self.notice("Call the dentist before five.", kind: "reminder")
        let said = InboxPane.spoken(n, picking: false, picked: false)
        #expect(said.hasPrefix("Unread. Reminder. Call the dentist before five."))
        #expect(!said.contains("alarm"), "the glyph's name is not read")
    }

    @Test func aReadRowDoesNotSayUnreadAndAFinishedOneSaysHow() {
        let read = Self.notice("Call the dentist before five.", kind: "reminder") { $0.seen = true }
        #expect(InboxPane.spoken(read, picking: false, picked: false).hasPrefix("Reminder. "))
        let done = Self.notice("Call the dentist before five.", kind: "reminder") {
            $0.status = .done; $0.outcome = InboxGate.outcome
        }
        let said = InboxPane.spoken(done, picking: false, picked: false)
        #expect(said.hasSuffix(". Kept quiet"))
        #expect(!said.contains("Unread"))
    }

    @Test func whileSelectingARowSaysWhetherItIsPicked() {
        let n = Self.notice("Call the dentist before five.", kind: "reminder")
        #expect(InboxPane.spoken(n, picking: true, picked: true).hasPrefix("Selected. "))
        #expect(InboxPane.spoken(n, picking: true, picked: false).hasPrefix("Not selected. "))
    }

    @Test func markdownIsNotReadAloud() {
        let n = Self.notice("**Marketing brief, Tue**\nThe `r/mac` thread has three replies and one of them asks for a link to the download page.")
        let said = InboxPane.spoken(n, picking: false, picked: false)
        #expect(!said.contains("**") && !said.contains("`"))
    }

    // MARK: ↑ and ↓ in the Inbox

    @Test func theArrowKeysWalkTheListAndStopAtItsEnds() {
        let ids = ["a", "b", "c"]
        #expect(InboxPane.neighbour(of: nil, in: ids, by: 1) == "a", "nothing open: the first row")
        #expect(InboxPane.neighbour(of: "a", in: ids, by: 1) == "b")
        #expect(InboxPane.neighbour(of: "b", in: ids, by: -1) == "a")
        #expect(InboxPane.neighbour(of: "a", in: ids, by: -1) == "a", "no wrapping off the top")
        #expect(InboxPane.neighbour(of: "c", in: ids, by: 1) == "c", "nor off the bottom")
        #expect(InboxPane.neighbour(of: "gone", in: ids, by: 1) == "a", "the open row was finished meanwhile")
        #expect(InboxPane.neighbour(of: "a", in: [], by: 1) == nil)
    }

    // MARK: Meetings

    @Test func aMeetingsLengthIsSpokenAsALength() {
        #expect(MeetingsPane.spokenLength(20) == "Under a minute")
        #expect(MeetingsPane.spokenLength(60) == "1 minute")
        #expect(MeetingsPane.spokenLength(42 * 60 + 7) == "42 minutes")
        #expect(MeetingsPane.spokenLength(3600) == "1 hour")
        #expect(MeetingsPane.spokenLength(3600 + 61) == "1 hour 1 minute")
        #expect(MeetingsPane.spokenLength(2 * 3600 + 30 * 60) == "2 hours 30 minutes")
    }

    // MARK: Reduce Motion

    @Test func reduceMotionTakesTheAnimationAway() {
        #expect(CalmMotion.animation(.easeOut(duration: 0.2), reduced: true) == nil)
        #expect(CalmMotion.animation(.easeOut(duration: 0.2), reduced: false) == .easeOut(duration: 0.2))
    }

    @Test func aChangeStillHappensWithMotionReduced() {
        var done = false
        CalmMotion.animate(.easeOut(duration: 0.2), reduced: true) { done = true }
        #expect(done)
    }

    /// The places that slide ask first, and stay asking.
    @Test func whatSlidesAsksAboutReduceMotion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let inbox = try source("Sources/Moe/Inbox/IslandInbox.swift")
        #expect(inbox.contains(".calmAnimation("))
        #expect(!inbox.contains("\n        .animation("), "the inbox list animates without asking again")
        let memory = try source("Sources/Moe/Memory/MemoryPane.swift")
        #expect(!memory.contains("withAnimation("), "Memory slides without asking again")
        #expect(try source("Sources/Moe/Settings/HumanLever.swift").contains(".calmAnimation("))
    }

    /// Icon-only controls in the files this covers carry a name.
    @Test func iconOnlyControlsAreNamed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let wanted: [(String, [String])] = [
            ("Sources/Moe/Inbox/IslandInbox.swift", ["accessibilityLabel(\"Dismiss\")", "\"Inbox\"", "children: .combine"]),
            ("Sources/Moe/Inbox/NoticeCard.swift", ["accessibilityLabel(\"Close\")", "accessibilityLabel(\"Ask Moe about this\")"]),
            ("Sources/Moe/Inbox/InboxPane.swift", ["accessibilityActions", "Button(\"Archive\")", ".onMoveCommand"]),
            ("Sources/Moe/Meeting/MeetingsPane.swift", ["\"Back to all meetings\"", "\"Delete this meeting\""]),
            ("Sources/Moe/Memory/MemoryRows.swift", ["accessibilityLabel(\"Forget this\")"]),
            ("Sources/Moe/UI/PaneHeader.swift", ["accessibilityLabel(\"Clear search\")"]),
            ("Sources/Moe/Settings/VoicePane.swift", ["accessibilityLabel(\"Hear this voice\")"]),
        ]
        for (path, needles) in wanted {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for needle in needles { #expect(text.contains(needle), "\(path) lost \(needle)") }
        }
    }
}
