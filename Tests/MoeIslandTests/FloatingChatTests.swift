import CoreGraphics
import Foundation
import Testing
@testable import MoeIsland

/// The chat popped out of the notch (2026-11-13): where it is, where its
/// window goes, and what the notch card's header can hold.
struct FloatingChatTests {

    // MARK: - Placement

    /// Every event from every placement, written out: the table is the spec.
    @Test func everyTransition() {
        let out = ChatPlacement.floating(shown: true)
        let away = ChatPlacement.floating(shown: false)
        let table: [(ChatPlacement, ChatPlacementEvent, ChatPlacement)] = [
            (.notch, .detach, out), (.notch, .dock, .notch), (.notch, .close, .notch),
            (.notch, .summon, .notch), (.notch, .toggle, out),
            (out, .detach, out), (out, .dock, .notch), (out, .close, away),
            (out, .summon, out), (out, .toggle, .notch),
            (away, .detach, out), (away, .dock, .notch), (away, .close, away),
            (away, .summon, out), (away, .toggle, out),
        ]
        for (from, event, to) in table {
            #expect(FloatingChat.next(from, event) == to, "\(from) + \(event)")
        }
    }

    /// Esc and ✕ put the window away; the chat stays out of the notch, so a
    /// click on the notch brings the window back rather than a second card.
    @Test func closingKeepsTheChatOutOfTheNotch() {
        let closed = FloatingChat.next(.floating(shown: true), .close)
        #expect(closed.isDetached)
        #expect(!FloatingChat.notchOpensCard(closed, meetingOn: false, dictating: false))
        #expect(FloatingChat.next(closed, .summon) == .floating(shown: true))
    }

    /// Never two cards: while the chat is out the notch opens no card of its
    /// own — except a meeting's or a dictation's, which are not the chat.
    @Test func theNotchOpensNoSecondCard() {
        for p in [ChatPlacement.floating(shown: true), .floating(shown: false)] {
            #expect(!FloatingChat.notchOpensCard(p, meetingOn: false, dictating: false))
            #expect(FloatingChat.routesToWindow(p, meetingOn: false, dictating: false))
            #expect(FloatingChat.notchOpensCard(p, meetingOn: true, dictating: false))
            #expect(FloatingChat.notchOpensCard(p, meetingOn: false, dictating: true))
        }
        #expect(FloatingChat.notchOpensCard(.notch, meetingOn: false, dictating: false))
        #expect(!FloatingChat.routesToWindow(.notch, meetingOn: false, dictating: false))
    }

    @Test func theMenuSaysWhatTheShortcutWillDo() {
        #expect(FloatingChat.menuTitle(.notch, shortcut: "⌃⌥P") == "Pop Out Chat  (⌃⌥P)")
        #expect(FloatingChat.menuTitle(.floating(shown: false), shortcut: "⌃⌥P") == "Show Chat Window  (⌃⌥P)")
        #expect(FloatingChat.menuTitle(.floating(shown: true), shortcut: "⌃⌥P") == "Put Chat Back in the Notch  (⌃⌥P)")
    }

    // MARK: - Frames

    static let laptop = FloatingChatFrame.Screen(id: "laptop", visible: CGRect(x: 0, y: 0, width: 1512, height: 944))
    static let external = FloatingChatFrame.Screen(id: "external", visible: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    @Test func clampKeepsTheWholeWindowOnTheScreen() {
        let v = Self.laptop.visible
        // Dragged half off the right edge and below the Dock.
        let c = FloatingChatFrame.clamp(CGRect(x: 1400, y: -200, width: 420, height: 540), to: v)
        #expect(v.contains(c))
        #expect(c.size == CGSize(width: 420, height: 540))
        // Too small, too big.
        #expect(FloatingChatFrame.clamp(CGRect(x: 10, y: 10, width: 50, height: 50), to: v).size
                == FloatingChatFrame.minimum)
        let huge = FloatingChatFrame.clamp(CGRect(x: 0, y: 0, width: 5000, height: 5000), to: v)
        #expect(huge.width == FloatingChatFrame.maximum.width)
        #expect(huge.height == v.height)
        #expect(v.contains(huge))
    }

