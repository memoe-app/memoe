import CoreGraphics
import Foundation

/// Where the notch is, on whichever Mac this is.
///
/// Every notched Mac reports its cutout the same way — the menu bar's safe
/// area for the height, and the two strips of menu bar either side of it for
/// the width — but the numbers differ by model and by the scaled resolution
/// the person picked: a 13-inch Air measures 179 × 32 pt at its default, a
/// 14-inch Pro is published at 185 × 32, a 16-inch at 220 × 38 at "More
/// Space", and every Mac without one (the M1 Air, the MacBook Neo, an iMac,
/// any external display) reports nothing at all. The island hangs every one
/// of its shapes off this measurement, so it lives here, where each of those
/// machines can be a test instead of a guess.
///
/// Two things this fixes that the inline version did not:
///
///  - **Centring.** The window was centred on the screen, and the notch is
///    centred on the *menu bar strips*. On the 13-inch Air they are 646 and
///    645 pt, so the notch's centre is half a point right of the screen's:
///    enough to leave a hairline of bezel down one side of an open panel.
///  - **Which screen.** The notch was measured on the screen under the
///    cursor while the window lived on the screen it was first built on. With
///    an external display, a reply arriving while the cursor was out there
///    measured *no* notch and drew the panel's first 32 pt up inside the
///    camera housing of the laptop.
public struct NotchGeometry: Equatable, Sendable {
    /// The cutout, in points. Zero width on a Mac without one; the height can
    /// still be non-zero when a display reports a camera inset but no strips,
    /// so content is kept clear of it all the same.
    public let size: CGSize
    /// The cutout's horizontal centre, in global screen coordinates — the
    /// same space as `NSScreen.frame` — or the screen's centre without one.
    public let centreX: CGFloat

    /// What kind of cutout that is. `size` is only the box the menu bar
    /// avoids; on a Mac whose camera floats in a capsule, the hardware is
    /// smaller than the box and does not touch the top of the screen.
    public let cutout: Cutout

    public var hasNotch: Bool { size.width > 0 && size.height > 0 }

    /// The floating capsule, on a Mac that has one.
    public var capsule: CapsuleCutout? {
        if case .capsule(let c) = cutout { return c }
        return nil
    }

    public init(size: CGSize, centreX: CGFloat) {
        self.init(size: size, centreX: centreX,
                  cutout: size.width > 0 && size.height > 0 ? .attached : .none)
    }

    public init(size: CGSize, centreX: CGFloat, cutout: Cutout) {
        self.size = size
        self.centreX = centreX
        self.cutout = cutout
    }

    // MARK: - The floating capsule (2026-11-12)

    /// The three things the top of a Mac's screen can have.
    public enum Cutout: Equatable, Sendable {
        /// Nothing: the MacBook Neo, the M1 Air, an iMac, an external display.
        case none
        /// A notch hanging from the top edge of the screen (2021–2025).
        case attached
        /// A capsule floating in the menu bar, with lit screen above it.
        case capsule(CapsuleCutout)
    }

    /// A floating camera capsule, placed inside the box macOS reports.
    ///
    /// Measured on the owner's MacBook Pro (Mac17,13, 1512 × 993 pt @2x,
    /// macOS 27.2) on 2026-11-12, from a phone photo of an on-screen numbered
    /// grid, good to half a point: the capsule is 58 pt wide and 31 pt tall
    /// with fully rounded ends, horizontally centred, with 8.5 pt of lit
    /// screen above it. macOS reports none of that. It reports the box the
    /// menu bar keeps clear — `safeAreaInsets.top` 40 and two 726.5 pt strips,
    /// so a 59 × 40 pt gap — and windows may draw in the lit pixels round
    /// the capsule.
    public struct CapsuleCutout: Equatable, Sendable {
        /// Lit screen between the top edge and the capsule.
        public let topGap: CGFloat
        /// The capsule itself.
        public let size: CGSize
        /// True when the numbers come from a photo of this very model; false
        /// when they are another model's proportions fitted to this box.
        public let measured: Bool
        /// Where macOS draws its own microphone indicator beside this
        /// capsule (`SystemIndicator`). Pixels the island can never draw over.
        public let indicator: SystemIndicator

