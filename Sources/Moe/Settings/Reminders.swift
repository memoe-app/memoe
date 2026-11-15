import Foundation

/// What is on a clock, and how to put something new there.
///
/// The whole answer comes from `hermes/reminders.py`, which is the pane's
/// side of Hermes's cron: the schedule store, the sixteen blueprints, and
/// the one route by which a Moe job may be created. Nothing here parses
/// `hermes cron list` — that command prints a box-drawn report with no
/// `--json` at all — and nothing here writes `cron/jobs.json`.
///
/// Read the head of that script before changing anything here. The two
/// rules it enforces are not cosmetic: a job created any way other than
/// `register_job` → `pin_job_brain` stops the next time the person changes
/// their brain in Settings, and a blueprint default accepted as an answer
/// is a reminder nobody asked for.
///
/// `JobActivity` is the other half and stays the other half. It owns last
/// run, next run, outcome and cost, from `hermes-jobs/job-activity.py`;
/// this owns where a job delivers, what it was asked to do, and whether it
/// can fire. The pane reads both and joins them on `id`.
///
/// Everything here blocks on a subprocess. Call it off the main thread.
enum Reminders {

    // MARK: - What comes back
    //
    // Every type below decodes each key with `decodeIfPresent` and keeps
    // its own default when the key is absent, rather than letting Swift
    // synthesise `init(from:)`.
    //
    // That is not defensiveness for its own sake. Swift's synthesised
    // `Decodable` does **not** fall back to a property's default value for
    // a missing key — it throws `keyNotFound`, and the whole answer
    // becomes nil. Measured here on 2026-09-04: adding one `var error =
    // ""` to `Listing` made every successful `list` fail to decode,
    // because a success has no error to report, and the pane went from a
    // list of reminders to "Moe couldn't reach the part of itself that
    // keeps the clock". `Outcome` had the same hole and would have
    // reported every created reminder as a failure *after* creating it.
    //
    // `reminders.py` also fills every key on every path (its `SHAPES`), so
    // this is the second of two halves. One would do today; two is what
    // survives either end changing.

