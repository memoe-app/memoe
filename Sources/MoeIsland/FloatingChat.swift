import CoreGraphics
import Foundation

/// The chat, popped out of the notch into a window of its own (the owner,
/// 2026-11-13: "the location by the notch is obstructing your view, there
/// should be a way where you can somehow move it around your machine where it
/// stays on any window and app and you can resize").
///
/// Where the conversation is drawn. One answer for the whole app, read by the
/// notch and by the floating window alike, so the two can never both draw the
/// card: the notch's own card opens only while the chat is at the notch
/// (`notchOpensCard`), and the floating window shows only while it is out.
public enum ChatPlacement: Equatable, Sendable, Codable {
    /// The card drops down from the notch, as it always has.
    case notch
    /// The card lives in its own window. `shown` is false after Esc or ✕:
    /// the chat is still out of the notch, only put away until it is wanted
    /// again (a click on the notch, the shortcut, an answer to show).
    case floating(shown: Bool)

    public var isDetached: Bool { if case .floating = self { true } else { false } }
    public var floatingShown: Bool { self == .floating(shown: true) }
}

/// What can happen to the placement.
public enum ChatPlacementEvent: Equatable, Sendable {
    /// The pop-out button in the notch card's header, the menu item.
    case detach
    /// The window's dock button: back into the notch.
    case dock
    /// Esc, or the window's ✕. Never ends the conversation.
    case close
    /// Somebody wants the chat: a click on the notch, an answer arriving,
    /// a file dropped on it.
    case summon
    /// The keyboard shortcut: out of the notch, back on screen if it was
    /// put away, and back into the notch if it is already in front of you.
    case toggle
}

public enum FloatingChat {

    /// The one transition function. Every route to the window goes through
    /// it, so "detached" means the same thing to the notch, the menus and
    /// the shortcut.
    public static func next(_ p: ChatPlacement, _ e: ChatPlacementEvent) -> ChatPlacement {
        switch (p, e) {
        case (_, .detach): return .floating(shown: true)
        case (_, .dock): return .notch
        case (.notch, .close), (.notch, .summon): return .notch
        case (.floating, .close): return .floating(shown: false)
        case (.floating, .summon): return .floating(shown: true)
        case (.notch, .toggle): return .floating(shown: true)
        case (.floating(let shown), .toggle): return shown ? .notch : .floating(shown: true)
        }
    }

    /// Whether the notch may open its own card. Never while the chat is out:
    /// that would be a second card of the same conversation. A meeting and a
    /// dictation are the notch's own panels, not the chat, and keep it.
    public static func notchOpensCard(_ p: ChatPlacement, meetingOn: Bool, dictating: Bool) -> Bool {
        !p.isDetached || meetingOn || dictating
    }

    /// Whether something that would have opened the notch card should bring
    /// the window forward instead. The same exceptions as `notchOpensCard`.
    public static func routesToWindow(_ p: ChatPlacement, meetingOn: Bool, dictating: Bool) -> Bool {
        !notchOpensCard(p, meetingOn: meetingOn, dictating: dictating)
    }

    /// The menu item that does what the shortcut does, named for what it
    /// will do now (`next(_, .toggle)`).
    public static func menuTitle(_ p: ChatPlacement, shortcut: String) -> String {
        switch p {
        case .notch: return "Pop Out Chat  (\(shortcut))"
        case .floating(shown: false): return "Show Chat Window  (\(shortcut))"
        case .floating(shown: true): return "Put Chat Back in the Notch  (\(shortcut))"
        }
    }
}

/// The round buttons in the notch card's header, beside the camera: the
/// inbox, a new conversation, the pop-out, and the fold at the far end. The
/// band beside a notch is narrow — 100 pt each side on a 16-inch Pro — so
/// what goes in it is counted rather than hoped for.
public enum NotchCardHeader {
    public static let button = 21.0
    public static let spacing = 6.0
    /// The fold's own place at the card's edge (`IslandView.bandClock`):
    /// 8 in, 21 wide, 8 before the next.
    public static let trailing = 8.0 + 21 + 8
    /// Kept clear of the cutout's edge.
    public static let clearance = 4.0

    /// Whether `buttons` round buttons, and `extra` points of something else
    /// (the clock), fit in `room` points between the cutout and the card's
    /// edge.
    public static func fits(buttons: Int, extra: Double = 0, room: Double) -> Bool {
        let n = Double(buttons)
        let items = buttons + (extra > 0 ? 1 : 0)
        let width = trailing + n * button + extra + Double(max(items - 1, 0)) * spacing
        return width + clearance <= room
    }

