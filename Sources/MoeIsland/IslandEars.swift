import CoreGraphics
import Foundation

/// What the folded island shows beside the notch: its two "ears".
///
/// The owner, 2026-10-15: "no more colors or glowing. The thing that spins
/// around, the white thing while it's thinking, we should still have. When
/// there's a notification, it just shows on the side of the notch. If it's
/// idle, it just shows somehow that it's there, but it shouldn't be glowing."
/// Option B of the island review ("Ears"): the black notch grows a small
/// black ear on either side, the way the iPhone's Dynamic Island does. Nothing
/// floats under the notch, nothing glows, and every mark is white or grey —
/// with one exception, the red dot that says a meeting is being recorded,
/// because that is a privacy signal and red is what people look for.
///
/// This is the decision, in a library target so each state is a test; the
/// drawing is `IslandView.ears`. It replaced `IslandHalo` and `IslandBreath`,
/// the coloured, blurred, breathing light that used to surround the notch.
public enum IslandEars {

    /// The left ear: what is happening to your voice.
    public enum Left: Equatable, Sendable {
        /// Moe is listening: three white bars moved by your voice.
        case levels
        /// Moe is speaking: the same bars, moving gently on their own.
        case speaking
        /// The microphone is muted mid-conversation: the slashed mic and
        /// "Muted". Muted used to be a red halo and a red tab; it is a word now.
        case muted
        /// A reply held by a tap: the pause glyph and "Paused". Until this it
        /// looked exactly like idle.
        case paused
        /// A double-tap just stopped everything: the stop glyph and "Stopped",
        /// for a moment (`Conductor.stoppedShownSeconds`). Until this a stop
        /// only made the island go quiet, and the owner kept tapping.
        case stopped
        /// Dictation is listening: a text cursor and the level bars.
        case dictating
        /// A meeting is being recorded: a small red dot and "Recording" — the
        /// one colour left on the island. `paused` greys the dot and says so;
        /// `whisper` adds a waveform while you are asking Moe something.
        case recording(paused: Bool, whisper: Bool)
        /// Moe is working, on a Mac with a floating capsule: a small white
        /// ring with a light running round it. On a notch the light runs
        /// round the notch itself; a capsule's outline is the camera's.
        case working
    }

    /// The right ear: Moe's own presence, and anything it has to tell you.
    public enum Right: Equatable, Sendable {
        /// At rest: one dim dot. "It's there, but it shouldn't be glowing."
        case presence
        /// Something is waiting for you (a held reminder, an update, a call
        /// offer): the dot at full white. Still — nothing breathes. Not on a
        /// floating capsule at rest, which shows nothing (`of`).
        case waiting
        /// Something just arrived: the ear widens to hold its line for a few
        /// seconds (`Conductor.noticePeek`), then shrinks back to a dot.
        case notice(String)
        /// Moe has your screen or your browser: "Using Safari · Stop".
        /// Computer use used to be a magenta halo; it is words now.
        case driving(String)
        /// A meeting's news: "2 action items", "Writing notes…", "Notes ready".
        case meeting(String)
        /// Moe is working, on a floating capsule: the word ("Thinking",
        /// "Working"), with the ring beside it when the left side is taken.
        case working(String, ring: Bool)
    }

    public struct Inputs: Equatable, Sendable {
        /// The panel is open; it swallows the notch and there are no ears.
        public var open = false
        public var listening = false
        public var speaking = false
        /// Thinking or acting: the running white light owns the notch, and
        /// the presence dot tucks away.
        public var working = false
        public var muted = false
        public var replyPaused = false
        /// A stop just happened (`Left.stopped`).
        public var stopped = false
        /// Dictation is on and listening (not tidying the text).
        public var dictating = false
        /// Dictation of any kind, including the tidying pass.
        public var dictationOn = false
        /// A meeting is being recorded.
        public var recording = false
        public var meetingPaused = false
        public var whisper = false
        /// The meeting's line for the right ear, if it has one.
        public var meetingLine: String?
        /// The arrived notice's line, if one is peeking.
        public var noticeLine: String?
        /// `IslandGlow.glows` — something is waiting to be opened.
        public var waiting = false
        /// "Using Safari" / "Browsing", while Moe drives.
        public var driving: String?
        /// The Mac's camera floats in a capsule (`NotchGeometry.Cutout`).
        /// The island is that capsule and nothing else at rest, and working
        /// is shown inside it rather than as a light round the notch.
        public var capsule = false
        /// "Thinking" or "Working", for the capsule's right side.
        public var workingWord: String?
        /// A conversation is open between turns — Moe has finished and is
        /// waiting to hear whether you go on — and nobody is speaking.
        /// `listening` is still true then; on a capsule that is rest.
        public var betweenTurns = false