    /// Whether a due job would actually fire. Three answers, and the third
    /// one is load-bearing: `nil` is "could not tell", which is not
    /// "stopped". A heartbeat file that was never written is an older
    /// build or a scheduler that has not started, and calling that dead
    /// tells a person their reminders are broken on no evidence.
    struct Ticker: Decodable, Equatable {
        var alive: Bool?
        var age: Double?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alive = c.value(.alive, nil as Bool?)
            age = c.value(.age, nil as Double?)
        }
        enum CodingKeys: String, CodingKey { case alive, age }
    }

    /// One job on the clock, in the parts `JobActivity` has no reason to
    /// know. `state` and `runnable` are Hermes's own answers, never
    /// re-derived here from `enabled` — that is how a paused job comes to
    /// read as scheduled.
    struct Job: Decodable, Identifiable, Equatable {
        var id = ""
        var name = ""
        var deliver = ""
        var prompt = ""
        var script = ""
        /// scheduled | paused | completed | error
        var state = ""
        var runnable = false
        var terminal = false
        var schedule = ""
        var nextRun: String?
        /// How many runs were asked for; nil is "for as long as I keep it".
        var repeatTimes: Int?
        var completed = 0
        /// Moe's own upkeep: shown, never edited. The list is in the script.
        var upkeep = false

        // The brain this job runs on, and whether that still adds up.
        //
        // These are not decoration. Hermes refuses to dispatch an UNPINNED
        // job whose global inference config has moved since it was created
        // — and it refuses at dispatch, leaving the record untouched. So
        // `state`, `runnable` and `next_run` all say a dead job is fine,
        // and this pane said "Next tomorrow at 8:00 am" about jobs that
        // would be skipped every tick until somebody remade them. Every
        // job the pane did not create itself can be in that state: on this
        // Mac, `moe-social-drafts` is one brain change away from it.
        //
        // `drifted` is Hermes's own verdict, computed in the script from
        // `cron_model_drift_axes` — never re-derived here from the four
        // fields below, which is how you get a pane that calls a working
        // job dead. Empty means it will fire.
        var provider = ""
        var model = ""
        var providerSnapshot = ""
        var modelSnapshot = ""
        /// The axes — "provider", "model" — Hermes would refuse to run on.
        var drifted: [String] = []
        /// The other hole: unpinned with no snapshot either, so the guard
        /// cannot see it. This job is not stopped; it follows whatever
        /// brain Moe is moved to and spends on it. A caution, not a stop.
        var unguarded = false
        /// Made before jobs recorded who asked for them, and messages
        /// somebody: "This job messages Dan — keep?", asked once on the card.
        /// Until it is answered, what the job sends to a named person shows
        /// amber ("made before Moe checked recipients") rather than being
        /// refused.
        var keep: Keep?


        enum CodingKeys: String, CodingKey {
            case id, name, deliver, prompt, script, state, runnable, terminal, schedule, upkeep, keep
            case nextRun = "next_run", repeatTimes = "repeat", completed
            case provider, model, drifted, unguarded
            case providerSnapshot = "provider_snapshot", modelSnapshot = "model_snapshot"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, "")
            name = c.value(.name, "")
            deliver = c.value(.deliver, "")
            prompt = c.value(.prompt, "")
            script = c.value(.script, "")
            state = c.value(.state, "")
            runnable = c.value(.runnable, false)
            terminal = c.value(.terminal, false)
            schedule = c.value(.schedule, "")
            nextRun = c.value(.nextRun, nil as String?)
            repeatTimes = c.value(.repeatTimes, nil as Int?)
            completed = c.value(.completed, 0)
            upkeep = c.value(.upkeep, false)
            provider = c.value(.provider, "")
            model = c.value(.model, "")
            providerSnapshot = c.value(.providerSnapshot, "")
            modelSnapshot = c.value(.modelSnapshot, "")
            drifted = c.value(.drifted, [])
            unguarded = c.value(.unguarded, false)
            keep = c.value(.keep, nil as Keep?)
        }

        struct Keep: Decodable, Equatable {
            var asksFor: [String] = []
            var question = ""
            init(asksFor: [String] = [], question: String = "") {
                self.asksFor = asksFor
                self.question = question
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                asksFor = c.value(.asksFor, [])
                question = c.value(.question, "")
            }
            enum CodingKeys: String, CodingKey { case asksFor = "asks_for", question }

            /// What is recorded as the person's words when they press Keep:
            /// the names they are agreeing the job may message.
            var answer: String { "Keep messaging " + asksFor.joined(separator: ", ") }
        }

        /// What this job is, said to a person.
        ///
        /// Moe's upkeep jobs are named by `JobActivity`, which already has
        /// words for all seven and is what Settings › Background prints —
        /// two screens naming one job two ways is worse than either name.
        /// Everything else is a reminder the person made, and its name is
        /// theirs.
        var title: String {
            upkeep ? JobActivity.title(for: name) : name
        }

        /// What this job will do, in one line.
        ///
        /// The first sentence of the prompt, not the first line: several
        /// blueprints fill a whole paragraph onto one line, and the
        /// morning briefing's is 500 characters that name a skill and a
        /// markdown file. Cut at a word, never mid-word, and never at all
        /// for a script job — those have no prompt.
        var summary: String {
            let flat = prompt.split(whereSeparator: \.isNewline)
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if flat.isEmpty { return "" }
            if flat.count <= Self.summaryLength { return dotted(flat) }
            let cut = flat.prefix(Self.summaryLength)
            let atWord = cut.lastIndex(of: " ").map { String(cut[cut.startIndex..<$0]) } ?? String(cut)
            return atWord.trimmingCharacters(in: .whitespaces) + "…"
        }

        private static let summaryLength = 110

        /// A sentence ends in something. Without this the row read "Remind
        /// the user: call mum Spoken here, and sent to the chats you
        /// picked" — two sentences with nothing between them.
        private func dotted(_ text: String) -> String {
            ".!?…".contains(text.last ?? " ") ? text : text + "."
        }

        /// When this will next happen — **or why it will not**.
        ///
        /// The rule this method exists for: never tell a person something
        /// is scheduled when it cannot fire. Five different things stop a
        /// job, they look alike from a distance, and only one of them is
        /// something they did on purpose:
        ///
        /// - it finished the run count it was given (terminal, `completed`)
        /// - it stopped on an error (terminal, `error`)
        /// - they paused it
        /// - it is not tied to a brain and the brain has moved, so Hermes
        ///   refuses to spend on it — `drifted`
        /// - the scheduler itself is not ticking, so nothing fires at all
        ///
        /// The fourth was missing until 2026-09-04, and it is the one that
        /// makes the rule FALSE rather than incomplete: that refusal
        /// happens at dispatch and leaves no mark on the record, so
        /// `state` reads "scheduled", `runnable` reads true, `next_run` is
        /// set, and this said "Next tomorrow at 8:00 am" about a job that
        /// would never run again. It applies to every job the pane did not
        /// create — Moe's own `create` pins, but a job made from a
        /// conversation or by an older build does not.
        ///
        /// The last one is the reason `ticker` is a parameter. A row that
        /// says "Next at 6:30 pm" while Moe's background clock is stopped
        /// is a promise the machine cannot keep. An *unknown* ticker is
        /// not a stopped one and says nothing extra — Hermes's own rule,
        /// and it is the right way round: reporting a live scheduler as
        /// dead tells people scheduling is pointless when it is working.
        func when(_ ticker: Ticker) -> String {
            if terminal {
                return state == "error"
                    ? "Stopped after a problem. It will not run again."
                    : "Finished — it ran the number of times you asked for."
            }
            if !runnable { return "Paused. It will not run until you switch it back on." }
            if !drifted.isEmpty {
                return "Skipped every time. It was set up for a different brain to the one "
                    + "Moe is on now and is not tied to one, so Moe will not spend on it. "
                    + "Remove it and make it again."
            }
            guard let next = nextRun, let at = Self.date(next) else {
                return "No next time set, so it will not run."
            }
            if ticker.alive == false {
                return "Waiting — nothing is running the clock right now, so this will not fire until it is back."
            }
            return "Next " + Self.friendly(at)
        }

        /// The warning that is **not** a stop, and so must not be in
        /// `when`.
        ///
        /// An unpinned job with no snapshot of the brain it was made on is
        /// invisible to Hermes's spend guard: nothing stops it, so it runs
        /// on whatever brain Moe is moved to, at whatever that costs. It
        /// is the state `reminders.py` used to leave behind when creating
        /// one failed halfway. Saying "it will not run" about it would be
        /// the same lie in the other direction, so it goes beside the row
        /// rather than in place of its next time.
        var caution: String? {
            // `when` has already said this one, in stronger words.
            guard drifted.isEmpty, unguarded, !terminal else { return nil }
            return "Not tied to a brain, so it will follow whatever brain Moe is set to."
        }

        /// How often, in the person's words — and **empty rather than a
        /// cron expression**.
        ///
        /// Hermes stores a schedule two ways: "every 1440m" for an
        /// interval, and "30 18 * * 1-5" for a calendar one. Neither is a
        /// sentence, and the second is the thing the whole blueprint
        /// feature exists so that nobody has to read: its own design note
        /// says the point is that "users never type raw cron". Printing it
        /// back at them undoes that in one line, so an expression this
        /// cannot say in words is not said at all — the row still carries
        /// its next time, which is the part that answers the question.
        var cadence: String {
            let s = schedule.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return "" }
            if s.hasPrefix("once at") { return "Once" }
            if let m = Self.minutes(s) {
                if m % 1440 == 0 { return m == 1440 ? "Every day" : "Every \(m / 1440) days" }
                if m % 60 == 0 { return m == 60 ? "Every hour" : "Every \(m / 60) hours" }
                return "Every \(m) minutes"
            }
            return Self.recurrence(s)
        }

        /// "every 1440m" → 1440. Nil for a cron expression, which has no
        /// single interval to name — and nil for a non-positive one, which
        /// is not an interval at all. Without that second guard "every 0m"
        /// rendered as "Every 0 days" and "every -5m" as "Every -5
        /// minutes", both of which are sentences about a job that has no
        /// cadence to describe. Nil sends them to `recurrence`, which
        /// cannot read them either and answers with nothing — the right
        /// answer, and the one this file already prefers to a half-right
        /// one.
        private static func minutes(_ display: String) -> Int? {
            guard display.hasPrefix("every "), display.hasSuffix("m"),
                  let n = Int(display.dropFirst(6).dropLast()), n > 0 else { return nil }
            return n
        }

        /// A five-field cron expression as how often it comes round —
        /// the time of day is deliberately left out, because `when` has
        /// already said it and a row saying both says it twice.
        ///
        /// Only the shapes the sixteen blueprints actually produce are
        /// translated. Anything else returns empty: a partly-right
        /// sentence about when something will happen is worse than no
        /// sentence, and the blueprints are where these come from.
        static func recurrence(_ expression: String) -> String {
            let f = expression.split(separator: " ").map(String.init)
            guard f.count == 5, f[2] == "*", f[3] == "*" else { return "" }
            let (minute, hour, day) = (f[0], f[1], f[4])
            // The day-of-week field, checked on EVERY branch. The two
            // interval branches used to read fields 1, 2 and 3 and ignore
            // field 5 entirely, so "*/30 * * * 1-5" — every half hour, on
            // weekdays — was shown as "Every 30 minutes", which is what
            // the row says about a job that also runs all weekend. It is
            // the same class of mistake as printing the raw expression:
            // a confident sentence that is not true of the job.
            guard let onDays = Self.days(day) else { return "" }
            if minute.hasPrefix("*/"), hour == "*", let n = Int(minute.dropFirst(2)), n > 0 {
                return "Every \(n) minutes" + onDays
            }
            if hour.hasPrefix("*/"), Int(minute) != nil, let n = Int(hour.dropFirst(2)), n > 0 {
                return (n == 1 ? "Every hour" : "Every \(n) hours") + onDays
            }
            guard Int(minute) != nil, Int(hour) != nil else { return "" }
            switch day {
            case "*": return "Every day"
            case "1-5": return "Every weekday"
            case "0,6", "6,0": return "Every weekend"
            default:
                guard let n = Int(day), Self.dayNames.indices.contains(n) else { return "" }
                return "Every \(Self.dayNames[n])"
            }
        }

        private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                       "Thursday", "Friday", "Saturday"]

        /// A cron day-of-week field as a phrase to hang off an interval —
        /// empty for "every day", which needs no phrase. **Nil** is "I
        /// cannot say this one", and the caller must then say nothing at
        /// all rather than drop the restriction and describe a different
        /// job.
        private static func days(_ day: String) -> String? {
            switch day {
            case "*": return ""
            case "1-5": return " on weekdays"
            case "0,6", "6,0": return " at weekends"
            default:
                guard let n = Int(day), Self.dayNames.indices.contains(n) else { return nil }
                return " on \(Self.dayNames[n])s"
            }
        }

        /// Hermes writes offset ISO 8601 with fractional seconds in some
        /// places and without in others; both turn up in one listing.
        static func date(_ text: String) -> Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: text) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: text)
        }

        /// "at 6:30 pm", "tomorrow at 9:08 am", "on 12 September".
        static func friendly(_ at: Date) -> String {
            let cal = Calendar.current
            let time = DateFormatter()
            time.dateFormat = "h:mm a"
            let clock = time.string(from: at).lowercased()
            if cal.isDateInToday(at) { return "at \(clock)" }
            if cal.isDateInTomorrow(at) { return "tomorrow at \(clock)" }
            let day = DateFormatter()
            day.dateFormat = "d MMMM"
            return "on \(day.string(from: at)) at \(clock)"
        }
    }

    /// `ok == false` carries `error`, and the pane shows it. The script
    /// refuses in sentences — "Moe's thinking part isn't installed here
    /// yet" — and replacing that with one generic line of our own throws
    /// away the only thing that told the person what to do about it.
    struct Listing: Decodable {
        var ok = false
        var error = ""
        var jobs: [Job] = []
        var ticker = Ticker()
        /// Something in `jobs` did not decode, so this list is **short**,
        /// possibly to nothing.
        ///
        /// The whole file's rule is that "nothing is scheduled" and "I
        /// could not look" are different answers. `jobs` was read with the
        /// same forgiving helper as every scalar, so one malformed element
        /// — or a `jobs` that was not a list at all — threw inside `try?`
        /// and came back as `ok: true` with an empty array: the pane drew
        /// "Nothing yet" over a store that may have been full. That is the
        /// exact conflation the header forbids, arrived at through the
        /// mechanism meant to prevent it.
        ///
        /// Not in `CodingKeys`: this is decided here, not sent. (It must
        /// not be — `test-reminders-pane.sh` requires the script to carry
        /// every key `CodingKeys` names, and no answer carries this one.)
        var unreadable = false

        /// One element of `jobs` that is allowed to fail on its own, so a
        /// single bad record costs its own row rather than every row.
        /// `Job.init` is forgiving about every field, so this only fails
        /// for something that is not an object at all.
        private struct MaybeJob: Decodable {
            let job: Job?
            init(from decoder: Decoder) throws { job = try? Job(from: decoder) }
        }

        enum CodingKeys: String, CodingKey { case ok, error, jobs, ticker }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.value(.ok, false)
            error = c.value(.error, "")
            ticker = c.value(.ticker, Ticker())
            if !c.contains(.jobs) {
                // No key at all is an older script, not a broken list —
                // the same degrade-to-default every other field takes.
                jobs = []
            } else if let raw = try? c.decode([MaybeJob].self, forKey: .jobs) {
                jobs = raw.compactMap(\.job)
                unreadable = jobs.count != raw.count
            } else {
                // The key is there and is not a list of anything.
                jobs = []
                unreadable = true
            }
        }
    }

    /// One blank on a template's form. **There is no `default`** — the
    /// script strips it before this is decoded, so a default cannot be
    /// pre-filled here even by accident. See `reminders.py`.
    struct Field: Decodable, Identifiable, Equatable {
        var name = ""
        /// text | time | enum | weekdays
        var type = "text"
        var label = ""
        var options: [String] = []
        var optional = false
        var strict = true
        var help = ""
        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, type, label, options, optional, strict, help
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, "")
            type = c.value(.type, "text")
            label = c.value(.label, "")
            options = c.value(.options, [])
            optional = c.value(.optional, false)
            strict = c.value(.strict, true)
            help = c.value(.help, "")
        }

        /// A `weekdays` slot is an enum with three answers; nothing about
        /// it needs its own control.
        var isChoice: Bool { !options.isEmpty }
    }

    struct Blueprint: Decodable, Identifiable, Equatable {
        var key = ""
        var title = ""
        var description = ""
        var category = ""
        var fields: [Field] = []
        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, title, description, category, fields
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.value(.key, "")
            title = c.value(.title, "")
            description = c.value(.description, "")
            category = c.value(.category, "")
            fields = c.value(.fields, [])
        }

        /// Hermes's titles, in Moe's voice. §4.1: the rewriting happens at
        /// the surface, never in the catalogue — the catalogue is Hermes's
        /// and is shared with everything else that reads it.
        var heading: String {
            switch key {
            case "morning-brief": return "A morning briefing"
            case "important-mail": return "Only the mail that matters"
            case "weekly-review": return "A weekly look back"
            case "workday-start": return "A nudge when work starts"
            case "custom-reminder": return "Remind me to…"
            case "evening-winddown": return "Winding down"
            case "news-digest": return "News on one subject"
            case "bill-renewal-watch": return "Bills and renewals"
            case "price-watch": return "Watch a price"
            case "competitor-watch": return "Watch other companies"
            case "habit-checkin": return "Keep a habit going"
            case "hydration-move": return "Water and a stretch"
            case "meal-plan": return "A week of meals"
            case "learn-daily": return "Learn a little daily"
            case "gratitude-journal": return "Something to reflect on"
            case "on-this-day": return "Something worth knowing"
            default: return title
            }
        }
    }

    struct Catalog: Decodable {
        var ok = false
        var error = ""
        var blueprints: [Blueprint] = []
        var deliver: [String] = []

        enum CodingKeys: String, CodingKey { case ok, error, blueprints, deliver }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.value(.ok, false)
            error = c.value(.error, "")
            blueprints = c.value(.blueprints, [])
            deliver = c.value(.deliver, [])
        }
    }

    /// What a write did, or would not do. `error` is written for a person
    /// to read: the script refuses in sentences rather than status codes,
    /// because every refusal here is something they can act on.
    struct Outcome: Decodable {
        var ok = false
        var error = ""
        var id = ""
        var name = ""
        /// The slots still blank, when that was the refusal.
        var missing: [String] = []

        init(ok: Bool, error: String) { self.ok = ok; self.error = error }

        enum CodingKeys: String, CodingKey { case ok, error, id, name, missing }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ok = c.value(.ok, false)
            error = c.value(.error, "")
            id = c.value(.id, "")
            name = c.value(.name, "")
            missing = c.value(.missing, [])
        }
    }

    // MARK: - Running it

    /// ~/.moe/hermes/reminders.py (installed), then the app's own copy,
    /// then the checkout — the ladder `BrainSetup` uses, for the same
    /// reason: the middle rung is what keeps a home whose payload copy
    /// failed from showing an empty pane with no explanation.
    static func scriptPath() -> String? {
        var candidates = [Paths.home.appendingPathComponent("hermes/reminders.py").path]
        if let b = Payload.bundlePayload {
            candidates.append(b.appendingPathComponent("hermes/reminders.py").path)
        }
        if let c = Payload.checkoutPath("moe-home/hermes/reminders.py") { candidates.append(c) }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Blocking. Nil when the script could not be found or gave no answer
    /// at all — which the pane says in words, rather than drawing an empty
    /// list: "nothing is scheduled" and "I could not look" are different
    /// answers and only one of them is fine.
    private static func ask<T: Decodable>(_ args: [String], timeout: TimeInterval = 30) -> T? {
        guard let script = scriptPath() else { return nil }
        // The Hermes venv's interpreter, never the system one:
        // configure-hermes.py needs PyYAML at import and refuses, loudly,
        // to be imported by anything that lacks it — and reminders.py
        // imports it to reach `register_job`.
        let r = ScriptRunner.run(BrainSetup.python(), [script] + args, timeout: timeout)
        guard let data = jsonPart(r.output) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// The last line that is a JSON object. stderr is merged into stdout
    /// by `ScriptRunner`, and Hermes's own imports write warnings there —
    /// so the answer is the last line, not the first, and a run that
    /// printed only warnings has no answer at all.
    static func jsonPart(_ text: String) -> Data? {
        let line = text.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("{") && $0.hasSuffix("}") }
        return line.map { Data($0.utf8) }
    }

    /// Nil only when the script gave no answer at all — it could not be
    /// found, it could not be started, or it crashed. A refusal comes back
    /// as a decoded value with `ok == false` and words in `error`, and the
    /// two are different things the pane says differently.
    static func list() -> Listing? { ask(["list"]) }

    static func catalog() -> Catalog? { ask(["blueprints"]) }

    /// Create one reminder from a template. `values` is slot name → the
    /// person's answer; a blank one is refused by the script, which is the
    /// enforcing end of "a template's default is never an answer".
    ///
    /// Creating takes longer than reading: `register_job` starts a second
    /// Python that imports Hermes's cron before it writes anything.
    static func create(key: String, values: [String: String], name: String) -> Outcome {
        guard let json = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: json, encoding: .utf8) else {
            return Outcome(ok: false, error: "Moe couldn't read that form.")
        }
        // `--name=` with the equals sign, because the name is the one
        // argument here a person types. `--name -daily` is argparse's
        // "expected one argument": exit 2, nothing on stdout, and so
        // nothing for `ask` to decode — which the pane reports as "Moe
        // couldn't reach the part of itself that keeps the clock" about a
        // reminder called `-daily`, which is a perfectly good name. The
        // `=` form has no such reading. `--key` and `--values` come from
        // the catalogue and from JSONSerialization, so neither can start
        // with a dash, but they are spelled the same way here so that the
        // next argument added does not have to rediscover this.
        let out: Outcome? = ask(["create", "--key=" + key, "--values=" + text,
                                 "--name=" + name], timeout: 90)
        return out ?? Outcome(ok: false, error: unreachable)
    }

    /// The person's "Keep" on a job's "this job messages X — keep?" card:
    /// recorded as who asked for the job. `reminders.py` accepts it only from
    /// this app (it checks its parent process is the signed app).
    static func keep(id: String, answer: String) -> Outcome {
        let out: Outcome? = ask(["keep", id, "--answer=" + answer], timeout: 45)
        return out ?? Outcome(ok: false, error: unreachable)
    }

    /// pause | resume | remove | run.
    static func verb(_ verb: String, id: String) -> Outcome {
        let out: Outcome? = ask([verb, id], timeout: 45)
        return out ?? Outcome(ok: false, error: unreachable)
    }

    /// One sentence for "the script did not answer", used wherever a write
    /// comes back with nothing. A write that cannot be confirmed must not
    /// report success: the pane reloads after every one of these, so what
    /// the person sees next is the store rather than this guess.
    private static let unreachable =
        "Moe couldn't reach the part of itself that keeps the clock. Nothing was changed."
}

/// One key, or the fallback — never a thrown `keyNotFound` that takes the
/// whole answer with it.
///
/// Swift's synthesised `Decodable` does not use a property's default value
/// when a key is absent; it throws, and a struct with one absent key
/// decodes to nothing at all. Every type in `Reminders` reads its keys
/// through this instead, so a shape that grows a field on one side and not
/// the other degrades to a default rather than to a blank screen.
private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