        /// `indicator` nil gives the reference model's, fitted to this capsule.
        public init(topGap: CGFloat, size: CGSize, measured: Bool, indicator: SystemIndicator? = nil) {
            self.topGap = topGap
            self.size = size
            self.measured = measured
            self.indicator = indicator ?? {
                let m = NotchGeometry.measuredCapsules[NotchGeometry.referenceCapsuleModel]!
                return m.indicator.scaled(x: size.width / m.size.width, y: size.height / m.size.height)
            }()
        }

        /// Fully rounded ends.
        public var radius: CGFloat { min(size.width, size.height) / 2 }
        public var bottom: CGFloat { topGap + size.height }
        public var midY: CGFloat { topGap + size.height / 2 }
    }

    /// macOS's own microphone indicator on a capsule Mac (found 2026-11-12).
    ///
    /// While any app has the microphone open, macOS 27 keeps an orange dot
    /// just right of the camera. When an app *starts* using the microphone,
    /// and when the pointer is near, it grows into an outlined pill round the
    /// camera with the dot and an orange microphone in its right end. Both
    /// are drawn by the system above every window, this app's included: the
    /// island sits at window level 33, over the menu bar's own windows, and
    /// in the owner's photographs the pill still covered the island's
    /// "Thinking", leaving its last letter showing. So the island cannot
    /// draw there. It keeps what it has to say outside `pill` whenever the
    /// microphone is open, which is exactly when it is listening or thinking.
    ///
    /// x is from the cutout's centre line, y from the top of the screen.
    public struct SystemIndicator: Equatable, Sendable {
        /// The outlined pill at its largest.
        public let pill: CGRect
        /// The resting dot's centre.
        public let dot: CGPoint

        public init(pill: CGRect, dot: CGPoint) {
            self.pill = pill
            self.dot = dot
        }

        func scaled(x sx: CGFloat, y sy: CGFloat) -> SystemIndicator {
            SystemIndicator(pill: CGRect(x: pill.minX * sx, y: pill.minY * sy,
                                         width: pill.width * sx, height: pill.height * sy),
                            dot: CGPoint(x: dot.x * sx, y: dot.y * sy))
        }
    }

    /// One model's capsule as photographed, beside the box macOS reported
    /// for it at the same resolution.
    public struct CapsuleMeasurement: Equatable, Sendable {
        public let reported: CGSize
        public let topGap: CGFloat
        public let size: CGSize
        public let indicator: SystemIndicator
    }

    /// Capsules that have been measured, by `hw.model`. Add a row only from a
    /// photograph of the machine; an invented row draws a step beside the
    /// camera on every Mac of that model.
    public static let measuredCapsules: [String: CapsuleMeasurement] = [
        // The indicator, same day. The dot is exact: a screen capture has it
        // centred 794 pt across and 23 pt down a 1512 pt screen, 38 pt right
        // of centre. The pill is from the owner's photograph (IMG_0627),
        // scaled by two things in it whose positions are known — that dot,
        // and the "g" of the island's own "Thinking" 44.5 pt further right:
        // 151 pt wide and 39 pt tall, from 72 pt left of centre to 79 pt
        // right, centred on the dot's row. Good to about 3 pt, so it is
        // written a point generous and `CapsuleIsland.clearance` is added.
        "Mac17,13": CapsuleMeasurement(reported: CGSize(width: 59, height: 40),
                                       topGap: 8.5, size: CGSize(width: 58, height: 31),
                                       indicator: SystemIndicator(
                                           pill: CGRect(x: -72, y: 3, width: 152, height: 40),
                                           dot: CGPoint(x: 38, y: 23))),
    ]
    /// The proportions an unmeasured capsule Mac is given.
    public static let referenceCapsuleModel = "Mac17,13"

