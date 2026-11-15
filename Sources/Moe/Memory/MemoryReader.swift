import Foundation

// What the Memory page reads, how it is laid out, and how a change to one
// line is written. The view is MemoryPane.swift; everything here is plain
// data and blocking file/process work, so it can be tested without a window.
//
// Owner decisions 2026-09-22: every line is corrected where it stands —
// click it, type, Return; no sheet, no summary block — and (the third that
// day, design B) the page is a list of sections on the left, one section
// shown at a time on the right: `MemoryTab`, `sections`, `planAdd`.
//
// Where each line comes from:
//
//   * The daily crawl's profile, memory/profile/*.md, through
//     learn/profile.py — `list --json`, `correct`, `delete`, `restore`.
//     A correction is written with source `user`: merge.py never lets a
//     crawl add a competing line on that topic, consolidate.py never caps,
//     supersedes, archives or dedupes one away, and `expire` skips it — so
//     an edit survives the nightly pass. The old wording is tombstoned by id
//     and topic key so no crawl brings it back.
//   * Hermes's own memory, ~/.hermes/memories/USER.md and MEMORY.md. Those
//     files are claimstore's projection of the ledger: an editor's change is
//     absorbed as a new claim but a removal is never a retraction, so the
//     page never edits the files. It goes through claimstore's cli.py
//     (`list`, `correct`, `delete`), which appends retract/assert records on
//     this Mac's chain and re-projects the files before it returns. Only
//     when that cannot run (no Hermes interpreter) is a change handed to Moe
//     in Chat (`MemoryEdit.askMoe`).
//   * The crawl's open questions, memory/profile/questions.md.

/// One line on the page, whichever store it came from.
struct MemoryLine: Identifiable, Equatable {
    enum Origin: Equatable {
        /// Hermes's own memory: the `group` is "you" or "memory".
        case hermes(group: String)
        /// A crawl claim, by its ten-character id.
        case claim(id: String)
    }
    enum Section: String { case you, things }
    enum Sureness: String { case sure = "Sure", fairly = "Fairly sure", unsure = "Not sure" }
    /// A standing fact about a person or you, or something that happened.
    enum Kind: String { case stable, event }

    let id: String
    let section: Section
    let text: String
    let origin: Origin
    /// "WhatsApp · Sep 22" — shown faintly on hover.
    let source: String
    let sureness: Sureness?
    /// The profile file it came from ("people", "threads"…); "" for Hermes.
    var file: String = ""
    var kind: Kind = .stable
    /// False for a past event (or a superseded fact) the crawl still keeps.
    var active: Bool = true
    /// How many separate sightings back it up.
    var support: Int = 0
    /// yyyy-MM-dd, when it was last seen; sorts recency.
    var date: String = ""
    /// "new" or "contradicts", when the profile flags one.
    var flag: String? = nil
    /// For a line of Hermes's memory: its claim id in the ledger, which
    /// claimstore's cli.py takes. Nil when it was read off the file.
    var ledgerID: String? = nil
    /// A line the nightly tidy set aside (claimstore/tidy.py): the change
    /// that did it, which Restore puts back (cli.py undo). Shown under Past.
    var tidyChange: String? = nil
    /// A fact deleted before and noticed again by something that is not the
    /// person (§3.1): only their yes brings it back (cli.py revive). Asked
    /// in To check, never shown as a line.
    var revival: Bool = false

    var isClaim: Bool { if case .claim = origin { return true }; return false }
    var claimID: String? { if case .claim(let id) = origin { return id }; return nil }
}

/// One row of the page: a line, a line to check, a question, or a past line.
struct MemoryItem: Identifiable, Equatable {
    enum Role: Equatable { case line, check, question, past }
    let id: String
    let role: Role
    /// What is drawn — the line without its markdown bold.
    let text: String
    /// Nil for a question.
    let line: MemoryLine?

    static func of(_ line: MemoryLine, role: Role = .line) -> MemoryItem {
        MemoryItem(id: line.id, role: role, text: MemoryReader.shown(MemoryReader.plain(line.text)), line: line)
    }
    static func question(_ q: String) -> MemoryItem {
        MemoryItem(id: "q:" + q, role: .question, text: q, line: nil)
    }
}

/// One item of profile.py's "check these" list.
struct MemoryCheck: Equatable {
    enum Kind: String { case contradicts, question, unsure, new }
    let kind: Kind
    let text: String
    /// The claim ids it is about; empty for a free-text question.
    let ids: [String]

    /// Before `check` existed: every open question, about nothing in particular.
    static func fallback(_ questions: [String]) -> [MemoryCheck] {
        questions.map { MemoryCheck(kind: .question, text: $0, ids: []) }
    }
}

struct MemorySection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [MemoryItem]
}

/// What saving one line does. Decided from the line and the draft alone,
/// so the rules are testable without a window or a process.
enum MemoryEdit: Equatable {
    case nothing
    /// profile.py correct: the new wording is the person's own (`user`).
    case correct(id: String, text: String)
    /// profile.py delete, with its tombstones.
    case forget(id: String)
    /// profile.py confirm: the line is right, and becomes the person's own.
    case confirm(id: String)
    /// A line of Hermes's memory, by its ledger id: cli.py correct/delete.
    case correctMemory(id: String, text: String)
    case forgetMemory(id: String)
    /// A line of Hermes's memory with no ledger id (cli.py cannot run):
    /// the sentence Moe is asked to act on.
    case askMoe(String)
    /// profile.py dismiss: close a question without answering it.
    case dismiss(question: String)
    /// An answer to one of the crawl's questions: kept as the person's own
    /// line, and the question closed.
    case answer(question: String, text: String)
    /// "+ Add something Moe should know": a new line of the person's own,
    /// in a profile file (profile.py add — source `user`).
    case add(file: String, text: String)
    /// Put one change of the nightly tidy back (cli.py undo).
    case undoTidy(change: String)
    /// The person's answer about a deleted fact noticed again (cli.py revive).
    case revive(id: String, keep: Bool)
}

