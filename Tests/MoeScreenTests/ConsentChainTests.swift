import CoreGraphics
import Foundation
import Testing
@testable import MoeScreen

/// Where a consent control is, for the hit-test (D9.14). Every number here
/// is a MEASUREMENT (2026-11-12, macOS 27.2): the 480-pt consent sheet hosted
/// the way `ReacceptPrompt` hosts it — `NSWindow(contentViewController:)`,
/// `[.titled, .closable]` — with a 60×24 Agree at the bottom right.
///
///     window.frame 480×170 · contentView.bounds 480×138 (a 32-pt title bar)
///     SwiftUI .global frame of the button   (396, 122, 60, 24)   y down, from the WINDOW's top
///     AppKit rect of a view behind it       (396,  24, 60, 24)   y up, window coordinates
@Suite("ControlPlace")
struct ControlPlaceTests {
    static let window = 4242
    /// What the fix records: `probe.convert(probe.bounds, to: nil)`.
    static let agree = ControlPlace(windowNumber: window,
                                    rectInWindow: CGRect(x: 396, y: 24, width: 60, height: 24))
    /// A person's mouse-up in the middle of Agree, as `locationInWindow`.
    static let click = CGPoint(x: 426, y: 36)

    static func facts(inside: Bool, pid: Int64 = 0) -> HumanEventRule.Facts {
        .init(kind: .mouseUp, sourcePID: pid, age: 0.01, liveAndUnused: true,
              insideControl: inside, activatesControl: false)
    }

    @Test func aRealClickOnAgreeInTheTitledWindowIsAPerson() {
        let inside = HumanEventRule.insideControl(click: Self.click, eventWindow: Self.window, place: Self.agree)
        #expect(inside)
        #expect(HumanEventRule.classify(Self.facts(inside: inside)) == .person)
    }

    /// The defect, kept as arithmetic so it cannot come back unnoticed: the
    /// old hit-test compared SwiftUI's `.global` frame with the click flipped
    /// by the content view's height. Same click, same button: outside.
    @Test func theOldGlobalFrameArithmeticPutThatSameClickOutside() {
        let global = CGRect(x: 396, y: 122, width: 60, height: 24)
        let contentHeight: CGFloat = 138
        let flipped = CGPoint(x: Self.click.x, y: contentHeight - Self.click.y)
        #expect(!global.contains(flipped))
        // …and not by a little: no point of the button could pass, because
        // the title bar (32) is taller than the button (24).
        for y in stride(from: Self.agree.rectInWindow.minY, through: Self.agree.rectInWindow.maxY, by: 1) {
            #expect(!global.contains(CGPoint(x: Self.click.x, y: contentHeight - y)))
        }
        #expect(HumanEventRule.classify(Self.facts(inside: false)) == .outsideControl)
    }

    @Test func aClickBesideTheButtonIsStillOutside() {
        for miss in [CGPoint(x: 395, y: 36), CGPoint(x: 457, y: 36), CGPoint(x: 426, y: 23), CGPoint(x: 426, y: 49),
                     CGPoint(x: 240, y: 150)] {
            let inside = HumanEventRule.insideControl(click: miss, eventWindow: Self.window, place: Self.agree)
            #expect(!inside, "\(miss)")
            #expect(HumanEventRule.classify(Self.facts(inside: inside)) == .outsideControl)
        }
    }

    /// The same point of ANOTHER window is not a click on this control.
    @Test func theSamePointOfAnotherWindowIsOutside() {
        #expect(!HumanEventRule.insideControl(click: Self.click, eventWindow: 7, place: Self.agree))
    }

    @Test func aControlWithNoPlaceIsNeverInside() {
        #expect(!HumanEventRule.insideControl(click: Self.click, eventWindow: Self.window, place: nil))
        let empty = ControlPlace(windowNumber: Self.window, rectInWindow: .zero)
        #expect(!HumanEventRule.insideControl(click: .zero, eventWindow: Self.window, place: empty))
    }

    /// A synthetic click dead centre of the button, in the right window: the
    /// place is right and it is still not a person (cua-driver's pixel click,
    /// measured 2026-09-11, pid 95219).
    @Test func aSyntheticClickInsideTheButtonStillFails() {
        let inside = HumanEventRule.insideControl(click: Self.click, eventWindow: Self.window, place: Self.agree)
        #expect(inside)
        let verdict = HumanEventRule.classify(Self.facts(inside: inside, pid: 95219))
        #expect(verdict == .posted(pid: 95219))
        #expect(HumanGate.proof(verdict) == nil)
    }
}

/// One verified press, and exactly the steps that follow from it.
@Suite("ConsentChain")
struct ConsentChainTests {
    static func proof() -> PersonProof { HumanGate.proof(.person)! }
    static func chain(_ origin: String = "keep-a-copy-agree", at now: TimeInterval = 1000) -> ConsentChain {
        ConsentChain(proof(), origin: origin, now: now)
    }

    // MARK: who can open one

    @Test func onlyAPersonsPressOrAPassedAuthenticationIsProof() async {
        #expect(HumanGate.proof(.person) != nil)
        let notPeople: [HumanEventRule.Verdict] = [.noEvent, .notInput("other"), .posted(pid: 51715), .stale(9),
                                                   .notLive, .outsideControl, .notActivating]
        for verdict in notPeople {
            #expect(HumanGate.proof(verdict) == nil, "\(verdict)")
            // An accessibility press (no event) still has to authenticate…
            #expect(await HumanGate.prove(verdict, reason: "r", authenticator: DenyingAuthenticator()) == nil)
        }
        // …and a VoiceOver user who does is proof.
        #expect(await HumanGate.prove(.noEvent, reason: "r", authenticator: AllowingAuthenticator()) != nil)
    }