    /// A gap narrower than this is a capsule. The capsule reports 59 pt; the
    /// narrowest attached notch reports 179 pt at its default resolution and
    /// about 150 at the densest scaled one, and the capsule at the largest
    /// text setting comes to under 90. A hundred sits between with room on
    /// both sides.
    public static let capsuleMaximumWidth: CGFloat = 100

    /// Whether a reported box is a floating capsule's, from its size alone.
    public static func isCapsule(_ reported: CGSize) -> Bool {
        reported.width > 0 && reported.height > 0 && reported.width < capsuleMaximumWidth
    }

    /// The capsule inside a reported box.
    ///
    /// The capsule is a fixed piece of glass and the box is in points, so a
    /// scaled resolution ("More Space") changes both by the same ratio: each
    /// measured number is scaled by how the reported box compares with the
    /// one it was measured against. A model nobody has photographed gets the
    /// reference model's proportions. Either way the result is held inside
    /// the reported box, which is the one thing macOS does promise.
    public static func capsule(reported: CGSize, model: String?) -> CapsuleCutout {
        let known = model.flatMap { measuredCapsules[$0] }
        // The reference row is in the table by construction.
        let m = known ?? measuredCapsules[referenceCapsuleModel]!
        let sx = reported.width / m.reported.width
        let sy = reported.height / m.reported.height
        let topGap = min(max(m.topGap * sy, 0), reported.height)
        let width = min(m.size.width * sx, reported.width)
        let height = min(m.size.height * sy, reported.height - topGap)
        return CapsuleCutout(topGap: topGap, size: CGSize(width: width, height: height),
                             measured: known != nil, indicator: m.indicator.scaled(x: sx, y: sy))
    }

    /// The narrowest the resting hover target is ever made. A floating
    /// capsule is 58 pt wide, and a target that small at the top edge of the
    /// screen is one nobody hits. This is the invisible target only: what is
    /// drawn on a capsule Mac is the capsule (`CapsuleIsland`).
    public static let minimumTargetWidth: CGFloat = 120
    /// The target on a Mac with no cutout at all.
    public static let noNotchTargetWidth: CGFloat = 130
    /// What the island draws in place of a notch on a Mac without one: a
    /// small black tab under the middle of the menu bar, the size the halo
    /// and the working light already traced. Without it they traced nothing
    /// — a smudge of light and a loose dash in the menu bar of a MacBook Neo
    /// or an external display.
    public static let virtualNotch = CGSize(width: 120, height: 24)

    /// The resting hover target's width for this machine.
    public var targetWidth: CGFloat { Self.targetWidth(for: size) }

    /// The same, from a cutout's size alone — what `IslandView` is handed.
    public static func targetWidth(for notch: CGSize) -> CGFloat {
        notch.width > 0 && notch.height > 0
            ? max(notch.width, minimumTargetWidth) : noNotchTargetWidth
    }

    /// Measure from what `NSScreen` reports: its `frame`,
    /// `safeAreaInsets.top`, `auxiliaryTopLeftArea` and
    /// `auxiliaryTopRightArea`.
    ///
    /// The two strips are taken in either coordinate space — the screen's own
    /// or the global one — by checking which of them the right-hand strip's
    /// edge agrees with. On the primary display the two are the same and
    /// nothing can tell them apart; on a laptop sitting to the right of an
    /// external monitor, reading them in the wrong space would put the island
    /// a whole screen away from its notch.
    ///
    /// `model` is `hw.model`, used only to look a floating capsule's own
    /// numbers up (`measuredCapsules`); which kind of cutout this is comes
    /// from the reported gap alone.
    public static func measure(frame: CGRect, safeAreaTop: CGFloat,
                               left: CGRect?, right: CGRect?,
                               model: String? = nil) -> NotchGeometry {
        let height = max(safeAreaTop, 0)
        guard let left, let right, left.width > 0, right.width > 0 else {
            return NotchGeometry(size: CGSize(width: 0, height: height), centreX: frame.midX)
        }
        let local = abs(right.maxX - frame.maxX) > 1 && abs(right.maxX - frame.width) <= 1
        let origin = local ? frame.minX : 0
        let gapStart = origin + left.maxX
        let gapEnd = origin + right.minX
        let width = gapEnd - gapStart
        // A cutout wider than half the display is not a cutout; it is two
        // strips that were not describing one. Refuse it rather than draw it.
        guard width > 0, width < frame.width / 2 else {
            return NotchGeometry(size: CGSize(width: 0, height: height), centreX: frame.midX)
        }
        let size = CGSize(width: width, height: height)
        let cutout: Cutout = height <= 0 ? .none
            : isCapsule(size) ? .capsule(capsule(reported: size, model: model))
            : .attached
        return NotchGeometry(size: size, centreX: (gapStart + gapEnd) / 2, cutout: cutout)
    }

