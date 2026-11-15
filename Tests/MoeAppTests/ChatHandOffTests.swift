import AppKit
import Foundation
import Testing
import MoeChat
@testable import Moe

/// ⌘J hands the notch's conversation to the window and keeps what was
/// waiting in the box (the owner's answer 1, 2026-11-13).
@MainActor
struct ChatHandOffTests {

    @Test func theDraftAndItsFilesGoToTheWindow() throws {
        try StallGuardConductorTests.requireScratchHome()
        let c = Conductor(config: Config())
        let file = ChatAttachment(path: "/tmp/menu.pdf", name: "menu.pdf", kind: .file)
        c.handOffDraft(text: "and ask if they have a terrace", attachments: [file])
        #expect(c.chatDraft == "and ask if they have a terrace")
        #expect(c.chatDraftAttachments == [file])
    }

    /// Files alone go too; an empty box leaves Chat's own draft alone.
    @Test func filesAloneAndNothingAtAll() throws {
        try StallGuardConductorTests.requireScratchHome()
        let c = Conductor(config: Config())
        c.handOffDraft(text: "  ", attachments: [])
        #expect(c.chatDraft == nil)
        #expect(c.chatDraftAttachments.isEmpty)
        let shot = ChatAttachment(path: "/tmp/shot.png", name: "shot.png", kind: .image)
        c.handOffDraft(text: "", attachments: [shot])
        #expect(c.chatDraft == nil)
        #expect(c.chatDraftAttachments == [shot])
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 38)!
    }

    @Test func onlyCommandJIsTheKey() {
        #expect(KeyWatch.matches(key("j", .command), key: "j"))
        #expect(!KeyWatch.matches(key("j", []), key: "j"))
        #expect(!KeyWatch.matches(key("j", [.command, .shift]), key: "j"))
        #expect(!KeyWatch.matches(key("k", .command), key: "j"))
    }
}
