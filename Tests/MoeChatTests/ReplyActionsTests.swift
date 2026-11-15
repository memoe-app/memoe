import Testing
@testable import MoeChat

/// Send · Edit · Copy · Retry under drafts, offers and errors (the owner's
/// answer 7, 2026-11-13).
struct ReplyActionsTests {

    let draft = """
    Here's a reply to Sam:

    > Hi Sam,
    > Thursday works for me. See you at 3.
    > Yossi

    Want me to send it?
    """

    @Test func aDraftGetsSendEditCopy() {
        #expect(ReplyActions.of(text: draft, isAnswer: true, failed: false, latest: true) == [.send, .edit, .copy])
        #expect(ReplyActions.draft(in: draft) == "Hi Sam,\nThursday works for me. See you at 3.\nYossi")
    }

    @Test func anOfferGetsAYes() {
        let offer = "Table for two at Nopa, Friday at 7:00. Want the confirmation in your calendar?"
        #expect(ReplyActions.of(text: offer, isAnswer: true, failed: false, latest: true) == [.accept])
        #expect(ReplyActions.isOffer("Done. Should I tell Dana too?"))
    }

    /// A question that is not an offer, and a plain answer, get nothing.
    @Test func ordinaryAnswersGetNothing() {
        #expect(ReplyActions.of(text: "Which Friday did you mean?", isAnswer: true, failed: false, latest: true).isEmpty)
        #expect(ReplyActions.of(text: "It's 18° in Lisbon.", isAnswer: true, failed: false, latest: true).isEmpty)
        // A quote of one word is not a draft.
        #expect(ReplyActions.draft(in: "> ok") == nil)
    }

    @Test func anErrorGetsRetry() {
        #expect(ReplyActions.of(text: "Moe's brain didn't answer.", isAnswer: false, failed: true, latest: true) == [.retry])
        // "Stopped." is a note, not a failure.
        #expect(ReplyActions.of(text: "Stopped.", isAnswer: false, failed: false, latest: true).isEmpty)
    }

    /// Only the newest turn: a yes three answers up is stale.
    @Test func onlyTheNewestTurn() {
        #expect(ReplyActions.of(text: draft, isAnswer: true, failed: false, latest: false).isEmpty)
        #expect(ReplyActions.of(text: "x", isAnswer: false, failed: true, latest: false).isEmpty)
    }

    @Test func theAnsweringButtonsSpeakAsThePerson() {
        #expect(ReplyAction.send.words != nil)
        #expect(ReplyAction.accept.words != nil)
        #expect(ReplyAction.copy.words == nil && ReplyAction.edit.words == nil && ReplyAction.retry.words == nil)
    }
}
