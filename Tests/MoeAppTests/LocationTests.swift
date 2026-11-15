import Foundation
import Testing
import MoeBrain
@testable import Moe

/// `moe_location`, the app's half: where this Mac is, with permission, asked
/// for on first need, rounded, never guessed, never kept.
///
/// CoreLocation is behind `LocationProvider`; every test here injects its own
/// fixes and refusals, so none can raise macOS's question or read where this
/// Mac really is. The coordinates are invented (a point in Lakewood, NJ, and
/// one in Jerusalem) and are what the log assertions look for.
@MainActor
@Suite(.serialized)
struct LocationTests {

    final class FakeProvider: LocationProvider {
        var services = true
        var authorization: LocationAuthorization = .authorized
        /// What the person does with macOS's question, when one is up.
        var decision: LocationAuthorization = .notDetermined
        var fixes: [LocationFix?] = []
        var names: [PlaceName?] = [LocationTests.lakewood]
        var requests = 0
        var waits = 0
        var fixCalls = 0
        var geocoded: [(Double, Double)] = []

        func servicesEnabled() async -> Bool { services }
        func requestAuthorization() { requests += 1 }
        func waitForDecision(timeout: TimeInterval) async -> LocationAuthorization {
            waits += 1
            authorization = decision
            return authorization
        }
        func fix(timeout: TimeInterval) async -> LocationFix? {
            fixCalls += 1
            return fixes.isEmpty ? nil : fixes.removeFirst()
        }
        func place(latitude: Double, longitude: Double) async -> PlaceName? {
            geocoded.append((latitude, longitude))
            return names.count > 1 ? names.removeFirst() : names.first ?? nil
        }
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    final class Lines { var all: [String] = []; var text: String { all.joined(separator: "\n") } }

    static let lakewood = PlaceName(city: "Lakewood", region: "NJ", country: "United States",
                                    countryCode: "US", timeZone: "America/New_York")
    static let lat = 40.082117, lon = -74.209683

    static func make(_ setUp: (FakeProvider) -> Void = { _ in })
        -> (LocationService, FakeProvider, Clock, Lines) {
        let provider = FakeProvider()
        let clock = Clock(), lines = Lines()
        provider.fixes = [fix(at: clock.now)]
        setUp(provider)
        let service = LocationService(provider: provider)
        service.now = { clock.now }
        service.log = { lines.all.append($0) }
        return (service, provider, clock, lines)
    }

    static func fix(at: Date, lat: Double = lat, lon: Double = lon, accuracy: Double = 65) -> LocationFix {
        LocationFix(latitude: lat, longitude: lon, accuracy: accuracy, at: at)
    }

    // MARK: - Allowed

    @Test func allowedGivesTheTownAndCoordinatesRoundedToAboutAKilometre() async throws {
        let (service, provider, _, _) = Self.make()
        let json = await service.answer().json
        #expect(json["status"] as? String == "ok")
        #expect(json["city"] as? String == "Lakewood")
        #expect(json["region"] as? String == "NJ")
        #expect(json["country"] as? String == "United States")
        #expect(json["time_zone"] as? String == "America/New_York")
        #expect(json["latitude"] as? Double == 40.08)
        #expect(json["longitude"] as? Double == -74.21)
        #expect(json["precision"] as? String == "rounded to about 1 km")
        #expect(json["accuracy_m"] as? Int == 65)
        #expect(json["age_s"] as? Int == 0)
        #expect(json["stale"] == nil)
        #expect((json["source"] as? String)?.contains("not the internet connection") == true)
        // Nothing asked: it was already allowed.
        #expect(provider.requests == 0)
        // The town's name is looked up from the rounded pair, never the street.
        #expect(provider.geocoded.count == 1)
        #expect(provider.geocoded.first?.0 == 40.08 && provider.geocoded.first?.1 == -74.21)
        // And nothing in the whole answer carries the unrounded numbers.
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        // (JSONSerialization writes -74.21 as -74.2099999…, the same number.)
        #expect(!text.contains("40.0821") && !text.contains("74.2096"))
    }

