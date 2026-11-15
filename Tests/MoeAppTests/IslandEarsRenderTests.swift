import AppKit
import Foundation
import SwiftUI
import Testing
import MoeIsland
@testable import Moe

/// The folded island, drawn by the real `IslandView` and read pixel by pixel
/// (2026-10-15: "no more colors or glowing").
///
/// Two promises, both about what reaches the screen rather than about a
/// constant: nothing is drawn below the notch's band in any folded state —
/// the halo used to spill fifteen points and more down over the menu bar and
/// the window under it — and nothing drawn is coloured, except the one red
/// recording dot. Revert the redesign and both go red: the old halo was a
/// blurred green, white, amber, magenta or lavender lozenge under the notch.
@MainActor
struct IslandEarsRenderTests {

    static let notch = CGSize(width: 185, height: 32)
    static let canvas = CGSize(width: 700, height: 160)

    private func conductor(_ pose: (inout Conductor.SnapshotState) -> Void) throws -> Conductor {
        try StallGuardConductorTests.requireScratchHome()
        _ = NSApplication.shared
        var s = Conductor.SnapshotState()
        pose(&s)
        let c = Conductor(config: Config())
        c.pose(s)
        return c
    }

    private func view(_ c: Conductor, notch: CGSize = notch) -> IslandView {
        IslandView(conductor: c, presentation: .collapsed, notchSize: notch,
                   contentSize: CGSize(width: notch.width, height: 0),
                   draft: IslandDraft(), takesFocus: false,
                   onTap: {}, onHover: { _ in })
    }

    /// RGBA, premultiplied, row 0 at the top.
    private func pixels(_ v: IslandView) throws -> (data: [UInt8], width: Int, height: Int) {
        let r = ImageRenderer(content: v.frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .environment(\.islandSnapshot, true))
        r.scale = 1
        let cg = try #require(r.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data, w, h)
    }

    private static let states: [(String, (inout Conductor.SnapshotState) -> Void)] = [
        ("idle", { _ in }),
        ("listening", { $0.mode = .listening; $0.inConversation = true; $0.level = 0.9 }),
        ("muted", { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true; $0.level = 0.9 }),
        ("thinking", { $0.mode = .thinking; $0.working = true; $0.acting = true }),
        ("speaking", { $0.mode = .speaking; $0.inConversation = true }),
        ("paused", { $0.mode = .speaking; $0.inConversation = true; $0.replyPaused = true }),
        ("driving", { $0.mode = .thinking; $0.acting = true; $0.drivingApp = "Safari" }),
        ("dictation", { $0.dictation = .listening; $0.level = 0.8 }),
        ("transcribing", { $0.dictation = .transcribing }),
        ("notice", { s in
            s.notices = InboxSamples.items()
            s.noticePeek = s.notices.first
        }),
        ("waiting", { $0.notices = InboxSamples.items() }),
    ]

    @Test(arguments: [IslandEarsRenderTests.notch, .zero])
    func nothingIsDrawnBelowTheNotchInAnyState(notch: CGSize) throws {
        // The band the notch occupies, plus the running light's 2.5 pt inset
        // and its 2 pt stroke: that is all a folded island may cover.
        let band = Int((notch.height > 0 ? notch.height : NotchGeometry.virtualNotch.height) + 5)
        for (name, pose) in Self.states {
            let p = try pixels(view(try conductor(pose), notch: notch))
            var below = 0
            for y in band..<p.height {
                for x in 0..<p.width where p.data[(y * p.width + x) * 4 + 3] > 2 { below += 1 }
            }
            #expect(below == 0, "\(name): \(below) pixels drawn below the notch's band")
        }
    }

    @Test func everythingDrawnIsWhiteGreyOrBlack() throws {
        for (name, pose) in Self.states {
            let p = try pixels(view(try conductor(pose)))
            var coloured = 0
            for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 12 {
                let rgb = [p.data[i], p.data[i + 1], p.data[i + 2]].map(Int.init)
                if rgb.max()! - rgb.min()! > 12 { coloured += 1 }
            }
            #expect(coloured == 0, "\(name): \(coloured) coloured pixels")
        }
    }

