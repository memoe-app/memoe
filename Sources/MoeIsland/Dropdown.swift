import Foundation
import MoeChat

/// The island's dropdown, redesigned (the owner's review, 2026-09-24).
///
/// What it replaces. A spoken turn used to swap the open panel twice: the
/// conversation, then a one-line working row with seven controls, then the
/// conversation again with a different set. Mute moved between four rows,
/// Stop became a ✕ that called a weaker stop, and a slashed mic meant "you
/// are muted" while a slashed speaker meant "press to go quiet". The owner's
/// words: "that whole thing is a mess", and "I like extreme minimalism while
/// being clear, and the user not having to guess what's going on".
///
/// What it is now, for every state outside a meeting, one layout that is
/// never swapped mid-turn:
///
/// 1. one word of status in the black band beside the notch, with a clock
///    while Moe works (`IslandStatus`);
/// 2. your last words, in a bubble on the right, as in any chat;
/// 3. Moe's line: the step it is on, or the answer;
/// 4. a ⋯ that slides out the controls as small icons (`IslandTray`), with
///    the red muted mic kept outside it while muted, so mute stays
///    unmistakable;
/// 5. the field, only when you can use it (`Dropdown.showsField`).
///
/// The rules live here, in a library target, so they can be tested without
/// AppKit, and so the view and the height arithmetic read the same answer.
public enum IslandStatus {

    public enum Tone: Equatable, Sendable {
        /// Moe's own light: thinking, working, speaking.
        case moe
        /// Quiet: idle, a finished answer, a paused reply.
        case dim
        /// Green: Moe hears you.
        case listening
        /// Red: your mic is muted.
        case muted
        /// Magenta: Moe has the mouse and keyboard.
        case driving
    }

    public struct Status: Equatable, Sendable {
        public let word: String
        public let tone: Tone
        /// A running clock beside the word: only while Moe works.
        public let clock: Bool
    }

    public enum Mode: Equatable, Sendable { case idle, listening, thinking, speaking }

    public static func of(mode: Mode, acting: Bool, stepKnown: Bool,
                          drivingApp: String?, browsing: Bool,
                          replyPaused: Bool, muted: Bool,
                          inConversation: Bool) -> Status {
        let working = mode == .thinking || acting
        if working {
            if let app = drivingApp { return Status(word: "Using \(app)", tone: .driving, clock: true) }
            if browsing { return Status(word: "Browsing", tone: .driving, clock: true) }
            return Status(word: stepKnown ? "Working" : "Thinking", tone: .moe, clock: true)
        }
        switch mode {
        case .speaking:
            return replyPaused ? Status(word: "Paused", tone: .dim, clock: false)
                               : Status(word: "Speaking", tone: .moe, clock: false)
        case .listening:
            if muted { return Status(word: "Muted", tone: .muted, clock: false) }
            return Status(word: inConversation ? "Your turn" : "Listening", tone: .listening, clock: false)
        case .idle, .thinking:
            if muted { return Status(word: "Muted", tone: .muted, clock: false) }
            return Status(word: "Moe", tone: .dim, clock: false)
        }
    }
}

/// The controls behind the ⋯, as small icons, in a fixed order so each one
/// is always in the same place: mic, updates, captions, start over, pause or
/// resume or read aloud, copy, open in the window, stop.
public enum IslandTray {

    public enum Control: Equatable, Sendable {
        /// Your mic. Shows its state: plain when on, red and crossed when
        /// muted. While muted it is also drawn outside the tray.
        case mic(muted: Bool)
        /// Progress said aloud while Moe works. Shows its state: a speaker
        /// when on, a crossed speaker, filled in, when you turned it off.
        case updates(quiet: Bool)
        /// The live transcript: when on, the panel opens by itself as you
        /// talk and as Moe answers (ticket #12). Filled in when on.
        case captions(on: Bool)
        case startOver
        case pause
        case resume
        case readAloud
        case copy
        /// The whole conversation in the Memoe window. A click on the island
        /// no longer opens it (2026-09-24), so it is here.
        case openChat
        /// Stop Moe and everything it started. Named "Take back control"
        /// while Moe has the screen.
        case stop(driving: Bool)
    }

