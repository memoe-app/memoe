import Foundation
import MoeBrain
import MoeVoice
import Testing
@testable import Moe

/// **Two consecutive ordinary turns must ask for the same brain process.**
///
/// On the plan route the model runs in a child whose system prompt and model
/// are fixed at spawn; a request that names a different one is answered by
/// killing the child and starting another under the turn — 5.9–6.9 s, on 11%
/// of 519 measured turns and 22% in the last month of them
/// (docs/SPEED-FINDINGS-2026-11-12.md). The brief did that for months by
/// being in the system prompt.
///
/// So this drives the real Conductor and builds each turn with the very
/// function `HermesBrain.pumpLocked` builds it with, changes everything that
/// is allowed to change between two turns — the clock, the brief on disk,
/// spoken or typed, the full reminder or the short one, a rebuilt prompt —
/// and requires the launch signature (`LaunchSignature`: the system message,
/// the provider, the model) to stay byte for byte where it was. Then it
/// changes the one thing that IS allowed to move it, and requires that to be
/// seen and named — a check that could not fail would report PASS forever.
///
/// An extension of the Now-line suite because both set `TurnClock.source`,
/// and a serialized suite is what keeps two tests off one global.
extension ConductorNowLineTests {

    @MainActor
    @Test func twoConsecutiveOrdinaryTurnsAskForTheSameBrainProcess() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        brain.sessionID = "one-session"
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.brief.deletingLastPathComponent(), withIntermediateDirectories: true)
        let savedConnections = try? Data(contentsOf: Paths.connections)
        let savedClock = TurnClock.source
        defer {
            TurnClock.source = savedClock
            try? fm.removeItem(at: Paths.brief)
            if let savedConnections { try? savedConnections.write(to: Paths.connections) }
            else { try? fm.removeItem(at: Paths.connections) }
        }
        try "- gmail: connected, two accounts\n".write(to: Paths.connections, atomically: true, encoding: .utf8)

        let endpoint = HermesEndpoint(config: Config())
        let selection = BrainSelection(provider: .claudeCode, model: "sonnet")

        /// One turn, start to finish: what is on disk and on the clock, then
        /// what the Conductor hands the brain, then the request Hermes gets.
        /// The system prompt is rebuilt for EVERY turn — more often than the
        /// app does — so anything volatile that has crept into it shows.
        func turn(_ words: String, _ origin: TurnOrigin, minute: Int, brief: String, sends n: Int) async throws -> URLRequest {
            try brief.write(to: Paths.brief, atomically: true, encoding: .utf8)
            TurnClock.source = { (Self.ticket.addingTimeInterval(Double(minute) * 60), Self.ny) }
            moe.submit(words, origin: origin, starter: .person)
            try await brain.waitForSends(n)
            let sent = try #require(brain.sent.last)
            #expect(sent.text.contains(words))
            let request = HermesBrain.request(
                endpoint: endpoint, sessionID: brain.sessionID,
                system: BrainPrompt.systemPrompt(supportsTools: true, language: "English"),
                brain: selection, text: sent.text, starter: sent.starter, logAs: sent.logAs, spoken: sent.spoken)
            brain.reply("Done.", end: .answered)
            return request
        }
        func brief(_ stamp: String, _ inbound: String) -> String {
            "# Right now\n\n_Refreshed Wednesday 23 September, \(stamp)._\n\n## Inbound (recent)\n\n\(inbound)\n"
        }
        func user(_ request: URLRequest) throws -> String {
            let data = try #require(request.httpBody)
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]]
            return try #require(messages?.last?["content"] as? String)
        }

        let first = try await turn("what is on today", .spoken, minute: 0,
                                   brief: brief("6:07 PM", "Dani|are we still on for two?"), sends: 1)
        let second = try await turn("and write that up as a list", .typed, minute: 11,
                                    brief: brief("6:17 PM", "Dani|are we still on for two?\nDani|running ten late"), sends: 2)
        let third = try await turn("thanks, what else", .spoken, minute: 23,
                                   brief: brief("6:27 PM", "Dani|here now"), sends: 3)

        // The volatile things really did reach the requests…
        let users = try [first, second, third].map(user)
        #expect(users[0].hasPrefix("Now: Wednesday 23 September 2026, 6:08 PM"))
        #expect(users[1].hasPrefix("Now: Wednesday 23 September 2026, 6:19 PM"))
        #expect(users[0].contains("are we still on for two?") && users[0].contains(BrainPrompt.deliveryReminder))
        #expect(users[1].contains("(Typed, not spoken:") && users[1].contains("running ten late"))
        // Turn two's brief is an update: the one new line, not the old one again.
        #expect(users[1].contains("An update to the brief") && !users[1].contains("are we still on for two?"))
        #expect(users[1].contains(BrainPrompt.deliveryReminderShort))
        #expect(users[2].contains("here now"))
        // …and only a person's spoken turn is marked as one.
        #expect([first, second, third].map { $0.value(forHTTPHeaderField: "X-Hermes-Voice-Turn") } == ["1", nil, "1"])

        // …and none of them moved what the brain's process was started with.
        let signatures = [first, second, third].compactMap { LaunchSignature(requestBody: $0.httpBody) }
        try #require(signatures.count == 3)
        #expect(signatures[1].changes(since: signatures[0]) == [])
        #expect(signatures[2].changes(since: signatures[1]) == [])
        #expect(signatures[0].provider == "claude-code-cli" && signatures[0].model == "sonnet")
        #expect(signatures[0].promptLength > 5_000, "the system message was not the real prompt")

        // The same file rewritten with the same bytes, as sync.sh does every
        // ten minutes, is not a change either.
        try "- gmail: connected, two accounts\n".write(to: Paths.connections, atomically: true, encoding: .utf8)
        let rewritten = try await turn("one more", .spoken, minute: 31, brief: brief("6:37 PM", "Dani|here now"), sends: 4)
        #expect(LaunchSignature(requestBody: rewritten.httpBody) == signatures[0])

        // The control: a connection really changing is the one thing here
        // that may move it — and it is seen, and named.
        try "- gmail: connected, two accounts\n- slack: connected\n".write(to: Paths.connections, atomically: true, encoding: .utf8)
        let after = try await turn("and now", .spoken, minute: 32, brief: brief("6:37 PM", "Dani|here now"), sends: 5)
        let changed = try #require(LaunchSignature(requestBody: after.httpBody))
        let moved = changed.changes(since: signatures[0])
        #expect(moved.count == 1 && moved[0].hasPrefix("the system prompt ("))
    }

    /// The effort a person chose rides in the request's options, never in
    /// what the process was started with — on every provider.
    @Test func reasoningEffortIsNotPartOfTheLaunch() throws {
        let endpoint = HermesEndpoint(config: Config())
        for provider in BrainProviderKind.allCases {
            let model = provider.defaultModel.isEmpty ? "some-model" : provider.defaultModel
            let levels = provider.effortLevels(for: model)
            let requests = ([""] + levels).map { level in
                HermesBrain.request(endpoint: endpoint, sessionID: "s", system: "You are Moe.",
                                    brain: BrainSelection(provider: provider, model: model, reasoningEffort: level),
                                    text: "hello", starter: .person, spoken: level.isEmpty)
            }
            let signatures = requests.compactMap { LaunchSignature(requestBody: $0.httpBody) }
            try #require(signatures.count == requests.count)
            #expect(Set(signatures.map(\.promptDigest)).count == 1, "\(provider.rawValue)")
            #expect(signatures.allSatisfy { $0 == signatures[0] }, "\(provider.rawValue)")
        }
    }

    /// The voice mark is a person's spoken turn and nothing else: not a
    /// background turn, and not sent at all when the setting is off.
    @MainActor
    @Test func onlyAPersonsSpokenTurnIsMarkedAndTheSettingTurnsItOff() async throws {
        let endpoint = HermesEndpoint(config: Config())
        func mark(_ starter: TurnStarter?, spoken: Bool) -> String? {
            endpoint.chatRequest(sessionID: "s", sessionKey: "moe", system: "x", user: "y", stream: true,
                                 origin: starter, spoken: spoken)
                .value(forHTTPHeaderField: "X-Hermes-Voice-Turn")
        }
        #expect(mark(.person, spoken: true) == "1")
        #expect(mark(.person, spoken: false) == nil)
        #expect(mark(.background, spoken: true) == nil)
        #expect(mark(nil, spoken: true) == nil)

        #expect(Config().spokenTurnsOpenQuick, "on by default")
        try StallGuardConductorTests.requireScratchHome()
        var config = Config()
        config.replyChime = false
        config.screenContext = false
        config.spokenTurnsOpenQuick = false
        let brain = FakeBrain()
        let moe = Conductor(config: config, brain: brain)
        moe.submit("what is on today", origin: .spoken, starter: .person)
        try await brain.waitForSends(1)
        #expect(brain.sent.last?.spoken == false)
        brain.reply("Done.", end: .answered)

        let (on, heard) = try StallGuardConductorTests.make()
        on.submit("what is on today", origin: .spoken, starter: .person)
        try await heard.waitForSends(1)
        #expect(heard.sent.last?.spoken == true)
        heard.reply("Done.", end: .answered)
        on.submit("Something you handed off just finished.", origin: .spoken, starter: .background)
        try await heard.waitForSends(2)
        #expect(heard.sent.last?.spoken == false, "a turn Moe raised itself is nobody speaking")
    }
}
