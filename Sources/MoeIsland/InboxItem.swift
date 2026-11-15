import Foundation

/// One thing Moe brought to the person on its own: a reminder, a question,
/// work it has ready, a brief, a heads-up. The inbox's row, the reading
/// card's page, and the app's Inbox list are all drawn from this.
///
/// Before this there was no such thing. The island held one string, and a
/// 13 KB marketing brief arrived as three lines cut off mid-sentence under
/// "Earlier, at 8:30 AM", with Dismiss / Reply / Play whatever it was (the
/// owner, 2026-09-29: "What even is that? I can't even see what that says").
/// Dismiss threw it away, nothing told its source, and Reply dropped it into
/// whatever conversation happened to be open. docs/INBOX.md is the design.
public struct InboxItem: Codable, Equatable, Identifiable, Sendable {

    /// What it is, which decides what can be done about it.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Something the person asked to be reminded of, or a follow-up Moe
        /// is keeping: Done, Snooze.
        case reminder
        /// Moe wants an answer: its options as chips, or words.
        case question
        /// The work is done and waiting for a yes: an offer's draft.
        case work
        /// A report to read: a job's briefing, a digest.
        case brief
        /// Worth knowing, nothing to do: a ticket fixed, a setup note.
        case headsUp

        public var label: String {
            switch self {
            case .reminder: return "Reminder"
            case .question: return "Question"
            case .work: return "Ready for you"
            case .brief: return "Brief"
            case .headsUp: return "Heads-up"
            }
        }

        /// Whether it waits for the person, or is only for their information.
        public var needsYou: Bool { self != .headsUp }
    }

    public enum Status: String, Codable, Sendable {
        /// Waiting. Counted on the island unless hidden or snoozed.
        case open
        /// Finished: Done, Got it, answered, sent. It told its source, and it
        /// never comes back.
        case done
    }

    public let id: String
    public var kind: Kind
    /// A few words: what it is. Never the start of the body cut short.
    public var title: String
    /// One or two sentences: why it is here, readable on its own.
    public var summary: String
    /// Everything, as it arrived. The reading card shows this.
    public var body: String
    /// When it was for (a late reminder keeps its original time).
    public var at: Date
    public var status: Status = .open
    /// ✕ on the island: out of the island's list, still in the app's.
    public var hidden = false
    public var snoozedUntil: Date?
    /// Opened, or the inbox looked at while it was there: it no longer makes
    /// the notch glow.
    public var seen = false
    public var doneAt: Date?
    /// What finished it, in the person's words: "Done", "Snoozed", "Sent".
    public var outcome: String?
    /// Answers offered as chips (a question's), in order.
    public var options: [String] = []
    /// The job it came from, by name, for the card's by-line.
    public var source: String = ""

    // What it can be changed through: the same fields the island's handle
    // always carried (`Conductor.NudgeHandle`), kept so an action on an old
    // notice still reaches the follow-up or the job behind it.
    public var job: String = ""
    public var jobID: String = ""
    public var loops: [String] = []
    public var said: String = ""
    public var instruction: String = ""
    public var offer: String = ""
    public var awayCarry: String = ""
    public var expiresAt: Date?
    public var expiredText: String = ""
    /// A finished helper's: the conversation it belongs to. "Open it" takes
    /// the person there, where the result is answered.
    public var openThread: String = ""
    /// The real-world thing it is about, when its writer knows: a situation
    /// (`situation:<id>`), a follow-up (`loop:<slug>`), a promise, a meeting,
    /// a routine. One open card per subject: a new notice about the same
    /// thing updates that card in place instead of adding one
    /// (docs/INBOX-QUIET.md decision 8). Empty: matched by its words only.
    public var subject: String = ""
    /// A pack its one button buys — `voice` or `hours` — on the app's own
    /// card at 80 % of a plan's allowance (docs/PLANS-AND-CAPS-2026-11-13.md
    /// §7 D7). Empty on every other card.
    public var buy: String = ""
    /// That button's words ("Add 100 hours · $5").
    public var buyTitle: String = ""

    public init(id: String = UUID().uuidString, kind: Kind, title: String, summary: String,
                body: String, at: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.body = body
        self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, summary, body, at, status, hidden, snoozedUntil, seen, doneAt, outcome,
             options, source, job, jobID, loops, said, instruction, offer, awayCarry, expiresAt, expiredText,
             openThread, subject, buy, buyTitle
    }

    /// Every field but the first six is optional on disk, so a file written
    /// before a field existed still reads, and nothing is lost to a version.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .headsUp
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        at = try c.decode(Date.self, forKey: .at)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .open
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        job = try c.decodeIfPresent(String.self, forKey: .job) ?? ""
        jobID = try c.decodeIfPresent(String.self, forKey: .jobID) ?? ""
        loops = try c.decodeIfPresent([String].self, forKey: .loops) ?? []
        said = try c.decodeIfPresent(String.self, forKey: .said) ?? ""
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        offer = try c.decodeIfPresent(String.self, forKey: .offer) ?? ""
        awayCarry = try c.decodeIfPresent(String.self, forKey: .awayCarry) ?? ""
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        expiredText = try c.decodeIfPresent(String.self, forKey: .expiredText) ?? ""
        openThread = try c.decodeIfPresent(String.self, forKey: .openThread) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        buy = try c.decodeIfPresent(String.self, forKey: .buy) ?? ""
        buyTitle = try c.decodeIfPresent(String.self, forKey: .buyTitle) ?? ""
    }

    /// Waiting, and not snoozed past `now`.
    public func isWaiting(now: Date = Date()) -> Bool {
        guard status == .open else { return false }
        if let until = snoozedUntil, until > now { return false }
        return true
    }

    /// On the island's list: waiting, and not hidden there.
    public func onIsland(now: Date = Date()) -> Bool { isWaiting(now: now) && !hidden }
}