    @Test func aPersonsPressIsNotAskedToAuthenticate() async {
        struct Trap: PersonAuthenticator { func confirmPerson(reason: String) async -> Bool {
            Issue.record("authenticator consulted for a person's press"); return false } }
        #expect(await HumanGate.prove(.person, reason: "r", authenticator: Trap()) != nil)
    }

    // MARK: what it covers

    @Test func itCoversExactlyItsChainAndEachStepOnce() {
        let chain = Self.chain()
        #expect(chain.covers(ConsentChain.keySignIn, now: 1002))
        #expect(!chain.covers(ConsentChain.keySignIn, now: 1003), "single-use")
        #expect(chain.covers(ConsentChain.keepACopyTurnOn, now: 1004))
        #expect(!chain.covers(ConsentChain.keepACopyTurnOn, now: 1005), "single-use")
        #expect(!chain.covers(ConsentChain.keySignIn, now: 1006))
    }

    @Test func itCannotAuthoriseAnyOtherControl() {
        let chain = Self.chain()
        for control in ["keep-a-copy-agree", "upgrade-agree", "reaccept-agree", "away-keep-a-copy",
                        "privacy-problem-reports", "privacy-cloud-copy", "danger-delete", "", "*"] {
            #expect(!chain.covers(control, now: 1001), "\(control)")
        }
        // Asking for the wrong thing spent nothing.
        #expect(chain.covers(ConsentChain.keySignIn, now: 1001))
    }

    /// The turn-on follows from the keep-a-copy Agree and from no other.
    @Test func anAgreeThatWasNotForTheCopyDoesNotTurnItOn() {
        for origin in ["upgrade-agree", "reaccept-agree", "privacy-problem-reports"] {
            let chain = Self.chain(origin)
            #expect(!chain.covers(ConsentChain.keepACopyTurnOn, now: 1001), "\(origin)")
            #expect(chain.covers(ConsentChain.keySignIn, now: 1001), "\(origin)")
        }
    }

    @Test func aControlThatLeadsNowhereOpensAChainThatCoversNothing() {
        for origin in ["away-keep-a-copy", "privacy-cloud-copy", "danger-delete", "consent-key-sign-in", "harness-agree"] {
            #expect(ConsentChain.consequences(of: origin).isEmpty, "\(origin)")
            let chain = Self.chain(origin)
            #expect(!chain.covers(ConsentChain.keySignIn, now: 1000))
            #expect(!chain.covers(ConsentChain.keepACopyTurnOn, now: 1000))
        }
    }

    // MARK: how long

    @Test func itExpires() {
        let fresh = Self.chain()
        #expect(fresh.covers(ConsentChain.keySignIn, now: 1000 + ConsentChain.window))   // inclusive
        let late = Self.chain()
        #expect(!late.covers(ConsentChain.keySignIn, now: 1000 + ConsentChain.window + 0.01))
        // Expired is expired: a step asked for late does not leave the rest alive.
        #expect(!late.covers(ConsentChain.keepACopyTurnOn, now: 1001))
        // A clock that ran backwards is not "fresh".
        #expect(!Self.chain().covers(ConsentChain.keySignIn, now: 999))
        #expect(ConsentChain.window <= 60, "seconds, not minutes")
    }

    /// The Google sign-in can take a minute. What follows is counted from the
    /// person coming back — but only for a step this chain covered, only
    /// once, and never past the ceiling.
    @Test func theSignInItCoveredRenewsItOnceAndNothingElseDoes() {
        let chain = Self.chain()
        #expect(chain.covers(ConsentChain.keySignIn, now: 1002))
        chain.finished(ConsentChain.keySignIn, now: 1090)           // 88 s in the browser
        #expect(chain.covers(ConsentChain.keepACopyTurnOn, now: 1095))

        // Without the covered sign-in, the same wait has run it out.
        let idle = Self.chain()
        idle.finished(ConsentChain.keySignIn, now: 1090)            // never covered: renews nothing
        #expect(!idle.covers(ConsentChain.keepACopyTurnOn, now: 1095))

        // A second "finished" for the same step renews nothing more.
        let twice = Self.chain()
        #expect(twice.covers(ConsentChain.keySignIn, now: 1002))
        twice.finished(ConsentChain.keySignIn, now: 1020)
        twice.finished(ConsentChain.keySignIn, now: 1200)
        #expect(!twice.covers(ConsentChain.keepACopyTurnOn, now: 1205))

        // And nothing outlives the ceiling.
        let old = Self.chain()
        #expect(old.covers(ConsentChain.keySignIn, now: 1002))
        old.finished(ConsentChain.keySignIn, now: 1000 + ConsentChain.ceiling + 1)
        #expect(!old.covers(ConsentChain.keepACopyTurnOn, now: 1000 + ConsentChain.ceiling + 2))
    }

    // MARK: where it lives

    /// Bound for the press's own action and the work that action starts;
    /// absent everywhere else.
    @Test func itIsReachableOnlyFromTheWorkThePressStarted() async {
        #expect(ConsentChain.current == nil)
        let chain = Self.chain()
        var started: Task<Bool, Never>?
        // The control's action is synchronous and starts a Task, as every
        // consent action in the app does.
        ConsentChain.$current.withValue(chain) {
            #expect(ConsentChain.current === chain)
            started = Task { await Self.hop(); return ConsentChain.current === chain }
        }
        #expect(await started!.value, "the Task the action started carries the chain")
        // After the action returns, and on any other task: nothing.
        #expect(ConsentChain.current == nil)
        #expect(await Task.detached { ConsentChain.current == nil }.value)
        #expect(await Task { ConsentChain.current == nil }.value)
    }

    private static func hop() async { await Task.yield() }
}
