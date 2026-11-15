import Foundation
import MoeChat
import MoeLedger

/// Every conversation the ledger says happened, and how to find one.
///
/// **Ledger-first, Hermes as the index** (HERMES-SURFACES §4.3). The list
/// and every word on this screen come from `~/.moe/ledger` through
/// `ConversationProjector`; Hermes's FTS5 index over `state.db` is used
/// only to point at a conversation, never to supply one.
///
/// The two stores disagree by design and a naive Sessions page would
/// expose it. Hermes's `state.db` never crosses devices and the ledger
/// does; and deleting a conversation destroys the ledger key while
/// leaving Hermes's copy of the same turns intact (`CLOUD-PLAN` §9 — a
/// decision, not a bug). So the ledger decides what exists.
///
/// **The filter is `kind == "turn"`, not "present in the ledger".** Slice
/// 3 puts `intent`, `intent.result` and `intent.attempt` records inside
/// threads, because work is queued in the conversation it was asked in.
/// A thread whose only records are those is a queued lookup, not a
/// conversation, and filtering on presence alone would list it as one.
/// `Tests/MoeLedgerTests/IntentProjectionTests.swift` pins the same rule
/// on the projector; `liveThreads` is where it is pinned here.
///
/// Everything here blocks on files, a decrypt and a subprocess. Call it
/// off the main thread.
enum Chats {

    // MARK: - What comes back

    /// One conversation, as a row.
    struct Thread: Identifiable, Equatable {
        var id: String
        var title: String
        var startedAt: Date
        var updatedAt: Date
        var turns: Int
        /// Where the turns came from — `live` for this Mac, `telegram` for
        /// a thread Moe Away recorded, `backfill` for one imported when it
        /// was first reopened. Several is normal: one conversation can be
        /// carried on from a phone.
        var sources: [String]
        /// The last thing said, cut to a line. From the ledger, decrypted
        /// here — never from Hermes's copy.
        var preview: String

        /// Where this conversation happened, said to a person. `backfill`
        /// is deliberately not a word here: it describes how the record
        /// got written, which is not something a person asked.
        var whereFrom: String {
            let real = sources.filter { $0 != "backfill" }
            if real.contains("telegram"), real.contains("live") { return "Here and on Telegram" }
            if real.contains("telegram") { return "On Telegram" }
            return "Here"
        }
    }

    /// A conversation Hermes's index pointed at, or one whose own words
    /// match — resolved to a thread the ledger vouches for, always.
    struct Match: Identifiable, Equatable {
        var thread: Thread
        /// The line to show under the row, and where it came from.
        var excerpt: String
        /// True when `excerpt` is Hermes's snippet rather than a turn out
        /// of the ledger. Hermes stores more of a session than the ledger
        /// does — tool results, the silent priming turn — so a hit with no
        /// matching turn is a real answer, not a bug, and saying which is
        /// the difference between a quote and a hint.
        var fromIndex: Bool
        var id: String { thread.id }
    }

    /// The whole answer for the list. `error` is a sentence for a person;
    /// an empty list with `ok` is "you have not talked to Moe yet", which
    /// is a different and much less alarming thing than "I could not
    /// look" and must never be drawn the same way.
    struct Library: Equatable {
        var ok = false
        var error = ""
        var threads: [Thread] = []
        /// Threads the ledger holds and cannot open: their key was
        /// destroyed, or never arrived from another device. Counted, never
        /// listed — a row for a conversation whose words are gone is a
        /// row that can only disappoint.
        var unreadable = 0
    }

    /// What a search found. `ok == false` carries `error`.
    struct Results: Equatable {
        var ok = false
        var error = ""
        var query = ""
        var matches: [Match] = []
        /// How many sessions Hermes was allowed to look in. Zero means the
        /// index was never asked, which is not the same as finding nothing.
        var indexed = 0
        /// True when the index was reached at all. False after a search
        /// answered entirely out of the ledger, which is what happens on a
        /// Mac where Hermes has not started.
        var usedIndex = false
    }

    // MARK: - Reading the ledger

    /// A reader over this Mac's ledger. Read-only: nothing on this screen
    /// appends, and `ConversationLedger` only writes when asked to.
    ///
    /// Built per call rather than held. The ledger parses incrementally
    /// and caches inside itself, so a held instance would go stale against
    /// another writer — the app's own Conductor and Hermes's `claimstore`
    /// plugin both append under this device — and a settings pane that
    /// shows a conversation from ten minutes ago is worse than one that
    /// re-reads.
    static func reader() -> ConversationLedger {
        ConversationLedger(directory: Paths.ledger,
                           store: ConversationStore(directory: Paths.conversations))
    }

