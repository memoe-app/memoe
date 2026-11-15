import Foundation
import Testing
@testable import Moe

/// docs/DEFAULTS.md slices 4 and 13 — what a fresh Moe's welcome recommends,
/// and what it pushes first:
///
///   row 1   both plan sign-ins recommended, equally
///   row 24  the learn step recommended on: the pass and every source ticked,
///           Save untouched is an answer, Skip is not
///   row 25  asked again, once, the first time a source is connected
///   row 33  Accessibility and Screen Recording asked on "Say hello"
///   row 34  the Mac's four apps, then Google, then everything else
///   row 40  all of it folded in: still seven screens

private func source(_ name: String, _ state: BackgroundLearning.State,
                    connected: Bool = true) -> BackgroundLearning.Source {
    .init(name: name, state: state, connected: connected, label: name.capitalized, reads: "your \(name)")
}

private func connection(_ id: String) -> Connection {
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    return Connection(id: id, kind: Connection.Kind(rawValue: parts[0]) ?? .mcp, name: parts[1],
                      label: parts[1].capitalized, blurb: "", authKind: .oauth, state: .notConnected,
                      detail: "", envKeys: [], allowedUsersKey: "", prompts: [:], docs: "",
                      connectName: parts[1], setupScript: "")
}

/// A Mac row as `MacSources.connection` builds one.
private func macRow(_ name: String, auth: Connection.AuthKind, state: Connection.State) -> Connection {
    Connection(id: "mac/\(name)", kind: .mac, name: name, label: name.capitalized, blurb: "",
               authKind: auth, state: state, detail: "", envKeys: [], allowedUsersKey: "", prompts: [:],
               docs: "", connectName: "", setupScript: "")
}

/// Every consent.sh call a flow asks for, without running it.
private final class ConsentCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ call: [String]) { lock.lock(); recorded.append(call); lock.unlock() }
}

/// A ConnectFlow that can launch nothing: every script, status check and
/// consent write is replaced (as in ConnectFlowTests.swift).
@MainActor
private func sealedFlow(consentStatus: Int32 = 0) -> (ConnectFlow, ConsentCalls) {
    let flow = ConnectFlow()
    let calls = ConsentCalls()
    flow.locateScript = { "/nonexistent/moe-app-tests/\($0)" }
    flow.launchScript = { _, _, _, _, _, _, _, _ in
        ScriptRunner.Result(status: 1, output: "", timedOut: false)
    }
    flow.checkConnected = { _ in false }
    flow.runConsent = { verb, name in
        calls.record([verb, name])
        return ScriptRunner.Result(status: consentStatus, output: "", timedOut: false)
    }
    return (flow, calls)
}

@MainActor
private func settled(_ flow: ConnectFlow, seconds: TimeInterval = 60) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        switch flow.phase {
        case .done, .failed: return true
        default: try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    return false
}

struct OnboardingDefaultsTests {

    // MARK: Row 1

    @Test("both plans are recommended, equally, and nothing else is")
    func bothPlansRecommended() {
        let recommended = Set(BrainGuide.all.filter(\.isRecommended).map(\.kind))
        #expect(recommended == [.claudeCode, .codex])
        // A pair, at the top, both badged; a key and this Mac below, unbadged.
        #expect(BrainPath.all.prefix(2).map(\.id) == [BrainPath.claude.id, BrainPath.chatgpt.id])
        #expect(BrainPath.all.filter(\.recommended).map(\.id) == [BrainPath.claude.id, BrainPath.chatgpt.id])
        #expect(!BrainPath.key.recommended)
        #expect(!BrainPath.onThisMac.recommended)
    }

    // MARK: Row 24

    @Test("the learn step starts recommended: the pass on and every offered source on")
    @MainActor func learnStartsOn() {
        let model = LearnStepModel(posed: OnboardingView.posedLearnSources, recommend: true)
        model.load()
        #expect(model.loaded)
        #expect(!model.rows.isEmpty)
        #expect(model.pass)
        #expect(model.ticked == Set(model.rows.map(\.id)))
        #expect(model.hasChoice)
    }