    public static func controls(working: Bool, inConversation: Bool, muted: Bool,
                                offersWorkSilently: Bool, workingSilently: Bool,
                                transcriptOn: Bool = false,
                                voiced: Bool, replyPaused: Bool,
                                answerPlayable: Bool, answerShown: Bool,
                                driving: Bool) -> [Control] {
        var c: [Control] = []
        if inConversation || muted { c.append(.mic(muted: muted)) }
        if offersWorkSilently { c.append(.updates(quiet: workingSilently)) }
        if inConversation || transcriptOn { c.append(.captions(on: transcriptOn)) }
        if voiced {
            c.append(.startOver)
            c.append(replyPaused ? .resume : .pause)
        } else if answerPlayable, !working {
            c.append(.readAloud)
        }
        if answerShown, !working { c.append(.copy) }
        if !working { c.append(.openChat) }
        if working { c.append(.stop(driving: driving)) }
        return c
    }

    /// Muted, the red mic is drawn beside the ⋯ as well as in it, so the one
    /// state the owner asked to be unmistakable never hides behind a click.
    public static func mutedOutside(_ muted: Bool) -> Bool { muted }
}

public enum Dropdown {

    /// The field is always there, as in any chat (the owner, 2026-09-25,
    /// "there's no chat field at all, it's disappeared"). It used to hide
    /// while Moe worked and while you talked; a message typed mid-turn is
    /// now held and sent when the turn finishes (`Conductor.queuedTyped`).
    public static func showsField(working: Bool, listening: Bool, draftInProgress: Bool) -> Bool {
        true
    }

    /// The row of controls under the conversation. The ⋯ lives beside the
    /// send button now, and Stop is the send button itself while Moe works
    /// (the owner, 2026-11-13), so the row that used to hold a lone ⋯ on
    /// every card is drawn only while the controls are slid out — or while
    /// muted, because the red Unmute pill lives on it and must stay in view.
    public static func showsControlsRow(hasControls: Bool, open: Bool, muted: Bool) -> Bool {
        hasControls && (open || muted)
    }

    public struct Contents: Equatable, Sendable {
        /// The conversation (`IslandChat`), scrolling past its cap.
        public var chat: [IslandChat.Row]
        /// The greeting on a cold start, when there is no conversation yet.
        public var greeting: String
        /// The ⋯ row is drawn (there is at least one control).
        public var controls: Bool
        public var field: Bool
        /// How tall the field's text runs: one line empty, up to four as
        /// you type or paste (`ComposerEditor`).
        public var fieldText: Double = 0
        /// Height of whatever cannot scroll above the conversation: the
        /// reminder, the fix cards, the update and call offers
        /// (`ConversationPanel.banners`).
        public var banners: Double
        /// The status word sits in the band beside the notch; without a
        /// notch it takes a row of its own at the top.
        public var statusInBand: Bool

        public init(chat: [IslandChat.Row] = [], greeting: String = "",
                    controls: Bool = false, field: Bool = true, fieldText: Double = 0, banners: Double = 0,
                    statusInBand: Bool = true) {
            self.chat = chat
            self.greeting = greeting
            self.controls = controls
            self.field = field
            self.fieldText = fieldText
            self.banners = banners
            self.statusInBand = statusInBand
        }
    }

    /// Every number is read off `IslandView.minimalBody`, one line each.
    public enum Metric {
        public static let width = 420.0
        public static let side = 18.0                // .padding(.horizontal, 18)
        public static let top = 12.0                 // .padding(.top, 12)
        public static let bottom = 16.0              // .padding(.bottom, 16)
        public static let gap = 10.0                 // VStack(spacing: 10)
        public static let statusRow = 22.0           // the status word, when not in the band
        /// Your bubble: 13 pt text, 17 pt lines, 7 pt above and below, 11 pt
        /// either side, at most four-fifths of the panel wide and four lines
        /// tall (a longer question ends in "…").
        public static let youSize = 13.0
        public static let youLineHeight = 17.0
        public static let youPadV = 7.0
        public static let youPadH = 11.0
        public static let youWidthShare = 0.8
        public static let youLinesMax = 4
        public static let moeSize = 15.0
        public static let moeLine = 21.0             // 15 pt, .lineSpacing(3)
        public static let noted = 16.0               // NotedLines, one line each
        public static let controls = 26.0            // the ⋯ and its icons
        public static let field = 34.0               // the rounded field, one line
        /// One line of the field's text; more lines add to `field`.
        public static let fieldLine = 17.0
        /// Past this many lines Moe's text scrolls rather than grows.
        public static let moeLinesMax = 9
    }

    public static let minimumHeight = 64.0
    public static let maximumHeight = ConversationPanel.maximumHeight
    /// Clicked open, the panel may grow past the hover panel's 420 so a long
    /// answer can be read whole (the owner, 2026-10-30: "it doesn't actually
    /// expand more. I can't see the whole thing"). Hover stays at 420.
    public static let expandedMaximumHeight = 620.0