    @Test func preciseIsExactOnlyWhenAskedFor() async {
        let (service, _, _, _) = Self.make()
        let json = await service.answer(precise: true).json
        #expect(json["latitude"] as? Double == 40.08212)
        #expect(json["longitude"] as? Double == -74.20968)
        #expect(json["precision"] as? String == "exact")
    }

    // MARK: - Not allowed: a plain sentence, never a guess

    @Test func deniedIsAPlainRefusalAndNeverTouchesTheRadio() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .denied }
        let answer = await service.answer()
        #expect(answer == .denied)
        let json = answer.json
        #expect(json["status"] as? String == "denied")
        let say = json["say"] as? String ?? ""
        #expect(say.contains("Location is switched off for Memoe on this Mac"))
        #expect(say.contains("Location Services"))
        #expect(say.contains("Do not guess"))
        #expect(say.contains("say that is what you used"))
        #expect(json["latitude"] == nil && json["city"] == nil)
        #expect(provider.fixCalls == 0 && provider.requests == 0 && provider.geocoded.isEmpty)
    }

    @Test func locationServicesOffForTheWholeMacSaysSoAndAsksNothing() async {
        let (service, provider, _, _) = Self.make { $0.services = false; $0.authorization = .notDetermined }
        let answer = await service.answer()
        #expect(answer == .servicesOff)
        #expect(answer.sentence?.contains("switched off for this whole Mac") == true)
        #expect(provider.requests == 0 && provider.fixCalls == 0)
    }

    @Test func restrictedSaysThePersonCannotSwitchItOn() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .restricted }
        let answer = await service.answer()
        #expect(answer == .restricted)
        #expect(answer.sentence?.contains("restricted") == true)
        #expect(provider.fixCalls == 0)
    }

    @Test func everyAnswerWithoutAPlaceHasASentenceAndNoCoordinates() {
        for answer in [LocationAnswer.servicesOff, .denied, .restricted, .asked, .unavailable, .refused] {
            let json = answer.json
            #expect((json["say"] as? String)?.isEmpty == false, "\(answer)")
            #expect(Set(json.keys) == ["status", "say"], "\(answer)")
        }
    }

    // MARK: - Not asked yet: asked once, on first need

    @Test func undeterminedAsksOnceAndWaitsOnTheSameQuestionAfterThat() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .notDetermined }
        // The question goes up; the person has not answered when the wait ends.
        let first = await service.answer()
        #expect(first == .asked)
        #expect(first.sentence?.contains("click Allow") == true)
        #expect(provider.requests == 1)
        #expect(provider.fixCalls == 0, "no fix before a yes")
        // Called again while it is still up: no second question.
        #expect(await service.answer() == .asked)
        #expect(provider.requests == 1)
        #expect(provider.waits == 2)
        // They click Allow: the next call has the place, and still asked once.
        provider.decision = .authorized
        #expect((await service.answer().json)["city"] as? String == "Lakewood")
        #expect(provider.requests == 1)
    }

    @Test func allowingAtTheQuestionAnswersInTheSameCall() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .notDetermined; $0.decision = .authorized }
        #expect((await service.answer().json)["status"] as? String == "ok")
        #expect(provider.requests == 1)
    }

    @Test func decliningAtTheQuestionIsTheRefusal() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .notDetermined; $0.decision = .denied }
        #expect(await service.answer() == .denied)
        #expect(provider.requests == 1 && provider.fixCalls == 0)
    }

    // MARK: - Fresh, refreshed, stale

    @Test func aRecentFixAnswersWithItsAgeAndWithoutAskingAgain() async {
        let (service, provider, clock, _) = Self.make()
        _ = await service.answer()
        clock.now += 240
        let json = await service.answer().json
        #expect(json["age_s"] as? Int == 240)
        #expect(json["stale"] == nil)
        #expect(provider.fixCalls == 1 && provider.geocoded.count == 1)
    }

    @Test func anOldFixIsRefreshed() async {
        let (service, provider, clock, _) = Self.make()
        _ = await service.answer()
        clock.now += 1200
        // They have travelled: a new fix, a new town.
        provider.fixes = [Self.fix(at: clock.now, lat: 31.778, lon: 35.2354)]
        provider.names = [PlaceName(city: "Jerusalem", region: nil, country: "Israel",
                                    countryCode: "IL", timeZone: "Asia/Jerusalem")]
        let json = await service.answer().json
        #expect(provider.fixCalls == 2)
        #expect(json["city"] as? String == "Jerusalem")
        #expect(json["age_s"] as? Int == 0)
        #expect(json["stale"] == nil)
    }

    @Test func anOldFixThatCannotBeRefreshedIsGivenMarkedWithItsAge() async {
        let (service, provider, clock, _) = Self.make()
        _ = await service.answer()
        clock.now += 1200
        provider.fixes = []                     // the radio has nothing now
        let json = await service.answer().json
        #expect(provider.fixCalls == 2, "it tried")
        #expect(json["status"] as? String == "ok")
        #expect(json["city"] as? String == "Lakewood")
        #expect(json["stale"] as? Bool == true)
        #expect(json["age_s"] as? Int == 1200)
        #expect((json["note"] as? String)?.contains("20 minutes old") == true)
    }

    @Test func preciseWantsAFixNoOlderThanAMinute() async {
        let (service, provider, clock, _) = Self.make()
        _ = await service.answer()
        clock.now += 240
        provider.fixes = [Self.fix(at: clock.now)]
        _ = await service.answer(precise: true)
        #expect(provider.fixCalls == 2)
        // Same square kilometre: the town is not looked up a second time.
        #expect(provider.geocoded.count == 1)
    }

    @Test func allowedButNoFixSaysSoRatherThanGuessing() async {
        let (service, _, _, _) = Self.make { $0.fixes = [] }
        let answer = await service.answer()
        #expect(answer == .unavailable)
        #expect(answer.sentence?.contains("could not work out where it is") == true)
    }

    @Test func aFixWithNoTownNameSaysItIsCoordinatesOnly() async {
        let (service, _, _, _) = Self.make { $0.names = [nil] }
        let json = await service.answer().json
        #expect(json["city"] == nil)
        #expect(json["latitude"] as? Double == 40.08)
        #expect((json["note"] as? String)?.contains("coordinates only") == true)
    }

    // MARK: - The log never says where

    @Test func noLogLineCarriesACoordinateOrAPlaceName() async {
        let (service, provider, clock, lines) = Self.make { $0.authorization = .notDetermined }
        _ = await service.answer()                         // asked
        provider.decision = .authorized
        _ = await service.answer()                         // fix
        _ = await service.answer(precise: true)            // exact
        clock.now += 1200
        provider.fixes = []
        _ = await service.answer()                         // stale
        provider.authorization = .denied
        _ = await service.answer()                         // denied
        provider.services = false
        _ = await service.answer()                         // services off

        #expect(lines.all.count == 7, "\(lines.all)")
        #expect(lines.all.contains("location: asked macOS for permission (first need)"))
        #expect(lines.all.contains("location: fix, accuracy 65 m, age 0 s, rounded, town named"))
        #expect(lines.all.contains("location: fix, accuracy 65 m, age 0 s, exact, town named"))
        #expect(lines.all.contains("location: stale fix, accuracy 65 m, age 1200 s, rounded, town named"))
        #expect(lines.all.contains("location: no place given — denied"))
        for secret in ["40.08", "40.1", "74.2", "-74", "Lakewood", "NJ", "United States", "New_York", "America"] {
            #expect(!lines.text.contains(secret), "the log says where: \(secret) in \(lines.all)")
        }
    }

    // MARK: - The bridge: who may ask

    @Test func aRequestIsAPipePathAndAFlagAndNothingElse() {
        #expect(LocationBridge.Request(#"{"reply": "/tmp/x/reply", "precise": true}"#)
                == LocationBridge.Request(#"{"precise": true, "reply": "/tmp/x/reply"}"#))
        #expect(LocationBridge.Request(#"{"reply": "/tmp/x/reply"}"#)?.precise == false)
        #expect(LocationBridge.Request(#"{"reply": "/tmp/x/reply", "precise": "yes"}"#)?.precise == false)
        for bad in ["", "Privacy_AllFiles", "/tmp/x/reply", #"{"reply": "relative/reply"}"#,
                    #"{"reply": 3}"#, #"["/tmp/x"]"#,
                    #"{"reply": "/"# + String(repeating: "a", count: 3000) + #""}"#] {
            #expect(LocationBridge.Request(bad) == nil, "\(bad.prefix(40))")
        }
    }

    @Test func aSignalWithNoStepInThePersonsTurnGetsNoPlaceAndRaisesNoQuestion() async {
        let (service, provider, _, _) = Self.make { $0.authorization = .notDetermined; $0.decision = .authorized }
        let bridge = LocationBridge()
        let lines = Lines()
        bridge.service = service
        bridge.log = { lines.all.append($0) }
        bridge.stepGrace = 0.2
        // Any process on this Mac can post the signal.
        #expect(await bridge.answer(precise: true) == .refused)
        #expect(provider.requests == 0 && provider.fixCalls == 0 && provider.waits == 0)
        #expect(lines.all == ["location: refused — no moe_location step in a turn of the person's"])
        // The step is running: the same request is answered.
        bridge.stepRunning = { true }
        #expect((await bridge.answer(precise: false).json)["city"] as? String == "Lakewood")
    }

    @Test func theSignalMayArriveAMomentBeforeTheStep() async {
        let (service, _, _, _) = Self.make()
        let bridge = LocationBridge()
        bridge.service = service
        bridge.log = { _ in }
        var polls = 0
        bridge.stepRunning = { polls += 1; return polls > 3 }
        #expect((await bridge.answer(precise: false).json)["status"] as? String == "ok")
    }

    @Test func theConductorCountsOnlyALocationStepInThePersonsOwnTurn() async throws {
        let (moe, brain) = try FixCardConductorTests.make()
        let (service, provider, _, _) = Self.make()
        moe.location.service = service
        moe.location.log = { _ in }
        moe.location.stepGrace = 0.1
        moe.location.stepRunning = { [weak moe] in moe?.locationStepRunning ?? false }
        func step(_ name: String, id: String) {
            brain.emit(.toolStarted(name: name, id: id, emoji: nil, detail: "", spoken: nil))
        }

        // Nobody's turn in flight.
        #expect(!moe.locationStepRunning)
        #expect(await moe.location.answer(precise: false) == .refused)

        // A background turn, even with the step running in it.
        moe.submit("Something you handed off just finished.", origin: .spoken, starter: .background,
                   outgoing: "(Background note, not from the user.)")
        try await brain.waitForSends(1)
        step("mcp__hermes__moe_location", id: "toolu_bg")
        #expect(!moe.locationStepRunning)
        #expect(await moe.location.answer(precise: false) == .refused)
        brain.reply("Done.", end: .answered)

        // The person's turn, but some other step (the model's shell).
        moe.submit("what's the weather?", origin: .typed, starter: .person)
        try await brain.waitForSends(2)
        step("terminal", id: "toolu_sh")
        step("mcp__hermes__moe_open_settings", id: "toolu_open")
        #expect(!moe.locationStepRunning)
        #expect(await moe.location.answer(precise: false) == .refused)
        #expect(provider.fixCalls == 0)

        // The person's turn with the location step running.
        step("mcp__hermes__moe_location", id: "toolu_loc")
        #expect(moe.locationStepRunning)
        #expect((await moe.location.answer(precise: false).json)["city"] as? String == "Lakewood")

        // The turn is over: nothing more.
        brain.reply("Sunny, 24 degrees in Lakewood.", end: .answered)
        #expect(!moe.locationStepRunning)
    }

    @Test func theToolIsKnownByItsBareAndItsBridgedName() {
        #expect(LocationBridge.isLocationTool("moe_location"))
        #expect(LocationBridge.isLocationTool("mcp__hermes__moe_location"))
        #expect(!LocationBridge.isLocationTool("moe_open_settings"))
        #expect(!LocationBridge.isLocationTool("moe_location_history"))
    }

    // MARK: - The reply goes down a private pipe and nowhere else

    @Test func theReplyIsWrittenOnlyIntoAPrivatePipe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moe-loc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = Data("{\"status\":\"ok\"}\n".utf8)

        // A regular file is refused and left exactly as it was.
        let file = dir.appendingPathComponent("file").path
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: file))
        chmod(file, 0o600)
        #expect(!LocationBridge.write(line, toPipe: file))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "untouched")
        // Nothing is ever created.
        let missing = dir.appendingPathComponent("missing").path
        #expect(!LocationBridge.write(line, toPipe: missing))
        #expect(!FileManager.default.fileExists(atPath: missing))
        // A link to a pipe is not followed.
        let pipe = dir.appendingPathComponent("reply").path
        #expect(mkfifo(pipe, 0o600) == 0)
        let reader = open(pipe, O_RDWR | O_NONBLOCK)
        defer { close(reader) }
        let link = dir.appendingPathComponent("link").path
        #expect(symlink(pipe, link) == 0)
        #expect(!LocationBridge.write(line, toPipe: link))
        // A pipe others could read is refused.
        let open_ = dir.appendingPathComponent("shared").path
        #expect(mkfifo(open_, 0o600) == 0)
        chmod(open_, 0o644)
        let sharedReader = open(open_, O_RDWR | O_NONBLOCK)
        defer { close(sharedReader) }
        #expect(!LocationBridge.write(line, toPipe: open_))

        // The private pipe gets the whole line.
        #expect(LocationBridge.write(line, toPipe: pipe))
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(reader, &buf, buf.count)
        #expect(n == line.count)
        #expect(Data(buf.prefix(max(n, 0))) == line)
    }

    // MARK: - The rule, the row, the bundle

    @Test func theRuleIsInTheStablePromptAndOnlyWhereThereAreTools() {
        let prompt = BrainPrompt.systemPrompt()
        #expect(prompt.contains(BrainPrompt.locationRule))
        #expect(BrainPrompt.locationRule.contains("moe_location"))
        #expect(BrainPrompt.locationRule.contains("say that is what you used"))
        #expect(prompt == BrainPrompt.systemPrompt(), "stable: the same text every turn")
        #expect(!BrainPrompt.systemPrompt(supportsTools: false).contains("moe_location"))
    }

    @Test func theSettingsRowSaysAllFourThingsAndOpensLocationServices() {
        let guide = PermissionGuide.location
        for field in [guide.name, guide.what, guide.ifDeclined, guide.steps] { #expect(!field.isEmpty) }
        #expect(guide.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        #expect(guide.ifDeclined.hasPrefix("Moe keeps working"))
        #expect(PermRow.short(guide.what, id: guide.id)
                == "To know which town you're in for the weather, “near me” and directions.")
        // Asked on first need: never in the welcome's list.
        #expect(!PermissionGuide.all.contains { $0.id == guide.id })
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theBundleCarriesTheUsageStringAndTheEntitlement() throws {
        let build = try String(contentsOf: Self.root.appendingPathComponent("build.sh"), encoding: .utf8)
        let usage = "Moe uses this Mac’s location to answer when you ask something that depends on where you are, like the weather or what’s nearby. Only when you ask, never in the background."
        for key in ["NSLocationWhenInUseUsageDescription", "NSLocationUsageDescription"] {
            #expect(build.contains("<key>\(key)</key>\n  <string>\(usage)</string>"), "\(key)")
        }
        // Under Hardened Runtime macOS refuses location, with no prompt, without this.
        let entitlements = try #require(NSDictionary(contentsOf:
            Self.root.appendingPathComponent("scripts/Moe.entitlements")))
        #expect(entitlements["com.apple.security.personal-information.location"] as? Bool == true)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
    }

    @Test func nothingInTheAppKeepsOrSendsThePlace() throws {
        // The three files that ever hold a fix: no file write, no defaults,
        // no network client, no memory tool.
        for name in ["LocationService.swift", "LocationBridge.swift", "CoreLocationProvider.swift"] {
            let src = try String(contentsOf: Self.root.appendingPathComponent("Sources/Moe/Location/\(name)"),
                                 encoding: .utf8)
            for word in ["UserDefaults", "URLSession", "write(to:", "FileHandle", "Config.update", "O_CREAT"] {
                #expect(!src.contains(word), "\(name) uses \(word)")
            }
        }
    }
}
