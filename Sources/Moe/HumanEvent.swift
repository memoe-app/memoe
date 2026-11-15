import AppKit
import SwiftUI
import LocalAuthentication
import MoeScreen

// MARK: - Only a person can press this (D9.14)
//
// Moe drives the screen (docs/COMPUTER-USE.md): cua-driver clicks by
// accessibility press and by posting CGEvents, and AppleScript presses
// buttons through System Events. So a control that records consent — the
// consent sheet's Agree, the re-accept Agree, the Privacy switches — acts on
// its own only for an event a person made; for anything else it asks the
// person to authenticate (Touch ID / login password) before it runs.
// `HumanEventRule` (MoeScreen) is the rule and its measurements; this file
// reads the live event, keeps the person-event monitor, and wraps it for
// SwiftUI.
//
// Match on what the event IS, and prove it belongs to THIS press. Never on
// which tool might have sent it: the next tool has a new name, and a
// synthetic event from it is stamped with its pid exactly like the ones
// measured here.

/// Remembers the last event a person actually made, so a control can tell a
/// live person-press from a lingering `NSApp.currentEvent`. Process-global,
/// like the event stream it watches.
@MainActor
final class HumanPresence {
    static let shared = HumanPresence()

    private var monitor: Any?
    private var lastPersonTimestamp: TimeInterval?
    private var consumed: Set<TimeInterval> = []

    /// Install the monitor once, at launch. Idempotent.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            self?.note(event); return event
        }
    }

    private func note(_ event: NSEvent) {
        // Only a person's event (pid 0) is worth remembering. A synthetic
        // event carries the posting process's pid and is ignored here, so it
        // can never become the "live person event" a press is matched to.
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        guard pid == 0 else { return }
        lastPersonTimestamp = event.timestamp
    }

    /// Mark the current event as having authorised an action, so the same
    /// event cannot authorise a second (an AX press moments after a real
    /// click).
    private func consume(_ timestamp: TimeInterval) {
        consumed.insert(timestamp)
        if consumed.count > 128 { consumed.removeAll() }   // unbounded only in theory
    }

    /// The verdict on the event dispatching right now, for the control at
    /// `place` (`HumanPressPlace`: AppKit's own rectangle for it, read now).
    /// Call synchronously inside the action — after an `await`,
    /// `currentEvent` is somebody else's.
    func classify(control place: HumanPressPlace?,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> HumanEventRule.Verdict {
        guard let event = NSApp.currentEvent else { return HumanEventRule.classify(nil) }
        let kind: HumanEventRule.Facts.Kind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .mouseUp
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: kind = .other
        }
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        let live = (lastPersonTimestamp == event.timestamp) && !consumed.contains(event.timestamp)

        // Read only for the two kinds that can be a press: other event
        // types do not all carry a window or a location.
        let where_ = (kind == .mouseUp || kind == .keyDown) ? place?.read() : nil
        let eventWindow = event.window?.windowNumber ?? -1
        let facts = HumanEventRule.Facts(
            kind: kind, sourcePID: pid, age: now - event.timestamp,
            liveAndUnused: live,
            insideControl: kind == .mouseUp
                && HumanEventRule.insideControl(click: event.locationInWindow, eventWindow: eventWindow,
                                                place: where_),
            activatesControl: activates(event, place: where_))
        let verdict = HumanEventRule.classify(facts)
        if verdict.isPerson { consume(event.timestamp) }
        return verdict
    }

    private func activates(_ event: NSEvent, place: ControlPlace?) -> Bool {
        guard event.type == .keyDown, event.window?.isKeyWindow == true else { return false }
        // Where the control's window is known, the key must have gone to it.
        if let place, place.windowNumber != event.window?.windowNumber { return false }
        switch event.keyCode {
        case 36, 76, 49: return true   // Return, keypad Enter, Space
        default: return false
        }
    }
}

