import Foundation

/// Which parts of the brief a conversation has already been told, so a turn
/// carries only what changed.
///
/// The brief rides on the person's message (a system prompt that changes
/// restarts the model — see `BrainPrompt.briefBlock`), and whatever rides on
/// a message stays in the transcript and is re-read on every later turn. It
/// was sent whole whenever its bytes changed, and its bytes change every ten
/// minutes whether or not anything happened: `sync.sh` stamps the top with
/// the minute it ran. Measured over 1,325 turns
/// (docs/SPEED-FINDINGS-2026-11-12.md): the brief went out whole on 288 of
/// them — 2.93 M characters, 16% of everything those conversations re-read —
/// and the context that builds is the largest single multiplier on how long
/// the first word takes (×2.6 from under 80k tokens to over 250k).
///
/// So: the whole brief the first time a session sees it. After that, nothing
/// when only the stamps moved; and when its words did, only the lines that
/// are new and the lines that are gone, part by part.
///
/// Replayed over the 272 whole briefs that really rode on a turn
/// (2026-09-16 → 11-12, a line-for-line copy of this rule): 2.53 M
/// characters become 0.99 M, **39%**, and the typical update is 0.9 KB where
/// the brief is 9.3 KB. Cutting at the `## ` headings alone and resending a
/// changed part whole — the first version of this — left 61%: one new
/// message resent every message beside it.
///
/// **Nothing is dropped and nothing is judged.** A line that left is always
/// reported, even a message that merely aged out of a "recent" list: telling
/// an old message from a finished task would take knowing which parts are
/// logs, and a list of names is walked past by the next name. Suppressing
/// aged-out records was measured too and bought three points (36%).
///
/// **The whole brief again every `refreshEvery` messages**, for the reason
/// `DeliveryReminderLedger` gives: an update leans on the full copy still
/// being in the transcript, a long session's transcript is compacted into a
/// summary, and nothing tells Moe when. A count needs no signal.
///
/// Keyed by session id, as the ledger it replaced was: every path that
/// leaves the model without its transcript rotates the id already.
public struct BriefLedger: Sendable {
    /// A full brief on message 1, 21, 41, … of a session.
    public static let refreshEvery = 20

    public enum Send: Equatable, Sendable {
        /// The model already has all of it.
        case nothing
        /// The brief, whole.
        case full(String)
        /// Only what changed since the last time this session was told.
        case update(String)
    }

    /// One part of the brief: a `## ` section, a `### ` part of one, or
    /// whatever comes before the first heading.
    struct Part: Equatable, Sendable {
        /// "" (the top), "Tasks", "Inbound (recent) / whatsapp".
        let key: String
        /// The `## ` section this belongs under, when it is a `### ` part.
        let parent: String?
        /// The part as the file has it, heading line first.
        let raw: [String]
        /// Its lines for comparison — see `words(of:)`.
        let words: [String]
    }

    private var session: String?
    private var told: [Part] = []
    /// Messages sent into `session` since (and including) the last full one.
    private var sinceFull = 0

    public init() {}

    /// What a turn about to go into `session` should carry of `brief` (the
    /// file's text). A brain with no session to name (`""`) cannot be known
    /// to have kept anything, so it gets the whole brief whenever its words
    /// differ — what every brain got before this — and never an update.
    public mutating func next(brief: String, session: String) -> Send {
        let now = Self.parts(of: brief)
        guard !session.isEmpty else {
            let known = self.session == nil && Self.same(now, told)
            self.session = nil
            told = now
            sinceFull = 1
            return known ? .nothing : .full(brief)
        }
        // A session that has not seen it (or was only ever shown an empty
        // one), or one whose full copy is far enough back that it may have
        // been compacted away: all of it, even when it is word for word the
        // one sent before.
        if self.session != session || told.isEmpty || sinceFull >= Self.refreshEvery {
            self.session = session
            told = now
            sinceFull = 1
            return .full(brief)
        }
        sinceFull += 1
        guard !Self.same(now, told) else { return .nothing }
        let update = Self.update(from: told, to: now)
        told = now
        // Only the order of things moved: nothing to say.
        return update.isEmpty ? .nothing : .update(update)
    }