    /// The control: the one colour that stays — a recorded meeting's dot —
    /// is found by the same reading, so the check above can see colour.
    @Test func theRecordingDotIsTheOneColour() throws {
        let c = try conductor { $0.meeting = .recording(since: Date()) }
        #expect(view(c).ears.left == .recording(paused: false, whisper: false))
        let p = try pixels(view(c))
        var red = 0
        for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 200 {
            if Int(p.data[i]) - Int(p.data[i + 1]) > 60 { red += 1 }
        }
        #expect(red > 4, "the recording dot should be red")
    }

    /// The notification pill: out while the notice peeks, gone with it.
    @Test func aNoticeRidesInTheRightEarAndLeavesWithIt() throws {
        let item = InboxSamples.items()[0]
        let c = try conductor { s in
            s.notices = [item]
            s.noticePeek = item
        }
        guard case .notice(let line)? = view(c).ears.right else {
            Issue.record("no notice in the right ear: \(String(describing: view(c).ears.right))")
            return
        }
        #expect(line == NoticeTab.earLine(item))
        let out = IslandView.earReach(view(c).ears).right

        let after = try conductor { $0.notices = [item] }
        let back = IslandView.earReach(view(after).ears).right
        #expect(view(after).ears.right == .waiting)
        #expect(out > back + 60, "the ear widens for the line (\(out)) and shrinks back (\(back))")

        // Drawn: the pill reaches well past the notch on the right, and the
        // left of the notch stays clear menu bar.
        let p = try pixels(view(c))
        let mid = p.width / 2
        let y = Int(Self.notch.height / 2)
        let rightEdge = (mid..<p.width).last { p.data[(y * p.width + $0) * 4 + 3] > 200 } ?? mid
        let leftEdge = (0..<mid).first { p.data[(y * p.width + $0) * 4 + 3] > 200 } ?? mid
        #expect(rightEdge - mid > Int(Self.notch.width / 2) + 60)
        #expect(mid - leftEdge <= Int(Self.notch.width / 2) - IslandEars.overlap.toInt + 1,
                "nothing out on the left: \(mid - leftEdge)")
    }
}

private extension CGFloat {
    var toInt: Int { Int(self) }
}

/// The island on a floating camera capsule, drawn by the real `IslandView`
/// and read pixel by pixel (2026-11-12).
///
/// The numbers are the owner's MacBook Pro (Mac17,13) as measured that day:
/// macOS reports a 59 × 40 pt box; the glass is 58 × 31 pt, 8.5 pt below the
/// top of the screen. The promise is about that 8.5 pt: in no state, folded
/// or open, is anything drawn in the strip of screen above the capsule. The
/// build before this drew a black tab at least 120 pt wide from the top edge
/// down the whole 40 pt.
@MainActor
struct CapsuleIslandRenderTests {

    static let box = CGSize(width: 59, height: 40)
    static let capsule = NotchGeometry.capsule(reported: box, model: "Mac17,13")
    static let canvas = CGSize(width: 700, height: 400)

    private func conductor(_ pose: (inout Conductor.SnapshotState) -> Void) throws -> Conductor {
        try StallGuardConductorTests.requireScratchHome()
        _ = NSApplication.shared
        var s = Conductor.SnapshotState()
        pose(&s)
        let c = Conductor(config: Config())
        c.pose(s)
        return c
    }

    private func view(_ c: Conductor, _ presentation: NotchIsland.Presentation = .collapsed,
                      content: CGSize = CGSize(width: 59, height: 0),
                      capsule: NotchGeometry.CapsuleCutout? = capsule,
                      micOpen: Bool = false) -> IslandView {
        IslandView(conductor: c, presentation: presentation, notchSize: Self.box, capsule: capsule,
                   micOpenSomewhere: micOpen,
                   contentSize: content, draft: IslandDraft(), takesFocus: false,
                   onTap: {}, onHover: { _ in })
    }

