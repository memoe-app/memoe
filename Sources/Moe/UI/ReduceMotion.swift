import AppKit
import SwiftUI

/// Reduce Motion (System Settings › Accessibility › Display).
///
/// Until 2026-11-12 nothing in the app asked. Things that slide — a card
/// leaving the inbox sideways, the next memory question rising into place, a
/// switch's knob — slid for someone who had asked the Mac to stop doing that.
///
/// What is gated is movement. A colour that fades from one state to another
/// is not motion and is left alone; so is anything that *is* the information
/// (a level meter).
enum CalmMotion {
    /// The system's switch, for code that is not a view.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The animation, or none when motion is reduced. With no animation a
    /// transition does not run either: the view is simply there, or gone.
    static func animation(_ animation: Animation, reduced: Bool = CalmMotion.reduced) -> Animation? {
        reduced ? nil : animation
    }

    /// `withAnimation`, unless motion is reduced.
    static func animate<Result>(_ animation: Animation, reduced: Bool = CalmMotion.reduced,
                                _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(CalmMotion.animation(animation, reduced: reduced), body)
    }
}

private struct CalmAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(CalmMotion.animation(animation, reduced: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` for something that moves: off under Reduce Motion.
    func calmAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(CalmAnimation(animation: animation, value: value))
    }
}