    @Test("the Memory page's sheet asks the same question without pre-ticking anything")
    @MainActor func memorySheetDoesNotRecommend() {
        let model = LearnStepModel(posed: OnboardingView.posedLearnSources)
        model.load()
        #expect(!model.rows.isEmpty)
        // Only what the file already says yes to starts ticked.
        #expect(model.ticked == Set(model.rows.filter(\.on).map(\.id)))
        let welcome = LearnStepModel(posed: OnboardingView.posedLearnSources, recommend: true)
        welcome.load()
        #expect(model.ticked.isSubset(of: welcome.ticked))
    }

    @Test("the welcome's problem-report row uses the one audited text and offers anonymity")
    func reportsRowUsesTheAuditedText() throws {
        let source = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/MoeAppTests/OnboardingDefaultsTests.swift",
                                  with: "Sources/Moe/Onboarding/OnboardingWindow.swift"), encoding: .utf8)
        // The words come from the one place Settings › Privacy reads too
        // (`ProblemReportsLink`), never a copy written here.
        #expect(source.contains("small(reports.disclosure)"))
        #expect(source.contains("reports.anonymousTitle"))
        #expect(!source.contains("SLICE9"))
    }

    @Test("Save with nothing touched records every source and the daily pass")
    @MainActor func saveUntouchedWrites() {
        let model = LearnStepModel(posed: OnboardingView.posedLearnSources, recommend: true)
        model.load()
        let writes = model.writes
        #expect(writes.allSatisfy { $0.on })
        #expect(writes.map { $0.name } == model.rows.flatMap(\.names) + [BackgroundLearning.source])
    }

    @Test("Skip records nothing, and a source already refused is not pre-ticked")
    func skipWritesNothing() {
        let fresh = [source("calendar", .unset), source("notes", .unset)]
        // Skip never reaches the writer; nothing ticked is nothing written.
        #expect(BackgroundLearning.stepWrites(rows: BackgroundLearning.rows(fresh), ticked: [],
                                              pass: true, passState: .unset).isEmpty)

        let withANo = [source("calendar", .unset), source("notes", .refused), source("imessage", .granted)]
        let ticks = BackgroundLearning.recommendedTicks(withANo)
        #expect(ticks == ["calendar", "imessage"])
        let writes = BackgroundLearning.stepWrites(rows: BackgroundLearning.rows(withANo), ticked: ticks,
                                                   pass: true, passState: .unset)
        // Save untouched can never turn an old no into a yes.
        #expect(!writes.contains { $0.name == "notes" })
        #expect(writes.map { $0.name } == ["calendar", BackgroundLearning.source])
    }

    // MARK: Row 25

    @Test("asked at connect: for an unset source, never for one already answered")
    func connectAsk() throws {
        typealias Ask = BackgroundLearning.ConnectAsk
        // Just connected: the list has not caught up ("connected: false").
        let list = [source("notes", .unset, connected: false), source("calendar", .granted),
                    source("chrome", .refused)]
        let row = try #require(Ask.row(forConnection: ["notes", ""], sources: list, asked: []))
        #expect(row.id == "notes")
        #expect(row.names == ["notes"])
        // Once: a source already asked about is not asked again.
        #expect(Ask.row(forConnection: ["notes"], sources: list, asked: ["notes"]) == nil)
        // Never for a yes, never for a no.
        #expect(Ask.row(forConnection: ["calendar"], sources: list, asked: []) == nil)
        #expect(Ask.row(forConnection: ["chrome"], sources: list, asked: []) == nil)
        // Nothing the daily pass can read: nothing to ask.
        #expect(Ask.row(forConnection: ["gmail"], sources: list, asked: []) == nil)
        #expect(Ask.row(forConnection: [""], sources: list, asked: []) == nil)

        // A Hermes connection has two answers; both must still be unset.
        let half = [source("watch:linear", .unset), source("linear", .granted)]
        #expect(Ask.row(forConnection: ["linear"], sources: half, asked: []) == nil)
        let both = [source("watch:linear", .unset), source("linear", .unset)]
        let linear = try #require(Ask.row(forConnection: ["linear"], sources: both, asked: []))
        #expect(Set(linear.names) == ["watch:linear", "linear"])

        // Yes: every answer the connection has, and the pass only when unset.
        #expect(Ask.writes(for: linear, passState: .unset).map { $0.name }
                == linear.names + [BackgroundLearning.source])
        #expect(Ask.writes(for: linear, passState: .unset).allSatisfy { $0.on })
        #expect(Ask.writes(for: linear, passState: .refused).map { $0.name } == linear.names)
        #expect(Ask.writes(for: linear, passState: .granted).map { $0.name } == linear.names)
    }

    /// A service Composio brokers is a source like any other. The names
    /// ConnectionsView hands over are the row's `name` and `connectName`,
    /// which for a brokered row are the slug and the full id
    /// (ConnectionsModel: `name: name, … connectName: id`) — so the question
    /// has to find the row under the slug. Until 2026-09-20 no brokered
    /// service was in the list at all (learn/consent_list.py kept only
    /// `kind == "mcp"` rows), so connecting GitHub asked nothing at all;
    /// this holds the seam that fix lands on.
    @Test("asked at connect for a service Composio brokers, under its slug")
    func connectAskForABrokeredService() throws {
        typealias Ask = BackgroundLearning.ConnectAsk
        let list = [source("watch:github", .unset, connected: false),
                    source("github", .unset, connected: false),
                    source("calendar", .granted)]
        let names = ["github", "composio/github"]
        let row = try #require(Ask.row(forConnection: names, sources: list, asked: []))
        #expect(row.id == "github")
        #expect(Set(row.names) == ["watch:github", "github"])
        // Yes says yes to the connection AND turns the daily pass on — the
        // two halves of the offer: read it back once, then keep up with it.
        #expect(Ask.writes(for: row, passState: .unset).map { $0.name }
                == row.names + [BackgroundLearning.source])
        // Once per service, like any other.
        #expect(Ask.row(forConnection: names, sources: list, asked: ["github"]) == nil)
    }

    /// The ask fires from `justConnected`. Calendar, Reminders and Notes are
    /// macOS permissions: no script, no sheet, no `succeed()`. The grant is
    /// known when the list reads the row connected again.
    @Test("asked at connect for a Mac permission: a grant the person was sent for sets justConnected, once")
    @MainActor func connectAskAfterAPermissionGrant() {
        let (flow, _) = sealedFlow()
        var calendar = macRow("calendar", auth: .macPermission, state: .needsAttention)
        flow.awaitPermission(calendar)
        flow.permissionsChecked([calendar])
        #expect(flow.justConnected == nil, "not granted yet")

        calendar.state = .connected
        flow.permissionsChecked([calendar])
        #expect(flow.justConnected?.id == "mac/calendar")

        // Once: the next read of the list is not a second connect.
        flow.justConnected = nil
        flow.permissionsChecked([calendar])
        #expect(flow.justConnected == nil)

        // A row nobody was sent to grant is not a connect, however it reads.
        flow.permissionsChecked([macRow("reminders", auth: .macPermission, state: .connected)])
        #expect(flow.justConnected == nil)
        // Nor is one that was already connected when the button was pressed.
        let notes = macRow("notes", auth: .macPermission, state: .connected)
        flow.awaitPermission(notes)
        flow.permissionsChecked([notes])
        #expect(flow.justConnected == nil)
    }

    @Test("asked at connect for an opt-in source: switching it on sets justConnected; off or a refusal does not")
    @MainActor func connectAskAfterConsent() async {
        let chrome = macRow("chrome", auth: .consent, state: .notConnected)

        let (flow, calls) = sealedFlow()
        flow.setConsent(chrome, on: true)
        #expect(await settled(flow))
        guard case .done = flow.phase else { Issue.record("on went to \(flow.phase)"); return }
        #expect(calls.calls == [["grant", "chrome"]])
        #expect(flow.justConnected?.id == "mac/chrome")

        flow.justConnected = nil
        flow.setConsent(chrome, on: false)
        #expect(await settled(flow))
        #expect(calls.calls.last == ["revoke", "chrome"])
        #expect(flow.justConnected == nil)

        let (refused, _) = sealedFlow(consentStatus: 1)
        refused.setConsent(chrome, on: true)
        #expect(await settled(refused))
        guard case .failed = refused.phase else { Issue.record("refusal went to \(refused.phase)"); return }
        #expect(refused.justConnected == nil)
    }

    @Test("the marker remembers a source once it has been asked about")
    func connectAskMarker() {
        typealias Ask = BackgroundLearning.ConnectAsk
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-connect-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(Ask.asked(home: home).isEmpty)
        Ask.markAsked("notes", home: home)
        Ask.markAsked("notes", home: home)
        Ask.markAsked("linear", home: home)
        #expect(Ask.asked(home: home) == ["notes", "linear"])
        #expect(Ask.row(forConnection: ["notes"], sources: [source("notes", .unset)],
                        asked: Ask.asked(home: home)) == nil)
    }

    @Test("Not now asks once more a week later, then never; a bare legacy line is one ask long ago")
    func connectAskAgainInAWeek() throws {
        typealias Ask = BackgroundLearning.ConnectAsk
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-connect-again-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day0 = ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z")!
        Ask.markAsked("notes", home: home, now: day0)
        #expect(Ask.asked(home: home, now: day0.addingTimeInterval(6 * 86400)) == ["notes"], "not before a week")
        #expect(Ask.asked(home: home, now: day0.addingTimeInterval(8 * 86400)).isEmpty, "due again after a week")
        Ask.markAsked("notes", home: home, now: day0.addingTimeInterval(8 * 86400))
        #expect(Ask.asked(home: home, now: day0.addingTimeInterval(400 * 86400)) == ["notes"], "twice is the last")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "linear\n".write(to: Ask.markerURL(home: home), atomically: true, encoding: .utf8)
        #expect(Ask.asked(home: home, now: day0).isEmpty, "the old file's line: asked once, long ago")
        Ask.markAsked("linear", home: home, now: day0)
        #expect(Ask.record(home: home)["linear"]?.times == 2)
    }

    @Test("the launch ask: a connected source nobody answered and that is due; never an answered one")
    func pendingAsk() {
        typealias Ask = BackgroundLearning.ConnectAsk
        let list = [source("gmail", .granted), source("mail", .refused), source("notes", .unset),
                    source("calendar", .unset), source("drive", .unset, connected: false)]
        #expect(Ask.pending(sources: list, asked: [])?.id == "notes")
        #expect(Ask.pending(sources: list, asked: ["notes"])?.id == "calendar")
        #expect(Ask.pending(sources: list, asked: ["notes", "calendar"]) == nil, "not connected is not asked")
        #expect(Ask.pending(sources: nil, asked: []) == nil)
    }

    @Test("the launch question asks about every unanswered source at once, in words")
    func pendingAllAtOnce() {
        typealias Ask = BackgroundLearning.ConnectAsk
        let list = [source("calendar", .unset), source("notes", .unset), source("mail", .unset),
                    source("gmail", .granted)]
        #expect(Ask.pendingAll(sources: list, asked: ["notes"]).map(\.id) == ["calendar", "mail"])
        #expect(Ask.listed(["Calendar"]) == "Calendar")
        #expect(Ask.listed(["Calendar", "Notes", "Mail"]) == "Calendar, Notes and Mail")
        #expect(LearnStepCopy.askTitleMany(3) == "Let Moe learn from these 3 and watch them for things you'd want help with?")
        #expect(LearnStepCopy.askBodyMany("Calendar, Notes and Mail").hasPrefix("Calendar, Notes and Mail. Moe reads"))
    }

    @Test("asked twice in one day is one ask, so the week-later ask still comes")
    func sameDayOnce() {
        typealias Ask = BackgroundLearning.ConnectAsk
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("moe-connect-sameday-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let day0 = ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z")!
        Ask.markAsked("notes", home: home, now: day0)
        Ask.markAsked("notes", home: home, now: day0.addingTimeInterval(60))
        #expect(Ask.record(home: home)["notes"]?.times == 1)
        #expect(Ask.asked(home: home, now: day0.addingTimeInterval(8 * 86400)).isEmpty)
    }

    @Test("the question says learn and watch, and that nothing is sent")
    func askWords() {
        #expect(LearnStepCopy.askTitle("Notes") == "Let Moe learn from Notes and watch it for things you'd want help with?")
        #expect(LearnStepCopy.askBody("your notes").contains("Nothing is ever sent unless you say so"))
        #expect(LearnStepCopy.askDetail.contains("Not now asks again in a week"))
        #expect(BackgroundLearning.Words.row("Gmail") == "Learn from Gmail and watch it")
    }

    // MARK: Row 33

    @Test("Say hello says why, in one plain line each")
    func permissionLines() {
        #expect(Onboarding.accessibilityWhy.contains("talk key"))
        // Not "click for you": that is CuaDriver's switch, not Memoe's
        // (FirstRunPermissionCopyTests).
        #expect(Onboarding.screenHelperNote.contains("CuaDriver"))
        #expect(Onboarding.screenRecordingWhy.contains("see your screen"))
    }

    // MARK: Row 34

    @Test("Connections: the Mac's four, then Google, then the rest")
    func connectionsOrder() {
        let rows = ["mcp/linear", "mac/imessage", "composio/notion", "composio/googledrive", "mac/notes",
                    "composio/gmail", "mac/reminders", "mac/chrome", "composio/googlecalendar",
                    "mac/calendar", "mcp/obscure"].map(connection)
        let ids = ConnectionsCatalog.sections(rows, excludingInbound: true).inOrder.map(\.id)
        func at(_ id: String) -> Int { ids.firstIndex(of: id) ?? Int.max }
        #expect(Array(ids.prefix(3)) == ["mac/calendar", "mac/reminders", "mac/notes"], "\(ids)")
        #expect(Array(ids.dropFirst(3).prefix(3)) == ["composio/gmail", "composio/googlecalendar",
                                                      "composio/googledrive"], "\(ids)")
        for later in ["mac/imessage", "mac/chrome", "composio/notion", "mcp/linear", "mcp/obscure"] {
            #expect(at(later) > at("composio/googledrive"), "\(later) in \(ids)")
        }
        #expect(ConnectionsCatalog.firstMac == ["mac/calendar", "mac/reminders", "mac/notes", "mac/contacts"])
        #expect(ConnectionsCatalog.firstGoogle == ["composio/gmail", "composio/googlecalendar",
                                                   "composio/googledrive"])
    }

    // MARK: Rows 30 and 40

    @Test("still seven screens, and the last one starts Moe with the Mac by default")
    func stillSeven() {
        #expect(Onboarding.Screen.shown.count == (Features.dictation ? 8 : 7))
        #expect(Onboarding.Screen.shown.last == .connect)
        #expect(Config().launchAtLogin)
        #expect(Onboarding.launchAtLoginTitle == "Start Moe when my Mac starts")
        #expect(Onboarding.problemReportsTitle == "Let Moe send problem reports")
    }
}