    /// Alpha, one byte a pixel at 2x — the measured Mac's own scale, where
    /// the capsule's half points (8.5, 39.5) are whole pixels (17, 79). Row 0
    /// at the top; `width` and `height` are in pixels.
    private func alpha(_ v: IslandView) throws -> (a: [UInt8], width: Int, height: Int) {
        let r = ImageRenderer(content: v.frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .environment(\.islandSnapshot, true))
        r.scale = 2
        let cg = try #require(r.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (stride(from: 3, to: data.count, by: 4).map { data[$0] }, w, h)
    }

    private static let folded: [(String, (inout Conductor.SnapshotState) -> Void)] = [
        ("rest", { _ in }),
        ("listening", { $0.mode = .listening; $0.inConversation = true; $0.level = 0.9 }),
        ("muted", { $0.mode = .listening; $0.inConversation = true; $0.micMuted = true }),
        ("working", { $0.mode = .thinking; $0.working = true; $0.acting = true }),
        ("speaking", { $0.mode = .speaking; $0.inConversation = true }),
        ("driving", { $0.mode = .thinking; $0.acting = true; $0.drivingApp = "Safari" }),
        ("notice", { s in s.notices = InboxSamples.items(); s.noticePeek = s.notices.first }),
        ("meeting", { $0.meeting = .recording(since: Date()) }),
    ]

    /// 8.5 pt of lit screen above the capsule is pixel rows 0…16; the capsule
    /// ends at 39.5 pt, so pixel row 79 is the first below it.
    @Test func theStripAboveTheCapsuleStaysLitInEveryFoldedState() throws {
        for (name, pose) in Self.folded {
            let p = try alpha(view(try conductor(pose)))
            let above = (0..<17).reduce(0) { n, y in
                n + (0..<p.width).filter { p.a[y * p.width + $0] > 2 }.count
            }
            #expect(above == 0, "\(name): \(above) pixels drawn above the capsule")
            // And nothing below it: the capsule ends at 39.5.
            let below = (79..<p.height).reduce(0) { n, y in
                n + (0..<p.width).filter { p.a[y * p.width + $0] > 2 }.count
            }
            #expect(below == 0, "\(name): \(below) pixels drawn below the capsule")
        }
    }

    /// At rest: 58 pt of black across the capsule's middle row (y 24), and
    /// not a point more. The old tab was 120.
    @Test func atRestOnlyTheCapsuleIsDrawn() throws {
        let p = try alpha(view(try conductor { _ in }))
        // 58 pt is 116 pixels, centred on pixel 700 of 1400.
        let row = (0..<p.width).filter { p.a[48 * p.width + $0] > 127 }
        #expect(row.count == 116, "drawn \(row.count) pixels wide at rest")
        #expect(row.first == 642)
        #expect(row.last == 757)
        // 31 pt is 62 pixels, from 17 (8.5 pt) to 78 (39.5 pt).
        let column = (0..<p.height).filter { p.a[$0 * p.width + 700] > 127 }
        #expect(column.first == 17)
        #expect(column.last == 78)
    }

    /// Every way the owner's Mac can be at rest, with and without a
    /// microphone open somewhere (macOS's own pill or dot beside the camera):
    /// nothing is drawn outside the camera's 58 × 31 pt — pixels 642…757
    /// across and 17…78 down at 2x. IMG_0629 and IMG_0630 (2026-11-12) were
    /// "waiting" with a microphone open: 77 pt of black and a white dot
    /// right of the camera, which this reads as 154 pixels past 757.
    static let restStates: [(String, (inout Conductor.SnapshotState) -> Void)] = [
        ("rest", { _ in }),
        ("waiting", { $0.notices = InboxSamples.items() }),
        ("wake word on", { $0.alwaysListening = true }),
        ("wake word on, waiting", { $0.alwaysListening = true; $0.notices = InboxSamples.items() }),
        ("conversation open, quiet", { $0.inConversation = true }),
        ("between turns", { $0.mode = .listening; $0.inConversation = true; $0.betweenTurns = true }),
        ("between turns, waiting", { s in
            s.mode = .listening; s.inConversation = true; s.betweenTurns = true
            s.notices = InboxSamples.items()
        }),
    ]

