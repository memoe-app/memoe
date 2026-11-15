import Foundation
import MoeChat
import MoeLedger

/// What Moe has actually been doing, on this Mac.
///
/// Four sources, joined into one list in time order (HERMES-SURFACES §4.2):
///
/// - **the ledger**, for the conversations you had — the only one of the
///   four that is Moe's own and the only one with words in it;
/// - **`~/.moe/logs/activity.jsonl`**, for turns that happened somewhere
///   else entirely. That file is the only way Moe learns a turn happened
///   on Telegram: those never reach the app, never reach its ledger from
///   this machine, and the first anyone hears of one is the reply on the
///   phone;
/// - **Hermes's cron run ledger**, for what ran on a clock;
/// - **Hermes's failure incidents**, for what did not.
///
/// Three things this file will not do, each of them a rule rather than a
/// preference.
///
/// **No message bodies.** The activity hook records a timestamp, a
/// platform, a chat type, a session id, a model and two character counts,
/// and it says in its own header why: it would otherwise hold both sides
/// of every conversation on every platform and be the best prize in
/// `~/.moe`. The timeline says what happened; the words are reached by
/// opening that conversation in Chats, under the person's own key.
///
/// **No completeness claim built on `gateway.log`.** Verified by the
/// cloud session: `Plugin discovery complete` is logged by
/// `hermes_cli.plugins`, which that file's component filter excludes, and
/// `Loaded hook '<name>'` is a bare `print()` reaching no file at all. A
/// health check built on the first of those cried wolf on a healthy
/// machine. The log is shown as a log and described as an incomplete one.
///
/// **This Mac only.** Moe Away runs on a Fly volume and its logs stay
/// there; nothing here can read them, and a timeline that implied
/// otherwise would be read as "Moe did nothing away" rather than "Moe
/// cannot see what it did away".
///
/// Everything here blocks. Call it off the main thread.
enum Activity {

    // MARK: - What a row is

    /// What kind of thing happened. The mark and the wording follow from
    /// this and nothing else, so a row cannot look like a failure because
    /// of its text.
    enum Kind: String, Equatable {
        /// A conversation in the app, on this Mac or synced into it.
        case talked
        /// A turn that happened on another platform entirely.
        case elsewhere
        /// Something on a clock ran.
        case job
        /// Something on a clock stopped.
        case incident
    }

    struct Event: Identifiable, Equatable {
        var id: String
        var at: Date
        var kind: Kind
        var title: String
        var detail: String
        /// The quieter third line, or empty.
        var note: String = ""
        /// The conversation this row can open in Chats, when there is one.
        /// Empty for a job, and empty for a turn that happened elsewhere —
        /// see `Feed.reachable`.
        var thread: String = ""
        /// True for Moe's own upkeep. Shown, but folded away by default:
        /// five jobs ticking every few minutes is most of the machine's
        /// day and none of a person's.
        var upkeep = false
    }

    /// The raw log, and what it honestly is not. The wording is the
    /// script's — it is the only place that knows which file it read.
    struct RawLog: Decodable, Equatable {
        var path = ""
        var lines: [String] = []
        var missing = true
        var note = ""

