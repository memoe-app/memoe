import Foundation
import Testing

/// Where `ReplyRoute` and the reply chime are *called from*.
///
/// `ReplyRoute.speaks` is a pure function with a full truth table of tests
/// against it, and both of the defects this file exists to stop got past all
/// of them — because neither was in the function. They were in the state the
/// Conductor keeps beside it, and `Sources/Moe/Conductor.swift` is an
/// executable target that Swift cannot import into a test.
///
/// So this reads the source, the same way `ConductorWiringTests` does and for
/// the same reason: the claim being made is about a *call site*, and a call
/// site is not reachable any other way. Both checks below name the artefact
/// they read and fail loudly if it moves.
///
/// If one fails after a legitimate refactor, do not delete it — work out
/// which of the two bugs it is describing and confirm the new shape cannot
/// have it.
struct ReplyRoutingWiringTests {

    private static let source: String? = {
        let root = URL(fileURLWithPath: #filePath)   // Tests/MoeIslandTests/…
            .deletingLastPathComponent()             // Tests/MoeIslandTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // repo root
        return try? String(contentsOf: root.appendingPathComponent("Sources/Moe/Conductor.swift"),
                           encoding: .utf8)
    }()

    @Test func theConductorSourceIsWhereThisExpectsItToBe() {
        #expect(Self.source != nil,
                "Sources/Moe/Conductor.swift moved; these wiring checks need its new path.")
    }

    // MARK: - The origin is claimed by the turn that is answered

    /// The bug: `turnOrigin = origin` was the first statement of `submit`,
    /// ahead of three guards that return without starting a turn — an empty
    /// transcript, a meeting Moe handles itself, and one already in flight.
    /// Neither island field is disabled while Moe is answering, so typing
    /// anything during a spoken reply took the third of those and re-routed
    /// the reply *already streaming*: every remaining gate read
    /// `replySpeaks == false` and Moe went mute mid-sentence.
    ///
    /// The invariant that stops it: the assignment sits after the last early
    /// return, which is the same place `turnBeganAt` is set — and `submit`
    /// says of that mark, in so many words, that a turn Moe handles itself
    /// must not leave one behind for the next thing typed to pick up.
    @Test func theOriginIsSetWhereTheTurnBudgetIs() throws {
        let source = try #require(Self.source)
        let assignment = try #require(source.range(of: "turnOrigin = origin"),
                                      "submit no longer records the turn's origin at all.")
        let budget = try #require(source.range(of: "turnBeganAt = spokenTurnBeganAt"))
        let guardAlreadyBusy = try #require(source.range(of: "guard !awaitingReply else {"))