    @Test(arguments: [false, true])
    func atRestNothingButTheCameraIsDrawnWhateverTheMicrophone(micOpen: Bool) throws {
        for (name, pose) in Self.restStates {
            let v = view(try conductor(pose), micOpen: micOpen)
            #expect(v.ears.left == nil && v.ears.right == nil, "\(name): \(v.ears)")
            let p = try alpha(v)
            var outside = 0, minX = p.width, maxX = 0
            for y in 0..<p.height {
                for x in 0..<p.width where p.a[y * p.width + x] > 2 {
                    if x < 642 || x > 757 || y < 17 || y > 78 { outside += 1 }
                    if y == 48 { minX = min(minX, x); maxX = max(maxX, x) }
                }
            }
            #expect(outside == 0, "\(name), mic \(micOpen): \(outside) pixels outside the camera")
            #expect(minX == 642 && maxX == 757, "\(name), mic \(micOpen): drawn \(minX)…\(maxX)")
        }
    }

    /// The control, and the other half of the promise: every state the
    /// owner named — listening, thinking, speaking, a notice — still grows
    /// the capsule sideways, microphone open or not.
    @Test(arguments: [false, true])
    func theActiveStatesStillGrow(micOpen: Bool) throws {
        let active: [(String, (inout Conductor.SnapshotState) -> Void)] = [
            ("listening", { $0.mode = .listening; $0.inConversation = true; $0.level = 0.9 }),
            ("thinking", { $0.mode = .thinking; $0.working = true }),
            ("speaking", { $0.mode = .speaking; $0.inConversation = true }),
            ("notice", { s in s.notices = InboxSamples.items(); s.noticePeek = s.notices.first }),
            ("listening, waiting", { s in
                s.mode = .listening; s.inConversation = true; s.level = 0.9
                s.notices = InboxSamples.items()
            }),
        ]
        for (name, pose) in active {
            let p = try alpha(view(try conductor(pose), micOpen: micOpen))
            let row = (0..<p.width).filter { p.a[48 * p.width + $0] > 127 }
            let width = (row.last ?? 0) - (row.first ?? 0) + 1
            #expect(width > 116 + 40, "\(name), mic \(micOpen): only \(width) pixels wide")
        }
    }

    /// Listening: wider than the glass on both sides, still 31 pt tall.
    @Test func listeningGrowsSidewaysOnly() throws {
        let p = try alpha(view(try conductor { $0.mode = .listening; $0.inConversation = true }))
        let row = (0..<p.width).filter { p.a[48 * p.width + $0] > 127 }
        #expect((row.first ?? 700) < 642 - 30)
        #expect((row.last ?? 700) > 757 + 30)
        let column = (0..<p.height).filter { p.a[$0 * p.width + 700] > 127 }
        #expect(column.first == 17)     // 8.5 pt
        #expect(column.last == 78)      // 39.5 pt
    }

    /// Open: a card from the capsule's top edge. The strip above is clear
    /// right across, the top corners are rounded (the old panel was square
    /// against the top of the screen), and the card is black under the
    /// camera's band.
    @Test func theOpenCardFloats() throws {
        let content = CGSize(width: 420, height: 190)
        let c = try conductor { $0.turns = [Turn(role: .you, text: "hello"), Turn(role: .moe, text: "Hello.")] }
        let p = try alpha(view(c, .expanded, content: content))
        // Only the card's soft shadow may reach up there; nothing solid.
        let above = (0..<17).reduce(0) { n, y in
            n + (0..<p.width).filter { p.a[y * p.width + $0] > 127 }.count
        }
        #expect(above == 0, "\(above) solid points drawn above the card")
        // The card's own top row, in the middle: black.
        #expect(p.a[24 * p.width + 700] > 250)
        #expect(p.a[24 * p.width + 700 - 300] > 250)
        // Its top-left corner is rounded away: 2 pt in from the corner of a
        // 24 pt radius is outside the card, and it is not black. The shadow
        // may tint it.
        #expect(p.a[20 * p.width + (700 - 420 + 4)] < 200)
        // Bottom edge: 40 + 190.
        #expect(p.a[450 * p.width + 700] > 250)
    }

