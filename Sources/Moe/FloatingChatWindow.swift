import AppKit
import Combine
import CoreGraphics
import MoeIsland
import SwiftUI

/// The notch card's window chrome, when it is the floating window.
/// `IslandView.floatingBody` reads it; nothing on the notch does.
struct FloatingChrome {
    var keepOnTop = true
    var translucent = false
    /// Bumped to put the caret in the field: a summons by hand (the pop-out,
    /// the shortcut, a click on the notch), never an answer arriving.
    var focusRequest = 0
    var onDock: () -> Void = {}
    var onToggleOnTop: () -> Void = {}
    var onToggleTranslucent: () -> Void = {}
    /// The header is the window's handle (`FloatingChatWindow.dragMoved`).
    var onDragChanged: () -> Void = {}
    var onDragEnded: () -> Void = {}
}

/// Where the window's memory is kept between launches.
protocol FloatingChatStore: AnyObject {
    func load() -> FloatingChatMemory
    func save(_ memory: FloatingChatMemory)
}

/// UserDefaults, which is per app: Memoe Dev's window remembers its own
/// place, not the real Memoe's.
final class DefaultsFloatingChatStore: FloatingChatStore {
    private let defaults: UserDefaults
    static let key = "floatingChat"
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> FloatingChatMemory { FloatingChatMemory.decode(defaults.data(forKey: Self.key)) }
    func save(_ memory: FloatingChatMemory) { defaults.set(memory.encoded(), forKey: Self.key) }
}

/// The chat, out of the notch (the owner, 2026-11-13): a window over every
/// app, every desktop and full-screen apps, moved by its header, resized by
/// its edges, remembered per display, and put back in the notch with one
/// button.
///
/// **It is not a copy of the chat.** It draws `IslandView` — the notch
/// card's own view — with the same `Conductor` and the same `IslandDraft`
/// the notch holds, so a word typed in one is in the other and an answer
/// streams into whichever is on screen. Only one is ever on screen:
/// `ChatPlacement` decides, and the notch reads it before it opens its card
/// (`NotchIsland.chatIsOut`).
///
/// A non-activating panel, like the island: clicking it, scrolling it or
/// pressing its buttons leaves the app you are in in front. The field takes
/// the keyboard when you click into it (`becomesKeyOnlyIfNeeded`), without
/// making Memoe the active app.
@MainActor
final class FloatingChatWindow: NSObject, NSWindowDelegate {

    /// ⌃⌥P, pop out. The other ⌃⌥ shortcuts are Space (talk), M (meeting),
    /// and S and R during a meeting; Rectangle and Magnet own ⌃⌥ with
    /// arrows, Return, C, D, E, F, G, T, U, I, J and K by default.
    static let shortcut = "⌃⌥P"

    private(set) var placement: ChatPlacement
    /// The notch folds its card, the menus retitle.
    var onPlacementChanged: ((ChatPlacement) -> Void)?
    /// The tray's window icon: the whole conversation in the Memoe window.
    var onOpenWindow: (() -> Void)?

    private let conductor: Conductor
    private let draft: IslandDraft
    private let store: FloatingChatStore
    private(set) var memory: FloatingChatMemory
    private(set) var panel: FloatingChatPanel?
    private var hosting: FloatingHostingView?
    private var focusRequest = 0
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var screenObserver: Any?

    /// False only in tests: the window is built and laid out but never put on
    /// the screen of the Mac running them.
    var putsOnScreen = true
    /// The displays, as the frame rules see them. Replaced in tests.
    var screens: () -> [FloatingChatFrame.Screen] = { FloatingChatWindow.liveScreens() }
    /// Which of them has the notch (`NotchGeometry.hostIndex`).
    var hostIndex: () -> Int = {
        NotchGeometry.hostIndex(notched: NSScreen.screens.map { NotchIsland.geometry(of: $0).hasNotch })
    }