// MARK: - Deciding what it is

/// Everything a writer can say about a message, in the inbox file's own
/// terms (`ReminderChannels.Message`): the pure half of turning a file into
/// a notice, so it can be tested without a Mac.
public struct NoticeInput: Sendable {
    public var text: String
    public var at: Date
    public var title = ""
    public var summary = ""
    public var kind = ""
    public var options: [String] = []
    public var job = ""
    public var jobID = ""
    public var loops: [String] = []
    public var said = ""
    public var instruction = ""
    public var offer = ""
    public var awayCarry = ""
    public var expiredText = ""
    public var source = ""
    public var openThread = ""
    /// The inbox file's `subject`, when its writer named one.
    public var subject = ""

    public init(text: String, at: Date) {
        self.text = text
        self.at = at
    }
}

public enum NoticeMaker {

    /// Longer than this, and it is something to read, not a line to glance at.
    public static let briefLength = 420

    public static func kind(of m: NoticeInput) -> InboxItem.Kind {
        if let declared = InboxItem.Kind(rawValue: m.kind) { return declared }
        if !m.offer.isEmpty { return .work }
        // A held send: Moe is asking whether it may go.
        if !m.expiredText.isEmpty { return .question }
        if !m.options.isEmpty { return .question }
        if !m.awayCarry.isEmpty || !m.openThread.isEmpty { return .headsUp }
        let text = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > briefLength { return .brief }
        if !m.loops.isEmpty { return .reminder }
        if !m.jobID.isEmpty && !isMoeJob(m.job) { return .reminder }
        if text.hasSuffix("?") { return .question }
        // A support ticket's update, an away notice, Moe's own heads-up.
        if !m.instruction.isEmpty || isMoeJob(m.job) || m.job.isEmpty { return .headsUp }
        return .reminder
    }