        public init() {}
    }

    /// Both ears for a state. Nil is an ear tucked away behind the notch.
    public static func of(_ i: Inputs) -> (left: Left?, right: Right?) {
        guard !i.open else { return (nil, nil) }
        guard i.capsule else { return (left(i), right(i)) }
        var l = left(i), r = right(i)
        // Between turns nobody is being heard: no bars until somebody is.
        if i.betweenTurns, l == .levels { l = nil }
        // Working: the ring on the left when that side is free, and the word
        // on the right when nothing else has it. A meeting keeps its right
        // side quiet, as it does on a notch.
        if i.working {
            let ringOnLeft = l == nil
            if ringOnLeft { l = .working }
            if r == nil, !i.recording, let word = i.workingWord {
                r = .working(word, ring: !ringOnLeft)
            }
        }
        // At rest the island is the hardware's capsule exactly: no dot — not
        // even the white one that says something is waiting. That dot sat
        // in 22 pt of black right of the camera, 77 pt with a microphone
        // open (it steps past macOS's pill), for as long as a notice went
        // unread, and the owner photographed it as idle on 2026-11-12: "you
        // see the black always stick out … you shouldn't see anything
        // different than the default notch." What is waiting is in the card
        // on hover; a notice arriving still grows the capsule (`notice`).
        // Both dots come back as soon as the left side has anything to say.
        if l == nil, r == .presence || r == .waiting { r = nil }
        return (l, r)
    }

    static func left(_ i: Inputs) -> Left? {
        // The stop's answer outranks everything for its moment: it is the
        // reply to the gesture just made, and a meeting's Recording ear
        // comes straight back after it.
        if i.stopped { return .stopped }
        if i.dictationOn { return i.dictating ? .dictating : nil }
        if i.recording { return .recording(paused: i.meetingPaused, whisper: i.whisper) }
        if i.muted { return .muted }
        if i.replyPaused { return .paused }
        if i.listening { return .levels }
        if i.speaking { return .speaking }
        return nil
    }

    static func right(_ i: Inputs) -> Right? {
        // Moe has the screen: the one state a person may want to end
        // mid-flight, so it outranks everything, the notice included.
        if let d = i.driving { return .driving(d) }
        if let line = i.meetingLine { return .meeting(line) }
        if let line = i.noticeLine, !i.recording, !i.dictationOn { return .notice(line) }
        if i.working { return nil }
        // During a meeting the Recording ear is the presence; a second mark
        // over somebody's call says nothing new.
        if i.recording { return nil }
        return i.waiting ? .waiting : .presence
    }

    // MARK: - Geometry

    /// How far an ear tucks under the notch. Its inner end is hidden behind
    /// the hardware, so the ear reads as the notch growing, not as a pill
    /// laid beside it, and so it can slide out from behind it.
    public static let overlap: CGFloat = 12
    /// Space between the notch's edge and an ear's contents; the running
    /// light passes through it.
    public static let innerPad: CGFloat = 8
    /// Space between an ear's contents and its outer end.
    public static let outerPad: CGFloat = 9
    /// The radius of an ear's outer bottom corner.
    public static let cornerRadius: CGFloat = 10

    public static let textSize: CGFloat = 11.5
    public static let dotSize: CGFloat = 4
    public static let waitingDotSize: CGFloat = 5
    public static let presenceOpacity: Double = 0.35
    /// The level bars: three of them, 2 pt wide, 2 pt apart, up to 12 high.
    public static let barCount = 3
    public static let barWidth: CGFloat = 2
    public static let barGap: CGFloat = 2
    public static let barMax: CGFloat = 12
    public static let glyph: CGFloat = 10
    public static let gap: CGFloat = 6
    /// The "Stop" chip in the driving ear.
    public static let stopWord = "Stop"
    public static let stopPad: CGFloat = 7

