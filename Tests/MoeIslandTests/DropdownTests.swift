import Testing
@testable import MoeIsland

/// The dropdown of 2026-09-24: one layout for a whole turn, one word of
/// status, the controls behind a ⋯ (`Dropdown`, `IslandStatus`, `IslandTray`).
@Suite struct DropdownTests {

    // MARK: - Status

    private func status(_ mode: IslandStatus.Mode, acting: Bool = false, step: Bool = false,
                        app: String? = nil, browsing: Bool = false, paused: Bool = false,
                        muted: Bool = false, conversation: Bool = true) -> IslandStatus.Status {
        IslandStatus.of(mode: mode, acting: acting, stepKnown: step, drivingApp: app,
                        browsing: browsing, replyPaused: paused, muted: muted,
                        inConversation: conversation)
    }

    @Test func aTurnReadsAsOneWordAtEachStep() {
        #expect(status(.listening, conversation: false).word == "Listening")
        #expect(status(.thinking).word == "Thinking")
        #expect(status(.thinking, acting: true, step: true).word == "Working")
        #expect(status(.speaking).word == "Speaking")
        #expect(status(.speaking, paused: true).word == "Paused")
        #expect(status(.listening).word == "Your turn")
        #expect(status(.idle).word == "Moe")
    }

    @Test func theClockRunsOnlyWhileMoeWorks() {
        #expect(status(.thinking).clock)
        #expect(status(.speaking, acting: true, step: true).clock)
        #expect(!status(.speaking).clock)
        #expect(!status(.idle).clock)
    }

    @Test func mutedSaysSoWhenNothingElseIsHappening() {
        #expect(status(.listening, muted: true) == .init(word: "Muted", tone: .muted, clock: false))
        // Muted while Moe works: the work is the news; the red mic says the rest.
        #expect(status(.thinking, muted: true).word == "Thinking")
    }

    @Test func drivingNamesTheApp() {
        let s = status(.thinking, acting: true, app: "Safari")
        #expect(s.word == "Using Safari")
        #expect(s.tone == .driving)
    }

    // MARK: - The tray

    private func tray(working: Bool = false, conversation: Bool = true, muted: Bool = false,
                      offersQuiet: Bool = false, quiet: Bool = false, voiced: Bool = false,
                      paused: Bool = false, playable: Bool = false, shown: Bool = false,
                      driving: Bool = false) -> [IslandTray.Control] {
        IslandTray.controls(working: working, inConversation: conversation, muted: muted,
                            offersWorkSilently: offersQuiet, workingSilently: quiet,
                            voiced: voiced, replyPaused: paused, answerPlayable: playable,
                            answerShown: shown, driving: driving)
    }

