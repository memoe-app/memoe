import CoreGraphics
import Testing
@testable import MoeIsland

/// The folded island's ears (2026-10-15, option B of the island review):
/// what each side of the notch shows, and how far it reaches.
@Suite struct IslandEarsTests {

    /// A stand-in for the real font: 6 pt a character. The view measures with
    /// the real one; these tests are about which ear shows what.
    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }

    private func ears(_ f: (inout IslandEars.Inputs) -> Void = { _ in })
        -> (left: IslandEars.Left?, right: IslandEars.Right?) {
        var i = IslandEars.Inputs()
        f(&i)
        return IslandEars.of(i)
    }

    @Test func idleIsOneDimDotOnTheRightAndNothingOnTheLeft() {
        let e = ears()
        #expect(e.left == nil)
        #expect(e.right == .presence)
        #expect(IslandEars.presenceOpacity < 0.5, "present, not glowing")
    }

    /// "An ear covers menu-bar icons next to the notch": at rest it is about
    /// twenty points, no more.
    @Test func theIdleEarIsNarrow() {
        let reach = IslandEars.reach(IslandEars.Right.presence, measure: measure)
        #expect(reach > 0)
        #expect(reach <= 22)
        #expect(IslandEars.reach(IslandEars.Left?.none, measure: measure) == 0)
    }

    @Test func listeningOpensTheLeftEarWithBars() {
        #expect(ears { $0.listening = true }.left == .levels)
        #expect(ears { $0.speaking = true }.left == .speaking)
    }

    /// Muted was a red halo and a red tab; it is a word in the left ear now,
    /// whatever else is going on outside a meeting or dictation.
    @Test func mutedIsAWord() {
        #expect(ears { $0.listening = true; $0.muted = true }.left == .muted)
        #expect(ears { $0.speaking = true; $0.muted = true }.left == .muted)
        #expect(ears { $0.working = true; $0.muted = true }.left == .muted)
    }

    @Test func aHeldReplySaysPausedRatherThanLookingIdle() {
        #expect(ears { $0.speaking = true; $0.replyPaused = true }.left == .paused)
        #expect(ears { $0.speaking = true; $0.replyPaused = true }.left != ears().left)
    }

    /// Thinking keeps the running light, and the ears tuck away under it.
    @Test func workingTucksThePresenceDot() {
        let e = ears { $0.working = true }
        #expect(e.left == nil)
        #expect(e.right == nil)
    }

    /// The notification pill: it slides out with the line, and when the line
    /// goes it retracts to the dot — full white if something is still waiting.
    @Test func aNoticeWidensTheRightEarAndRetracts() {
        let line = "Marketing brief · Reply draft for you"
        let out = ears { $0.noticeLine = line; $0.waiting = true }
        #expect(out.right == .notice(line))
        let wide = IslandEars.reach(out.right, measure: measure)

        let after = ears { $0.waiting = true }
        #expect(after.right == .waiting)
        let narrow = IslandEars.reach(after.right, measure: measure)
        #expect(wide > narrow + 100)
        #expect(narrow <= 22)
    }

    @Test func aNoticeNeverInterruptsAMeetingOrDictation() {
        #expect(ears { $0.noticeLine = "x"; $0.recording = true }.right == nil)
        #expect(ears { $0.noticeLine = "x"; $0.dictationOn = true; $0.dictating = true }.right == .presence)
    }

    /// Computer use was magenta. It is words now, with the Stop, and it
    /// outranks everything else on the right — a notice included.
    @Test func drivingSaysWhatAndOffersStop() {
        let e = ears { $0.driving = "Using Safari"; $0.working = true; $0.noticeLine = "x" }
        #expect(e.right == .driving("Using Safari"))
    }

    @Test func theStopChipIsWhereItIsDrawn() {
        let right = IslandEars.Right.driving("Using Safari")
        let notch: CGFloat = 185
        let outer = notch / 2 + IslandEars.reach(right, measure: measure)
        #expect(IslandEars.hitsStop(xFromCentre: outer - IslandEars.outerPad - 4, notchWidth: notch,
                                    right: right, measure: measure))
        // The words before the chip, the notch, and the far side are not Stop.
        #expect(!IslandEars.hitsStop(xFromCentre: notch / 2 + 20, notchWidth: notch,
                                     right: right, measure: measure))
        #expect(!IslandEars.hitsStop(xFromCentre: 0, notchWidth: notch, right: right, measure: measure))
        #expect(!IslandEars.hitsStop(xFromCentre: -(outer - 10), notchWidth: notch,
                                     right: right, measure: measure))
        #expect(!IslandEars.hitsStop(xFromCentre: outer + 1, notchWidth: notch,
                                     right: right, measure: measure))
        // No driving ear, no Stop.
        #expect(!IslandEars.hitsStop(xFromCentre: outer - 10, notchWidth: notch,
                                     right: .presence, measure: measure))
    }

    @Test func aRecordedMeetingIsTheRecordingEar() {
        let e = ears { $0.recording = true; $0.listening = true; $0.muted = true }
        #expect(e.left == .recording(paused: false, whisper: false))
        #expect(e.right == nil, "the Recording ear is the presence; no second mark over the call")
        #expect(ears { $0.recording = true; $0.meetingPaused = true }.left == .recording(paused: true, whisper: false))
        #expect(ears { $0.recording = true; $0.meetingLine = "2 action items" }.right == .meeting("2 action items"))
    }

    @Test func dictationShowsTheCursorAndThenTheLight() {
        #expect(ears { $0.dictationOn = true; $0.dictating = true; $0.listening = true }.left == .dictating)
        let tidying = ears { $0.dictationOn = true; $0.working = true }
        #expect(tidying.left == nil)
        #expect(tidying.right == nil)
    }

    @Test func openTheEarsAreGone() {
        let e = ears { $0.open = true; $0.listening = true; $0.noticeLine = "x"; $0.driving = "Using Safari" }
        #expect(e.left == nil)
        #expect(e.right == nil)
    }

    /// The running light is crisp: a sharp head, and a tail that fades by
    /// steps from faint behind to brighter near the head, all behind it.
    @Test func theTrailFadesTowardsItsHead() {
        let tail = IslandTrail.tail
        #expect(tail.count >= 3)
        #expect(zip(tail, tail.dropFirst()).allSatisfy { $0.opacity < $1.opacity && $0.start < $1.start })
        #expect(tail.allSatisfy { $0.start + $0.length <= 0.0001 }, "the tail is behind the head")
        #expect(tail.allSatisfy { $0.opacity < 1 })
    }
}

