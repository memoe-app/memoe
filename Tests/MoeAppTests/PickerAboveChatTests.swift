import AppKit
import Testing
@testable import Moe

/// The + in the popped-out chat opened its file picker underneath the chat,
/// or on another desktop than the full-screen app in front, so pressing it
/// did nothing the owner could see (2026-11-14). The picker now sits above
/// the floating chat, below the island, and comes to the desktop in front.
@MainActor
struct PickerAboveChatTests {

    @Test func thePickerOpensAboveTheFloatingChatAndBelowTheIsland() {
        let chat = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel],
                           backing: .buffered, defer: true)
        FloatingChatWindow.applyLevel(chat, keepOnTop: true)
        let picker = NSWindow(contentRect: .zero, styleMask: [.titled],
                              backing: .buffered, defer: true)
        AttachmentIntake.raise(picker)

        #expect(picker.level > chat.level)
        let island = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 8)
        #expect(picker.level < island)
        #expect(picker.collectionBehavior.contains(.moveToActiveSpace))
        #expect(picker.collectionBehavior.contains(.fullScreenAuxiliary))
    }
}