    /// The ceiling for a presentation: the hover panel's, or the open one's.
    public static func maximum(expanded: Bool) -> Double {
        expanded ? expandedMaximumHeight : maximumHeight
    }

    /// Moe's line: its wrapped lines, up to `moeLinesMax`, past which it
    /// scrolls. The view frames it at exactly this.
    ///
    /// Measured 16 pt narrower than it is drawn. Measured at the drawn width
    /// it came out a line short on the owner's Mac (2026-09-24, the last
    /// line of an answer cut off at the panel's edge): the scroll view can
    /// take a scroller's width from the text. Erring wide costs at most a
    /// line of black; erring narrow hides the end of the answer.
    public static func moeHeight(_ text: String,
                                 wraps: ConversationPanel.Wraps = ConversationPanel.estimate) -> Double {
        let textWidth = Metric.width - Metric.side * 2 - 16
        let lines = min(max(wraps(text, textWidth, Metric.moeSize), 1), Metric.moeLinesMax)
        return Double(lines) * Metric.moeLine
    }

    /// The widest your bubble's text may run.
    public static var youTextWidth: Double {
        (Metric.width - Metric.side * 2) * Metric.youWidthShare - Metric.youPadH * 2
    }

    /// Your bubble, to the lines it wraps to (up to `youLinesMax`).
    public static func youHeight(_ text: String,
                                 wraps: ConversationPanel.Wraps = ConversationPanel.estimate) -> Double {
        let lines = min(max(wraps(text, youTextWidth - 8, Metric.youSize), 1), Metric.youLinesMax)
        return Double(lines) * Metric.youLineHeight + Metric.youPadV * 2
    }

    public static func height(_ c: Contents,
                              wraps: ConversationPanel.Wraps = ConversationPanel.estimate,
                              maximum: Double = maximumHeight) -> Double {
        layout(c, wraps: wraps, maximum: maximum).height
    }

    /// The least of the conversation kept in view when a reminder, a fix and
    /// the field leave little room: a few lines, scrolled to the newest.
    public static let minimumChat = 60.0

    /// The panel's height and the conversation's, together.
    ///
    /// Everything but the conversation is drawn at full height: the status
    /// row, the cards above, the ⋯ and the field. The conversation takes what
    /// is left under the panel's maximum and scrolls inside it. Before this
    /// the panel was capped and the conversation was not, so with a reminder
    /// card up the content ran past the panel at both ends — the card up
    /// under the notch, the field below the panel's edge (the owner,
    /// 2026-09-25, with a screenshot).
    public static func layout(_ c: Contents,
                              wraps: ConversationPanel.Wraps = ConversationPanel.estimate,
                              maximum: Double = maximumHeight)
        -> (height: Double, chat: Double) {
        var fixed: [Double] = []
        if !c.statusInBand { fixed.append(Metric.statusRow) }
        if c.banners > 0 { fixed.append(c.banners) }
        if c.controls { fixed.append(Metric.controls) }
        if c.field { fixed.append(Metric.field + max(c.fieldText - Metric.fieldLine, 0)) }
        // The conversation's own cap grows by whatever the panel's does.
        let chatCap = IslandChat.maxHeight + max(maximum - maximumHeight, 0)
        let natural: Double = !c.chat.isEmpty ? IslandChat.height(c.chat, wraps: wraps, cap: chatCap)
            : (!c.greeting.isEmpty ? moeHeight(c.greeting, wraps: wraps) : 0)
        let rowCount = fixed.count + (natural > 0 ? 1 : 0)
        let chrome = Metric.top + Metric.bottom + Double(max(rowCount - 1, 0)) * Metric.gap
        let room = maximum - chrome - fixed.reduce(0, +)
        let chat = natural > 0 ? min(natural, max(room, minimumChat)) : 0
        let total = chrome + fixed.reduce(0, +) + chat
        return (min(max(total, minimumHeight), maximum), chat)
    }
}

/// The meeting panel's controls behind the same ⋯ (2026-09-24): mark this
/// moment, off the record, screenshot, clip the screen, stop and write the
/// notes. Off the record and a running clip change what is being recorded,
/// so while either is on it is also drawn outside the ⋯: a clip nobody can
/// find the stop for is a clip that goes on recording.
public enum MeetingTray {

    public enum Control: Equatable, Sendable {
        case mark
        /// Shows its state: plain while on the record, filled in while off.
        case offRecord(on: Bool)
        case screenshot
        /// Shows its state: filled in while the screen is being clipped.
        case clip(on: Bool)
        /// Stop the recording and write the notes. Red.
        case stop
    }

