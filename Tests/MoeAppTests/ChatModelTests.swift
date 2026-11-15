import Foundation
import Testing
import MoeChat
@testable import Moe

/// A model per chat (the owner's answer 9, 2026-11-13): chosen from the
/// person's own provider's list, held by that chat only, and dropped when
/// the provider changes.
@MainActor
struct ChatModelTests {

    @Test func aChatKeepsItsOwnModelAndOthersKeepTheDefault() async throws {
        let (moe, brain) = try StallGuardConductorTests.make()
        let fallback = moe.defaultChatModel
        let other = try #require(moe.chatModelChoices.first { $0 != fallback },
                                 "the provider offers only one model")
        moe.submit("hello", origin: .typed, starter: .person)
        try await brain.waitForSends(1)
        brain.reply("Hi.", end: .answered)
        try await Task.sleep(nanoseconds: 50_000_000)
        let thread = moe.currentConversationID

        moe.setChatModel(other)
        #expect(moe.chatModel == other)
        #expect(moe.chatSelection().model == other)
        #expect(brain.applied.last?.model == other, "the brain was not handed the chat's model")

        // A new chat is on the default.
        moe.newConversation()
        #expect(moe.chatModel == nil)
        #expect(brain.applied.last?.model == fallback)

        // Back on the first, its model comes back with it.
        moe.saveConversation(flush: true)
        moe.openConversation(id: thread)
        #expect(moe.chatModel == other)
        #expect(brain.applied.last?.model == other)

        // Choosing the default again clears it.
        moe.setChatModel(fallback)
        #expect(moe.chatModel == nil)
    }

    /// A choice made on one provider means nothing on another.
    @Test func aModelIsKeptForTheProviderItWasChosenOn() {
        let m = ConversationStore.Marks(model: "gpt-5.4", provider: "openai-codex")
        #expect(m.model(on: "openai-codex") == "gpt-5.4")
        #expect(m.model(on: "claude-code-cli") == nil)
        #expect(ConversationStore.Marks().model(on: "openai-codex") == nil)
    }

    @Test func theChoicesAreTheProvidersOwnList() throws {
        let (moe, _) = try StallGuardConductorTests.make()
        let provider = moe.config.brainProvider
        for id in provider.curatedModels { #expect(moe.chatModelChoices.contains(id)) }
        #expect(moe.chatModelChoices.contains(moe.defaultChatModel) || moe.defaultChatModel.isEmpty)
    }
}