/// Where a control is, for the hit-test: a view AppKit lays out behind it
/// (`HumanPressProbe`), asked for its rectangle **at the moment of the
/// press**. Nothing is cached, so there is no frame captured before layout,
/// none left over from before a resize, and none in a coordinate space that
/// has to be converted (see `ControlPlace` for what that cost).
@MainActor
final class HumanPressPlace {
    fileprivate(set) weak var view: NSView?

    func read() -> ControlPlace? {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return ControlPlace(windowNumber: window.windowNumber,
                            rectInWindow: view.convert(view.bounds, to: nil))
    }
}

extension HumanPressPlace {
    /// **Weaker than a control's own place, and only for a control that has
    /// none yet**: the whole content of the window the event dispatching
    /// right now was delivered to. A press judged against it still has to be
    /// a live, unused, hardware event made this instant — so an accessibility
    /// press (no event), a posted click (the poster's pid) and a lingering
    /// event all fail exactly as they do for a control — but it is not proved
    /// to have landed on THIS control, only in its window. Call it in the
    /// control's action, like `HumanEvent.current`. Give the control a
    /// `HumanPressProbe` instead wherever its view can be edited.
    static func windowOfCurrentEvent() -> HumanPressPlace? {
        guard let content = NSApp.currentEvent?.window?.contentView else { return nil }
        let place = HumanPressPlace()
        place.view = content
        return place
    }
}

/// Put behind a consent control — `.background(HumanPressProbe(place))` — so
/// the control has a place to hit-test. It draws nothing and takes no clicks.
struct HumanPressProbe: NSViewRepresentable {
    let place: HumanPressPlace?
    init(_ place: HumanPressPlace?) { self.place = place }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.setAccessibilityElement(false)
        place?.view = view
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { place?.view = view }
}

enum HumanEvent {
    /// The verdict for the control at `place`, right now. Synchronously, in
    /// the control's action.
    @MainActor
    static func current(control place: HumanPressPlace?) -> HumanEventRule.Verdict {
        HumanPresence.shared.classify(control: place)
    }

    /// Gate a consent step that is NOT itself a control the person presses —
    /// the Google sign-in that registers this Mac's key, say. It follows from
    /// a press, so the press that was verified answers for it
    /// (`ConsentChain`: once, within seconds, and only for a step that press
    /// leads to). With no such press behind it, the person authenticates.
    /// Never "a person's press" on its own account: nothing is pressed here.
    @MainActor
    static func authorize(step: String, reason: String = HumanOnly.authReason,
                          chain: ConsentChain? = ConsentChain.current,
                          authenticator: PersonAuthenticator = LocalAuthAuthenticator()) async -> Bool {
        if let chain, chain.covers(step) {
            Log.write("consent: '\(step)' follows from your press on '\(chain.origin)'; not asking again")
            return true
        }
        Log.write("consent: '\(step)' has no person's press behind it; asking to authenticate")
        return await authenticator.confirmPerson(reason: reason)
    }

    /// Gate a control whose press was read with `current(control:)` in its
    /// own action: a person's press goes ahead, anything else authenticates.
    /// Returns the proof, which opens the chain for what follows.
    @MainActor
    static func authorize(control: String, verdict: HumanEventRule.Verdict,
                          reason: String = HumanOnly.authReason,
                          authenticator: PersonAuthenticator = LocalAuthAuthenticator()) async -> PersonProof? {
        if let proof = HumanGate.proof(verdict) { return proof }
        Log.write("consent: '\(control)' not a person's press — \(verdict.reason); asking to authenticate")
        return await HumanGate.prove(verdict, reason: reason, authenticator: authenticator)
    }

    /// Run a consent control's action inside the chain its press opens, so
    /// the steps that follow from it are not asked about again.
    @MainActor
    static func run(_ proof: PersonProof, control: String, _ action: () -> Void) {
        ConsentChain.$current.withValue(ConsentChain(proof, origin: control), operation: action)
    }
}

