import Foundation

/// Did a person make the event that is triggering this control? (D9.14)
///
/// The rule, in the terms the event itself carries — never a list of tools
/// that might have sent it (CLAUDE.md: a guard that enumerates names is
/// walked past by a new name). Measured 2026-09-11 on an M3, macOS 26.5.2,
/// against a standalone SwiftUI harness, reading `NSApp.currentEvent` inside
/// the Button/Toggle action:
///
/// (The person rows: the owner's own clicks on the harness window,
/// 2026-09-11 09:12:13–19Z, five pairs, age 2–18 ms; and 316 keyDowns and
/// every trackpad mouse-down seen by a listen-only tap over 150 s — all
/// `sourcePID` 0, user 0. Every synthetic row below carried user 501.)
///
/// | route                                      | currentEvent | sourcePID | user | age |
/// |--------------------------------------------|--------------|-----------|------|-----|
/// | a person's click (trackpad), a person's key| mouse/key    | **0**     | 0    | ms  |
/// | AXPress (`AXUIElementPerformAction`)       | **nil**      | —         | —    | —   |
/// | cua-driver `click` by element (AX path)    | **nil**      | —         | —    | —   |
/// | another process's `postToPid` Return — it FIRED a default button | keyDown | **poster's pid** | 501 | ms |
/// | cua-driver `click` by pixel (CGEvent path) | mouse        | **cua's pid** | 501 | **timestamp 0** |
///
/// `sourceStateID` is 1 (HID system state) for *all* of them, so it cannot
/// tell a person from a poster, and is not used. What separates them:
///
/// 1. **the source process** — a synthetic event is stamped with the posting
///    process's pid; a hardware event carries 0. An accessibility press has
///    no event at all.
/// 2. **liveness** — `NSApp.currentEvent` is process-global and an AX press
///    does not clear it, so a person's click *elsewhere* can still be the
///    current event when the agent presses this control a second later. So a
///    live person-event monitor must have seen *this exact* event as a
///    person's (pid 0), and it must not already have authorised an action
///    (`liveAndUnused`). This is what stops a lingering event riding a press.
/// 3. **delivery to THIS control** — a mouse-up must land inside the control
///    (`insideControl`); a key must be Return/Space with the control's window
///    key and the control the active one (`activatesControl`). A person who
///    clicked elsewhere fails this even if 1 and 2 somehow held.
///
/// When the verdict is not `.person`, the caller does not simply refuse: it
/// asks for the person with LocalAuthentication (`HumanGate`), so VoiceOver,
/// Voice Control and Switch users — whose presses are accessibility presses —
/// can still agree, while the agent, which cannot pass Touch ID or the login
/// password, cannot.
public enum HumanEventRule {

    /// What the app could read about the triggering event.
    public struct Facts: Equatable, Sendable {
        public enum Kind: String, Sendable { case mouseDown, mouseUp, keyDown, keyUp, other }
        public var kind: Kind
        /// `CGEventField.eventSourceUnixProcessID`. 0 for hardware, and -1
        /// stands in for an input event with no CGEvent (also not a person).
        public var sourcePID: Int64
        /// Seconds between the event's timestamp and now (system uptime).
        public var age: TimeInterval
        /// A live monitor saw THIS event as a person's (pid 0) and it has
        /// not authorised an action before.
        public var liveAndUnused: Bool
        /// mouseUp: the event's location is inside this control. (Ignored
        /// for keys.)
        public var insideControl: Bool
        /// keyDown: it is Return or Space, the control's window is key, and
        /// the control is the active one. (Ignored for mouse.)
        public var activatesControl: Bool
        public init(kind: Kind, sourcePID: Int64, age: TimeInterval,
                    liveAndUnused: Bool, insideControl: Bool, activatesControl: Bool) {
            self.kind = kind; self.sourcePID = sourcePID; self.age = age
            self.liveAndUnused = liveAndUnused
            self.insideControl = insideControl; self.activatesControl = activatesControl
        }
    }

    public enum Verdict: Equatable, Sendable {
        case person
        /// No event: an accessibility press, or code calling the action.
        case noEvent
        /// Not the mouse-up or key-down an action fires on.
        case notInput(String)
        /// Stamped with a posting process: synthetic.
        case posted(pid: Int64)
        /// Older than any press it could have caused, or dated in the future.
        case stale(TimeInterval)
        /// Not the live, unused person event this dispatch should carry — a
        /// lingering `currentEvent`, or one already used.
        case notLive
        /// A mouse-up outside this control (a click elsewhere).
        case outsideControl
        /// A key that does not activate this control.
        case notActivating