    public static func controls(recording: Bool, offRecord: Bool, screenshots: Bool,
                                clips: Bool, clipping: Bool) -> [Control] {
        guard recording else { return [] }
        var c: [Control] = [.mark, .offRecord(on: offRecord)]
        if screenshots { c.append(.screenshot) }
        if clips { c.append(.clip(on: clipping)) }
        c.append(.stop)
        return c
    }

    /// What stays in view with the ⋯ shut: anything that is changing what
    /// gets recorded right now.
    public static func outside(_ controls: [Control]) -> [Control] {
        controls.filter {
            switch $0 {
            case .offRecord(on: true), .clip(on: true): return true
            default: return false
            }
        }
    }
}

/// The dropdown's conversation as a chat (the owner, 2026-09-24): "it should
/// be a regular chat box … one side is you and one side is the output, and
/// you could scroll up", with the whole session in it. The rows here are what
/// `IslandView` draws and what `Dropdown.chatHeight` counts, so the two agree.
public enum IslandChat {

    public enum Row: Equatable, Sendable {
        /// Your words, a bubble on the right. `live` while you are talking.
        case you(id: String, text: String, live: Bool)
        /// What you typed while Moe was still working, waiting to go.
        case queued(text: String)
        /// Moe's answer, on the left.
        case moe(id: String, text: String)
        /// A note from the app (an error, "Stopped."), dim, on the left.
        case system(id: String, text: String)
        /// What Moe is doing right now, as its newest row: "Thinking", then
        /// the step. It is added under the conversation, never in place of it.
        case working(label: String)
        /// "Noted · Undo" lines under an answer.
        case noted(id: String, count: Int)
        /// What Moe did for an answer, folded to one line under it ("3 steps
        /// · 48 s · 1 source ›"); `lines` are the steps and sources while it
        /// is opened, empty while folded (the owner, 2026-11-13: a live line
        /// while working, then folded, on both surfaces).
        case steps(id: String, summary: String, lines: [String])
        /// Send · Edit · Copy, Yes or Retry under the newest turn
        /// (`ReplyActions`), one row of small buttons.
        case actions(id: String, labels: [String])

        public var id: String {
            switch self {
            case .you(let id, _, _), .moe(let id, _), .system(let id, _), .noted(let id, _),
                 .steps(let id, _, _), .actions(let id, _): return id
            case .working: return "working"
            case .queued: return "queued"
            }
        }
    }

    /// Past this many characters your message shows its start and a More.
    /// Moe's answers are never cut: the answer is what you came to read
    /// (the owner, 2026-09-25); a long one scrolls.
    public static let youLimit = 280

