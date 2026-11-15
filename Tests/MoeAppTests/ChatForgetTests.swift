import Foundation
import Testing
import MoeChat
import MoeBrain
@testable import Moe

/// "Don't remember this chat" (the owner's decision, 2026-11-13): a per-chat
/// switch, sent as X-Hermes-No-Memory on every turn of that chat, and a chat
/// so marked is never tagged.
@MainActor
struct ChatForgetTests {

    /// Every turn of a private chat carries the header, whoever started it;
    /// no other turn does.
    @Test func everyTurnOfAPrivateChatSaysSo() {
        let endpoint = HermesEndpoint(config: Config())
        func header(_ starter: TurnStarter, forget: Bool) -> String? {
            HermesBrain.request(endpoint: endpoint, sessionID: "s", system: "You are Moe.",
                                brain: BrainSelection(config: Config()), text: "hello",
                                starter: starter, forget: forget)
                .value(forHTTPHeaderField: "X-Hermes-No-Memory")
        }
        #expect(header(.person, forget: true) == "1")
        #expect(header(.background, forget: true) == "1", "a priming in a private chat is private too")
        #expect(header(.person, forget: false) == nil)
        #expect(header(.background, forget: false) == nil)
    }

    /// The live brain: `remember(false)` puts the header on the turns queued
    /// after it, and `remember(true)` takes it off again.
    @Test func theBrainSendsItOnceTold() throws {
        try StallGuardConductorTests.requireScratchHome()
        let brain = HermesBrain(config: Config())
        func header() -> String? {
            brain.nextRequestForTesting("hello", starter: .person).value(forHTTPHeaderField: "X-Hermes-No-Memory")
        }
        #expect(header() == nil)
        brain.remember(false)
        #expect(header() == "1")
        brain.remember(true)
        #expect(header() == nil)
    }

    /// The header is not part of what the brain's process was started with,
    /// so turning the switch on costs no restart.
    @Test func theSwitchIsNotPartOfTheLaunch() {
        let endpoint = HermesEndpoint(config: Config())
        let sigs = [false, true].map {
            LaunchSignature(requestBody: HermesBrain.request(
                endpoint: endpoint, sessionID: "s", system: "You are Moe.",
                brain: BrainSelection(config: Config()), text: "hello", starter: .person,
                forget: $0).httpBody)
        }
        #expect(sigs[0] != nil && sigs[0] == sigs[1])
    }

    /// The switch is per chat: the brain is told on the chat it was set on,
    /// told again when that chat is reopened, and a new chat is remembered.
    @Test func theBrainFollowsTheChatsSwitch() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        moe.submit("hello", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Hi.", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)
        let thread = moe.currentConversationID

        moe.setChatForgets(true)
        #expect(moe.chatForgets)
        #expect(brain.remembers.last == false, "the brain was not told this chat is private")

        moe.newConversation()
        #expect(!moe.chatForgets)
        #expect(brain.remembers.last == true, "a new chat inherited the last one's switch")

        moe.saveConversation(flush: true)
        moe.openConversation(id: thread)
        #expect(moe.chatForgets)
        #expect(brain.remembers.last == false, "reopening a private chat lost its switch")

        moe.setChatForgets(false)
        #expect(brain.remembers.last == true)
    }

    /// A private chat is never tagged: not asked, and a call already out
    /// when the switch went on leaves it untagged.
    @Test func aPrivateChatIsNeverTagged() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        var asked: [String] = []
        var finish: (([String]?, Bool) -> Void)?
        moe.tagCall = { thread, _, _, done in asked.append(thread); finish = done }
        let turns = Self.exchanges(TagRules.minExchanges)

        moe.setChatForgets(true)
        moe.tagIfNeeded(id: moe.currentConversationID, turns: turns)
        #expect(asked.isEmpty, "a chat marked Don't remember was sent to be tagged")

        moe.setChatForgets(false)
        moe.tagIfNeeded(id: moe.currentConversationID, turns: turns)
        #expect(asked == [moe.currentConversationID])
        moe.setChatForgets(true)              // while the call is out
        finish?(["travel"], true)
        #expect(moe.conversationMarks()[moe.currentConversationID]?.tags == [])
    }

    static func exchanges(_ n: Int) -> [ConversationStore.StoredTurn] {
        (0..<n).flatMap { i in [
            ConversationStore.StoredTurn(id: "y\(i)", role: .you, text: "Question \(i) about Lisbon", at: Date()),
            ConversationStore.StoredTurn(id: "m\(i)", role: .moe, text: "Answer \(i).", at: Date()),
        ] }
    }
}

/// Tags: one call per chat, after a few exchanges, kept per Mac beside pins.
@MainActor
struct ChatTagTests {

    @Test func oneCallPerChatAndNeverPerTurn() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        var asked = 0
        moe.tagCall = { _, _, _, done in asked += 1; done(["travel", "lisbon"], true) }
        let id = moe.currentConversationID
        moe.tagIfNeeded(id: id, turns: ChatForgetTests.exchanges(TagRules.minExchanges - 1))
        #expect(asked == 0, "tagged before the chat had enough to go on")
        for n in TagRules.minExchanges...(TagRules.minExchanges + 4) {
            moe.tagIfNeeded(id: id, turns: ChatForgetTests.exchanges(n))
        }
        #expect(asked == 1, "the tagging call was repeated")
        #expect(moe.conversationMarks()[id]?.tags == ["travel", "lisbon"])
    }

    /// An answer that is not tags is still an answer: never asked again. A
    /// call that failed is not asked again this launch either.
    @Test func aUselessAnswerOrAFailureIsNotRetriedEveryTurn() async throws {
        let (moe, _) = try StallGuardConductorTests.make()
        var asked = 0
        moe.tagCall = { _, _, _, done in asked += 1; done(nil, false) }
        let turns = ChatForgetTests.exchanges(TagRules.minExchanges)
        moe.tagIfNeeded(id: "a", turns: turns)
        moe.tagIfNeeded(id: "a", turns: turns)
        #expect(asked == 1)
        #expect(moe.conversationMarks()["a"]?.tagged != true, "a failure is tried again next launch")
        moe.tagCall = { _, _, _, done in asked += 1; done(nil, true) }
        moe.tagIfNeeded(id: "b", turns: turns)
        #expect(moe.conversationMarks()["b"]?.tagged == true)
    }
}