        public var isPerson: Bool { self == .person }

        /// One line for the log. Never shown to the person.
        public var reason: String {
            switch self {
            case .person: return "person"
            case .noEvent: return "no triggering event (accessibility press or programmatic)"
            case .notInput(let k): return "triggering event is not a mouse-up or key-down (\(k))"
            case .posted(let pid): return "synthetic event posted by pid \(pid)"
            case .stale(let age): return String(format: "triggering event is %.2f s old", age)
            case .notLive: return "not the live, unused person event for this press (a lingering or reused event)"
            case .outsideControl: return "the click was not inside this control"
            case .notActivating: return "the key does not activate this control"
            }
        }
    }

    /// Longest a press may take between the event and the action running. A
    /// real click's action runs within milliseconds of its mouse-up; 0.5 s is
    /// generous and still far shorter than a person could notice a lingering
    /// event surviving.
    public static let maxAge: TimeInterval = 0.5
    /// A little slack for clock jitter; anything more in the future is not a
    /// press that just happened.
    public static let ageFloor: TimeInterval = -0.05

    public static func classify(_ facts: Facts?) -> Verdict {
        guard let f = facts else { return .noEvent }
        switch f.kind {
        case .mouseUp, .keyDown: break
        default: return .notInput(f.kind.rawValue)
        }
        guard f.sourcePID == 0 else { return .posted(pid: f.sourcePID) }
        guard f.age >= ageFloor, f.age <= maxAge else { return .stale(f.age) }
        guard f.liveAndUnused else { return .notLive }
        switch f.kind {
        case .mouseUp: return f.insideControl ? .person : .outsideControl
        case .keyDown: return f.activatesControl ? .person : .notActivating
        default: return .notInput(f.kind.rawValue)
        }
    }
}

// MARK: - Where the control is, for the hit-test

/// A control's place, as AppKit itself reports it: the window it is in, and
/// its rectangle in that window's own coordinates (bottom-left origin, y up)
/// — `view.convert(view.bounds, to: nil)` on a view laid out behind the
/// control, read at the moment of the press. A mouse-up's
/// `NSEvent.locationInWindow` is in the same coordinates, so nothing is
/// flipped and nothing depends on a title bar, a toolbar, the camera cutout
/// or the backing scale.
///
/// **Why not SwiftUI's `.global` frame, which this used to be** (measured
/// 2026-11-12, macOS 27.2, a 480-pt-wide SwiftUI sheet hosted the way
/// `ReacceptPrompt` hosts it, the Agree button 60×24 at the bottom right):
///
/// | window                         | window h | content h | `.global` y | y flipped by content h |
/// |--------------------------------|----------|-----------|-------------|------------------------|
/// | `[.titled, .closable]`         | 170      | 138       | **122**     | **90**                 |
/// | `[.borderless]`                | 138      | 138       | 90          | 90                     |
/// | `[.titled, .fullSizeContentView]` | 138   | 138       | 106         | 106                    |
///
/// `.global` is measured from the top of the WINDOW, title bar included; the
/// old hit-test flipped the click by the CONTENT view's height. In a plain
/// titled window the two differ by the title bar (32 pt), which is taller
/// than the button (24 pt) — so no click a person could make on the re-accept
/// window's Agree was ever "inside" it, and every one fell to Touch ID. The
/// Settings, Onboarding and main windows are full-size-content and matched by
/// luck. AppKit's own numbers need no luck: the probe row above reads
/// (396, 24, 60, 24) in all three.
public struct ControlPlace: Equatable, Sendable {
    /// `NSWindow.windowNumber` of the window the control is in.
    public var windowNumber: Int
    /// The control's rectangle in that window's coordinates (y up).
    public var rectInWindow: CGRect
    public init(windowNumber: Int, rectInWindow: CGRect) {
        self.windowNumber = windowNumber; self.rectInWindow = rectInWindow
    }

    /// A mouse-up at `locationInWindow` (the event's own field), delivered to
    /// window `eventWindow`, landed on this control. A click at the same
    /// point of a DIFFERENT window did not.
    public func contains(click locationInWindow: CGPoint, eventWindow: Int) -> Bool {
        eventWindow == windowNumber && !rectInWindow.isEmpty && rectInWindow.contains(locationInWindow)
    }
}

extension HumanEventRule {
    /// `Facts.insideControl`, from what the press recorded. No place (the
    /// control is not in a window, or was given no probe) is never inside.
    public static func insideControl(click locationInWindow: CGPoint, eventWindow: Int,
                                     place: ControlPlace?) -> Bool {
        place?.contains(click: locationInWindow, eventWindow: eventWindow) ?? false
    }
}