    /// Takes the island, not a draft: the window's field is the notch's
    /// field, and there is no way to hand it another one.
    init(conductor: Conductor, island: NotchIsland, store: FloatingChatStore = DefaultsFloatingChatStore()) {
        self.conductor = conductor
        self.draft = island.draft
        self.store = store
        let memory = store.load()
        self.memory = memory
        // Out of the notch when Memoe last quit, but never on screen by
        // itself at launch: it comes when the chat is wanted.
        placement = memory.detached ? .floating(shown: false) : .notch
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.screensChanged() } }
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    // MARK: - The one way in

    /// Every route — the pop-out, the dock, ✕ and Esc, the shortcut, a
    /// click on the notch, an answer arriving — goes through here, and
    /// through `FloatingChat.next`.
    ///
    /// - Parameter focus: put the keyboard in the field. True for anything
    ///   done by hand; false for an answer arriving, which must not swallow
    ///   the next keystroke meant for the app in front (§7).
    @discardableResult
    func handle(_ event: ChatPlacementEvent, focus: Bool = true) -> ChatPlacement {
        let before = placement
        let after = FloatingChat.next(before, event)
        placement = after
        if memory.detached != after.isDetached {
            memory.detached = after.isDetached
            store.save(memory)
        }
        if after.floatingShown { present(focus: focus) } else { putAway() }
        if after != before {
            Log.write("chat window: \(event) — \(Self.describe(before)) → \(Self.describe(after))")
            onPlacementChanged?(after)
        }
        return after
    }

    static func describe(_ p: ChatPlacement) -> String {
        switch p {
        case .notch: return "in the notch"
        case .floating(let shown): return shown ? "floating" : "floating, put away"
        }
    }

    // MARK: - On screen

    private func present(focus: Bool) {
        let p = panel ?? build()
        if !shownByUs, let placed = FloatingChatFrame.restore(memory, screens: screens(), host: hostIndex()) {
            p.setFrame(placed.frame, display: false)
        }
        if focus { focusRequest += 1 }
        refresh()
        shownByUs = true
        conductor.islandOpen = true
        guard putsOnScreen else { return }
        p.orderFrontRegardless()
        // The keyboard without activating Memoe: the panel is non-activating.
        if focus { p.makeKey() }
    }

    private func putAway() {
        guard let p = panel, shownByUs else { return }
        shownByUs = false
        remember(p.frame)
        p.orderOut(nil)
    }

    /// On screen by this controller's say-so (`isVisible` is false for a
    /// window a test never ordered in).
    private(set) var shownByUs = false

    /// The view, rebuilt for the window's size and switches. Everything it
    /// shows it reads from the Conductor itself, as the notch does.
    private func refresh() {
        guard let hosting, let panel else { return }
        hosting.rootView = root(size: hosting.bounds.size == .zero ? panel.frame.size : hosting.bounds.size)
    }

    func root(size: CGSize) -> IslandView {
        var chrome = FloatingChrome()
        chrome.keepOnTop = memory.keepOnTop
        chrome.translucent = memory.translucent
        chrome.focusRequest = focusRequest
        chrome.onDock = { [weak self] in self?.handle(.dock) }
        chrome.onToggleOnTop = { [weak self] in self?.setKeepOnTop(!(self?.memory.keepOnTop ?? true)) }
        chrome.onToggleTranslucent = { [weak self] in self?.setTranslucent(!(self?.memory.translucent ?? false)) }
        chrome.onDragChanged = { [weak self] in self?.dragMoved() }
        chrome.onDragEnded = { [weak self] in self?.dragEnded() }
        return IslandView(conductor: conductor,
                          presentation: .expanded,
                          notchSize: .zero,
                          contentSize: size,
                          draft: draft,
                          takesFocus: true,
                          onTap: {},
                          onHover: { _ in },
                          onClose: { [weak self] in self?.handle(.close) },
                          onOpenChat: { [weak self] in self?.onOpenWindow?() },
                          floating: chrome)
    }

    // MARK: - The switches

    func setKeepOnTop(_ on: Bool) {
        memory.keepOnTop = on
        store.save(memory)
        if let panel { Self.applyLevel(panel, keepOnTop: on) }
        refresh()
    }

    func setTranslucent(_ on: Bool) {
        memory.translucent = on
        store.save(memory)
        if let panel { panel.alphaValue = Self.alpha(translucent: on, inUse: panel.isKeyWindow) }
        refresh()
    }

    /// See-through only while it is not the window you are typing in.
    static func alpha(translucent: Bool, inUse: Bool) -> CGFloat { translucent && !inUse ? 0.78 : 1 }

    /// Above every app's windows (`.floating`, under the island's own level
    /// so the notch is never covered), or an ordinary window that the app
    /// you click covers. On every desktop and over full-screen apps either way.
    static func applyLevel(_ panel: NSPanel, keepOnTop: Bool) {
        panel.isFloatingPanel = keepOnTop
        panel.level = keepOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // MARK: - Moving by the header

    /// The header's drag. Read from the pointer itself rather than the
    /// gesture's translation, which is measured in a view that is moving.
    private func dragMoved() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        guard let start = dragStart else {
            dragStart = (mouse, panel.frame.origin)
            return
        }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func dragEnded() {
        dragStart = nil
        guard let panel else { return }
        settle(panel)
    }

    /// Wholly on the screen it was let go on, and remembered there.
    private func settle(_ panel: NSPanel) {
        let all = screens()
        if let s = FloatingChatFrame.screen(of: panel.frame, among: all) ?? all.first {
            let clamped = FloatingChatFrame.clamp(panel.frame, to: s.visible)
            if clamped != panel.frame { panel.setFrame(clamped, display: true, animate: false) }
        }
        remember(panel.frame)
    }

    private func remember(_ frame: CGRect) {
        memory.save(frame, among: screens())
        store.save(memory)
    }

    private func screensChanged() {
        guard let panel, panel.isVisible else { return }
        settle(panel)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) { refresh() }
    func windowDidEndLiveResize(_ notification: Notification) { if let panel { settle(panel) } }
    func windowDidBecomeKey(_ notification: Notification) {
        panel?.alphaValue = Self.alpha(translucent: memory.translucent, inUse: true)
    }
    func windowDidResignKey(_ notification: Notification) {
        panel?.alphaValue = Self.alpha(translucent: memory.translucent, inUse: false)
    }
    /// ⌘W, which the panel answers because it is closable, puts it away like
    /// ✕; nothing ever destroys it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        handle(.close)
        return false
    }

    // MARK: - Construction

    func build() -> FloatingChatPanel {
        let size = FloatingChatFrame.initialSize
        let p = FloatingChatPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView,
                                              .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.title = "Memoe Chat"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        // The notch card's palette in both appearances, as the island pins it
        // (docs/PANEL-FINDINGS.md §8): the field's editor follows the window.
        p.appearance = NSAppearance(named: .darkAqua)
        p.backgroundColor = .black
        p.isOpaque = false
        p.hasShadow = true
        p.contentMinSize = FloatingChatFrame.minimum
        p.contentMaxSize = FloatingChatFrame.maximum
        p.isMovable = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .utilityWindow
        p.setAccessibilityLabel("Memoe chat")
        Self.applyLevel(p, keepOnTop: memory.keepOnTop)
        p.alphaValue = Self.alpha(translucent: memory.translucent, inUse: false)
        p.delegate = self

        let host = FloatingHostingView(rootView: root(size: size))
        host.sizingOptions = []
        host.onDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let taken = AttachmentIntake.take(from: pasteboard)
            guard !taken.isEmpty else { return false }
            self.draft.attachments.append(contentsOf: taken)
            self.panel?.makeKey()
            return true
        }
        host.registerForDraggedTypes(AttachmentIntake.draggedTypes)
        p.contentView = host
        hosting = host
        panel = p
        return p
    }

    // MARK: - Displays

    /// Every display by a name that survives unplugging it: its UUID, or its
    /// name and size where there is none.
    static func liveScreens() -> [FloatingChatFrame.Screen] {
        NSScreen.screens.map { FloatingChatFrame.Screen(id: key(of: $0), visible: $0.visibleFrame) }
    }

    static func key(of screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, uuid) as String? {
            return s
        }
        return "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))"
    }
}

/// Takes the keyboard without activating Memoe, as the island's panel does.
final class FloatingChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The window's view: files dropped anywhere on it join the field, as they
/// do dropped on the notch.
final class FloatingHostingView: NSHostingView<IslandView> {
    var onDrop: ((NSPasteboard) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        AttachmentIntake.canTake(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        AttachmentIntake.canTake(sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}
