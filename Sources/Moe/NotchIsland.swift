import AppKit
import Combine
import MoeIsland
import SwiftUI

/// Moe's island: invisible at rest behind the notch, drops down on hover.
///
/// Written directly against AppKit rather than pulled from a package, because
/// every notch library on GitHub uses SwiftUI macros (`@Entry`, `#Preview`)
/// whose plugins ship with full Xcode — and this app builds with just the
/// Command Line Tools.
///
/// Two things here are non-obvious and both were learned the hard way:
///
///  1. **The window never changes size.** It is created once at the largest
///     size the island will ever need and stays there; only the drawn content
///     grows and shrinks. Resizing a window on hover makes the cursor fall
///     outside it, which fires hover-exit, which shrinks it back, which fires
///     hover-enter — a flicker loop.
///  2. **Hit testing is clipped to what's drawn.** Because the window is
///     permanently large, without this it would swallow every click in a wide
///     band across the top of the screen, including the menu bar.
@MainActor
final class NotchIsland {

    /// The cases are unchanged; they live in `MoeIsland` so the rules that
    /// read them — what a click means, what hover may do, what "be visible"
    /// means — can be tested without a window. docs/PANEL-FINDINGS.md.
    typealias Presentation = IslandPresentation

    private var panel: NSPanel?
    /// Whether `window` is the island's own panel (Esc in it may stop Moe).
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
    private var hosting: IslandHostingView?
    private(set) var presentation: Presentation = .hidden
    /// The draft in the ask field, held out here rather than in the view's
    /// `@State`, because the clock that folds a self-opened panel has to know
    /// whether something is half-typed — §7.
    let draft = IslandDraft()
    /// The chat popped out of the notch (`FloatingChatWindow`). While it is
    /// out, the notch never opens its own card: what would have opened it
    /// brings the window forward instead (`chatIsOut`).
    weak var floating: FloatingChatWindow?
    /// This panel opened itself when Moe answered, so it closes itself too:
    /// it never takes the keyboard, and it folds after long enough to read.
    private var selfOpened = false
    private var revealTask: Task<Void, Never>?
    private var outsideClick: Any?

    private let conductor: Conductor
    private var collapseTask: Task<Void, Never>?
    private var hoverExitTask: Task<Void, Never>?
    /// The cursor left the island while a dictation was running. The strip is
    /// held open for the whole hold, so the exit is remembered and acted on
    /// when dictation ends.
    private var cursorLeftWhileDictating = false

    var onOpenWindow: (() -> Void)?

    /// The largest the island ever gets — the window is this size always.
    private let maxWidth: CGFloat = 460
    /// Tall enough for the meeting panel (transcript + chat); the
    /// conversation panel uses less of it.
    ///
    /// The notes panel is the tall one, and it is the only state drawn when
    /// the call is over and there is nothing underneath to cover, so the
    /// window has to hold `NotesPanel.maximumHeight`. At 330 it did not, and
    /// a notes panel measured honestly would have been clipped by the window
    /// instead of by the scroll view — the same content lost one layer up.
    private let maxContentHeight: CGFloat = CGFloat(max(NotesPanel.maximumHeight,
                                                        Dropdown.expandedMaximumHeight))

    /// Redraw when the conversation state changes, so the glow appears and
    /// disappears without needing a hover to trigger a re-layout.
    private var sessionObserver: AnyCancellable?
    private var dictationObserver: AnyCancellable?
    private var meetingObserver: AnyCancellable?
    private var bannerObserver: AnyCancellable?
    private var workingObserver: AnyCancellable?
    private var noticeObserver: AnyCancellable?
    /// The content size the panel was last laid out at, so the content
    /// observer re-lays it out only when that would change.
    private var drawnContent: CGSize = .zero
    private var transcriptObserver: AnyCancellable?
    /// "A new version of Memoe is ready." coming and going (docs/DEFAULTS.md
    /// row 47). Its own observer, because whether it shows depends on more
    /// than the banners above: it waits for Moe to be idle.
    private var updateObserver: AnyCancellable?
    private var updateNoticeShown = false
    /// Mute coming and going: the collapsed island grows or loses its red
    /// "Muted" tab, and its size and click target with it.
    private var muteObserver: AnyCancellable?
    /// Keeps the folded island's click target on its ears (`refreshEarZone`).
    private var earObserver: AnyCancellable?
    /// A capsule Mac only: the island steps round macOS's microphone pill
    /// while any app has the microphone open (`MicIndicatorWatch`).
    private var micObserver: AnyCancellable?

    init(conductor: Conductor) {
        self.conductor = conductor
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }

        // Dictation never opens the panel: the halo around the notch is the
        // only cue. The observer just re-lays-out a panel the cursor is
        // already holding open, since its content swaps with the state.
        dictationObserver = conductor.$dictation
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state != .off {
                    // A new dictation: whatever the cursor did during the last
                    // one is no longer interesting.
                    self.cursorLeftWhileDictating = false
                    return
                }
                let left = self.cursorLeftWhileDictating
                self.cursorLeftWhileDictating = false
                guard self.presentation == .peek else { return }
                // Peek is a different size for the dictation strip than for
                // the conversation, so even when the cursor keeps the panel
                // open it has to be laid out again for the new content —
                // otherwise the chat is drawn into a 64pt strip.
                //
                // `left` is the fix for the strip outstaying the cursor: the
                // hover exit that arrived mid-dictation was recorded rather
                // than dropped, so it is honoured here.
                let stay = !left && self.cursorIsOverIsland()
                self.apply(stay ? .peek : .collapsed, animated: true)
            }

        // A meeting changes the panel's shape (strip on hover, tall when
        // open) and its content; re-lay-out whatever is showing when the
        // state moves, and fold the panel when the meeting is dismissed.
        meetingObserver = conductor.$meeting
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, self.presentation != .hidden else { return }
                if state == .off, self.presentation == .expanded { self.apply(.collapsed, animated: true); return }
                self.apply(self.presentation, animated: true)
            }

        // The rows above the conversation change its height, and the height
        // is only worked out in `apply`. A reminder arriving, a call offer,
        // or Accessibility being switched on in System Settings while the
        // panel is open used to leave it sized for what it held before —
        // too short for the new row, or a slab of black under a row that
        // had gone.
        bannerObserver = Publishers.CombineLatest3(
            conductor.$pendingNudge.removeDuplicates(),
            conductor.$meetingOffer.map { $0 != nil }.removeDuplicates(),
            AccessibilityWatch.shared.$granted.removeDuplicates())
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.presentation == .peek || self.presentation == .expanded else { return }
                self.apply(self.presentation, animated: true)
            }

        // The inbox: opening it, a row finished, a notice arriving (its line
        // under the folded notch), the way back after a reply.
        noticeObserver = Publishers.MergeMany(
            conductor.$showingInbox.map { _ in () }.eraseToAnyPublisher(),
            conductor.$notices.map { _ in () }.eraseToAnyPublisher(),
            conductor.$noticePeek.map { $0?.id }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            conductor.$noticeReturn.map { _ in () }.eraseToAnyPublisher())
            .dropFirst()
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.presentation != .hidden else { return }
                self.apply(self.presentation, animated: true)
            }

        // The dropdown's height follows what it holds (`Dropdown`): the
        // step while Moe works, then the answer as it streams in, the field
        // coming and going, your live words. Anything that can change it is
        // watched, and the panel is re-laid out only when the height it
        // would be drawn at actually differs — never on a step whose label
        // fits the same line.
        workingObserver = Publishers.MergeMany(
            conductor.$mode.map { _ in () }.eraseToAnyPublisher(),
            conductor.$acting.map { _ in () }.eraseToAnyPublisher(),
            conductor.$turns.map { _ in () }.eraseToAnyPublisher(),
            conductor.$partial.map { $0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            conductor.$workingStep.map { _ in () }.eraseToAnyPublisher(),
            conductor.$voicedTurnID.map { _ in () }.eraseToAnyPublisher(),
            conductor.$inConversation.map { _ in () }.eraseToAnyPublisher(),
            // The field grows with what is typed, a line at a time.
            draft.$text.map { $0.count / 30 + $0.filter { $0 == "\n" }.count }.removeDuplicates()
                .map { _ in () }.eraseToAnyPublisher(),
            draft.$attachments.map { $0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            // The compact card grows a row while its ⋯ is out.
            draft.$trayOpen.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.presentation == .peek || self.presentation == .expanded,
                      let screen = self.hostScreen else { return }
                let size = self.contentSize(for: self.presentation, notch: self.notchSize(of: screen),
                                            accessibility: self.liveAccessibility)
                guard abs(size.height - self.drawnContent.height) > 0.5
                        || abs(size.width - self.drawnContent.width) > 0.5 else { return }
                self.apply(self.presentation, animated: true)
            }

        // Transcript on: the words are shown as they are heard, which means
        // the panel opens when you start talking — shut, there is nothing to
        // read them in. Opened the way an answer opens it (`selfOpened`), so
        // it folds away the same way and never takes the keyboard.
        // And when Moe starts to answer aloud: the transcript is pressed to
        // read the conversation, and Moe's half of it is the answer
        // (`ReplyReveal.transcriptOpens`, ticket #12).
        transcriptObserver = Publishers.CombineLatest(
            conductor.$mode.removeDuplicates(),
            conductor.$showsTranscript)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, shows in
                guard let self,
                      ReplyReveal.transcriptOpens(listening: mode == .listening,
                                                  speaking: mode == .speaking,
                                                  transcriptOn: shows,
                                                  collapsed: self.presentation == .collapsed)
                else { return }
                if self.chatIsOut { self.floating?.handle(.summon, focus: false); return }
                self.panel?.orderFrontRegardless()
                self.collapseTask?.cancel()
                self.selfOpened = true
                self.apply(.expanded, animated: true)
                self.watchForOutsideClick()
            }

        // Read after the change lands (`receive(on:)` first): `@Published`
        // emits before the new value is stored, and the policy reads the
        // Conductor itself rather than the value in hand.
        updateObserver = Publishers.MergeMany(
            UpdateReadyNotice.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            conductor.$mode.map { _ in () }.eraseToAnyPublisher(),
            conductor.$inConversation.map { _ in () }.eraseToAnyPublisher(),
            conductor.$acting.map { _ in () }.eraseToAnyPublisher(),
            conductor.$drivingApp.map { _ in () }.eraseToAnyPublisher(),
            conductor.$browsing.map { _ in () }.eraseToAnyPublisher(),
            conductor.$dictation.map { _ in () }.eraseToAnyPublisher(),
            conductor.$meeting.map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let showing = UpdateReadyNotice.shared.showing(for: self.conductor)
                guard showing != self.updateNoticeShown else { return }
                self.updateNoticeShown = showing
                // The notice also lights the collapsed island's amber glow
                // (`IslandGlow`), so an island that was put away comes back the
                // way it does when a nudge arrives (`queueReminder` →
                // `onWantsIsland(true)` → `reveal()`), or the glow is unseen.
                if showing, !self.presentation.isOnScreen { self.reveal(); return }
                guard self.presentation == .peek || self.presentation == .expanded else { return }
                self.apply(self.presentation, animated: true)
            }

        earObserver = conductor.objectWillChange
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshEarZone() }

        muteObserver = conductor.$micMuted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.presentation.isOnScreen else { return }
                self.apply(self.presentation, animated: true)
            }

        // A conversation starting or ending redraws the folded island. This
        // was a task that woke every 250 ms for the life of the app to ask;
        // `inConversation` is published, so it tells us. `prepend(false)` and
        // `dropFirst()` keep what the poll did at launch: nothing, unless a
        // conversation is already live.
        sessionObserver = conductor.$inConversation
            .prepend(false)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.presentation == .collapsed else { return }
                self.apply(.collapsed, animated: true)
            }
    }

    // MARK: - Geometry

    /// The display the island lives on: the notched one when there is one,
    /// else the one with the menu bar. `NotchGeometry.hostIndex`.
    ///
    /// It was the screen under the cursor, read afresh on every `apply` —
    /// while the window stayed on whichever screen it was built on. With an
    /// external display that measured the wrong screen's notch (none) and
    /// drew the panel's first 32 pt up inside the laptop's camera housing.
    private var hostScreen: NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }
        let notched = screens.map { Self.geometry(of: $0).hasNotch }
        return screens[NotchGeometry.hostIndex(notched: notched)]
    }

    static func geometry(of screen: NSScreen) -> NotchGeometry {
        NotchGeometry.measure(frame: screen.frame,
                              safeAreaTop: screen.safeAreaInsets.top,
                              left: screen.auxiliaryTopLeftArea,
                              right: screen.auxiliaryTopRightArea,
                              model: hardwareModel)
    }

    /// `hw.model` ("Mac17,13"), read once. Only a floating capsule's own
    /// numbers are looked up by it (`NotchGeometry.measuredCapsules`).
    static let hardwareModel: String? = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }()

    private func notchSize(of screen: NSScreen) -> CGSize {
        Self.geometry(of: screen).size
    }

    /// The floating capsule on that screen, if its cutout is one.
    private func capsule(of screen: NSScreen) -> NotchGeometry.CapsuleCutout? {
        Self.geometry(of: screen).capsule
    }

    /// Whether macOS may be drawing its microphone pill round that capsule
    /// (`IslandView.indicatorLive`, from the same two facts). The watch is
    /// only ever started on a Mac that has a capsule.
    private func indicatorLive(_ capsule: NotchGeometry.CapsuleCutout?) -> Bool {
        capsule != nil && (MicIndicatorWatch.shared.open || IslandView.usesMicrophone(conductor))
    }

    /// Reduce Motion (System Settings › Accessibility › Display): the island
    /// changes shape at once instead of springing.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The talk-key row's sentence while Accessibility is off.
    private var liveAccessibility: String? {
        AccessibilityWatch.shared.granted ? nil : AccessibilityWatch.shared.problem(for: conductor.config.talkKey)
    }

    /// The meeting panel while it is recording, in points.
    ///
    /// It used to be the full 460 × 330, which is a lot of black over
    /// somebody's call window — and the panel is opened *during* the call,
    /// on top of the faces. This is the smallest that still holds a
    /// readable transcript, the chat and the field.
    /// The meeting panel: the dropdown's width (`Dropdown.Metric.width`), so
    /// a call and a conversation open to the same shape, and tall enough for
    /// the tabs, a few transcript lines, the ⋯ row and the field.
    static let recordingPanel = CGSize(width: Dropdown.Metric.width, height: 270)
    /// Afterwards there is a summary, decisions and tickable action items
    /// to read, and no call underneath: it can be bigger again.
    static let notesPanel = CGSize(width: 428, height: 300)
    /// Collapsed and muted: the left ear says "Muted" (`IslandEars`). Read
    /// here only for the log line a click on the folded island writes.
    private var showingMutedTab: Bool {
        ConversationControls.showsMutedTab(presentation: presentation, muted: conductor.micMuted,
                                           meetingOn: meetingOn, dictating: conductor.dictation != .off)
    }

    /// How tall the conversation panel needs to be, from what is in it.
    ///
    /// It was a flat 190 points whatever the state, so a panel holding one
    /// line of text drew 150 points of black under it. Measuring the rendered
    /// content and resizing the window would risk the hover flicker this file
    /// is built to avoid — a resize moves the cursor out of the panel, which
    /// fires hover-exit, which resizes again — so the height is *computed*
    /// from the same state the view draws. Deterministic, and no feedback
    /// loop: nothing here reads a size that this then changes.
    ///
    /// The arithmetic is `ConversationPanel.height`, in a library target so it
    /// can be tested. It used to be here, and it counted the reminder card as
    /// one line of sentence, did not count the talk-key row or the call offer
    /// at all, and let the hover panel cap at 210 whatever was in it — which
    /// is the ask field hanging off the bottom of the panel in the owner's
    /// screenshot of 2026-09-14.
    private func conversationHeight(width: CGFloat, peek: Bool, notch: CGSize,
                                    accessibility: String?) -> CGFloat {
        if conductor.showingInbox {
            // The inbox's own measure (`InboxLayout`): its rows, capped, plus
            // the panel's top and bottom padding and the header line.
            let rows = conductor.islandNotices.map { (title: $0.title, summary: $0.summary, needsYou: $0.kind.needsYou) }
            let chromeInBand = ConversationPanel.chromeFitsInBand(panelWidth: Double(width), notch: notch)
            return CGFloat(min(InboxLayout.height(rows: rows)
                               + Dropdown.Metric.top + Dropdown.Metric.bottom
                               + (chromeInBand ? 0 : ConversationPanel.Metric.chromeDrop),
                               ConversationPanel.maximumHeight))
        }
        let panel = IslandView.dropdownContents(conductor, draft: draft, accessibility: accessibility,
                                                updateShowing: UpdateReadyNotice.shared.showing(for: conductor),
                                                width: Double(width), notch: notch)
        return CGFloat(Dropdown.height(panel, wraps: IslandTextMeasure.wraps,
                                       maximum: Dropdown.maximum(expanded: !peek)))
    }

    /// The banners above the conversation, as `ConversationPanel` counts them.
    static func bannerContents(_ conductor: Conductor, accessibility: String?, updateShowing: Bool,
                               width: Double, notch: CGSize) -> ConversationPanel.Contents {
        var offers: [ConversationPanel.Offer] = []
        if let sentence = IslandView.callOfferSentence(conductor) {
            offers.append(.init(text: sentence, actions: 3))
        }
        if updateShowing {
            offers.append(.init(text: UpdateReadyPolicy.sentence, actions: 2))
        }
        if let accessibility {
            offers.append(.init(text: accessibility, actions: 1,
                                inlineActionWidth: IslandView.offerPillWidth("Fix")))
        }
        for offer in conductor.fixOffers {
            let actions = IslandView.fixActions(offer)
            offers.append(.init(text: offer.why, actions: actions.count,
                                inlineActionWidth: IslandView.offerPillWidth(actions[0])))
        }
        let contents = ConversationPanel.Contents(
            turns: conductor.turns.count,
            partial: !conductor.partial.isEmpty,
            statusLine: !conductor.statusLine.isEmpty,
            // The inbox holds notices now; nothing sits above the chat.
            nudge: nil,
            offers: offers,
            chromeInBand: ConversationPanel.chromeFitsInBand(panelWidth: width, notch: notch),
            working: WorkingRow.shows(thinking: conductor.mode == .thinking, acting: conductor.acting,
                                      dictating: conductor.dictation != .off,
                                      meetingOn: conductor.meeting != .off)
                && !conductor.showsTranscript,
            folds: conductor.turns.suffix(8).filter {
                $0.role == .moe && !$0.isStreaming
                    && WorkingRow.summary(steps: $0.tools.count, took: $0.took) != nil
            }.count)
        return contents
    }

    /// The notes panel, likewise: a summary is a paragraph, not a fixed box.
    ///
    /// The arithmetic is `NotesPanel.layout` — a library target, so it can be
    /// tested. It used to be four lines here that allowed a flat 96 pt for
    /// everything that is not the summary, counted decisions and action items
    /// four at a time and nothing else at all, and capped at 320. The chrome
    /// alone is about 160 pt, so the body was handed far less room than it
    /// needed and the `ScrollView` it sits in quietly kept the rest off
    /// screen: in `10-notes-ready.png` the ACTION ITEMS heading and both
    /// items were simply not in the panel, with nothing to say so.
    private var notesHeight: CGFloat {
        guard case .done = conductor.meeting else { return 180 }
        return CGFloat(NotesPanel.layout(for: conductor).height)
    }

    #if DEBUG
    /// The drawn size of a presentation, for `Moe --panel-snapshot`
    /// (docs/PANEL-FINDINGS.md §9). The snapshot asks the real layout rather
    /// than keeping its own copy of these numbers, because a preview that can
    /// drift from the thing it previews is worse than no preview.
    func snapshotContentSize(for p: Presentation, notch: CGSize, accessibility: String?,
                             trayOpen: Bool = false) -> CGSize {
        draft.trayOpen = trayOpen
        defer { draft.trayOpen = false }
        return contentSize(for: p, notch: notch, accessibility: accessibility)
    }
    #endif

    /// Size of the *drawn* island, excluding the part behind the notch.
    private func contentSize(for p: Presentation, notch: CGSize, accessibility: String?) -> CGSize {
        let meeting = conductor.dictation == .off && conductor.meeting != .off
        let done: Bool = if case .done = conductor.meeting { true } else { false }
        switch p {
        case .expanded:
            guard meeting else {
                // The same width as the hover panel: opening one you are
                // already looking at used to widen it by 40 pt.
                let w = CGFloat(Dropdown.Metric.width)
                return CGSize(width: w,
                              height: conversationHeight(width: w, peek: false, notch: notch,
                                                         accessibility: accessibility))
            }
            return done ? CGSize(width: Self.notesPanel.width, height: notesHeight)
                        : Self.recordingPanel
        // Dictation needs a strip for the transcript, not a conversation;
        // so does a meeting on hover (the clock and the controls).
        case .peek:     return conductor.dictation != .off
                             ? CGSize(width: 360, height: 64)
                             // A meeting's hover is the meeting panel now, not
                             // a 58pt strip: see IslandView.meetingContent.
                             // Asking something mid-call used to cost a hover,
                             // a click, then a click into the field.
                             : meeting ? (done ? Self.notesPanel
                                               : Self.recordingPanel)
                             : CGSize(width: 420,
                                      height: conversationHeight(width: 420, peek: true, notch: notch,
                                                                 accessibility: accessibility))
        case .collapsed:
            // At rest the island is the notch and its ears (`IslandEars`),
            // all of them inside the notch's own band: nothing hangs under it
            // any more, so nothing here is taller than the notch. The ears'
            // reach is the hover zone's business (`hoverZone`), not this.
            // Without a notch, the drawn stand-in (`NotchGeometry.virtualNotch`)
            // is what the cursor finds.
            return notch.width > 0 ? CGSize(width: notch.width, height: 0)
                                   : CGSize(width: NotchGeometry.noNotchTargetWidth,
                                            height: max(NotchGeometry.virtualNotch.height - notch.height, 18))
        case .hidden:   return .zero
        }
    }

    /// Slack around the drawn island: room for the open panel's drop shadow
    /// (`IslandView.panel`, spill 44) to fade out in, and for the folded
    /// island's ears (`IslandEars`) to reach past the notch — the widest, a
    /// notice's line, comes to about 230 pt past the notch's edge, inside the
    /// 350 pt this leaves either side of centre. The panel's coloured glow,
    /// which this was first sized for, is gone (2026-10-15).
    private let glowMargin: CGFloat = 120

    /// The window: fixed, and big enough for the largest state plus its glow.
    ///
    /// Centred on the notch rather than on the screen. They are not the same
    /// point: the 13-inch Air's menu bar strips are 646 and 645 pt, so its
    /// notch sits half a point right of centre, and the window is snapped to
    /// the pixel grid rather than to whole points so that half point survives.
    private func windowFrame(on screen: NSScreen) -> NSRect {
        let geometry = Self.geometry(of: screen)
        let notch = geometry.size
        let height = notch.height + maxContentHeight + glowMargin
        let width = maxWidth + glowMargin * 2
        let scale = max(screen.backingScaleFactor, 1)
        return NSRect(x: ((geometry.centreX - width / 2) * scale).rounded() / scale,
                      y: (screen.frame.maxY - height).rounded(),
                      width: width, height: height)
    }

    // MARK: - Presentation

    func show(expanded: Bool) {
        if expanded, chatIsOut { floating?.handle(.summon); return }
        collapseTask?.cancel()
        // An explicit command: whatever this puts on screen is not the panel
        // that opened itself, so it does not close itself either.
        endReveal()
        apply(expanded ? .expanded : .collapsed, animated: true)
        panel?.orderFrontRegardless()
    }

    /// Hover moves between collapsed and peek only — it must never shrink the
    /// expanded panel out from under someone reading it.
    func setHovering(_ hovering: Bool) {
        if hovering {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            // The person's switch (Voice › More › "Hovering the notch opens
            // it"). Off, a hover is nothing at all; a click still opens.
            guard conductor.config.notchHoverOpens else { return }
            // The chat is in its window: hovering the notch brings that
            // window forward (without the keyboard — a hover is not a
            // request to type). It used to show nothing, and with the window
            // put away or behind a full-screen app the notch looked dead
            // (the owner, 2026-11-14). The card itself still never opens.
            if chatIsOut { floating?.handle(.summon, focus: false); return }
            // In every state, working included: the stop and the Work
            // silently switch live on the peek, and hovering is how the peek
            // is reached. `IslandBehaviour.hoverEntered` is the rule.
            if let target = IslandBehaviour.hoverEntered(current: presentation,
                                                         meetingOn: meetingOn) {
                apply(target, animated: true)
            }
            return
        }
        guard presentation == .peek else { return }
        // Hover in, hover out — in every state, dictation included.
        //
        // The strip used to be pinned open for the whole hold on the theory
        // that you would want to watch the words arrive. In practice you are
        // looking at the thing you are dictating into, and a panel that
        // ignores the cursor reads as stuck. The halo around the notch is
        // what says a dictation is running; the strip is a detail you ask
        // for by hovering, like everything else here.
        cursorLeftWhileDictating = true
        // Small grace period: SwiftUI reports a spurious exit as the content
        // reflows, and collapsing on that is what reads as flicker.
        hoverExitTask?.cancel()
        hoverExitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.presentation == .peek else { return }
                guard !self.cursorIsOverIsland() else { return }
                self.apply(.collapsed, animated: true)
            }
        }
    }

    /// Checked against the real cursor position rather than trusting the
    /// enter/exit events that caused the flicker in the first place.
    private func cursorIsOverIsland() -> Bool {
        guard let panel, let hosting else { return false }
        let zone = hosting.hoverZone
        // Screen coordinates are bottom-left origin, so the zone hangs down
        // from the top edge of the panel.
        let lift = hosting.hoverLift
        let rect = NSRect(x: panel.frame.midX + hosting.hoverShift - zone.width / 2,
                          y: panel.frame.maxY - zone.height,
                          width: zone.width, height: zone.height - lift.inset)
        if NSMouseInRect(NSEvent.mouseLocation, rect, false) { return true }
        guard lift.inset > 0 else { return false }
        // The column over the camera, up to the top edge.
        let stem = NSRect(x: panel.frame.midX - lift.stem / 2, y: panel.frame.maxY - lift.inset,
                          width: lift.stem, height: lift.inset)
        return NSMouseInRect(NSEvent.mouseLocation, stem, false)
    }

    private func apply(_ target: Presentation, animated: Bool) {
        guard let screen = hostScreen else { return }
        // The one gate: with the chat in its window the notch draws no card,
        // whoever asked. Every path that opens the card arrives here.
        let target = chatIsOut && target.isOpen ? .collapsed : target
        let p = panel ?? build(on: screen)
        // Anything that is not the open panel ends a self-opened reveal: the
        // clock and the outside-click watch belong to that one panel.
        if target != .expanded { endReveal() }
        // While muted, every change of what is drawn is logged, so an unmute
        // can be read against what the island was showing when it came.
        if target != presentation, conductor.micMuted {
            Log.write("island: \(presentation) → \(target) (muted)")
        }
        presentation = target
        // Folding leaves the inbox, so the next hover opens on the chat and
        // not on a list nobody asked for again. Before the size is taken,
        // which reads `showingInbox`.
        if target == .collapsed { conductor.closeInbox() }
        // A thread on screen is never put away from under someone reading it
        // (`Conductor.startFreshIfIdle`).
        conductor.islandOpen = target == .peek || target == .expanded
            || floating?.placement.floatingShown == true

        let notch = notchSize(of: screen)
        let capsule = capsule(of: screen)
        let content = contentSize(for: target, notch: notch, accessibility: liveAccessibility)
        drawnContent = content

        // The window stays put; only what's drawn inside it changes.
        _ = p
        let zone = hoverZone(for: target, content: content, notch: notch, capsule: capsule)
        hosting?.hoverZone = zone.size
        hosting?.hoverShift = zone.shift
        hosting?.hoverLift = hoverLift(for: target, notch: notch, capsule: capsule)
        // §1, part three: collapsed, every drawn thing has hit testing off, so
        // the hosting view takes the click itself and no gesture recogniser
        // can be rebuilt out from under it.
        hosting?.takesTheClick = IslandBehaviour.hostViewTakesTheClick(current: target)
        let root = IslandView(conductor: conductor,
                              presentation: target,
                              notchSize: notch,
                              capsule: capsule,
                              micOpenSomewhere: capsule != nil && MicIndicatorWatch.shared.open,
                              contentSize: content,
                              draft: draft,
                              // A panel that opened itself must not swallow the
                              // next keystroke — §7.
                              takesFocus: !selfOpened,
                              onTap: { [weak self] in self?.tapped() },
                              onHover: { [weak self] in self?.setHovering($0) },
                              onClose: { [weak self] in self?.foldByHand() },
                              onOpenChat: { [weak self] in self?.onOpenWindow?() },
                              onDetach: { [weak self] in self?.detach() })
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                hosting?.rootView = root
            }
        } else {
            hosting?.rootView = root
        }
    }

    /// A click on the island. During a meeting it opens the panel here —
    /// transcript, chat, the field — rather than the window: that is where
    /// "click to type" goes. Otherwise the window, as before.
    ///
    /// §3: a click *inside* an open meeting panel does nothing. The gesture
    /// covers the whole island, so the transcript, the space beside the
    /// field — anything that is not itself a button — used to fold the panel
    /// away, and getting back cost another click. The chevron closes it.
    private func tapped(at x: CGFloat? = nil) {
        // Folded while Moe has the screen, the right ear reads "Using Safari
        // · Stop", and a click on the Stop is a stop — the one control a
        // person may need mid-flight, so it is not a click away behind the
        // panel. Anywhere else on the island opens it, as always.
        if presentation == .collapsed, let x, let screen = hostScreen {
            let notch = notchSize(of: screen)
            let capsule = capsule(of: screen)
            // On a capsule the right side starts at the camera's edge, or
            // past the system's microphone pill while that may be showing.
            let live = indicatorLive(capsule)
            let drawn = capsule.map { 2 * CapsuleIsland.inner($0, indicatorLive: live).right }
                ?? (notch.width > 0 && notch.height > 0 ? notch.width : NotchGeometry.virtualNotch.width)
            let right = IslandEars.of(IslandView.earInputs(conductor, open: false, waiting: earWaiting,
                                                           capsule: capsule != nil)).right
            let cap = capsule.map { CapsuleIsland.reach($0, left: 0, right: .infinity, indicatorLive: live).right }
            if IslandEars.hitsStop(xFromCentre: x, notchWidth: drawn, right: right,
                                   maximumReach: cap ?? .infinity,
                                   measure: IslandView.earMeasure) {
                Log.write("island: Stop pressed on the folded island's driving ear")
                conductor.stopEverything()
                return
            }
        }
        if chatIsOut {
            floating?.handle(.summon)
            return
        }
        switch IslandBehaviour.click(current: presentation, meetingOn: meetingOn) {
        case .ignore:
            return
        case .open:
            // Muted, the click that opens is written down: on 2026-09-25 the
            // owner's mute "unmuted itself" six times and nothing in the log
            // said what the island was doing just before.
            if conductor.micMuted {
                Log.write("island: clicked \(showingMutedTab ? "the muted tab" : "the notch") (\(presentation)); "
                          + "opening it — still muted")
            }
            openByHand()
        }
    }

    /// Open the panel because the person asked: any click on the collapsed
    /// island or a hover peek (`IslandBehaviour.click`, 2026-09-24 — a click
    /// on the island opens it here, never the window).
    func openByHand() {
        if chatIsOut { floating?.handle(.summon); return }
        collapseTask?.cancel()
        // Opened by hand, so it is the user's: it keeps the keyboard, and no
        // clock folds it. A click in another app does (2026-09-25): since a
        // click on the island opens it rather than the window, a panel
        // opened that way had no way out but ⌃ or Esc, and the owner found it
        // stuck open with the ⌃ out of reach. The draft in its field is kept
        // for when it opens again.
        endReveal()
        apply(.expanded, animated: true)
        panel?.makeKey()
        watchForOutsideClick()
    }

    /// A meeting is on and dictation is not — the state in which the island
    /// is the meeting panel. One definition, used by every rule here.
    private var meetingOn: Bool {
        conductor.meeting != .off && conductor.dictation == .off
    }

    /// The chat is in its own window, and this is not a meeting or a
    /// dictation — which are the notch's own panels and keep it.
    var chatIsOut: Bool {
        guard let floating else { return false }
        return FloatingChat.routesToWindow(floating.placement, meetingOn: meetingOn,
                                           dictating: conductor.dictation != .off)
    }

    /// The header's pop-out: the chat leaves the notch. The draft, the
    /// tray and the conversation go with it, because they were never the
    /// notch's: the window draws the same Conductor and the same draft.
    func detach() {
        floating?.handle(.detach)
    }

    /// The window came, went, or docked. Out: the notch's card folds at once
    /// (never two cards). Docked: the card opens where it always was, so the
    /// conversation does not vanish on the way back.
    func placementChanged(_ placement: ChatPlacement, docked: Bool) {
        if placement.isDetached {
            if presentation.isOpen { foldByHand() } else { apply(presentation, animated: false) }
        } else if docked {
            openByHand()
        } else {
            apply(presentation, animated: false)
        }
    }

    /// The hover zone, as a size measured down from the top of the window,
    /// and how far its centre sits right of the window's.
    ///
    /// Deliberately NOT an NSRect: `NSHostingView` is flipped, so a rect built
    /// with a bottom-left origin silently lands at the *bottom* of the window —
    /// which made the island drop down when the cursor was nowhere near the
    /// notch.
    ///
    /// Folded, it is the notch and whichever ears are out (`IslandEars`) —
    /// and only those: a notice's ear is two hundred points of menu bar on
    /// the right, and a zone centred on the notch would have taken the same
    /// two hundred points of clicks on the left, where nothing is drawn.
    ///
    /// On a floating capsule the folded zone is still measured from the top
    /// edge of the screen and is never narrower than `minimumTargetWidth`:
    /// the drawn capsule is 58 pt, and the target is not.
    private func hoverZone(for target: Presentation, content: CGSize, notch: CGSize,
                           capsule: NotchGeometry.CapsuleCutout?) -> (size: CGSize, shift: CGFloat) {
        let base = NotchGeometry.targetWidth(for: notch)
        guard target == .collapsed else {
            return (CGSize(width: max(content.width, base), height: notch.height + content.height), 0)
        }
        let r = IslandView.earReach(IslandEars.of(IslandView.earInputs(conductor, open: false,
                                                                       waiting: earWaiting,
                                                                       capsule: capsule != nil)))
        let drawn = notch.width > 0 && notch.height > 0 ? notch.width : NotchGeometry.virtualNotch.width
        var left = max(base / 2, drawn / 2 + r.left)
        var right = max(base / 2, drawn / 2 + r.right)
        if let capsule {
            // What is drawn (`CapsuleIsland.folded`): past the system's
            // microphone pill while that may be showing.
            let f = CapsuleIsland.folded(capsule, leftReach: r.left, rightReach: r.right,
                                         indicatorLive: indicatorLive(capsule))
            left = max(base / 2, -f.minX)
            right = max(base / 2, f.maxX)
        }
        return (CGSize(width: left + right, height: notch.height + content.height), (right - left) / 2)
    }

    /// The open card on a floating capsule starts below the top of the
    /// screen, and the strip of menu bar above it is not the island's: a
    /// click there goes to the menu bar. Only the column over the camera
    /// stays the island's (`IslandHostingView.hoverLift`), so a pointer
    /// resting at the top edge, where the resting target reaches, does not
    /// fall out of the panel it just opened.
    private func hoverLift(for target: Presentation, notch: CGSize,
                           capsule: NotchGeometry.CapsuleCutout?) -> (inset: CGFloat, stem: CGFloat) {
        guard let capsule, target == .peek || target == .expanded else { return (0, 0) }
        return (capsule.topGap, NotchGeometry.targetWidth(for: notch))
    }

    /// `IslandView.attentionWaiting`, read from here: the right ear's dot is
    /// a point larger when something is waiting.
    private var earWaiting: Bool {
        IslandGlow.glows(nudgeHeld: conductor.hasUnseenNotice,
                         updateNoticeShowing: UpdateReadyNotice.shared.showing(for: conductor),
                         callOffered: conductor.meetingOffer != nil)
    }

    /// The ears come and go with what Moe is doing — a notice, a mute, a
    /// meeting, the screen — and the click target has to follow them, or a
    /// notice's ear is drawn where clicks fall through to the menu bar. The
    /// view redraws them by itself; this only moves the zone.
    private func refreshEarZone() {
        guard presentation == .collapsed, let screen = hostScreen, let hosting else { return }
        let zone = hoverZone(for: .collapsed, content: drawnContent, notch: notchSize(of: screen),
                             capsule: capsule(of: screen))
        if zone.size != hosting.hoverZone || zone.shift != hosting.hoverShift {
            hosting.hoverZone = zone.size
            hosting.hoverShift = zone.shift
        }
    }

    func collapseSoon(after seconds: Double = 4) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.presentation == .expanded else { return }
                self.apply(self.cursorIsOverIsland() ? .peek : .collapsed, animated: true)
            }
        }
    }

    // MARK: - Visibility (§4) and the self-opening panel (§7)

    /// "Be visible." A wake word, a nudge, a meeting bookmark, the
    /// push-to-talk key — a dozen ordinary events want the island on screen,
    /// and every one of them used to be answered with a collapse, which
    /// slammed an open meeting panel shut mid-sentence. An island that is
    /// already on screen is already visible. §4.
    func reveal() {
        if let target = IslandBehaviour.visibility(.wantsVisible, current: presentation) {
            show(expanded: target == .expanded)
        }
        panel?.orderFrontRegardless()
    }

    /// "Be closed." The other half of §4: the conversation ended, the nudge
    /// was dismissed, everything was stopped. This is the one that folds.
    func dismiss() {
        collapseTask?.cancel()
        endReveal()
        if let target = IslandBehaviour.visibility(.dismissed, current: presentation) {
            apply(target, animated: true)
        }
        panel?.orderFrontRegardless()
    }

    /// Moe answered. Open the panel so the answer is read, because during a
    /// meeting — and anywhere spoken replies are off — the panel is the only
    /// place the answer exists. §5 gives the signal; §7 is this.
    ///
    /// Never takes the keyboard: a panel that opened itself and then
    /// swallowed the next keystroke is the worse interruption. It folds again
    /// after long enough to read, and a second answer restarts that clock
    /// rather than cancelling it, because a second answer is more to read.
    /// A call to record, or a call that ended: open for the question, the way
    /// an answer opens — in front, never with the keyboard, folding on a click
    /// elsewhere — but with no reading clock: a question stays until answered
    /// or put away.
    func revealOffer() {
        if chatIsOut { floating?.handle(.summon, focus: false); return }
        panel?.orderFrontRegardless()
        if presentation == .expanded { return }
        collapseTask?.cancel()
        selfOpened = true
        apply(.expanded, animated: true)
        watchForOutsideClick()
    }

    func revealReply() {
        // `replySpeaks`, not the master switch: whether *this* answer reached
        // the person by ear is the question, and since the reply modes split
        // that is a different thing from whether Moe speaks at all. A typed
        // question with speech left on used to be judged "spoken" here and
        // the panel stayed shut over an answer nobody was ever told.
        guard ReplyReveal.opens(meetingOn: meetingOn,
                                speaksReply: conductor.replySpeaks,
                                policy: PanelReveal(configValue: conductor.config.panelOnReply),
                                transcriptOn: conductor.showsTranscript)
        else { return }
        // The chat is in its window: the answer is shown there, in front and
        // without the keyboard, and the window is not folded by a clock —
        // it was put where it is not in the way.
        if chatIsOut { floating?.handle(.summon, focus: false); return }
        // Front, but not key: `orderFrontRegardless` shows a non-activating
        // panel over the call without taking the user's app away from them.
        panel?.orderFrontRegardless()
        // Already open, and opened by hand: the answer lands in the panel
        // they opened, and that one is theirs to close. Starting a fold clock
        // on it would take away a panel nobody asked this to take away.
        if presentation == .expanded, !selfOpened { return }
        collapseTask?.cancel()
        // Before `apply`, so the view is built without the focus grab.
        selfOpened = true
        apply(.expanded, animated: true)
        watchForOutsideClick()
        // A second answer restarts the clock rather than cancelling it: a
        // second answer is more to read, not a reason to stay forever.
        startReadingClock()
    }

    /// The panel's own way out: the fold button, and Escape.
    ///
    /// Not just `apply(.collapsed)`. A panel that opened itself is still
    /// carrying two pieces of state after it closes — `selfOpened`, and a
    /// reading clock that re-arms — and leaving them behind means the next
    /// answer finds the panel already believing it self-opened, and starts a
    /// second clock beside the first. Closing by hand ends all three.
    ///
    /// It deliberately does *not* touch the turn. Folding is "I have read
    /// this", not "stop what you are doing"; the ✕ beside it is the one that
    /// means the second thing, and it is only offered while Moe is busy.
    private func foldByHand() {
        revealTask?.cancel()
        revealTask = nil
        selfOpened = false
        apply(.collapsed, animated: true)
    }

    /// The reading clock. It re-arms rather than firing once, so a panel held
    /// open by a resting cursor or a half-typed question still folds the
    /// moment that stops being true.
    private func startReadingClock() {
        revealTask?.cancel()
        // Nil means "until I dismiss it": no clock is started at all, and the
        // panel then folds only the way any hand-opened one does — an outside
        // click, or the person collapsing it. Twelve seconds is a good length
        // for two spoken sentences and a poor one for the paragraphs a typed
        // reply is now allowed to be.
        guard let reading = ReplyReveal.readingTime(seconds: conductor.config.replyReadingSeconds)
        else { return }
        revealTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(reading * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let again = await MainActor.run { () -> Bool in
                    guard let self, self.selfOpened, self.presentation == .expanded else { return false }
                    // `isKeyWindow` is the honest read of "clicked into the
                    // field and thinking": with `becomesKeyOnlyIfNeeded` the
                    // panel takes key for the text field and nothing else,
                    // and gives it up the moment the call window is clicked.
                    switch ReplyReveal.due(cursorOverIsland: self.cursorIsOverIsland(),
                                           draftInProgress: self.draft.inProgress,
                                           holdsTheKeyboard: self.panel?.isKeyWindow == true) {
                    case .wait: return true
                    case .fold: self.apply(.collapsed, animated: true); return false
                    }
                }
                if !again { return }
            }
        }
    }

    /// A click in another app gives up at once — the panel is sitting over
    /// somebody's video call. A global monitor does not see events delivered
    /// to this app, but the panel is non-activating and the island is exactly
    /// the surface a stray click lands on, so the pointer is checked too.
    private func watchForOutsideClick() {
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selfOpened || self.presentation == .expanded else { return }
                guard ReplyReveal.outsideClickFolds(cursorOverIsland: self.cursorIsOverIsland()) else { return }
                self.apply(.collapsed, animated: true)
            }
        }
    }

    /// Put down everything the self-opened panel was holding. Idempotent:
    /// `apply` calls it on the way to any state that is not the open panel,
    /// which includes the fold this itself causes.
    private func endReveal() {
        revealTask?.cancel()
        revealTask = nil
        if let monitor = outsideClick {
            NSEvent.removeMonitor(monitor)
            outsideClick = nil
        }
        selfOpened = false
    }

    func hide() {
        collapseTask?.cancel()
        hoverExitTask?.cancel()
        // Stay on screen but draw nothing: the panel must remain available for
        // the hover-to-peek gesture, and re-creating it each time is what made
        // the island flicker.
        presentation = .collapsed
        apply(.collapsed, animated: false)
    }

    private func reposition() {
        guard presentation != .hidden, let panel, let screen = hostScreen else { return }
        panel.setFrame(windowFrame(on: screen), display: true)
        apply(presentation, animated: false)
    }

    // MARK: - Files dragged onto the notch

    private var dragWatch: Task<Void, Never>?
    /// Whether this drag is what opened the panel, so a drag that ends with
    /// nothing dropped folds only a panel it opened itself.
    private var dragOpened = false

    /// A file is being dragged at the notch. The panel opens and is held open
    /// for the rest of the drag, wherever the pointer goes: a drag is not a
    /// hover, and the hover rule would fold the panel the moment the pointer
    /// strayed on its way to letting go.
    private func dragArrived() {
        // A meeting panel's field has nowhere to show a file, and one that
        // cannot be seen must not ride along with the next question.
        guard !meetingOn else { return }
        // Out in its window, the chat takes files dropped on the window.
        if chatIsOut { return }
        collapseTask?.cancel()
        hoverExitTask?.cancel()
        if dragWatch == nil {
            dragOpened = presentation != .expanded
        }
        if presentation != .expanded {
            endReveal()
            apply(.expanded, animated: true)
        }
        dragWatch?.cancel()
        dragWatch = Task { [weak self] in
            // The one end-of-drag signal that still reaches a window the drag
            // has left: the button coming up, wherever that happened.
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Room for a drop that landed here to arrive first.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.dragEnded()
        }
    }

    private func dragEnded() {
        dragWatch = nil
        defer { dragOpened = false }
        guard dragOpened, presentation == .expanded, !draft.inProgress, !cursorIsOverIsland() else { return }
        apply(.collapsed, animated: true)
    }

    private func dropped(_ pasteboard: NSPasteboard) -> Bool {
        guard !meetingOn else { return false }
        let taken = AttachmentIntake.take(from: pasteboard)
        guard !taken.isEmpty else { return false }
        draft.attachments.append(contentsOf: taken)
        if chatIsOut { floating?.handle(.summon); return true }
        if presentation != .expanded {
            endReveal()
            apply(.expanded, animated: true)
        }
        // The keyboard, without activating Moe: the next thing is to say
        // what the file is for.
        panel?.makeKey()
        return true
    }

    // MARK: - Construction

    private func build(on screen: NSScreen) -> NSPanel {
        let notch = notchSize(of: screen)
        let capsule = capsule(of: screen)
        let content = contentSize(for: .collapsed, notch: notch, accessibility: liveAccessibility)
        let view = IslandView(conductor: conductor,
                              presentation: .collapsed,
                              notchSize: notch,
                              capsule: capsule,
                              micOpenSomewhere: capsule != nil && MicIndicatorWatch.shared.open,
                              contentSize: content,
                              draft: draft,
                              takesFocus: true,
                              onTap: { [weak self] in self?.tapped() },
                              onHover: { [weak self] in self?.setHovering($0) },
                              onClose: { [weak self] in self?.foldByHand() },
                              onDetach: { [weak self] in self?.detach() })
        let host = IslandHostingView(rootView: view)
        host.onClick = { [weak self] x in self?.tapped(at: x) }
        host.takesTheClick = IslandBehaviour.hostViewTakesTheClick(current: .collapsed)
        host.onDragEntered = { [weak self] in self?.dragArrived() }
        host.onDrop = { [weak self] in self?.dropped($0) ?? false }
        host.registerForDraggedTypes(AttachmentIntake.draggedTypes)
        hosting = host

        if capsule != nil, micObserver == nil {
            micObserver = MicIndicatorWatch.shared.$open
                .removeDuplicates()
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, self.presentation.isOnScreen else { return }
                    self.apply(self.presentation, animated: true)
                }
        }

        let frame = windowFrame(on: screen)
        let zone = hoverZone(for: .collapsed, content: content, notch: notch, capsule: capsule)
        host.hoverZone = zone.size
        host.hoverShift = zone.shift

        let p = IslandPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        // The island is dark in both appearances (docs/PANEL-FINDINGS.md §8):
        // it grows out of a black cutout. Everything SwiftUI draws here is
        // painted black or white-at-an-opacity and never asked the Mac. The
        // AppKit-backed pieces did — the text field's editor, its caret and
        // selection, the checkbox — so on a Mac in light mode the "Ask Moe"
        // box came up light inside a black panel, and dark again the next
        // time the Mac was dark. "Sometimes the chat box is dark, and
        // sometimes it's not." Pinning the window settles every control.
        p.appearance = NSAppearance(named: .darkAqua)
        p.hasShadow = false
        p.isMovable = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 8)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        // §1, part one. Clicking a window that is not key spends that click on
        // making it key and never delivers it to the view — and during a
        // meeting Moe is never the active app, so that was every click. With
        // this, clicking the tab does not ask for the keyboard at all; only
        // the text field does, and `makeKey()` still works when it is asked
        // for explicitly.
        p.becomesKeyOnlyIfNeeded = true
        // Without this a non-activating panel never sees the cursor and
        // .onHover would never fire.
        p.acceptsMouseMovedEvents = true
        panel = p
        return p
    }
}