// MARK: - The accessibility fallback (D9.14)

/// Proves the person is there when the triggering event did not (VoiceOver,
/// Voice Control, Switch Control — their presses are accessibility presses,
/// which carry no event). The real one is Touch ID / the login password via
/// LocalAuthentication; tests inject a stub so nothing prompts.
public protocol PersonAuthenticator: Sendable {
    /// `true` if the person authenticated. Never throws — a cancel or a
    /// missing biometric is just `false`.
    func confirmPerson(reason: String) async -> Bool
}

/// Person's press → run. Otherwise ask the person to authenticate, and run
/// only if they do. The agent cannot pass either gate.
public enum HumanGate {
    public static func allow(_ verdict: HumanEventRule.Verdict,
                             reason: String,
                             authenticator: PersonAuthenticator) async -> Bool {
        await prove(verdict, reason: reason, authenticator: authenticator) != nil
    }

    /// The proof a person's press carries, or nil. Never asks anybody.
    public static func proof(_ verdict: HumanEventRule.Verdict) -> PersonProof? {
        verdict.isPerson ? PersonProof() : nil
    }

    /// `allow`, returning what was proved: a person's press, or — for a
    /// press that was not provably one — the person authenticating.
    public static func prove(_ verdict: HumanEventRule.Verdict,
                             reason: String,
                             authenticator: PersonAuthenticator) async -> PersonProof? {
        if let proof = proof(verdict) { return proof }
        return await authenticator.confirmPerson(reason: reason) ? PersonProof() : nil
    }
}

/// That a person was just there: a `.person` verdict, or a passed
/// authentication. It can only be made in this file, by `HumanGate`, and it
/// carries nothing — it is not a credential and cannot be written down, sent
/// or parsed. Its one use is to open a `ConsentChain`.
public struct PersonProof: Sendable {
    fileprivate init() {}
}

// MARK: - One press, and what follows from it (D9.14)

/// One verified press on a consent control, standing in for the steps that
/// are **consequences of that same act** — and for nothing else.
///
/// The owner, 2026-11-12, Settings › Away → Turn it back on: press, Touch ID,
/// Agree, Touch ID, Google, Touch ID, press again, Touch ID. Two of those four
/// prompts were this rule failing to recognise his own clicks (`ControlPlace`
/// above). The other two were steps the APP took because he pressed Agree —
/// registering this Mac's key at a Google sign-in, and then doing the thing
/// he had pressed for — each of which asked "is a person pressing this?" of
/// an event that could not exist, because no press starts them.
///
/// So the press that was verified is carried forward, narrowly:
///
/// - **Made only from a `PersonProof`** — a `.person` verdict or a passed
///   authentication (`HumanGate`). No initialiser takes a string, a file, a
///   flag or a date. (This is a boundary against what drives the app from
///   outside. Code compiled into the app can construct a verdict, as it could
///   always have called the action directly; that is what review is for.)
/// - **Held in memory, on the task the press started** (`ConsentChain.current`
///   is a task-local, bound for the duration of the control's own action).
///   There is no table to look one up in, nothing on disk, no CLI verb, URL
///   scheme, tool or notification that reads or sets it. A different press,
///   a timer, a launch check and an agent-driven action each run on a task
///   that has none.
/// - **Single-purpose**: a chain covers the steps `consequences(of:)` lists
///   for the control that was pressed, and no other control. That table is
///   code, not a parameter.
/// - **Single-use**: each step is covered once. A second request for the
///   same step is refused and takes the ordinary route (authenticate).
/// - **Short-lived**: a step must begin within `window` seconds of the last
///   moment this chain knew the person was there — the press, or the return
///   of the Google sign-in it covered — and never later than `ceiling` after
///   the press. Expired, it covers nothing.
///
/// **What an agent driving the UI can and cannot do after this.** It still
/// cannot press Agree, the switches, or Turn it back on: an accessibility
/// press has no event, a posted event carries the poster's pid, and both get
/// the authentication sheet, which it cannot pass — `HumanEventRule.classify`
/// is unchanged. So it cannot open a chain. It cannot borrow one: a chain is
/// reachable only from code running inside the action of the press that made
/// it, and an agent's press of any OTHER control starts a new action with no
/// chain. If it presses a consent control in the seconds after the person
/// pressed one, its press is judged on its own (no event → authenticate); the
/// person's chain is not consulted, because the question "was this control
/// pressed by a person" is never answered by a chain — only "may this step,
/// which follows from a press already verified, go ahead". What it CAN still
/// do is what it always could: drive the browser the Google sign-in opens.
/// That sign-in is not what makes an agreement the person's — the verified
/// press is — and it opens only inside a chain a person started.
public final class ConsentChain: @unchecked Sendable {