extension HumanEvent {
    /// `run`, for an action that waits: the chain is bound for as long as the
    /// action takes (a sign-in in the browser), and to nothing after it.
    @MainActor
    static func run<T: Sendable>(_ proof: PersonProof, control: String,
                                 _ action: () async throws -> T) async rethrows -> T {
        try await ConsentChain.$current.withValue(ConsentChain(proof, origin: control), operation: action)
    }
}

enum HumanOnly {
    /// Shown under a control after an attempt that was neither a person's
    /// press nor an authentication.
    static let note = "Please click this yourself."
    /// The reason string LocalAuthentication shows.
    static let authReason = "Confirm it's you to agree"
}

/// LocalAuthentication: Touch ID, then the login password. The agent can
/// drive neither.
struct LocalAuthAuthenticator: PersonAuthenticator {
    let reasonFallback = HumanOnly.authReason
    func confirmPerson(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.write("consent: cannot ask for authentication: \(error?.localizedDescription ?? "unknown")")
            return false
        }
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}

/// A Button that runs `action` only for a person's press, or — for a press
/// that is not provably a person's (an accessibility user, say) — after the
/// person authenticates. Anything the agent can do (AX press, posted event,
/// a lingering click elsewhere) neither runs it nor gets asked.
///
///     HumanOnlyButton("Agree and continue", control: "upgrade-agree") { agree() }
///         .keyboardShortcut(.defaultAction)
struct HumanOnlyButton<Label: View>: View {
    let control: String
    let action: () -> Void
    let authenticator: PersonAuthenticator
    let label: () -> Label
    @State private var place = HumanPressPlace()
    @State private var refused = false

    init(control: String, authenticator: PersonAuthenticator = LocalAuthAuthenticator(),
         action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.control = control
        self.authenticator = authenticator
        self.action = action
        self.label = label
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                gate(HumanEvent.current(control: place))
            } label: { label() }
            .background(HumanPressProbe(place))
            if refused {
                Text(HumanOnly.note).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("human-only-note")
            }
        }
    }

    private func gate(_ verdict: HumanEventRule.Verdict) {
        if let proof = HumanGate.proof(verdict) {
            refused = false; HumanEvent.run(proof, control: control, action); return
        }
        Task { @MainActor in
            if let proof = await HumanEvent.authorize(control: control, verdict: verdict,
                                                      authenticator: authenticator) {
                refused = false; HumanEvent.run(proof, control: control, action)
            } else {
                refused = true
                Log.write("consent: '\(control)' not authenticated; refused")
            }
        }
    }
}

extension HumanOnlyButton where Label == Text {
    init(_ title: String, control: String,
         authenticator: PersonAuthenticator = LocalAuthAuthenticator(), action: @escaping () -> Void) {
        self.init(control: control, authenticator: authenticator, action: action) { Text(title) }
    }
}

/// A Toggle binding whose *set* goes through only for a person's press, or
/// after the person authenticates. A refused flip leaves the value unchanged
/// (SwiftUI re-reads it, so the switch springs back). Give the Toggle a
/// `.background(HumanPressProbe(place))` so the hit-test works; `HumanLever`
/// does this.
extension Binding where Value == Bool {
    @MainActor
    func humanOnly(_ control: String, place: HumanPressPlace?, refused: Binding<Bool>,
                   authenticator: PersonAuthenticator = LocalAuthAuthenticator()) -> Binding<Bool> {
        Binding(get: { wrappedValue }, set: { new in
            guard new != wrappedValue else { return }
            let verdict = HumanEvent.current(control: place)
            if let proof = HumanGate.proof(verdict) {
                refused.wrappedValue = false
                HumanEvent.run(proof, control: control) { wrappedValue = new }
                return
            }
            Task { @MainActor in
                if let proof = await HumanEvent.authorize(control: control, verdict: verdict,
                                                          authenticator: authenticator) {
                    refused.wrappedValue = false
                    HumanEvent.run(proof, control: control) { wrappedValue = new }
                } else {
                    refused.wrappedValue = true
                }
            }
        })
    }
}
