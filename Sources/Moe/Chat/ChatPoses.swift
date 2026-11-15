#if DEBUG
import Foundation
import MoeChat

/// Every state a conversation can be in, posed once and photographed on all
/// three surfaces: the notch card and the floating window
/// (`Moe --panel-snapshot <dir> x`) and the Chat page in a real titled
/// window (`Moe --settings-snapshot <dir> main-chat-window`).
///
/// docs/CHAT-DEEP-DIVE-2026-11-13.md §0: no pose covered the empty state,
/// Moe working, a streaming reply, an error, a code block, a table, RTL text
/// or a long thread, so none of those could be looked at, and the clipped
/// greeting the owner photographed could not be caught by any shot. An
/// invisible state cannot be polished. One list, so the three surfaces are
/// always photographed in the same states.
enum ChatPoses {

    struct Pose {
        let name: String
        let note: String
        let state: Conductor.SnapshotState
    }

    static var all: [Pose] {
        [
            Pose(name: "empty", note: "nothing said yet: the greeting, below the titlebar",
                 state: Conductor.SnapshotState()),
            Pose(name: "thinking", note: "asked, before the first word: Thinking, the clock, ■ in place of send",
                 state: thinking(step: nil)),
            Pose(name: "working", note: "a step under way: the live line says what at, with the clock and Stop",
                 state: thinking(step: "Opening OpenTable")),
            Pose(name: "streaming", note: "the answer arriving",
                 state: {
                     var s = thinking(step: nil)
                     s.acting = false
                     s.mode = .thinking
                     s.turns.append(Turn(role: .moe, text: "Nopa has a table for two at 7:00 on Friday, and Zuni has 7:15. Nopa is the closer of the two,",
                                         isStreaming: true))
                     return s
                 }()),
            Pose(name: "queued", note: "typed while Moe works: the message waits where you can see it",
                 state: {
                     var s = thinking(step: "Reading your calendar")
                     s.queuedTyped = "and check if Dana is free after"
                     return s
                 }()),
            Pose(name: "done", note: "finished: the answer, then \"3 steps · 48 s\" folded under it",
                 state: done()),
            Pose(name: "error", note: "the brain did not answer: a plain line",
                 state: {
                     var s = Conductor.SnapshotState()
                     var note = Turn(role: .system, text: "Moe's brain didn't answer. Try again in a moment.")
                     note.failed = true
                     s.turns = [Turn(role: .you, text: "what's the weather in Lisbon this weekend"), note]
                     return s
                 }()),
            Pose(name: "draft", note: "a drafted email: the card, and what to do with it",
                 state: turns(["draft a reply to Sam saying Thursday works"],
                              "Here it is:\n\n> Hi Sam,\n>\n> Thursday works for me. Shall we say 3 at your office?\n>\n> Thanks,\n> Jordan\n\nSend it, or change anything first?")),
            Pose(name: "list", note: "a list: hanging indent, the wrapped line under the text not the bullet",
                 state: turns(["what's on tomorrow before noon?"],
                              "Two things.\nStandup with Dana at 9:30, twenty minutes, on Zoom.\nThe dentist at 11:15.\n\nBefore you go:\n- Route 4 is slow in the mornings, so leave by **10:50** and take the bridge rather than the tunnel if it is raining.\n- Bring the insurance card.\n  - The new one, from October.\n1. Reply to Dana's agenda.\n2. Move the 1:1 with Eli to Thursday.")),
            Pose(name: "table", note: "a table",
                 state: turns(["compare the three flights"],
                              "Here they are:\n\n| Flight | Leaves | Arrives | Price |\n|---|---|---|---:|\n| TP 1361 | 07:05 | 09:40 | €184 |\n| FR 7262 | 11:30 | 14:10 | €96 |\n| U2 8091 | 18:45 | 21:20 | €131 |\n\nThe Ryanair one is cheapest but lands after lunch.")),
            Pose(name: "code", note: "a code block: language, Copy, monospaced on every surface",
                 state: turns(["how do I list the biggest files in Downloads?"],
                              "In Terminal:\n\n```bash\ndu -sh ~/Downloads/* | sort -h | tail -20\n```\n\nThe last line is the biggest.")),
            Pose(name: "rtl", note: "Hebrew: right to left, yours and Moe's, every paragraph",
                 state: turns(["מה יש לי מחר בבוקר?"],
                              "שני דברים.\nישיבת צוות עם דנה ב-9:30, עשרים דקות.\nרופא שיניים ב-11:15. כדאי לצאת עד 10:50.")),
            Pose(name: "rtl-english-first", note: "Hebrew that starts with an English word still reads right to left",
                 state: turns(["Zoom עם דנה מחר?"],
                              "Zoom עם דנה מחר ב-9:30, ונשלחה לך הזמנה.\nCalendar מעודכן.")),
            Pose(name: "rtl-mixed", note: "a mixed list, a Hebrew draft in a card, and code that stays left to right",
                 state: turns(["תכין לי טיוטה לסם"],
                              "הנה הטיוטה:\n\n> שלום סם,\n>\n> יום חמישי מתאים לי. נגיד ב-3 במשרד שלך?\n>\n> תודה,\n> יוסי\n\nומה שביקשת:\n- לשלוח את ה-deck לפני הפגישה.\n- Dana צריכה אישור עד יום רביעי.\n\n```bash\nopen ~/Desktop/deck.key\n```")),
            Pose(name: "long", note: "a long thread: sixty turns, scrolled to the newest",
                 state: {
                     var s = Conductor.SnapshotState()
                     s.turns = (1...30).flatMap { i in
                         [Turn(role: .you, text: "Question \(i): what about item \(i)?"),
                          Turn(role: .moe, text: "Item \(i) is done. It moved on Tuesday and nobody needs to do anything about it.")]
                     }
                     return s
                 }()),
        ]
    }

    /// Asked, and Moe at work on it.
    static func thinking(step: String?) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.mode = .thinking
        s.awaitingReply = true
        s.acting = step != nil
        s.workingStep = step
        s.workingSince = Date(timeIntervalSinceNow: -43)
        s.turns = [Turn(role: .you, text: "What's on tomorrow?"),
                   Turn(role: .moe, text: "Standup at 9:30 and the dentist at 11:15."),
                   Turn(role: .you, text: "book me a table for two somewhere near the office on Friday at seven")]
        return s
    }

    static func done() -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        var answer = Turn(role: .moe, text: "Table for two at Nopa, Friday at 7:00. It's under your name. Want the confirmation in your calendar?")
        answer.tools = ["Looked at your calendar", "Read something on opentable.com", "Worked through the page"]
        answer.took = 48
        answer.links = [ReplyLinks.Link(url: "https://www.opentable.com/r/nopa", label: "opentable.com/r")]
        s.turns = [Turn(role: .you, text: "book me a table for two somewhere near the office on Friday at seven"), answer]
        return s
    }

    static func turns(_ yours: [String], _ moe: String) -> Conductor.SnapshotState {
        var s = Conductor.SnapshotState()
        s.turns = yours.map { Turn(role: .you, text: $0) } + [Turn(role: .moe, text: moe)]
        return s
    }
}
#endif