    @Test func theLeftOfTheTrayNeverMovesAndTheActionIsLast() {
        // Working, then speaking, then paused: the mic stays first, and only
        // the right-hand end changes — the lifecycle the owner called a mess.
        let cc = IslandTray.Control.captions(on: false)
        #expect(tray(working: true, offersQuiet: true)
                == [.mic(muted: false), .updates(quiet: false), cc, .stop(driving: false)])
        #expect(tray(voiced: true, shown: true)
                == [.mic(muted: false), cc, .startOver, .pause, .copy, .openChat])
        #expect(tray(voiced: true, paused: true, shown: true)
                == [.mic(muted: false), cc, .startOver, .resume, .copy, .openChat])
    }

    @Test func oneStopOnlyWhileThereIsSomethingToStop() {
        #expect(!tray(playable: true, shown: true).contains(.stop(driving: false)))
        #expect(tray(working: true, driving: true).last == .stop(driving: true))
    }

    @Test func aFinishedAnswerCanBeReadAloudAndCopied() {
        #expect(tray(conversation: false, playable: true, shown: true) == [.readAloud, .copy, .openChat])
    }

    @Test func switchesShowTheirStateNotTheirAction() {
        #expect(tray(muted: true).first == .mic(muted: true))
        #expect(IslandTray.controls(working: false, inConversation: true, muted: false,
                                    offersWorkSilently: false, workingSilently: false,
                                    transcriptOn: true, voiced: false, replyPaused: false,
                                    answerPlayable: false, answerShown: false, driving: false)
                .contains(.captions(on: true)))
        #expect(tray(working: true, offersQuiet: true, quiet: true).contains(.updates(quiet: true)))
    }

    /// With nothing else to control, the ⋯ still holds the way to the whole
    /// conversation in the window — a click on the island no longer opens it.
    @Test func theWindowIsAlwaysOneClickAwayExceptMidJob() {
        #expect(tray(conversation: false) == [.openChat])
        #expect(!tray(working: true).contains(.openChat))
    }

    // MARK: - Field and height

    /// The owner, 2026-09-25: "there's no chat field at all, it's
    /// disappeared" — while Moe was working. It is always there now.
    @Test func theFieldIsAlwaysThere() {
        for working in [false, true] {
            for listening in [false, true] {
                #expect(Dropdown.showsField(working: working, listening: listening, draftInProgress: false))
            }
        }
    }

    @Test func theHeightFollowsTheConversation() {
        let q = IslandChat.Row.you(id: "1", text: "table for two", live: false)
        let short = Dropdown.height(.init(chat: [q, .moe(id: "2", text: "Nopa, 7:00.")], controls: true))
        let long = Dropdown.height(.init(chat: [q, .moe(id: "2", text: String(repeating: "word ", count: 80))],
                                         controls: true))
        #expect(long > short)
    }

    /// The owner, 2026-09-24: "you can't really see your transcript, it's
    /// small at the top". Your words are a bubble now, wrapping to four
    /// lines rather than one truncated line.
    @Test func yourWordsWrapInTheirBubble() {
        let short = Dropdown.youHeight("table for two")
        let long = Dropdown.youHeight(String(repeating: "word ", count: 30))
        #expect(long > short)
        #expect(long <= Double(Dropdown.Metric.youLinesMax) * Dropdown.Metric.youLineHeight
                + Dropdown.Metric.youPadV * 2)
    }

    @Test func aVeryLongAnswerScrollsRatherThanGrows() {
        let huge = Dropdown.moeHeight(String(repeating: "word ", count: 2000))
        #expect(huge == Double(Dropdown.Metric.moeLinesMax) * Dropdown.Metric.moeLine)
    }

    @Test func theHeightCountsExactlyWhatIsDrawn() {
        // One row of each: the arithmetic is the view's padding and gaps.
        let m = Dropdown.Metric.self
        let rows: [IslandChat.Row] = [.you(id: "1", text: "Hi", live: false), .moe(id: "2", text: "Hi.")]
        let c = Dropdown.Contents(chat: rows, controls: true, field: true)
        let chat = IslandChat.height(rows)
        let expected = m.top + chat + m.controls + m.field + 2 * m.gap + m.bottom
        #expect(Dropdown.height(c) == expected)
    }
}

@Suite struct MeetingTrayTests {

    @Test func aRecordingHasItsToolsAndOneStopLast() {
        let c = MeetingTray.controls(recording: true, offRecord: false, screenshots: true,
                                     clips: true, clipping: false)
        #expect(c == [.mark, .offRecord(on: false), .screenshot, .clip(on: false), .stop])
        #expect(MeetingTray.outside(c).isEmpty)
    }

    @Test func whatChangesTheRecordingStaysInView() {
        let off = MeetingTray.controls(recording: true, offRecord: true, screenshots: false,
                                       clips: true, clipping: true)
        #expect(MeetingTray.outside(off) == [.offRecord(on: true), .clip(on: true)])
    }

    @Test func toolsTheOwnerSwitchedOffAreNotOffered() {
        let c = MeetingTray.controls(recording: true, offRecord: false, screenshots: false,
                                     clips: false, clipping: false)
        #expect(c == [.mark, .offRecord(on: false), .stop])
    }

    @Test func nothingBeforeTheRecordingStarts() {
        #expect(MeetingTray.controls(recording: false, offRecord: false, screenshots: true,
                                     clips: true, clipping: false).isEmpty)
    }
}


/// The dropdown's conversation as a chat (the owner, 2026-09-24): the whole
/// session, you on the right, Moe on the left, scrolling, with More on long
/// messages.
@Suite struct IslandChatTests {

    @Test func aShortMessageIsShownWhole() {
        #expect(IslandChat.clipped("book me a table", limit: IslandChat.youLimit) == nil)
    }