    /// Every thread that is a conversation: it has at least one surviving
    /// `turn` record and has not been deleted.
    ///
    /// Both halves matter and they fail differently. `isDeleted` is the
    /// person's own deletion, and a thread that came back after one would
    /// be the worst bug this screen could have. The turn count is §4.3's
    /// rule: an `intent` record carries a thread id because work is queued
    /// in the conversation it was asked in, so a thread can exist in the
    /// ledger having never been a conversation.
    static func liveThreads(_ ledger: ConversationLedger) -> [String] {
        let p = ledger.projector
        return p.threads().filter { thread in
            !p.isDeleted(thread: thread) && !p.turnRecords(thread: thread).isEmpty
        }
    }

    /// The list. Nil is never returned: a ledger that cannot be read comes
    /// back as `ok == false` with words, because "you have no
    /// conversations" and "I could not look" must not draw the same.
    static func library() -> Library {
        let ledger = reader()
        let p = ledger.projector
        var out = Library(ok: true)
        var seen = Set<String>()
        for thread in liveThreads(ledger) {
            seen.insert(thread)
            guard let convo = p.project(thread: thread) else {
                // Held, not openable. The key is gone, or has not arrived
                // from the device that has it.
                out.unreadable += 1
                continue
            }
            guard !convo.turns.isEmpty else { continue }
            out.threads.append(summarise(convo, records: p.turnRecords(thread: thread)))
        }
        out.threads.sort { $0.updatedAt > $1.updatedAt }
        if out.threads.isEmpty, out.unreadable == 0, !FileManager.default.fileExists(atPath: Paths.ledger.path) {
            out.ok = false
            out.error = "Moe hasn't started keeping conversations on this Mac yet."
        }
        return out
    }

    /// One conversation in full, decrypted here. Nil when the ledger will
    /// not open it — deleted, or its key destroyed.
    static func open(_ thread: String) -> ConversationStore.Conversation? {
        let ledger = reader()
        guard liveThreads(ledger).contains(thread) else { return nil }
        return ledger.projector.project(thread: thread)
    }

    private static func summarise(_ convo: ConversationStore.Conversation,
                                  records: [LedgerRecord]) -> Thread {
        // `source` is in the clear on every turn record — the projector
        // seals the words and nothing else, so that destroying a key costs
        // the words and not the thread's shape. That is exactly the field
        // that answers "where did this conversation happen".
        var sources: [String] = []
        for r in records {
            let s = r.body["source"]?.stringValue ?? ""
            if !s.isEmpty, !sources.contains(s) { sources.append(s) }
        }
        // The last turn with something in it, not simply the last turn.
        // Found by rendering: a thread whose final reply was an ellipsis
        // drew a row whose whole preview was "…", which says less than no
        // preview at all.
        let last = convo.turns.reversed().first { !line($0.text).isEmpty && line($0.text) != "…" }
        return Thread(id: convo.id,
                      title: convo.title,
                      startedAt: convo.startedAt,
                      updatedAt: convo.turns.last?.at ?? convo.updatedAt,
                      turns: convo.turns.count,
                      sources: sources.sorted(),
                      preview: line(last?.text ?? ""))
    }