/// One section of the Memory page's own list (design B, 2026-09-22).
enum MemoryTab: String, CaseIterable {
    case you, people, now, check, chats, past

    var title: String {
        switch self {
        case .you: return "You"
        case .people: return "People"
        case .now: return "Right now"
        case .check: return "To check"
        case .chats: return "From your chats"
        case .past: return "Past"
        }
    }

    /// The one line under the heading.
    var subtitle: String {
        switch self {
        case .you: return "What Moe believes about you. Click a line to change it."
        case .people: return "The people in your life, as Moe knows them. Click a line to change it."
        case .now: return "What is going on for you at the moment. Click a line to change it."
        case .check: return "Moe isn't sure about these. Your answers set it straight."
        case .chats: return "Notes Moe kept from your conversations. Click a line to change it."
        case .past: return "Lines Moe no longer uses. Restore one to bring it back."
        }
    }

    /// The section with nothing in it: one quiet line.
    var empty: String {
        switch self {
        case .you: return "Nothing about you yet."
        case .people: return "No one yet."
        case .now: return "Nothing going on right now."
        case .check: return "Nothing to check."
        case .chats: return "No notes from your chats yet."
        case .past: return "Nothing in the past."
        }
    }

    /// The profile file "+ Add" writes to; nil where nothing can be added.
    /// You is the person's identity — the file the brain reads first.
    var addFile: String? {
        switch self {
        case .you: return "identity"
        case .people: return "people"
        case .now: return "threads"
        case .check, .chats, .past: return nil
        }
    }

    /// The empty field's hint.
    var addPrompt: String {
        switch self {
        case .people: return "Name — who they are to you"
        case .now: return "Something going on, e.g. Moving house in November"
        default: return "Something Moe should know about you"
        }
    }
}

enum MemoryReader {
    static let profileFiles = ["identity", "people", "threads", "voice", "preferences"]
    /// Where an answer to a question is kept. It is about the person, and
    /// identity.md is the file the brain reads first.
    static let answerFile = "identity"