    public static func make(_ m: NoticeInput, id: String = UUID().uuidString) -> InboxItem {
        let kind = kind(of: m)
        let words = NoticeWords.derive(text: m.text, job: m.job, kind: kind)
        var n = InboxItem(id: id, kind: kind,
                       title: m.title.isEmpty ? words.title : NoticeWords.oneLine(m.title, max: 70),
                       summary: m.summary.isEmpty ? words.summary : m.summary,
                       body: m.text, at: m.at)
        n.options = m.options
        n.source = m.source.isEmpty ? NoticeWords.jobLabel(m.job) : m.source
        n.job = m.job
        n.jobID = m.jobID
        n.loops = m.loops
        n.said = m.said
        n.instruction = m.instruction
        n.offer = m.offer
        n.awayCarry = m.awayCarry
        n.expiredText = m.expiredText
        n.openThread = m.openThread
        n.subject = subject(of: m)
        return n
    }

    /// What the notice is about, as a key: the writer's own when it gave
    /// one, else the situation an offer came from, else the first follow-up
    /// it names. Worked out here as well as in deliver.py, so a file written
    /// by an older plugin still finds its card (a guard that only lives
    /// upstream is undone by the staleness it guards against).
    public static func subject(of m: NoticeInput) -> String {
        let given = String(m.subject.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces).prefix(120))
        if !given.isEmpty { return given }
        if !m.offer.isEmpty { return "situation:" + m.offer }
        if let first = m.loops.first(where: { !$0.isEmpty }) { return "loop:" + first }
        return ""
    }

    /// Moe's own background jobs are all named `moe-…` (deliver.is_moe_job).
    public static func isMoeJob(_ job: String) -> Bool { job.lowercased().hasPrefix("moe-") }
}

// MARK: - A title and a summary from whatever arrived

public enum NoticeWords {

    /// The title and the one-or-two sentences the island shows, from the
    /// text itself when the writer gave neither.
    ///
    /// The brief of 2026-09-29 began "**Marketing brief, Tue 09-29**" and
    /// then "**Reply draft for you to post (r/mac, …)**": a short first line
    /// is a title; a body built from bold headings is summarised by them,
    /// because "Reply draft for you to post · Overdue · Due this week ·
    /// Postiz" says what is in it and its first sentence does not.
    public static func derive(text: String, job: String, kind: InboxItem.Kind) -> (title: String, summary: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return (jobLabel(job).isEmpty ? "Moe" : jobLabel(job), "") }

        var title = ""
        var rest = Array(lines.dropFirst())
        let firstBare = bare(first)
        if lines.count > 1, firstBare.count <= 70, !firstBare.hasSuffix("."), !first.hasPrefix(">"),
           !first.hasPrefix("- ") {
            title = firstBare.hasSuffix(":") ? String(firstBare.dropLast()) : firstBare
        } else {
            rest = lines
        }

        let headings = rest.compactMap(sectionHeading)
        let prose = rest.filter { sectionHeading($0) == nil && !$0.hasPrefix(">") }
        var summary: String
        if kind == .brief, headings.count >= 2 {
            summary = headings.prefix(5).joined(separator: " · ")
        } else {
            summary = firstSentences(prose.map(bare).joined(separator: " "), max: 170)
        }