    /// The part of a turn that contains what was searched for, marked.
    ///
    /// Not the first line of it. Found by rendering: a thread matched on
    /// "meeting" and its row showed the opening sentence of the turn,
    /// which was about the calendar — so the row said nothing about why
    /// it was a result, and the person is left to take it on faith. The
    /// window is centred on the match and marked with the same `‹ ›` the
    /// index's own snippets use, so a hit found two ways looks the same
    /// either way.
    static func excerpt(_ text: String, matching needle: String, limit: Int = 140) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let found = flat.range(of: needle, options: [.caseInsensitive]) else {
            return line(flat, limit: limit)
        }
        let marked = flat.replacingCharacters(
            in: found, with: "‹" + flat[found] + "›")
        // Where the match now sits in the marked string, and half the
        // window either side of it.
        let at = marked.distance(from: marked.startIndex,
                                 to: marked.range(of: "‹")?.lowerBound ?? marked.startIndex)
        guard marked.count > limit else { return marked }
        let want = max(0, at - limit / 3)
        let start = marked.index(marked.startIndex, offsetBy: min(want, max(0, marked.count - limit)))
        let end = marked.index(start, offsetBy: min(limit, marked.distance(from: start, to: marked.endIndex)))
        var window = String(marked[start..<end])
        if start != marked.startIndex { window = "…" + window }
        if end != marked.endIndex { window += "…" }
        return window
    }

    /// One line out of a turn, cut at a word. A turn is markdown and can
    /// be a page of it; a row is a row.
    static func line(_ text: String, limit: Int = 140) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if flat.count <= limit { return flat }
        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { String(cut[cut.startIndex..<$0]) } ?? String(cut)
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Hermes as the index

    /// The Hermes sessions this thread's turns were served by, out of
    /// `ledger/brain-sessions.json`.
    ///
    /// That file is the app's own note of which records each brain session
    /// has already been told about, so its keys are the sessions Moe has
    /// used and its values are ledger record ids. Resolving those ids back
    /// through the ledger gives an **exact** session → thread map, with no
    /// guessing: the alternative is re-deriving `BrainSession.id(thread:
    /// brain:)` for every brain a person might ever have chosen, and a
    /// well-formed identifier that resolves to nothing is more dangerous
    /// than an absent one.
    ///
    /// Measured on this Mac, 2026-09-04: 117 sessions, every one of them
    /// present in `state.db`, every one resolving to exactly one thread —
    /// out of 657 `api_server` sessions and 763 sessions in total. The
    /// other 646 are cron prompts, subagent runs, CLI sessions and threads
    /// the person deleted, and none of them is a conversation Moe should
    /// ever put on screen.
    static func sessionsByThread(_ ledger: ConversationLedger) -> [String: String] {
        let url = Paths.ledger.appendingPathComponent("brain-sessions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: [String]] else { return [:] }

        // Only `turn` records are allowed to name a thread here. §4.3's
        // rule, applied where a session is resolved rather than only where
        // a thread is listed: an `intent` record carries a thread id too,
        // and a session that had only ever been told about one would map
        // to a conversation on the strength of a queued lookup.
        var threadOfRecord: [String: String] = [:]
        for record in ledger.ledger.all() where record.kind == LedgerRecord.Kind.turn {
            if let thread = record.body["thread"]?.stringValue {
                threadOfRecord[record.id] = thread
            }
        }
        var out: [String: String] = [:]
        for (session, records) in sessions {
            let threads = Set(records.compactMap { threadOfRecord[$0] })
            // Exactly one, or none. A session that somehow names two
            // threads is a session this cannot attribute, and attributing
            // it to the first one would put one conversation's words under
            // another's title.
            if threads.count == 1 { out[session] = threads.first }
        }
        return out
    }

    /// `~/.moe/hermes/history.py` — installed, then the app's own copy,
    /// then the checkout. The ladder `Reminders` and `BrainSetup` use, for
    /// the same reason: the middle rung is what keeps a home whose payload
    /// copy failed from showing an empty screen with no explanation.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("hermes/history.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes/history.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes/history.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// One hit as `history.py` reports it. Every key read with
    /// `decodeIfPresent`: Swift's synthesised `Decodable` throws
    /// `keyNotFound` for an absent key rather than using the property's
    /// default, and one missing key takes the whole answer with it.
    struct IndexHit: Decodable, Equatable {
        var session = ""
        var role = ""
        var at = ""
        var snippet = ""

        enum CodingKeys: String, CodingKey { case session, role, at, snippet }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            session = c.chatsValue(.session, "")
            role = c.chatsValue(.role, "")
            at = c.chatsValue(.at, "")
            snippet = c.chatsValue(.snippet, "")
        }
    }

    struct IndexAnswer: Decodable, Equatable {
        var ok = false
        var error = ""
        var query = ""
        var hits: [IndexHit] = []
        var sessions = 0
        var capped = false

        enum CodingKeys: String, CodingKey { case ok, error, query, hits, sessions, capped }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.chatsValue(.ok, false)
            error = c.chatsValue(.error, "")
            query = c.chatsValue(.query, "")
            hits = c.chatsValue(.hits, [])
            sessions = c.chatsValue(.sessions, 0)
            capped = c.chatsValue(.capped, false)
        }
    }

    /// Ask Hermes's index, in the sessions the ledger vouches for.
    ///
    /// The allowed sessions go over **stdin**, and the script refuses to
    /// search at all without them. That is the guard, and it is there
    /// rather than here on purpose: a pane is not a guard, and the words
    /// of a deleted conversation must not leave Hermes's store even into
    /// this process's memory. `reminders.py` learnt the same lesson about
    /// its upkeep jobs.
    static func askIndex(_ query: String, sessions: [String]) -> IndexAnswer? {
        guard let script = scriptPath(), !sessions.isEmpty else { return nil }
        // `--query=…`, joined, never `--query`, `…` as two arguments. A
        // person who types a word beginning with a hyphen — "-ish",
        // "--help", a dashed name — hands argparse something that looks
        // like an option, and argparse answers by printing usage to stderr
        // and exiting 2. The joined form has no such reading. Found by
        // searching for `-pelican` in the suite.
        let r = ScriptRunner.run(BrainSetup.python(),
                                 [script, "search", "--query=" + query, "--limit=60"],
                                 stdin: sessions.joined(separator: "\n") + "\n",
                                 timeout: 20)
        guard let data = jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode(IndexAnswer.self, from: data)
    }

    /// The last line that is a JSON object. `ScriptRunner` merges stderr
    /// into stdout and Hermes's own imports write warnings there, so the
    /// answer is the last such line rather than the first — and a run that
    /// printed only warnings has no answer at all.
    static func jsonPart(_ text: String) -> Data? {
        let line = text.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("{") && $0.hasSuffix("}") }
        return line.map { Data($0.utf8) }
    }

    // MARK: - Searching

    /// Find a conversation. Two ways in, one way out.
    ///
    /// The ledger's own turns are matched here, which is what covers a
    /// conversation Hermes has no session for — every turn Moe Away
    /// recorded from Telegram lands in the ledger under a thread of its
    /// own and under no `api_server` session at all, so an index-only
    /// search would silently never find one. Hermes's index is asked as
    /// well, because it holds more of a session than the ledger does: the
    /// silent priming turn, tool results, and turns from before a thread
    /// was first projected.
    ///
    /// **Both roads end at the same gate.** A result is a thread out of
    /// `liveThreads`, and the words shown are the ledger's wherever the
    /// ledger has them. Nothing from Hermes reaches the screen except
    /// through a session that resolves to one of those threads.
    static func search(_ query: String) -> Results {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Results(ok: false, error: "Type something to look for.", query: query)
        }
        let ledger = reader()
        let p = ledger.projector
        let live = liveThreads(ledger)
        var known: [String: (Thread, ConversationStore.Conversation)] = [:]
        for thread in live {
            guard let convo = p.project(thread: thread), !convo.turns.isEmpty else { continue }
            known[thread] = (summarise(convo, records: p.turnRecords(thread: thread)), convo)
        }

        var excerpt: [String: (String, Bool)] = [:]
        var order: [String] = []
        let needle = trimmed.lowercased()

        // The ledger's own words first, so a thread that really contains
        // the phrase is quoted from the ledger rather than from Hermes's
        // copy of it.
        for (thread, pair) in known {
            guard let turn = pair.1.turns.last(where: { $0.text.lowercased().contains(needle) })
                    ?? pair.1.turns.first(where: { $0.text.lowercased().contains(needle) })
            else { continue }
            excerpt[thread] = (self.excerpt(turn.text, matching: trimmed), false)
            order.append(thread)
        }

        // Then the index, for the threads its sessions resolve to.
        var results = Results(ok: true, query: trimmed)
        let byThread = sessionsByThread(ledger)
        let allowed = byThread.filter { known[$0.value] != nil }
        results.indexed = allowed.count
        if let answer = askIndex(trimmed, sessions: Array(allowed.keys).sorted()) {
            results.usedIndex = answer.ok
            if !answer.ok, !answer.error.isEmpty, excerpt.isEmpty {
                // Only when the ledger found nothing either: a search that
                // answered out of the ledger is a search that worked, and
                // saying "the index refused that" over a page of results
                // is a warning about nothing.
                results.error = answer.error
            }
            for hit in answer.hits {
                guard let thread = byThread[hit.session], known[thread] != nil else { continue }
                if excerpt[thread] == nil {
                    excerpt[thread] = (hit.snippet, true)
                    order.append(thread)
                }
            }
        }

        results.matches = order.compactMap { thread in
            guard let pair = known[thread], let text = excerpt[thread] else { return nil }
            return Match(thread: pair.0, excerpt: text.0, fromIndex: text.1)
        }
        .sorted { $0.thread.updatedAt > $1.thread.updatedAt }
        return results
    }
}

/// One key, or the fallback — never a thrown `keyNotFound` that takes the
/// whole answer with it.
///
/// Swift's synthesised `Decodable` does not use a property's default when
/// a key is absent; it throws, and a struct with one absent key decodes to
/// nothing at all. Measured on this repo the day before this file was
/// written: one added `var error = ""` turned every successful answer into
/// a failure. Named `chatsValue` rather than `value` because `Reminders`
/// declares its own private extension of the same shape on the same type,
/// and two `value(_:_:)` in one module is ambiguous at the call site.
private extension KeyedDecodingContainer {
    func chatsValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