    /// The control: the same view without a capsule draws from the top edge
    /// of the screen, so the reading above can see what it forbids.
    @Test func withoutACapsuleThePanelStillReachesTheTopEdge() throws {
        let content = CGSize(width: 420, height: 190)
        let c = try conductor { $0.turns = [Turn(role: .you, text: "hello"), Turn(role: .moe, text: "Hello.")] }
        let p = try alpha(view(c, .expanded, content: content, capsule: nil))
        #expect(p.a[0 * p.width + 700 - 300] > 250)
        #expect(p.a[4 * p.width + (700 - 420 + 4)] > 250)
    }

    // MARK: - macOS's microphone pill (`NotchGeometry.SystemIndicator`)

    /// Pixels of anything but black inside a rectangle given in points from
    /// the cutout's centre line and the top of the screen: the ring, the
    /// bars, a dot, a word. The island's own black is not counted — black
    /// under the system's pill is the point.
    private func lit(_ v: IslandView, in rect: CGRect) throws -> Int {
        let r = ImageRenderer(content: v.frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .environment(\.islandSnapshot, true))
        r.scale = 2
        let cg = try #require(r.cgImage)
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for y in max(Int(rect.minY * 2), 0)..<min(Int(rect.maxY * 2), h) {
            for x in max(Int(rect.minX * 2) + w / 2, 0)..<min(Int(rect.maxX * 2) + w / 2, w)
            where data[(y * w + x) * 4] > 40 { n += 1 }
        }
        return n
    }

    /// The owner's photograph of 2026-11-12: the system's pill over the
    /// island, and of "Thinking" only the "g" left showing. With a
    /// microphone open, in every folded state, nothing the island has to say
    /// is drawn where that pill can be — and it is still said, beside it.
    @Test func nothingIsSaidUnderTheSystemsPillInAnyFoldedState() throws {
        let pill = Self.capsule.indicator.pill
        let leftOfIt = CGRect(x: -350, y: 0, width: 350 + pill.minX, height: 60)
        let rightOfIt = CGRect(x: pill.maxX, y: 0, width: 350 - pill.maxX, height: 60)
        for (name, pose) in Self.folded {
            let v = view(try conductor(pose), micOpen: true)
            #expect(v.indicatorLive)
            #expect(try lit(v, in: pill) == 0, "\(name): drawn under the system's pill")
            if name != "rest" {
                #expect(try lit(v, in: leftOfIt) + lit(v, in: rightOfIt) > 8, "\(name): nothing left to see")
            }
        }
    }

    /// Memoe's own microphone is known without the watch: listening, the
    /// pill is assumed the moment the microphone opens.
    @Test func memoesOwnMicrophoneCountsWithoutBeingTold() throws {
        let listening = view(try conductor { $0.mode = .listening; $0.inConversation = true; $0.level = 0.9 })
        #expect(listening.indicatorLive)
        #expect(try lit(listening, in: Self.capsule.indicator.pill) == 0)
        let wake = view(try conductor { $0.mode = .thinking; $0.alwaysListening = true })
        #expect(wake.indicatorLive)
        #expect(try lit(wake, in: Self.capsule.indicator.pill) == 0)
        // Not on a notch: there is no pill there to step round.
        let notched = IslandView(conductor: try conductor { $0.mode = .listening }, presentation: .collapsed,
                                 notchSize: CGSize(width: 185, height: 32), micOpenSomewhere: true,
                                 contentSize: CGSize(width: 185, height: 0), draft: IslandDraft(),
                                 takesFocus: false, onTap: {}, onHover: { _ in })
        #expect(!notched.indicatorLive)
    }