    /// ~/.moe/learn/profile.py (installed), the app's copy, the checkout.
    /// `MOE_PROFILE_SCRIPT` goes first: the snapshot and the tests point it
    /// at their own checkout's copy.
    static func profileScript() -> String? {
        var candidates = [ProcessInfo.processInfo.environment["MOE_PROFILE_SCRIPT"] ?? "",
                          Paths.home.appendingPathComponent("learn/profile.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("learn/profile.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/learn/profile.py") { candidates.append(c) }
        return candidates.first { !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0) }
    }

    // MARK: Reading

    static func lines() -> [MemoryLine] { read().lines }

    /// What the page shows, and whether Moe was able to look at all.
    struct Reading {
        var lines: [MemoryLine] = []
        /// What Moe has learned about the person could not be read — the
        /// reader is missing or would not run. Not the same as there being
        /// nothing, and the page must not say "Nothing about you yet" then.
        var couldntLook = false
    }

    /// The page's one line when it could not read, in place of an empty
    /// section's "Nothing about you yet." — which is a different answer.
    static let couldntLookLine =
        "Moe couldn't look at what it knows about you just now. Nothing has been lost — open this page again in a moment."

    static func read() -> Reading {
        var out: [MemoryLine] = hermesLines() ?? []
        if out.isEmpty { for e in HermesMemory.read() {
            out.append(MemoryLine(id: "hermes:" + e.id,
                                  section: e.group == "you" ? .you : .things,
                                  text: e.text,
                                  origin: .hermes(group: e.group),
                                  source: "A conversation",
                                  sureness: nil))
        } }
        let learned = claimsIfReadable()
        out += learned ?? []
        out += tidied()
        out += revivals()
        return Reading(lines: out, couldntLook: learned == nil)
    }

    /// What the nightly tidy set aside in the last 30 days, as Past lines
    /// with Restore (claimstore cli.py `tidied`).
    static func tidied() -> [MemoryLine] {
        guard let py = hermesPython(), let cli = claimstoreCLI() else { return [] }
        let r = ScriptRunner.run(py, [cli, "tidied", "--json"], timeout: 20)
        guard r.status == 0 else { return [] }
        return parseTidied(r.output)
    }

    static func parseTidied(_ output: String) -> [MemoryLine] {
        guard let start = output.firstIndex(of: "["),
              let data = output[start...].data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [MemoryLine] = []
        for row in rows where row["undone"] == nil {
            guard let n = row["n"] as? String else { continue }
            let group = (row["target"] as? String) == "user" ? "you" : "memory"
            let after = ((row["after"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.first
            let kept = row["kept"] as? String
            let what: String
            switch row["do"] as? String ?? "" {
            case "merge": what = after.map { "Merged into “\($0)”" } ?? "Merged"
            case "rewrite": what = after.map { "Reworded as “\($0)”" } ?? "Reworded"
            case "duplicate": what = kept.map { "Already said in “\($0)”" } ?? "Said twice"
            case "settle": what = kept.map { "Disagreed with “\($0)”" } ?? "Disagreed with another line"
            case "staged": what = after.map { "Updated to “\($0)”" } ?? "Updated"
            default: what = "Over, so set aside"
            }
            let day = String(n.prefix(10))
            for (i, b) in ((row["before"] as? [[String: Any]]) ?? []).enumerated() {
                guard let text = b["text"] as? String, !text.isEmpty else { continue }
                out.append(MemoryLine(id: "tidy:\(n):\(i)", section: group == "you" ? .you : .things,
                                      text: text, origin: .hermes(group: group),
                                      source: "Tidied overnight · " + what, sureness: nil,
                                      active: false, date: day, tidyChange: n))
            }
        }
        return out
    }

    /// Deleted facts noticed again, waiting for the person's word (cli.py
    /// `revivals`).
    static func revivals() -> [MemoryLine] {
        guard let py = hermesPython(), let cli = claimstoreCLI() else { return [] }
        let r = ScriptRunner.run(py, [cli, "revivals", "--json"], timeout: 20)
        guard r.status == 0 else { return [] }
        return parseRevivals(r.output)
    }

    static func parseRevivals(_ output: String) -> [MemoryLine] {
        guard let start = output.firstIndex(of: "["),
              let data = output[start...].data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let text = row["text"] as? String, !text.isEmpty
            else { return nil }
            let group = (row["target"] as? String) == "user" ? "you" : "memory"
            let byPerson = row["by_person"] as? Bool ?? false
            return MemoryLine(id: "revive:" + id, section: group == "you" ? .you : .things, text: text,
                              origin: .hermes(group: group),
                              source: byPerson ? "You deleted this before" : "Moe had let this go",
                              sureness: nil, ledgerID: id, revival: true)
        }
    }

    /// The crawl's claims, through profile.py so the ids are the ones its
    /// correct/delete/restore take.
    static func claims() -> [MemoryLine] { claimsIfReadable() ?? [] }

    /// Nil when profile.py is missing or would not run. An empty profile is
    /// `[]` with exit 0 (measured against a fresh home), so nil is never
    /// "nothing learned yet" — it is "could not look", and the log says why.
    static func claimsIfReadable() -> [MemoryLine]? {
        guard let script = profileScript() else {
            Log.write("memory: profile.py is not installed; the page cannot read what Moe has learned")
            return nil
        }
        let r = ScriptRunner.run(BrainSetup.python(), [script, "list", "--json"], timeout: 20)
        guard r.status == 0 else {
            Log.write("memory: profile.py list did not run (status \(r.status)\(r.timedOut ? ", timed out" : "")): "
                      + ScriptRunner.Result.humanLine(in: r.output))
            return nil
        }
        return parseClaims(r.output)
    }

    // MARK: Hermes's memory, through claimstore

    /// claimstore's cli.py: `MOE_CLAIMSTORE_CLI`, the installed plugin, the
    /// app's payload, the checkout.
    static func claimstoreCLI() -> String? {
        var candidates = [TestHooks.env("MOE_CLAIMSTORE_CLI") ?? "",
                          HermesMemory.dir().deletingLastPathComponent()
                              .appendingPathComponent("plugins/claimstore/cli.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes-plugins/claimstore/cli.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes-plugins/claimstore/cli.py") { candidates.append(c) }
        return candidates.first { !$0.isEmpty && FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Hermes's own interpreter: cli.py seals with `cryptography` and
    /// projects with Hermes's `tools.memory_tool`; no other Python has either.
    static func hermesPython() -> String? {
        if let env = TestHooks.env("MOE_HERMES_PYTHON") { return env }
        let venv = HermesMemory.dir().deletingLastPathComponent()
            .appendingPathComponent("hermes-agent/.venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: venv) ? venv : nil
    }

    /// Hermes's memory from the ledger, with the ids cli.py takes. Nil when
    /// cli.py cannot run; the page then reads the files.
    static func hermesLines() -> [MemoryLine]? {
        guard let py = hermesPython(), let cli = claimstoreCLI() else { return nil }
        let r = ScriptRunner.run(py, [cli, "list", "--json"], timeout: 20)
        guard r.status == 0 else { return nil }
        return parseHermes(r.output)
    }

    static func parseHermes(_ output: String) -> [MemoryLine]? {
        guard let start = output.firstIndex(of: "["),
              let data = output[start...].data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let text = row["text"] as? String, !text.isEmpty
            else { return nil }
            let group = (row["target"] as? String) == "user" ? "you" : "memory"
            let source = (row["source"] as? String ?? "").hasPrefix("user") ? "Your words" : "A conversation"
            return MemoryLine(id: "hermes:" + id, section: group == "you" ? .you : .things, text: text,
                              origin: .hermes(group: group), source: source, sureness: nil,
                              ledgerID: id)
        }
    }

    /// Whether a line speaks as Moe — "I", "me", "my" outside quotes. Such a
    /// USER.md line reads as the person's own words on the page, so it is
    /// not shown under "You" until it has been reworded.
    static func speaksAsMoe(_ text: String) -> Bool {
        let unquoted = text.replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: "", options: .regularExpression)
        return unquoted.range(of: #"\b(I|I'm|I've|I'll|I'd|me|my|myself)\b"#,
                              options: .regularExpression) != nil
    }

    /// `profile.py list --json`, as lines. Every field the 2026-09-22
    /// contract added is optional: no `active` is active, no `kind` is an
    /// event in threads.md and stable elsewhere, no `support` is 0.
    static func parseClaims(_ output: String) -> [MemoryLine] {
        guard let start = output.firstIndex(of: "["),
              let data = output[start...].data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let text = row["text"] as? String, !text.isEmpty else { return nil }
            let file = row["file"] as? String ?? ""
            let source = row["source"] as? String ?? ""
            let date = row["date"] as? String ?? ""
            let conf = (row["confidence"] as? String ?? "").lowercased()
            let sure: MemoryLine.Sureness? = conf.hasPrefix("high") ? .sure
                : conf.hasPrefix("med") ? .fairly
                : conf.hasPrefix("low") ? .unsure : nil
            let kind = (row["kind"] as? String).flatMap(MemoryLine.Kind.init(rawValue:))
                ?? (file == "threads" ? .event : .stable)
            let flag = ((row["flag"] as? String) ?? (row["status"] as? String))?.lowercased()
            return MemoryLine(id: "claim:" + id,
                              section: ["identity", "preferences", "voice"].contains(file) ? .you : .things,
                              text: text,
                              origin: .claim(id: id),
                              source: sourceWords(source, date),
                              sureness: sure,
                              file: file,
                              kind: kind,
                              active: row["active"] as? Bool ?? true,
                              support: (row["support"] as? NSNumber)?.intValue ?? 0,
                              date: (row["occurred_end"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? date,
                              flag: flag)
        }
    }

    /// "WhatsApp · Sep 22": where the crawl looked, and when. A line the
    /// person wrote or corrected is "Your words".
    static func sourceWords(_ source: String, _ date: String) -> String {
        let names: [String: String] = [
            "chatgpt": "ChatGPT", "claude": "Claude", "chrome": "Chrome", "gmail": "Gmail", "imessage": "Messages", "calendar": "Calendar",
            "notes": "Notes", "drive": "Google Drive", "telegram": "Telegram", "whatsapp": "WhatsApp",
            "chat": "A conversation", "conversation": "A conversation", "user": "Your words",
            "github": "GitHub", "slack": "Slack", "outlook": "Outlook", "mail": "Mail",
            "messages": "Messages", "contacts": "Contacts", "reminders": "Reminders",
            "linkedin": "LinkedIn", "notion": "Notion", "discord": "Discord",
        ]
        let name = names[source.lowercased()] ?? (source.isEmpty ? "Something you let Moe read"
                                                                  : source.prefix(1).uppercased() + source.dropFirst())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return name }
        return name + " · " + d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The crawl's open questions, one a line.
    static func questions(in memoryDir: URL = Paths.memory) -> [String] {
        let url = memoryDir.appendingPathComponent("profile/questions.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseQuestions(text)
    }

    static func parseQuestions(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            let q = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? nil : q
        }
    }

    // MARK: The page

    /// "Eli — builds …": the line without its markdown bold.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    /// A line as said to the person (owner, 2026-09-22, "make it
    /// simpler"): "the user" becomes "you", as profile.py's second_person()
    /// does for questions. Stored lines keep no subject — distil refuses
    /// "you" in them, because the same lines reach the brain's prompt, where
    /// "you" is the assistant — so this is the page's own pass. Text inside
    /// double quotes is a quoted line and is never touched.
    static func shown(_ text: String) -> String {
        let rules: [(String, String)] = [
            (#"\bthe user(?:'|’)s\b"#, "your"),
            (#"\bdoes the user\b"#, "do you"), (#"\bis the user\b"#, "are you"),
            (#"\bwas the user\b"#, "were you"), (#"\bhas the user\b"#, "have you"),
            (#"\bthe user is\b"#, "you are"), (#"\bthe user was\b"#, "you were"),
            (#"\bthe user has\b"#, "you have"), (#"\bthe user does\b"#, "you do"),
            (#"\bthe user\b"#, "you"),
            (#"^user(?:'|’)s\b"#, "your"), (#"^user is\b"#, "you are"), (#"^user\b"#, "you"),
        ]
        guard text.range(of: "user", options: .caseInsensitive) != nil else { return text }
        // "the user reports" → "you report": a verb after "the user" loses its
        // third-person s ("carries" → "carry", "watches" → "watch").
        func verb(_ w: String) -> String {
            let l = w.lowercased()
            if l.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if ["sses", "shes", "ches", "xes", "zes", "oes"].contains(where: l.hasSuffix) { return String(w.dropLast(2)) }
            if l.hasSuffix("s") && !l.hasSuffix("ss") && !l.hasSuffix("us") { return String(w.dropLast()) }
            return w
        }
        var out = ""
        for (i, part) in text.components(separatedBy: "\"").enumerated() {
            if i > 0 { out += "\"" }
            if i % 2 == 1 { out += part; continue }
            var p = part
            if let re = try? NSRegularExpression(pattern: #"(?<!(?:does|was|has|is) )(?<!the )\b(the user|user) ([a-z]{3,})\b"#, options: [.caseInsensitive]) {
                for m in re.matches(in: p, range: NSRange(p.startIndex..., in: p)).reversed() {
                    guard let whole = Range(m.range, in: p), let w = Range(m.range(at: 2), in: p),
                          !["is", "was", "has", "does"].contains(p[w].lowercased()),
                          p[w].first?.isLowercase == true else { continue }
                    let upper = p[whole].first?.isUppercase == true
                    p.replaceSubrange(whole, with: (upper ? "You " : "you ") + verb(String(p[w])))
                }
            }
            for (pattern, you) in rules {
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for m in re.matches(in: p, range: NSRange(p.startIndex..., in: p)).reversed() {
                    guard let r = Range(m.range, in: p) else { continue }
                    let upper = p[r].first?.isUppercase == true
                    p.replaceSubrange(r, with: upper ? you.prefix(1).uppercased() + you.dropFirst() : you)
                }
            }
            out += p
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// The bold name at the start of a people line, if it has one.
    static func boldName(_ text: String) -> String? {
        guard text.hasPrefix("**") else { return nil }
        let rest = text.dropFirst(2)
        guard let end = rest.range(of: "**") else { return nil }
        let name = String(rest[..<end.lowerBound])
        return name.isEmpty ? nil : name
    }

    /// Most support first, then most recent.
    static func ranked(_ lines: [MemoryLine]) -> [MemoryLine] {
        lines.enumerated().sorted { a, b in
            if a.element.support != b.element.support { return a.element.support > b.element.support }
            if a.element.date != b.element.date { return a.element.date > b.element.date }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Everyone currently in the person's life, best-supported first.
    static func people(_ lines: [MemoryLine]) -> [MemoryLine] {
        ranked(lines.filter { $0.file == "people" && $0.active && $0.kind == .stable })
    }

    /// The "To check" list as `profile.py check --json` gives it (≤ 5
    /// items, contradicts > question > unsure > new). Nil when the installed
    /// profile.py predates the verb; the open questions stand in then.
    static func checkList() -> [MemoryCheck]? {
        guard let script = profileScript() else { return nil }
        let r = ScriptRunner.run(BrainSetup.python(), [script, "check", "--json"], timeout: 20)
        guard r.status == 0 else { return nil }
        return parseChecks(r.output)
    }

    static func parseChecks(_ output: String) -> [MemoryCheck]? {
        guard let start = output.firstIndex(of: "["),
              let data = output[start...].data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let text = row["text"] as? String, !text.isEmpty else { return nil }
            let kind = MemoryCheck.Kind(rawValue: row["kind"] as? String ?? "") ?? .question
            return MemoryCheck(kind: kind, text: text, ids: row["ids"] as? [String] ?? [])
        }
    }

    /// The rows of "To check", in profile.py's order. A contradiction or a
    /// question is its sentence with an Answer, followed by the lines it is
    /// about, each with Right and Edit — so "which is right?" is answered by
    /// pressing Right on one. An unsure or new line is just that line.
    static func checks(_ list: [MemoryCheck], lines: [MemoryLine]) -> [MemoryItem] {
        let byID = Dictionary(lines.compactMap { l in l.claimID.map { ($0, l) } }, uniquingKeysWith: { a, _ in a })
        var out: [MemoryItem] = lines.filter(\.revival).map { .of($0, role: .check) }
        var seen = Set<String>()
        for c in list {
            let about = c.ids.compactMap { byID[$0] }.filter(\.active)
            switch c.kind {
            case .contradicts, .question:
                out.append(.question(c.text))
            case .unsure, .new:
                if about.isEmpty { continue }
            }
            for l in about where seen.insert(l.id).inserted {
                out.append(.of(l, role: .check))
            }
        }
        return out
    }

    /// The page's five sections, in the order its own list shows them:
    /// You, People, Right now, To check, From your chats. Every section is
    /// returned, empty or not — the list shows a count of 0 and the section
    /// its one quiet line — except that the view hides "From your chats"
    /// while it has nothing in it. A line in "To check" is not also shown
    /// in its own section, and every active line is shown exactly once.
    ///
    /// Moe's own conversation notes (Hermes's MEMORY.md, and a USER.md line
    /// that speaks as Moe) are "From your chats", not "You": they are Moe's
    /// notes on how to work — the studio's invoice day, "never send without
    /// reading it back" — and in "You" they would read as facts about the
    /// person. Design B, 2026-09-22.
    static func sections(lines: [MemoryLine], checks list: [MemoryCheck]) -> [MemorySection] {
        let checking = checks(list, lines: lines)
        let inCheck = Set(checking.map(\.id))
        let active = lines.filter { $0.active && !$0.revival && !inCheck.contains($0.id) }
        let people = MemoryReader.people(active)
        let now = active.filter { $0.isClaim && ($0.kind == .event || $0.file == "threads") }
            .sorted { $0.date > $1.date }
        let chats = active.filter {
            $0.origin == .hermes(group: "memory") || ($0.origin == .hermes(group: "you") && speaksAsMoe($0.text))
        }
        let placed = Set((people + now + chats).map(\.id))
        // Everything else is about the person: Hermes's USER.md, the crawl's
        // identity, voice and preferences — and anything the rules above
        // missed (a file this build does not know), which still shows
        // rather than vanishing.
        let you = active.filter { !placed.contains($0.id) }
        let groups: [(MemoryTab, [MemoryItem])] = [
            (.you, you.map { MemoryItem.of($0) }),
            (.people, people.map { MemoryItem.of($0) }),
            (.now, now.map { MemoryItem.of($0) }),
            (.check, checking),
            (.chats, chats.map { MemoryItem.of($0) }),
        ]
        return groups.map { MemorySection(id: $0.0.rawValue, title: $0.0.title, items: $0.1) }
    }

    /// The section to open on: the one last chosen this session, unless it
    /// has since gone (From your chats, emptied), then You.
    static func opening(_ remembered: MemoryTab, shown: [MemoryTab]) -> MemoryTab {
        shown.contains(remembered) || remembered == .past ? remembered : .you
    }

    /// Archived crawl lines, most recent first: events that are over, older
    /// wordings, lines past a file's limit. Each can be restored.
    static func past(_ lines: [MemoryLine]) -> [MemoryItem] {
        lines.filter { !$0.active && !$0.revival }.sorted { $0.date > $1.date }.map { MemoryItem.of($0, role: .past) }
    }

    // MARK: Saving one line

    /// Put the bold name back on a people line the person edited as plain
    /// text: the page draws "Dana — co-founder", the file keeps
    /// "**Dana** — co-founder", and profile.py finds people by that name.
    static func rebold(original: String, edited: String) -> String {
        guard let name = boldName(original), !edited.contains("**") else { return edited }
        if let dash = edited.range(of: " — ") {
            let who = edited[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            if !who.isEmpty { return "**\(who)**" + edited[dash.lowerBound...] }
        }
        if edited.hasPrefix(name) { return "**\(name)**" + edited.dropFirst(name.count) }
        return edited
    }

    /// What saving `draft` over `item` does. Unchanged text does nothing;
    /// an empty draft forgets the line; an answer is kept as the person's.
    static func plan(_ item: MemoryItem, draft: String) -> MemoryEdit {
        let text = draft.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        switch item.role {
        case .past:
            return .nothing
        case .question:
            return text.isEmpty ? .nothing : .answer(question: item.text, text: text)
        case .line, .check:
            // A deleted fact noticed again is answered on its card, Yes or
            // No; it is not a live line cli.py could correct or delete.
            guard let line = item.line, text != item.text, !line.revival else { return .nothing }
            switch line.origin {
            case .claim(let id):
                return text.isEmpty ? .forget(id: id) : .correct(id: id, text: rebold(original: line.text, edited: text))
            case .hermes where line.ledgerID != nil:
                return text.isEmpty ? .forgetMemory(id: line.ledgerID!) : .correctMemory(id: line.ledgerID!, text: text)
            case .hermes:
                return text.isEmpty
                    ? .askMoe("Please forget this from your memory, and don't bring it back: “\(line.text)”")
                    : .askMoe("Please change this in your memory. It says: “\(line.text)”. It should say: “\(text)”.")
            }
        }
    }

    /// What "+ Add" saves. Empty does nothing; a people line gets its name
    /// in bold, as every people line has it ("**Dana** — co-founder").
    static func planAdd(_ tab: MemoryTab, draft: String) -> MemoryEdit {
        let text = draft.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let file = tab.addFile, !text.isEmpty else { return .nothing }
        return .add(file: file, text: file == "people" ? personLine(text) : text)
    }

    /// "Dana - co-founder" → "**Dana** — co-founder"; "Dana" → "**Dana**".
    static func personLine(_ text: String) -> String {
        guard !text.contains("**") else { return text }
        for sep in [" — ", " – ", " - ", ": ", ", "] {
            if let r = text.range(of: sep) {
                let who = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let what = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !who.isEmpty { return what.isEmpty ? "**\(who)**" : "**\(who)** — \(what)" }
            }
        }
        return "**\(text)**"
    }

    /// The python3 argv that makes a profile change. Nil for a change that
    /// is not the profile's to make.
    static func command(_ edit: MemoryEdit, script: String) -> [String]? {
        switch edit {
        case .correct(let id, let text): return [script, "correct", id, text, "--json"]
        case .forget(let id): return [script, "delete", id, "--json"]
        case .answer(let q, let text): return [script, "answer", q, text, "--file", answerFile, "--json"]
        case .dismiss(let q): return [script, "dismiss", q, "--json"]
        case .add(let file, let text): return [script, "add", file, text, "--json"]
        case .confirm(let id): return [script, "confirm", id, "--json"]
        case .nothing, .askMoe, .correctMemory, .forgetMemory, .undoTidy, .revive: return nil
        }
    }

    /// "Right": profile.py confirm — the line becomes the person's own
    /// (`user`, high, never flagged, left alone by the nightly pass), the
    /// question quoting it closes, and the other side of a contradiction it
    /// settles is archived.
    static func confirmCommand(_ line: MemoryLine, script: String) -> [String]? {
        guard let id = line.claimID else { return nil }
        return [script, "confirm", id, "--json"]
    }

    static func restoreCommand(_ line: MemoryLine, script: String) -> [String]? {
        guard let id = line.claimID else { return nil }
        return [script, "restore", id, "--json"]
    }

    /// The cli.py argv (after the interpreter) for a change to a line of
    /// Hermes's memory. Nil for anything else.
    static func memoryCommand(_ edit: MemoryEdit, cli: String) -> [String]? {
        switch edit {
        case .correctMemory(let id, let text): return [cli, "correct", id, text, "--json"]
        case .forgetMemory(let id): return [cli, "delete", id, "--json"]
        case .undoTidy(let change): return [cli, "undo", change, "--json"]
        case .revive(let id, let keep): return [cli, "revive", id, keep ? "yes" : "no", "--json"]
        default: return nil
        }
    }

    /// Runs whichever script the change is for — profile.py or cli.py.
    /// Nil on success, else the sentence to show.
    static func perform(_ edit: MemoryEdit) -> String? {
        if let py = hermesPython(), let cli = claimstoreCLI(), let argv = memoryCommand(edit, cli: cli) {
            return run(argv, python: py)
        }
        guard let script = profileScript(), let argv = command(edit, script: script)
        else { return "Moe can't find the file it keeps this in." }
        return run(argv)
    }

    /// Runs several changes in order, stopping at the first that fails.
    static func perform(all edits: [MemoryEdit]) -> String? {
        for e in edits { if let problem = perform(e) { return problem } }
        return nil
    }

    /// Runs one profile command. Nil on success, else the sentence to show.
    static func run(_ argv: [String], python: String = BrainSetup.python(),
                    extraEnv: [String: String] = [:]) -> String? {
        let r = ScriptRunner.run(python, argv, extraEnv: extraEnv, timeout: 20)
        guard r.status != 0 else { return nil }
        // `--json` failures are one object with an `error`.
        let json = r.output.firstIndex(of: "{").flatMap { r.output[$0...].data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let why = (json?["error"] as? String) ?? ScriptRunner.Result.humanLine(in: r.output)
        return "Couldn't change that" + (why.isEmpty ? "." : ": \(why)")
    }

    // MARK: The folder, and the one quiet line

    /// Where "Open folder" goes: one folder holding every memory file a
    /// person would recognise. See `MemoryFolder`.
    static func folderToOpen(memoryDir: URL = Paths.memory, hermesDir: URL = HermesMemory.dir()) -> URL {
        MemoryFolder.ensure(memoryDir: memoryDir, hermesDir: hermesDir)
    }

    /// The page's one line about the cloud copy — only when there is one.
    static func whereItLives(awayCopy: Bool) -> String? {
        awayCopy ? "With Away on, your machine in the cloud keeps a sealed copy in step." : nil
    }

    /// The markdown notes a person can edit. soul.md is not one of them.
    static func notes() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: Paths.memory, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "md" && $0.lastPathComponent != "soul.md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - To check, one at a time

/// One card of "To check" (owner, 2026-09-22: "answering is not a clean
/// experience"): one thing Moe is unsure of, asked as a question in "you"
/// form, with Yes, No and Something else… — and a quiet Skip.
struct CheckCard: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An unsure or new line: "Is this right?" and the line.
        case line(MemoryLine)
        /// One of the crawl's questions, about one line or about nothing.
        case question(String, about: MemoryLine?)
        /// Two lines that disagree: the question, and a choice between them.
        case choose(String, between: [MemoryLine])
    }
    let id: String
    let kind: Kind
    /// The quiet words above the question: "Moe isn't sure".
    let label: String

    /// What is asked, in the person's own "you".
    var prompt: String {
        switch kind {
        case .line(let l) where l.revival: return "Remember this again?"
        case .line: return "Is this right?"
        case .question(let q, _): return q
        // The question quotes both lines, and they are the choices under it.
        case .choose: return "Which of these is right?"
        }
    }

    /// The line being asked about, as the page shows it; nil for a question.
    var detail: String? {
        if case .line(let l) = kind { return MemoryReader.shown(MemoryReader.plain(l.text)) }
        return nil
    }

    /// How the card is answered. The crawl's questions are free text, and
    /// not every one is a yes-or-no question (“Who is ‘he’ in …?”, or no
    /// question at all: “unclear who ‘he’ is”). Read from the words, and
    /// when in doubt it is open: a box for an answer can take a yes, but
    /// Yes and No cannot answer "who".
    enum Shape: Equatable { case yesNo, choose, open }

    var shape: Shape {
        switch kind {
        case .line: return .yesNo
        case .choose: return .choose
        case .question(let q, _): return Self.isYesNo(q) ? .yesNo : .open
        }
    }

    /// A yes-or-no question: it ends in "?", does not start with a
    /// question word, and does not offer alternatives ("A or B?").
    static func isYesNo(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.hasSuffix("?") else { return false }
        let first = q.lowercased().prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        let wh: Set<Substring> = ["who", "whom", "whose", "what", "which", "when", "where", "why", "how",
                                  "who's", "what's", "where's", "how's", "who’s", "what’s", "where’s", "how’s"]
        if wh.contains(first) { return false }
        // "A or B?" offers two answers; ", or did that change?" is still a yes.
        if q.range(of: #"[^,]\s+or\s+[^?]*\?$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           q.range(of: #"\bor not\?$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return false
        }
        return true
    }

    /// The lines a contradiction offers as its choices.
    var choices: [String] {
        if case .choose(_, let ls) = kind { return ls.map { MemoryReader.shown(MemoryReader.plain($0.text)) } }
        return []
    }
}

enum CardAnswer: Equatable {
    case yes, no
    /// "Something else…": the person's own words.
    case other(String)
    /// On a contradiction: the line that is right.
    case pick(Int)
    /// "Doesn't matter": close the question without an answer.
    case dismiss
}

extension MemoryReader {
    /// The cards of "To check", in profile.py's order (contradictions,
    /// questions, unsure, new). A line is asked about once.
    static func cards(_ list: [MemoryCheck], lines: [MemoryLine]) -> [CheckCard] {
        let byID = Dictionary(lines.compactMap { l in l.claimID.map { ($0, l) } }, uniquingKeysWith: { a, _ in a })
        // A deleted fact noticed again comes first: only the person can
        // bring it back, and it waits unseen otherwise.
        var out: [CheckCard] = lines.filter(\.revival).map {
            CheckCard(id: $0.id, kind: .line($0), label: $0.source)
        }
        var seen = Set<String>()
        for c in list {
            let about = c.ids.compactMap { byID[$0] }.filter { $0.active && !seen.contains($0.id) }
            switch c.kind {
            case .contradicts where about.count >= 2:
                out.append(CheckCard(id: "q:" + c.text, kind: .choose(c.text, between: Array(about.prefix(2))),
                                     label: "These disagree"))
            case .contradicts, .question:
                out.append(CheckCard(id: "q:" + c.text, kind: .question(c.text, about: about.first),
                                     label: "Moe isn't sure"))
            case .unsure, .new:
                guard let l = about.first else { continue }
                out.append(CheckCard(id: l.id, kind: .line(l), label: c.kind == .new ? "New" : "Moe isn't sure"))
            }
            about.forEach { seen.insert($0.id) }
        }
        return out
    }

    /// What answering a card writes, in order. Every write is the person's
    /// word: confirm / delete / correct on a line (each closes any question
    /// quoting it), answer / dismiss on a question about nothing.
    static func plan(_ card: CheckCard, _ answer: CardAnswer) -> [MemoryEdit] {
        let words: (String) -> String = {
            $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if case .question(let q, _) = card.kind, card.shape == .open {
            // An open question is answered in words, never by rewriting the
            // line it quotes into the answer ("Mendy" is not the line).
            switch answer {
            case .other(let t):
                let t = words(t)
                return t.isEmpty ? [] : [.answer(question: q, text: t)]
            case .dismiss: return [.dismiss(question: q)]
            default: return []
            }
        }
        if case .line(let l) = card.kind, l.revival, let id = l.ledgerID {
            switch answer {
            case .yes: return [.revive(id: id, keep: true)]
            case .no: return [.revive(id: id, keep: false)]
            default: return []
            }
        }
        switch (card.kind, answer) {
        case (.question(let q, _), .dismiss), (.choose(let q, _), .dismiss):
            return [.dismiss(question: q)]
        case (.line(let l), .yes), (.question(_, let l?), .yes):
            return l.claimID.map { [.confirm(id: $0)] } ?? []
        case (.line(let l), .no), (.question(_, let l?), .no):
            return l.claimID.map { [.forget(id: $0)] } ?? []
        case (.line(let l), .other(let t)), (.question(_, let l?), .other(let t)):
            let t = words(t)
            guard !t.isEmpty, let id = l.claimID else { return [] }
            return [.correct(id: id, text: rebold(original: l.text, edited: t))]
        case (.question(let q, .none), .yes):
            return [.answer(question: q, text: "\(q) Yes.")]
        case (.question(let q, .none), .no):
            return [.answer(question: q, text: "\(q) No.")]
        case (.question(let q, .none), .other(let t)):
            let t = words(t)
            return t.isEmpty ? [] : [.answer(question: q, text: t)]
        case (.choose(_, let ls), .pick(let i)) where ls.indices.contains(i):
            // confirm archives the other side of the question it closes.
            return ls[i].claimID.map { [.confirm(id: $0)] } ?? []
        case (.choose(let q, let ls), .other(let t)):
            let t = words(t)
            guard !t.isEmpty else { return [] }
            // The answer first — forgetting a line closes the question.
            return [.answer(question: q, text: t)] + ls.compactMap { $0.claimID.map { .forget(id: $0) } }
        case (.choose(let q, _), .no):
            // Neither is right, and nothing to say instead: close it.
            return [.dismiss(question: q)]
        default:
            return []
        }
    }
}

// MARK: - Talking it through with Moe

/// The drafts the Memory page puts in Chat's box — never sent for the
/// person (owner, 2026-09-22: "talk it through with Moe"). Each names the
/// files it is about, by the names the brain is given in moe-profile's
/// prompt section, so Moe knows exactly what to read and change.
enum MemoryTalk {
    /// The files behind a section, as the brain knows them.
    static func files(_ tab: MemoryTab) -> [String] {
        switch tab {
        case .you: return ["identity.md", "preferences.md", "voice.md", "USER.md"]
        case .people: return ["people.md"]
        case .now: return ["threads.md"]
        case .check: return ["questions.md", "check.md"]
        case .chats: return ["MEMORY.md"]
        case .past: return ["archive.md"]
        }
    }

    /// "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// "Go through with Moe", for one section. Nil for Past.
    static func draft(for tab: MemoryTab) -> String? {
        let what: String
        switch tab {
        case .you: what = "what you know about me — the You lines in my memory"
        case .people: what = "the people you know in my life — the People lines in my memory"
        case .now: what = "what you think is going on for me right now — the Right now lines in my memory"
        case .check: what = "the things you're not sure about in my memory"
        case .chats: what = "the notes you kept from our conversations"
        case .past: return nil
        }
        return "Let's go through \(what) (\(list(files(tab)))). Ask me about anything that looks off, one at a time, and fix it as we go."
    }

    /// The file a line lives in, as the brain knows it.
    static func file(_ line: MemoryLine) -> String {
        switch line.origin {
        case .hermes(let group): return group == "you" ? "USER.md" : "MEMORY.md"
        case .claim: return line.file.isEmpty ? "your profile" : line.file + ".md"
        }
    }

    /// "Discuss", on one line.
    static func discuss(_ item: MemoryItem) -> String {
        let from = item.line.map { " (from \(file($0)))" } ?? ""
        return "Let's talk about this memory: “\(item.text)”\(from). Is it right, and should we change it?"
    }

    /// "Review everything with Moe": a questionnaire over every file.
    static let everything = "Let's review everything you remember about me, file by file: identity.md, preferences.md, voice.md, people.md, threads.md, then USER.md and MEMORY.md. Go one file at a time and ask me one short question at a time — is this right? — and fix, confirm or forget each line as I answer."
}

// MARK: - One folder

/// **Every memory file in one Finder window** (owner, 2026-09-22): "when you
/// press Open folder, it shows you one by one" — Hermes's USER.md and
/// MEMORY.md beside the learned profile, not two folders and not a folder
/// full of sidecars.
///
/// The files cannot move. Hermes and claimstore read and write
/// `$HERMES_HOME/memories`; profile.py, consolidate.py and the ledger's
/// document sync (`moeledger/documents.py` PROFILE_FILES) address
/// `memory/profile/<name>` by path. So this is a *view*: a folder of
/// symlinks, `memory/What Moe knows/`, one per file, each pointing at the
/// real one.
///
/// Why links in their own folder, rather than links added to the profile
/// folder and the internals hidden with `chflags hidden`: profile.py writes
/// every file by temp-file-and-rename, which makes a new inode each time and
/// drops the hidden flag — archive.md would reappear after the first nightly
/// pass. A link names a path, not an inode, so it survives every rewrite,
/// and the internals (digests/, stamps/, backups/, .meta.json, archive.md,
/// *.lock) are simply never linked.
///
/// Rebuilt at launch and every time the page opens it, so a wipe, a new
/// Hermes home or a file that appears later is picked up. It never removes
/// anything but its own links: a real file in the folder — an editor that
/// saved over a link — is left for the person.
enum MemoryFolder {
    static let name = "What Moe knows"

    /// (name in the folder, where the real file lives relative to its home).
    /// Hermes's first, then the profile in the order the page reads.
    static func entries(memoryDir: URL, hermesDir: URL) -> [(String, URL)] {
        let profile = memoryDir.appendingPathComponent("profile", isDirectory: true)
        return [("USER.md", hermesDir.appendingPathComponent("USER.md")),
                ("MEMORY.md", hermesDir.appendingPathComponent("MEMORY.md"))]
            + ["summary", "identity", "people", "threads", "voice", "preferences", "questions", "check"]
                .map { ("\($0).md", profile.appendingPathComponent("\($0).md")) }
    }

    @discardableResult
    static func ensure(memoryDir: URL = Paths.memory, hermesDir: URL = HermesMemory.dir()) -> URL {
        let fm = FileManager.default
        let view = memoryDir.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: view, withIntermediateDirectories: true)
        for (leaf, target) in entries(memoryDir: memoryDir, hermesDir: hermesDir) {
            let link = view.appendingPathComponent(leaf)
            let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
            let exists = fm.fileExists(atPath: target.path)
            if current == nil, (try? fm.attributesOfItem(atPath: link.path)) != nil {
                continue        // a real file, not ours: the person's
            }
            if current == target.path && exists { continue }
            if current != nil { try? fm.removeItem(at: link) }
            if exists { try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path) }
        }
        return view
    }
}
