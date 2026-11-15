import AppKit
import Foundation
import MoeIsland
import SwiftUI
import Testing
@testable import Moe

/// The chat out of the notch, wired to the real `NotchIsland` and the real
/// `Conductor` (2026-11-13). The window is built and laid out but never put
/// on this Mac's screen (`putsOnScreen = false`).
@MainActor
struct FloatingChatWindowTests {

    final class MemoryStore: FloatingChatStore {
        var memory = FloatingChatMemory()
        var saves = 0
        func load() -> FloatingChatMemory { memory }
        func save(_ m: FloatingChatMemory) { memory = m; saves += 1 }
    }

    static let screen = FloatingChatFrame.Screen(id: "test", visible: CGRect(x: 0, y: 0, width: 1512, height: 944))

    private func make(_ store: MemoryStore = MemoryStore()) throws
        -> (NotchIsland, FloatingChatWindow, Conductor, MemoryStore) {
        try StallGuardConductorTests.requireScratchHome()
        _ = NSApplication.shared
        let c = Conductor(config: Config())
        let island = NotchIsland(conductor: c)
        let w = FloatingChatWindow(conductor: c, island: island, store: store)
        w.putsOnScreen = false
        w.screens = { [Self.screen] }
        w.hostIndex = { 0 }
        island.floating = w
        w.onPlacementChanged = { island.placementChanged($0, docked: !$0.isDetached) }
        island.show(expanded: false)
        return (island, w, c, store)
    }

    /// The pop-out folds the notch card and shows the window; while it is
    /// out, nothing that used to open the card does: a click, a hover, an
    /// explicit open — each brings the window instead. A hover too: it once
    /// showed nothing, and a put-away window made the notch look dead.
    @Test func whileOutTheNotchNeverOpensItsCard() throws {
        let (island, w, _, _) = try make()
        island.openByHand()
        #expect(island.presentation == .expanded)

        island.detach()
        #expect(w.placement == .floating(shown: true))
        #expect(island.presentation == .collapsed)
        #expect(island.chatIsOut)

        w.handle(.close)
        #expect(w.placement == .floating(shown: false))
        island.setHovering(true)
        #expect(island.presentation == .collapsed)
        #expect(w.placement == .floating(shown: true))
        island.setHovering(false)
        w.handle(.close)
        island.openByHand()
        #expect(island.presentation == .collapsed)
        #expect(w.placement == .floating(shown: true))
        w.handle(.close)
        island.show(expanded: true)
        #expect(island.presentation == .collapsed)
        #expect(w.placement == .floating(shown: true))
        island.revealOffer()
        #expect(island.presentation == .collapsed)
    }

    /// The switch: off, a hover opens nothing — not the peek, not the
    /// popped-out window — and a click still does.
    @Test func withHoverOffAHoverDoesNothing() throws {
        let (island, w, c, _) = try make()
        c.setNotchHoverOpens(false)
        defer { c.setNotchHoverOpens(true) }
        island.show(expanded: false)
        island.setHovering(true)
        #expect(island.presentation != .peek)
        island.setHovering(false)

        island.detach()
        w.handle(.close)
        island.setHovering(true)
        #expect(w.placement == .floating(shown: false))
        island.setHovering(false)
        island.openByHand()
        #expect(w.placement == .floating(shown: true))
    }

    /// Docking puts the card back where it was, open, so the conversation
    /// does not vanish on the way.
    @Test func dockingOpensTheCardInTheNotch() throws {
        let (island, w, _, _) = try make()
        island.detach()
        w.handle(.dock)
        #expect(w.placement == .notch)
        #expect(!island.chatIsOut)
        #expect(island.presentation == .expanded)
        island.setHovering(false)
        island.show(expanded: false)
        island.setHovering(true)
        #expect(island.presentation == .peek)
    }

    /// One conversation, one draft: the window draws the notch's own draft
    /// and the same Conductor, so a word typed in one is in the other.
    @Test func theWindowIsTheSameChatNotACopy() throws {
        let (island, w, c, _) = try make()
        let view = w.root(size: CGSize(width: 420, height: 540))
        #expect(view.draft === island.draft)
        #expect(view.conductor === c)
        #expect(view.floating != nil)
        island.draft.text = "half a thought"
        #expect(w.root(size: .zero).draft.text == "half a thought")
    }

    /// Out of the notch is remembered across launches; put away is not —
    /// the window never opens itself at launch.
    @Test func detachedIsRememberedButNotShown() throws {
        let (island, w, _, store) = try make()
        island.detach()
        #expect(store.memory.detached)
        let c2 = Conductor(config: Config())
        let again = FloatingChatWindow(conductor: c2, island: NotchIsland(conductor: c2), store: store)
        #expect(again.placement == .floating(shown: false))
        w.handle(.dock)
        #expect(!store.memory.detached)
    }

    /// Shown, then put away: its frame is saved under the screen it is on,
    /// clamped to it.
    @Test func putAwayRemembersTheFrame() throws {
        let (_, w, _, store) = try make()
        w.handle(.detach)
        let panel = try #require(w.panel)
        #expect(panel.frame == FloatingChatFrame.initial(on: Self.screen.visible))
        panel.setFrame(CGRect(x: 200, y: 150, width: 500, height: 600), display: false)
        w.handle(.close)
        #expect(store.memory.frames["test"]?.rect == CGRect(x: 200, y: 150, width: 500, height: 600))
        #expect(store.memory.lastScreen == "test")
        w.handle(.summon)
        #expect(panel.frame == CGRect(x: 200, y: 150, width: 500, height: 600))
    }

    /// A window over every app, every desktop and full-screen apps; an
    /// ordinary one when Keep on Top is off. Resizable, within limits.
    @Test func theWindowIsAFloatingPanelOnEverySpace() throws {
        let (_, w, _, store) = try make()
        w.handle(.detach)
        let panel = try #require(w.panel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.level == .floating)
        #expect(panel.level.rawValue < NSWindow.Level.statusBar.rawValue)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.contentMinSize == FloatingChatFrame.minimum)
        w.setKeepOnTop(false)
        #expect(panel.level == .normal)
        #expect(!store.memory.keepOnTop)
        w.setKeepOnTop(true)
        #expect(panel.level == .floating)
    }

    /// The header sits where a titled window keeps its title bar. A click
    /// there has to reach the header's buttons, not the hidden title bar.
    @Test func theHeaderButtonsAreNotUnderTheTitleBar() throws {
        let (_, w, _, _) = try make()
        w.handle(.detach)
        let panel = try #require(w.panel)
        let frameView = try #require(panel.contentView?.superview)
        panel.contentView?.layoutSubtreeIfNeeded()
        // The ✕, at the right end of the header, 22 pt down.
        let point = NSPoint(x: frameView.bounds.maxX - 30, y: frameView.bounds.maxY - 22)
        let hit = frameView.hitTest(point)
        #expect(hit != nil)
        #expect(hit === panel.contentView || hit?.isDescendant(of: panel.contentView!) == true,
                "hit \(String(describing: hit))")
    }

    /// See-through only while not in use.
    @Test func translucentOnlyWhenNotInUse() {
        #expect(FloatingChatWindow.alpha(translucent: true, inUse: false) < 1)
        #expect(FloatingChatWindow.alpha(translucent: true, inUse: true) == 1)
        #expect(FloatingChatWindow.alpha(translucent: false, inUse: false) == 1)
    }
}