        if title.isEmpty {
            let label = jobLabel(job)
            // Only a brief is named after its job: ready work and a
            // reminder say what they are in their own first sentence.
            if kind == .brief, !label.isEmpty {
                title = label
            } else {
                // Short enough to be its own title: then the summary is
                // what follows it, never the same words twice.
                let all = prose.map(bare).joined(separator: " ")
                if all.count <= 70 {
                    title = all
                    summary = ""
                } else {
                    // The first sentence is the title, whole where it fits
                    // two lines; the summary is what follows it, never the
                    // same words again (the owner, 2026-09-29: "Andrew
                    // Wilson Follow Up… · Andrew Wilson Follow Up…").
                    let first = firstSentence(all)
                    title = first.count <= 110 ? first : oneLine(first, max: 100)
                    summary = firstSentences(String(all.dropFirst(first.count)), max: 170)
                }
            }
        }
        return (oneLine(title, max: 110), summary)
    }

    /// A line that is only a bold phrase, or a "# heading": a section name,
    /// cut at its first bracket or colon ("Overdue: Week 1 ended…" → "Overdue").
    static func sectionHeading(_ line: String) -> String? {
        var s: Substring
        if line.hasPrefix("#") {
            s = Substring(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4,
                  !line.dropFirst(2).dropLast(2).contains("**") {
            s = line.dropFirst(2).dropLast(2)
        } else if line.hasPrefix("**"), let close = line.dropFirst(2).range(of: ":**") {
            // "**Postiz:** clean. …": a section named in bold at the start.
            s = line.dropFirst(2)[..<close.lowerBound]
        } else {
            return nil
        }
        if let cut = s.firstIndex(where: { $0 == "(" || $0 == ":" || $0 == "—" }) { s = s[..<cut] }
        let out = s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",.")))
        return out.isEmpty ? nil : out
    }

    /// The words without markdown's markers.
    public static func bare(_ s: String) -> String {
        var t = s
        for m in ["**", "__", "`"] { t = t.replacingOccurrences(of: m, with: "") }
        while t.hasPrefix("#") { t.removeFirst() }
        if t.hasPrefix("> ") { t.removeFirst(2) }
        if t.hasPrefix("- ") || t.hasPrefix("* ") { t.removeFirst(2) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Up to `max` characters, ending on a sentence where one ends in time,
    /// else on a word, with an ellipsis only when something was cut.
    public static func firstSentences(_ s: String, max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        let head = String(t.prefix(max))
        if let end = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: end.lowerBound) > max / 3 {
            return String(head[..<end.lowerBound]) + "."
        }
        return oneLine(t, max: max)
    }

    /// Up to and including the first ". ", "? " or "! "; the whole of it
    /// when there is none.
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        var prev: Character = " "
        for (i, c) in t.enumerated() {
            if c == " ", ".?!".contains(prev) { return String(t.prefix(i)) }
            prev = c
        }
        return t
    }

    public static func oneLine(_ s: String, max: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard t.count > max else { return t }
        var head = String(t.prefix(max - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > max / 2 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;:—-"))) + "…"
    }

    /// A job's name as a person would say it. Moe's own jobs have names only
    /// this repo knows; the person's own are theirs, as they wrote them.
    public static func jobLabel(_ job: String) -> String {
        let j = job.trimmingCharacters(in: .whitespaces)
        switch j.lowercased() {
        case "": return ""
        case "moe-calendar-heads-up": return "Calendar"
        case "moe-proactive", "moe-loop-check": return "Follow-up"
        case "moe-situations": return "Ready for you"
        case "moe-away": return "Away"
        case "moe-tickets": return "Support"
        default:
            if NoticeMaker.isMoeJob(j) { return "Moe" }
            return j
        }
    }
}

// MARK: - The reading card's page

/// The body as the reading card lays it out: headings, paragraphs, lists,
/// to-dos and drafts. A draft (a quoted block) gets its own card with Copy,
/// because a draft is something to take somewhere else.
public enum NoticeBlock: Equatable, Sendable {
    case heading(String)
    case prose(String)
    case draft(String)
    case bullets([String])
    case todo([String])
}

public enum NoticeBody {

    public static func blocks(_ text: String) -> [NoticeBlock] {
        var out: [NoticeBlock] = []
        var prose: [String] = []
        var quote: [String] = []
        var bullets: [String] = []
        var todos: [String] = []
        var inFence = false

        func flushProse() {
            let p = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { out.append(.prose(p)) }
            prose = []
        }
        func flushQuote() {
            let q = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty { out.append(.draft(q)) }
            quote = []
        }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !todos.isEmpty { out.append(.todo(todos)); todos = [] }
        }
        func flushAll() { flushProse(); flushQuote(); flushLists() }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inFence { flushQuote(); inFence = false } else { flushAll(); inFence = true }
                continue
            }
            if inFence { quote.append(line); continue }
            if t.hasPrefix(">") {
                if quote.isEmpty { flushProse(); flushLists() }
                var rest = Substring(t.dropFirst())
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quote.append(String(rest))
                continue
            }
            if !quote.isEmpty { flushQuote() }
            if t.isEmpty { flushProse(); flushLists(); continue }
            if let h = heading(t) { flushAll(); out.append(.heading(h)); continue }
            if let todo = todoItem(t) { flushProse(); if !bullets.isEmpty { flushLists() }; todos.append(todo); continue }
            if let item = bulletItem(t) { flushProse(); if !todos.isEmpty { flushLists() }; bullets.append(item); continue }
            flushLists()
            prose.append(line)
        }
        flushAll()
        return out
    }

    /// "# X", or a line that is only bold. The whole line, markers gone.
    static func heading(_ t: String) -> String? {
        if t.hasPrefix("#") {
            let hashes = t.prefix(while: { $0 == "#" }).count
            let rest = t.dropFirst(hashes)
            guard (1...4).contains(hashes), rest.first == " " else { return nil }
            let h = rest.trimmingCharacters(in: .whitespaces)
            return h.isEmpty ? nil : h
        }
        if t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4, !t.dropFirst(2).dropLast(2).contains("**") {
            var h = String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            if h.hasSuffix(":") { h.removeLast() }
            return h.isEmpty ? nil : h
        }
        return nil
    }

    static func bulletItem(_ t: String) -> String? {
        for m in ["- ", "* ", "• "] where t.hasPrefix(m) {
            return String(t.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
        }
        // "1. " / "1) "
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 2 {
            let rest = t.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func todoItem(_ t: String) -> String? {
        for m in ["- [ ] ", "* [ ] ", "- [x] ", "- [X] "] where t.hasPrefix(m) {
            return String(t.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Reply: a new conversation, unless it is this one

public enum NoticeThread {

    /// Whether a reply to `notice` belongs in the conversation on screen
    /// rather than a new one. The owner, 2026-09-29: a new conversation,
    /// unless the card is about what you are talking about right now.
    ///
    /// "Right now" is the last few minutes; "about" is sharing real words
    /// with what was said, never a guess about topics. An empty or idle
    /// conversation is never "this one".
    public static func continuesHere(notice: InboxItem, recent: [String], lastActivity: Date?,
                                     now: Date = Date()) -> Bool {
        guard let last = lastActivity, now.timeIntervalSince(last) < 10 * 60, !recent.isEmpty else {
            return false
        }
        let theirs = words(notice.title + " " + notice.summary)
        guard theirs.count >= 2 else { return false }
        let ours = words(recent.joined(separator: " "))
        return theirs.intersection(ours).count >= 2
    }

    static let stop: Set<String> = [
        "the", "and", "for", "you", "your", "with", "that", "this", "from", "have", "are", "was",
        "not", "but", "about", "what", "when", "will", "can", "all", "one", "out", "get", "has",
        "moe", "just", "today", "now", "here", "there", "they", "them", "their", "its", "into",
        "reply", "draft", "ready", "brief", "reminder", "remind", "need", "want", "would", "could",
    ]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stop.contains($0) })
    }
}

// MARK: - The island's list, measured

public enum InboxLayout {
    public static let width: Double = 460
    public static let header: Double = 44
    public static let section: Double = 26
    public static let rowChrome: Double = 20 + 8 + 30   // padding, gap, actions
    public static let lineHeight: Double = 17
    /// The island's window (`ConversationPanel.maximumHeight`); past it the
    /// list scrolls.
    public static let maxHeight: Double = 420
    public static let empty: Double = 120

    /// The island's height with the inbox open: the header, each section's
    /// label, each row by its title and summary lines, capped (it scrolls).
    public static func height(rows: [(title: String, summary: String, needsYou: Bool)],
                              charsPerLine: Int = 58) -> Double {
        guard !rows.isEmpty else { return header + empty }
        var h = header + 12
        let needs = rows.filter(\.needsYou).count
        if needs > 0 { h += section }
        if needs < rows.count { h += section }
        for r in rows {
            let summaryLines = r.summary.isEmpty ? 0 : min(3, (r.summary.count + charsPerLine - 1) / charsPerLine)
            h += rowChrome + lineHeight * Double(1 + summaryLines) + 16
        }
        return min(h, maxHeight)
    }
}