    static var barsWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }

    public static let mutedWord = "Muted"
    public static let pausedWord = "Paused"
    public static let stoppedWord = "Stopped"
    public static let recordingWord = "Recording"
    public static let recordingPausedWord = "Off the record"

    /// The width of an ear's contents, with `measure` giving a string's width
    /// at the ear's font (the view passes the real font; tests pass a rule).
    public static func contentWidth(_ left: Left, measure: (String) -> CGFloat) -> CGFloat {
        switch left {
        case .levels, .speaking: return barsWidth
        case .working: return glyph
        case .dictating: return glyph + gap + barsWidth
        case .muted: return glyph + gap + measure(mutedWord)
        case .paused: return glyph + gap + measure(pausedWord)
        case .stopped: return glyph + gap + measure(stoppedWord)
        case .recording(let paused, let whisper):
            return 6 + gap + measure(paused ? recordingPausedWord : recordingWord)
                + (whisper ? gap + glyph : 0)
        }
    }

    public static func contentWidth(_ right: Right, measure: (String) -> CGFloat) -> CGFloat {
        switch right {
        case .presence: return dotSize
        case .waiting: return waitingDotSize
        case .notice(let s): return waitingDotSize + gap + measure(s)
        case .driving(let s): return measure(s) + gap + measure(stopWord) + stopPad * 2
        case .meeting(let s): return measure(s)
        case .working(let s, let ring): return (ring ? glyph + gap : 0) + measure(s)
        }
    }

    /// How far an ear reaches past the notch's edge. Zero when tucked away.
    public static func reach(_ contentWidth: CGFloat?) -> CGFloat {
        guard let w = contentWidth else { return 0 }
        return ceil(innerPad + w + outerPad)
    }

    /// Whether a click `x` points right of the notch's centre lands on the
    /// driving ear's Stop. Generous by a few points on the inside, because
    /// the chip is small and sits at the top edge of the screen.
    public static func hitsStop(xFromCentre x: CGFloat, notchWidth: CGFloat, right: Right?,
                                maximumReach: CGFloat = .infinity,
                                measure: (String) -> CGFloat) -> Bool {
        guard case .driving? = right else { return false }
        let outer = notchWidth / 2 + min(reach(right, measure: measure), maximumReach)
        let chip = measure(stopWord) + stopPad * 2
        return x <= outer && x >= outer - outerPad - chip - 4
    }

    public static func reach(_ left: Left?, measure: (String) -> CGFloat) -> CGFloat {
        reach(left.map { contentWidth($0, measure: measure) })
    }

    public static func reach(_ right: Right?, measure: (String) -> CGFloat) -> CGFloat {
        reach(right.map { contentWidth($0, measure: measure) })
    }
}

/// The white light that runs round the notch while Moe works, as numbers.
///
/// Kept through the 2026-10-15 redesign ("the thing that spins around, the
/// white thing while it's thinking, we should still have"), and made crisp:
/// it used to be drawn twice, a 2 pt head plus a 5.5 pt copy blurred by 5,
/// over a 1.5 pt tail blurred by 2. Now the head is one sharp stroke and the
/// tail fades in steps of plain strokes — no blur anywhere, so no glow.
public enum IslandTrail {
    /// Seconds per lap of the notch.
    public static let lap: Double = 2.4
    /// Seconds per turn of the small ring a floating capsule shows instead
    /// (`IslandEars.Left.working`): a circle is a much shorter track.
    public static let ringLap: Double = 0.9
    /// Where a snapshot (`Moe --panel-snapshot`) poses the head.
    public static let snapshotPoint: CGFloat = 0.3
    /// The bright head, as a fraction of the outline.
    public static let head: CGFloat = 0.05

    public struct Step: Equatable, Sendable {
        /// Where the step starts, relative to the head (negative is behind).
        public let start: CGFloat
        public let length: CGFloat
        public let opacity: Double
    }

    /// The tail: five steps behind the head, faint to bright.
    public static let tail: [Step] = [0.06, 0.12, 0.2, 0.3, 0.42].enumerated().map { i, o in
        Step(start: -0.20 + CGFloat(i) * 0.04, length: 0.04, opacity: o)
    }
}
