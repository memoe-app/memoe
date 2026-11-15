import Foundation
import Testing
@testable import Moe

/// Moe knows its own settings (docs/SETTINGS-ASSISTANT.md): one catalogue,
/// held to the pages' own words, the safety split held by name, and a bridge
/// whose refusals are proved by what they leave unchanged.
@MainActor
@Suite(.serialized)
struct SettingsCatalogueTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Every title is a row's title, word for word, in a Settings source.
    /// A renamed row with a stale entry would send Moe looking for a label
    /// the person cannot find.
    @Test func everyTitleIsOnAPage() throws {
        let dir = Self.root.appendingPathComponent("Sources/Moe/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !$0.lastPathComponent.hasPrefix("SettingsCatalogue") }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        for e in SettingsCatalogue.all {
            // A row titled by a constant (`BackgroundLearning.Words.pass`) is found by the constant's text.
            #expect(source.contains("title: \"\(e.title)\"") || source.contains("static let pass = \"\(e.title)\""),
                    "no row is titled “\(e.title)” (\(e.id))")
        }
    }

    @Test func idsAndTitlesAreUnique() {
        let ids = SettingsCatalogue.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Two rows may share a title only on different pages; the spotlight
        // and the prompt's map tell them apart by page.
        let keyed = SettingsCatalogue.all.map { "\($0.page.rawValue)/\($0.title)" }
        #expect(Set(keyed).count == keyed.count)
        #expect(SettingsCatalogue.all.allSatisfy { !$0.says.isEmpty && !$0.does.isEmpty })
    }

    /// The person flips these, never Moe: the microphone, the screen, money,
    /// the brain, sending for them. Named, so moving one to `.moe` is a
    /// visible decision in a diff rather than a quiet edit.
    @Test func theSafetySplitHolds() {
        let theirs = ["brainModel", "reasoningEffort", "workLimitMinutes", "wakeWordEnabled",
                      "conversationMode", "bargeIn", "holdOpensConversation", "locale", "ttsVoice",
                      "cloudVoice", "meetingAutoDetect", "meetingCapture.screenshots",
                      "meetingCapture.recording", "meetingCapture.scope", "meetingCapture.caption",
                      "screenContext", "screenPointerMovesMouse", "computerUseMayTakeOver",
                      "backgroundThinking", "situationOffersToChats",
                      "browseAsProfile", "meetingCapture.region", "learning", "memorySeeding"]
        for id in theirs {
            let e = SettingsCatalogue.entry(id)
            #expect(e != nil, "\(id) left the catalogue")
            #expect(e?.who == .person, "\(id) must be the person's to flip")
        }
        let moe = SettingsCatalogue.all.filter { $0.who == .moe }.map(\.id).sorted()
        #expect(moe == ["calendarHeadsUpMinutes", "closeOffer", "followUpSeconds", "hotKeyModifiers",
                        "instantAck", "meetingAutoStopOnCallEnd", "notchHoverOpens", "nudges",
                        "panelOnReply", "quietHours", "replyChime", "replyLength",
                        "replyReadingSeconds", "situationOffers", "speakReplies", "speakSpokenReplies",
                        "speakTypedReplies", "spokenProgress", "talkKey", "tenMinuteCheck", "typedAnswersOpenChat",
                        "typedRepliesReadAsText"])
    }

    /// The send gate lets a settings change through without asking only
    /// from its own copy of `SettingsCatalogue.direct`. The two must agree,
    /// and every value in it must be one the setting takes.
    @Test func theGateHoldsTheSameTable() throws {
        let hook = try String(contentsOf: Self.root.appendingPathComponent("moe-home/hermes/hooks/confirm-send.sh"),
                              encoding: .utf8)
        let start = try #require(hook.range(of: "SETTINGS_DIRECT = {"))
        let end = try #require(hook.range(of: "\n}", range: start.upperBound..<hook.endIndex))
        let block = String(hook[start.upperBound..<end.lowerBound])
        var gate: [String: Set<String>] = [:]
        let pair = try Regex(#""([A-Za-z.]+)": \(([^)]*)\)"#)
        for m in block.matches(of: pair) {
            let id = String(m.output[1].substring ?? "")
            let values = (m.output[2].substring ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
            gate[id] = Set(values)
        }
        #expect(gate == SettingsCatalogue.direct)
        for (id, values) in SettingsCatalogue.direct {
            let e = try #require(SettingsCatalogue.entry(id), "\(id) is not a setting")
            #expect(e.who == .moe, "\(id) is the person's; Moe never changes it at all")
            for v in values { #expect(SettingsCatalogue.normalise(v, for: e) == v, "\(id) does not take \(v)") }
        }
        // Turning speech, nudges or offers on, quiet hours off, and a new
        // talk key are never on it: those must reach the person's eyes.
        for (id, widening) in [("speakReplies", "loud"), ("nudges", "on"), ("quietHours", "off"),
                               ("situationOffers", "on"), ("replyChime", "on"), ("closeOffer", "spoken")] {
            #expect(!(SettingsCatalogue.direct[id] ?? []).contains(widening), "\(id)=\(widening) must ask")
        }
        #expect(SettingsCatalogue.direct["talkKey"] == nil && SettingsCatalogue.direct["hotKeyModifiers"] == nil)
    }

    @Test func valuesAreNormalisedOrRefused() throws {
        let chime = try #require(SettingsCatalogue.entry("replyChime"))
        #expect(SettingsCatalogue.normalise("Off", for: chime) == "off")
        #expect(SettingsCatalogue.normalise("yes", for: chime) == "on")
        #expect(SettingsCatalogue.normalise("loud", for: chime) == nil)
        let length = try #require(SettingsCatalogue.entry("replyLength"))
        #expect(SettingsCatalogue.normalise("Detailed", for: length) == "detailed")
        #expect(SettingsCatalogue.normalise("huge", for: length) == nil)
    }

    /// Every switch Moe may change really changes, and reads back what it was
    /// given: a `write` that calls the wrong setter fails here.
    @Test func everyMoeSettingWritesAndReadsBack() throws {
        try StallGuardConductorTests.requireScratchHome()
        var seed = Config()
        seed.hermesKey = "settings-catalogue-test"
        seed.save()
        let c = Conductor(config: seed)
        for e in SettingsCatalogue.all where e.who == .moe {
            let was = e.read(c)
            let other: String
            switch e.kind {
            case .toggle: other = was == "on" ? "off" : "on"
            case .choice(let options):
                other = try #require(options.map(\.value).first { $0 != was }, "\(e.id) has one choice")
            case .number(let lo, let hi, _):
                other = SettingsCatalogue.normalise(String(Double(was) == lo ? hi : lo), for: e) ?? ""
            }
            #expect(e.write(c, other), "\(e.id) did not take \(other)")
            #expect(e.read(c) == other, "\(e.id) reads \(e.read(c)) after writing \(other)")
            _ = e.write(c, was)
        }
    }

    @Test func thePublishedFileCarriesEverySettingAndItsValue() throws {
        try StallGuardConductorTests.requireScratchHome()
        var seed = Config()
        seed.replyChime = false
        seed.save()
        let c = Conductor(config: seed)
        try? FileManager.default.removeItem(at: SettingsCatalogue.fileURL)
        SettingsCatalogue.publish(c)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: SettingsCatalogue.fileURL))
                               as? [String: Any])
        let rows = try #require(obj["settings"] as? [[String: Any]])
        #expect(rows.count == SettingsCatalogue.all.count)
        let chime = try #require(rows.first { $0["id"] as? String == "replyChime" })
        #expect(chime["value"] as? String == "off")
        #expect(chime["page"] as? String == "Voice")
        #expect(chime["who"] as? String == "moe")
        #expect((chime["says"] as? [String])?.contains("stop dinging") == true)
    }

    /// Every title is in the prompt, and no value is: moving a switch must
    /// not change the prompt, or every change respawns the brain.
    @Test func thePromptKnowsEveryTitleAndNoValue() throws {
        try StallGuardConductorTests.requireScratchHome()
        let prompt = BrainPrompt.systemPrompt()
        #expect(prompt.contains("moe_settings_find"))
        for e in SettingsCatalogue.all { #expect(prompt.contains(e.title), "the prompt lacks “\(e.title)”") }
        let c = Conductor(config: Config())
        let before = BrainPrompt.systemPrompt()
        c.setReplyChime(!c.config.replyChime)
        #expect(BrainPrompt.systemPrompt() == before)
        #expect(!BrainPrompt.systemPrompt(supportsTools: false).contains("moe_settings_find"))
    }

    // MARK: - The bridge

    private func bridge(running: Bool) throws -> (SettingsBridge, Conductor) {
        try StallGuardConductorTests.requireScratchHome()
        var seed = Config()
        seed.replyChime = true
        seed.screenContext = true
        seed.save()
        let c = Conductor(config: seed)
        let b = SettingsBridge(conductor: c)
        b.stepGrace = 0
        b.stepRunning = { running }
        b.log = { _ in }
        return (b, c)
    }

    private func request(_ action: String, _ id: String, _ value: String? = nil) -> SettingsBridge.Request {
        var obj: [String: Any] = ["reply": "/tmp/nowhere", "action": action, "id": id]
        if let value { obj["value"] = value }
        let raw = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        return SettingsBridge.Request(raw)!
    }

    @Test func aChangeInThePersonsTurnIsApplied() async throws {
        let (b, c) = try bridge(running: true)
        let out = await b.answer(request("change", "replyChime", "off"))
        #expect(out["status"] as? String == "ok")
        #expect(out["was"] as? String == "on" && out["now"] as? String == "off")
        #expect(c.config.replyChime == false)
        #expect(Config.load().replyChime == false)
    }

    @Test func noStepNoChange() async throws {
        let (b, c) = try bridge(running: false)
        let out = await b.answer(request("change", "replyChime", "off"))
        #expect(out["status"] as? String == "refused")
        #expect(c.config.replyChime == true)
    }

    @Test func thePersonsSwitchIsNeverChangedWhateverTheRequestSays() async throws {
        let (b, c) = try bridge(running: true)
        let out = await b.answer(request("change", "screenContext", "off"))
        #expect(out["status"] as? String == "refused")
        #expect(c.config.screenContext == true)
    }

    @Test func aValueTheSettingDoesNotTakeChangesNothing() async throws {
        let (b, c) = try bridge(running: true)
        let out = await b.answer(request("change", "replyChime", "loud"))
        #expect(out["status"] as? String == "refused")
        #expect(c.config.replyChime == true)
    }

    @Test func showOpensThePageWithTheRowLit() async throws {
        let (b, _) = try bridge(running: true)
        var opened: [(MainWindow.Section, String)] = []
        b.open = { opened.append(($0, $1)) }
        let out = await b.answer(request("show", "screenContext"))
        #expect(out["status"] as? String == "ok")
        #expect(opened.count == 1 && opened.first?.0 == .permissions)
        #expect(opened.first?.1 == "Moe sees my screen when I ask")

        let (quiet, _) = try bridge(running: false)
        var none: [(MainWindow.Section, String)] = []
        quiet.open = { none.append(($0, $1)) }
        _ = await quiet.answer(request("show", "screenContext"))
        #expect(none.isEmpty)
    }

    @Test func malformedRequestsAreNotRequests() {
        #expect(SettingsBridge.Request(#"{"reply":"/tmp/p","action":"delete","id":"x"}"#) == nil)
        #expect(SettingsBridge.Request(#"{"reply":"relative","action":"show","id":"x"}"#) == nil)
        #expect(SettingsBridge.Request(#"{"reply":"/tmp/p","action":"show"}"#) == nil)
        #expect(SettingsBridge.Request("not json") == nil)
    }

    @Test func theSpotlightOpensWhatTheRowIsBehind() {
        #expect(SettingSpotlight.under("Ding when a written answer is ready") == "More")
        #expect(SettingSpotlight.under("How much Moe says") == nil)
        #expect(SettingsBridge.isSettingsTool("mcp__moe__moe_settings_change"))
        #expect(!SettingsBridge.isSettingsTool("moe_settings_find"))
    }
}