    @Test func aLongMessageShowsItsStartAndMore() throws {
        let long = String(repeating: "word ", count: 100)
        let head = try #require(IslandChat.clipped(long, limit: IslandChat.youLimit))
        #expect(head.count <= IslandChat.youLimit + 1)
        #expect(head.hasSuffix("…"))
        #expect(!head.hasSuffix(" …"), "cut mid-word or on a space")
        // More costs its own line.
        let clippedRow = IslandChat.height(.you(id: "1", text: long, live: false))
        let plainRow = IslandChat.height(.you(id: "1", text: head, live: false))
        #expect(clippedRow == plainRow + IslandChat.more)
    }

    @Test func aLongSessionScrollsRatherThanGrows() {
        let rows = (0..<40).map { IslandChat.Row.moe(id: "\($0)", text: "An answer of a line or two.") }
        #expect(IslandChat.height(rows) == IslandChat.maxHeight)
    }

    /// The owner, 2026-09-25: "the output Moe gives shouldn't have a cap,
    /// only the user's input should — people read output, not input."
    @Test func moesAnswerIsNeverCut() {
        let long = String(repeating: "word ", count: 400)
        let short = IslandChat.height(.moe(id: "1", text: "word"))
        #expect(IslandChat.height(.moe(id: "1", text: long)) > short * 20)
    }

    @Test func rowsKeepTheirOwnIds() {
        let rows: [IslandChat.Row] = [.you(id: "a", text: "x", live: false), .moe(id: "b", text: "y"),
                                      .noted(id: "b:noted", count: 1), .working(label: "Thinking")]
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}


/// The owner's screenshot, 2026-09-25: a three-line reminder over a long
/// conversation. The panel was capped and the conversation was not, so the
/// content ran out of both ends: the card up under the notch, the field
/// below the panel.
@Suite struct DropdownFitTests {

    private let long: [IslandChat.Row] = (0..<30).map {
        .moe(id: "\($0)", text: "Kicking off a long research-and-draft run now, and I will message you when it wraps.")
    }

    @Test func theConversationGivesWaySoTheCardAndFieldFit() {
        let c = Dropdown.Contents(chat: long, controls: true, field: true, banners: 110)
        let (height, chat) = Dropdown.layout(c)
        #expect(height <= Dropdown.maximumHeight)
        let m = Dropdown.Metric.self
        let drawn = m.top + 110 + chat + m.controls + m.field + 3 * m.gap + m.bottom
        #expect(drawn <= Dropdown.maximumHeight + 0.5, "the content is taller than the panel it is drawn in")
        #expect(chat < IslandChat.height(long))
    }

    /// The owner, 2026-10-30: clicked open, "it doesn't actually expand
    /// more. I can't see the whole thing." The hover panel and the open one
    /// were the same height; the open one now has room to grow.
    @Test func clickedOpenALongAnswerGetsMoreRoomThanOnHover() {
        let answer: [IslandChat.Row] = [.you(id: "1", text: "explain it", live: false),
                                        .moe(id: "2", text: String(repeating: "word ", count: 500))]
        let c = Dropdown.Contents(chat: answer, field: true)
        let hover = Dropdown.layout(c)
        let open = Dropdown.layout(c, maximum: Dropdown.maximum(expanded: true))
        let grown = Dropdown.expandedMaximumHeight - Dropdown.maximumHeight
        #expect(open.height == hover.height + grown)
        #expect(open.height <= Dropdown.expandedMaximumHeight)
        #expect(open.chat - hover.chat == grown,
                "the extra height went somewhere other than the conversation")
    }

    @Test func clickedOpenAShortConversationIsNoTaller() {
        let rows: [IslandChat.Row] = [.you(id: "1", text: "hi", live: false), .moe(id: "2", text: "Hello.")]
        let c = Dropdown.Contents(chat: rows, field: true)
        let open = Dropdown.layout(c, maximum: Dropdown.maximum(expanded: true))
        #expect(open.height == Dropdown.layout(c).height)
        #expect(open.chat == Dropdown.layout(c).chat)
    }

    @Test func aShortConversationIsNotSqueezed() {
        let rows: [IslandChat.Row] = [.you(id: "1", text: "hi", live: false), .moe(id: "2", text: "Hello.")]
        let c = Dropdown.Contents(chat: rows, controls: true, field: true, banners: 110)
        #expect(Dropdown.layout(c).chat == IslandChat.height(rows))
    }

    @Test func someConversationIsAlwaysLeft() {
        let c = Dropdown.Contents(chat: long, controls: true, field: true, banners: 390)
        #expect(Dropdown.layout(c).chat >= Dropdown.minimumChat)
    }
}