/// A borderless panel cannot take keyboard focus by default; the meeting
/// panel has a text field, so this one can — without activating the app,
/// which would pull the user's meeting window back.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view that only accepts the mouse where the island is actually drawn.
///
/// The panel is permanently as large as the biggest island state. Without this
/// it would eat clicks across a 460pt-wide band at the top of every screen,
/// the menu bar included.
final class IslandHostingView: NSHostingView<IslandView> {
    /// Width, and height measured down from the top edge.
    var hoverZone: CGSize = .zero
    /// How far the zone's centre sits right of the view's: the folded
    /// island's ears are not symmetric (`NotchIsland.hoverZone`).
    var hoverShift: CGFloat = 0
    /// A floating capsule's open card: the top `inset` points of the zone
    /// belong to the menu bar, except a column `stem` wide over the camera.
    /// Zero everywhere else (`NotchIsland.hoverLift`).
    var hoverLift: (inset: CGFloat, stem: CGFloat) = (0, 0)

    /// §1, part three — the part of the first-click fix that cannot fail.
    ///
    /// While the island is collapsed every drawn thing is
    /// `allowsHitTesting(false)`: the halo, the working arc, the consent ring
    /// and the meeting tab. So `hitTest` returns *this view*, and it handles
    /// `mouseDown` itself. No gesture recogniser, nothing SwiftUI can rebuild
    /// mid-click, and — with `acceptsFirstMouse` below — nothing that a
    /// window which is not key can swallow.
    var takesTheClick = false
    /// What that click does, given how far right of the notch's centre it
    /// landed. `NotchIsland.tapped(at:)`.
    var onClick: ((CGFloat) -> Void)?

    /// Deliver the click even though this window is not key. During a meeting
    /// Moe is never the active app, and without this the first click on the
    /// island is spent making the window key and never reaches anything —
    /// which is the whole of "click, then click again".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard takesTheClick else { super.mouseDown(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        onClick?(local.x - bounds.midX)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Work out the distance from the top regardless of whether this view
        // is flipped, because NSHostingView is and that is easy to forget.
        let fromTop = isFlipped ? local.y : bounds.height - local.y
        let fromCentre = abs(local.x - (bounds.midX + hoverShift))
        guard fromTop >= 0, fromTop <= hoverZone.height,
              fromCentre <= hoverZone.width / 2 else { return nil }
        if fromTop < hoverLift.inset, abs(local.x - bounds.midX) > hoverLift.stem / 2 { return nil }
        return takesTheClick ? self : super.hitTest(point)
    }

    /// A file dragged over the notch. `NotchIsland.dragArrived()`.
    var onDragEntered: (() -> Void)?
    /// A file let go over it. `NotchIsland.dropped(_:)`.
    var onDrop: ((NSPasteboard) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AttachmentIntake.canTake(sender.draggingPasteboard) else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        AttachmentIntake.canTake(sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}