    /// Which display the island lives on: the first with a notch, because
    /// that is where Moe lives; otherwise the first display, which is the one
    /// carrying the menu bar.
    ///
    /// Deliberately not "the screen under the cursor". The window is built
    /// once and never follows the pointer, so measuring the screen under it
    /// is what let the notch and the window disagree.
    public static func hostIndex(notched: [Bool]) -> Int {
        notched.firstIndex(of: true) ?? 0
    }
}

/// The island on a Mac whose camera floats in a capsule, as numbers.
///
/// The approved design (2026-11-12, "capsule that grows"): at rest the island
/// is a black capsule exactly over the real one, so nothing extra is drawn
/// and the strip of screen above it stays lit. With something to show, the
/// capsule keeps its top gap, height and rounding and grows sideways only.
/// Open, it grows into a floating rounded card whose top edge is the
/// capsule's top edge, with the camera inside its top band and the content
/// beginning below the capsule. Nothing here touches the top of the screen.
///
/// Everything is measured from the cutout's centre line (x) and the top of
/// the screen (y), in points.
public enum CapsuleIsland {
    public typealias Capsule = NotchGeometry.CapsuleCutout

    /// The open card's corner radius.
    public static let cardRadius: CGFloat = 24

    /// How far the capsule may grow past the camera on each side before it
    /// starts covering what the menu bar holds. On the measured 1512 pt
    /// screen the strips are 726.5 pt each: 140 on the left stops at x 587,
    /// past the eighth or ninth menu of most apps, and holds the longest
    /// left indicator ("Off the record", 125 pt); 260 on the right holds a
    /// 34-character notice and stops at x 1045. Longer text is cut with an
    /// ellipsis, never the menu bar.
    public static let maximumLeftReach: CGFloat = 140
    public static let maximumRightReach: CGFloat = 260

    public static func reach(left: CGFloat, right: CGFloat) -> (left: CGFloat, right: CGFloat) {
        (min(max(left, 0), maximumLeftReach), min(max(right, 0), maximumRightReach))
    }

    /// Clear space kept between the system's indicator and anything the
    /// island draws beside it: the pill's outline is a photograph's estimate.
    public static let clearance: CGFloat = 4

    /// The camera's own rectangle.
    public static func hardware(_ c: Capsule) -> CGRect {
        CGRect(x: -c.size.width / 2, y: c.topGap, width: c.size.width, height: c.size.height)
    }

    /// What the island can never be seen in: the camera, and — while the
    /// microphone is open — the pill macOS may draw round it at any moment
    /// (`NotchGeometry.SystemIndicator`).
    public static func occupied(_ c: Capsule, indicatorLive: Bool) -> CGRect {
        indicatorLive ? hardware(c).union(c.indicator.pill) : hardware(c)
    }

    /// Where each side's content starts: the camera's edge, or past the
    /// system's pill and `clearance` while the microphone is open.
    public static func inner(_ c: Capsule, indicatorLive: Bool) -> (left: CGFloat, right: CGFloat) {
        let h = hardware(c)
        guard indicatorLive else { return (h.minX, h.maxX) }
        let o = occupied(c, indicatorLive: true)
        return (min(h.minX, o.minX - clearance), max(h.maxX, o.maxX + clearance))
    }