    /// The control: with no microphone open anywhere the working ring and
    /// word sit at the camera's edges, inside where the pill would be — so
    /// the reading above can see what it forbids.
    @Test func withNoMicrophoneTheWordSitsAtTheCamerasEdge() throws {
        let v = view(try conductor { $0.mode = .thinking; $0.working = true; $0.acting = true })
        #expect(!v.indicatorLive)
        #expect(try lit(v, in: Self.capsule.indicator.pill) > 40)
    }

    /// Open: the status word is in the band once, and not again as the
    /// first row under it (the photograph had "Thinking" twice). A step is
    /// still a row, because the band then says "Working".
    @Test func theOpenCardSaysThinkingOnce() throws {
        let thinking = try conductor { $0.mode = .thinking; $0.turns = [Turn(role: .you, text: "what's going on")] }
        #expect(IslandView.chatRows(thinking).last == .working(label: "Thinking"))
        #expect(IslandView.chatRows(thinking, statusOnce: true).count == 1)
        #expect(!IslandView.chatRows(thinking, statusOnce: true).contains(.working(label: "Thinking")))
        // The panel's height arithmetic agrees with what is drawn.
        let draft = IslandDraft()
        let capsule = IslandView.dropdownContents(thinking, draft: draft, accessibility: nil, updateShowing: false,
                                                  width: 420, notch: Self.box)
        let notch = IslandView.dropdownContents(thinking, draft: draft, accessibility: nil, updateShowing: false,
                                                width: 420, notch: CGSize(width: 185, height: 32))
        #expect(capsule.chat.count == 1)
        #expect(notch.chat.count == 2)   // a notched Mac is as it was
    }

