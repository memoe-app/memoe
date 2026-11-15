import CoreGraphics
import Testing
@testable import MoeIsland

/// Every Mac the island has to sit on, as `NSScreen` describes it.
///
/// The first case is measured, not recalled: a 13-inch MacBook Air (Mac15,12)
/// on 2026-09-14 reported a 1470 × 956 pt frame, a 32 pt safe area, and menu
/// bar strips of 646 pt at x 0 and 645 pt at x 825. The Pros are published
/// figures laid out the same way. Every Mac without a notch — the MacBook Neo,
/// the M1 Air, an iMac, any external display — reports no strips and no inset.
struct NotchGeometryTests {

    private static let airFrame = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private static let airLeft = CGRect(x: 0, y: 924, width: 646, height: 32)
    private static let airRight = CGRect(x: 825, y: 924, width: 645, height: 32)

    @Test func theThirteenInchAirAsMeasured() {
        let g = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32,
                                      left: Self.airLeft, right: Self.airRight)
        #expect(g.size == CGSize(width: 179, height: 32))
        #expect(g.hasNotch)
        // Half a point right of the screen's centre, which is 735. Centring
        // the window on the screen is what left a hairline of bezel showing.
        #expect(g.centreX == 735.5)
        #expect(g.centreX != Self.airFrame.midX)
    }

    @Test func theFourteenInchPro() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                      left: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                      right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        #expect(g.size == CGSize(width: 185, height: 32))
        #expect(g.centreX == 756)
    }

    @Test func theSixteenInchProAtMoreSpace() {
        let frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 38,
                                      left: CGRect(x: 0, y: 1131, width: 790, height: 38),
                                      right: CGRect(x: 1010, y: 1131, width: 790, height: 38))
        #expect(g.size == CGSize(width: 220, height: 38))
        #expect(g.centreX == 900)
    }

    /// The MacBook Neo, the M1 Air, an iMac, an external display.
    @Test func aMacWithNoNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1504, height: 941)
        let g = NotchGeometry.measure(frame: frame, safeAreaTop: 0, left: nil, right: nil)
        #expect(!g.hasNotch)
        #expect(g.size == .zero)
        #expect(g.centreX == frame.midX)
        #expect(g.targetWidth == NotchGeometry.noNotchTargetWidth)
    }

    /// The laptop to the right of a 1920 pt external monitor. Whichever space
    /// the strips come in, the notch is where the laptop is — not 1920 pt to
    /// the left of it, on somebody's spreadsheet.
    @Test func aLaptopBesideAnExternalDisplay() {
        let frame = CGRect(x: 1920, y: 0, width: 1470, height: 956)
        let global = NotchGeometry.measure(
            frame: frame, safeAreaTop: 32,
            left: Self.airLeft.offsetBy(dx: 1920, dy: 0),
            right: Self.airRight.offsetBy(dx: 1920, dy: 0))
        let local = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                          left: Self.airLeft, right: Self.airRight)
        #expect(global.centreX == 1920 + 735.5)
        #expect(local == global)
    }

    @Test func aLaptopToTheLeftOfItsMainDisplay() {
        let frame = CGRect(x: -1470, y: 0, width: 1470, height: 956)
        let global = NotchGeometry.measure(
            frame: frame, safeAreaTop: 32,
            left: Self.airLeft.offsetBy(dx: -1470, dy: 0),
            right: Self.airRight.offsetBy(dx: -1470, dy: 0))
        let local = NotchGeometry.measure(frame: frame, safeAreaTop: 32,
                                          left: Self.airLeft, right: Self.airRight)
        #expect(global.centreX == -1470 + 735.5)
        #expect(local == global)
        #expect(global.size.width == 179)
    }

    /// The floating capsule gets a target a person can hit with a pointer,
    /// however small the glass is: 59 pt reported, 120 pt of target.
    @Test func aCapsuleStillGetsAHittableTarget() {
        let g = Self.capsuleMac()
        #expect(g.size.width == 59)
        #expect(g.targetWidth == NotchGeometry.minimumTargetWidth)
        #expect(NotchGeometry.targetWidth(for: CGSize(width: 179, height: 32)) == 179)
    }

    /// Strips that overlap, or leave most of the screen between them, are not
    /// describing a notch. No notch is the honest reading.
    @Test func stripsThatDescribeNoCutoutAreRefused() {
        let overlapping = NotchGeometry.measure(
            frame: Self.airFrame, safeAreaTop: 32,
            left: CGRect(x: 0, y: 924, width: 900, height: 32), right: Self.airRight)
        #expect(!overlapping.hasNotch)
        let vast = NotchGeometry.measure(
            frame: Self.airFrame, safeAreaTop: 32,
            left: CGRect(x: 0, y: 924, width: 100, height: 32),
            right: CGRect(x: 1370, y: 924, width: 100, height: 32))
        #expect(!vast.hasNotch)
        #expect(vast.centreX == Self.airFrame.midX)
    }

    /// An inset with no strips: no notch to draw, but the height is kept so
    /// the panel's content still starts below whatever the inset is for.
    @Test func anInsetWithoutStripsKeepsItsHeight() {
        let g = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32, left: nil, right: nil)
        #expect(!g.hasNotch)
        #expect(g.size.height == 32)
    }

    @Test func theIslandLivesOnTheNotchedDisplay() {
        // External monitor first (it has the menu bar), laptop second.
        #expect(NotchGeometry.hostIndex(notched: [false, true]) == 1)
        #expect(NotchGeometry.hostIndex(notched: [true, false]) == 0)
        // No notch anywhere: the display with the menu bar.
        #expect(NotchGeometry.hostIndex(notched: [false, false]) == 0)
        #expect(NotchGeometry.hostIndex(notched: []) == 0)
    }

    // MARK: - The floating capsule

    // Measured, not recalled: the owner's MacBook Pro (Mac17,13, 1512 × 993
    // pt @2x, macOS 27.2) on 2026-11-12. `NSScreen` reported
    // `safeAreaInsets.top` 40 and two strips 726.5 pt wide, which is a 59 ×
    // 40 pt box. A phone photo of an on-screen numbered grid, good to half a
    // point, put the glass itself at 58 × 31 pt with fully rounded ends
    // (radius 15.5), centred, 8.5 pt below the top of the screen, its lower
    // edge at 39.5.
    private static let capsuleFrame = CGRect(x: 0, y: 0, width: 1512, height: 993)
    private static let capsuleLeft = CGRect(x: 0, y: 953, width: 726.5, height: 40)
    private static let capsuleRight = CGRect(x: 785.5, y: 953, width: 726.5, height: 40)

    private static func capsuleMac(model: String? = "Mac17,13") -> NotchGeometry {
        NotchGeometry.measure(frame: capsuleFrame, safeAreaTop: 40,
                              left: capsuleLeft, right: capsuleRight, model: model)
    }

    @Test func theCapsuleProAsMeasured() throws {
        let g = Self.capsuleMac()
        // What macOS reports: the box, not the glass.
        #expect(g.size == CGSize(width: 59, height: 40))
        #expect(g.centreX == 756)
        #expect(g.hasNotch)
        // What the photo says is inside it.
        let c = try #require(g.capsule)
        #expect(c.size == CGSize(width: 58, height: 31))
        #expect(c.topGap == 8.5)
        #expect(c.radius == 15.5)
        #expect(c.bottom == 39.5)
        #expect(c.midY == 24)
        #expect(c.measured)
    }

    /// Which kind of cutout it is comes from the reported gap alone: the
    /// capsule's 59 pt against 179, 185 and 220 for the attached notches.
    @Test func attachedNotchesAreNotCapsules() {
        let air = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32,
                                        left: Self.airLeft, right: Self.airRight, model: "Mac15,12")
        #expect(air.cutout == .attached)
        #expect(air.capsule == nil)
        // Even with the capsule Mac's own model string: the gap decides.
        let mislabelled = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 32,
                                                left: Self.airLeft, right: Self.airRight, model: "Mac17,13")
        #expect(mislabelled.cutout == .attached)
        let bare = NotchGeometry.measure(frame: Self.airFrame, safeAreaTop: 0, left: nil, right: nil)
        #expect(bare.cutout == .none)
        #expect(NotchGeometry(size: CGSize(width: 185, height: 32), centreX: 756).cutout == .attached)
        #expect(NotchGeometry(size: .zero, centreX: 756).cutout == .none)
    }

    /// A capsule Mac nobody has photographed: the measured model's
    /// proportions, fitted to the box this one reports — and never outside
    /// that box, which is the one thing macOS does promise.
    @Test func anUnmeasuredCapsuleStaysInsideItsReportedBox() throws {
        let same = try #require(Self.capsuleMac(model: "Mac99,1").capsule)
        #expect(!same.measured)
        #expect(same.size == CGSize(width: 58, height: 31))
        #expect(same.topGap == 8.5)

        for box in [CGSize(width: 59, height: 40), CGSize(width: 50, height: 34),
                    CGSize(width: 78, height: 53), CGSize(width: 40, height: 24),
                    CGSize(width: 99, height: 20)] {
            for model in ["Mac17,13", nil] as [String?] {
                let c = NotchGeometry.capsule(reported: box, model: model)
                #expect(c.topGap >= 0)
                #expect(c.size.width > 0 && c.size.width <= box.width)
                #expect(c.size.height > 0 && c.bottom <= box.height)
                #expect(c.radius <= c.size.height / 2)
            }
        }
    }

    /// "More Space" and "Larger Text" change the points, not the glass: the
    /// box and everything in it move by the same ratio. Half the box is half
    /// the measured capsule.
    @Test func aScaledResolutionScalesTheCapsuleWithItsBox() {
        let half = NotchGeometry.capsule(reported: CGSize(width: 29.5, height: 20), model: "Mac17,13")
        #expect(half.size == CGSize(width: 29, height: 15.5))
        #expect(half.topGap == 4.25)
        // The ratios hold at an arbitrary scale too: 8.5 : 31 : 40.
        let c = NotchGeometry.capsule(reported: CGSize(width: 50, height: 34), model: "Mac17,13")
        #expect(abs(c.topGap / 34 - 8.5 / 40) < 1e-9)
        #expect(abs(c.size.height / 34 - 31.0 / 40) < 1e-9)
        #expect(abs(c.size.width / 50 - 58.0 / 59) < 1e-9)
    }

    /// The laptop to the right of an external monitor: the capsule is where
    /// the laptop is, whichever space the strips come in.
    @Test func aCapsuleLaptopBesideAnExternalDisplay() {
        let frame = Self.capsuleFrame.offsetBy(dx: 1920, dy: 0)
        let global = NotchGeometry.measure(frame: frame, safeAreaTop: 40,
                                           left: Self.capsuleLeft.offsetBy(dx: 1920, dy: 0),
                                           right: Self.capsuleRight.offsetBy(dx: 1920, dy: 0),
                                           model: "Mac17,13")
        let local = NotchGeometry.measure(frame: frame, safeAreaTop: 40,
                                          left: Self.capsuleLeft, right: Self.capsuleRight,
                                          model: "Mac17,13")
        #expect(global.centreX == 2676)
        #expect(local == global)
        #expect(global.capsule?.size == CGSize(width: 58, height: 31))
        // And it is the display the island lives on.
        #expect(NotchGeometry.hostIndex(notched: [false, global.hasNotch]) == 1)
    }

    // MARK: - What is drawn on a capsule (`CapsuleIsland`)

    /// At rest the island is the hardware's own rectangle: 58 × 31 pt, 8.5 pt
    /// down, centred. Nothing is added, and the 8.5 pt above stays lit.
    @Test func atRestTheIslandIsTheCapsuleExactly() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let rest = CapsuleIsland.folded(c, leftReach: 0, rightReach: 0)
        #expect(rest == CGRect(x: -29, y: 8.5, width: 58, height: 31))
    }

    /// With something to show it grows sideways only: the top gap and the
    /// height are the hardware's in every state, and each side grows by what
    /// that side holds, so the camera stays where it is.
    @Test func itGrowsSidewaysOnly() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let grown = CapsuleIsland.folded(c, leftReach: 27, rightReach: 21)
        #expect(grown.minY == 8.5)
        #expect(grown.height == 31)
        #expect(grown.minX == -56)   // 29 of glass, 27 of reach
        #expect(grown.maxX == 50)    // 29 + 21
        #expect(grown.width == 106)  // 58 + 27 + 21
    }

    /// And only so far: 140 pt left of the camera and 260 right of it, so a
    /// long line is cut short rather than laid over the menu bar's contents.
    @Test func itsGrowthIsCapped() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let huge = CapsuleIsland.folded(c, leftReach: 900, rightReach: 900)
        #expect(huge.minX == -169)   // 29 + 140
        #expect(huge.maxX == 289)    // 29 + 260
        // On the measured 1512 pt screen that is x 587 … 1045 of the menu bar.
        #expect(huge.minX + 756 == 587)
        #expect(huge.maxX + 756 == 1045)
        let clamped = CapsuleIsland.reach(left: -3, right: 12)
        #expect(clamped.left == 0 && clamped.right == 12)
    }

    /// Open, it is a card whose top edge is the capsule's — 8.5 pt below the
    /// top of the screen, never touching it — and whose content starts at the
    /// bottom of the reported box, under the capsule's lower edge (39.5).
    @Test func theOpenCardHangsFromTheCapsulesTopEdge() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let card = CapsuleIsland.card(c, bandHeight: 40, content: CGSize(width: 420, height: 193))
        #expect(card.minY == 8.5)
        #expect(card.minY > 0)
        #expect(card == CGRect(x: -210, y: 8.5, width: 420, height: 31.5 + 193))
        // Content begins at 40, which is below the camera.
        #expect(card.maxY - 193 == 40)
        #expect(card.maxY - 193 >= c.bottom)
        #expect(CapsuleIsland.cardRadius == 24)
    }

    /// The resting target is not the 58 pt of glass: at least 120 pt wide,
    /// and all the way up to the top edge of the screen.
    @Test func theRestingTargetIsWiderThanTheCapsuleAndReachesTheTopEdge() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let t = CapsuleIsland.restTarget(c, bandHeight: 40)
        #expect(t.width >= 120)
        #expect(t.width > c.size.width * 2)
        #expect(t.minY == 0)
        #expect(t.maxY == 40)
        #expect(t.midX == 0)
    }

    // MARK: - macOS's own microphone indicator (`NotchGeometry.SystemIndicator`)

    /// The numbers, as measured on the owner's Mac on 2026-11-12: the dot is
    /// 38 pt right of centre and 23 pt down (a screen capture: 794, 23 on a
    /// 1512 pt screen); the pill is about 151 × 39 pt round the camera (the
    /// owner's photograph, scaled by the dot and the island's own "g").
    @Test func theSystemsIndicatorIsWhereItWasPhotographed() throws {
        let c = try #require(Self.capsuleMac().capsule)
        #expect(c.indicator.dot == CGPoint(x: 38, y: 23))
        #expect(c.indicator.dot.x + 756 == 794)
        #expect(c.indicator.pill == CGRect(x: -72, y: 3, width: 152, height: 40))
        // It is round the camera, and far wider than it.
        #expect(c.indicator.pill.contains(CapsuleIsland.hardware(c)))
        #expect(c.indicator.pill.width > c.size.width * 2.5)
        #expect(c.indicator.pill.contains(c.indicator.dot))
    }

    /// What the island cannot be seen in: the camera alone while no
    /// microphone is open, the camera and the system's pill while one is.
    @Test func theOccupiedRectangleGrowsWhenTheMicrophoneIsOpen() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let quiet = CapsuleIsland.occupied(c, indicatorLive: false)
        let live = CapsuleIsland.occupied(c, indicatorLive: true)
        #expect(quiet == CGRect(x: -29, y: 8.5, width: 58, height: 31))
        #expect(live == CGRect(x: -72, y: 3, width: 152, height: 40))
        #expect(live.contains(quiet))
        #expect(live.width > quiet.width + 80)
    }

    /// The photographed defect: "Thinking" was drawn from the camera's edge
    /// and the system's pill covered all of it but the "g". With the
    /// microphone open each side's content is beside the pill, a clear 4 pt
    /// from it, and the black runs unbroken underneath from one to the other.
    @Test func whatTheIslandShowsIsNeverUnderTheSystemsPill() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let occupied = CapsuleIsland.occupied(c, indicatorLive: true)
        // Every pair of reaches the folded states produce, and a long notice.
        for (l, r) in [(27.0, 21.0), (0.0, 67.0), (27.0, 0.0), (125.0, 240.0), (0.0, 22.0)] {
            let f = CapsuleIsland.folded(c, leftReach: l, rightReach: r, indicatorLive: true)
            let s = CapsuleIsland.slots(c, leftReach: l, rightReach: r, indicatorLive: true)
            if let left = s.left {
                #expect(!left.intersects(occupied), "left \(l): \(left)")
                #expect(left.maxX <= occupied.minX - CapsuleIsland.clearance)
                #expect(left.minX == f.minX)
            } else { #expect(l == 0) }
            if let right = s.right {
                #expect(!right.intersects(occupied), "right \(r): \(right)")
                #expect(right.minX >= occupied.maxX + CapsuleIsland.clearance)
                #expect(right.maxX == f.maxX)
            } else { #expect(r == 0) }
            // One shape: the camera's own rows, across the camera.
            #expect(f.minY == 8.5 && f.height == 31)
            #expect(f.contains(CapsuleIsland.hardware(c)))
        }
        // The working state as drawn: ring left, "Thinking" right.
        let f = CapsuleIsland.folded(c, leftReach: 27, rightReach: 67, indicatorLive: true)
        #expect(f.minX == -103)   // 72 of pill, 4 clear, 27 of ring
        #expect(f.maxX == 151)    // 80 of pill, 4 clear, 67 of word
    }

    /// The control for the test above: with no microphone open the content
    /// starts at the camera's edge — inside where the pill would be — which
    /// is the approved drawing, and exactly what the photograph showed
    /// going wrong once the pill was there.
    @Test func withNoMicrophoneOpenTheContentSitsAtTheCamerasEdge() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let s = CapsuleIsland.slots(c, leftReach: 27, rightReach: 67, indicatorLive: false)
        #expect(s.left == CGRect(x: -56, y: 8.5, width: 27, height: 31))
        #expect(s.right == CGRect(x: 29, y: 8.5, width: 67, height: 31))
        #expect(try #require(s.right).intersects(c.indicator.pill))
        // And the default is that one: nothing changes for a caller that
        // does not say.
        #expect(CapsuleIsland.folded(c, leftReach: 27, rightReach: 67)
                == CapsuleIsland.folded(c, leftReach: 27, rightReach: 67, indicatorLive: false))
    }

    /// A side with nothing to hold stays at the camera's edge, microphone or
    /// not: at rest the island is still the hardware's rectangle exactly.
    @Test func atRestTheMicrophoneChangesNothing() throws {
        let c = try #require(Self.capsuleMac().capsule)
        #expect(CapsuleIsland.folded(c, leftReach: 0, rightReach: 0, indicatorLive: true)
                == CGRect(x: -29, y: 8.5, width: 58, height: 31))
        let rightOnly = CapsuleIsland.folded(c, leftReach: 0, rightReach: 22, indicatorLive: true)
        #expect(rightOnly.minX == -29)
        #expect(rightOnly.maxX == 106)   // 80 + 4 + 22
    }

    /// On the right, room given to the pill comes out of the reach, not out
    /// of the menu bar: the limit is x 1045 either way. On the left the
    /// reach is whole, so "Off the record" (125 pt) is never cut short in a
    /// meeting, and the island may run to x 540.
    @Test func theRightLimitDoesNotMoveWhenTheMicrophoneOpens() throws {
        let c = try #require(Self.capsuleMac().capsule)
        let huge = CapsuleIsland.folded(c, leftReach: 900, rightReach: 900, indicatorLive: true)
        #expect(huge.maxX == 289)
        #expect(huge.maxX + 756 == 1045)
        #expect(huge.minX == -216)     // 72 of pill, 4 clear, 140 of reach
        #expect(huge.minX + 756 == 540)
        let r = CapsuleIsland.reach(c, left: 900, right: 900, indicatorLive: true)
        #expect(r.left == 140)
        #expect(r.left >= 125)
        #expect(abs(r.right - (260 - 55)) < 0.001)   // 51 of pill past the camera, 4 clear
        let quiet = CapsuleIsland.reach(c, left: 900, right: 900, indicatorLive: false)
        #expect(quiet.left == 140 && quiet.right == 260)
    }

    /// The open card's top band: the status word left of the camera, the
    /// clock and buttons right of it, both centred on the camera's middle
    /// row and neither under the camera or the pill. The first row of
    /// content (the band's 40 pt, then the panel's 12 of padding) starts
    /// below both.
    @Test func theOpenCardsHeaderGoesRoundTheCamera() throws {
        let c = try #require(Self.capsuleMac().capsule)
        for live in [false, true] {
            let occupied = CapsuleIsland.occupied(c, indicatorLive: live)
            let h = CapsuleIsland.header(c, cardWidth: 420, inset: 14, height: 14, indicatorLive: live)
            #expect(!h.left.intersects(occupied))
            #expect(!h.right.intersects(occupied))
            #expect(h.left.midY == 24 && h.right.midY == 24)   // the camera's middle row
            #expect(h.left.minX == -196)
            #expect(h.right.maxX == 196)
            #expect(h.left.width >= 100 && h.right.width >= 100)
            #expect(40 + Dropdown.Metric.top >= occupied.maxY + 8)
        }
        let live = CapsuleIsland.header(c, cardWidth: 420, inset: 14, height: 14, indicatorLive: true)
        #expect(live.left.maxX == -76)    // 4 clear of the pill's left end
        #expect(live.right.minX == 84)
        let quiet = CapsuleIsland.header(c, cardWidth: 420, inset: 14, height: 14, indicatorLive: false)
        #expect(quiet.left.maxX == -29)
        #expect(quiet.right.minX == 29)
    }

    /// An unmeasured capsule Mac gets the reference indicator in proportion,
    /// and the same promises hold on it.
    @Test func anUnmeasuredCapsuleGetsTheIndicatorInProportion() {
        let c = NotchGeometry.capsule(reported: CGSize(width: 50, height: 34), model: nil)
        #expect(c.indicator.pill.contains(CapsuleIsland.hardware(c)))
        let s = CapsuleIsland.slots(c, leftReach: 27, rightReach: 67, indicatorLive: true)
        #expect(s.left?.intersects(c.indicator.pill) == false)
        #expect(s.right?.intersects(c.indicator.pill) == false)
        // The plain initialiser, used where a capsule is posed by hand.
        let posed = NotchGeometry.CapsuleCutout(topGap: 8.5, size: CGSize(width: 58, height: 31), measured: true)
        #expect(posed.indicator.pill == CGRect(x: -72, y: 3, width: 152, height: 40))
    }

    /// Which box is a capsule's, from its size alone — what the panel's
    /// height arithmetic is handed.
    @Test func aCapsulesBoxIsKnownByItsSize() {
        #expect(NotchGeometry.isCapsule(CGSize(width: 59, height: 40)))
        #expect(!NotchGeometry.isCapsule(CGSize(width: 179, height: 32)))
        #expect(!NotchGeometry.isCapsule(.zero))
        #expect(!NotchGeometry.isCapsule(CGSize(width: 0, height: 25)))
    }
}