    /// `reach(left:right:)` beside the system's pill. On the right the
    /// island's outer limit stays where it was (x 1045 on the measured
    /// screen, short of the status items): room given to the pill comes out
    /// of the reach, and a long notice ends in "…" sooner. On the left the
    /// reach is kept whole, because the longest thing shown there — "Off the
    /// record", 125 pt — is shown during a meeting, when the microphone is
    /// always open; the island then runs to x 540, the ninth or tenth menu.
    public static func reach(_ c: Capsule, left: CGFloat, right: CGFloat,
                             indicatorLive: Bool) -> (left: CGFloat, right: CGFloat) {
        let h = hardware(c)
        let i = inner(c, indicatorLive: indicatorLive)
        return (min(max(left, 0), maximumLeftReach),
                min(max(right, 0), max(maximumRightReach - (i.right - h.maxX), 0)))
    }

    /// The folded capsule: the hardware's own rectangle, grown sideways by
    /// what each side has to hold. With nothing to hold it is the hardware's
    /// rectangle exactly. While the microphone is open a side with something
    /// to hold first grows past the system's pill, so the black runs
    /// unbroken under the pill and what it holds is beside the pill, not
    /// behind it; a side with nothing to hold stays at the camera's edge.
    public static func folded(_ c: Capsule, leftReach: CGFloat, rightReach: CGFloat,
                              indicatorLive: Bool = false) -> CGRect {
        let h = hardware(c)
        let r = reach(c, left: leftReach, right: rightReach, indicatorLive: indicatorLive)
        let i = inner(c, indicatorLive: indicatorLive)
        let minX = r.left > 0 ? i.left - r.left : h.minX
        let maxX = r.right > 0 ? i.right + r.right : h.maxX
        return CGRect(x: minX, y: c.topGap, width: maxX - minX, height: c.size.height)
    }

    /// Where each side's content is drawn inside `folded`: the outer
    /// `reach` points of it. Nil for a side with nothing to hold.
    public static func slots(_ c: Capsule, leftReach: CGFloat, rightReach: CGFloat,
                             indicatorLive: Bool = false) -> (left: CGRect?, right: CGRect?) {
        let r = reach(c, left: leftReach, right: rightReach, indicatorLive: indicatorLive)
        let f = folded(c, leftReach: leftReach, rightReach: rightReach, indicatorLive: indicatorLive)
        return (r.left > 0 ? CGRect(x: f.minX, y: f.minY, width: r.left, height: f.height) : nil,
                r.right > 0 ? CGRect(x: f.maxX - r.right, y: f.minY, width: r.right, height: f.height) : nil)
    }

    /// The open card's top band, either side of the camera: where the status
    /// word (left) and the clock and buttons (right) go, centred on the
    /// camera's own middle. Neither reaches under the camera or the
    /// system's pill. `inset` is the card's side padding.
    public static func header(_ c: Capsule, cardWidth: CGFloat, inset: CGFloat, height: CGFloat,
                              indicatorLive: Bool) -> (left: CGRect, right: CGRect) {
        let i = inner(c, indicatorLive: indicatorLive)
        let y = c.midY - height / 2
        let l = -cardWidth / 2 + inset
        let r = cardWidth / 2 - inset
        return (CGRect(x: l, y: y, width: max(i.left - l, 0), height: height),
                CGRect(x: i.right, y: y, width: max(r - i.right, 0), height: height))
    }

    /// The open card. Its top edge is the capsule's; its content starts at
    /// the bottom of the box macOS reports (`bandHeight`), which is at or
    /// just under the capsule's lower edge.
    public static func card(_ c: Capsule, bandHeight: CGFloat, content: CGSize) -> CGRect {
        CGRect(x: -content.width / 2, y: c.topGap,
               width: content.width, height: max(bandHeight - c.topGap, 0) + content.height)
    }

    /// The resting hover and click target: wider than the capsule, and up to
    /// the very top of the screen, where a pointer thrown at the edge lands.
    public static func restTarget(_ c: Capsule, bandHeight: CGFloat) -> CGRect {
        let w = max(c.size.width, NotchGeometry.minimumTargetWidth)
        return CGRect(x: -w / 2, y: 0, width: w, height: max(bandHeight, c.bottom))
    }
}