    /// The chain the current task is running inside, if a person's press on
    /// a consent control started it.
    @TaskLocal public static var current: ConsentChain?

    /// The step every Agree may lead to: the Google sign-in that registers
    /// this Mac's key for agreeing, when the edge has none.
    public static let keySignIn = "consent-key-sign-in"
    /// The step the keep-a-copy sheet's Agree leads to: turning the copy on,
    /// which is what the person pressed for before the sheet appeared.
    public static let keepACopyTurnOn = "keep-a-copy-turn-on"

    /// The step a press of a "Sign in with Google" button leads to: signing
    /// in, and recording that the person agreed by doing it (D9.4 — the line
    /// under every such button says so). Asked for BEFORE the browser opens,
    /// so the answer is about the press and not about whatever drove Google.
    public static let signInAcceptance = "sign-in-acceptance"
    /// The step a press of the problem-reports switch leads to: a signed note
    /// in `privacy.json` that this yes was a person's, which is the only
    /// thing launch may later record again on an account that lacks it
    /// (`ProblemReports.reconcile`).
    public static let problemReportsYes = "problem-reports-yes"

    /// What may follow from a press of `origin` without asking the person
    /// again. Anything not listed here asks.
    public static func consequences(of origin: String) -> Set<String> {
        switch origin {
        case "keep-a-copy-agree": return [keySignIn, keepACopyTurnOn]
        case "upgrade-agree", "reaccept-agree": return [keySignIn]
        // The problem-reports switch records an acceptance too, and can meet
        // a Mac whose key is not on record.
        //
        // All three controls that make that one call, not just the first.
        // The welcome's switch and "Confirm it's you" under the Settings
        // switch reach the same `ProblemReports.turn`, and were left out: the
        // press was verified, carried all the way to the sign-in, and then
        // covered nothing — so the person who had just clicked was asked for
        // Touch ID anyway.
        case "privacy-problem-reports", "privacy-problem-reports-confirm",
             "onboarding-problem-reports":
            return [keySignIn, problemReportsYes]
        // The three buttons that sign this Mac in to a Memoe account: the
        // Away page's "Sign in", a plan's "Get …" on a Mac with no account,
        // and a brokered connection's first Connect.
        case "away-sign-in", "plan-sign-in", "connect-sign-in":
            return [signInAcceptance]
        default: return []
        }
    }

    /// Seconds a step may begin after the person was last known to be there.
    public static let window: TimeInterval = 30
    /// Seconds after the press beyond which the chain covers nothing,
    /// whatever happened in between (a sign-in left open in the browser).
    public static let ceiling: TimeInterval = 600

    /// The control the person pressed.
    public let origin: String
    private let lock = NSLock()
    private let born: TimeInterval
    private var anchor: TimeInterval
    private var remaining: Set<String>
    private var renewable: Set<String> = []

    public init(_ proof: PersonProof, origin: String,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.origin = origin
        self.born = now
        self.anchor = now
        self.remaining = Self.consequences(of: origin)
    }

    /// May `step` go ahead on the strength of this chain's press? Yes once,
    /// for a step this chain's control leads to, while it is fresh. Asking
    /// uses it up.
    public func covers(_ step: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining.contains(step) else { return false }
        guard now >= anchor, now - anchor <= Self.window, now - born <= Self.ceiling else {
            // Expired: nothing later may ride on it either.
            remaining.removeAll(); renewable.removeAll()
            return false
        }
        remaining.remove(step)
        renewable.insert(step)
        return true
    }

    /// A step this chain covered has just finished with the person plainly
    /// there (they came back from the Google sign-in): the next step's
    /// `window` is counted from now. Once per covered step; a step the chain
    /// did not cover renews nothing, and nothing outlives `ceiling`.
    public func finished(_ step: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard renewable.remove(step) != nil, now >= anchor, now - born <= Self.ceiling else { return }
        anchor = now
    }
}

/// For tests, and for the harness (so the falsifier never triggers Touch ID).
public struct DenyingAuthenticator: PersonAuthenticator {
    public init() {}
    public func confirmPerson(reason: String) async -> Bool { false }
}
public struct AllowingAuthenticator: PersonAuthenticator {
    public init() {}
    public func confirmPerson(reason: String) async -> Bool { true }
}