/// The same decisions on a Mac whose camera floats in a capsule
/// (2026-11-12): at rest the island is the hardware and nothing else, and
/// working is a ring and a word inside the capsule, not a light round it.
struct CapsuleEarsTests {

    private func inputs(_ f: (inout IslandEars.Inputs) -> Void) -> IslandEars.Inputs {
        var i = IslandEars.Inputs()
        i.capsule = true
        f(&i)
        return i
    }

    @Test func atRestNothingIsOut() {
        let e = IslandEars.of(inputs { _ in })
        #expect(e.left == nil)
        #expect(e.right == nil)
        // The same state on a notch keeps its dot: nothing changed there.
        let notch = IslandEars.of(IslandEars.Inputs())
        #expect(notch.right == .presence)
    }

    @Test func listeningPutsBarsLeftAndTheDotRight() {
        let e = IslandEars.of(inputs { $0.listening = true })
        #expect(e.left == .levels)
        #expect(e.right == .presence)
    }

    /// The owner's photographs of 2026-11-12 (IMG_0629, IMG_0630): idle, a
    /// notice unread, and a black run right of the camera holding one white
    /// dot. At rest a capsule shows nothing, waiting or not.
    @Test func somethingWaitingAddsNothingAtRest() {
        let e = IslandEars.of(inputs { $0.waiting = true })
        #expect(e.left == nil)
        #expect(e.right == nil)
        // The dot is still there once the island is out for something else.
        let busy = IslandEars.of(inputs { $0.waiting = true; $0.listening = true })
        #expect(busy.left == .levels)
        #expect(busy.right == .waiting)
        // A notice arriving still grows it: that is news, not rest.
        let peek = IslandEars.of(inputs { $0.waiting = true; $0.noticeLine = "Dana replied" })
        #expect(peek.right == .notice("Dana replied"))
        // A notch keeps its white dot: nothing changed there.
        var n = IslandEars.Inputs()
        n.waiting = true
        #expect(IslandEars.of(n).right == .waiting)
    }

    /// The follow-up window: the microphone is open in case you go on, and
    /// nobody is speaking. Rest — the bars come when somebody is heard.
    @Test func betweenTurnsNothingIsOutUntilSomebodySpeaks() {
        let quiet = IslandEars.of(inputs { $0.listening = true; $0.betweenTurns = true })
        #expect(quiet.left == nil && quiet.right == nil)
        let heard = IslandEars.of(inputs { $0.listening = true })
        #expect(heard.left == .levels && heard.right == .presence)
        // Muted between turns is still said: it is a state the person chose.
        let muted = IslandEars.of(inputs { $0.listening = true; $0.betweenTurns = true; $0.muted = true })
        #expect(muted.left == .muted)
        // A notch is unchanged.
        var n = IslandEars.Inputs()
        n.listening = true
        n.betweenTurns = true
        #expect(IslandEars.of(n).left == .levels)
    }

    @Test func workingIsARingAndAWord() {
        let e = IslandEars.of(inputs { $0.working = true; $0.workingWord = "Thinking" })
        #expect(e.left == .working)
        #expect(e.right == .working("Thinking", ring: false))
        // On a notch, working tucks both ears away: the light runs round it.
        var n = IslandEars.Inputs()
        n.working = true
        n.workingWord = "Thinking"
        #expect(IslandEars.of(n).left == nil)
        #expect(IslandEars.of(n).right == nil)
    }

    @Test func workingWhileMutedKeepsTheWordAndMovesTheRing() {
        let e = IslandEars.of(inputs { $0.working = true; $0.workingWord = "Working"; $0.muted = true })
        #expect(e.left == .muted)
        #expect(e.right == .working("Working", ring: true))
    }

    @Test func drivingKeepsItsStopAndGainsTheRing() {
        let e = IslandEars.of(inputs { $0.working = true; $0.workingWord = "Working"; $0.driving = "Using Safari" })
        #expect(e.left == .working)
        #expect(e.right == .driving("Using Safari"))
    }

    @Test func openHasNoEarsOnACapsuleEither() {
        let e = IslandEars.of(inputs { $0.open = true; $0.listening = true })
        #expect(e.left == nil && e.right == nil)
    }

    @Test func theStopChipIsFoundInsideTheCap() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }
        let right = IslandEars.Right.driving(String(repeating: "x", count: 80))
        let outer = 29 + CapsuleIsland.maximumRightReach
        #expect(IslandEars.hitsStop(xFromCentre: outer - 12, notchWidth: 58, right: right,
                                    maximumReach: CapsuleIsland.maximumRightReach, measure: measure))
        #expect(!IslandEars.hitsStop(xFromCentre: outer + 2, notchWidth: 58, right: right,
                                     maximumReach: CapsuleIsland.maximumRightReach, measure: measure))
    }
}
