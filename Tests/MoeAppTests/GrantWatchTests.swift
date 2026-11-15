import Foundation
import Testing
import MoeBrain
@testable import Moe

/// docs/FIXABLE-FAILURES.md slice 4, driven through the real Conductor: a
/// failed tool's card, Open Settings through the real `FixActions.live`
/// `.grant` branch, the watch, the flip, and the one background carry-on.
///
/// Only two things are swapped: opening a URL (a recorder — System Settings
/// never opens on the Mac running this) and the probe (a switch the test
/// flips). `grantWatch.runsTimer` is off and the test calls `tick()` itself,
/// so nothing waits on a real two seconds.
@MainActor
@Suite(.serialized)
struct GrantWatchTests {

    final class Switch { var on = false; var calls = 0; var fixes: [ToolFix] = [] }

    static let answer = "I can't read Chrome's data: Full Disk Access is off for Memoe. Want me to open that setting?"

    /// A Conductor whose last turn failed with the fixture's tcc_app_data and
    /// has finished, with its Fix card on show.
    static func failedTurn() async throws -> (Conductor, FakeBrain, Switch, Box) {
        let (moe, brain) = try FixCardConductorTests.make()
        let sw = Switch()
        let opened = Box()
        moe.openSettingsURL = { opened.urls.append($0) }
        moe.fixActions = .live
        moe.grantWatch.runsTimer = false
        moe.grantWatch.probe = { _, fix in sw.calls += 1; sw.fixes.append(fix); return sw.on }
        moe.submit("find me a flight from Hanoi to Kunming", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(.toolStarted(name: "browser_navigate", id: "toolu_chrome_1", emoji: nil,
                                detail: "google.com/travel/flights", spoken: nil))
        brain.emit(HermesBrain.toolFinished(frame: try FixCardConductorTests.fixtureFrame(), id: "toolu_chrome_1"))
        brain.reply(answer, end: .answered)
        return (moe, brain, sw, opened)
    }

    final class Box { var urls: [URL] = [] }

    /// Open Settings starts its watch from a Task (the baseline is read
    /// first): let it run.
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    /// The brain's `moe_open_settings` step, running, as the stream reports it.
    static func openSettingsStep(_ brain: FakeBrain, id: String = "toolu_open_1") {
        brain.emit(.toolStarted(name: "mcp__hermes__moe_open_settings", id: id, emoji: nil,
                                detail: "Privacy_AllFiles", spoken: nil))
    }

    // MARK: - End to end

    /// The acceptance run, minus the Mac: tcc_app_data → card → Open Settings
    /// starts the watch → the switch flips → exactly one carry-on, from
    /// `.background`, and the card is gone.
    @Test func aFlipAfterOpenSettingsSendsExactlyOneBackgroundCarryOn() async throws {
        let (moe, brain, sw, opened) = try await Self.failedTurn()
        let card = try #require(moe.fixOffers.first)
        #expect(card.fix.code == .tccAppData)

        moe.performFix(card)
        await Self.settle()
        #expect(opened.urls == [card.settingsURL!], "Open Settings opens exactly the card's pane")
        #expect(moe.grantWatch.watches[.tccAppData] != nil, "Open Settings starts the watch")

        let before = brain.sent.count
        await moe.grantWatch.tick()          // still off
        await moe.grantWatch.tick()
        #expect(brain.sent.count == before)
        #expect(sw.calls == 3, "the baseline, then two polls")

        sw.on = true
        await moe.grantWatch.tick()
        try await brain.waitForSends(before + 1)
        let carryOn = try #require(brain.sent.last)
        #expect(carryOn.starter == .background)
        #expect(carryOn.text.contains("(Background note, not from the person: Full Disk Access for \(BuildInfo.hostAppName) is on now. Carry on with what you were doing.)"))
        #expect(moe.grantWatch.watches.isEmpty)
        #expect(moe.fixOffers.isEmpty)

        // And only one, however long the switch stays on.
        await moe.grantWatch.tick()
        await moe.grantWatch.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(brain.sent.count == before + 1)
    }

    /// The probe reads the folder the tool could not — the failure's `path` —
    /// before the guide's generic one.
    @Test func theReadableProbePrefersTheFailuresPath() async throws {
        let (moe, _, sw, _) = try await Self.failedTurn()
        moe.performFix(try #require(moe.fixOffers.first))
        await Self.settle()
        let fix = try #require(sw.fixes.first)
        #expect(GrantWatch.probePath(PermissionGuide.fullDiskAccessProbePath, fix: fix)
                == "/Users/x/Library/Application Support/Google/Chrome")
        let bare = ToolFix(code: .tccAppData, pane: "Privacy_AllFiles")
        #expect(GrantWatch.probePath("~/Library/Application Support/com.apple.TCC", fix: bare)
                == NSHomeDirectory() + "/Library/Application Support/com.apple.TCC")
        // Not a relative path, and never one with a NUL in it.
        let odd = ToolFix(code: .tccAppData, extras: ["path": "Library/x"])
        #expect(GrantWatch.probePath("/fallback", fix: odd) == "/fallback")
    }