    /// The watch's one rule: the indicator is assumed for ten seconds after
    /// the last microphone closes, because the system's outlives it.
    @Test func theIndicatorIsAssumedForAWhileAfterTheMicrophoneCloses() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(!MicIndicatorWatch.holds(lastOpen: nil, now: t))
        #expect(MicIndicatorWatch.holds(lastOpen: t, now: t))
        #expect(MicIndicatorWatch.holds(lastOpen: t, now: t.addingTimeInterval(9)))
        #expect(!MicIndicatorWatch.holds(lastOpen: t, now: t.addingTimeInterval(11)))
    }

    /// The compact card: working, nothing in the conversation. The band
    /// says "Thinking"; under it is the field and nothing else. Before, an
    /// empty row sat between them holding only the ⋯ at its far right — 36
    /// of the card's 98 pt (the owner's photograph, and c69 of the first
    /// fix). The ⋯ is in the band now, and its controls take a row only
    /// while they are out.
    @Test func workingWithNothingSaidTheCardIsTheBandAndTheField() throws {
        let c = try conductor { $0.mode = .thinking }
        let draft = IslandDraft()
        #expect(IslandView.trayInHeader(c, chromeInBand: true, notch: Self.box))
        let shut = IslandView.dropdownContents(c, draft: draft, accessibility: nil, updateShowing: false,
                                               width: 420, notch: Self.box)
        #expect(shut.chat.isEmpty && !shut.controls && shut.field)
        let height = Dropdown.height(shut, wraps: IslandTextMeasure.wraps)
        #expect(height == 64)   // 12 above the field, its 34, 16 below; was 98
        // Drawn: nothing between the band (40) and the field (52).
        let v = IslandView(conductor: c, presentation: .peek, notchSize: Self.box, capsule: Self.capsule,
                           micOpenSomewhere: true, contentSize: CGSize(width: 420, height: height),
                           draft: draft, takesFocus: false, onTap: {}, onHover: { _ in })
        #expect(try lit(v, in: CGRect(x: -210, y: 44, width: 420, height: 6)) == 0)
        // The ⋯ is in the band, right of the system's pill.
        let band = CGRect(x: Self.capsule.indicator.pill.maxX, y: 14, width: 150, height: 20)
        #expect(try lit(v, in: band) > 20)

        // Its controls out: a row for them, and the card grows by it.
        draft.trayOpen = true
        let out = IslandView.dropdownContents(c, draft: draft, accessibility: nil, updateShowing: false,
                                              width: 420, notch: Self.box)
        #expect(out.controls)
        #expect(Dropdown.height(out, wraps: IslandTextMeasure.wraps) == 64 + 26 + 10 - 2)
    }

    /// Where the compact card does not apply: anything in the conversation,
    /// muted (the Unmute pill lives on the controls' row), the inbox — and
    /// any Mac without a capsule, which still has its "Thinking" row.
    @Test func theCompactCardIsOnlyForAnEmptyConversationOnACapsule() throws {
        let said = try conductor { $0.mode = .thinking; $0.turns = [Turn(role: .you, text: "what's going on")] }
        #expect(!IslandView.trayInHeader(said, chromeInBand: true, notch: Self.box))
        let muted = try conductor { $0.mode = .thinking; $0.micMuted = true }
        #expect(!IslandView.trayInHeader(muted, chromeInBand: true, notch: Self.box))
        let empty = try conductor { $0.mode = .thinking }
        let notch = CGSize(width: 185, height: 32)
        #expect(!IslandView.trayInHeader(empty, chromeInBand: true, notch: notch))
        #expect(!IslandView.trayInHeader(empty, chromeInBand: false, notch: .zero))
        let notched = IslandView.dropdownContents(empty, draft: IslandDraft(), accessibility: nil,
                                                  updateShowing: false, width: 420, notch: notch)
        // Its "Thinking" row stays. Its ⋯ is beside the send button now
        // (the owner, 2026-11-13), so no row of controls is counted until
        // they are slid out.
        #expect(!notched.controls && notched.chat.count == 1)
    }

    /// A conversation that fits its frame is drawn whole (every Mac). The
    /// end marker used to sit inside the rows' stack, ten points of spacing
    /// under the last row, so the content was ten points taller than its
    /// frame and, scrolled to its end, lost them off the top; and the "more
    /// above" fade was laid over the first row whether or not anything was
    /// above. The owner's photograph: one row, "Thinking", with no tops.
    ///
    /// On a notched Mac that row is the panel's first: 32 pt of band, 12 of
    /// padding, then 19 pt of row (44 … 63). Its letters stand on a baseline
    /// near 58 and the "g" hangs to 62, so the rows from 55 down hold ink;
    /// cut by ten points, the whole word is above 53 and they hold none.
    @Test func aConversationThatFitsIsNotCutOffAtTheTop() throws {
        let notch = CGSize(width: 185, height: 32)
        let c = try conductor { $0.mode = .thinking }
        #expect(IslandView.chatRows(c) == [.working(label: "Thinking")])
        let contents = IslandView.dropdownContents(c, draft: IslandDraft(), accessibility: nil,
                                                   updateShowing: false, width: 420, notch: notch)
        let size = CGSize(width: 420, height: Dropdown.height(contents, wraps: IslandTextMeasure.wraps))
        let v = IslandView(conductor: c, presentation: .peek, notchSize: notch, contentSize: size,
                           draft: IslandDraft(), takesFocus: false, onTap: {}, onHover: { _ in })
        let word = CGRect(x: -180, y: 44, width: 100, height: 19)
        let foot = CGRect(x: -180, y: 55, width: 100, height: 8)
        let head = CGRect(x: -180, y: 44, width: 100, height: 6)
        #expect(try lit(v, in: word) > 150, "the row is drawn")
        #expect(try lit(v, in: foot) > 60, "the word stands on its own baseline, not ten points above it")
        // The capitals' tops are 4 pt down the row: the frame's first rows
        // are clear above them, and they are not faded away.
        #expect(try lit(v, in: head) > 10, "the tops of the letters are drawn")
    }
}