        #expect(assignment.lowerBound > guardAlreadyBusy.upperBound,
                "turnOrigin is assigned before the guard !awaitingReply return, so a turn dropped for being too early re-routes the reply already in flight.")
        #expect(abs(source.distance(from: assignment.lowerBound, to: budget.lowerBound)) < 400,
                "turnOrigin has drifted away from turnBeganAt; the two mark the same moment and must move together.")
    }

    /// Set exactly once, so there is no second place for the shape above to
    /// come back in.
    @Test func theOriginIsSetInExactlyOnePlace() throws {
        let source = try #require(Self.source)
        let times = source.components(separatedBy: "turnOrigin = ").count - 1
        #expect(times == 1,
                "turnOrigin is assigned \(times) times; every extra one is another way for a dropped turn to re-route the turn being answered.")
    }

    // MARK: - The chime is not a sound a recorded meeting can make

    /// The bug: the chime was gated on `!replySpeaks` alone. Mid-meeting
    /// `replySpeaks` is false *because the room must not hear Moe* — so
    /// quietly asking "what did they just say", which is a supported path
    /// with its own field and its own prompt block, put a tone out of the
    /// speakers and into the call.
    ///
    /// Two silences, one of which wants a sound. The gate has to name the
    /// meeting itself; no amount of `replySpeaks` can tell them apart.
    @Test func theChimeNamesTheMeetingAndNotJustTheSilence() throws {
        let source = try #require(Self.source)
        let play = try #require(source.range(of: "chime.play(.reply)"),
                                "the reply chime is gone; delete this check on purpose or restore the meeting guard with it.")
        // The guard is on the same line, immediately before the call.
        let lineStart = source[..<play.lowerBound].lastIndex(of: "\n") ?? source.startIndex
        let line = String(source[lineStart..<play.upperBound])
        #expect(line.contains("!meeting.isRecording"),
                "the reply chime does not check meeting.isRecording, so a question asked quietly during a recorded meeting sounds a tone into the call. Line: \(line)")
    }

    // MARK: - A panel that opens itself must offer a way out

    private static func read(_ path: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// `expandedBody`, from its declaration to the brace that closes the type
    /// it is the last member of.
    ///
    /// Bounded rather than run to the end of the file, which is what the first
    /// version did — and `StateDot`, forty lines further down, draws its idle
    /// dot at `.white.opacity(0.4)`. The dimming check matched it and failed
    /// on a view that has nothing to do with any of this.
    private func expandedBody() throws -> String {
        let view = try #require(Self.read("Sources/Moe/IslandView.swift"),
                                "Sources/Moe/IslandView.swift moved.")
        // The dropdown of 2026-09-24 (`Dropdown`): one body for every state
        // outside a meeting, from its declaration to the next member.
        let start = try #require(view.range(of: "private var minimalBody: some View {"))
        let rest = view[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "minimalBody has no end this slice can find.")
        return String(rest[..<end.lowerBound])
    }

    /// The complaint, in the owner's words: "when Moe responds and the setting
    /// allowed the response to come in the island, there's no way to x out of
    /// the dropdown."
    ///
    /// There was one button — `xmark`, at four-tenths opacity — and it meant
    /// `cancelEverything`: take the microphone down and abandon the turn. That
    /// is the right verb while Moe is working and the wrong one once it has
    /// answered. It went unnoticed while the panel only opened itself when Moe
    /// had nothing to say; a typed reply is silent by default now, so it opens
    /// on every one of them.
    @Test func theExpandedPanelOffersAFold() throws {
        let body = try expandedBody()
        let view = try #require(Self.read("Sources/Moe/IslandView.swift"))
        #expect(body.contains("chrome(stop: false)")
                && view.contains(#"IslandButton(icon: "chevron.up") { onClose() }"#),
                "the expanded panel has no fold button, so a self-opened panel can only be closed by stopping the turn or waiting out the clock.")
        #expect(body.contains(".onExitCommand"),
                "Escape does not fold the panel, and it is what everybody tries first.")
        // Dimming the only way out to four-tenths is what made it invisible.
        #expect(!body.contains(".opacity(0.4)"),
                "the panel's way out is dimmed to four-tenths again.")
    }

    /// Folding is not stopping. Offering `cancelEverything` as the way to
    /// dismiss a finished answer offers the wrong verb, so it is shown only
    /// while there is something to stop.
    @Test func stopIsOfferedOnlyWhileThereIsSomethingToStop() throws {
        // The dropdown of 2026-09-24: the corner never offers ✕ (it called
        // `cancelEverything`, a weaker stop than the working row's). Stop is
        // one icon in the tray, only while Moe works (`IslandTray`, tested in
        // DropdownTests), and it is the full stop.
        let body = try expandedBody()
        #expect(body.contains("chrome(stop: false)"),
                "the dropdown's corner offers a ✕ again, a second stop beside the tray's.")
        let view = try #require(Self.read("Sources/Moe/IslandView.swift"))
        let stop = try #require(view.range(of: "case .stop(let driving):"),
                                "the tray has no stop.")
        #expect(view[stop.upperBound...].prefix(200).contains("conductor.stopEverything()"),
                "the tray's stop is not the full stop.")
    }

    /// Closing by hand has to end the self-opening state too, or the next
    /// answer finds a panel that already believes it opened itself and starts
    /// a second reading clock beside the first.
    @Test func foldingByHandEndsTheSelfOpenedState() throws {
        let island = try #require(Self.read("Sources/Moe/NotchIsland.swift"),
                                  "Sources/Moe/NotchIsland.swift moved.")
        #expect(island.contains("onClose: { [weak self] in self?.foldByHand() }"),
                "onClose no longer goes through foldByHand, so it collapses the panel without cancelling the reading clock or clearing selfOpened.")
        let fold = try #require(island.range(of: "private func foldByHand() {"))
        let end = try #require(island.range(of: "\n    }", range: fold.upperBound..<island.endIndex))
        let source = String(island[fold.upperBound..<end.lowerBound])
        #expect(source.contains("revealTask?.cancel()"), "foldByHand leaves the reading clock running.")
        #expect(source.contains("selfOpened = false"), "foldByHand leaves selfOpened set.")
        // Folding is "I have read this", never "stop what you are doing".
        #expect(!source.contains("cancelEverything"),
                "foldByHand cancels the turn; folding a panel must not stop Moe working.")
    }

    /// The owner, 2026-09-24: hovering the notch during a call showed the
    /// transcript and the question field, and put the cursor in the field,
    /// so a pass of the mouse took the keyboard off the call window. Hover
    /// still shows both; only a click (the expanded panel) takes the keyboard.
    @Test func aMeetingHoverNeverTakesTheKeyboard() throws {
        let view = try #require(Self.read("Sources/Moe/IslandView.swift"))
        #expect(view.contains("guard takesFocus, presentation == .expanded else { return }"),
                "the meeting field takes the keyboard on hover again.")
    }

}