    /// A screen smaller than the window's minimum still gets a window that
    /// fits it, never one hanging off it.
    @Test func aTinyScreenStillGetsAWindowOnIt() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let c = FloatingChatFrame.clamp(CGRect(x: 0, y: 0, width: 420, height: 540), to: tiny)
        #expect(tiny.contains(c))
    }

    @Test func theFirstTimeOutIsTheTopRightCorner() {
        let f = FloatingChatFrame.initial(on: Self.laptop.visible)
        #expect(f.size == FloatingChatFrame.initialSize)
        #expect(f.maxX == Self.laptop.visible.maxX - FloatingChatFrame.margin)
        #expect(f.maxY == Self.laptop.visible.maxY - FloatingChatFrame.margin)
    }

    @Test func itOpensWhereItWasLeftOnThatScreen() throws {
        var m = FloatingChatMemory()
        m.save(CGRect(x: 1600, y: 300, width: 500, height: 700), among: [Self.laptop, Self.external])
        #expect(m.lastScreen == "external")
        let r = try #require(FloatingChatFrame.restore(m, screens: [Self.laptop, Self.external], host: 0))
        #expect(r.screen == "external")
        #expect(r.frame == CGRect(x: 1600, y: 300, width: 500, height: 700))
    }

    /// The external display unplugged: the laptop's own remembered place,
    /// and failing that the first placement on the notch's screen — never a
    /// frame on a display that is not there.
    @Test func aScreenThatIsGoneFallsBackToOneThatIsHere() throws {
        var m = FloatingChatMemory()
        m.save(CGRect(x: 1600, y: 300, width: 500, height: 700), among: [Self.laptop, Self.external])
        let r = try #require(FloatingChatFrame.restore(m, screens: [Self.laptop], host: 0))
        #expect(r.screen == "laptop")
        #expect(r.frame == FloatingChatFrame.initial(on: Self.laptop.visible))

        m.save(CGRect(x: 100, y: 100, width: 400, height: 400), among: [Self.laptop])
        m.lastScreen = "external"
        let back = try #require(FloatingChatFrame.restore(m, screens: [Self.laptop], host: 0))
        #expect(back.frame == CGRect(x: 100, y: 100, width: 400, height: 400))
    }

    /// Remembered on a big display, which now runs at a smaller resolution:
    /// shrunk and slid onto it.
    @Test func aRememberedFrameIsClampedToTheScreenAsItIsNow() throws {
        var m = FloatingChatMemory()
        m.frames["external"] = .init(CGRect(x: 3500, y: 900, width: 800, height: 1300))
        m.lastScreen = "external"
        let smaller = FloatingChatFrame.Screen(id: "external", visible: CGRect(x: 1512, y: 0, width: 1920, height: 1050))
        let r = try #require(FloatingChatFrame.restore(m, screens: [Self.laptop, smaller], host: 0))
        #expect(smaller.visible.contains(r.frame))
        #expect(r.frame.width == 800)
    }

    @Test func noScreensNoFrame() {
        #expect(FloatingChatFrame.restore(FloatingChatMemory(), screens: [], host: 0) == nil)
    }

    @Test func aFrameIsSavedUnderTheScreenItIsMostlyOn() {
        let straddling = CGRect(x: 1400, y: 100, width: 420, height: 400)   // 112 on the laptop, 308 off it
        #expect(FloatingChatFrame.screen(of: straddling, among: [Self.laptop, Self.external])?.id == "external")
        #expect(FloatingChatFrame.screen(of: CGRect(x: -900, y: 0, width: 100, height: 100),
                                         among: [Self.laptop]) == nil)
    }

    @Test func theMemorySurvivesARoundTripAndAGarbledRead() {
        var m = FloatingChatMemory()
        m.detached = true
        m.keepOnTop = false
        m.translucent = true
        m.save(CGRect(x: 10, y: 20, width: 400, height: 500), among: [Self.laptop])
        #expect(FloatingChatMemory.decode(m.encoded()) == m)
        #expect(FloatingChatMemory.decode(Data("nonsense".utf8)) == FloatingChatMemory())
        #expect(FloatingChatMemory.decode(nil) == FloatingChatMemory())
        #expect(FloatingChatMemory().keepOnTop)
    }

    // MARK: - The notch card's header

    /// Room beside the cutout on a 420 pt card, per Mac.
    static func room(notch: Double) -> Double { (420 - notch) / 2 }

    @Test func aFourteenInchHoldsThePopOutBesideANewConversation() {
        let h = NotchCardHeader.idle(room: Self.room(notch: 185), newConversation: true, tray: false)
        #expect(h.detach && h.newConversation)
        let air = NotchCardHeader.idle(room: Self.room(notch: 179), newConversation: true, tray: false)
        #expect(air.detach && air.newConversation)
    }

    /// The 16-inch's band is 100 pt: three buttons and the fold do not fit,
    /// and drawn anyway the first one ran under the cutout. The pop-out
    /// stays; a new conversation gives way.
    @Test func aSixteenInchGivesUpNewConversationForThePopOut() {
        let h = NotchCardHeader.idle(room: Self.room(notch: 220), newConversation: true, tray: false)
        #expect(h.detach)
        #expect(!h.newConversation)
        #expect(!NotchCardHeader.fits(buttons: 3, room: Self.room(notch: 220)))
    }

    @Test func withNothingElseThePopOutAlwaysFits() {
        for notch in [179.0, 185, 200, 220] {
            #expect(NotchCardHeader.idle(room: Self.room(notch: notch), newConversation: false, tray: false).detach)
        }
        #expect(NotchCardHeader.idle(room: .infinity, newConversation: true, tray: true) == (true, true))
    }

    /// Nowhere to put it: the header is exactly what it was before.
    @Test func noRoomLeavesTheHeaderAsItWas() {
        let h = NotchCardHeader.idle(room: 40, newConversation: true, tray: false)
        #expect(!h.detach)
        #expect(h.newConversation)
    }
}
