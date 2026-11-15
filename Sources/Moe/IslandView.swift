import AppKit
import MoeBrain
import MoeChat
import MoeDesign
import MoeIsland
import MoeMeeting
import MoeVoice
import SwiftUI

/// What the island draws.
///
/// The window this lives in is permanently large (it never resizes, or hover
/// would flicker), so this view has to place itself and — critically — confine
/// the hover target to the island's own bounds.
///
/// That last point is the bug that made it "pop up from a couple of inches
/// away": `.onHover` is driven by an `NSTrackingArea` covering whatever view it
/// is attached to. Putting it on a container that filled the window meant the
/// whole top strip of the screen was a trigger. Overriding `hitTest` does not
/// help — that governs clicks, not tracking areas. The modifier must go on a
/// view that is exactly the size of the intended target.
struct IslandView: View {
    @ObservedObject var conductor: Conductor
    let presentation: NotchIsland.Presentation
    let notchSize: CGSize
    /// The Mac's floating camera capsule, when its cutout is one
    /// (`NotchGeometry.Cutout`). `notchSize` is then only the box the menu
    /// bar avoids; this is the glass. Nil on every other Mac, which draws
    /// exactly as it always did.
    var capsule: NotchGeometry.CapsuleCutout? = nil
    /// Some app has the microphone open, so macOS is drawing its indicator
    /// beside the capsule (`MicIndicatorWatch`). Memoe's own microphone is
    /// counted without being told (`indicatorLive`).
    var micOpenSomewhere = false
    let contentSize: CGSize
    /// The half-typed question. Held outside the view so the clock that
    /// folds a self-opened panel can see it — docs/PANEL-FINDINGS.md §7.
    @ObservedObject var draft: IslandDraft
    /// False when the panel opened itself because Moe answered: it is showing
    /// you something, not asking for something, and a panel that swallowed
    /// the next keystroke would be the worse interruption. §7.
    var takesFocus: Bool = true
    let onTap: () -> Void
    let onHover: (Bool) -> Void
    /// Fold the panel back (the × on a meeting panel).
    var onClose: () -> Void = {}
    /// The ⋯ tray's window icon: the whole conversation in the Memoe window.
    var onOpenChat: () -> Void = {}
    @State private var handOffKey = KeyWatch()
    /// The header's pop-out: the chat leaves the notch for a window of its
    /// own (`FloatingChatWindow`).
    var onDetach: () -> Void = {}
    /// Set when this is the floating window rather than the notch: the same
    /// view, the same rows, the same field and tray, in a movable,
    /// resizable window. Nil on the notch, which draws exactly as before.
    var floating: FloatingChrome? = nil
    private var asked: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }
    /// The mid-meeting field takes focus as soon as the panel opens. Opening
    /// it and then having to click into the field was two clicks for one
    /// intention — and the intention is obvious, because asking is the only
    /// thing the expanded panel is for.
    @FocusState private var askFocused: Bool
    /// Whether the talk key can work. Said on hover and on the open panel, because
    /// a dead talk key used to be announced only in the log.
    @ObservedObject private var ax = AccessibilityWatch.shared
    /// A downloaded update waiting for a restart (docs/DEFAULTS.md row 47).
    @ObservedObject private var updateNotice = UpdateReadyNotice.shared
    /// The nudge card's Reply field: whether it is open, and what is in it.
    /// The field takes the place of the card's buttons, so opening it costs
    /// no height and the panel is not laid out again under the cursor.
    @State private var flashOn = false
    /// Which of the two things the expanded meeting panel shows: what you
    /// and Moe have said to each other, or what the room is saying.
    enum MeetingPage { case chat, transcript, todo }
    /// Nil until the person picks. A meeting opens on the transcript,
    /// because that is what the panel is opened to look at; everything else
    /// opens on Chat.
    ///
    /// It used to depend on `turns.isEmpty` too, so the page you got
    /// changed the first time you asked Moe anything and never changed
    /// back — the panel you opened to read the room reopened on your own
    /// conversation for the rest of the call.
    @State private var chosenPage: MeetingPage?
    private var meetingPage: MeetingPage {
        get { chosenPage ?? (conductor.meeting.isRecording ? .transcript : .chat) }
        nonmutating set { chosenPage = newValue }
    }
    /// True only while `ImageRenderer` is drawing this for
    /// `Moe --panel-snapshot` (docs/PANEL-FINDINGS.md §9). False in the
    /// running app, always. See IslandSnapshotSeam.swift for why the two
    /// controls below need a stand-in offscreen.
    @Environment(\.islandSnapshot) private var snapshotting
    @Environment(\.islandPosedAccessibility) private var posedAccessibility
    /// Reduce Motion: shapes change at once, and nothing loops.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The talk-key row's sentence, or nil when there is nothing to say.
    private var accessibilityProblem: String? {
        if snapshotting { return posedAccessibility }
        return ax.granted ? nil : ax.problem(for: conductor.config.talkKey)
    }

    private var isOpen: Bool {
        presentation == .peek || presentation == .expanded
    }

    // MARK: - The folded island: ears, not a halo (2026-10-15)

    /// The two ears either side of the folded notch (`IslandEars`): Moe's
    /// presence, your voice, and anything it has to tell you. Internal so the
    /// tests can read them off a real view.
    var ears: (left: IslandEars.Left?, right: IslandEars.Right?) {
        IslandEars.of(Self.earInputs(conductor, open: isOpen, waiting: attentionWaiting,
                                     capsule: capsule != nil))
    }

    /// Whether macOS may be drawing its microphone pill round the capsule
    /// (`NotchGeometry.SystemIndicator`): this is a capsule Mac, and the
    /// microphone is open — Memoe's, known the moment it opens, or anyone's.
    var indicatorLive: Bool {
        capsule != nil && (micOpenSomewhere || Self.usesMicrophone(conductor))
    }
    /// Memoe itself has the microphone: listening, in a conversation,
    /// waiting for its name, dictating, or recording a meeting.
    static func usesMicrophone(_ c: Conductor) -> Bool {
        c.mode == .listening || c.inConversation || c.alwaysListening
            || c.dictation != .off || c.meeting.isRecording
    }

    /// Collapsed and muted: the left ear says "Muted". Kept under its old
    /// name because it is the same promise — muted is visible folded — read
    /// off the ear that now keeps it.
    var showsMutedTab: Bool { ears.left == .muted }

    /// What the ears are decided from. Static so `NotchIsland` sizes the
    /// click target from exactly what this view draws.
    static func earInputs(_ c: Conductor, open: Bool, waiting: Bool,
                          capsule: Bool = false) -> IslandEars.Inputs {
        var i = IslandEars.Inputs()
        i.capsule = capsule
        if capsule, c.dictation == .off, busy(c) {
            i.workingWord = c.workingStep?.isEmpty == false ? "Working" : "Thinking"
        }
        let dictationOn = c.dictation != .off
        i.open = open
        i.listening = c.mode == .listening
        i.betweenTurns = c.betweenTurns
        i.speaking = c.mode == .speaking
        i.working = c.dictation == .transcribing || (!dictationOn && busy(c))
        i.muted = c.micMuted
        i.replyPaused = c.mode == .speaking && c.replyHeldByKey
        i.stopped = c.showingStopped
        i.dictationOn = dictationOn
        i.dictating = c.dictation == .listening
        i.recording = c.meeting.isRecording
        i.meetingPaused = c.meetingPaused
        i.whisper = c.meetingWhisper
        i.meetingLine = dictationOn ? nil : meetingEarLine(c)
        if c.meeting == .off, !dictationOn, let n = c.noticePeek { i.noticeLine = NoticeTab.earLine(n) }
        i.waiting = waiting
        if let app = c.drivingApp { i.driving = "Using \(app)" } else if c.browsing { i.driving = "Browsing" }
        return i
    }

    /// The meeting's news for the right ear; nil while it is only recording.
    static func meetingEarLine(_ c: Conductor) -> String? {
        switch c.meeting {
        case .off: return nil
        case .starting: return "Starting…"
        case .stopping: return "Writing notes…"
        case .done: return "Notes ready"
        case .recording:
            let n = c.meetingLiveActions.count
            return n == 0 ? nil : "\(n) action item\(n == 1 ? "" : "s")"
        }
    }

    /// The ears' words are measured at the font they are drawn in.
    static let earFont = NSFont.systemFont(ofSize: IslandEars.textSize, weight: .medium)
    static func earMeasure(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: earFont]).width)
    }

    /// How far each ear reaches past the notch's edge.
    static func earReach(_ e: (left: IslandEars.Left?, right: IslandEars.Right?)) -> (left: CGFloat, right: CGFloat) {
        (IslandEars.reach(e.left, measure: earMeasure), IslandEars.reach(e.right, measure: earMeasure))
    }

    /// Something just arrived (`Conductor.noticePeek`). Never during a
    /// meeting or dictation, which own the ears then.
    static func showsNoticeTab(_ c: Conductor, presentation: NotchIsland.Presentation) -> Bool {
        presentation == .collapsed && c.noticePeek != nil && c.meeting == .off && c.dictation == .off
    }

    /// The notch as it is drawn: the hardware's, or the stand-in's.
    private var drawnNotch: CGSize { capsule?.size ?? (hasNotch ? notchSize : NotchGeometry.virtualNotch) }

    /// How far each side reaches past the cutout. A capsule's growth is
    /// capped (`CapsuleIsland.maximumLeftReach`); a notch's ears are not.
    private var reach: (left: CGFloat, right: CGFloat) {
        let r = Self.earReach(ears)
        guard let capsule else { return r }
        return CapsuleIsland.reach(capsule, left: r.left, right: r.right, indicatorLive: indicatorLive)
    }

    /// How far the folded island runs each side of the cutout's centre.
    /// On a capsule that is `CapsuleIsland.folded`, which steps round the
    /// system's microphone pill.
    private var foldedExtent: (left: CGFloat, right: CGFloat) {
        let r = reach
        guard let capsule else { return (drawnNotch.width / 2 + r.left, drawnNotch.width / 2 + r.right) }
        let f = CapsuleIsland.folded(capsule, leftReach: r.left, rightReach: r.right,
                                     indicatorLive: indicatorLive)
        return (-f.minX, f.maxX)
    }

    /// The hover and click target: the notch and its ears folded, the panel
    /// open. Symmetric about the notch, because the window is centred on it;
    /// `hitShape` trims it to what is really drawn.
    private var targetWidth: CGFloat {
        let base = NotchGeometry.targetWidth(for: notchSize)
        if isOpen { return max(contentSize.width, base) }
        let e = foldedExtent
        return max(base, 2 * max(e.left, e.right))
    }
    private var targetHeight: CGFloat {
        if isOpen { return notchSize.height + contentSize.height }
        // At rest the target is the notch — and on a Mac without one it was
        // therefore zero points tall, so `.onHover` had no area to track and
        // hovering never opened the island on a MacBook Neo, an M1 Air or an
        // external display. The drawn stand-in is the target there.
        return notchSize.height > 0 ? notchSize.height : NotchGeometry.virtualNotch.height
    }

    /// Folded, the notch and the ears that are out — not the blank menu bar
    /// on the side without one. Open, the whole frame.
    private var hitShape: IslandHitShape {
        let base = NotchGeometry.targetWidth(for: notchSize)
        // A capsule's open card floats: the strip above it is the menu
        // bar's, except the column over the camera (`NotchIsland.hoverLift`).
        if isOpen { return IslandHitShape(full: true, topInset: capsule?.topGap ?? 0, stem: base) }
        let e = foldedExtent
        return IslandHitShape(full: false,
                              left: max(base / 2, e.left),
                              right: max(base / 2, e.right))
    }

    private var hasNotch: Bool { notchSize.width > 0 && notchSize.height > 0 }

    /// The black tab a Mac without a notch gets in place of one
    /// (`NotchGeometry.virtualNotch`), whenever the island is folded: the
    /// ears and the working light hang off it the way they hang off the
    /// hardware on a notched Mac.
    private var virtualNotch: some View {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 10,
                               bottomTrailingRadius: 10, topTrailingRadius: 0,
                               style: .continuous)
            .fill(Color.black)
            .frame(width: NotchGeometry.virtualNotch.width,
                   height: NotchGeometry.virtualNotch.height)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    var body: some View {
        if let floating { floatingBody(floating) } else { notchBody }
    }

    private var notchBody: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Folded: the ears (`IslandEars`). No halo, no glow, no colour
                // but the recording dot — the owner, 2026-10-15. They are the
                // "Moe is alive" signal and never need a hover.
                // On a floating capsule the island is the capsule, grown
                // sideways (`capsuleView`), and working is a ring inside it.
                if !isOpen { if let capsule { capsuleView(capsule) } else { earsView } }
                // The white light that runs round the notch while Moe works.
                if isWorking && !isOpen && capsule == nil { workingArc }
                if !hasNotch && !isOpen { virtualNotch }
                if isOpen { panel }
            }
            // Sized to the island exactly — this IS the hover zone.
            .frame(width: targetWidth, height: targetHeight, alignment: .top)
            .contentShape(hitShape)
            .onHover(perform: onHover)
            .onTapGesture(perform: onTap)
            // Folded, the island is one thing to VoiceOver: what it is, what
            // it is showing, and that pressing it opens it.
            .accessibilityElement(children: isOpen ? .contain : .ignore)
            .accessibilityLabel(isOpen ? "Memoe panel" : "Memoe")
            .accessibilityValue(isOpen ? "" : foldedAccessibilityValue)
            .accessibilityHint(isOpen ? "" : "Opens the Memoe panel")
            .accessibilityAddTraits(isOpen ? [] : .isButton)
            .accessibilityAction { if !isOpen { onTap() } }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: conductor.meetingFlash) { _, _ in
            // Someone said your name: the recording dot flashes white twice.
            // Reduce Motion: the dot goes white once and comes back, no blink.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16).repeatCount(4, autoreverses: true)) {
                flashOn = true
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { flashOn = false }
            }
        }
    }

    /// Both ears, hanging off the notch's sides.
    ///
    /// Each is a black slab the notch's height, tucked `IslandEars.overlap`
    /// under the cutout so the two read as one object, with its outer bottom
    /// corner rounded. Its inner edge never moves; its width springs, so a
    /// notice slides out from behind the notch and back in again.
    private var earsView: some View {
        let e = ears
        let r = Self.earReach(e)
        let n = drawnNotch
        return ZStack(alignment: .top) {
            ear(trailing: false, reach: r.left, height: n.height, notchWidth: n.width) {
                if let l = e.left { leftEar(l) }
            }
            ear(trailing: true, reach: r.right, height: n.height, notchWidth: n.width) {
                if let rt = e.right { rightEar(rt) }
            }
        }
        .allowsHitTesting(false)
    }

    private func ear<C: View>(trailing: Bool, reach: CGFloat, height: CGFloat, notchWidth: CGFloat,
                              @ViewBuilder _ content: () -> C) -> some View {
        let width = reach > 0 ? IslandEars.overlap + reach : 0
        let inner = notchWidth / 2 - IslandEars.overlap
        let r = IslandEars.cornerRadius
        return UnevenRoundedRectangle(topLeadingRadius: 0,
                                      bottomLeadingRadius: trailing ? 0 : r,
                                      bottomTrailingRadius: trailing ? r : 0,
                                      topTrailingRadius: 0, style: .continuous)
            .fill(Color.black)
            .overlay(alignment: trailing ? .leading : .trailing) {
                HStack(spacing: IslandEars.gap) { content() }
                    .fixedSize()
                    .padding(trailing ? .leading : .trailing, IslandEars.overlap + IslandEars.innerPad)
                    .padding(trailing ? .trailing : .leading, IslandEars.outerPad)
                    .transition(.opacity)
            }
            .clipped()
            .frame(width: width, height: height)
            .offset(x: (trailing ? 1 : -1) * (inner + width / 2))
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: reach)
    }

    // MARK: - The floating capsule (2026-11-12, `CapsuleIsland`)

    /// The folded island on a Mac whose camera floats in a capsule: one black
    /// capsule over the real one — same top gap, same height, same rounding
    /// — that grows sideways to hold whatever each side has to show. With
    /// nothing to show it is the hardware's own rectangle and adds nothing
    /// to the screen; the strip above it stays lit in every state.
    private func capsuleView(_ c: NotchGeometry.CapsuleCutout) -> some View {
        let e = ears
        let r = reach
        let frame = CapsuleIsland.folded(c, leftReach: r.left, rightReach: r.right,
                                         indicatorLive: indicatorLive)
        return Capsule(style: .circular)
            .fill(Color.black)
            .frame(width: frame.width, height: frame.height)
            .overlay(alignment: .leading) {
                if let l = e.left, r.left > 0 {
                    HStack(spacing: IslandEars.gap) { leftEar(l) }
                        .padding(.leading, IslandEars.outerPad)
                        .padding(.trailing, IslandEars.innerPad)
                        .frame(width: r.left, height: frame.height, alignment: .trailing)
                        .clipped()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if let rt = e.right, r.right > 0 {
                    HStack(spacing: IslandEars.gap) { rightEar(rt) }
                        .padding(.leading, IslandEars.innerPad)
                        .padding(.trailing, IslandEars.outerPad)
                        .frame(width: r.right, height: frame.height, alignment: .leading)
                        .clipped()
                        .transition(.opacity)
                }
            }
            // The camera stays where it is: the capsule's own centre moves
            // by half the difference between its two sides.
            .offset(x: frame.midX, y: frame.minY)
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: frame)
            .allowsHitTesting(false)
    }

    /// The working ring: the same crisp white light that runs round a notch
    /// (`IslandTrail`), run round a small circle inside the capsule. Reduce
    /// Motion holds it still.
    private var workingRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: snapshotting || reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = snapshotting || reduceMotion ? 0.3
                : t.truncatingRemainder(dividingBy: IslandTrail.ringLap) / IslandTrail.ringLap
            ZStack {
                Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(p * 360))
            }
            .frame(width: IslandEars.glyph - 1.5, height: IslandEars.glyph - 1.5)
            .frame(width: IslandEars.glyph)
        }
    }

    /// What VoiceOver reads for the folded island: the words its two sides
    /// are showing, or that it is idle.
    private var foldedAccessibilityValue: String {
        let e = ears
        var parts: [String] = []
        switch e.left {
        case .levels?: parts.append("Listening")
        case .speaking?: parts.append("Speaking")
        case .muted?: parts.append(IslandEars.mutedWord)
        case .paused?: parts.append(IslandEars.pausedWord)
        case .stopped?: parts.append(IslandEars.stoppedWord)
        case .dictating?: parts.append("Dictating")
        case .recording(let paused, _)?:
            parts.append(paused ? IslandEars.recordingPausedWord : "Recording a meeting")
        case .working?: break
        case nil: break
        }
        switch e.right {
        case .waiting?: parts.append("Something is waiting for you")
        case .notice(let line)?: parts.append(line)
        case .driving(let words)?: parts.append(words)
        case .meeting(let line)?: parts.append(line)
        case .working(let word, _)?: parts.append(word)
        // A capsule at rest draws no dot for it; VoiceOver still says it.
        case .presence?, nil: if capsule != nil, attentionWaiting, e.left == nil { parts.append("Something is waiting for you") }
        }
        if parts.isEmpty, isWorking { parts.append("Working") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: ", ")
    }

    private func earText(_ s: String) -> some View {
        Text(s)
            .font(Font(Self.earFont))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
    }

    private func earGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: IslandEars.glyph)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func leftEar(_ l: IslandEars.Left) -> some View {
        switch l {
        case .levels:
            levelBars(voice: CGFloat(max(0, min(1, conductor.level))))
        case .speaking:
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { tl in
                // Reduce Motion: the bars stand still at one pose.
                let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
                EarBars(heights: (0..<IslandEars.barCount).map { i in
                    CGFloat(5 + 3 * sin(t * 3 + Double(i) * 1.3))
                })
            }
        case .dictating:
            IBeam()
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 6, height: 10)
                .frame(width: IslandEars.glyph)
            levelBars(voice: CGFloat(max(0, min(1, conductor.level))))
        case .muted:
            earGlyph("mic.slash.fill")
            earText(IslandEars.mutedWord)
        case .paused:
            earGlyph("pause.fill")
            earText(IslandEars.pausedWord)
        case .stopped:
            earGlyph("stop.fill")
            earText(IslandEars.stoppedWord)
        case .recording(let paused, let whisper):
            Circle()
                .fill(flashOn ? Color.white : paused ? Color.white.opacity(0.4) : Self.recordRed)
                .frame(width: 6, height: 6)
            earText(paused ? IslandEars.recordingPausedWord : IslandEars.recordingWord)
            if whisper { earGlyph("waveform") }
        case .working:
            workingRing
        }
    }

    /// Three white bars moved by your voice.
    private func levelBars(voice: CGFloat) -> some View {
        let shape: [CGFloat] = [0.6, 1, 0.7]
        return EarBars(heights: shape.map { 2 + (IslandEars.barMax - 2) * $0 * voice })
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: voice)
    }

    @ViewBuilder
    private func rightEar(_ r: IslandEars.Right) -> some View {
        switch r {
        case .presence:
            Circle().fill(Color.white.opacity(IslandEars.presenceOpacity))
                .frame(width: IslandEars.dotSize, height: IslandEars.dotSize)
        case .waiting:
            Circle().fill(Color.white)
                .frame(width: IslandEars.waitingDotSize, height: IslandEars.waitingDotSize)
        case .notice(let line):
            Circle().fill(Color.white.opacity(0.95))
                .frame(width: IslandEars.waitingDotSize, height: IslandEars.waitingDotSize)
            earText(line)
        case .driving(let words):
            earText(words)
            earText(IslandEars.stopWord)
                .padding(.horizontal, IslandEars.stopPad)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        case .meeting(let line):
            earText(line)
        case .working(let word, let ring):
            if ring { workingRing }
            earText(word)
        }
    }

    /// "‹ Chat  Inbox · 3 waiting" above the list. The way back lives here,
    /// in the header, because the corner icon gives its place to the clock
    /// while Moe works (the owner, 2026-10-30: "sometimes it doesn't show up").
    private var inboxHeader: some View {
        HStack(spacing: 6) {
            Button { conductor.closeInbox() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").accessibilityHidden(true).font(.system(size: 9, weight: .bold))
                    Text("Chat").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(Theme.Island.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Back to the conversation")
            .accessibilityLabel("Back to the conversation")
            Text("Inbox").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Island.ink)
            let n = conductor.islandNotices.count
            if n > 0 {
                Text("\(n) waiting").font(.system(size: 11)).foregroundStyle(Theme.Island.ink3)
            }
            Spacer(minLength: 0)
            Button { conductor.onOpenInboxPage?(nil) } label: {
                Text("Open in app").font(.system(size: 11)).foregroundStyle(Theme.Island.ink3)
            }
            .buttonStyle(.plain)
            .help("The Inbox page in Memoe, with everything done this week")
        }
        .padding(.top, chromeInBand ? 0 : Self.chromeDrop)
        .padding(.horizontal, 2)
    }

    /// A reply open for an inbox item: what the field is for, and the way
    /// out (the owner, 2026-09-29: "how do I exit out?").
    private var replyingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill").accessibilityHidden(true)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.Island.amber)
            Text("Replying to this. Type below and press Return.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Island.ink2)
                .lineLimit(1)
            Spacer(minLength: 0)
            InboxButton("Cancel", style: .normal) { conductor.cancelNoticeReply() }
                .help("Nothing is sent; it stays in your inbox")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.Island.amber.opacity(0.10)))
        .padding(.top, chromeInBand ? 0 : Self.chromeDrop)
    }

    /// "↩ Back to Launch film": the conversation a reply to a notice left.
    private func returnChip(_ r: Conductor.NoticeReturn) -> some View {
        Button { conductor.returnFromNotice() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward").accessibilityHidden(true).font(.system(size: 9, weight: .bold))
                Text("Back to \(r.fromTitle)").font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(Theme.Island.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .padding(.top, chromeInBand ? 0 : Self.chromeDrop)
    }

    private var dictating: Bool { conductor.dictation != .off }

    /// Whether the travelling light should be running.
    ///
    /// It used to be exactly `mode == .thinking`, which is only the stretch
    /// before the first word of a reply. Everything after that — reading a
    /// file, searching mail, a web lookup between two sentences — left `mode`
    /// somewhere else and the trail stopped, so the island sat under a static
    /// glow while Moe was plainly busy. `acting` is true from the first tool
    /// call to the end of the turn, which is the rest of the work.
    ///
    /// Dictation's own pass counts: after the key comes up the transcript goes
    /// to the brain to be tidied, and that second or two was a motionless
    /// lavender glow, indistinguishable from a freeze. Same light, moving.
    private var isWorking: Bool {
        if conductor.dictation == .transcribing { return true }
        // Listening and typing are not work — the halo already says both.
        if dictating { return false }
        return conductor.mode == .thinking || conductor.acting
    }

    /// A light that runs around the outline of the notch while Moe works —
    /// the one moving thing the owner kept (2026-10-15), drawn crisp: white,
    /// no blur, no halo under it. The tail fades in steps rather than through
    /// a blurred stroke.
    ///
    /// The trick is WHERE the animation is applied. Rotating the shape makes a
    /// trimmed arc swing around the centre like the hand of a clock — which is
    /// what the last two attempts did. Moving the trim's start and end along
    /// the path instead makes the light follow the outline itself: down one
    /// side, across the bottom, up the other, round the corners. A snake, not a
    /// hand.
    private var workingArc: some View {
        let w = max(notchSize.width, 120)
        let h = max(notchSize.height, 24)
        let inset: CGFloat = 2.5

        return TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // A still is taken at a fixed point of the lap, with the head on
            // the notch's lower edge: at a random instant it is as likely to
            // be on the top edge, which is off the screen. Reduce Motion
            // holds the light there too: lit, and still.
            let p = snapshotting || reduceMotion ? IslandTrail.snapshotPoint
                : CGFloat(t.truncatingRemainder(dividingBy: IslandTrail.lap) / IslandTrail.lap)

            ZStack {
                ForEach(Array(IslandTrail.tail.enumerated()), id: \.offset) { _, step in
                    TrailSegment(start: p + step.start, length: step.length, radius: 13)
                        .stroke(Color.white.opacity(step.opacity),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .butt))
                }
                TrailSegment(start: p, length: IslandTrail.head, radius: 13)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: w + inset * 2, height: h + inset * 2)
            // The top edge sits off the screen; the sides and the bottom sit
            // `inset` clear of the cutout. It used to ride 2 pt higher, half
            // its stroke hidden under the notch — the blurred head made up
            // for that, and the crisp one cannot.
            .offset(y: -inset)
        }
        .allowsHitTesting(false)
    }
    /// The visible panel, hanging below the notch.
    /// The dropped panel.
    ///
    /// It runs from the very top of the screen, not from the bottom of the
    /// notch. The old shape started at the notch's lower edge and tapered in
    /// to exactly the notch's width, which left a horizontal seam across the
    /// menu bar — a black lid hanging under the hardware, obviously a separate
    /// object. Filling the notch band too, in the same true black as the
    /// bezel, makes the cutout disappear into the panel: on a notched Mac the
    /// notch stops existing while this is open, and on a Mac without one the
    /// panel simply grows from the top edge. One drawing, both machines.
    ///
    /// Only the bottom corners are rounded. The top edge is the screen's.
    /// A blurred shape with room to fade out in.
    ///
    /// The two frames are the whole point. The inner one draws the shape at
    /// the panel's size; the outer one hands the blur a canvas `spill`
    /// points larger on every side, which is where the falloff goes. Blur
    /// first and the falloff is clipped to the shape's own bounds instead,
    /// which is a square of light around a rounded panel. The last frame
    /// reports the panel's size, so the caller lays this out as if it were
    /// the panel itself.
    private func spilled<S: Shape>(_ shape: S, _ colour: Color, size: CGSize,
                                   blur: CGFloat, spill: CGFloat) -> some View {
        shape
            .fill(colour)
            .frame(width: size.width, height: size.height)
            .frame(width: size.width + spill * 2, height: size.height + spill * 2)
            .blur(radius: blur)
            .frame(width: size.width, height: size.height)
    }

    private var panel: some View {
        // A floating capsule opens into a floating card (`CapsuleIsland.card`):
        // its top edge is the capsule's, all four corners are rounded, and
        // the strip of screen above it stays lit. The content sits exactly
        // where it does under a notch; only the black behind it changes.
        let top = capsule?.topGap ?? 0
        let radius: CGFloat = capsule != nil ? CapsuleIsland.cardRadius
            : presentation == .expanded ? 20 : 16
        let shape = IslandCardShape(cornerRadius: radius, floating: capsule != nil)
        return VStack(spacing: 0) {
            // The notch band. Filled rather than clear now — this is the part
            // that swallows the cutout.
            Color.clear.frame(height: notchSize.height)
            content
                .frame(width: contentSize.width, height: contentSize.height)
        }
        .frame(width: contentSize.width)
        // Only the panel and its drop shadow. The state's coloured light used
        // to spill out around it (two blurred lozenges); the owner,
        // 2026-10-15: no more colours or glowing. The shadow is drawn as a
        // blurred copy inside a frame `spill` larger on every side, because a
        // `.shadow` after `.compositingGroup()` is clipped square to the view.
        .background {
            let size = CGSize(width: contentSize.width,
                              height: notchSize.height - top + contentSize.height)
            ZStack {
                spilled(shape,
                        Color.black.opacity(0.5), size: size,
                        blur: 12, spill: 44)
                    .offset(y: 4)
                // The panel itself, last, so the shadow is only ever seen
                // where it spills past this.
                shape
                    .fill(Color.black)
            }
            .padding(.top, top)
        }
        .overlay(
            // Sides and bottom only: a hairline across the top would draw the
            // seam this design exists to remove. A floating card has no seam
            // to hide and is outlined all the way round.
            shape
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                .padding(.top, top)
                .offset(y: capsule == nil ? -2 : 0)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: conductor.mode)
    }

    @ViewBuilder
    private var content: some View {
        // Both open states show the conversation; expanded is simply taller.
        //
        // `peekBody` used to be a separate, smaller thing — a headline, a
        // subline and two buttons, with no field — so hovering gave you
        // something you then had to click again to talk to. One body for both
        // means the first hover already has everywhere you need.
        if dictating { dictationBody }
        else if conductor.meeting != .off { meetingContent }
        else { minimalBody }
    }

    // MARK: - The dropdown (Dropdown, 2026-09-24)

    /// Whether Moe is on a job: before the first word, or any step after it.
    private var busy: Bool { Self.busy(conductor) }
    static func busy(_ c: Conductor) -> Bool { c.mode == .thinking || c.acting }

    private var status: IslandStatus.Status {
        let mode: IslandStatus.Mode = switch conductor.mode {
        case .idle: .idle
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        }
        return IslandStatus.of(mode: mode, acting: conductor.acting,
                               stepKnown: conductor.workingStep?.isEmpty == false,
                               drivingApp: conductor.drivingApp, browsing: conductor.browsing,
                               replyPaused: conductor.replyHeldByKey, muted: conductor.micMuted,
                               inConversation: conductor.inConversation)
    }

    /// White, or grey when quiet: the word beside the dot says which state
    /// it is (2026-10-15 — muted was red, listening green, driving magenta).
    private func toneColour(_ tone: IslandStatus.Tone) -> Color {
        tone == .dim ? .white.opacity(0.38) : Theme.Island.moeLight
    }

    /// One word and a dot, and the clock while Moe works. In the black band
    /// beside the notch when there is one; a row of its own otherwise.
    private var statusWord: some View {
        let s = status
        return HStack(spacing: 7) {
            Circle().fill(toneColour(s.tone)).frame(width: 6, height: 6)
            Text(s.word)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        // On a capsule the word may be shortened to stay on its side of the
        // camera (`bandWord`); everywhere else it is never squeezed.
        .fixedSize(horizontal: capsule == nil, vertical: true)
    }

    /// The clock sits on the other side of the notch, beside the ⌃: on the
    /// left it ran under the notch (and under the recording ring) as soon
    /// as the word was longer than "Working".
    private func bandClock<C: View>(@ViewBuilder _ clock: () -> C) -> some View {
        clock()
            .padding(.trailing, chromeInBand ? 8 + 21 + 8 : 8 + 21 + 8)
            .offset(y: chromeInBand ? bandLift(14) : 5)
    }

    /// The status word in the band, left of the cutout. On a floating capsule
    /// it is held to its own side of the camera and of the system's
    /// microphone pill (`CapsuleIsland.header`): a long word ends in "…"
    /// rather than running under either.
    @ViewBuilder
    private func bandWord<W: View>(@ViewBuilder _ word: () -> W) -> some View {
        if let capsule {
            let room = CapsuleIsland.header(capsule, cardWidth: contentSize.width, inset: Self.bandInset,
                                            height: 14, indicatorLive: indicatorLive).left.width
            word()
                .frame(maxWidth: room, alignment: .leading)
                .padding(.leading, Self.bandInset)
                .offset(y: bandLift(14))
        } else {
            word()
                .padding(.leading, Self.bandInset)
                .offset(y: bandLift(14))
        }
    }
    static let bandInset: CGFloat = 14

    /// How far up from the top of the content something `height` tall goes
    /// to sit centred in the black band beside the camera. Under a notch the
    /// band is the whole cutout's height; on a floating capsule it is the
    /// capsule's own, which starts below the top of the screen.
    private func bandLift(_ height: CGFloat) -> CGFloat {
        let middle = capsule?.midY ?? notchSize.height / 2
        return -(notchSize.height - middle) - height / 2
    }

    /// Moe's latest answer, or its latest system line; nil when your words
    /// are the last thing said.
    private var lastAnswer: Turn? { Self.lastAnswer(conductor) }
    static func lastAnswer(_ c: Conductor) -> Turn? {
        guard let last = c.turns.last, last.role != .you else { return nil }
        return last
    }

    /// Your words: live while you talk, else the last thing you said.
    private var youText: String? { Self.youText(conductor) }
    static func youText(_ c: Conductor) -> String {
        if !c.partial.isEmpty { return c.partial }
        return c.turns.last(where: { $0.role == .you })?.text ?? ""
    }

    /// What goes on Moe's line: the step while it works, else the answer,
    /// else the greeting on a cold start.
    private var moeText: String { Self.moeText(conductor) }
    /// The greeting, on a cold start before anything has been said; the
    /// conversation itself is `chatRows`.
    static func moeText(_ c: Conductor) -> String {
        chatRows(c).isEmpty ? greeting : ""
    }
    /// Whether the dim line of your words is drawn.
    static func showsYouLine(_ c: Conductor) -> Bool {
        !(c.turns.isEmpty && c.partial.isEmpty)
            && (!c.partial.isEmpty || c.turns.contains { $0.role == .you })
    }
    /// Lines of "Noted · Undo" under the answer.
    static func notedCount(_ c: Conductor) -> Int {
        guard !busy(c), let a = lastAnswer(c), a.role == .moe else { return 0 }
        return a.noted.count
    }

    /// Internal, not private: `IslandMuteTests` reads the tray off a real view.
    var trayControls: [IslandTray.Control] {
        Self.trayControls(conductor, driving: islandOverride == .driving)
    }
    static func trayControls(_ c: Conductor, driving: Bool) -> [IslandTray.Control] {
        let answer = busy(c) ? nil : lastAnswer(c)
        return IslandTray.controls(
            working: busy(c), inConversation: c.inConversation, muted: c.micMuted,
            offersWorkSilently: c.offersWorkSilently, workingSilently: c.workingSilently,
            transcriptOn: c.showsTranscript,
            voiced: c.voicedTurnID != nil, replyPaused: c.replyHeldByKey,
            answerPlayable: answer.map { $0.role == .moe && c.canPlayReply($0) } ?? false,
            answerShown: answer?.role == .moe,
            driving: driving)
    }

    /// The compact card (2026-11-12, a floating capsule only): Moe is
    /// working and there is nothing in the conversation to show — the band
    /// beside the camera already says "Thinking". The ⋯ then sits in the
    /// band with the clock and the fold, not alone at the right of an empty
    /// row between the band and the field, and its controls take a row only
    /// while they are out. Never while muted: the Unmute pill lives on that
    /// row and must stay in view.
    static func trayInHeader(_ c: Conductor, chromeInBand: Bool, notch: CGSize) -> Bool {
        chromeInBand && NotchGeometry.isCapsule(notch) && !c.showingInbox && !c.micMuted
            && chatRows(c, statusOnce: true).isEmpty && moeText(c).isEmpty
            && !trayControls(c, driving: false).isEmpty
    }
    private var trayInHeader: Bool {
        capsule != nil && Self.trayInHeader(conductor, chromeInBand: chromeInBand, notch: notchSize)
    }

    private var showsField: Bool { Self.showsField(conductor, draft: draft) }
    static func showsField(_ c: Conductor, draft: IslandDraft) -> Bool {
        Dropdown.showsField(working: busy(c), listening: c.mode == .listening && !c.micMuted,
                               draftInProgress: draft.inProgress)
    }

    /// Whether the ⋯ has slid its icons out. Folds shut with the panel.
    private var trayOpenByHand: Bool {
        get { draft.trayOpen }
        nonmutating set { draft.trayOpen = newValue }
    }
    @Environment(\.islandPosedTrayOpen) private var posedTrayOpen
    @Environment(\.islandPosedSnoozeOpen) private var posedSnoozeOpen
    private var trayOpen: Bool { trayOpenByHand || posedTrayOpen }

    private var minimalBody: some View {
        VStack(alignment: .leading, spacing: Dropdown.Metric.gap) {
            if !chromeInBand { statusWord.frame(height: Dropdown.Metric.statusRow) }
            if conductor.showingInbox {
                // The inbox in the chat's place (docs/INBOX.md): the icon
                // that opened it, pressed again, brings the chat back.
                inboxHeader
                IslandInboxView(conductor: conductor, snoozeOpenFor: posedSnoozeOpen)
            } else {
                if hasBanners { bannersBlock }
                if conductor.replyingTo != nil {
                    replyingBar
                } else if conductor.showsNoticeReturn, let r = conductor.noticeReturn {
                    returnChip(r)
                }
                if chatRows.isEmpty {
                    if !moeText.isEmpty { moeLine }
                } else {
                    chatView
                }
                if controlsRowShown { trayRow }
                if showsField { askField }
            }
        }
        .padding(.top, Dropdown.Metric.top)
        .padding(.bottom, Dropdown.Metric.bottom)
        .padding(.horizontal, Dropdown.Metric.side)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if chromeInBand {
                bandWord { statusWord }
            }
        }
        .overlay(alignment: .topTrailing) { chrome(stop: false) }
        .overlay(alignment: .topTrailing) {
            if status.clock, let since = conductor.workingSince {
                bandClock {
                    HStack(spacing: 6) {
                        WorkingClock(since: since, frozen: snapshotting)
                        // Mid-job too: a long job is when the card is most
                        // in the way. Only where the band has the room.
                        if NotchCardHeader.fits(buttons: 1 + (trayInHeader ? 1 : 0), extra: 34,
                                                room: Double(headerRoom)) {
                            detachButton
                        }
                        if trayInHeader { trayToggle }
                    }
                    .frame(height: 14)
                }
            } else {
                // The inbox, and a new conversation, beside the fold. The
                // conversation on screen is filed in Chat, not lost
                // (`Conductor.newConversation`). Not mid-job, where the clock
                // has this place and a new thread would abandon the work.
                // And the pop-out, beside the fold (`NotchCardHeader.idle`).
                let header = NotchCardHeader.idle(
                    room: Double(headerRoom),
                    newConversation: !conductor.turns.isEmpty && !busy && !conductor.showingInbox,
                    tray: trayInHeader)
                bandClock {
                    HStack(spacing: 6) {
                        InboxIconButton(count: conductor.islandNotices.count,
                                        on: conductor.showingInbox) { conductor.toggleInbox() }
                            .help(conductor.showingInbox ? "Back to the conversation" : "Inbox")
                        if header.newConversation {
                            IslandButton(icon: "square.and.pencil") { conductor.newConversation() }
                                .help("New conversation (this one stays in Chat)")
                                .accessibilityLabel("New conversation")
                        }
                        if header.detach { detachButton }
                        if trayInHeader { trayToggle }
                    }
                    // On a capsule the buttons are centred on the camera's
                    // row with the fold beside them; under a notch they sit
                    // where they always have.
                    .frame(height: capsule == nil ? nil : 14)
                }
            }
        }
        .onChange(of: presentation) { _, p in if p == .collapsed { trayOpenByHand = false } }
        .onExitCommand { onClose() }
    }

    // MARK: - The floating window (FloatingChatWindow, 2026-11-13)

    /// How far the window's conversation fades in at its top edge.
    static let floatingFade: CGFloat = 14

    /// The notch card, out of the notch: its header is a row of its own
    /// (status, clock, then the inbox, a new conversation, keep on top, back
    /// to the notch and close), and the conversation takes whatever height
    /// the window is given. Everything under the header is the notch card's
    /// own — the cards, the chat rows, the ⋯ tray, the field — drawn by the
    /// same code from the same Conductor and the same draft.
    private func floatingBody(_ f: FloatingChrome) -> some View {
        VStack(alignment: .leading, spacing: Dropdown.Metric.gap) {
            floatingHeader(f)
            if conductor.showingInbox {
                inboxHeader
                IslandInboxView(conductor: conductor, snoozeOpenFor: posedSnoozeOpen)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                if hasBanners { bannersBlock }
                if conductor.replyingTo != nil {
                    replyingBar
                } else if conductor.showsNoticeReturn, let r = conductor.noticeReturn {
                    returnChip(r)
                }
                if chatRows.isEmpty {
                    if !moeText.isEmpty { moeLine }
                    Spacer(minLength: 0)
                } else {
                    chatView(fill: true)
                }
                if controlsRowShown { trayRow }
                askField
            }
        }
        .padding(.top, 10)
        .padding(.bottom, Dropdown.Metric.bottom - 2)
        .padding(.horizontal, Dropdown.Metric.side - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .onExitCommand { onClose() }
        .onChange(of: f.focusRequest) { _, _ in askFocused = true }
        .onAppear {
            guard f.focusRequest > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { askFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memoe chat")
    }

    /// The window's header, which is also its handle: drag it to move the
    /// window. Right-click for the window's two switches.
    private func floatingHeader(_ f: FloatingChrome) -> some View {
        HStack(spacing: 6) {
            statusWord
            if status.clock, let since = conductor.workingSince {
                WorkingClock(since: since, frozen: snapshotting)
            }
            Spacer(minLength: 8)
            InboxIconButton(count: conductor.islandNotices.count,
                            on: conductor.showingInbox) { conductor.toggleInbox() }
                .help(conductor.showingInbox ? "Back to the conversation" : "Inbox")
            if !conductor.turns.isEmpty, !busy, !conductor.showingInbox {
                IslandButton(icon: "square.and.pencil") { conductor.newConversation() }
                    .help("New conversation (this one stays in Chat)")
                    .accessibilityLabel("New conversation")
            }
            IslandButton(icon: f.keepOnTop ? "pin.fill" : "pin") { f.onToggleOnTop() }
                .help(f.keepOnTop ? "Kept on top of every app. Click to let other windows cover it"
                                  : "Keep it on top of every app")
                .accessibilityLabel("Keep on top")
                .accessibilityValue(f.keepOnTop ? "On" : "Off")
            IslandButton(icon: "pip.enter") { f.onDock() }
                .help("Put the chat back in the notch (\(FloatingChatWindow.shortcut))")
                .accessibilityLabel("Put the chat back in the notch")
            IslandButton(icon: "xmark") { onClose() }
                .help("Close (esc). The conversation carries on: click the notch to bring it back")
                .accessibilityLabel("Close the chat window")
                .accessibilityHint("The conversation carries on")
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in f.onDragChanged() }
            .onEnded { _ in f.onDragEnded() })
        .contextMenu {
            Button(f.keepOnTop ? "Let Other Windows Cover It" : "Keep on Top") { f.onToggleOnTop() }
            Button(f.translucent ? "Solid" : "See-Through When Not in Use") { f.onToggleTranslucent() }
            Divider()
            Button("Put Back in the Notch") { f.onDock() }
        }
    }

    // MARK: The conversation, as a chat

    /// The whole session, oldest at the top, newest at the bottom, the way
    /// any chat reads (`IslandChat`). While Moe works its step is the newest
    /// row, under the conversation rather than instead of it.
    ///
    /// `statusOnce`: the card on a floating capsule. Its band already says
    /// "Thinking" beside the camera, so the bare word is not said again as a
    /// row directly under it (the owner, 2026-11-12, with a photograph of
    /// the two stacked). A step is still a row: the band says "Working" and
    /// the row says what at.
    static func chatRows(_ c: Conductor, statusOnce: Bool = false,
                         openSteps: Set<String> = []) -> [IslandChat.Row] {
        var rows: [IslandChat.Row] = []
        for turn in c.turns.suffix(40) {
            let id = turn.id.uuidString
            switch turn.role {
            case .you:
                rows.append(.you(id: id, text: turn.text, live: false))
            case .moe:
                if !turn.text.isEmpty { rows.append(.moe(id: id, text: turn.text)) }
                if !turn.isStreaming, !turn.text.isEmpty, let summary = stepsSummary(turn) {
                    let sid = id + ":steps"
                    rows.append(.steps(id: sid, summary: summary,
                                       lines: openSteps.contains(sid) ? stepLines(turn) : []))
                }
                if !turn.noted.isEmpty { rows.append(.noted(id: id + ":noted", count: turn.noted.count)) }
            case .system:
                if !turn.text.isEmpty { rows.append(.system(id: id, text: turn.text)) }
            }
            let actions = c.actions(for: turn)
            if !actions.isEmpty { rows.append(.actions(id: id + ":actions", labels: actions.map(\.label))) }
        }
        if !c.partial.isEmpty { rows.append(.you(id: "partial", text: c.partial, live: true)) }
        // The step while Moe works, unless its answer is already streaming
        // into the last row, which says the same thing better.
        let answering = c.turns.last.map { $0.role == .moe && $0.isStreaming && !$0.text.isEmpty } ?? false
        if let queued = c.queuedTyped { rows.append(.queued(text: queued)) }
        if busy(c), !answering {
            let step = c.workingStep.flatMap { $0.isEmpty ? nil : WorkingRow.label(step: $0) }
            // Before the first step, the word. The owner, 2026-09-25: a bare
            // "…" read as nothing, not as Moe thinking.
            if step != nil || !statusOnce { rows.append(.working(label: step ?? "Thinking")) }
        }
        return rows
    }

    private var chatRows: [IslandChat.Row] {
        Self.chatRows(conductor, statusOnce: statusOnce, openSteps: draft.openSteps)
    }

    /// "3 steps · 48 s · 1 source", the line a finished answer folds what
    /// it did to; nil when it did nothing worth folding.
    /// The opened steps on the card, a line each: the steps, the thinking
    /// in one line, the pages read. One list for drawing and measuring.
    static func stepLines(_ turn: Turn) -> [String] {
        turn.tools + [WorkingRow.thinkingLine(turn.thinking)].compactMap { $0 } + turn.links.map(\.label)
    }

    static func stepsSummary(_ turn: Turn) -> String? {
        let steps = WorkingRow.summary(steps: turn.tools.count, took: turn.took, thought: !turn.thinking.isEmpty)
        let sources = turn.links.isEmpty ? nil
            : turn.links.count == 1 ? "1 source" : "\(turn.links.count) sources"
        let parts = [steps, sources].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// The band holds the status word, on a floating capsule.
    private var statusOnce: Bool { capsule != nil && chromeInBand }

    /// What the dropdown holds, as `Dropdown` measures it — one builder for
    /// the island's height and for the conversation's frame here, so the
    /// two cannot disagree about how much room the conversation has.
    static func dropdownContents(_ c: Conductor, draft: IslandDraft, accessibility: String?,
                                 updateShowing: Bool, width: Double, notch: CGSize) -> Dropdown.Contents {
        let banners = NotchIsland.bannerContents(c, accessibility: accessibility, updateShowing: updateShowing,
                                                 width: width, notch: notch)
        return Dropdown.Contents(
            chat: chatRows(c, statusOnce: banners.chromeInBand && NotchGeometry.isCapsule(notch),
                           openSteps: draft.openSteps),
            greeting: moeText(c),
            controls: Dropdown.showsControlsRow(hasControls: !trayControls(c, driving: false).isEmpty,
                                                open: draft.trayOpen, muted: c.micMuted),
            field: showsField(c, draft: draft),
            // The field's text runs between the + and the ⋯ and send.
            fieldText: Double(ComposerEditor.height(draft.text, size: 13, lineHeight: 17, maxLines: 4,
                                                    width: Dropdown.Metric.width - 36 - 102,
                                                    wraps: IslandTextMeasure.wraps)),
            banners: ConversationPanel.banners(banners, width: width, wraps: IslandTextMeasure.wraps),
            statusInBand: banners.chromeInBand)
    }

    /// The conversation's frame: its rows, or less when the cards and the
    /// field need the room (`Dropdown.layout`).
    private var chatFrameHeight: CGFloat {
        let contents = Self.dropdownContents(conductor, draft: draft, accessibility: accessibilityProblem,
                                             updateShowing: updateNoticeShowing,
                                             width: Double(contentSize.width), notch: notchSize)
        return CGFloat(Dropdown.layout(contents, wraps: IslandTextMeasure.wraps,
                                       maximum: Dropdown.maximum(expanded: presentation == .expanded)).chat)
    }

    /// The conversation is taller than its frame, so some of it is scrolled
    /// out of the top.
    private func chatOverflows(_ rows: [IslandChat.Row]) -> Bool {
        CGFloat(IslandChat.height(rows, wraps: IslandTextMeasure.wraps, cap: .infinity)) > chatFrameHeight + 0.5
    }

    /// Messages whose More was pressed, by row id.
    @State private var expandedRows: Set<String> = []

    private var chatView: some View { chatView(fill: false) }

    /// `fill`: the floating window, where the conversation takes whatever
    /// height the window has and scrolls inside it, rather than the measured
    /// frame the notch card is laid out to.
    private func chatView(fill: Bool) -> some View {
        let rows = chatRows
        return ScrollViewReader { proxy in
            IslandScrollBox {
                // The end marker sits outside the rows' stack. Inside it, the
                // stack's spacing put ten points between the last row and
                // the marker, so the content was ten points taller than the
                // frame `IslandChat.height` gives it, and scrolled to its end
                // it lost those ten points off the top: the first row of a
                // short conversation was drawn with its top cut away (the
                // owner's photograph, 2026-11-12: "Thinking" with no tops).
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: IslandChat.gap) {
                        ForEach(rows, id: \.id) { row in
                            chatRow(row)
                                // Every message copies, and the whole
                                // conversation does too (2026-09-29).
                                .contextMenu {
                                    if let text = Self.rowText(row) {
                                        Button("Copy message") { Transcript.copy(text) }
                                    }
                                    Button("Copy conversation") {
                                        Transcript.copy(Transcript.plain(conductor.turns))
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 0).id("chatEnd")
                }
                // In the window the fade is always on, so the first row starts
                // below it: scrolled to the top nothing is faded, scrolled
                // down the fade says there is more above.
                .padding(.top, fill ? Self.floatingFade : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The system's own scroller, shown while scrolling: with none, a
            // long answer's start sat above the frame with nothing to say so.
            .scrollIndicators(.automatic)
            .frame(height: fill ? nil : chatFrameHeight)
            .frame(maxHeight: fill ? .infinity : nil)
            // A line scrolled half out of the top reads as two rows colliding;
            // a short fade says "there is more up there", as the meeting
            // transcript does. Only when there is: over a conversation that
            // fits, the fade took the top off its first row.
            .mask {
                if fill {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.floatingFade)
                        Color.black
                    }
                } else {
                    LinearGradient(stops: [
                        .init(color: chatOverflows(rows) ? .clear : .black, location: 0),
                        .init(color: .black, location: min(0.08, 14 / max(chatFrameHeight, 1))),
                        .init(color: .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
            }
            .onAppear { scrollToNewest(proxy) }
            .onChange(of: conductor.turns.count) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("chatEnd", anchor: .bottom) }
            }
            // An answer as it grows: its start pinned to the top once it is
            // taller than the frame, so it reads down rather than each new
            // word pulling the reader to the bottom. A short one cannot
            // scroll that far, so it still ends up pinned to the newest.
            .onChange(of: conductor.turns.last?.text) { _, _ in scrollToNewest(proxy) }
            .onChange(of: conductor.partial) { _, _ in proxy.scrollTo("chatEnd", anchor: .bottom) }
            .onChange(of: conductor.workingStep) { _, _ in proxy.scrollTo("chatEnd", anchor: .bottom) }
        }
    }

    /// The newest answer, from its start: pinned to the top once it is
    /// taller than the frame, so it reads down rather than each new word
    /// pulling the reader to the bottom, and opening the panel on a long one
    /// lands on its first line (the owner, 2026-10-30: "I can't see the
    /// whole thing"). A short one cannot scroll that far, so it still ends
    /// pinned to the newest row. Anything else that is newest — your words,
    /// a step — is the bottom.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        if conductor.partial.isEmpty, let last = conductor.turns.last, last.role == .moe, !last.text.isEmpty {
            proxy.scrollTo(last.id.uuidString, anchor: .top)
        } else {
            proxy.scrollTo("chatEnd", anchor: .bottom)
        }
    }

    /// A row's words, for Copy message; nil for rows that are not a message.
    static func rowText(_ row: IslandChat.Row) -> String? {
        switch row {
        case .you(_, let text, _), .moe(_, let text), .system(_, let text), .queued(let text):
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    @ViewBuilder
    private func chatRow(_ row: IslandChat.Row) -> some View {
        switch row {
        case .you(let id, let text, let live):
            let clip = expandedRows.contains(id) ? nil : IslandChat.clipped(text, limit: IslandChat.youLimit)
            VStack(alignment: .trailing, spacing: 2) {
                youBubble(clip ?? text, live: live)
                if clip != nil { moreButton(id) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .moe(_, let text):
            // The renderer the Chat page uses, in the island's style. A table
            // too wide for the notch card folds to a line that opens the
            // window; the floating window has the room and draws it.
            ReplyView(text, style: .island(openWindow: floating == nil ? handOff : nil))
        case .queued(let text):
            VStack(alignment: .trailing, spacing: 2) {
                youBubble(text, live: false).opacity(0.55)
                HStack(spacing: 8) {
                    Text("Sends when Moe finishes")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    Button { conductor.cancelQueued() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 18, height: IslandChat.more - 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Don't send it")
                    .accessibilityLabel("Don't send it")
                }
                .frame(height: IslandChat.more - 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .steps(let id, let summary, let lines):
            stepsFoot(id: id, summary: summary, open: !lines.isEmpty)
        case .actions(let id, _):
            if let turn = conductor.turns.first(where: { $0.id.uuidString + ":actions" == id }) {
                ReplyActionRow(actions: conductor.actions(for: turn), style: .island) { action in
                    perform(action, on: turn)
                }
                .frame(height: IslandChat.actionsLine)
            }
        case .system(_, let text):
            Text(text)
                .font(.system(size: IslandChat.systemSize))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .working(let label):
            HStack(spacing: 8) {
                Circle().fill(toneColour(status.tone)).frame(width: 5, height: 5)
                    .modifier(Breathing())
                Text(label)
                    .font(.system(size: IslandChat.moeSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(height: IslandChat.moeLine)
        case .noted(let id, _):
            if let turn = conductor.turns.first(where: { $0.id.uuidString + ":noted" == id }) {
                NotedLines(facts: turn.noted, style: .island) { claim in
                    conductor.forgetNoted(turnID: turn.id, claim: claim)
                }
            }
        }
    }

    /// What Moe did, folded under its answer: "3 steps · 48 s ›". A click
    /// opens the steps and the pages it read, and folds them again.
    @ViewBuilder
    private func stepsFoot(id: String, summary: String, open: Bool) -> some View {
        let turn = conductor.turns.first { $0.id.uuidString + ":steps" == id }
        VStack(alignment: .leading, spacing: IslandChat.stepsGap) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
                    if open { draft.openSteps.remove(id) } else { draft.openSteps.insert(id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(summary)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .frame(height: IslandChat.stepsLine)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Fold what Moe did" : "What Moe did")
            .accessibilityLabel("What Moe did: \(summary)")
            .accessibilityValue(open ? "Shown" : "Folded")
            if open, let turn {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(turn.tools.enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .frame(height: IslandChat.stepLine)
                    }
                    if let line = WorkingRow.thinkingLine(turn.thinking) {
                        Text(line)
                            .font(.system(size: 11.5).italic())
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(height: IslandChat.stepLine)
                            .help("Moe's thinking — the whole of it is in the Memoe window")
                    }
                    ForEach(turn.links, id: \.url) { link in
                        if let url = URL(string: link.url) {
                            Link(destination: url) {
                                Text(link.label).underline()
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .frame(height: IslandChat.stepLine)
                            .help(link.url)
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func moreButton(_ id: String) -> some View {
        Button("More") { expandedRows.insert(id) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(height: IslandChat.more - 2)
            .help("Show the whole message")
    }

    /// Your words in a bubble on the right, as in any chat; Moe's answer
    /// stays on the left as plain text. Live while you talk: brighter, with
    /// a green edge, like the light at the notch.
    private func youBubble(_ text: String, live: Bool) -> some View {
        let m = Dropdown.Metric.self
        let lines = TextDirection.preparedLines(text)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(lines.text)
                .font(.system(size: m.youSize))
                .foregroundStyle(.white.opacity(live ? 0.9 : 0.78))
                .lineSpacing(m.youLineHeight - 16)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .reads(lines.direction)
                .padding(.horizontal, m.youPadH)
                .padding(.vertical, m.youPadV)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 4, topTrailingRadius: 14,
                                           style: .continuous)
                        .fill(live ? Theme.Island.listening.opacity(0.14) : Color.white.opacity(0.1))
                )
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 4, topTrailingRadius: 14,
                                           style: .continuous)
                        .stroke(live ? Theme.Island.listening.opacity(0.35) : .clear, lineWidth: 1)
                )
                .frame(maxWidth: bubbleWidth, alignment: .trailing)
        }
    }

    /// Your bubble's widest: four-fifths of the notch card, or of the
    /// floating window as it is widened.
    private var bubbleWidth: CGFloat {
        let m = Dropdown.Metric.self
        let card = CGFloat(Dropdown.youTextWidth + m.youPadH * 2)
        guard floating != nil else { return card }
        return max(card, (contentSize.width - CGFloat(m.side) * 2) * CGFloat(m.youWidthShare))
    }

    /// The step, shimmering while Moe works; the answer when it lands. Long
    /// answers scroll past `moeLinesMax` lines rather than grow the panel.
    private var moeLine: some View {
        let text = moeText
        let line = Text(busy ? AttributedString(text) : Self.linked(text))
            .font(.system(size: Dropdown.Metric.moeSize))
            .foregroundStyle(.white.opacity(busy ? 0.75 : (lastAnswer?.role == .system ? 0.45 : 0.96)))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        // Exactly as tall as `Dropdown.height` counted it, from the same
        // measurement: a scroll view is greedy, and given `maxHeight` it
        // took every spare point and pushed the ⋯ down.
        return IslandScrollBox { line }
            .scrollIndicators(.never)
            .frame(height: CGFloat(Dropdown.moeHeight(text, wraps: IslandTextMeasure.wraps)))
    }

    /// The ⋯, and the icons it slides out to its left. Muted, a red
    /// "Unmute" pill stands at the other end of the row, whether the tray is
    /// open or not, and the tray leaves its own mic out: it used to be a
    /// bare red circle six points from the ⋯, and every one of the owner's
    /// six unmutes on 2026-09-25 was that circle (the log's "on the island").
    private var trayRow: some View {
        let controls = trayControls.filter {
            if case .mic(muted: true) = $0 { return !IslandTray.mutedOutside(true) }
            return true
        }
        return HStack(spacing: 6) {
            if IslandTray.mutedOutside(conductor.micMuted) {
                UnmutePill { pressUnmute() }
            }
            Spacer(minLength: 0)
            if trayOpen {
                ForEach(Array(controls.enumerated()), id: \.offset) { _, c in trayIcon(c) }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(height: Dropdown.Metric.controls)
    }

    /// The controls' row: only while slid out, or muted (`Dropdown.showsControlsRow`).
    private var controlsRowShown: Bool {
        Dropdown.showsControlsRow(hasControls: !trayControls.isEmpty, open: trayOpen,
                                  muted: conductor.micMuted)
    }

    /// The ⋯ that slides the controls out and back.
    private var trayToggle: some View {
        TrayButton(icon: "ellipsis", style: trayOpen ? .lit : .quiet) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { trayOpenByHand.toggle() }
        }
        .help(trayOpen ? "Hide the controls" : "Controls")
        .accessibilityLabel(trayOpen ? "Hide the controls" : "Show the controls")
    }

    /// The Unmute pill was pressed. Only a panel opened by hand unmutes; on
    /// a hover peek the press pins the panel open and the mute stays
    /// (`IslandBehaviour.unmutePress`). Either way the log says which.
    func pressUnmute() {
        switch IslandBehaviour.unmutePress(current: presentation) {
        case .unmute:
            conductor.setMicMuted(false, from: "island's Unmute pill (\(presentation))")
        case .open:
            Log.write("island: Unmute pressed on a \(presentation) panel — pinned it open; still muted")
            onTap()
        }
    }

    @ViewBuilder
    private func trayIcon(_ c: IslandTray.Control) -> some View {
        switch c {
        case .mic(let muted):
            // Muted, this glyph is not drawn (the Unmute pill is); if it ever
            // is, it goes through the same rule as the pill.
            TrayButton(icon: muted ? "mic.slash.fill" : "mic.fill", style: muted ? .red : .plain) {
                if muted { pressUnmute() }
                else { conductor.setMicMuted(true, from: "island's mute glyph (\(presentation))") }
            }
            .help(muted ? ConversationControls.unmuteHelp : ConversationControls.muteHelp)
            .accessibilityLabel(muted ? "Unmute the microphone" : "Mute the microphone")
        case .updates(let quiet):
            TrayButton(icon: quiet ? "speaker.slash.fill" : "speaker.wave.2.fill", style: quiet ? .lit : .plain) {
                conductor.toggleWorkSilently()
            }
            .help(quiet ? "Working quietly: Moe will only say the answer. Click to hear progress again."
                        : "Moe says what it's doing as it goes. Click to keep it quiet until the answer.")
            .accessibilityLabel("Spoken progress")
            .accessibilityValue(quiet ? "Off" : "On")
        case .captions(let on):
            TrayButton(icon: "captions.bubble.fill", style: on ? .lit : .plain) { conductor.toggleTranscript() }
                .help(on ? "Live transcript on: the panel opens as you talk and as Moe answers. Click to turn it off."
                         : "Turn on the live transcript: the panel opens as you talk and as Moe answers.")
                .accessibilityLabel("Live transcript")
                .accessibilityValue(on ? "On" : "Off")
        case .startOver:
            TrayButton(icon: "arrow.counterclockwise", style: .plain) { conductor.restartReply() }
                .help("Say it again from the top")
                .accessibilityLabel("Say it again from the top")
        case .pause, .resume:
            TrayButton(icon: c == .pause ? "pause.fill" : "play.fill", style: .plain) {
                if let id = conductor.voicedTurnID { conductor.playPauseReply(id) }
            }
            .help(c == .pause ? "Pause (a tap of the talk key does the same)" : "Carry on from where it paused")
            .accessibilityLabel(c == .pause ? "Pause the reply" : "Carry on with the reply")
        case .readAloud:
            TrayButton(icon: "play.fill", style: .plain) {
                if let a = lastAnswer { conductor.playPauseReply(a.id) }
            }
            .help("Read this aloud")
            .accessibilityLabel("Read this aloud")
        case .openChat:
            TrayButton(icon: "macwindow", style: .plain) { handOff() }
                .help("Open the whole conversation in the Memoe window (⌘J)")
                .accessibilityLabel("Open the conversation in the Memoe window")
        case .copy:
            TrayButton(icon: "doc.on.doc", style: .plain) {
                guard let a = lastAnswer else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(a.text, forType: .string)
            }
            .help("Copy the answer")
            .accessibilityLabel("Copy the answer")
        case .stop(let driving):
            TrayButton(icon: "stop.fill", style: driving ? .driving : .plain) { conductor.stopEverything() }
                .help(driving ? IslandOverride.stopLabel(screen: conductor.drivingApp != nil)
                              : "Stop: Moe drops this job")
                .accessibilityLabel("Stop")
        }
    }

    /// The field, when there is something you can type (`Dropdown.showsField`).
    private var askField: some View { askField(placeholder: askPlaceholder, attach: true) }

    /// The one field, in the conversation and in a meeting. A meeting refuses
    /// attachments (a file dropped mid-call has nowhere to go), so it has no +.
    private func askField(placeholder: String, attach: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if attach, !draft.attachments.isEmpty { IslandAttachmentChips(draft: draft) }
            HStack(spacing: 8) {
                if snapshotting {
                    if attach { IslandAddGlyph() }
                    IslandFieldStandIn(placeholder: placeholder, text: draft.text)
                } else {
                    if attach { IslandAddButton(draft: draft) }
                    // Grows to four lines, then scrolls (`ComposerEditor`):
                    // a one-line field showed a pasted email only through
                    // the arrow keys.
                    ComposerEditor(text: $draft.text, placeholder: placeholder,
                                   size: 13, lineHeight: 17, maxLines: 4,
                                   ink: .white, placeholderInk: .white.opacity(0.38),
                                   focus: $askFocused,
                                   attach: attach ? { draft.attachments.append(contentsOf: $0) } : nil,
                                   onSubmit: sendAsked)
                }
                // The ⋯ beside send, in the conversation's field: it used to
                // sit alone on a row of its own between the answer and the
                // field (deep dive §2.10). On the compact card it is in the
                // band (`trayInHeader`).
                if attach, !trayInHeader, !trayControls.isEmpty { trayToggle }
                switch attach ? ComposerAction.of(working: busy, hasDraft: draft.inProgress)
                              : .send(enabled: draft.inProgress) {
                case .stop:
                    Button { conductor.stopEverything() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .help(islandOverride == .driving ? IslandOverride.stopLabel(screen: conductor.drivingApp != nil)
                                                     : "Stop: Moe drops this job (esc)")
                    .accessibilityLabel("Stop")
                case .send(let enabled):
                    Button(action: sendAsked) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(enabled ? .black : .white.opacity(0.35))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(enabled ? Color.white : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .help(busy ? "Send when Moe finishes" : "Send")
                    .accessibilityLabel(busy ? "Send when Moe finishes" : "Send")
                }
            }
            .padding(.leading, attach ? 6 : 14)
            .padding(.trailing, 4)
            .padding(.vertical, (Dropdown.Metric.field - Dropdown.Metric.fieldLine) / 2)
            .frame(minHeight: Dropdown.Metric.field)
            .background(RoundedRectangle(cornerRadius: Dropdown.Metric.field / 2, style: .continuous)
                .fill(Color.white.opacity(0.08)))
        }
    }

    private var askPlaceholder: String {
        if conductor.replyingTo != nil { return "Type your answer to Moe" }
        return conductor.turns.isEmpty ? "Ask Moe, or hold \(conductor.config.talkKey.inSentence) and talk" : "Ask Moe"
    }

    // MARK: - Meeting

    private static let youTint = Theme.Island.you
    private static let themTint = Theme.Island.them
    private static let amber = Theme.Island.amber
    /// The one red on the island, shared by the ring, the tab and the
    /// header dot, so "recording" is a single colour wherever it appears.
    static let recordRed = Theme.Island.recording

    @ViewBuilder
    private var meetingContent: some View {
        switch presentation {
        case .expanded:
            if case .done = conductor.meeting { meetingDoneBody } else { meetingExpandedBody }
        // Hover gives you the whole panel, field included.
        //
        // Peek used to be a 58pt strip — a clock and three buttons, nothing to
        // type into — so asking Moe something mid-call cost a hover, a click,
        // and then a click into the field. Three gestures to say one sentence,
        // on the surface whose entire purpose is saying things quietly during
        // a meeting. The panel it opened is the panel you wanted.
        default:
            if case .done = conductor.meeting { meetingDoneBody } else { meetingExpandedBody }
        }
    }

    /// The state, in a word. The clock is drawn beside it rather than
    /// concatenated into it: they are different kinds of information and a
    /// panel with one type size for both has no hierarchy at all.
    private var meetingStateWord: String {
        switch conductor.meeting {
        case .recording: return conductor.meetingPaused ? "Off the record" : "Recording"
        case .starting: return "Starting the meeting…"
        case .stopping: return "Writing your notes…"
        case .done: return "Notes ready"
        case .off: return ""
        }
    }


    /// One small dismissable line: the hint, a name mention, a recap.
    /// A notice with one or two named answers: the call offer, the end offer.
    ///
    /// One action sits at the end of the sentence, the way a notification's
    /// button does. It used to take a row of its own under a sentence that
    /// was cut to one line — "…switched on in A…", then a lone Fix — so the
    /// row spent two lines of height and still did not say what it meant.
    /// The sentence wraps now (`ConversationPanel.offerBar` counts the
    /// lines), and more than one action keeps its own row.
    private func offerBar(_ text: String, icon: String, tint: Color,
                          actions: [(String, () -> Void)]) -> some View {
        let inline = actions.count == 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: inline ? .center : .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).accessibilityHidden(true).font(.system(size: 10)).foregroundStyle(tint)
                Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(Int(ConversationPanel.Metric.offerLimit))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if inline { offerActions(actions, tint: tint) }
            }
            if !inline { offerActions(actions, tint: tint) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func offerActions(_ actions: [(String, () -> Void)], tint: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                Button(action: a.1) {
                    Text(a.0)
                        .font(.system(size: 10, weight: .semibold))
                        // Dark on amber, as the reminder card's Play: white on
                        // amber does not read.
                        .foregroundStyle(i == 0 ? (tint == Self.amber ? Color.black.opacity(0.85) : Color.white)
                                                : .white.opacity(0.75))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(i == 0 ? tint.opacity(0.85) : Color.white.opacity(0.11)))
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    /// The width of a one-word pill at the end of an offer row, for the
    /// height arithmetic: the label, and 9 pt either side.
    static func offerPillWidth(_ label: String) -> Double {
        IslandTextMeasure.width(label, size: 10, weight: .semibold) + 18
    }

    /// The call offer's sentence — one definition, for the row and for
    /// `NotchIsland`, which has to know how many lines it wraps to.
    static func callOfferSentence(_ conductor: Conductor) -> String? {
        guard let offer = conductor.meetingOffer else { return nil }
        let mode = conductor.config.meetingAutoDetect
        return MeetingOfferText.title(offer.app) + " — "
            + MeetingOfferText.body(offer.app, mode: mode, countdown: offer.countdown)
    }

    /// "Zoom meeting detected — record it?" Shown wherever the panel is
    /// open, meeting or not, because it arrives before there is a meeting.
    @ViewBuilder
    private var callOfferBar: some View {
        if let offer = conductor.meetingOffer, let sentence = Self.callOfferSentence(conductor) {
            offerBar(sentence,
                     icon: "phone.fill", tint: Self.amber,
                     actions: offer.countdown != nil
                        ? [("Start now", { conductor.acceptMeetingOffer() }),
                           ("Don't record", { conductor.dismissMeetingOffer() }),
                           (MeetingOfferText.never(offer.app), { conductor.neverOfferForApp() })]
                        : [("Record", { conductor.acceptMeetingOffer() }),
                           ("Not this one", { conductor.dismissMeetingOffer() }),
                           (MeetingOfferText.never(offer.app), { conductor.neverOfferForApp() })])
        }
    }

    /// One line and, when it can be put away, a ✕. The capture status has
    /// no ✕: it goes when the capture does, and its ✕ used to do nothing.
    private func noticeBar(_ text: String, icon: String, tint: Color, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).accessibilityHidden(true).font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            Spacer(minLength: 4)
            if let dismiss { IslandButton(icon: "xmark", action: dismiss).accessibilityLabel("Dismiss") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Clicked open while recording: the live transcript on top (you and
    /// them in two colours, the newest 40 lines, pinned to the end), the
    /// chat with Moe below, one field. Replies are text only.
    /// One of the two page tabs on the expanded meeting panel.
    private func meetingPageTab(_ page: MeetingPage, _ label: String, icon: String) -> some View {
        let on = meetingPage == page
        return Button {
            meetingPage = page
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(on ? 1 : 0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(on ? 0.16 : 0.0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
    }

    /// The meeting's word beside the notch: a red dot and "Recording" with
    /// the clock, or a dim one and "Off the record" — the same place and
    /// shape as the conversation's (`statusWord`).
    private var meetingStatusWord: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(conductor.meeting.isRecording && !conductor.meetingPaused
                      ? Self.recordRed : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(meetingStateWord)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .fixedSize(horizontal: capsule == nil, vertical: true)
    }

    private var meetingTray: [MeetingTray.Control] {
        MeetingTray.controls(
            recording: conductor.meeting.isRecording, offRecord: conductor.meetingPaused,
            screenshots: conductor.config.meetingCapture.isEnabled
                && conductor.config.meetingCapture.screenshots != .off,
            clips: conductor.config.meetingCapture.isEnabled
                && conductor.config.meetingCapture.recording != .off,
            clipping: conductor.meetingClip)
    }

    /// The ⋯ and the meeting's icons, as the conversation's tray: what
    /// changes the recording stays out even with the ⋯ shut.
    private var meetingTrayRow: some View {
        let controls = meetingTray
        let shown = trayOpen ? controls : MeetingTray.outside(controls)
        return HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, c in meetingTrayIcon(c) }
            TrayButton(icon: "ellipsis", style: trayOpen ? .lit : .quiet) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { trayOpenByHand.toggle() }
            }
            .help(trayOpen ? "Hide the controls" : "Mark, off the record, screenshot, stop")
            .accessibilityLabel(trayOpen ? "Hide the meeting controls" : "Show the meeting controls")
        }
        .frame(height: Dropdown.Metric.controls)
    }

    @ViewBuilder
    private func meetingTrayIcon(_ c: MeetingTray.Control) -> some View {
        switch c {
        case .mark:
            TrayButton(icon: "bookmark.fill", style: .plain) { conductor.addMeetingBookmark() }
                .help("Mark this moment in the notes")
                .accessibilityLabel("Mark this moment in the notes")
        case .offRecord(let on):
            TrayButton(icon: "pause.fill", style: on ? .lit : .plain) { conductor.toggleMeetingPause() }
                .help(on ? "Off the record: nothing is being written down. Click to go back on."
                         : "Go off the record. Nothing is written down until you come back.")
                .accessibilityLabel("Off the record")
                .accessibilityValue(on ? "On" : "Off")
        case .screenshot:
            TrayButton(icon: "camera.fill", style: .plain) { conductor.captureScreenshot(trigger: .user) }
                .help("Take a screenshot (⌃⌥S)")
                .accessibilityLabel("Take a screenshot")
        case .clip(let on):
            TrayButton(icon: "record.circle", style: on ? .lit : .plain) { conductor.toggleMeetingClip(trigger: .user) }
                .help(on ? "Recording the screen. Click to stop (⌃⌥R)." : "Record the screen (⌃⌥R)")
                .accessibilityLabel(on ? "Stop recording the screen" : "Record the screen")
        case .stop:
            TrayButton(icon: "stop.fill", style: .red) { conductor.stopMeeting() }
                .help("Stop and write the notes")
                .accessibilityLabel("Stop the meeting and write the notes")
        }
    }

    private var meetingExpandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chromeInBand { meetingStatusWord.frame(height: Dropdown.Metric.statusRow) }
            callOfferBar
            if let hint = conductor.meetingHint {
                noticeBar(hint, icon: "lightbulb.fill", tint: Self.amber) { conductor.dismissMeetingHint() }
            }
            if let m = conductor.meetingMention {
                noticeBar("Your name came up — \(m)", icon: "person.wave.2.fill", tint: Self.amber) { conductor.dismissMeetingMention() }
            }
            if let c = conductor.meetingCatchUp {
                noticeBar(c, icon: "clock.arrow.circlepath", tint: Self.themTint) { conductor.dismissMeetingCatchUp() }
            }
            if !conductor.meetingCaptureStatus.isEmpty {
                noticeBar(conductor.meetingCaptureStatus, icon: "camera.fill", tint: Self.amber, dismiss: nil)
            }
            if let ended = conductor.meetingEndOffer {
                offerBar(ended, icon: "phone.down.fill", tint: Self.amber,
                         actions: [("Stop", { conductor.acceptMeetingEndOffer() }),
                                   ("Keep going", { conductor.dismissMeetingEndOffer() })])
            }
            // Above the tabs and with two named answers, not a grey line in
            // the subtitle row: while this is showing, everything being
            // written down is attributed to one person, and that is worth
            // an interruption. It was "no meeting audio" in the health
            // line, and it went unread through a whole meeting.
            if let fault = conductor.meetingTapFault {
                offerBar(fault, icon: "waveform.slash", tint: Self.amber,
                         actions: [("Open Settings", { conductor.openAudioCaptureSettings() }),
                                   ("I know", { conductor.dismissMeetingTapFault() })])
            }

            // Two pages, one at a time: the conversation with Moe, and the
            // room's transcript.
            //
            // They shared one scroll for a while — transcript, then a
            // "between you and Moe" divider, then the chat — which meant the
            // thing you came to read was always under the thing you did
            // not, and a long call pushed your own question out of view
            // every time someone spoke. Two pages give each its whole
            // height; the tabs say which is which.
            // Centred, with the line count laid over the trailing edge so
            // it never nudges the tabs off centre.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                meetingPageTab(.transcript, "Transcript", icon: "text.alignleft")
                meetingPageTab(.chat, "Ask Moe", icon: "bubble.left.fill")
                if !conductor.meetingLiveActions.isEmpty {
                    meetingPageTab(.todo, "To do · \(conductor.meetingLiveActions.count)", icon: "checklist")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            ScrollViewReader { proxy in
                IslandScrollBox {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        switch meetingPage {
                        case .transcript:
                            if conductor.meetingTimeline.isEmpty {
                                ledgerRow(gutter: "", tint: .clear) {
                                    Text(conductor.meetingHealth.isEmpty
                                         ? "Listening to the room — the transcript appears in ~30 s."
                                         : conductor.meetingHealth)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.40))
                                }
                            }
                            // The whole call, not a tail: this page exists to
                            // scroll back through it.
                            ForEach(Array(conductor.meetingTimeline.enumerated()), id: \.offset) { _, seg in
                                ledgerRow(gutter: Self.speakerLabel(seg.speaker),
                                          tint: seg.speaker.isYou ? Self.youTint : Self.themTint) {
                                    Text(seg.text)
                                        .font(.system(size: 12))
                                        .foregroundStyle(seg.speaker.isYou
                                                         ? Self.youTint.opacity(0.85)
                                                         : .white.opacity(0.88))
                                        .lineSpacing(1.5)
                                        .textSelection(.enabled)
                                }
                            }

                        case .todo:
                            // What Moe has heard people agree to do, as it
                            // hears it. Who, what, by when — the same three
                            // things the notes will list when the call ends.
                            if conductor.meetingLiveActions.isEmpty {
                                ledgerRow(gutter: "", tint: .clear) {
                                    Text("Nothing agreed yet. When someone says they'll do something, it shows up here.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.40))
                                }
                            }
                            ForEach(Array(conductor.meetingLiveActions.enumerated()), id: \.offset) { _, item in
                                ledgerRow(gutter: item.who.isEmpty ? "SOMEONE" : item.who.uppercased(),
                                          tint: Self.amber) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.what)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineSpacing(1.5)
                                            .textSelection(.enabled)
                                        if !item.when.isEmpty {
                                            Text("by \(item.when)")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundStyle(Self.amber.opacity(0.85))
                                        }
                                    }
                                }
                            }

                        case .chat:
                            if conductor.turns.isEmpty && conductor.partial.isEmpty {
                                ledgerRow(gutter: "", tint: .clear) {
                                    Text("Ask Moe anything about the call. The room can't hear it, and Moe has the transcript so far.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.40))
                                }
                            }
                            // Moe keeps the serif it has everywhere else, so a
                            // reply is never mistaken for something the room said.
                            ForEach(conductor.turns.suffix(20)) { turn in
                                ledgerRow(turn, aside: true).id(turn.id)
                            }
                            if !conductor.partial.isEmpty {
                                ledgerRow(gutter: "YOU", tint: .white.opacity(0.30), aside: true) {
                                    Text(conductor.partial)
                                        .font(.system(size: 12).italic())
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("mend")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                // A scroll view cuts its top row in half at the boundary,
                // which on a black panel reads as two lines colliding rather
                // than one line continuing above. Fading the first few points
                // says "there is more up there" instead.
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.055),
                        .init(color: .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                )
                .onAppear { proxy.scrollTo("mend", anchor: .bottom) }
                .onChange(of: conductor.meetingTimeline.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("mend", anchor: .bottom) }
                }
                .onChange(of: conductor.turns.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo("mend", anchor: .bottom) }
                }
                // A reply streams into a turn that already exists, so the
                // count never moves while the answer grows.
                .onChange(of: conductor.turns.last?.text) { _, _ in
                    proxy.scrollTo("mend", anchor: .bottom)
                }
                .onChange(of: conductor.partial) { _, _ in
                    proxy.scrollTo("mend", anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)

            // Kept, small and dim, on the ⋯ row's left: "only your voice" in
            // a call with other people is how you notice Moe cannot hear them.
            HStack(spacing: 8) {
                if meetingPage == .transcript, !conductor.meetingTimeline.isEmpty {
                    Text(TranscriptFooter.line(conductor.meetingTimeline))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                        .help("How many lines, and how many voices Moe has told apart")
                }
                if !meetingTray.isEmpty { meetingTrayRow }
            }
            askField(placeholder: "Ask Moe about the call, quietly", attach: false)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if chromeInBand {
                bandWord { meetingStatusWord }
            }
        }
        .overlay(alignment: .topTrailing) { chrome(stop: false) }
        .overlay(alignment: .topTrailing) {
            if conductor.meeting.isRecording {
                bandClock {
                    Text(conductor.meetingClock)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .onChange(of: presentation) { _, p in if p == .collapsed { trayOpenByHand = false } }
        // Clicked open, the panel is the intent to say something, so the
        // field takes the keyboard after a short beat (or AppKit takes it
        // back). Hovered open, it never does: a pass of the mouse during a
        // call must not swallow what you were typing into the call window.
        .onAppear {
            guard takesFocus, presentation == .expanded else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { askFocused = true }
        }
        // Give it up on the way out, so a keystroke aimed at the call window
        // is not swallowed by a field that is no longer on screen.
        .onDisappear { askFocused = false; handOffKey.stop() }
        .background(KeyWatchAnchor(watch: handOffKey))
        .onAppear { handOffKey.start(key: "j") { handOff() } }
    }

    /// A button under the newest turn (`ReplyActions`). Edit puts the
    /// draft in this box to change and send back.
    private func perform(_ action: ReplyAction, on turn: Turn) {
        switch action {
        case .send, .accept: conductor.answer(action)
        case .retry: conductor.retry(failed: turn.id)
        case .copy: Transcript.copy(ReplyActions.draft(in: turn.text) ?? turn.text)
        case .edit:
            if let d = ReplyActions.draft(in: turn.text) {
                draft.text = ReplyActionRow.editPrefix + d
                askFocused = true
            }
        }
    }

    /// To the Chat page, with what was waiting in the box (the owner's
    /// answer 1): the words and files go with the conversation, not lost
    /// in a card that has closed.
    private func handOff() {
        conductor.handOffDraft(text: draft.text, attachments: draft.attachments)
        draft.text = ""
        draft.attachments = []
        onOpenChat()
    }

    /// A transcript speaker in the gutter's own register.
    ///
    /// `Speaker.label` reads "them (speaker 2)", which is a sentence about a
    /// diarisation result rather than a name. In 30 points it becomes "#2",
    /// and you become YOU like everywhere else.
    private static func speakerLabel(_ speaker: MoeMeeting.Speaker) -> String {
        if speaker.isYou { return "YOU" }
        return speaker.label
            .replacingOccurrences(of: "them (speaker ", with: "#")
            .replacingOccurrences(of: ")", with: "")
            .uppercased()
    }

    private func sendAsked() {
        let t = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = draft.attachments
        guard !t.isEmpty || !files.isEmpty else { return }
        asked = ""
        draft.attachments = []
        // The answer lands on the Chat page; show it, whichever page the
        // question was typed from. Switchable, because a question asked while
        // reading the notes is often *about* the notes, and taking the page
        // away to answer it is taking away what was being asked about.
        if conductor.config.typedAnswersOpenChat { meetingPage = .chat }
        conductor.submit(t, origin: .typed, starter: .person, attachments: files)
    }

    /// The meeting is over: the summary, the action items as one-click
    /// Reminders, where the notes went.
    ///
    /// The old version of this was a title, one paragraph and two circular
    /// glyph buttons floating in the top-right corner — nothing said what
    /// meeting it was, how long it ran, or which of the two circles was
    /// the one that opens the notes. It now has a header with the meeting's
    /// own name and time under it, labelled sections in the app's existing
    /// small-caps style, a single named action, and the delivery line
    /// where a footnote belongs.
    private var meetingDoneBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The title wraps, in the display serif, and takes the width.
            //
            // It was one bold sans line clamped to `lineLimit(1)` beside a
            // green tick and two controls, so a real meeting title — which is
            // a sentence, because a model wrote it — was cut mid-word every
            // time: "Testing Mo: Transcript vs Chat C…". The tick is gone
            // with it; "Notes ready" above the title says the same thing in
            // words, and a panel that only appears when the notes are written
            // did not need a success icon to prove it.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("NOTES READY")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(Self.youTint)
                    Text(doneSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    IslandButton(icon: "xmark") { conductor.dismissMeetingOutcome(); onClose() }
                        .opacity(0.4)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
                Text(conductor.meetingOutcome?.record.notes?.title ?? "Notes ready")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            // Asked here rather than in Settings › Meetings, because this is
            // the panel that has just shown a transcript full of "speaker 4",
            // and nobody goes hunting for a permission while reading one.
            if let offer = conductor.meetingCalendarOffer {
                offerBar(offer, icon: "person.text.rectangle", tint: Self.themTint,
                         actions: [("Use my calendar", { conductor.acceptCalendarNameOffer() }),
                                   ("Not now", { conductor.dismissCalendarNameOffer() })])
            }

            IslandScrollBox(tail: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let notes = conductor.meetingOutcome?.record.notes {
                        if !notes.summary.isEmpty {
                            Text(notes.summary)
                                .font(.system(size: 14))
                                .lineSpacing(2.5)
                                .foregroundStyle(.white.opacity(0.88))
                                .textSelection(.enabled)
                                // A measure, as everywhere else. Summaries are
                                // the longest prose the island ever shows and
                                // ran the full 428pt without one.
                                .frame(maxWidth: 330, alignment: .leading)
                        }
                        if !notes.decisions.isEmpty {
                            sectionLabel("DECISIONS")
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(notes.decisions, id: \.self) { d in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•").foregroundStyle(.white.opacity(0.35))
                                        Text(d).textSelection(.enabled)
                                    }
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        if !notes.actionItems.isEmpty {
                            sectionLabel("ACTION ITEMS · TICK TO ADD A REMINDER")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { i, item in
                                    let label = Text((item.who.isEmpty ? "" : "\(item.who): ") + item.what
                                                     + (item.when.isEmpty ? "" : " — by \(item.when)"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.85))
                                    if snapshotting {
                                        // §9: an AppKit checkbox rasterises as
                                        // SwiftUI's "unsupported" bar. Drawn
                                        // from the system colours, because §8's
                                        // complaint about this control is that
                                        // it follows the Mac's appearance and
                                        // not the panel's.
                                        HStack(spacing: 6) {
                                            IslandCheckboxStandIn(on: item.reminded == true)
                                            label
                                        }
                                    } else {
                                        Toggle(isOn: Binding(get: { item.reminded == true },
                                                             set: { if $0 { conductor.remindMeetingAction(i) } })) {
                                            label
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(item.reminded == true)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(conductor.meetingStatus)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.7))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // Only when there is more than fits. A scroll view that ends in a
            // hard edge on a black panel is indistinguishable from a panel
            // that has finished, which is how a set of notes lost its action
            // items in silence. 14 pt, in points — §9's fade was a *fraction*
            // of its box once and took 11 pt out of a 70 pt column.
            .mask(notesLayout.overflows
                  ? AnyView(VStack(spacing: 0) {
                        Rectangle().fill(Color.black)
                        LinearGradient(colors: [.black, .black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                    })
                  : AnyView(Rectangle().fill(Color.black)))

            // A fade alone is a cue you have to already know how to read, and
            // the review's other complaint about this island is exactly that.
            // Words, then, in the panel's own small-caps.
            if notesLayout.overflows {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down").accessibilityHidden(true)
                        .font(.system(size: 7, weight: .bold))
                    Text("SCROLL FOR THE REST")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .kerning(0.4)
                }
                .foregroundStyle(.white.opacity(0.45))
            }

            // The audio was kept against the user's own delete setting.
            // That is a fact about their disk and about a recording of
            // other people, so it gets a line of its own: it used to be
            // appended to `meetingStatus`, which reaches this panel only
            // through `doneSubtitle` — one line, truncated, at 45 %
            // opacity, where it was cut off mid-sentence every time.
            if let audioNote = meetingAudioNote {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: audioNote.kept ? "waveform.circle.fill" : "waveform.slash").accessibilityHidden(true)
                        .font(.system(size: 10))
                        .foregroundStyle(audioNote.kept ? Self.amber : .white.opacity(0.5))
                    Text(audioNote.text)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !conductor.meetingDelivery.isEmpty {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                Text(conductor.meetingDelivery)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The one action, at the bottom where an action goes — it used to
            // sit in the header competing with the title for the same row.
            if case .done(let url) = conductor.meeting {
                IslandPill(icon: "doc.text", label: "Open notes") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.top, 13)
        .padding(.bottom, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Aug 30, 2:15 PM · 18:42", or the outcome when there are no notes —
    /// the panel used to say nothing at all about which meeting this was.
    private var doneSubtitle: String {
        guard let record = conductor.meetingOutcome?.record else { return conductor.meetingStatus }
        let when = MeetingListing.dateLabel(record.startedAt)
        let long = Timeline.clock(record.durationSeconds)
        guard record.notes != nil else { return "\(when) · \(long)" }
        // Without the kept-audio note, which has its own line at the foot
        // of the panel — here it would only ever be truncated away.
        var status = conductor.meetingStatus
        for note in CaptureCheck.allUiNotes { status = status.replacingOccurrences(of: note, with: "") }
        status = status.trimmingCharacters(in: .whitespaces)
        guard !status.isEmpty else { return "\(when) · \(long)" }
        return "\(when) · \(long) · \(status)"
    }

    /// What became of this meeting's audio, when that is worth a line: it
    /// was kept against the delete setting, or it looked like a capture
    /// failure and was deleted anyway because the meeting was too long to
    /// keep. Both are facts about the user's disk and about a recording of
    /// other people, and neither fits in `doneSubtitle`.
    private var meetingAudioNote: (text: String, kept: Bool)? {
        NotesPanel.audioNote(for: conductor.meetingOutcome?.record)
    }

    /// The same measurement `NotchIsland` sized this panel with, so the cue
    /// below the body and the room the body was given cannot disagree.
    private var notesLayout: NotesPanel.Layout {
        NotesPanel.layout(for: conductor)
    }

    /// The island's small-caps section heading, already the app's habit.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .kerning(0.4)
    }

    // MARK: - Dictation

    /// A strip, not a conversation: a glyph, the live transcript, nothing
    /// to tap. No greeting and no reply — this text is going to the cursor.
    private var dictationBody: some View {
        HStack(spacing: 11) {
            Image(systemName: conductor.dictation == .typing
                  ? "text.cursor" : "keyboard")
                .accessibilityHidden(true)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(dictationHeadline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(conductor.dictationPartial.isEmpty ? " " : conductor.dictationPartial)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)   // the newest words are what matter
            }

            Spacer(minLength: 4)

            if conductor.dictation == .listening {
                StateDot(mode: .listening, level: conductor.level)
                // There was no way to abandon a dictation from the island at
                // all: releasing pastes whatever was heard, and the only
                // escape was a key nobody is told about. Throwing away what
                // you just said has to be a visible button.
                IslandButton(icon: "xmark") { conductor.cancelDictationFromIsland() }
                    .accessibilityLabel("Cancel dictation")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var dictationHeadline: String {
        switch conductor.dictation {
        case .listening:    return conductor.dictationLatched ? "Dictating — tap to finish" : "Dictating"
        case .transcribing: return "Reading…"
        case .typing:       return "Typing…"
        case .off:          return ""
        }
    }

    // MARK: - Override and attention

    /// Driving beats a nudge beats the voice state — decided in MoeIsland so
    /// it can be tested, and read here in both the colour and the button so
    /// the two cannot drift apart.
    private var islandOverride: IslandOverride {
        IslandOverride.of(driving: conductor.drivingApp != nil || conductor.browsing,
                          nudgeWaiting: attentionWaiting,
                          idle: conductor.mode == .idle)
    }

    /// Something is waiting: a held nudge, or an update ready to install
    /// (row 47), or a call offer. `IslandGlow` decides; the right ear's dot
    /// turns full white for it (`IslandEars.Right.waiting`).
    /// It is on whatever "Let Moe bring things up on its own" says — an update
    /// is Moe's housekeeping, not Moe raising something (`IslandGlow`).
    private var attentionWaiting: Bool {
        IslandGlow.glows(nudgeHeld: conductor.hasUnseenNotice,
                         updateNoticeShowing: updateNoticeShowing,
                         callOffered: conductor.meetingOffer != nil)
    }

    static let talkLatchedHeadline = "Listening — tap to send"

    /// The shortcut as configured — ⌃⌥Space by default (Config.hotKeyModifiers),
    /// not the ⌥Space this used to hard-code.
    private var talkKey: String {
        HotKey.describe(keyCode: conductor.config.hotKeyCode, modifiers: conductor.config.hotKeyModifiers)
    }

    // MARK: - Expanded

    /// How far down the panel's own chrome reaches, so the card can start
    /// under it rather than beneath it.
    ///
    /// `expandedBody` floats ✕ and ⌃ over its top-trailing corner. The card
    /// is the first thing there and has a filled background, so the two
    /// buttons landed INSIDE it — reading as the card's own controls, one
    /// of them a ✕ a few points from the card's own ✕ and meaning something
    /// else entirely. Reserving space on the card's first line was not
    /// enough: the buttons still sat on the fill. The card starts below
    /// them instead, which costs eighteen points and gives the chrome its
    /// own line. Panel top padding 14, chrome top 8 and 21 tall, so the
    /// chrome ends 15 into the content; 18 clears it.
    ///
    /// On a notched Mac that drop is no longer spent: the chrome moves up
    /// into the black band beside the cutout (`chromeInBand`), and every
    /// banner — not only the card — starts at the top of the content. The
    /// talk-key row used to have no drop at all and sat under the ⌃.
    private static let chromeDrop = CGFloat(ConversationPanel.Metric.chromeDrop)

    /// The floating window has no band and no chrome drop: its header is a
    /// row of its own, so everything under it starts at the top, as it does
    /// under a notch.
    private var chromeInBand: Bool {
        floating != nil
            || ConversationPanel.chromeFitsInBand(panelWidth: Double(contentSize.width), notch: notchSize)
    }

    /// Points between the cutout (or the system's microphone pill beside a
    /// capsule) and the card's edge, for the header's buttons. Unbounded
    /// when the header has a row of its own.
    private var headerRoom: CGFloat {
        guard chromeInBand, floating == nil else { return .infinity }
        let half = contentSize.width / 2
        if let capsule { return half - CapsuleIsland.inner(capsule, indicatorLive: indicatorLive).right }
        return half - notchSize.width / 2
    }

    /// Out of the notch, into a window of its own (`FloatingChatWindow`).
    private var detachButton: some View {
        IslandButton(icon: "pip.exit") { onDetach() }
            .help("Pop out the chat (\(FloatingChatWindow.shortcut)): a window you can move, resize and keep over any app")
            .accessibilityLabel("Pop out the chat")
            .accessibilityHint("Opens the conversation in a window you can move and resize")
    }

    private var hasBanners: Bool {
        conductor.meetingOffer != nil || accessibilityProblem != nil
            || updateNoticeShowing || !conductor.fixOffers.isEmpty
    }

    /// A Fix card's buttons, in order — one list for the row and for
    /// `NotchIsland`, which counts them to size the panel.
    static func fixActions(_ offer: FixOffer) -> [String] {
        (offer.actionTitle.map { [$0] } ?? []) + [FixOffer.dismiss]
    }

    /// "A new version of Memoe is ready." — only once Moe is idle, never in a
    /// snapshot. `UpdateReadyPolicy` decides; NotchIsland sizes the panel from
    /// the same call.
    private var updateNoticeShowing: Bool {
        !snapshotting && updateNotice.showing(for: conductor)
    }

    /// A turn's text with its markdown read — bold, italic, code, links —
    /// the same parse the chat window does (`ReplyMarkdown`), and the plain
    /// text on anything that will not parse.
    ///
    /// It used to parse only a reply that held a link, and left every other
    /// one raw: "**Tomorrow is Yom Kippur**" reached the notch with its
    /// asterisks on while the window showed it bold. The guard was a
    /// shortcut for the common case, and the common case is that the model
    /// writes markdown whether or not it links anything.
    /// The same parse for text on the app's paper, where links keep the
    /// system's own colour rather than the island's.
    static func linkedOnPaper(_ text: String) -> AttributedString {
        ReplyMarkdown.inline(text)
    }

    static func linked(_ text: String) -> AttributedString {
        var attributed = ReplyMarkdown.inline(text)
        // Blue-on-black at 13pt is barely legible against this panel; the
        // island's own link colour is what the rest of it uses.
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Theme.Island.link
            attributed[run.range].underlineStyle = .single
        }
        return attributed
    }

    /// One turn of the meeting's chat tab: who, in the gutter, and what they
    /// said, with anything Moe noted under its answer.
    private func ledgerRow(_ turn: Turn, aside: Bool = false) -> some View {
        ledgerRow(gutter: Self.gutterLabel(turn.role),
                  tint: Self.gutterTint(turn.role), aside: aside) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.linked(turn.text))
                    .font(turn.role == .moe ? .system(size: 14) : .system(size: 12.5))
                    .foregroundStyle(turn.role == .moe ? .white.opacity(0.96)
                                     : turn.role == .you ? .white.opacity(0.62)
                                     : .white.opacity(0.42))
                    .lineSpacing(1.5)
                    .textSelection(.enabled)
                if turn.role == .moe, !turn.noted.isEmpty {
                    NotedLines(facts: turn.noted, style: .island) { claim in
                        conductor.forgetNoted(turnID: turn.id, claim: claim)
                    }
                }
            }
        }
    }

    private func ledgerRow<Body: View>(gutter: String, tint: Color,
                                       aside: Bool = false,
                                       @ViewBuilder body: () -> Body) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(gutter)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .trailing)
            body()
                // Capped near 52 characters. Without it a long reply ran the
                // full width of the panel and a short one left a void beside
                // it — the measure is what stops the column looking ragged.
                .frame(maxWidth: 312, alignment: .leading)
                // The row must report the height it draws.
                .fixedSize(horizontal: false, vertical: true)
                // Room for the rule, kept even on rows that have none, so the
                // room and the aside share one left edge.
                .padding(.leading, 10)
                // The rule that marks an aside, as an overlay rather than a
                // sibling — and that is the whole bug, not a stylistic choice.
                //
                // It used to be a `Rectangle().frame(width: 1.5)` sitting
                // between the gutter and the text. A rectangle with no height
                // is infinitely flexible vertically, and it was inside an
                // `HStack(alignment: .firstTextBaseline)`. A rectangle has no
                // text baseline, so SwiftUI takes its bottom edge as one and
                // hauls the flexible shape up to meet the *first* line of the
                // text beside it — which collapses the row's reported height
                // to about a line while the text goes on drawing three, over
                // the divider and the row below. An overlay cannot do that:
                // it is sized to its parent and takes no part in layout.
                .overlay(alignment: .leading) {
                    if aside {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(Theme.Island.moe.opacity(0.35))
                            .frame(width: 1.5)
                            .padding(.vertical, 1)
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func gutterLabel(_ role: Turn.Role) -> String {
        switch role {
        case .you: return "YOU"
        case .moe: return "MOE"
        // A system note has no speaker. A dash holds the spine without
        // pretending somebody said it.
        case .system: return "—"
        }
    }

    private static func gutterTint(_ role: Turn.Role) -> Color {
        switch role {
        case .moe: return Theme.Island.moe
        case .you: return .white.opacity(0.30)
        case .system: return .white.opacity(0.22)
        }
    }

    /// The first line of a cold start. Moe greets you by the hour rather
    /// than with a fixed string: the panel opens on something that sounds
    /// like somebody is there.
    static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning — I\u{2019}m here."
        case 12..<17: return "Good afternoon — I\u{2019}m here."
        case 17..<22: return "Good evening — I\u{2019}m here."
        default:      return "Still up? I\u{2019}m here."
        }
    }

    /// Everything that cannot scroll, as one block, so the drop under the
    /// chrome is paid once and `ConversationPanel` counts exactly what is
    /// here. Shared by the conversation and the working row.
    private var bannersBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            callOfferBar
            if updateNoticeShowing {
                // "Restart to update" hands Sparkle the go-ahead and it
                // relaunches Moe; "Later" asks again in a day.
                offerBar(UpdateReadyPolicy.sentence, icon: "arrow.down.circle.fill", tint: Self.amber,
                         actions: [(UpdateReadyPolicy.restartLabel, { updateNotice.restartToUpdate() }),
                                   (UpdateReadyPolicy.laterLabel, { updateNotice.later() })])
            }
            if let problem = accessibilityProblem {
                offerBar(problem, icon: "keyboard", tint: Self.amber,
                         actions: [("Fix", { ax.fix() })])
            }
            // A tool failed for a reason the person can fix (FixOffer): one
            // line of why, then the thing that fixes it, and Dismiss.
            ForEach(conductor.fixOffers) { offer in
                offerBar(offer.why, icon: "wrench.and.screwdriver.fill", tint: Self.amber,
                         actions: Self.fixActions(offer).map { title in
                             (title, { title == FixOffer.dismiss ? conductor.dismissFix(offer)
                                                                 : conductor.performFix(offer) })
                         })
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, chromeInBand ? 0 : Self.chromeDrop)
    }

    /// The ✕ and ⌃ in the corner. The working row passes `stop: false`: it
    /// has a labelled Stop of its own, and two ways to stop a foot apart is
    /// the question "which one" nobody should have to ask.
    private func chrome(stop: Bool) -> some View {
        HStack(spacing: 6) {
            if stop {
                IslandButton(icon: "xmark") { conductor.cancelEverything() }
                    .help("Stop — close the microphone and drop this turn")
                    .accessibilityLabel("Stop")
            }
            IslandButton(icon: "chevron.up") { onClose() }
                .help("Fold the panel away (esc)")
                .accessibilityLabel("Fold the panel away")
        }
        .padding(.top, chromeInBand ? 0 : 8)
        .padding(.trailing, 8)
        // Up into the band beside the notch, centred in it: the overlay's
        // top is the content's top, which is the band's bottom.
        .offset(y: chromeInBand ? bandLift(21) : 0)
    }
}

/// The clock on the working row. Ticks once a second; a snapshot draws it
/// once, from the posed start, so the shot is the same every time.
struct WorkingClock: View {
    let since: Date
    var frozen = false
    /// The island's dim white; the Chat page passes its own ink.
    var ink: Color = .white.opacity(0.35)
    var size: CGFloat = 11

    var body: some View {
        if frozen {
            label(Date())
        } else {
            TimelineView(.periodic(from: since, by: 1)) { context in label(context.date) }
        }
    }

    private func label(_ now: Date) -> some View {
        Text(WorkingRow.elapsed(now.timeIntervalSince(since)))
            .font(.system(size: size).monospacedDigit())
            .foregroundStyle(ink)
    }
}

/// The dot on the working row, breathing.
struct Breathing: ViewModifier {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                // Reduce Motion: the dot stays lit and still.
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// A named action, for the one button on a panel that deserves a word
/// rather than a glyph. The circular `IslandButton`s are right for the
/// things you already know (stop, close); they are wrong for "Open notes",
/// which nobody guesses from a document icon.
struct IslandPill: View {
    let icon: String
    let label: String
    /// The one pill that is a primary action rather than an offer — Play,
    /// on the amber card — takes the card's own colour, so the eye lands
    /// on it rather than on the grey word beside it. Everything else keeps
    /// the neutral fill and passes nothing.
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(tint == nil ? .white.opacity(hovering ? 1 : 0.85)
                                         : Color.black.opacity(hovering ? 0.95 : 0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint?.opacity(hovering ? 1 : 0.88)
                                       ?? Color.white.opacity(hovering ? 0.18 : 0.11)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Muted" — the tab under the folded notch: solid red, white word, the
/// slashed mic. A label, not a button: the hosting view takes the click and
/// opens the island (`IslandBehaviour.click`). Until 2026-09-25 it read
/// "Muted · tap to talk" and a tap unmuted.
struct MutedTab: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.slash.fill").accessibilityHidden(true).font(.system(size: 9, weight: .bold))
            Text(ConversationControls.mutedPill)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Theme.Island.recording.opacity(0.92)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// "Unmute" — the one control on the island that unmutes: red, the slashed
/// mic and the word, at the leading end of the control row, away from the ⋯.
struct UnmutePill: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill").accessibilityHidden(true).font(.system(size: 9, weight: .bold))
                Text(ConversationControls.unmuteButton)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Theme.Island.recording.opacity(hovering ? 1 : 0.88)))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(ConversationControls.unmuteHelp)
    }
}

/// The glyph of an answer's ▶ ↺ ⋯ — smaller and quieter than the island's
/// own controls, because it sits under every answer rather than once.
struct AnswerGlyph: View {
    let icon: String
    var lit = false
    var hovering = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(lit ? Theme.Island.moe : .white.opacity(hovering ? 0.8 : 0.45))
            .frame(width: 18, height: 16)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.07)))
            .contentShape(Capsule())
    }
}

struct AnswerButton: View {
    let icon: String
    var lit = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) { AnswerGlyph(icon: icon, lit: lit, hovering: hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }
}

/// A small round button for the island's controls.
struct IslandButton: View {
    /// How far past its drawn edge a header button answers a click.
    static let reach: CGFloat = (24 - 21) / 2
    let icon: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(prominent ? Color.white : .white.opacity(0.7))
                .frame(width: 21, height: 21)
                .background(
                    Circle().fill(prominent ? Theme.Island.recording.opacity(0.9)
                                            : Color.white.opacity(hovering ? 0.2 : 0.11))
                )
                // Drawn at 21 so the header's arithmetic is unchanged
                // (`NotchCardHeader`); pressable across 24, the smallest
                // target anywhere in chat (deep dive §2.10). The 6 between
                // buttons leaves the wider circles apart.
                .contentShape(Circle().inset(by: -IslandButton.reach))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One small round icon in the dropdown's tray (`IslandTray`). A switch
/// shows what is true now: `.plain` when normal, filled when changed from
/// normal (`.lit`, or `.red` for a muted mic). The ⋯ itself is `.quiet`.
struct TrayButton: View {
    enum Style { case plain, quiet, lit, red, driving }
    let icon: String
    let style: Style
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(width: 26, height: 26)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var glyph: Color {
        switch style {
        case .plain: return .white.opacity(0.85)
        case .quiet: return .white.opacity(hovering ? 0.95 : 0.55)
        case .lit: return .black
        case .red, .driving: return .white
        }
    }

    private var fill: Color {
        switch style {
        case .plain: return .white.opacity(hovering ? 0.18 : 0.09)
        case .quiet: return .white.opacity(hovering ? 0.12 : 0)
        case .lit: return .white.opacity(0.9)
        case .red: return Theme.Island.recording
        case .driving: return Theme.Island.driving
        }
    }
}

/// The state light: red listening, cyan thinking, green speaking.
struct StateDot: View {
    let mode: Conductor.Mode
    let level: Float

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.2)).frame(width: 20, height: 20)
            Circle().fill(tint).frame(width: size, height: size)
                .animation(.easeOut(duration: 0.08), value: size)
        }
    }

    private var size: CGFloat { mode == .listening ? 7 + CGFloat(level) * 9 : 8 }

    private var tint: Color {
        switch mode {
        case .idle:      return .white.opacity(0.4)
        case .listening: return .red
        case .thinking:  return .cyan
        case .speaking:  return .green
        }
    }
}

/// The ears' level bars: three white bars, bottom-aligned on a centre line.
struct EarBars: View {
    let heights: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: IslandEars.barGap) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: IslandEars.barWidth, height: max(2, min(IslandEars.barMax, h)))
            }
        }
        .frame(height: IslandEars.barMax)
    }
}

/// The open panel's outline: the slab hanging from the top edge of the screen
/// (`IslandPanelShape`, unchanged), or — on a Mac whose camera floats in a
/// capsule — a card that does not reach the top edge at all, so all four of
/// its corners are rounded.
struct IslandCardShape: Shape {
    var cornerRadius: CGFloat
    var floating = false

    func path(in rect: CGRect) -> Path {
        guard floating else { return IslandPanelShape(cornerRadius: cornerRadius).path(in: rect) }
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
    }
}

/// The folded island's hit area: the notch plus whichever ears are out,
/// measured from the frame's centre; or the whole frame when open.
struct IslandHitShape: Shape {
    var full: Bool
    var left: CGFloat = 0
    var right: CGFloat = 0
    /// A floating card: the frame's top `topInset` points are not the
    /// island's, except a column `stem` wide in the middle.
    var topInset: CGFloat = 0
    var stem: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        if full, topInset > 0 {
            var p = Path(CGRect(x: rect.minX, y: rect.minY + topInset,
                                width: rect.width, height: max(rect.height - topInset, 0)))
            p.addRect(CGRect(x: rect.midX - stem / 2, y: rect.minY, width: stem, height: topInset))
            return p
        }
        if full { return Path(rect) }
        return Path(CGRect(x: rect.midX - left, y: rect.minY, width: left + right, height: rect.height))
    }
}

/// A text cursor, drawn: dictation's mark in the left ear. The SF Symbols
/// that carry one bring a letter with it.
struct IBeam: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}