    /// What the idle header holds. The pop-out is always offered; where the
    /// band is too narrow for it and a new conversation both (a 16-inch with
    /// a conversation on screen), the new conversation gives way — it is
    /// also in the floating window's header and the Moe menu.
    public static func idle(room: Double, newConversation: Bool, tray: Bool)
        -> (newConversation: Bool, detach: Bool) {
        let base = 1 + (tray ? 1 : 0)
        if fits(buttons: base + 1 + (newConversation ? 1 : 0), room: room) {
            return (newConversation, true)
        }
        if fits(buttons: base + 1, room: room) { return (false, true) }
        // Nothing new fits: the header is what it was before the pop-out.
        return (newConversation, false)
    }
}

/// Where the window goes and how big it may be, as numbers.
public enum FloatingChatFrame {
    /// Small enough to sit beside a document; large enough for the field,
    /// the controls and a few lines of the conversation.
    public static let minimum = CGSize(width: 320, height: 260)
    /// A chat column, not a second desktop.
    public static let maximum = CGSize(width: 900, height: 1600)
    /// The first time out: the notch card's width, a little taller.
    public static let initialSize = CGSize(width: 420, height: 540)
    /// Kept clear of the screen's edges on the first placement.
    public static let margin: CGFloat = 16

    /// A frame that is the right size and wholly on `visible` (a screen's
    /// visible frame: below the menu bar, clear of the Dock). A frame saved
    /// on a bigger display, or before the Dock moved, comes back shrunk and
    /// slid in rather than off the edge where nobody can reach its header.
    public static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let maxW = min(maximum.width, visible.width)
        let maxH = min(maximum.height, visible.height)
        let w = min(max(frame.width, min(minimum.width, maxW)), maxW)
        let h = min(max(frame.height, min(minimum.height, maxH)), maxH)
        let x = min(max(frame.minX, visible.minX), visible.maxX - w)
        let y = min(max(frame.minY, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The first placement on a screen: its top-right corner, out of the way
    /// of the notch the window was taken out of to get away from.
    public static func initial(on visible: CGRect) -> CGRect {
        let w = initialSize.width, h = initialSize.height
        return clamp(CGRect(x: visible.maxX - margin - w, y: visible.maxY - margin - h, width: w, height: h),
                     to: visible)
    }

    /// One connected display, by a name that survives a reconnect.
    public struct Screen: Equatable, Sendable {
        public let id: String
        public let visible: CGRect
        public init(id: String, visible: CGRect) {
            self.id = id
            self.visible = visible
        }
    }

    /// Where the window opens: where it was last left, on the screen it was
    /// left on, if that screen is still here; else where it was last left on
    /// any screen that is; else the first placement on the host screen (the
    /// notch's). Always clamped to the screen it lands on.
    public static func restore(_ memory: FloatingChatMemory, screens: [Screen], host: Int) -> (frame: CGRect, screen: String)? {
        guard !screens.isEmpty else { return nil }
        let hostScreen = screens[min(max(host, 0), screens.count - 1)]
        var order: [Screen] = []
        if let last = memory.lastScreen, let s = screens.first(where: { $0.id == last }) { order.append(s) }
        order.append(hostScreen)
        order.append(contentsOf: screens)
        for s in order {
            if let saved = memory.frames[s.id] { return (clamp(saved.rect, to: s.visible), s.id) }
        }
        return (initial(on: hostScreen.visible), hostScreen.id)
    }

    /// The screen a frame is mostly on, for saving it under that screen's
    /// name. Nil when it is on none of them.
    public static func screen(of frame: CGRect, among screens: [Screen]) -> Screen? {
        var best: (Screen, CGFloat)?
        for s in screens {
            let i = s.visible.intersection(frame)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > (best?.1 ?? 0) { best = (s, area) }
        }
        return best?.0
    }
}

/// What is remembered between launches: where the window was on each
/// screen, which screen it was last on, whether the chat was out of the
/// notch, and the window's two switches.
public struct FloatingChatMemory: Equatable, Sendable, Codable {
    public struct Rect: Equatable, Sendable, Codable {
        public var x, y, width, height: Double
        public init(_ r: CGRect) {
            x = Double(r.minX); y = Double(r.minY); width = Double(r.width); height = Double(r.height)
        }
        public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    public var frames: [String: Rect] = [:]
    public var lastScreen: String?
    /// Out of the notch. Put away (`shown: false`) is not remembered: the
    /// window never opens itself at launch, only when it is wanted.
    public var detached = false
    /// Above every other app's windows (the default), or an ordinary window.
    public var keepOnTop = true
    /// See-through while you are not using it.
    public var translucent = false

    public init() {}

    /// Remember a frame the window was moved or resized to.
    public mutating func save(_ frame: CGRect, among screens: [FloatingChatFrame.Screen]) {
        guard let s = FloatingChatFrame.screen(of: frame, among: screens) else { return }
        frames[s.id] = Rect(frame)
        lastScreen = s.id
    }

    /// Never fails: a memory that cannot be read is a first launch.
    public static func decode(_ data: Data?) -> FloatingChatMemory {
        guard let data, let m = try? JSONDecoder().decode(FloatingChatMemory.self, from: data) else { return .init() }
        return m
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