    // MARK: - What changed

    /// The marker lines of a part sent as a change rather than whole. Named
    /// in the block's own instructions (`BrainPrompt.briefUpdateBlock`).
    public static let newLines = "New:"
    public static let goneLines = "No longer listed:"

    static func update(from told: [Part], to now: [Part]) -> String {
        var out: [String] = []
        var headed: String?          // the `## ` section the last piece sits under
        for part in now {
            let before = told.first { $0.key == part.key }
            let was = Set(before?.words ?? []), are = Set(part.words)
            let added = part.words.filter { !was.contains($0) }
            let removed = (before?.words ?? []).filter { !are.contains($0) }
            // Unchanged, or the same lines in another order: nothing to say.
            if before != nil, added.isEmpty, removed.isEmpty { continue }
            var text: [String] = []
            // A `### ` part is shown under its section's heading, written
            // once, so "whatsapp" is never read without "Inbound".
            if let parent = part.parent, headed != parent {
                text.append("## " + parent)
                text.append("")
            }
            headed = part.parent ?? part.key
            if before == nil || added.count + removed.count >= part.words.count {
                // New, or mostly different: the part as it now is, whole. It
                // replaces the copy the conversation had.
                text.append(contentsOf: part.raw)
            } else {
                if let heading = part.raw.first, heading.hasPrefix("#") { text.append(heading) }
                if !added.isEmpty { text.append(newLines); text.append(contentsOf: added) }
                if !removed.isEmpty { text.append(goneLines); text.append(contentsOf: removed) }
            }
            out.append(text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let gone = told.map(\.key).filter { key in !key.isEmpty && !now.contains { $0.key == key } }
        if !gone.isEmpty {
            out.append("_No longer in the brief: " + gone.joined(separator: ", ") + "._")
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: - Parts

    /// The brief cut at its `## ` and `### ` headings. A part with no words
    /// of its own — a section that is only a heading over its `### ` parts —
    /// is not one.
    static func parts(of brief: String) -> [Part] {
        var open: [(key: String, parent: String?, raw: [String])] = [("", nil, [])]
        var section = ""
        for line in brief.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                open.append((section, nil, [line]))
            } else if line.hasPrefix("### "), !section.isEmpty {
                let name = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                open.append((section + " / " + name, section, [line]))
            } else {
                open[open.count - 1].raw.append(line)
            }
        }
        return open.compactMap { part in
            let words = Self.words(of: part.raw)
            guard !words.isEmpty else { return nil }
            var raw = part.raw
            while let last = raw.last, last.trimmingCharacters(in: .whitespaces).isEmpty { raw.removeLast() }
            return Part(key: part.key, parent: part.parent, raw: raw, words: words)
        }
    }

    /// A part's lines for comparison: trimmed, without its heading, without
    /// blank lines, and without the two stamps `sync.sh` rewrites on every
    /// run — `_Refreshed Thursday 12 November, 11:54 AM._` at the top and
    /// `_As of 11:54 AM — the Now line on each message is the clock._` under
    /// the calendar. Everything else counts: a calendar line whose "in 20
    /// min" became "in 10 min" IS a change, and is sent, because a stale
    /// label is how a finished meeting gets called upcoming (ticket #9).
    static func words(of lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            guard !line.isEmpty, !line.hasPrefix("## "), !line.hasPrefix("### ") else { return false }
            if line.hasPrefix("_Refreshed ") && line.hasSuffix("._") { return false }
            if line.hasPrefix("_As of ") && line.hasSuffix("_") { return false }
            return true
        }
    }

    private static func same(_ a: [Part], _ b: [Part]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.words == $1.words }
    }
}