    /// The start of `text`, cut at a word near `limit`, or nil when it fits.
    public static func clipped(_ text: String, limit: Int) -> String? {
        guard text.count > limit else { return nil }
        let head = text.prefix(limit)
        let cut = head.lastIndex(where: { $0 == " " || $0 == "\n" }).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // Every number is read off `IslandView.chatRow`.
    public static let gap = 10.0
    public static let moeSize = 14.0
    public static let moeLine = 19.0
    /// Between the blocks of one answer, and inside a quote's card.
    public static let blockGap = 8.0
    public static let boxPad = 10.0
    public static let systemSize = 12.0
    public static let systemLine = 16.0
    /// The "More" under a clipped message.
    public static let more = 18.0
    public static let notedLine = 16.0
    /// The folded steps line under an answer, and each step once opened.
    public static let stepsLine = 18.0
    /// The row of action buttons: 24-pt targets.
    public static let actionsLine = 24.0
    public static let stepLine = 16.0
    /// Under the steps line, above the opened list.
    public static let stepsGap = 4.0
    /// Past this the conversation scrolls, pinned to its newest row.
    public static let maxHeight = 290.0

    /// Added to every row: AppKit's measurement came out a few points under
    /// SwiftUI's drawing per row, which over a conversation cut the oldest
    /// visible line in half at the top.
    public static let rowSlack = 3.0

    public static func height(_ row: Row, wraps: ConversationPanel.Wraps = ConversationPanel.estimate) -> Double {
        rowSlack + drawn(row, wraps: wraps)
    }

    private static func drawn(_ row: Row, wraps: ConversationPanel.Wraps) -> Double {
        let width = Dropdown.Metric.width - Dropdown.Metric.side * 2 - 16
        switch row {
        case .you(_, let text, _):
            let shown = clipped(text, limit: youLimit) ?? text
            let lines = max(wraps(shown, Dropdown.youTextWidth - 8, Dropdown.Metric.youSize), 1)
            return Double(lines) * Dropdown.Metric.youLineHeight + Dropdown.Metric.youPadV * 2
                + (clipped(text, limit: youLimit) == nil ? 0 : more)
        case .moe(_, let text):
            return answerHeight(text, width: width, wraps: wraps)
        case .system(_, let text):
            return Double(max(wraps(text, width, systemSize), 1)) * systemLine
        case .working:
            return moeLine
        case .queued(let text):
            let lines = max(wraps(text, Dropdown.youTextWidth - 8, Dropdown.Metric.youSize), 1)
            return Double(lines) * Dropdown.Metric.youLineHeight + Dropdown.Metric.youPadV * 2 + more
        case .noted(_, let count):
            return Double(count) * notedLine
        case .steps(_, _, let lines):
            return stepsLine + (lines.isEmpty ? 0 : stepsGap + Double(lines.count) * stepLine)
        case .actions:
            return actionsLine
        }
    }

    // The blocks of an answer, as `IslandView.islandBlock` draws them.
    /// Between the paragraphs (lines) of one block of prose.
    public static let paragraphGap = 4.0
    /// Between the items of a list.
    public static let listGap = 3.0
    /// A list item's text starts this far in from its marker's left edge,
    /// plus `listIndent` per level.
    public static let listMarker = 18.0
    public static let listIndent = 16.0
    /// Code: monospaced, under a header with its language and Copy.
    public static let codeSize = 12.5
    public static let codeLine = 17.0
    public static let codeHeader = 20.0
    /// A monospaced line is wider than the system font's at the same size;
    /// measured as if the font were this much larger, erring wide.
    public static let monoWidth = 1.2
    /// Tables of up to this many columns are drawn on the card; wider ones
    /// fold to one line that opens the window.
    public static let tableColumnsOnCard = 3
    public static let tableSize = 12.5
    public static let tableLine = 17.0
    public static let tableRowPad = 6.0

    /// One answer's height, block by block, at `width`.
    public static func answerHeight(_ text: String, width: Double,
                                    wraps: ConversationPanel.Wraps = ConversationPanel.estimate) -> Double {
        let blocks = ReplyBlocks.parse(text)
        guard !blocks.isEmpty else { return moeLine }
        let body = blocks.map { blockHeight($0, width: width, wraps: wraps) }.reduce(0, +)
        return body + Double(blocks.count - 1) * blockGap
    }

    public static func blockHeight(_ block: ReplyBlock, width: Double,
                                   wraps: ConversationPanel.Wraps = ConversationPanel.estimate) -> Double {
        func lines(_ s: String, _ w: Double, _ size: Double) -> Double { Double(max(wraps(s, w, size), 1)) }
        switch block {
        case .prose(let s):
            let paragraphs = ReplyBlock.paragraphs(s)
            return paragraphs.map { lines($0, width, moeSize) * moeLine }.reduce(0, +)
                + Double(max(paragraphs.count - 1, 0)) * paragraphGap
        case .heading(let s):
            return lines(s, width, moeSize) * moeLine
        case .quote(let s):
            return lines(s, width - boxPad * 2, moeSize) * moeLine + boxPad * 2
        case .code(let s, _):
            let body = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { lines(String($0).isEmpty ? " " : String($0), width - boxPad * 2, codeSize * monoWidth) }
                .reduce(0, +)
            return codeHeader + body * codeLine + boxPad * 2
        case .list(let items):
            return items.map { item in
                lines(item.text, width - listMarker - Double(item.level) * listIndent, moeSize) * moeLine
            }.reduce(0, +) + Double(max(items.count - 1, 0)) * listGap
        case .table(let t):
            guard t.columns <= tableColumnsOnCard, t.columns > 0 else { return moeLine }
            let column = (width - boxPad * 2) / Double(t.columns)
            let all = [t.header] + t.rows
            let rows = all.map { row in
                (0..<t.columns).map { c in
                    lines(row.indices.contains(c) ? row[c] : " ", column - 8, tableSize)
                }.max() ?? 1
            }
            return rows.map { $0 * tableLine + tableRowPad }.reduce(0, +) + boxPad
        }
    }

    /// The conversation's drawn height: every row and the gaps between,
    /// up to `cap` (`maxHeight` on hover), past which it scrolls.
    public static func height(_ rows: [Row], wraps: ConversationPanel.Wraps = ConversationPanel.estimate,
                              cap: Double = maxHeight) -> Double {
        guard !rows.isEmpty else { return 0 }
        let total = rows.map { height($0, wraps: wraps) }.reduce(0, +) + Double(rows.count - 1) * gap
        return min(total, cap)
    }
}