    /// Something newer the person said supersedes the carry-on.
    @Test func noCarryOnWhenANewerTurnSupersededIt() async throws {
        let (moe, brain, sw, _) = try await Self.failedTurn()
        moe.performFix(try #require(moe.fixOffers.first))
        await Self.settle()
        moe.submit("actually, what's the weather?", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        brain.reply("Sunny, 24 degrees.", end: .answered)
        let before = brain.sent.count
        sw.on = true
        await moe.grantWatch.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(brain.sent.count == before, "\(brain.sent.map(\.text))")
        #expect(moe.grantWatch.watches.isEmpty, "a dropped carry-on ends the watch")
    }

    /// Granted while a turn is still streaming: the note waits for it, then goes once.
    @Test func aFlipDuringATurnWaitsForItToFinish() async throws {
        let (moe, brain) = try FixCardConductorTests.make()
        let sw = Switch()
        moe.openSettingsURL = { _ in }
        moe.grantWatch.runsTimer = false
        moe.grantWatch.probe = { _, _ in sw.on }
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(HermesBrain.toolFinished(frame: try FixCardConductorTests.fixtureFrame(), id: "toolu_chrome_1"))
        // The brain opens the pane itself, mid-turn.
        Self.openSettingsStep(brain)
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") == nil)
        brain.emit(.toolFinished(id: "toolu_open_1"))
        sw.on = true
        await moe.grantWatch.tick()
        #expect(brain.sent.count == 1, "no second turn while one is in flight")
        #expect(moe.grantWatch.watches[.tccAppData] != nil)
        brain.reply("Opened it — switch Memoe on and I'll carry on.", end: .answered)
        await moe.grantWatch.tick()
        try await brain.waitForSends(2)
        #expect(brain.sent.last?.starter == .background)
        await moe.grantWatch.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(brain.sent.count == 2)
    }

    @Test func aNewConversationStopsTheWatch() async throws {
        let (moe, _, _, _) = try await Self.failedTurn()
        moe.performFix(try #require(moe.fixOffers.first))
        await Self.settle()
        #expect(!moe.grantWatch.watches.isEmpty)
        moe.newConversation()
        #expect(moe.grantWatch.watches.isEmpty)
    }

    // MARK: - The watcher on its own

    @Test func theWatchGivesUpAfterFiveMinutes() async throws {
        let watch = GrantWatch()
        watch.runsTimer = false
        var t = Date(timeIntervalSince1970: 1_000_000)
        watch.now = { t }
        var calls = 0
        watch.probe = { _, _ in calls += 1; return false }
        var granted = 0
        watch.onGranted = { _ in granted += 1; return .sent }
        #expect(await watch.start(fix: ToolFix(code: .tccAppData, pane: "Privacy_AllFiles"),
                                  guide: .fullDiskAccess, conversationID: "c", personTurn: 1))
        calls = 0
        t += 298; await watch.tick()
        #expect(calls == 1 && !watch.watches.isEmpty)
        t += 3; await watch.tick()          // 301 s
        #expect(watch.watches.isEmpty)
        #expect(calls == 1, "an expired watch is not probed again")
        watch.probe = { _, _ in true }
        await watch.tick()
        #expect(granted == 0)
    }

    @Test func neverTwoWatchesForOneCode() async throws {
        let watch = GrantWatch()
        watch.runsTimer = false
        let fix = ToolFix(code: .tccAppData, pane: "Privacy_AllFiles")
        watch.probe = { _, _ in false }
        #expect(await watch.start(fix: fix, guide: .fullDiskAccess, conversationID: "c", personTurn: 1))
        #expect(!(await watch.start(fix: fix, guide: .fullDiskAccess, conversationID: "c", personTurn: 2)))
        #expect(watch.watches.count == 1)
        #expect(watch.watches[.tccAppData]?.personTurn == 1, "the first watch stands")
        var granted = 0
        watch.probe = { _, _ in true }
        watch.onGranted = { _ in granted += 1; return .sent }
        await watch.tick(); await watch.tick()
        #expect(granted == 1)
    }

    /// Through the Conductor too: pressing Open Settings on a card and then
    /// the brain opening the same pane is one watch.
    @Test func theCardAndTheBrainShareOneWatch() async throws {
        let (moe, _, _, _) = try await Self.failedTurn()
        moe.performFix(try #require(moe.fixOffers.first))
        await Self.settle()
        #expect(!(await moe.watchGrant(for: ToolFix(code: .tccAppData, pane: "Privacy_AllFiles"))))
        #expect(moe.grantWatch.watches.count == 1)
    }

    /// A grant macOS only applies after a relaunch, whose probe cannot see it
    /// before then, is not watched; a readable path is, because reading the
    /// folder is the very thing that failed.
    @Test func relaunchGrantsAreWatchedOnlyWhenTheProbeIsTheEffect() {
        // Accessibility takes effect the moment it is switched on
        // (AccessibilityWatch arms the key then), so its probe flipping
        // means it works now: watched, like any live grant.
        #expect(!PermissionGuide.accessibility.needsRelaunch)
        #expect(GrantWatch.watchable(.accessibility))
        #expect(!GrantWatch.watchable(.screenRecording))   // needsRelaunch, preflight
        #expect(!GrantWatch.watchable(.inputMonitoring))
        #expect(GrantWatch.watchable(.fullDiskAccess))     // needsRelaunch, but readable path
        #expect(GrantWatch.watchable(.automation))
        #expect(GrantWatch.watchable(.driverAccessibility))
        #expect(!GrantWatch.watchable(.speechRecognition))    // nothing to probe
    }

    // MARK: - moe_open_settings, the app's half

    @Test func theBrainMayOpenAPaneOnlyInThePersonsTurnInFlight() async throws {
        let (moe, brain) = try FixCardConductorTests.make()
        let opened = Box()
        moe.openSettingsURL = { opened.urls.append($0) }
        moe.grantWatch.runsTimer = false
        moe.grantWatch.probe = { _, _ in false }

        // Nobody's turn in flight: a cron job, or anything else on this Mac.
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") != nil)

        // A background turn in flight.
        moe.submit("Something you handed off just finished.", origin: .spoken, starter: .background,
                   outgoing: "(Background note, not from the user.)")
        try await brain.waitForSends(1)
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") != nil)
        brain.reply("Done.", end: .answered)
        #expect(opened.urls.isEmpty)
        #expect(moe.grantWatch.watches.isEmpty)

        // The person's turn in flight: not a URL, not an unknown pane.
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        brain.emit(HermesBrain.toolFinished(frame: try FixCardConductorTests.fixtureFrame(), id: "toolu_chrome_1"))
        Self.openSettingsStep(brain)
        for bad in ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
                    "https://example.com", "Privacy_SpeechRecognition", "Privacy_ListenEvent",
                    "privacy_allfiles", ""] {
            #expect(await moe.openSettingsForBrain(pane: bad) != nil, "\(bad)")
        }
        #expect(opened.urls.isEmpty)

        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") == nil)
        #expect(opened.urls.map(\.absoluteString)
                == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        // The watch is for this conversation's own failure: its subject and path.
        let watched = try #require(moe.grantWatch.watches[.tccAppData])
        #expect(watched.fix.extras["path"] == "/Users/x/Library/Application Support/Google/Chrome")
    }

    /// The reviewer's spoof: any process can post the signal. With no tool
    /// failure for that pane — or no moe_open_settings step running — it
    /// opens nothing, watches nothing, and no "now on" note is ever sent.
    @Test func aSpoofedOpenWithNoRecordedFailureIsRefused() async throws {
        let (moe, brain) = try FixCardConductorTests.make()
        let opened = Box()
        moe.openSettingsURL = { opened.urls.append($0) }
        moe.grantWatch.runsTimer = false
        moe.submit("what's on my screen?", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        Self.openSettingsStep(brain)
        // Off and on alike: with no failure behind it, nothing opens.
        for i in 0..<20 {
            moe.grantWatch.probe = { _, _ in i % 2 == 1 }   // off first
            #expect(await moe.openSettingsForBrain(pane: "Privacy_Accessibility") != nil)
        }
        moe.grantWatch.probe = { _, _ in true }
        #expect(opened.urls.isEmpty)
        #expect(moe.grantWatch.watches.isEmpty)
        brain.reply("Nothing to see.", end: .answered)
        await moe.grantWatch.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(brain.sent.count == 1, "\(brain.sent.map(\.text))")

        // A real failure, but the signal comes from some other step (the
        // model's shell running osascript): still nothing.
        moe.grantWatch.probe = { _, _ in false }
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        brain.emit(HermesBrain.toolFinished(frame: try FixCardConductorTests.fixtureFrame(), id: "toolu_chrome_1"))
        brain.emit(.toolStarted(name: "terminal", id: "toolu_sh", emoji: nil, detail: "osascript", spoken: nil))
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") != nil)
        #expect(opened.urls.isEmpty)
    }

    /// A failure the person answered yes to in their next turn is still theirs;
    /// one from two turns back is not.
    @Test func theFailureMayBeFromTheTurnBeforeButNoOlder() async throws {
        let (moe, brain, _, opened) = try await Self.failedTurn()
        moe.grantWatch.probe = { _, _ in false }
        moe.submit("yes, open it", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        Self.openSettingsStep(brain)
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") == nil)
        #expect(opened.urls.count == 1)
        brain.reply("Opened.", end: .answered)
        moe.grantWatch.cancelAll("test")
        moe.submit("something else", origin: .typed, starter: .person)
        try await brain.waitForSends(3)
        Self.openSettingsStep(brain, id: "toolu_open_2")
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") != nil)
        #expect(opened.urls.count == 1)
    }

    /// Already on: the app holds the grant and the failure was elsewhere.
    /// No pane, no watch, no carry-on — from the brain or from the card.
    @Test func aGrantAlreadyOnIsNeverWatchedOrAnnounced() async throws {
        let (moe, brain, sw, opened) = try await Self.failedTurn()
        sw.on = true
        moe.performFix(try #require(moe.fixOffers.first))
        await Self.settle()
        #expect(moe.grantWatch.watches.isEmpty, "the card's watch took no baseline")
        moe.submit("yes, open it", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        Self.openSettingsStep(brain)
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") != nil)
        #expect(opened.urls.count == 1, "only the card's own press opened anything")
        brain.reply("It's already on.", end: .answered)
        await moe.grantWatch.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(brain.sent.count == 2, "\(brain.sent.map(\.text))")
    }

    /// Twenty opens of one pane in one turn open it once.
    @Test func twentyOpensInOneTurnOpenOnce() async throws {
        let (moe, brain) = try FixCardConductorTests.make()
        let opened = Box()
        moe.openSettingsURL = { opened.urls.append($0) }
        moe.grantWatch.runsTimer = false
        moe.grantWatch.probe = { _, _ in false }
        moe.submit("find me a flight", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.emit(HermesBrain.toolFinished(frame: try FixCardConductorTests.fixtureFrame(), id: "toolu_chrome_1"))
        Self.openSettingsStep(brain)
        var accepted = 0
        for i in 0..<20 {
            // Half of them after the watch has gone (it timed out, say):
            // the once-per-turn limit holds on its own.
            if i >= 10 { moe.grantWatch.cancelAll("test") }
            if await moe.openSettingsForBrain(pane: "Privacy_AllFiles") == nil { accepted += 1 }
        }
        #expect(accepted == 1)
        #expect(opened.urls.count == 1)

        // The next turn may open it again, but not while it is still watched.
        brain.emit(.toolFinished(id: "toolu_open_1"))
        brain.reply("Opened.", end: .answered)
        #expect(await moe.watchGrant(for: ToolFix(code: .tccAppData, pane: "Privacy_AllFiles")))
        moe.submit("is it on yet?", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        Self.openSettingsStep(brain, id: "toolu_open_2")
        #expect(await moe.openSettingsForBrain(pane: "Privacy_AllFiles") == "already watched")
        #expect(opened.urls.count == 1)
    }

    /// CuaDriver's guide already names it; the note says so once.
    @Test func theDriverNoteNamesCuaDriverOnce() {
        let note = Conductor.carryOnNote(.driverAccessibility, fix: ToolFix(code: .tccDriverAccessibility))
        #expect(note == "(Background note, not from the person: Accessibility (CuaDriver) is on now. Carry on with what you were doing.)")
        let own = Conductor.carryOnNote(.fullDiskAccess, fix: ToolFix(code: .tccAppData), app: "Memoe")
        #expect(own.contains("Full Disk Access for Memoe is on now"))
    }

    /// The plugin's allowlist and signal are the app's: one list, two languages.
    @Test func thePluginsAllowlistIsTheAppsKnownPanes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("moe-home/hermes-plugins/moe-screen/open_settings.py")
        let src = try String(contentsOf: url, encoding: .utf8)
        let block = try #require(src.range(of: "PANES = (")
            .flatMap { start in src[start.upperBound...].range(of: ")").map { src[start.upperBound..<$0.lowerBound] } })
        let panes = Set(block.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\"") else { return nil }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "\",")) })
        #expect(panes == ToolFix.knownPanes)
        for pane in panes {
            #expect(PermissionGuide.catalogue.contains { $0.settings.hasSuffix("?" + pane) && !$0.codes.isEmpty },
                    "\(pane) has no guide a fix points at")
        }
        #expect(src.contains("SIGNAL = \"\(Conductor.openSettingsSignal.rawValue)\""))
    }

    // MARK: - The rule

    @Test func theRuleIsInTheStablePrompt() {
        let prompt = BrainPrompt.systemPrompt()
        #expect(prompt.contains(BrainPrompt.fixableFailureRule))
        #expect(BrainPrompt.fixableFailureRule.contains("moe_open_settings"))
        #expect(BrainPrompt.fixableFailureRule.contains("Never guess a cause"))
        #expect(prompt == BrainPrompt.systemPrompt(), "stable: the same text every turn")
    }
}