        init() {}
        enum CodingKeys: String, CodingKey { case path, lines, missing, note }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.activityValue(.path, "")
            lines = c.activityValue(.lines, [])
            missing = c.activityValue(.missing, true)
            note = c.activityValue(.note, "")
        }
    }

    /// The whole answer. `ok == false` carries `error`, and an empty
    /// `events` with `ok` is "nothing happened in this window" — a
    /// different and far less alarming thing than "I could not look".
    struct Feed: Equatable {
        var ok = false
        var error = ""
        var days = 7
        var events: [Event] = []
        var log = RawLog()
        /// True when the ledger could be read at all. False turns the
        /// conversation rows off rather than reporting a quiet week.
        var sawLedger = false
        /// How many older rows were left off the end. Thirty days of this
        /// Mac is several hundred, and a settings pane that draws every
        /// one of them is a settings pane that takes a second to open —
        /// so it is cut, and the number is stated rather than the list
        /// simply stopping.
        var trimmed = 0
    }

    /// The most rows this will hand to a pane. Above this the window is
    /// the thing to change, not the scroll bar.
    static let ceiling = 200

    // MARK: - The script's shapes
    //
    // Every key below is read with `decodeIfPresent`. Swift's synthesised
    // `Decodable` throws `keyNotFound` for a missing key rather than
    // falling back to the property's default, and one absent key takes the
    // whole answer with it — measured on this repo on 2026-09-04, where
    // adding a single `var error = ""` turned every success into "Moe
    // couldn't reach…". `history.py` fills every key on every path too;
    // one half would do today, two is what survives either end changing.

    struct Elsewhere: Decodable, Equatable {
        var at = ""
        var platform = ""
        var chatType = ""
        var chatID = ""
        var session = ""
        var model = ""
        var provider = ""
        /// A count as a **string**, sometimes ending in `+`. The gateway
        /// truncates a message to 500 characters before a hook can see it,
        /// so the hook writes `"500+"` rather than a length that would be
        /// a lie on every substantial turn. Lines written before
        /// 2026-09-01 hold a bare integer; both shapes are in the live
        /// file and the script normalises both to this.
        var inChars = ""
        var outChars = ""

        enum CodingKeys: String, CodingKey {
            case at, platform, session, model, provider
            case chatType = "chat_type", chatID = "chat_id"
            case inChars = "in_chars", outChars = "out_chars"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = c.activityValue(.at, "")
            platform = c.activityValue(.platform, "")
            chatType = c.activityValue(.chatType, "")
            chatID = c.activityValue(.chatID, "")
            session = c.activityValue(.session, "")
            model = c.activityValue(.model, "")
            provider = c.activityValue(.provider, "")
            inChars = c.activityValue(.inChars, "")
            outChars = c.activityValue(.outChars, "")
        }
    }

    /// A job's runs on one day, already rolled up by the script.
    ///
    /// Not one row per run, and that is the script's decision rather than
    /// this file's: `moe-calendar-heads-up` fires every two minutes, which
    /// is about five thousand runs a week from one job. A timeline made of
    /// those is not a timeline. A job that ran once still reads as the one
    /// event it was, because `runs == 1` renders as a time.
    struct RunDay: Decodable, Equatable {
        var job = ""
        var name = ""
        var day = ""
        var runs = 0
        var failures = 0
        var firstAt = ""
        var lastAt = ""
        var upkeep = false

        enum CodingKeys: String, CodingKey {
            case job, name, day, runs, failures, upkeep
            case firstAt = "first_at", lastAt = "last_at"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            job = c.activityValue(.job, "")
            name = c.activityValue(.name, "")
            day = c.activityValue(.day, "")
            runs = c.activityValue(.runs, 0)
            failures = c.activityValue(.failures, 0)
            firstAt = c.activityValue(.firstAt, "")
            lastAt = c.activityValue(.lastAt, "")
            upkeep = c.activityValue(.upkeep, false)
        }
    }

    struct Incident: Decodable, Equatable {
        var id = ""
        var job = ""
        var name = ""
        var state = ""
        var type = ""
        var firstAt = ""
        var lastAt = ""
        var error = ""
        var output = ""
        var closed = false
        var upkeep = false

        enum CodingKeys: String, CodingKey {
            case id, job, name, state, type, error, output, closed, upkeep
            case firstAt = "first_at", lastAt = "last_at"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.activityValue(.id, "")
            job = c.activityValue(.job, "")
            name = c.activityValue(.name, "")
            state = c.activityValue(.state, "")
            type = c.activityValue(.type, "")
            firstAt = c.activityValue(.firstAt, "")
            lastAt = c.activityValue(.lastAt, "")
            error = c.activityValue(.error, "")
            output = c.activityValue(.output, "")
            closed = c.activityValue(.closed, false)
            upkeep = c.activityValue(.upkeep, false)
        }
    }

    struct Answer: Decodable, Equatable {
        var ok = false
        var error = ""
        var days = 7
        var elsewhere: [Elsewhere] = []
        var runs: [RunDay] = []
        var incidents: [Incident] = []
        var log = RawLog()

        enum CodingKeys: String, CodingKey {
            case ok, error, days, elsewhere, runs, incidents, log
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.activityValue(.ok, false)
            error = c.activityValue(.error, "")
            days = c.activityValue(.days, 7)
            elsewhere = c.activityValue(.elsewhere, [])
            runs = c.activityValue(.runs, [])
            incidents = c.activityValue(.incidents, [])
            log = c.activityValue(.log, RawLog())
        }
    }

    // MARK: - Running it

    /// Asked with `BrainSetup.python()` — Moe's own interpreter, never the
    /// system `python3` (a stub that puts up an install dialog on a Mac
    /// without developer tools).
    ///
    /// `history.py` is still stdlib-only on purpose — no PyYAML, nothing
    /// imported out of Hermes — so any real interpreter can run it, which is
    /// what `BrainSetup.python()` falls back to when Moe's own is broken.
    static func ask(days: Int, logLines: Int) -> Answer? {
        guard let script = Chats.scriptPath() else { return nil }
        // Joined, for the same reason `Chats.askIndex` joins its own — one
        // spelling for every argument this repo hands argparse, so nobody
        // has to remember which of them can carry a leading hyphen.
        let r = ScriptRunner.run(BrainSetup.python(),
                                 [script, "activity", "--days=\(days)",
                                  "--log-lines=\(logLines)"],
                                 timeout: 25)
        guard let data = Chats.jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: data)
    }

    // MARK: - The timeline

    /// Everything, newest first.
    ///
    /// The ledger half is read here rather than in the script because it
    /// is Moe's own store, sealed with keys that only this process holds —
    /// a Python reader would need the keyring and would be a second thing
    /// that could decrypt a person's conversations.
    static func timeline(days: Int = 7, logLines: Int = 40) -> Feed {
        var feed = Feed(days: days)
        let since = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400)

        let ledger = Chats.reader()
        let projector = ledger.projector
        let live = Chats.liveThreads(ledger)
        feed.sawLedger = FileManager.default.fileExists(atPath: Paths.ledger.path)
        for thread in live {
            guard let convo = projector.project(thread: thread) else { continue }
            feed.events.append(contentsOf: sittings(convo, since: since))
        }

        guard let answer = ask(days: days, logLines: logLines) else {
            // The ledger half still stands. A screen that showed nothing
            // because one of four sources was missing would be lying about
            // the other three.
            feed.ok = feed.sawLedger
            // Not "your conversations are below": on a Mac with no ledger
            // there are none, and a banner that promises a list under it
            // is worse than one that says what it could not read. Found by
            // rendering the pane against a scratch home.
            feed.error = "Moe couldn't read Hermes's record of what ran and what failed. Anything below is from Moe's own record."
            feed.events.sort { $0.at > $1.at }
            trim(&feed)
            return feed
        }
        feed.ok = answer.ok || feed.sawLedger
        feed.error = answer.ok ? "" : answer.error
        feed.log = answer.log
        feed.events.append(contentsOf: answer.elsewhere.compactMap(event(elsewhere:)))
        feed.events.append(contentsOf: answer.runs.compactMap(event(run:)))
        feed.events.append(contentsOf: answer.incidents.compactMap(event(incident:)))
        feed.events.sort { $0.at > $1.at }
        trim(&feed)
        return feed
    }

    /// Cut the tail, and say how much was cut. Sorting first is what makes
    /// this safe: what goes is always the oldest, and nothing is dropped
    /// out of the middle of a day.
    static func trim(_ feed: inout Feed) {
        guard feed.events.count > ceiling else { return }
        feed.trimmed = feed.events.count - ceiling
        feed.events = Array(feed.events.prefix(ceiling))
    }

    /// One conversation, as one row per day it was alive.
    ///
    /// Per day rather than per turn, and for the same reason the script
    /// rolls up cron runs: a person's thread is dozens of turns and a
    /// timeline of every one of them is a transcript with the words taken
    /// out, which is the least useful document available. The day is the
    /// unit a person actually asks about.
    static func sittings(_ convo: ConversationStore.Conversation,
                         since: Date) -> [Event] {
        let cal = Calendar.current
        var byDay: [Date: [ConversationStore.StoredTurn]] = [:]
        for turn in convo.turns where turn.at >= since {
            byDay[cal.startOfDay(for: turn.at), default: []].append(turn)
        }
        return byDay.map { day, turns in
            let last = turns.map(\.at).max() ?? day
            let mine = turns.filter { $0.role == .you }.count
            return Event(id: "talk:\(convo.id):\(Int(day.timeIntervalSince1970))",
                         at: last,
                         kind: .talked,
                         title: convo.title,
                         detail: mine == 1 ? "You asked Moe one thing."
                                           : "You and Moe went back and forth \(turns.count) times.",
                         note: "",
                         thread: convo.id)
        }
    }

    /// A turn that happened somewhere other than here.
    ///
    /// **No `thread`, deliberately.** §4.2 says the words are reached by
    /// opening that session in Chats, and on this Mac that link does not
    /// exist: the activity hook records Hermes's own session id
    /// (`20260831_121551_86fc6d10`), and the ledger's threads are keyed by
    /// nothing that resolves to it — a Telegram turn reaches the ledger
    /// through Moe Away, under a thread id that is never written back
    /// beside the session. Offering an "Open" that goes nowhere would be a
    /// well-formed identifier resolving to nothing, which is worse than an
    /// absent one. The row says where to look instead.
    static func event(elsewhere row: Elsewhere) -> Event? {
        guard let at = date(row.at) else { return nil }
        let where_ = ReminderChannels.title(for: row.platform)
        let kind = row.chatType == "dm" || row.chatType.isEmpty ? "" : " in a \(row.chatType)"
        var note = ""
        if !row.model.isEmpty { note = "Answered with \(row.model)." }
        if let sizes = lengths(row) { note += note.isEmpty ? sizes : " " + sizes }
        return Event(id: "away:\(row.at):\(row.session):\(row.chatID)",
                     at: at,
                     kind: .elsewhere,
                     title: "Replied on \(where_)\(kind)",
                     detail: "This happened away from this Mac, so Moe only knows that it did — not what was said.",
                     note: note)
    }

    /// "You wrote 36 characters, Moe wrote 74." — and never a number that
    /// is not one.
    ///
    /// `500+` is the gateway's truncation showing through: it cuts both
    /// fields at 500 characters before any hook sees them, so a longer
    /// turn arrives as exactly 500 and the hook records the suffix rather
    /// than a length it knows to be wrong. Printing "500" here would put
    /// that lie back.
    static func lengths(_ row: Elsewhere) -> String? {
        func say(_ raw: String) -> String? {
            guard !raw.isEmpty else { return nil }
            return raw.hasSuffix("+") ? "over \(raw.dropLast()) characters"
                                      : "\(raw) characters"
        }
        guard let mine = say(row.inChars), let theirs = say(row.outChars) else { return nil }
        return "You wrote \(mine), Moe wrote \(theirs)."
    }

    /// A job's day. `runs == 1` reads as the single event it was.
    static func event(run: RunDay) -> Event? {
        guard let at = date(run.lastAt) else { return nil }
        let name = JobActivity.title(for: run.name)
        var detail: String
        if run.runs == 1 {
            detail = "Ran once, at \(clock(at))."
        } else {
            detail = "Ran \(run.runs) times, last at \(clock(at))."
        }
        if run.failures > 0 {
            detail += run.failures == run.runs
                ? " Every one of them stopped on a problem."
                : " \(run.failures) of them stopped on a problem."
        }
        return Event(id: "run:\(run.job):\(run.day)",
                     at: at,
                     kind: .job,
                     title: name,
                     detail: detail,
                     note: "",
                     thread: "",
                     upkeep: run.upkeep)
    }

    /// A failure Hermes minted, one row each and never rolled up: it is
    /// the only thing on this screen a person can act on.
    static func event(incident: Incident) -> Event? {
        guard let at = date(incident.lastAt) else { return nil }
        let name = JobActivity.title(for: incident.name)
        // Hermes's own word for where the incident got to. `closed` is the
        // one that means it stopped mattering, and it is the one worth
        // saying, because a closed incident sitting in a timeline with no
        // note reads as an open problem.
        let state: String
        switch incident.state {
        case "closed": return nil          // it recovered; the run rows say so
        case "acked": state = "You have seen this one."
        case "alerted": state = "Moe told you about this one."
        default: state = "Moe noticed this one."
        }
        return Event(id: "bad:\(incident.id)",
                     at: at,
                     kind: .incident,
                     title: "\(name) stopped",
                     // Hermes puts a whole stderr dump in here on a script
                     // failure — a Python warning, a file path, a line
                     // number. A row is a row: the first line of it, and
                     // the output file the script named has the rest.
                     detail: incident.error.isEmpty
                        ? "Hermes did not say why."
                        : Chats.line(incident.error, limit: 160),
                     note: state,
                     thread: "",
                     upkeep: incident.upkeep)
    }

    // MARK: - Time

    /// Hermes writes offset ISO 8601 with fractional seconds in some
    /// places and without in others, and both turn up in one answer.
    static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    static func clock(_ at: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: at).lowercased()
    }

    /// "Today", "Yesterday", "Tuesday", "12 August" — the heading a group
    /// of rows sits under.
    static func day(_ at: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(at) { return "Today" }
        if cal.isDateInYesterday(at) { return "Yesterday" }
        let f = DateFormatter()
        // Inside the last week a weekday is what a person recognises;
        // beyond it a weekday is ambiguous and a date is not.
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: at),
                                         to: cal.startOfDay(for: Date())).day, days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateFormat = "d MMMM"
        }
        return f.string(from: at)
    }
}

/// One key, or the fallback — never a thrown `keyNotFound` that takes the
/// whole answer with it. See the note on `Chats.chatsValue`; this is the
/// same tool under a third name, because a module may not declare two
/// `value(_:_:)` on `KeyedDecodingContainer`.
private extension KeyedDecodingContainer {
    func activityValue<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
