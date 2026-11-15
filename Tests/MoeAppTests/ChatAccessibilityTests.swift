import Foundation
import Testing
import MoeChat
@testable import Moe

/// Chat to VoiceOver (deep dive §2.11): one stop per message that says who,
/// when and what, without the markdown it was written in.
@MainActor
struct ChatAccessibilityTests {

    @Test func aMessageIsSpokenAsWhoWhenAndWhat() {
        let at = Date()
        let moe = Turn(role: .moe, text: "Booked **Nopa** for 7.\nSee you there.", at: at)
        let spoken = TurnRow.spoken(moe)
        #expect(spoken == "Moe, \(ChatTime.clock(at)): Booked Nopa for 7. See you there.")
        #expect(!spoken.contains("**"))

        let yours = Turn(role: .you, text: "Book Nopa", at: at)
        #expect(TurnRow.spoken(yours).hasPrefix("You, "))
    }

    @Test func attachmentsAreCounted() {
        var t = Turn(role: .you, text: "Look at this")
        t.attachments = [ChatAttachment(path: "/tmp/a.png", name: "a.png", kind: .image)]
        #expect(TurnRow.spoken(t).hasSuffix("With 1 attachment."))
    }

    @Test func aNoteIsJustItsWords() {
        #expect(TurnRow.spoken(Turn(role: .system, text: "*Stopped.*")) == "Stopped.")
    }
}
